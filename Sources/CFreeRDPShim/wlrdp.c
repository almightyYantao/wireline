// See include/wlrdp.h for the threading contract.
#include "wlrdp.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/constants.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/graphics.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/event.h>
#include <freerdp/error.h>
#include <freerdp/input.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>

typedef struct {
    rdpClientContext common;
    wlrdp_session *s;
} wlContext;

typedef struct {
    rdpPointer pointer;
    uint8_t *rgba;
} wlPointer;

struct wlrdp_session {
    wlrdp_callbacks cb;
    rdpContext *context;
    pthread_t thread;
    int thread_started;

    // Shadow framebuffer (see header): written at EndPaint, read by copy_dirty.
    pthread_mutex_t fb_lock;
    uint8_t *shadow;
    uint32_t sw, sh;
    size_t sstride;
    int dirty;
    int32_t dx0, dy0, dx1, dy1;
    atomic_int frame_pending;
    int painted;

    // Guards `connected` and the channel pointers against teardown.
    pthread_mutex_t send_lock;
    int connected;
    DispClientContext *disp;
    int disp_ready;
    CliprdrClientContext *cliprdr;

    pthread_mutex_t clip_lock;
    uint16_t *clip_local;     // UTF-16 + NUL, offered to the server
    size_t clip_local_units;  // without the NUL
    uint32_t clip_requested;

    char *auth_user, *auth_pass, *auth_domain;
    int auth_set;
};

static wlrdp_session *session_of(rdpContext *context) {
    return context ? ((wlContext *)context)->s : NULL;
}

// MARK: - Clipboard (cliprdr): plain text both ways

static UINT clip_send_format_list(wlrdp_session *s, CliprdrClientContext *cliprdr) {
    pthread_mutex_lock(&s->clip_lock);
    const int have = s->clip_local != NULL;
    pthread_mutex_unlock(&s->clip_lock);
    CLIPRDR_FORMAT format = { .formatId = CF_UNICODETEXT, .formatName = NULL };
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = have ? 1 : 0;
    list.formats = have ? &format : NULL;
    return cliprdr->ClientFormatList(cliprdr, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    wlrdp_session *s = cliprdr->custom;
    if (!s) return ERROR_INVALID_PARAMETER;
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = 12;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
    if (rc != CHANNEL_RC_OK) return rc;
    rc = clip_send_format_list(s, cliprdr);
    if (s->cb.on_clipboard_ready) s->cb.on_clipboard_ready(s->cb.user);
    return rc;
}

static UINT clip_server_caps(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *caps) {
    (void)cliprdr; (void)caps;
    return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list) {
    wlrdp_session *s = cliprdr->custom;
    if (!s) return ERROR_INVALID_PARAMETER;
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
    if (rc != CHANNEL_RC_OK) return rc;
    int hasText = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT) hasText = 1;
    }
    if (!hasText) return CHANNEL_RC_OK;
    // Text only, fetched right away: it's small, and the Mac pasteboard has
    // no lazy provider we could hand the request to from this thread.
    CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = CF_UNICODETEXT;
    s->clip_requested = CF_UNICODETEXT;
    return cliprdr->ClientFormatDataRequest(cliprdr, &request);
}

static UINT clip_server_format_list_response(CliprdrClientContext *cliprdr,
                                             const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)cliprdr; (void)response;
    return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext *cliprdr,
                                     const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    wlrdp_session *s = cliprdr->custom;
    if (!s) return ERROR_INVALID_PARAMETER;
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    uint16_t *copy = NULL;
    size_t bytes = 0;
    pthread_mutex_lock(&s->clip_lock);
    if (request->requestedFormatId == CF_UNICODETEXT && s->clip_local) {
        bytes = (s->clip_local_units + 1) * sizeof(uint16_t);
        copy = malloc(bytes);
        if (copy) memcpy(copy, s->clip_local, bytes);
    }
    pthread_mutex_unlock(&s->clip_lock);
    if (copy) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)bytes;
        response.requestedFormatData = (const BYTE *)copy;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(copy);
    return rc;
}

