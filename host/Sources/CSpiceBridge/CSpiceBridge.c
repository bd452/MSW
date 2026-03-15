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

// Spice protocol clipboard constants (from spice-protocol/spice/vd_agent.h)
// These are stable protocol values that may not be exposed by spice-client.h
#ifndef VD_AGENT_CLIPBOARD_NONE
#define VD_AGENT_CLIPBOARD_NONE 0
#define VD_AGENT_CLIPBOARD_UTF8_TEXT 1
#define VD_AGENT_CLIPBOARD_IMAGE_PNG 2
#define VD_AGENT_CLIPBOARD_IMAGE_BMP 3
#define VD_AGENT_CLIPBOARD_IMAGE_TIFF 4
#define VD_AGENT_CLIPBOARD_IMAGE_JPG 5
#endif

#ifndef VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD
#define VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD 0
#define VD_AGENT_CLIPBOARD_SELECTION_PRIMARY 1
#define VD_AGENT_CLIPBOARD_SELECTION_SECONDARY 2
#endif
#endif

typedef struct winrun_spice_stream {
    pthread_t worker_thread;
    _Atomic bool worker_running;
    bool worker_started;  // Tracks whether worker_thread was actually created
    uint64_t window_id;
    void *user_data;
    winrun_spice_frame_cb frame_cb;
    winrun_spice_metadata_cb metadata_cb;
    winrun_spice_closed_cb closed_cb;
    winrun_clipboard_cb clipboard_cb;
    void *clipboard_user_data;
    // Control channel callback
    winrun_control_message_cb control_cb;
    void *control_user_data;
    pthread_mutex_t send_mutex;
    // Tracks current button state for mouse motion events
    int button_state;
    // Clipboard sequence number for deduplication
    uint64_t clipboard_sequence;
#if __APPLE__
    SpiceSession *session;
    SpiceInputsChannel *inputs_channel;
    SpiceMainChannel *main_channel;
    SpiceDisplayChannel *display_channel;
    SpicePortChannel *control_channel;  // For bidirectional control messages
    gulong channel_new_handler_id;
    // Display signal handlers
    gulong display_primary_create_handler_id;
    gulong display_primary_destroy_handler_id;
    gulong display_invalidate_handler_id;
    // Clipboard signal handlers on main channel
    gulong clipboard_grab_handler_id;
    gulong clipboard_data_handler_id;
    gulong clipboard_request_handler_id;
    gulong clipboard_release_handler_id;
    // Control channel signal handler
    gulong control_data_handler_id;
#endif
} winrun_spice_stream;

static void *winrun_mock_worker(void *context);
#if __APPLE__
static void *winrun_spice_glib_worker(void *context);
#endif

#if __APPLE__
// Forward declarations for clipboard signal handlers (needed before on_channel_new)
static void on_clipboard_grab(SpiceMainChannel *channel, guint selection,
                              guint32 *types, guint ntypes, gpointer user_data);
static void on_clipboard_data(SpiceMainChannel *channel, guint selection,
                              guint type, const guchar *data, guint size,
                              gpointer user_data);
static void on_clipboard_request(SpiceMainChannel *channel, guint selection,
                                 guint type, gpointer user_data);
static void on_clipboard_release(SpiceMainChannel *channel, guint selection,
                                 gpointer user_data);
static void on_control_port_data(SpicePortChannel *channel, gpointer data,
                                 gint size, gpointer user_data);
static void on_display_primary_create(SpiceChannel *channel,
                                      gint format,
                                      gint width,
                                      gint height,
                                      gint stride,
                                      gint shmid,
                                      gpointer data,
                                      gpointer user_data);
static void on_display_primary_destroy(SpiceChannel *channel, gpointer user_data);
static void on_display_invalidate(SpiceChannel *channel,
                                  gint x,
                                  gint y,
                                  gint w,
                                  gint h,
                                  gpointer user_data);
static void on_channel_event(SpiceChannel *channel, gint event, gpointer user_data);
static void winrun_emit_display_metadata(winrun_spice_stream *stream, gint width, gint height);
static void winrun_emit_primary_frame(SpiceChannel *channel, winrun_spice_stream *stream);

