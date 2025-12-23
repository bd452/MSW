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
    // Tracks current button state for mouse motion events
    int button_state;
#if __APPLE__
    SpiceSession *session;
    SpiceInputsChannel *inputs_channel;
    SpiceMainChannel *main_channel;
    gulong channel_new_handler_id;
#endif
} winrun_spice_stream;

static void *winrun_mock_worker(void *context);

#if __APPLE__
// Signal handler for new channels from Spice session
static void on_channel_new(SpiceSession *session, SpiceChannel *channel, gpointer user_data) {
    (void)session;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream) {
        return;
    }

    if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        pthread_mutex_lock(&stream->send_mutex);
        stream->inputs_channel = SPICE_INPUTS_CHANNEL(channel);
        g_object_ref(stream->inputs_channel);
        pthread_mutex_unlock(&stream->send_mutex);
    } else if (SPICE_IS_MAIN_CHANNEL(channel)) {
        pthread_mutex_lock(&stream->send_mutex);
        stream->main_channel = SPICE_MAIN_CHANNEL(channel);
        g_object_ref(stream->main_channel);
        pthread_mutex_unlock(&stream->send_mutex);
    }
}

// Convert our mouse button enum to Spice button number
static int winrun_button_to_spice(winrun_mouse_button button) {
    switch (button) {
        case WINRUN_MOUSE_BUTTON_LEFT:   return SPICE_MOUSE_BUTTON_LEFT;
        case WINRUN_MOUSE_BUTTON_RIGHT:  return SPICE_MOUSE_BUTTON_RIGHT;
        case WINRUN_MOUSE_BUTTON_MIDDLE: return SPICE_MOUSE_BUTTON_MIDDLE;
        // Map extra buttons to Spice up/down (used for extra mouse buttons)
        case WINRUN_MOUSE_BUTTON_EXTRA1: return SPICE_MOUSE_BUTTON_UP;
        case WINRUN_MOUSE_BUTTON_EXTRA2: return SPICE_MOUSE_BUTTON_DOWN;
        default: return 0;
    }
}

// Convert our button to mask bit for button state tracking
static int winrun_button_to_mask(winrun_mouse_button button) {
    switch (button) {
        case WINRUN_MOUSE_BUTTON_LEFT:   return SPICE_MOUSE_BUTTON_MASK_LEFT;
        case WINRUN_MOUSE_BUTTON_RIGHT:  return SPICE_MOUSE_BUTTON_MASK_RIGHT;
        case WINRUN_MOUSE_BUTTON_MIDDLE: return SPICE_MOUSE_BUTTON_MASK_MIDDLE;
        case WINRUN_MOUSE_BUTTON_EXTRA1: return SPICE_MOUSE_BUTTON_MASK_UP;
        case WINRUN_MOUSE_BUTTON_EXTRA2: return SPICE_MOUSE_BUTTON_MASK_DOWN;
        default: return 0;
    }
}
#endif

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
    stream->button_state = 0;
    pthread_mutex_init(&stream->send_mutex, NULL);
    atomic_store(&stream->worker_running, true);
#if __APPLE__
    stream->session = NULL;
    stream->inputs_channel = NULL;
    stream->main_channel = NULL;
    stream->channel_new_handler_id = 0;
#endif
    return stream;
}