static UINT clip_server_data_response(CliprdrClientContext *cliprdr,
                                      const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    wlrdp_session *s = cliprdr->custom;
    if (!s) return ERROR_INVALID_PARAMETER;
    if (response->common.msgFlags & CB_RESPONSE_FAIL) return CHANNEL_RC_OK;
    if (s->clip_requested != CF_UNICODETEXT || !response->requestedFormatData) return CHANNEL_RC_OK;
    const uint16_t *text = (const uint16_t *)response->requestedFormatData;
    size_t units = response->common.dataLen / sizeof(uint16_t);
    while (units > 0 && text[units - 1] == 0) units--;
    for (size_t i = 0; i < units; i++) {
        if (text[i] == 0) { units = i; break; }
    }
    if (s->cb.on_remote_clipboard) s->cb.on_remote_clipboard(s->cb.user, text, units);
    return CHANNEL_RC_OK;
}

static UINT clip_noop_lock(CliprdrClientContext *c, const CLIPRDR_LOCK_CLIPBOARD_DATA *d) {
    (void)c; (void)d; return CHANNEL_RC_OK;
}
static UINT clip_noop_unlock(CliprdrClientContext *c, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *d) {
    (void)c; (void)d; return CHANNEL_RC_OK;
}
static UINT clip_noop_file_request(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_REQUEST *r) {
    (void)c; (void)r; return CHANNEL_RC_OK;
}
static UINT clip_noop_file_response(CliprdrClientContext *c, const CLIPRDR_FILE_CONTENTS_RESPONSE *r) {
    (void)c; (void)r; return CHANNEL_RC_OK;
}

static void clip_init(wlrdp_session *s, CliprdrClientContext *cliprdr) {
    cliprdr->custom = s;
    cliprdr->MonitorReady = clip_monitor_ready;
    cliprdr->ServerCapabilities = clip_server_caps;
    cliprdr->ServerFormatList = clip_server_format_list;
    cliprdr->ServerFormatListResponse = clip_server_format_list_response;
    cliprdr->ServerLockClipboardData = clip_noop_lock;
    cliprdr->ServerUnlockClipboardData = clip_noop_unlock;
    cliprdr->ServerFormatDataRequest = clip_server_data_request;
    cliprdr->ServerFormatDataResponse = clip_server_data_response;
    cliprdr->ServerFileContentsRequest = clip_noop_file_request;
    cliprdr->ServerFileContentsResponse = clip_noop_file_response;
    pthread_mutex_lock(&s->send_lock);
    s->cliprdr = cliprdr;
    pthread_mutex_unlock(&s->send_lock);
}

// MARK: - Display control (disp)

static UINT disp_caps(DispClientContext *disp, UINT32 maxMonitors, UINT32 areaA, UINT32 areaB) {
    (void)maxMonitors; (void)areaA; (void)areaB;
    wlrdp_session *s = disp->custom;
    if (!s) return CHANNEL_RC_OK;
    pthread_mutex_lock(&s->send_lock);
    s->disp_ready = 1;
    pthread_mutex_unlock(&s->send_lock);
    if (s->cb.on_resize_ready) s->cb.on_resize_ready(s->cb.user);
    return CHANNEL_RC_OK;
}

// MARK: - Channel plumbing

static void on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    wlrdp_session *s = session_of(context);
    if (!s) return;
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clip_init(s, (CliprdrClientContext *)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext *disp = e->pInterface;
        disp->custom = s;
        disp->DisplayControlCaps = disp_caps;
        pthread_mutex_lock(&s->send_lock);
        s->disp = disp;
        pthread_mutex_unlock(&s->send_lock);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(context, e);
    }
}

static void on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    wlrdp_session *s = session_of(context);
    if (!s) return;
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&s->send_lock);
        s->cliprdr = NULL;
        pthread_mutex_unlock(&s->send_lock);
        ((CliprdrClientContext *)e->pInterface)->custom = NULL;
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&s->send_lock);
        s->disp = NULL;
        s->disp_ready = 0;
        pthread_mutex_unlock(&s->send_lock);
        ((DispClientContext *)e->pInterface)->custom = NULL;
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(context, e);
    }
}

// MARK: - Painting

/// Make the shadow match the GDI size; must hold fb_lock. Returns 1 if it changed.
static int shadow_fit(wlrdp_session *s, rdpGdi *gdi) {
    const uint32_t w = (uint32_t)gdi->width, h = (uint32_t)gdi->height;
    if (s->shadow && s->sw == w && s->sh == h) return 0;
    free(s->shadow);
    s->sstride = (size_t)w * 4;
    s->shadow = calloc(1, s->sstride * h);
    s->sw = s->shadow ? w : 0;
    s->sh = s->shadow ? h : 0;
    return 1;
}