// Port name for control channel - must match what guest listens on
#define WINRUN_CONTROL_PORT_NAME "com.winrun.control"

// Signal handler for new channels from Spice session
static void on_channel_new(SpiceSession *session, SpiceChannel *channel, gpointer user_data) {
    (void)session;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream) {
        return;
    }
    bool control_only_stream = (stream->window_id == UINT64_MAX);

    g_signal_connect(channel, "channel-event", G_CALLBACK(on_channel_event), stream);

    if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        if (control_only_stream) {
            fprintf(stderr, "[CSPICE] channel-new: inputs (ignored for control-only stream)\n");
            return;
        }
        fprintf(stderr, "[CSPICE] channel-new: inputs\n");
        pthread_mutex_lock(&stream->send_mutex);
        // Release previous channel if reconnecting
        if (stream->inputs_channel) {
            g_object_unref(stream->inputs_channel);
        }
        stream->inputs_channel = SPICE_INPUTS_CHANNEL(channel);
        g_object_ref(stream->inputs_channel);
        pthread_mutex_unlock(&stream->send_mutex);
        spice_channel_connect(channel);
    } else if (SPICE_IS_MAIN_CHANNEL(channel)) {
        fprintf(stderr, "[CSPICE] channel-new: main\n");
        pthread_mutex_lock(&stream->send_mutex);

        // Disconnect old clipboard handlers if reconnecting
        if (stream->main_channel) {
            if (stream->clipboard_grab_handler_id) {
                g_signal_handler_disconnect(stream->main_channel, stream->clipboard_grab_handler_id);
            }
            if (stream->clipboard_data_handler_id) {
                g_signal_handler_disconnect(stream->main_channel, stream->clipboard_data_handler_id);
            }
            if (stream->clipboard_request_handler_id) {
                g_signal_handler_disconnect(stream->main_channel, stream->clipboard_request_handler_id);
            }
            if (stream->clipboard_release_handler_id) {
                g_signal_handler_disconnect(stream->main_channel, stream->clipboard_release_handler_id);
            }
            g_object_unref(stream->main_channel);
        }

        stream->main_channel = SPICE_MAIN_CHANNEL(channel);
        g_object_ref(stream->main_channel);

        // Connect clipboard signal handlers
        stream->clipboard_grab_handler_id = g_signal_connect(
            stream->main_channel,
            "main-clipboard-selection-grab",
            G_CALLBACK(on_clipboard_grab),
            stream
        );
        stream->clipboard_data_handler_id = g_signal_connect(
            stream->main_channel,
            "main-clipboard-selection",
            G_CALLBACK(on_clipboard_data),
            stream
        );
        stream->clipboard_request_handler_id = g_signal_connect(
            stream->main_channel,
            "main-clipboard-selection-request",
            G_CALLBACK(on_clipboard_request),
            stream
        );
        stream->clipboard_release_handler_id = g_signal_connect(
            stream->main_channel,
            "main-clipboard-selection-release",
            G_CALLBACK(on_clipboard_release),
            stream
        );

        pthread_mutex_unlock(&stream->send_mutex);
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        if (control_only_stream) {
            fprintf(stderr, "[CSPICE] channel-new: display (ignored for control-only stream)\n");
            return;
        }
        fprintf(stderr, "[CSPICE] channel-new: display\n");
        pthread_mutex_lock(&stream->send_mutex);

        // Disconnect old display handlers if reconnecting
        if (stream->display_channel) {
            if (stream->display_primary_create_handler_id) {
                g_signal_handler_disconnect(stream->display_channel, stream->display_primary_create_handler_id);
            }
            if (stream->display_primary_destroy_handler_id) {
                g_signal_handler_disconnect(stream->display_channel, stream->display_primary_destroy_handler_id);
            }
            if (stream->display_invalidate_handler_id) {
                g_signal_handler_disconnect(stream->display_channel, stream->display_invalidate_handler_id);
            }
            g_object_unref(stream->display_channel);
        }

        stream->display_channel = SPICE_DISPLAY_CHANNEL(channel);
        g_object_ref(stream->display_channel);

        // Listen for primary surface lifecycle and dirty-region updates
        stream->display_primary_create_handler_id = g_signal_connect(
            stream->display_channel,
            "display-primary-create",
            G_CALLBACK(on_display_primary_create),
            stream
        );
        stream->display_primary_destroy_handler_id = g_signal_connect(
            stream->display_channel,
            "display-primary-destroy",
            G_CALLBACK(on_display_primary_destroy),
            stream
        );
        stream->display_invalidate_handler_id = g_signal_connect(
            stream->display_channel,
            "display-invalidate",
            G_CALLBACK(on_display_invalidate),
            stream
        );

        SpiceDisplayPrimary primary;
        memset(&primary, 0, sizeof(primary));
        gboolean has_primary = spice_display_channel_get_primary(SPICE_CHANNEL(stream->display_channel), 0, &primary);
        fprintf(
            stderr,
            "[CSPICE] display channel initial primary available=%d width=%d height=%d stride=%d data=%p\n",
            has_primary ? 1 : 0,
            primary.width,
            primary.height,
            primary.stride,
            (void *)primary.data
        );
        if (has_primary && primary.data && primary.width > 0 && primary.height > 0 && primary.stride > 0) {
            winrun_emit_display_metadata(stream, primary.width, primary.height);
            winrun_emit_primary_frame(SPICE_CHANNEL(stream->display_channel), stream);
        }

        pthread_mutex_unlock(&stream->send_mutex);
        spice_channel_connect(channel);
    } else if (SPICE_IS_PORT_CHANNEL(channel)) {
        fprintf(stderr, "[CSPICE] channel-new: port\n");
        // Check if this is our control port channel
        gchar *port_name = NULL;
        g_object_get(channel, "port-name", &port_name, NULL);

        if (port_name && g_strcmp0(port_name, WINRUN_CONTROL_PORT_NAME) == 0) {
            pthread_mutex_lock(&stream->send_mutex);

            // Disconnect old handler if reconnecting
            if (stream->control_channel) {
                if (stream->control_data_handler_id) {
                    g_signal_handler_disconnect(stream->control_channel, stream->control_data_handler_id);
                }
                g_object_unref(stream->control_channel);
            }

            stream->control_channel = SPICE_PORT_CHANNEL(channel);
            g_object_ref(stream->control_channel);

            // Connect data received handler
            stream->control_data_handler_id = g_signal_connect(
                stream->control_channel,
                "port-data",
                G_CALLBACK(on_control_port_data),
                stream
            );

            pthread_mutex_unlock(&stream->send_mutex);
        }

        g_free(port_name);
        spice_channel_connect(channel);
    }
}

