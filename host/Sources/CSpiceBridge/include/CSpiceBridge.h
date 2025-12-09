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

#ifdef __cplusplus
}
#endif