static void shadow_copy(wlrdp_session *s, rdpGdi *gdi, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > (int32_t)s->sw) w = (int32_t)s->sw - x;
    if (y + h > (int32_t)s->sh) h = (int32_t)s->sh - y;
    if (w <= 0 || h <= 0 || !gdi->primary_buffer) return;
    for (int32_t row = y; row < y + h; row++) {
        memcpy(s->shadow + (size_t)row * s->sstride + (size_t)x * 4,
               gdi->primary_buffer + (size_t)row * gdi->stride + (size_t)x * 4, (size_t)w * 4);
    }
    if (!s->dirty) {
        s->dirty = 1;
        s->dx0 = x; s->dy0 = y; s->dx1 = x + w; s->dy1 = y + h;
    } else {
        if (x < s->dx0) s->dx0 = x;
        if (y < s->dy0) s->dy0 = y;
        if (x + w > s->dx1) s->dx1 = x + w;
        if (y + h > s->dy1) s->dy1 = y + h;
    }
}

static void notify_frame(wlrdp_session *s) {
    if (!s->painted) {
        s->painted = 1;
        if (s->cb.on_stage) s->cb.on_stage(s->cb.user, WLRDP_STAGE_RUNNING);
    }
    if (atomic_exchange(&s->frame_pending, 1) == 0 && s->cb.on_frame) s->cb.on_frame(s->cb.user);
}

static BOOL wl_begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc->hwnd) return TRUE;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
    return TRUE;
}

static BOOL wl_end_paint(rdpContext *context) {
    wlrdp_session *s = session_of(context);
    rdpGdi *gdi = context->gdi;
    if (!s || !gdi || !gdi->primary || !gdi->primary->hdc->hwnd) return TRUE;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (hwnd->invalid->null) return TRUE;
    int resized;
    pthread_mutex_lock(&s->fb_lock);
    resized = shadow_fit(s, gdi);
    if (resized) shadow_copy(s, gdi, 0, 0, (int32_t)s->sw, (int32_t)s->sh);
    else shadow_copy(s, gdi, hwnd->invalid->x, hwnd->invalid->y, hwnd->invalid->w, hwnd->invalid->h);
    const uint32_t w = s->sw, h = s->sh;
    pthread_mutex_unlock(&s->fb_lock);
    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
    if (resized && s->cb.on_desktop_size) s->cb.on_desktop_size(s->cb.user, w, h);
    notify_frame(s);
    return TRUE;
}

static BOOL wl_desktop_resize(rdpContext *context) {
    wlrdp_session *s = session_of(context);
    rdpGdi *gdi = context->gdi;
    if (!s || !gdi) return TRUE;
    const UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(gdi, w, h)) return FALSE;
    pthread_mutex_lock(&s->fb_lock);
    shadow_fit(s, gdi);
    shadow_copy(s, gdi, 0, 0, (int32_t)s->sw, (int32_t)s->sh);
    const uint32_t sw = s->sw, sh = s->sh;
    pthread_mutex_unlock(&s->fb_lock);
    if (s->cb.on_desktop_size) s->cb.on_desktop_size(s->cb.user, sw, sh);
    notify_frame(s);
    return TRUE;
}

// MARK: - Pointer

static BOOL wl_pointer_new(rdpContext *context, rdpPointer *pointer) {
    wlPointer *p = (wlPointer *)pointer;
    if (pointer->width == 0 || pointer->height == 0) { p->rgba = NULL; return TRUE; }
    p->rgba = malloc((size_t)pointer->width * pointer->height * 4);
    if (!p->rgba) return FALSE;
    if (!freerdp_image_copy_from_pointer_data(p->rgba, PIXEL_FORMAT_RGBA32, 0, 0, 0, pointer->width,
                                              pointer->height, pointer->xorMaskData,
                                              pointer->lengthXorMask, pointer->andMaskData,
                                              pointer->lengthAndMask, pointer->xorBpp,
                                              context->gdi ? &context->gdi->palette : NULL)) {
        free(p->rgba);
        p->rgba = NULL;
        return FALSE;
    }
    return TRUE;
}