// Handler for receiving data from control port channel
static void on_control_port_data(SpicePortChannel *channel, gpointer data,
                                 gint size, gpointer user_data) {
    (void)channel;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream || !data || size <= 0) {
        return;
    }

    pthread_mutex_lock(&stream->send_mutex);
    winrun_control_message_cb cb = stream->control_cb;
    void *cb_user_data = stream->control_user_data;
    pthread_mutex_unlock(&stream->send_mutex);

    if (cb) {
        cb((const uint8_t *)data, (size_t)size, cb_user_data);
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

// Convert our clipboard format to Spice clipboard type
static guint winrun_format_to_spice(winrun_clipboard_format format) {
    switch (format) {
        case WINRUN_CLIPBOARD_FORMAT_TEXT: return VD_AGENT_CLIPBOARD_UTF8_TEXT;
        case WINRUN_CLIPBOARD_FORMAT_RTF:  return VD_AGENT_CLIPBOARD_UTF8_TEXT; // RTF sent as text
        case WINRUN_CLIPBOARD_FORMAT_HTML: return VD_AGENT_CLIPBOARD_UTF8_TEXT; // HTML sent as text
        case WINRUN_CLIPBOARD_FORMAT_PNG:  return VD_AGENT_CLIPBOARD_IMAGE_PNG;
        case WINRUN_CLIPBOARD_FORMAT_TIFF: return VD_AGENT_CLIPBOARD_IMAGE_BMP; // TIFF -> BMP fallback
        case WINRUN_CLIPBOARD_FORMAT_FILE_URL: return VD_AGENT_CLIPBOARD_UTF8_TEXT;
        default: return VD_AGENT_CLIPBOARD_UTF8_TEXT;
    }
}

// Convert Spice clipboard type to our format
static winrun_clipboard_format spice_to_winrun_format(guint spice_type) {
    switch (spice_type) {
        case VD_AGENT_CLIPBOARD_UTF8_TEXT: return WINRUN_CLIPBOARD_FORMAT_TEXT;
        case VD_AGENT_CLIPBOARD_IMAGE_PNG: return WINRUN_CLIPBOARD_FORMAT_PNG;
        case VD_AGENT_CLIPBOARD_IMAGE_BMP: return WINRUN_CLIPBOARD_FORMAT_PNG; // Convert BMP to PNG
        default: return WINRUN_CLIPBOARD_FORMAT_TEXT;
    }
}

static void winrun_emit_display_metadata(winrun_spice_stream *stream, gint width, gint height) {
    if (!stream || !stream->metadata_cb) {
        return;
    }

    winrun_spice_window_metadata metadata = {
        .window_id = stream->window_id,
        .position_x = 0.0,
        .position_y = 0.0,
        .width = width > 0 ? (double)width : 800.0,
        .height = height > 0 ? (double)height : 600.0,
        .scale_factor = 1.0,
        .is_resizable = true,
        .title = "Windows VM Console"
    };
    stream->metadata_cb(&metadata, stream->user_data);
}

static void winrun_emit_primary_frame(SpiceChannel *channel, winrun_spice_stream *stream) {
    if (!channel || !stream || !stream->frame_cb) {
        return;
    }

    SpiceDisplayPrimary primary;
    memset(&primary, 0, sizeof(primary));
    if (!spice_display_channel_get_primary(channel, 0, &primary)) {
        return;
    }
    if (!primary.data || primary.width <= 0 || primary.height <= 0 || primary.stride <= 0) {
        return;
    }

    size_t length = (size_t)primary.stride * (size_t)primary.height;
    if (length == 0) {
        return;
    }
    static uint64_t emitted_frames = 0;
    emitted_frames++;
    if (emitted_frames <= 5 || emitted_frames % 120 == 0) {
        fprintf(
            stderr,
            "[CSPICE] emit-primary-frame #%llu size=%dx%d stride=%d bytes=%zu\n",
            (unsigned long long)emitted_frames,
            primary.width,
            primary.height,
            primary.stride,
            length
        );
    }
    stream->frame_cb(primary.data, length, stream->user_data);
}

static void on_display_primary_create(SpiceChannel *channel,
                                      gint format,
                                      gint width,
                                      gint height,
                                      gint stride,
                                      gint shmid,
                                      gpointer data,
                                      gpointer user_data) {
    (void)format;
    (void)stride;
    (void)shmid;
    (void)data;

    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream) {
        return;
    }

    fprintf(stderr, "[CSPICE] display-primary-create %dx%d stride=%d\n", width, height, stride);
    winrun_emit_display_metadata(stream, width, height);
    winrun_emit_primary_frame(channel, stream);
}

