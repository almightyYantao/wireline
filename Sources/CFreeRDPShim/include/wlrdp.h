// Wireline's thin C layer over FreeRDP 3.
//
// FreeRDP's client API is callback- and macro-heavy and wants its own event
// loop thread; Swift only sees this small, opaque surface:
//
//   * one `wlrdp_session` per connection, with its own pthread running
//     freerdp_connect + the event loop;
//   * every callback is invoked on that RDP thread (never the main thread) —
//     RDPConnection hops to main itself;
//   * the GDI framebuffer is mirrored into a shadow buffer at each EndPaint,
//     so the main thread can copy dirty pixels without racing FreeRDP's
//     decoders or a resize;
//   * input / clipboard / resize calls are safe from any thread.
//
// Nothing here includes FreeRDP headers, so Swift never has to build the
// (large) FreeRDP clang module.
#ifndef WLRDP_H
#define WLRDP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wlrdp_session wlrdp_session;

/// Connection progress, reported through `on_stage`.
typedef enum {
    WLRDP_STAGE_CONNECTING = 1,   ///< PreConnect: TCP + protocol negotiation starting
    WLRDP_STAGE_SECURITY = 2,     ///< TLS is up: certificate check / NLA (CredSSP)
    WLRDP_STAGE_SESSION = 3,      ///< PostConnect: logged on, capabilities exchanged
    WLRDP_STAGE_RUNNING = 4,      ///< first frame painted
} wlrdp_stage;

typedef enum {
    WLRDP_POINTER_IMAGE = 0,      ///< `rgba` holds the cursor (non-premultiplied RGBA)
    WLRDP_POINTER_HIDDEN = 1,
    WLRDP_POINTER_DEFAULT = 2,
} wlrdp_pointer_kind;

typedef enum {
    WLRDP_AUTH_NLA = 0,
    WLRDP_AUTH_TLS = 1,
    WLRDP_AUTH_RDP = 2,
    WLRDP_AUTH_OTHER = 3,
} wlrdp_auth_reason;

typedef struct {
    int32_t x, y;
    uint32_t w, h;
} wlrdp_rect;

typedef struct {
    void *user;
    void (*on_stage)(void *user, wlrdp_stage stage);
    /// Pixels changed; call `wlrdp_copy_dirty`. Not called again until you do.
    void (*on_frame)(void *user);
    /// The remote desktop size changed (also fires once after connect).
    void (*on_desktop_size)(void *user, uint32_t width, uint32_t height);
    /// Server certificate (DER-or-PEM bytes as FreeRDP hands them, usually PEM).
    /// `host`/`port` are what FreeRDP dialled (127.0.0.1 for a tunnel).
    /// Return 1 to accept, 0 to reject. Blocks the RDP thread — fine.
    int (*on_verify_certificate)(void *user, const char *host, uint16_t port,
                                 const uint8_t *data, size_t length, uint32_t flags);
    /// Credentials are missing (or were rejected for TLS/RDP auth). Call
    /// `wlrdp_set_credentials` before returning 1; return 0 to cancel.
    int (*on_authenticate)(void *user, wlrdp_auth_reason reason);
    void (*on_pointer)(void *user, wlrdp_pointer_kind kind, const uint8_t *rgba,
                       uint32_t width, uint32_t height, uint32_t hot_x, uint32_t hot_y);
    /// The server's clipboard now holds text (CF_UNICODETEXT, UTF-16LE, no NUL).
    void (*on_remote_clipboard)(void *user, const uint16_t *utf16, size_t units);
    /// The clipboard channel is ready: announce the local clipboard now.
    void (*on_clipboard_ready)(void *user);
    /// The display-control channel is ready: `wlrdp_resize` works from now on.
    void (*on_resize_ready)(void *user);
    /// The session ended (connect failure, logoff, network, `wlrdp_stop`).
    /// `error` is freerdp_get_last_error, `errinfo` the server's disconnect reason.
    void (*on_disconnected)(void *user, uint32_t error, const char *error_name,
                            uint32_t errinfo, const char *errinfo_name);
} wlrdp_callbacks;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;   ///< may be NULL
    const char *password;   ///< may be NULL
    const char *domain;     ///< may be NULL
    const char *client_name;
    uint32_t width, height;           ///< initial desktop size, device pixels
    uint32_t desktop_scale;           ///< 100…500 (%), 0 = 100
    uint32_t device_scale;            ///< 100, 140 or 180, 0 = 100
    int clipboard;                    ///< cliprdr text sync
    int audio;                        ///< rdpsnd to the Mac's output
    int gfx;                          ///< graphics pipeline (RemoteFX/progressive)
} wlrdp_config;