static void wl_pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    wlPointer *p = (wlPointer *)pointer;
    free(p->rgba);
    p->rgba = NULL;
}

static BOOL wl_pointer_set(rdpContext *context, rdpPointer *pointer) {
    wlrdp_session *s = session_of(context);
    wlPointer *p = (wlPointer *)pointer;
    if (!s || !s->cb.on_pointer) return TRUE;
    if (!p->rgba) s->cb.on_pointer(s->cb.user, WLRDP_POINTER_HIDDEN, NULL, 0, 0, 0, 0);
    else s->cb.on_pointer(s->cb.user, WLRDP_POINTER_IMAGE, p->rgba, pointer->width, pointer->height,
                          pointer->xPos, pointer->yPos);
    return TRUE;
}

static BOOL wl_pointer_set_null(rdpContext *context) {
    wlrdp_session *s = session_of(context);
    if (s && s->cb.on_pointer) s->cb.on_pointer(s->cb.user, WLRDP_POINTER_HIDDEN, NULL, 0, 0, 0, 0);
    return TRUE;
}

static BOOL wl_pointer_set_default(rdpContext *context) {
    wlrdp_session *s = session_of(context);
    if (s && s->cb.on_pointer) s->cb.on_pointer(s->cb.user, WLRDP_POINTER_DEFAULT, NULL, 0, 0, 0, 0);
    return TRUE;
}

static BOOL wl_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    (void)context; (void)x; (void)y;
    return TRUE;   // never warp the Mac's pointer
}

// MARK: - Connection callbacks

static BOOL wl_pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    wlrdp_session *s = session_of(context);
    rdpSettings *settings = context->settings;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
        return FALSE;
    if (PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected) < 0)
        return FALSE;
    if (s && s->cb.on_stage) s->cb.on_stage(s->cb.user, WLRDP_STAGE_CONNECTING);
    return TRUE;
}

static BOOL wl_post_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    wlrdp_session *s = session_of(context);
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    context->update->BeginPaint = wl_begin_paint;
    context->update->EndPaint = wl_end_paint;
    context->update->DesktopResize = wl_desktop_resize;

    wlPointer prototype = { 0 };
    prototype.pointer.size = sizeof(wlPointer);
    prototype.pointer.New = wl_pointer_new;
    prototype.pointer.Free = wl_pointer_free;
    prototype.pointer.Set = wl_pointer_set;
    prototype.pointer.SetNull = wl_pointer_set_null;
    prototype.pointer.SetDefault = wl_pointer_set_default;
    prototype.pointer.SetPosition = wl_pointer_set_position;
    graphics_register_pointer(context->graphics, &prototype.pointer);

    if (s) {
        pthread_mutex_lock(&s->fb_lock);
        shadow_fit(s, context->gdi);
        const uint32_t w = s->sw, h = s->sh;
        pthread_mutex_unlock(&s->fb_lock);
        pthread_mutex_lock(&s->send_lock);
        s->connected = 1;
        pthread_mutex_unlock(&s->send_lock);
        if (s->cb.on_stage) s->cb.on_stage(s->cb.user, WLRDP_STAGE_SESSION);
        if (s->cb.on_desktop_size) s->cb.on_desktop_size(s->cb.user, w, h);
    }
    return TRUE;
}

static void wl_post_disconnect(freerdp *instance) {
    rdpContext *context = instance->context;
    wlrdp_session *s = session_of(context);
    if (s) {
        pthread_mutex_lock(&s->send_lock);
        s->connected = 0;
        pthread_mutex_unlock(&s->send_lock);
    }
    PubSub_UnsubscribeChannelConnected(context->pubSub, on_channel_connected);
    PubSub_UnsubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
    gdi_free(instance);
}

static int wl_verify_x509(freerdp *instance, const BYTE *data, size_t length, const char *hostname,
                          UINT16 port, DWORD flags) {
    wlrdp_session *s = session_of(instance->context);
    if (!s) return 0;
    if (s->cb.on_stage) s->cb.on_stage(s->cb.user, WLRDP_STAGE_SECURITY);
    if (!s->cb.on_verify_certificate) return 0;
    return s->cb.on_verify_certificate(s->cb.user, hostname, port, data, length, flags) ? 1 : 0;
}

static char *dup_or_null(const char *v) { return (v && *v) ? strdup(v) : NULL; }