static void on_display_primary_destroy(SpiceChannel *channel, gpointer user_data) {
    (void)channel;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream || !stream->metadata_cb) {
        return;
    }

    winrun_spice_window_metadata metadata = {
        .window_id = stream->window_id,
        .position_x = 0.0,
        .position_y = 0.0,
        .width = 0.0,
        .height = 0.0,
        .scale_factor = 1.0,
        .is_resizable = true,
        .title = "Windows VM Console"
    };
    stream->metadata_cb(&metadata, stream->user_data);
}

static void on_display_invalidate(SpiceChannel *channel,
                                  gint x,
                                  gint y,
                                  gint w,
                                  gint h,
                                  gpointer user_data) {
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream) {
        return;
    }
    static int invalidate_count = 0;
    invalidate_count++;
    if (invalidate_count <= 3) {
        fprintf(stderr, "[CSPICE] display-invalidate #%d x=%d y=%d w=%d h=%d\n",
                invalidate_count, x, y, w, h);
    }
    winrun_emit_primary_frame(channel, stream);
}

static const char *winrun_channel_event_name(gint event) {
    switch (event) {
        case SPICE_CHANNEL_NONE: return "NONE";
        case SPICE_CHANNEL_OPENED: return "OPENED";
        case SPICE_CHANNEL_SWITCHING: return "SWITCHING";
        case SPICE_CHANNEL_CLOSED: return "CLOSED";
        case SPICE_CHANNEL_ERROR_IO: return "ERROR_IO";
        case SPICE_CHANNEL_ERROR_TLS: return "ERROR_TLS";
        case SPICE_CHANNEL_ERROR_LINK: return "ERROR_LINK";
        case SPICE_CHANNEL_ERROR_CONNECT: return "ERROR_CONNECT";
        case SPICE_CHANNEL_ERROR_AUTH: return "ERROR_AUTH";
        default: return "UNKNOWN";
    }
}

