#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

struct cm_server;
/* All callbacks run on the caller's event-loop thread. Pointers are borrowed
 * for the duration of the callback; image bytes are native-endian ARGB32. */
struct cm_callbacks {
    void (*view_added)(void *ctx, const char *id);
    void (*view_ready)(void *ctx, const char *id);
    void (*view_lost)(void *ctx, const char *id, const char *error);
    void (*frame)(void *ctx, const char *id, const void *pixels, int width, int height,
                  int stride, bool alpha, int logical_width, int logical_height);
    void (*cursor)(void *ctx, const char *id, const void *pixels, int width, int height,
                   int stride, int logical_width, int logical_height, int hotspot_x, int hotspot_y);
    /* NULL cursor pixels mean the client explicitly requested a hidden cursor. */
    void (*selection)(void *ctx, uint64_t generation, const char *const *mimes, size_t count);
    /* send_selection transfers fd ownership to the callback. */
    void (*send_selection)(void *ctx, uint64_t token, const char *mime, int fd);
    void (*selection_released)(void *ctx, uint64_t token);
};
struct cm_server *cm_server_create(const char *socket_name, const struct cm_callbacks *callbacks,
                                  void *ctx, char *error, size_t error_capacity);
void cm_server_destroy(struct cm_server *server);
int cm_server_fd(struct cm_server *server);
void cm_server_dispatch(struct cm_server *server);
void cm_server_expect(struct cm_server *server, const char *id, int64_t pid);
void cm_server_forget(struct cm_server *server, const char *id);
void cm_server_configure(struct cm_server *server, const char *id, int width, int height);
void cm_server_select(struct cm_server *server, const char *id, bool exposed);
void cm_server_focus(struct cm_server *server, const char *id, bool focused);
void cm_server_output(struct cm_server *server, int logical_width, int logical_height, int scale);
/* visible=true acknowledges the selected surface after Qt presents it;
 * visible=false services hidden surfaces (or every surface if not exposed). */
void cm_server_frames(struct cm_server *server, bool visible);
void cm_server_keymap(struct cm_server *server, const char *xkb_keymap);
void cm_server_key(struct cm_server *server, uint32_t evdev_key, bool pressed, bool deliver, uint32_t time);
void cm_server_modifiers(struct cm_server *server, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group);
void cm_server_pointer(struct cm_server *server, const char *id, double x, double y, uint32_t time);
void cm_server_pointer_leave(struct cm_server *server);
void cm_server_button(struct cm_server *server, uint32_t linux_button, bool pressed, uint32_t time);
void cm_server_scroll(struct cm_server *server, double horizontal, double vertical, int discrete_h, int discrete_v, uint32_t time);
void cm_server_text(struct cm_server *server, const char *preedit, int cursor_begin, int cursor_end, const char *commit);
/* Copies MIME names. token is returned in send_selection/released callbacks. */
void cm_server_offer_selection(struct cm_server *server, const char *const *mimes, size_t count, uint64_t token);
/* Always consumes fd, including when generation has been superseded. */
bool cm_server_receive_selection(struct cm_server *server, uint64_t generation, const char *mime, int fd);

#ifdef __cplusplus
}
#endif