static BOOL wl_authenticate(freerdp *instance, char **username, char **password, char **domain,
                            rdp_auth_reason reason) {
    wlrdp_session *s = session_of(instance->context);
    if (!s) return FALSE;
    wlrdp_auth_reason r;
    switch (reason) {
    case AUTH_NLA: r = WLRDP_AUTH_NLA; break;
    case AUTH_TLS: r = WLRDP_AUTH_TLS; break;
    case AUTH_RDP: r = WLRDP_AUTH_RDP; break;
    default: return FALSE;   // smartcard, gateway: not supported
    }
    if (s->cb.on_stage) s->cb.on_stage(s->cb.user, WLRDP_STAGE_SECURITY);
    // TLS / RDP security with everything filled in: nothing to ask.
    if (r != WLRDP_AUTH_NLA && *username && *password) return TRUE;
    if (r == WLRDP_AUTH_NLA && *username && *password) return TRUE;
    if (!s->cb.on_authenticate) return FALSE;
    s->auth_set = 0;
    if (!s->cb.on_authenticate(s->cb.user, r) || !s->auth_set) return FALSE;
    free(*username); free(*password); free(*domain);
    *username = dup_or_null(s->auth_user);
    *password = dup_or_null(s->auth_pass);
    *domain = dup_or_null(s->auth_domain);
    return *username != NULL;
}

static int wl_logon_error_info(freerdp *instance, UINT32 data, UINT32 type) {
    (void)instance; (void)data; (void)type;
    return 1;
}

static BOOL wl_client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = wl_pre_connect;
    instance->PostConnect = wl_post_connect;
    instance->PostDisconnect = wl_post_disconnect;
    instance->VerifyX509Certificate = wl_verify_x509;
    instance->AuthenticateEx = wl_authenticate;
    instance->LogonErrorInfo = wl_logon_error_info;
    return TRUE;
}

static void wl_client_free(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }
static int wl_client_start(rdpContext *context) { (void)context; return 0; }
static int wl_client_stop(rdpContext *context) { (void)context; return 0; }

// MARK: - Session

static void *thread_proc(void *arg) {
    wlrdp_session *s = arg;
    rdpContext *context = s->context;
    freerdp *instance = context->instance;

    if (freerdp_client_start(context) == 0 && freerdp_connect(instance)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
        while (!freerdp_shall_disconnect_context(context)) {
            const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
            if (count == 0) break;
            const DWORD status = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
            if (status == WAIT_FAILED) break;
            if (!freerdp_check_event_handles(context)) break;
        }
    }
    const UINT32 error = freerdp_get_last_error(context);
    const UINT32 errinfo = freerdp_error_info(instance);
    freerdp_disconnect(instance);
    freerdp_client_stop(context);
    pthread_mutex_lock(&s->send_lock);
    s->connected = 0;
    s->cliprdr = NULL;
    s->disp = NULL;
    s->disp_ready = 0;
    pthread_mutex_unlock(&s->send_lock);
    if (s->cb.on_disconnected) {
        const char *ename = freerdp_get_last_error_name(error);
        const char *iname = freerdp_get_error_info_name(errinfo);
        s->cb.on_disconnected(s->cb.user, error, ename ? ename : "", errinfo, iname ? iname : "");
    }
    return NULL;
}

static BOOL set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *v) {
    return (v && *v) ? freerdp_settings_set_string(settings, key, v) : TRUE;
}

static pthread_once_t log_once = PTHREAD_ONCE_INIT;

static void quiet_logs(void) {
    // FreeRDP logs to stdout at INFO/WARN by default; keep errors only unless
    // the user asked for more (WLOG_LEVEL=DEBUG etc. still works).
    if (!getenv("WLOG_LEVEL")) WLog_SetLogLevel(WLog_GetRoot(), WLOG_ERROR);
}