static void on_channel_event(SpiceChannel *channel, gint event, gpointer user_data) {
    (void)user_data;
    gint channel_type = 0;
    gint channel_id = 0;
    g_object_get(channel, "channel-type", &channel_type, "channel-id", &channel_id, NULL);
    fprintf(
        stderr,
        "[CSPICE] channel-event type=%d id=%d event=%s(%d)\n",
        channel_type,
        channel_id,
        winrun_channel_event_name(event),
        event
    );
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
    stream->control_cb = NULL;
    stream->control_user_data = NULL;
    stream->button_state = 0;
    stream->clipboard_sequence = 0;
    stream->worker_started = false;
    pthread_mutex_init(&stream->send_mutex, NULL);
    atomic_store(&stream->worker_running, true);
#if __APPLE__
    stream->session = NULL;
    stream->inputs_channel = NULL;
    stream->main_channel = NULL;
    stream->display_channel = NULL;
    stream->control_channel = NULL;
    stream->channel_new_handler_id = 0;
    stream->display_primary_create_handler_id = 0;
    stream->display_primary_destroy_handler_id = 0;
    stream->display_invalidate_handler_id = 0;
    stream->clipboard_grab_handler_id = 0;
    stream->clipboard_data_handler_id = 0;
    stream->clipboard_request_handler_id = 0;
    stream->clipboard_release_handler_id = 0;
    stream->control_data_handler_id = 0;
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

    // Disconnect clipboard handlers from main channel
    if (stream->main_channel) {
        if (stream->clipboard_grab_handler_id) {
            g_signal_handler_disconnect(stream->main_channel, stream->clipboard_grab_handler_id);
        }
        if (stream->clipboard_data_handler_id) {
            g_signal_handler_disconnect(stream->main_channel, stream->clipboard_data_handler_id);
        }
        if (stream->clipboard_request_handler_id) {
            g_signal_handler_disconnect(stream->main_channel, stream->clipboard_request_handler_id);
        }
        if (stream->clipboard_release_handler_id) {
            g_signal_handler_disconnect(stream->main_channel, stream->clipboard_release_handler_id);
        }
    }

    // Disconnect control channel handler
    if (stream->control_channel) {
        if (stream->control_data_handler_id) {
            g_signal_handler_disconnect(stream->control_channel, stream->control_data_handler_id);
        }
        g_object_unref(stream->control_channel);
    }

    if (stream->display_channel) {
        if (stream->display_primary_create_handler_id) {
            g_signal_handler_disconnect(stream->display_channel, stream->display_primary_create_handler_id);
        }
        if (stream->display_primary_destroy_handler_id) {
            g_signal_handler_disconnect(stream->display_channel, stream->display_primary_destroy_handler_id);
        }
        if (stream->display_invalidate_handler_id) {
            g_signal_handler_disconnect(stream->display_channel, stream->display_invalidate_handler_id);
        }
        g_object_unref(stream->display_channel);
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

#if __APPLE__
    void *(*worker_entry)(void *) = winrun_spice_glib_worker;
#else
    void *(*worker_entry)(void *) = winrun_mock_worker;
#endif

    if (pthread_create(&stream->worker_thread, NULL, worker_entry, stream) != 0) {
        winrun_write_error(error_buffer, error_buffer_length, "Failed to spawn Spice worker thread");
        atomic_store(&stream->worker_running, false);
        return false;
    }

    stream->worker_started = true;
    return true;
}

#if __APPLE__
static void *winrun_spice_glib_worker(void *context) {
    winrun_spice_stream *stream = (winrun_spice_stream *)context;
    if (!stream) {
        return NULL;
    }

    while (atomic_load(&stream->worker_running)) {
        g_main_context_iteration(NULL, TRUE);
    }

    return NULL;
}
#endif

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
    fprintf(
        stderr,
        "[CSPICE] open-tcp host=%s port=%u tls=%d window=%llu\n",
        host,
        port,
        use_tls ? 1 : 0,
        (unsigned long long)window_id
    );

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
    fprintf(stderr, "[CSPICE] spice_session_connect() invoked\n");
    spice_session_connect(stream->session);
    // Start a GLib event-loop worker so channel and frame callbacks are pumped.
    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }
