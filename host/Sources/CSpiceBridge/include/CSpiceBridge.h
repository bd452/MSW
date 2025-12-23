#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *winrun_spice_stream_handle;

typedef struct {
    uint64_t window_id;
    double position_x;
    double position_y;
    double width;
    double height;
    double scale_factor;
    bool is_resizable;
    const char *title;
} winrun_spice_window_metadata;

typedef enum {
    WINRUN_SPICE_CLOSE_REASON_REMOTE = 0,
    WINRUN_SPICE_CLOSE_REASON_TRANSPORT = 1,
    WINRUN_SPICE_CLOSE_REASON_AUTHENTICATION = 2
} winrun_spice_close_reason;

typedef void (*winrun_spice_frame_cb)(const uint8_t *data, size_t length, void *user_data);
typedef void (*winrun_spice_metadata_cb)(const winrun_spice_window_metadata *metadata, void *user_data);
typedef void (*winrun_spice_closed_cb)(winrun_spice_close_reason reason, const char *message, void *user_data);

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
);

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
);

void winrun_spice_stream_close(winrun_spice_stream_handle stream);

// MARK: - Input Events

typedef enum {
    WINRUN_MOUSE_EVENT_MOVE = 0,
    WINRUN_MOUSE_EVENT_PRESS = 1,
    WINRUN_MOUSE_EVENT_RELEASE = 2,
    WINRUN_MOUSE_EVENT_SCROLL = 3
} winrun_mouse_event_type;

typedef enum {
    WINRUN_MOUSE_BUTTON_LEFT = 1,
    WINRUN_MOUSE_BUTTON_RIGHT = 2,
    WINRUN_MOUSE_BUTTON_MIDDLE = 4,
    WINRUN_MOUSE_BUTTON_EXTRA1 = 5,
    WINRUN_MOUSE_BUTTON_EXTRA2 = 6
} winrun_mouse_button;

typedef struct {
    uint64_t window_id;
    winrun_mouse_event_type event_type;
    winrun_mouse_button button;
    double x;
    double y;
    double scroll_delta_x;
    double scroll_delta_y;
    int32_t modifiers;
} winrun_mouse_event;

typedef enum {
    WINRUN_KEY_EVENT_DOWN = 0,
    WINRUN_KEY_EVENT_UP = 1
} winrun_key_event_type;

typedef struct {
    uint64_t window_id;
    winrun_key_event_type event_type;
    uint32_t key_code;
    uint32_t scan_code;
    bool is_extended_key;
    int32_t modifiers;
    const char *character;
} winrun_keyboard_event;

/// Send a mouse event to the guest
/// Returns true on success, false on failure
bool winrun_spice_send_mouse_event(
    winrun_spice_stream_handle stream,
    const winrun_mouse_event *event
);

/// Send a keyboard event to the guest
/// Returns true on success, false on failure
bool winrun_spice_send_keyboard_event(
    winrun_spice_stream_handle stream,
    const winrun_keyboard_event *event
);

// MARK: - Clipboard

typedef enum {
    WINRUN_CLIPBOARD_FORMAT_TEXT = 0,
    WINRUN_CLIPBOARD_FORMAT_RTF = 1,
    WINRUN_CLIPBOARD_FORMAT_HTML = 2,
    WINRUN_CLIPBOARD_FORMAT_PNG = 3,
    WINRUN_CLIPBOARD_FORMAT_TIFF = 4,
    WINRUN_CLIPBOARD_FORMAT_FILE_URL = 5
} winrun_clipboard_format;

typedef struct {
    winrun_clipboard_format format;
    const uint8_t *data;
    size_t data_length;
    uint64_t sequence_number;
} winrun_clipboard_data;

typedef void (*winrun_clipboard_cb)(const winrun_clipboard_data *clipboard, void *user_data);

/// Set clipboard content callback for receiving guest clipboard updates
void winrun_spice_set_clipboard_callback(
    winrun_spice_stream_handle stream,
    winrun_clipboard_cb clipboard_cb,
    void *user_data
);

/// Send clipboard data to the guest
/// Returns true on success, false on failure
bool winrun_spice_send_clipboard(
    winrun_spice_stream_handle stream,
    const winrun_clipboard_data *clipboard
);

/// Request clipboard content from the guest in the specified format
void winrun_spice_request_clipboard(
    winrun_spice_stream_handle stream,
    winrun_clipboard_format format
);

// MARK: - Drag and Drop

typedef enum {
    WINRUN_DRAG_OP_NONE = 0,
    WINRUN_DRAG_OP_COPY = 1,
    WINRUN_DRAG_OP_MOVE = 2,
    WINRUN_DRAG_OP_LINK = 3
} winrun_drag_operation;

typedef enum {
    WINRUN_DRAG_EVENT_ENTER = 0,
    WINRUN_DRAG_EVENT_MOVE = 1,
    WINRUN_DRAG_EVENT_LEAVE = 2,
    WINRUN_DRAG_EVENT_DROP = 3
} winrun_drag_event_type;

typedef struct {
    const char *host_path;
    const char *guest_path;
    uint64_t file_size;
    bool is_directory;
} winrun_dragged_file;

typedef struct {
    uint64_t window_id;
    winrun_drag_event_type event_type;
    double x;
    double y;
    const winrun_dragged_file *files;
    size_t file_count;
    winrun_drag_operation allowed_operations;
    winrun_drag_operation selected_operation;
} winrun_drag_event;

/// Send a drag and drop event to the guest
/// Returns true on success, false on failure
bool winrun_spice_send_drag_event(
    winrun_spice_stream_handle stream,
    const winrun_drag_event *event
);

// MARK: - Control Channel (Agent Messages)

/// Callback for receiving control messages from guest agent
typedef void (*winrun_control_message_cb)(
    const uint8_t *data,
    size_t length,
    void *user_data
);

/// Set control message callback for receiving guest agent messages
void winrun_spice_set_control_callback(
    winrun_spice_stream_handle stream,
    winrun_control_message_cb control_cb,
    void *user_data
);

/// Send a control message to the guest agent
/// Message format: [Type:1][Length:4][Payload:N] (binary envelope)
/// Returns true on success, false on failure
bool winrun_spice_send_control_message(
    winrun_spice_stream_handle stream,
    const uint8_t *data,
    size_t length
);

#ifdef __cplusplus
}
#endif