wlrdp_session *wlrdp_create(const wlrdp_config *config, const wlrdp_callbacks *callbacks) {
    pthread_once(&log_once, quiet_logs);
    wlrdp_session *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->cb = *callbacks;
    pthread_mutex_init(&s->fb_lock, NULL);
    pthread_mutex_init(&s->send_lock, NULL);
    pthread_mutex_init(&s->clip_lock, NULL);

    RDP_CLIENT_ENTRY_POINTS entry = { 0 };
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entry.ContextSize = sizeof(wlContext);
    entry.ClientNew = wl_client_new;
    entry.ClientFree = wl_client_free;
    entry.ClientStart = wl_client_start;
    entry.ClientStop = wl_client_stop;
    s->context = freerdp_client_context_new(&entry);
    if (!s->context) { wlrdp_destroy(s); return NULL; }
    ((wlContext *)s->context)->s = s;

    rdpSettings *st = s->context->settings;
    const uint32_t w = config->width >= 200 ? config->width & ~1u : 1024;
    const uint32_t h = config->height >= 200 ? config->height : 768;
    BOOL ok = freerdp_settings_set_string(st, FreeRDP_ServerHostname, config->host) &&
        freerdp_settings_set_uint32(st, FreeRDP_ServerPort, config->port ? config->port : 3389) &&
        set_string(st, FreeRDP_Username, config->username) &&
        set_string(st, FreeRDP_Password, config->password) &&
        set_string(st, FreeRDP_Domain, config->domain) &&
        set_string(st, FreeRDP_ClientHostname, config->client_name) &&
        freerdp_settings_set_uint32(st, FreeRDP_DesktopWidth, w) &&
        freerdp_settings_set_uint32(st, FreeRDP_DesktopHeight, h) &&
        freerdp_settings_set_uint32(st, FreeRDP_ColorDepth, 32) &&
        // Certificates are Wireline's business (trust-on-first-use per host).
        freerdp_settings_set_bool(st, FreeRDP_ExternalCertificateManagement, TRUE) &&
        freerdp_settings_set_bool(st, FreeRDP_SoftwareGdi, TRUE) &&
        freerdp_settings_set_bool(st, FreeRDP_UnicodeInput, TRUE) &&
        freerdp_settings_set_bool(st, FreeRDP_NetworkAutoDetect, TRUE) &&
        freerdp_settings_set_uint32(st, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT) &&
        freerdp_settings_set_bool(st, FreeRDP_AutoReconnectionEnabled, FALSE) &&
        freerdp_settings_set_bool(st, FreeRDP_SupportDisplayControl, TRUE) &&
        freerdp_settings_set_bool(st, FreeRDP_DynamicResolutionUpdate, TRUE) &&
        freerdp_settings_set_bool(st, FreeRDP_RedirectClipboard, config->clipboard ? TRUE : FALSE) &&
        freerdp_settings_set_bool(st, FreeRDP_AudioPlayback, config->audio ? TRUE : FALSE) &&
        freerdp_settings_set_bool(st, FreeRDP_SupportGraphicsPipeline, config->gfx ? TRUE : FALSE) &&
        // Built without FFmpeg/OpenH264: never advertise H.264.
        freerdp_settings_set_bool(st, FreeRDP_GfxH264, FALSE) &&
        freerdp_settings_set_bool(st, FreeRDP_GfxAVC444, FALSE) &&
        freerdp_settings_set_bool(st, FreeRDP_GfxAVC444v2, FALSE) &&
        freerdp_settings_set_bool(st, FreeRDP_GfxProgressive, TRUE) &&
        freerdp_settings_set_bool(st, FreeRDP_RemoteFxCodec, TRUE);
    if (ok && config->desktop_scale >= 100 && config->desktop_scale <= 500) {
        ok = freerdp_settings_set_uint32(st, FreeRDP_DesktopScaleFactor, config->desktop_scale) &&
             freerdp_settings_set_uint32(st, FreeRDP_DeviceScaleFactor,
                                         config->device_scale ? config->device_scale : 100);
    }
    if (ok && config->audio) {
        // Without an explicit backend rdpsnd picks its "fake" (silent) one.
        const char *rdpsnd[] = { "rdpsnd", "sys:mac" };
        ok = freerdp_client_add_static_channel(st, ARRAYSIZE(rdpsnd), rdpsnd) &&
             freerdp_client_add_dynamic_channel(st, ARRAYSIZE(rdpsnd), rdpsnd);
    }
    if (!ok) { wlrdp_destroy(s); return NULL; }
    return s;
}

void wlrdp_set_user(wlrdp_session *s, void *user) {
    if (s) s->cb.user = user;
}

int wlrdp_start(wlrdp_session *s) {
    if (!s || s->thread_started) return -1;
    if (pthread_create(&s->thread, NULL, thread_proc, s) != 0) return -1;
    s->thread_started = 1;
    return 0;
}

