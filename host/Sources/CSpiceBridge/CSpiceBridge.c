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
#include <glib.h>
#include <spice-client.h>
#endif

typedef struct winrun_spice_stream {
    pthread_t worker_thread;
    _Atomic bool worker_running;
    uint64_t window_id;
    void *user_data;
    winrun_spice_frame_cb frame_cb;
    winrun_spice_metadata_cb metadata_cb;
    winrun_spice_closed_cb closed_cb;
#if __APPLE__
    SpiceSession *session;
#endif
} winrun_spice_stream;

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
    atomic_store(&stream->worker_running, true);
    return stream;
}

static void winrun_spice_stream_free(winrun_spice_stream *stream) {
    if (!stream) {
        return;
    }

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

winrun_spice_stream *winrun_spice_stream_open_tcp(
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
    if (stream->session) {
        g_object_set(stream->session,
                     "host", host,
                     use_tls ? "tls-port" : "port", port_string,
                     NULL);
        if (ticket) {
            g_object_set(stream->session, "password", ticket, NULL);
        }
        spice_session_connect(stream->session);
    }
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

winrun_spice_stream *winrun_spice_stream_open_shared(
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
    int fd_dup = dup(shared_fd);
    if (fd_dup < 0) {
        winrun_write_error(error_buffer, error_buffer_length, strerror(errno));
        winrun_spice_stream_free(stream);
        return NULL;
    }

    stream->session = spice_session_new();
    if (!stream->session) {
        close(fd_dup);
        winrun_spice_stream_free(stream);
        winrun_write_error(error_buffer, error_buffer_length, "Unable to create Spice session");
        return NULL;
    }

    if (ticket) {
        g_object_set(stream->session, "password", ticket, NULL);
    }

    spice_session_connect_with_fd(stream->session, fd_dup);
#else
    (void)ticket;
#endif

    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }

    return stream;
}

void winrun_spice_stream_close(winrun_spice_stream *stream) {
    if (!stream) {
        return;
    }

    atomic_store(&stream->worker_running, false);
    pthread_join(stream->worker_thread, NULL);

#if __APPLE__
    if (stream->session) {
        g_object_unref(stream->session);
    }
#endif

    free(stream);
}