#else
    (void)host;
    (void)port;
    (void)use_tls;
    (void)ticket;

    // Only start mock worker on non-macOS platforms (e.g., CI/test environments)
    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }
#endif

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
    fprintf(stderr, "[CSPICE] open-shared fd=%d window=%llu\n", shared_fd, (unsigned long long)window_id);
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

    // Use spice_session_open_fd for pre-connected shared memory descriptor
    // This is used with Virtualization.framework's shared memory transport
    if (!spice_session_open_fd(stream->session, shared_fd)) {
        winrun_write_error(error_buffer, error_buffer_length, "Failed to open Spice session with shared-memory descriptor");
        winrun_spice_stream_free(stream);
        return NULL;
    }
    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }
#else
    (void)shared_fd;
    (void)ticket;

    // Only start mock worker on non-macOS platforms (e.g., CI/test environments)
    if (!winrun_spice_stream_start_worker(stream, error_buffer, error_buffer_length)) {
        winrun_spice_stream_free(stream);
        return NULL;
    }
#endif

    return stream;
}

void winrun_spice_stream_close(winrun_spice_stream_handle streamHandle) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream) {
        return;
    }

    fprintf(stderr, "[CSPICE] stream-close window=%llu\n", (unsigned long long)stream->window_id);
    atomic_store(&stream->worker_running, false);

#if __APPLE__
    if (stream->session) {
        spice_session_disconnect(stream->session);
    }
    g_main_context_wakeup(NULL);
#endif

    // Only join the worker thread if it was actually started
    if (stream->worker_started) {
        pthread_join(stream->worker_thread, NULL);
    }

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

#if __APPLE__
// Called when guest grabs clipboard (guest has new clipboard content)
static void on_clipboard_grab(SpiceMainChannel *channel, guint selection,
                              guint32 *types, guint ntypes, gpointer user_data) {
    (void)channel;
    (void)selection;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream || !types || ntypes == 0) {
        return;
    }

    // Request the first available type from the guest
    // Prefer text, then images
    guint preferred_type = types[0];
    for (guint i = 0; i < ntypes; i++) {
        if (types[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
            preferred_type = types[i];
            break;
        }
        if (types[i] == VD_AGENT_CLIPBOARD_IMAGE_PNG) {
            preferred_type = types[i];
            // Keep looking for text
        }
    }

    pthread_mutex_lock(&stream->send_mutex);
    SpiceMainChannel *main = stream->main_channel;
    if (main) {
        // Request the clipboard data in the preferred format
        spice_main_channel_clipboard_selection_request(main, selection, preferred_type);
    }
    pthread_mutex_unlock(&stream->send_mutex);
}

