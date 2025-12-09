#include "CSpiceBridge.h"

#include <pthread.h>
#include <errno.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if __APPLE__
#include "shim.h"
#endif

typedef struct winrun_spice_stream {
    pthread_t worker_thread;
    _Atomic bool worker_running;
    uint64_t window_id;
    void *user_data;
    winrun_spice_frame_cb frame_cb;
    winrun_spice_metadata_cb metadata_cb;
    winrun_spice_closed_cb closed_cb;
    winrun_clipboard_cb clipboard_cb;
    void *clipboard_user_data;
    pthread_mutex_t send_mutex;
#if __APPLE__
    SpiceSession *session;
    // TODO: Add inputs_channel and main_channel when full libspice-gtk is integrated
    // SpiceInputsChannel *inputs_channel;
    // SpiceMainChannel *main_channel;
#endif
} winrun_spice_stream;

static void *winrun_mock_worker(void *context);

static void winrun_write_error(char *buffer, size_t length, const char *message) {
    if (!buffer || length == 0 || !message) {
        return;
    }
    size_t msg_len = strnlen(message, length - 1);
    memcpy(buffer, message, msg_len);
    buffer[msg_len] = '\0';
}

static winrun_spice_stream *winrun_spice_stream_create(
    uint64_t window_id,
    void *user_data,
    winrun_spice_frame_cb frame_cb,
    winrun_spice_metadata_cb metadata_cb,
    winrun_spice_closed_cb closed_cb,
    char *error_buffer,
    size_t error_buffer_length
) {
    winrun_spice_stream *stream = calloc(1, sizeof(winrun_spice_stream));
    if (!stream) {
        winrun_write_error(error_buffer, error_buffer_length, "Allocation failure");
        return NULL;
    }

    stream->window_id = window_id;
    stream->user_data = user_data;
    stream->frame_cb = frame_cb;
    stream->metadata_cb = metadata_cb;
    stream->closed_cb = closed_cb;
    stream->clipboard_cb = NULL;
    stream->clipboard_user_data = NULL;
    pthread_mutex_init(&stream->send_mutex, NULL);
    atomic_store(&stream->worker_running, true);
    return stream;
}

static void winrun_spice_stream_free(winrun_spice_stream *stream) {
    if (!stream) {
        return;
    }

    pthread_mutex_destroy(&stream->send_mutex);

#if __APPLE__
    if (stream->session) {
        g_object_unref(stream->session);
    }
#endif

    free(stream);
}

static bool winrun_spice_stream_start_worker(
    winrun_spice_stream *stream,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (!stream) {
        return false;
    }

    if (pthread_create(&stream->worker_thread, NULL, winrun_mock_worker, stream) != 0) {
        winrun_write_error(error_buffer, error_buffer_length, "Failed to spawn Spice worker thread");
        atomic_store(&stream->worker_running, false);
        return false;
    }

    return true;
}

static void *winrun_mock_worker(void *context) {
    winrun_spice_stream *stream = (winrun_spice_stream *)context;
    if (!stream) {
        return NULL;
    }

    if (stream->metadata_cb) {
        winrun_spice_window_metadata metadata = {
            .window_id = stream->window_id,
            .position_x = 100.0,
            .position_y = 100.0,
            .width = 800.0,
            .height = 600.0,
            .scale_factor = 1.0,
            .is_resizable = true,
            .title = "Spice Window"
        };
        stream->metadata_cb(&metadata, stream->user_data);
    }

    struct timespec frame_delay = {
        .tv_sec = 0,
        .tv_nsec = 33 * 1000 * 1000
    };

    while (atomic_load(&stream->worker_running)) {
        if (stream->frame_cb) {
            uint8_t buffer[1024];
            for (size_t i = 0; i < sizeof(buffer); ++i) {
                buffer[i] = (uint8_t)(rand() % 255);
            }
            stream->frame_cb(buffer, sizeof(buffer), stream->user_data);
        }
        nanosleep(&frame_delay, NULL);
    }

    if (stream->closed_cb) {
        stream->closed_cb(WINRUN_SPICE_CLOSE_REASON_REMOTE, "Stream closed", stream->user_data);
    }

    return NULL;
}

winrun_spice_stream_handle winrun_spice_stream_open_tcp(
    const char *host,
    uint16_t port,
    bool use_tls,
    uint64_t window_id,
    void *user_data,
    winrun_spice_frame_cb frame_cb,
    winrun_spice_metadata_cb metadata_cb,
    winrun_spice_closed_cb closed_cb,
    const char *ticket,
    char *error_buffer,
    size_t error_buffer_length
) {
    winrun_spice_stream *stream = winrun_spice_stream_create(
        window_id,
        user_data,
        frame_cb,
        metadata_cb,
        closed_cb,
        error_buffer,
        error_buffer_length
    );
    if (!stream) {
        return NULL;
    }

#if __APPLE__
    char port_string[16];
    snprintf(port_string, sizeof(port_string), "%u", port);

    stream->session = spice_session_new();
    if (!stream->session) {
        winrun_write_error(error_buffer, error_buffer_length, "Unable to create Spice session");
        winrun_spice_stream_free(stream);
        return NULL;
    }

    g_object_set(stream->session,
                 "host", host,
                 use_tls ? "tls-port" : "port", port_string,
                 NULL);
    if (ticket) {
        g_object_set(stream->session, "password", ticket, NULL);
    }
    spice_session_connect(stream->session);
#else
    (void)host;
    (void)port;
    (void)use_tls;
#endif

    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }

    return stream;
}