void wlrdp_stop(wlrdp_session *s) {
    if (s && s->context) freerdp_abort_connect_context(s->context);
}

void wlrdp_destroy(wlrdp_session *s) {
    if (!s) return;
    if (s->thread_started) {
        wlrdp_stop(s);
        pthread_join(s->thread, NULL);
        s->thread_started = 0;
    }
    if (s->context) freerdp_client_context_free(s->context);
    s->context = NULL;
    free(s->shadow);
    free(s->clip_local);
    free(s->auth_user); free(s->auth_pass); free(s->auth_domain);
    pthread_mutex_destroy(&s->fb_lock);
    pthread_mutex_destroy(&s->send_lock);
    pthread_mutex_destroy(&s->clip_lock);
    free(s);
}

void wlrdp_set_credentials(wlrdp_session *s, const char *username, const char *password,
                           const char *domain) {
    if (!s) return;
    free(s->auth_user); free(s->auth_pass); free(s->auth_domain);
    s->auth_user = dup_or_null(username);
    s->auth_pass = dup_or_null(password);
    s->auth_domain = dup_or_null(domain);
    s->auth_set = 1;
}

void wlrdp_desktop_size(wlrdp_session *s, uint32_t *width, uint32_t *height) {
    pthread_mutex_lock(&s->fb_lock);
    *width = s->sw;
    *height = s->sh;
    pthread_mutex_unlock(&s->fb_lock);
}

int wlrdp_copy_dirty(wlrdp_session *s, uint8_t *dst, size_t dst_stride, uint32_t dst_width,
                     uint32_t dst_height, int full, wlrdp_rect *out) {
    pthread_mutex_lock(&s->fb_lock);
    if (!s->shadow || dst_width != s->sw || dst_height != s->sh) {
        pthread_mutex_unlock(&s->fb_lock);
        return -1;
    }
    int32_t x0 = s->dx0, y0 = s->dy0, x1 = s->dx1, y1 = s->dy1;
    if (full) { x0 = 0; y0 = 0; x1 = (int32_t)s->sw; y1 = (int32_t)s->sh; }
    else if (!s->dirty) {
        atomic_store(&s->frame_pending, 0);
        pthread_mutex_unlock(&s->fb_lock);
        return 0;
    }
    const size_t bytes = (size_t)(x1 - x0) * 4;
    for (int32_t row = y0; row < y1; row++) {
        memcpy(dst + (size_t)row * dst_stride + (size_t)x0 * 4,
               s->shadow + (size_t)row * s->sstride + (size_t)x0 * 4, bytes);
    }
    s->dirty = 0;
    atomic_store(&s->frame_pending, 0);
    pthread_mutex_unlock(&s->fb_lock);
    if (out) { out->x = x0; out->y = y0; out->w = (uint32_t)(x1 - x0); out->h = (uint32_t)(y1 - y0); }
    return 1;
}

// MARK: - Input

#define WITH_INPUT(s, body)                                                     \
    do {                                                                        \
        pthread_mutex_lock(&(s)->send_lock);                                    \
        if ((s)->connected && (s)->context && (s)->context->input) {            \
            rdpInput *input = (s)->context->input;                              \
            body;                                                               \
        }                                                                       \
        pthread_mutex_unlock(&(s)->send_lock);                                  \
    } while (0)

void wlrdp_send_key(wlrdp_session *s, uint8_t scancode, int extended, int down) {
    const UINT16 flags = (UINT16)((down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE) |
                                  (extended ? KBD_FLAGS_EXTENDED : 0));
    WITH_INPUT(s, (void)freerdp_input_send_keyboard_event(input, flags, scancode));
}

void wlrdp_send_unicode(wlrdp_session *s, uint16_t code_unit, int down) {
    const UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    WITH_INPUT(s, (void)freerdp_input_send_unicode_keyboard_event(input, flags, code_unit));
}

void wlrdp_send_mouse_move(wlrdp_session *s, uint16_t x, uint16_t y) {
    WITH_INPUT(s, (void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y));
}