// Called when guest sends clipboard data (response to our request or push)
static void on_clipboard_data(SpiceMainChannel *channel, guint selection,
                              guint type, const guchar *data, guint size,
                              gpointer user_data) {
    (void)channel;
    (void)selection;
    winrun_spice_stream *stream = (winrun_spice_stream *)user_data;
    if (!stream || !data || size == 0) {
        return;
    }

    pthread_mutex_lock(&stream->send_mutex);
    winrun_clipboard_cb cb = stream->clipboard_cb;
    void *cb_user_data = stream->clipboard_user_data;
    uint64_t seq = ++stream->clipboard_sequence;
    pthread_mutex_unlock(&stream->send_mutex);

    if (cb) {
        winrun_clipboard_data clipboard = {
            .format = spice_to_winrun_format(type),
            .data = data,
            .data_length = size,
            .sequence_number = seq
        };
        cb(&clipboard, cb_user_data);
    }
}

// Called when guest requests clipboard data from host
static void on_clipboard_request(SpiceMainChannel *channel, guint selection,
                                 guint type, gpointer user_data) {
    (void)channel;
    (void)selection;
    (void)type;
    (void)user_data;
    // This is called when guest wants clipboard data from the host.
    // The host should respond by calling spice_main_channel_clipboard_selection_notify
    // with the requested data. For now, we log and ignore - the Swift layer
    // should handle this by monitoring NSPasteboard and pushing updates.
    // TODO: Add a callback to notify Swift layer that guest wants clipboard data
}

// Called when guest releases clipboard
static void on_clipboard_release(SpiceMainChannel *channel, guint selection,
                                 gpointer user_data) {
    (void)channel;
    (void)selection;
    (void)user_data;
    // Guest released clipboard ownership - no action needed
}
#endif

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

#if __APPLE__
    SpiceMainChannel *main = stream->main_channel;
    if (!main) {
        pthread_mutex_unlock(&stream->send_mutex);
        return false;
    }

    guint spice_type = winrun_format_to_spice(clipboard->format);

    // First, grab the clipboard to notify guest we have new content
    guint32 types[] = { spice_type };
    spice_main_channel_clipboard_selection_grab(
        main,
        VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
        types,
        1
    );

    // Then send the actual data
    spice_main_channel_clipboard_selection_notify(
        main,
        VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
        spice_type,
        clipboard->data,
        clipboard->data_length
    );
#else
    (void)clipboard;
#endif

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

#if __APPLE__
    SpiceMainChannel *main = stream->main_channel;
    if (main) {
        guint spice_type = winrun_format_to_spice(format);
        spice_main_channel_clipboard_selection_request(
            main,
            VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
            spice_type
        );
    }
#else
    (void)format;
#endif

    pthread_mutex_unlock(&stream->send_mutex);
}

// MARK: - Drag and Drop

#if __APPLE__
// Context for async file transfer - must be kept alive until completion
typedef struct {
    GFile **sources;
    size_t file_count;
} file_transfer_context;

// Progress callback for file transfer
static void file_copy_progress_cb(goffset current, goffset total, gpointer user_data) {
    (void)user_data;
    // Progress reporting - could be extended to call back to Swift
    // For now, just log progress internally
    (void)current;
    (void)total;
}

// Completion callback for file transfer
static void file_copy_complete_cb(GObject *source, GAsyncResult *result, gpointer user_data) {
    file_transfer_context *ctx = (file_transfer_context *)user_data;
    SpiceMainChannel *channel = SPICE_MAIN_CHANNEL(source);
    GError *error = NULL;

    gboolean success = spice_main_channel_file_copy_finish(channel, result, &error);
    if (!success && error) {
        // Log error - could be extended to call back to Swift with error info
        g_error_free(error);
    }

    // Clean up GFile objects now that the transfer is complete
    if (ctx) {
        if (ctx->sources) {
            for (size_t i = 0; i < ctx->file_count && ctx->sources[i]; i++) {
                g_object_unref(ctx->sources[i]);
            }
            g_free(ctx->sources);
        }
        g_free(ctx);
    }
}
#endif