winrun_spice_stream_handle winrun_spice_stream_open_shared(
    int shared_fd,
    uint64_t window_id,
    void *user_data,
    winrun_spice_frame_cb frame_cb,
    winrun_spice_metadata_cb metadata_cb,
    winrun_spice_closed_cb closed_cb,
    const char *ticket,
    char *error_buffer,
    size_t error_buffer_length
) {
    if (shared_fd < 0) {
        winrun_write_error(error_buffer, error_buffer_length, "Invalid shared-memory descriptor");
        return NULL;
    }

    winrun_spice_stream *stream = winrun_spice_stream_create(
        window_id,
        user_data,
        frame_cb,
        metadata_cb,
        closed_cb,
        error_buffer,
        error_buffer_length
    );
    if (!stream) {
        return NULL;
    }

#if __APPLE__
    stream->session = spice_session_new();
    if (!stream->session) {
        winrun_write_error(error_buffer, error_buffer_length, "Unable to create Spice session");
        winrun_spice_stream_free(stream);
        return NULL;
    }

    if (ticket) {
        g_object_set(stream->session, "password", ticket, NULL);
    }

    g_object_set(stream->session, "host", "spice-shm", NULL);
    spice_session_connect(stream->session);
#else
    (void)ticket;
#endif

    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }

    return stream;
}

void winrun_spice_stream_close(winrun_spice_stream_handle streamHandle) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream) {
        return;
    }

    atomic_store(&stream->worker_running, false);
    pthread_join(stream->worker_thread, NULL);

    winrun_spice_stream_free(stream);
}

// MARK: - Input Events

bool winrun_spice_send_mouse_event(
    winrun_spice_stream_handle streamHandle,
    const winrun_mouse_event *event
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream || !event) {
        return false;
    }

    pthread_mutex_lock(&stream->send_mutex);

    // TODO: Implement actual Spice input send when libspice-gtk is fully integrated
    // Will use spice_inputs_channel_motion, spice_inputs_channel_button_press, etc.
    (void)event;

    pthread_mutex_unlock(&stream->send_mutex);
    return true;
}

bool winrun_spice_send_keyboard_event(
    winrun_spice_stream_handle streamHandle,
    const winrun_keyboard_event *event
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream || !event) {
        return false;
    }

    pthread_mutex_lock(&stream->send_mutex);

    // TODO: Implement actual Spice keyboard send when libspice-gtk is fully integrated
    // Will use spice_inputs_channel_key_press and spice_inputs_channel_key_release
    (void)event;

    pthread_mutex_unlock(&stream->send_mutex);
    return true;
}

// MARK: - Clipboard

void winrun_spice_set_clipboard_callback(
    winrun_spice_stream_handle streamHandle,
    winrun_clipboard_cb clipboard_cb,
    void *user_data
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream) {
        return;
    }

    pthread_mutex_lock(&stream->send_mutex);
    stream->clipboard_cb = clipboard_cb;
    stream->clipboard_user_data = user_data;
    pthread_mutex_unlock(&stream->send_mutex);
}

bool winrun_spice_send_clipboard(
    winrun_spice_stream_handle streamHandle,
    const winrun_clipboard_data *clipboard
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream || !clipboard || !clipboard->data) {
        return false;
    }

    pthread_mutex_lock(&stream->send_mutex);

    // TODO: Implement actual Spice clipboard send when libspice-gtk is fully integrated
    // For now, clipboard data is queued for the mock worker to handle
    (void)clipboard;

    pthread_mutex_unlock(&stream->send_mutex);
    return true;
}

void winrun_spice_request_clipboard(
    winrun_spice_stream_handle streamHandle,
    winrun_clipboard_format format
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream) {
        return;
    }

    pthread_mutex_lock(&stream->send_mutex);

    // TODO: Implement actual Spice clipboard request when libspice-gtk is fully integrated
    (void)format;

    pthread_mutex_unlock(&stream->send_mutex);
}

// MARK: - Drag and Drop

bool winrun_spice_send_drag_event(
    winrun_spice_stream_handle streamHandle,
    const winrun_drag_event *event
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream || !event) {
        return false;
    }

    pthread_mutex_lock(&stream->send_mutex);

    // TODO: Implement actual Spice file transfer when libspice-gtk is fully integrated
    // For drop events, we will use spice_main_channel_file_copy_async
    (void)event;

    pthread_mutex_unlock(&stream->send_mutex);
    return true;
}