static void winrun_spice_stream_free(winrun_spice_stream *stream) {
    if (!stream) {
        return;
    }

    pthread_mutex_destroy(&stream->send_mutex);

#if __APPLE__
    // Disconnect signal handler before releasing session
    if (stream->session && stream->channel_new_handler_id != 0) {
        g_signal_handler_disconnect(stream->session, stream->channel_new_handler_id);
    }

    if (stream->inputs_channel) {
        g_object_unref(stream->inputs_channel);
    }

    if (stream->main_channel) {
        g_object_unref(stream->main_channel);
    }

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

    // Connect channel-new handler to capture inputs channel
    stream->channel_new_handler_id = g_signal_connect(
        stream->session,
        "channel-new",
        G_CALLBACK(on_channel_new),
        stream
    );

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
    (void)ticket;
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

    // Connect channel-new handler to capture inputs channel
    stream->channel_new_handler_id = g_signal_connect(
        stream->session,
        "channel-new",
        G_CALLBACK(on_channel_new),
        stream
    );

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

#if __APPLE__
    SpiceInputsChannel *inputs = stream->inputs_channel;
    if (!inputs) {
        pthread_mutex_unlock(&stream->send_mutex);
        return false;
    }

    int x = (int)event->x;
    int y = (int)event->y;

    switch (event->event_type) {
        case WINRUN_MOUSE_EVENT_MOVE:
            // Use absolute positioning with display 0 (primary display)
            // button_state tracks which buttons are currently held
            spice_inputs_channel_position(inputs, x, y, 0, stream->button_state);
            break;

        case WINRUN_MOUSE_EVENT_PRESS: {
            int button = winrun_button_to_spice(event->button);
            int mask = winrun_button_to_mask(event->button);
            // Update button state before sending press
            stream->button_state |= mask;
            // Send position first to ensure cursor is at correct location
            spice_inputs_channel_position(inputs, x, y, 0, stream->button_state);
            spice_inputs_channel_button_press(inputs, button, stream->button_state);
            break;
        }

        case WINRUN_MOUSE_EVENT_RELEASE: {
            int button = winrun_button_to_spice(event->button);
            int mask = winrun_button_to_mask(event->button);
            // Send position first to ensure cursor is at correct location
            spice_inputs_channel_position(inputs, x, y, 0, stream->button_state);
            spice_inputs_channel_button_release(inputs, button, stream->button_state);
            // Update button state after sending release
            stream->button_state &= ~mask;
            break;
        }

        case WINRUN_MOUSE_EVENT_SCROLL: {
            // Spice scroll is handled via button press/release of scroll buttons
            // Positive delta = scroll up/right, negative = scroll down/left
            int scroll_y = (int)event->scroll_delta_y;
            int scroll_x = (int)event->scroll_delta_x;

            // Vertical scroll
            if (scroll_y > 0) {
                // Scroll up - repeated presses for momentum
                for (int i = 0; i < scroll_y; i++) {
                    spice_inputs_channel_button_press(inputs, SPICE_MOUSE_BUTTON_UP, stream->button_state);
                    spice_inputs_channel_button_release(inputs, SPICE_MOUSE_BUTTON_UP, stream->button_state);
                }
            } else if (scroll_y < 0) {
                // Scroll down
                for (int i = 0; i < -scroll_y; i++) {
                    spice_inputs_channel_button_press(inputs, SPICE_MOUSE_BUTTON_DOWN, stream->button_state);
                    spice_inputs_channel_button_release(inputs, SPICE_MOUSE_BUTTON_DOWN, stream->button_state);
                }
            }

            // Horizontal scroll (if supported) - some Spice implementations may not support this
            // We map to side buttons which some guests interpret as horizontal scroll
            (void)scroll_x;
            break;
        }

        default:
            pthread_mutex_unlock(&stream->send_mutex);
            return false;
    }
#else
    (void)event;
#endif

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

#if __APPLE__
    SpiceInputsChannel *inputs = stream->inputs_channel;
    if (!inputs) {
        pthread_mutex_unlock(&stream->send_mutex);
        return false;
    }

    // Spice uses hardware scan codes, not virtual key codes
    // The scan_code field should contain the hardware scan code
    // If scan_code is 0, we use key_code as a fallback (though this may not work correctly)
    guint scancode = event->scan_code != 0 ? event->scan_code : event->key_code;

    // Extended keys (right Ctrl, arrow keys, Insert, Delete, Home, End, Page Up/Down,
    // Numpad Enter, Numpad /, etc.) have a 0xE0 prefix in their scan code
    // Spice expects the extended flag to be encoded in the high byte
    if (event->is_extended_key) {
        scancode |= 0x100;  // Set bit 8 to indicate extended key
    }

    switch (event->event_type) {
        case WINRUN_KEY_EVENT_DOWN:
            spice_inputs_channel_key_press(inputs, scancode);
            break;

        case WINRUN_KEY_EVENT_UP:
            spice_inputs_channel_key_release(inputs, scancode);
            break;

        default:
            pthread_mutex_unlock(&stream->send_mutex);
            return false;
    }
#else
    (void)event;
#endif

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