wlrdp_session *wlrdp_create(const wlrdp_config *config, const wlrdp_callbacks *callbacks);
/// Replace `callbacks->user` (before `wlrdp_start`).
void wlrdp_set_user(wlrdp_session *s, void *user);
/// Spawn the RDP thread and start connecting. 0 on success.
int wlrdp_start(wlrdp_session *s);
/// Ask the session to end (non-blocking; `on_disconnected` follows).
void wlrdp_stop(wlrdp_session *s);
/// Stop, join the RDP thread and free everything. Blocks until the thread is
/// gone; don't call it on the main thread while a callback may be waiting on it.
void wlrdp_destroy(wlrdp_session *s);

/// From inside `on_authenticate`.
void wlrdp_set_credentials(wlrdp_session *s, const char *username, const char *password,
                           const char *domain);

// --- framebuffer ------------------------------------------------------------

/// Current desktop size in pixels (0×0 before the first frame).
void wlrdp_desktop_size(wlrdp_session *s, uint32_t *width, uint32_t *height);
/// Copy the pixels changed since the last call (BGRA, 32bpp) into `dst`
/// (`dst_width`×`dst_height`, `dst_stride` bytes per row). `full` copies all.
/// Returns 1 and the copied rect; 0 if nothing changed; -1 if `dst` doesn't
/// match the desktop size (re-query `wlrdp_desktop_size`).
int wlrdp_copy_dirty(wlrdp_session *s, uint8_t *dst, size_t dst_stride, uint32_t dst_width,
                     uint32_t dst_height, int full, wlrdp_rect *out);

// --- input (any thread) -----------------------------------------------------

/// `scancode` is a set-1 make code; `extended` for E0-prefixed keys.
void wlrdp_send_key(wlrdp_session *s, uint8_t scancode, int extended, int down);
/// One UTF-16 code unit, as a key down or up.
void wlrdp_send_unicode(wlrdp_session *s, uint16_t code_unit, int down);
void wlrdp_send_mouse_move(wlrdp_session *s, uint16_t x, uint16_t y);
/// button: 0 left, 1 right, 2 middle, 3 back (X1), 4 forward (X2).
void wlrdp_send_mouse_button(wlrdp_session *s, int button, int down, uint16_t x, uint16_t y);
/// One wheel event; `delta` in wheel units (120 = one notch), clamped to ±255.
void wlrdp_send_wheel(wlrdp_session *s, int vertical, int delta, uint16_t x, uint16_t y);
/// Focus came back: sync lock-key state and release everything held.
void wlrdp_send_focus_in(wlrdp_session *s, int caps_lock);

// --- channels ---------------------------------------------------------------

/// Ask the server to change the desktop size (display-control channel).
/// Returns 1 if the request was sent.
int wlrdp_resize(wlrdp_session *s, uint32_t width, uint32_t height, uint32_t desktop_scale,
                 uint32_t device_scale);
/// Offer local text to the server's clipboard (UTF-16, no NUL needed).
/// Returns 1 if the channel is up and the offer went out.
int wlrdp_set_local_clipboard(wlrdp_session *s, const uint16_t *utf16, size_t units);

#ifdef __cplusplus
}
#endif

#endif