void wlrdp_send_mouse_button(wlrdp_session *s, int button, int down, uint16_t x, uint16_t y) {
    switch (button) {
    case 0: case 1: case 2: {
        UINT16 flags = button == 0 ? PTR_FLAGS_BUTTON1 : button == 1 ? PTR_FLAGS_BUTTON2 : PTR_FLAGS_BUTTON3;
        if (down) flags |= PTR_FLAGS_DOWN;
        WITH_INPUT(s, (void)freerdp_input_send_mouse_event(input, flags, x, y));
        break;
    }
    case 3: case 4: {
        UINT16 flags = button == 3 ? PTR_XFLAGS_BUTTON1 : PTR_XFLAGS_BUTTON2;
        if (down) flags |= PTR_XFLAGS_DOWN;
        WITH_INPUT(s, (void)freerdp_input_send_extended_mouse_event(input, flags, x, y));
        break;
    }
    default: break;
    }
}

void wlrdp_send_wheel(wlrdp_session *s, int vertical, int delta, uint16_t x, uint16_t y) {
    if (delta == 0) return;
    // Wire format: a 9-bit two's-complement rotation (0x100 = negative).
    // Positive vertical = away from the user (scroll up); positive horizontal = right.
    int magnitude = delta < 0 ? -delta : delta;
    if (magnitude > 0xFF) magnitude = 0xFF;
    UINT16 flags = vertical ? PTR_FLAGS_WHEEL : PTR_FLAGS_HWHEEL;
    if (delta < 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE | (UINT16)((0x100 - magnitude) & 0xFF);
    else flags |= (UINT16)magnitude;
    WITH_INPUT(s, (void)freerdp_input_send_mouse_event(input, flags, x, y));
}

void wlrdp_send_focus_in(wlrdp_session *s, int caps_lock) {
    const UINT16 toggles = caps_lock ? KBD_SYNC_CAPS_LOCK : 0;
    WITH_INPUT(s, (void)freerdp_input_send_focus_in_event(input, toggles));
}

// MARK: - Channels

int wlrdp_resize(wlrdp_session *s, uint32_t width, uint32_t height, uint32_t desktop_scale,
                 uint32_t device_scale) {
    width &= ~1u;   // MS-RDPEDISP: even width
    if (width < DISPLAY_CONTROL_MIN_MONITOR_WIDTH) width = DISPLAY_CONTROL_MIN_MONITOR_WIDTH;
    if (height < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT) height = DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
    if (width > DISPLAY_CONTROL_MAX_MONITOR_WIDTH) width = DISPLAY_CONTROL_MAX_MONITOR_WIDTH;
    if (height > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT) height = DISPLAY_CONTROL_MAX_MONITOR_HEIGHT;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = width;
    layout.Height = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = (desktop_scale >= 100 && desktop_scale <= 500) ? desktop_scale : 100;
    layout.DeviceScaleFactor = device_scale ? device_scale : 100;
    // ~96 dpi physical size (mm); Windows only uses it for its DPI guess.
    layout.PhysicalWidth = width * 254 / 960;
    layout.PhysicalHeight = height * 254 / 960;
    if (layout.PhysicalWidth < 10) layout.PhysicalWidth = 10;
    if (layout.PhysicalHeight < 10) layout.PhysicalHeight = 10;
    int sent = 0;
    pthread_mutex_lock(&s->send_lock);
    if (s->connected && s->disp && s->disp_ready) {
        sent = s->disp->SendMonitorLayout(s->disp, 1, &layout) == CHANNEL_RC_OK;
    }
    pthread_mutex_unlock(&s->send_lock);
    return sent;
}

int wlrdp_set_local_clipboard(wlrdp_session *s, const uint16_t *utf16, size_t units) {
    uint16_t *copy = NULL;
    if (utf16 && units > 0) {
        copy = malloc((units + 1) * sizeof(uint16_t));
        if (!copy) return 0;
        memcpy(copy, utf16, units * sizeof(uint16_t));
        copy[units] = 0;
    }
    pthread_mutex_lock(&s->clip_lock);
    free(s->clip_local);
    s->clip_local = copy;
    s->clip_local_units = copy ? units : 0;
    pthread_mutex_unlock(&s->clip_lock);
    int sent = 0;
    pthread_mutex_lock(&s->send_lock);
    if (s->connected && s->cliprdr) sent = clip_send_format_list(s, s->cliprdr) == CHANNEL_RC_OK;
    pthread_mutex_unlock(&s->send_lock);
    return sent;
}