bool winrun_spice_send_drag_event(
    winrun_spice_stream_handle streamHandle,
    const winrun_drag_event *event
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream || !event) {
        return false;
    }

    pthread_mutex_lock(&stream->send_mutex);

#if __APPLE__
    SpiceMainChannel *main = stream->main_channel;
    if (!main) {
        pthread_mutex_unlock(&stream->send_mutex);
        return false;
    }

    // Only handle DROP events for file transfer
    // Enter/Move/Leave are for visual feedback which Spice handles via cursor
    if (event->event_type == WINRUN_DRAG_EVENT_DROP && event->files && event->file_count > 0) {
        // Create context to track resources for async operation
        file_transfer_context *ctx = g_new0(file_transfer_context, 1);
        if (!ctx) {
            pthread_mutex_unlock(&stream->send_mutex);
            return false;
        }

        // Create array of GFile pointers (NULL-terminated)
        ctx->sources = g_new0(GFile *, event->file_count + 1);
        ctx->file_count = event->file_count;
        if (!ctx->sources) {
            g_free(ctx);
            pthread_mutex_unlock(&stream->send_mutex);
            return false;
        }

        bool all_valid = true;
        for (size_t i = 0; i < event->file_count; i++) {
            if (event->files[i].host_path) {
                ctx->sources[i] = g_file_new_for_path(event->files[i].host_path);
                if (!ctx->sources[i]) {
                    all_valid = false;
                    break;
                }
            } else {
                all_valid = false;
                break;
            }
        }

        if (!all_valid) {
            // Clean up on failure
            for (size_t i = 0; i < event->file_count && ctx->sources[i]; i++) {
                g_object_unref(ctx->sources[i]);
            }
            g_free(ctx->sources);
            g_free(ctx);
            pthread_mutex_unlock(&stream->send_mutex);
            return false;
        }

        // Initiate async file copy to guest
        // The context (including GFile objects) will be freed in the completion callback
        spice_main_channel_file_copy_async(
            main,
            ctx->sources,
            G_FILE_COPY_NONE,
            NULL,  // GCancellable
            file_copy_progress_cb,
            NULL,  // progress user_data not needed
            file_copy_complete_cb,
            ctx    // Pass context for cleanup in completion callback
        );
    }
#else
    (void)event;
#endif

    pthread_mutex_unlock(&stream->send_mutex);
    return true;
}

// MARK: - Control Channel

void winrun_spice_set_control_callback(
    winrun_spice_stream_handle streamHandle,
    winrun_control_message_cb control_cb,
    void *user_data
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream) {
        return;
    }

    pthread_mutex_lock(&stream->send_mutex);
    stream->control_cb = control_cb;
    stream->control_user_data = user_data;
    pthread_mutex_unlock(&stream->send_mutex);
}

bool winrun_spice_send_control_message(
    winrun_spice_stream_handle streamHandle,
    const uint8_t *data,
    size_t length
) {
    winrun_spice_stream *stream = (winrun_spice_stream *)streamHandle;
    if (!stream || !data || length == 0) {
        return false;
    }

    pthread_mutex_lock(&stream->send_mutex);

#if __APPLE__
    SpicePortChannel *port = stream->control_channel;
    if (!port) {
        pthread_mutex_unlock(&stream->send_mutex);
        return false;
    }

    // Check if port is opened and ready
    gboolean is_opened = FALSE;
    g_object_get(port, "port-opened", &is_opened, NULL);
    if (!is_opened) {
        pthread_mutex_unlock(&stream->send_mutex);
        return false;
    }

    // Write data to port channel
    // spice_port_channel_write_async sends data to the guest
    spice_port_channel_write_async(
        port,
        data,
        length,
        NULL,  // GCancellable
        NULL,  // GAsyncReadyCallback (fire and forget for now)
        NULL   // user_data
    );
#else
    (void)data;
    (void)length;
#endif

    pthread_mutex_unlock(&stream->send_mutex);
    return true;
}
