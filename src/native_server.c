#define _POSIX_C_SOURCE 200809L
#ifndef WLR_USE_UNSTABLE
#define WLR_USE_UNSTABLE
#endif
#include "native_server.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/render/allocator.h>
#include <wlr/render/pixman.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_text_input_v3.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <xkbcommon/xkbcommon.h>

#define APP_PREFIX "io.niay.cinmux.session."
#define PENDING_LIMIT 32
#define CLIENT_DEADLINE_MS 5000

struct cm_view;
struct cm_expected {
    struct wl_list link;
    char *id;
    int64_t pid;
    int width, height;
    struct cm_view *view;
};

struct cm_client {
    struct wl_list link;
    struct cm_server *server;
    struct wl_client *client;
    struct wl_listener destroy;
    struct wl_event_source *deadline;
    bool pending;
};

struct cm_view {
    struct wl_list link;
    struct cm_server *server;
    struct cm_expected *expected;
    struct wlr_xdg_toplevel *toplevel;
    bool announced, ready, failed, rejected;
    struct wl_listener destroy, commit, map, unmap, app_id;
    struct wl_listener maximize, fullscreen;
    struct wlr_surface *cursor_surface;
    bool cursor_set;
    int hotspot_x, hotspot_y;
    struct wl_listener cursor_commit, cursor_destroy;
};

struct cm_decoration {
    struct wl_list link;
    struct wlr_xdg_toplevel_decoration_v1 *decoration;
    struct wl_listener request, destroy, commit;
};

struct cm_text_input {
    struct wl_list link;
    struct wlr_text_input_v3 *input;
    struct wl_listener destroy;
};

struct cm_selection {
    struct wlr_data_source source;
    struct cm_server *server;
    uint64_t token;
};

struct cm_server {
    struct cm_callbacks callbacks;
    void *ctx;
    struct wl_display *display;
    struct wl_event_loop *loop;
    struct wlr_backend *backend;
    struct wlr_renderer *renderer;
    struct wlr_allocator *allocator;
    struct wlr_output *output;
    struct wlr_seat *seat;
    struct wlr_xdg_shell *shell;
    struct wlr_xdg_decoration_manager_v1 *decorations;
    struct wlr_text_input_manager_v3 *text_manager;
    struct wlr_keyboard keyboard;
    struct xkb_context *xkb_context;
    bool keyboard_initialized, destroying, exposed, wants_focus;
    bool host_selection;
    bool host_keymap;
    uint64_t selection_generation;
    int output_width, output_height, scale;
    unsigned pending_clients;
    struct cm_expected *selected;
    struct wl_list expected, views, clients, decoration_list, text_inputs;
    struct wl_listener client_created, new_toplevel, new_popup;
    struct wl_listener new_decoration, new_text_input;
    struct wl_listener request_cursor, request_selection, set_selection;
};

static void listener_init(struct wl_listener *listener) {
    wl_list_init(&listener->link);
}

static void listener_remove(struct wl_listener *listener) {
    wl_list_remove(&listener->link);
    wl_list_init(&listener->link);
}

static void listen(struct wl_signal *signal, struct wl_listener *listener,
                   wl_notify_func_t notify) {
    listener->notify = notify;
    wl_signal_add(signal, listener);
}

static struct cm_expected *find_expected(struct cm_server *server, const char *id) {
    if (!id || !*id) return NULL;
    struct cm_expected *expected;
    wl_list_for_each(expected, &server->expected, link) {
        if (strcmp(expected->id, id) == 0) return expected;
    }
    return NULL;
}

static struct cm_view *selected_view(struct cm_server *server) {
    return server->selected ? server->selected->view : NULL;
}

static struct wlr_surface *view_surface(struct cm_view *view) {
    return view->toplevel->base->surface;
}

static struct cm_client *find_client(struct cm_server *server, struct wl_client *client) {
    struct cm_client *record;
    wl_list_for_each(record, &server->clients, link) {
        if (record->client == client) return record;
    }
    return NULL;
}

static void synchronize_text_focus(struct cm_server *server) {
    struct wlr_surface *surface = server->seat->keyboard_state.focused_surface;
    struct cm_text_input *record;
    wl_list_for_each(record, &server->text_inputs, link) {
        struct wlr_text_input_v3 *input = record->input;
        struct wlr_surface *target = surface &&
            wl_resource_get_client(input->resource) == wl_resource_get_client(surface->resource)
            ? surface : NULL;
        if (input->focused_surface == target) continue;
        if (input->focused_surface) wlr_text_input_v3_send_leave(input);
        if (target) wlr_text_input_v3_send_enter(input, target);
    }
}

static void update_focus(struct cm_server *server) {
    struct cm_view *selected = selected_view(server);
    struct wlr_surface *surface = selected && !selected->failed &&
        view_surface(selected)->mapped && server->exposed && server->wants_focus
        ? view_surface(selected) : NULL;
    struct cm_view *view;
    wl_list_for_each(view, &server->views, link) {
        if (!view->expected || !view->toplevel->base->initialized) continue;
        bool active = view_surface(view) == surface;
        if (view->toplevel->scheduled.activated != active)
            wlr_xdg_toplevel_set_activated(view->toplevel, active);
    }
    if (server->seat->keyboard_state.focused_surface != surface) {
        if (surface) {
            /* Application shortcuts are never included in a later enter event. */
            wlr_seat_keyboard_notify_enter(server->seat, surface, NULL, 0,
                                          &server->keyboard.modifiers);
        } else {
            wlr_seat_keyboard_notify_clear_focus(server->seat);
        }
    }
    synchronize_text_focus(server);
}

static void surface_output(struct wlr_surface *surface, int sx, int sy, void *data) {
    (void)sx;
    (void)sy;
    struct cm_server *server = data;
    wlr_surface_send_enter(surface, server->output);
    wlr_surface_set_preferred_buffer_scale(surface, server->scale);
}

static void fail_view(struct cm_view *view, const char *message) {
    if (!view->expected || view->failed || view->server->destroying) return;
    view->failed = true;
    if (selected_view(view->server) == view) cm_server_pointer_leave(view->server);
    update_focus(view->server);
    if (view->server->callbacks.view_lost)
        view->server->callbacks.view_lost(view->server->ctx, view->expected->id, message);
}

static pixman_image_t *surface_image(struct wlr_surface *surface) {
    struct wlr_texture *texture = wlr_surface_get_texture(surface);
    if (!texture || !wlr_texture_is_pixman(texture)) return NULL;
    pixman_image_t *image = wlr_pixman_texture_get_image(texture);
    if (!image) return NULL;
    pixman_format_code_t format = pixman_image_get_format(image);
    if (format != PIXMAN_a8r8g8b8 && format != PIXMAN_x8r8g8b8) return NULL;
    return image;
}

static struct wlr_buffer *begin_pixels(struct wlr_surface *surface, void **pixels, size_t *stride) {
    struct wlr_buffer *buffer = surface->buffer ? surface->buffer->source : NULL;
    if (!buffer) return NULL;
    uint32_t format;
    wlr_buffer_lock(buffer);
    if (!wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
                                         pixels, &format, stride)) {
        wlr_buffer_unlock(buffer);
        return NULL;
    }
    if (*stride > INT_MAX) {
        wlr_buffer_end_data_ptr_access(buffer);
        wlr_buffer_unlock(buffer);
        return NULL;
    }
    return buffer;
}

static void end_pixels(struct wlr_buffer *buffer) {
    wlr_buffer_end_data_ptr_access(buffer);
    wlr_buffer_unlock(buffer);
}

static void emit_frame(struct cm_view *view) {
    struct cm_server *server = view->server;
    struct wlr_surface *surface = view_surface(view);
    if (!view->expected || view->failed || !surface->mapped ||
        selected_view(server) != view || !server->exposed || !server->callbacks.frame) return;
    pixman_image_t *image = surface_image(surface);
    if (!image) {
        fail_view(view, "Foot's shared-memory buffer could not be imported as ARGB32 by wlroots/pixman.");
        return;
    }
    void *pixels;
    size_t stride;
    struct wlr_buffer *buffer = begin_pixels(surface, &pixels, &stride);
    if (!buffer) {
        fail_view(view, "Foot's shared-memory buffer is no longer readable.");
        return;
    }
    /* Access protects wl_shm against SIGBUS and refreshes a resized pool mapping.
     * Pixman's image describes the immutable texture; its old data pointer may
     * predate a wl_shm_pool.resize, so borrow the current source mapping. */
    server->callbacks.frame(server->ctx, view->expected->id, pixels,
        pixman_image_get_width(image), pixman_image_get_height(image), (int)stride,
        pixman_image_get_format(image) == PIXMAN_a8r8g8b8,
        surface->current.width, surface->current.height);
    end_pixels(buffer);
}

static void emit_cursor(struct cm_view *view) {
    struct cm_server *server = view->server;
    if (!view->expected || !view->cursor_set || selected_view(server) != view ||
        !server->exposed || !server->callbacks.cursor) return;
    struct wlr_surface *surface = view->cursor_surface;
    if (!surface || !wlr_surface_state_has_buffer(&surface->current)) {
        server->callbacks.cursor(server->ctx, view->expected->id, NULL, 0, 0, 0, 0, 0,
                                 view->hotspot_x, view->hotspot_y);
        return;
    }
    pixman_image_t *image = surface_image(surface);
    if (!image) {
        fail_view(view, "Foot's cursor buffer could not be imported by wlroots/pixman.");
        return;
    }
    void *pixels;
    size_t stride;
    struct wlr_buffer *buffer = begin_pixels(surface, &pixels, &stride);
    if (!buffer) {
        fail_view(view, "Foot's shared-memory cursor buffer is no longer readable.");
        return;
    }
    server->callbacks.cursor(server->ctx, view->expected->id, pixels,
        pixman_image_get_width(image), pixman_image_get_height(image), (int)stride,
        surface->current.width, surface->current.height, view->hotspot_x, view->hotspot_y);
    end_pixels(buffer);
}

static void cursor_committed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, cursor_commit);
    view->hotspot_x -= view->cursor_surface->current.dx;
    view->hotspot_y -= view->cursor_surface->current.dy;
    emit_cursor(view);
}

static void cursor_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, cursor_destroy);
    listener_remove(&view->cursor_commit);
    listener_remove(&view->cursor_destroy);
    view->cursor_surface = NULL;
    emit_cursor(view);
}

static void request_cursor(struct wl_listener *listener, void *data) {
    struct cm_server *server = wl_container_of(listener, server, request_cursor);
    struct wlr_seat_pointer_request_set_cursor_event *event = data;
    struct cm_view *view = selected_view(server);
    if (!view || !server->exposed || event->seat_client != server->seat->pointer_state.focused_client ||
        event->seat_client->client != wl_resource_get_client(view_surface(view)->resource)) return;
    listener_remove(&view->cursor_commit);
    listener_remove(&view->cursor_destroy);
    view->cursor_set = true;
    view->cursor_surface = event->surface;
    view->hotspot_x = event->hotspot_x;
    view->hotspot_y = event->hotspot_y;
    if (event->surface) {
        listen(&event->surface->events.commit, &view->cursor_commit, cursor_committed);
        listen(&event->surface->events.destroy, &view->cursor_destroy, cursor_destroyed);
        surface_output(event->surface, 0, 0, server);
    }
    emit_cursor(view);
}

static int client_expired(void *data) {
    struct cm_client *record = data;
    wl_client_destroy(record->client);
    return 0;
}

static void arm_client_deadline(struct cm_client *record) {
    if (!record || record->pending) return;
    if (record->server->pending_clients >= PENDING_LIMIT) {
        wl_client_post_implementation_error(record->client, "Cinmux pending client limit exceeded");
        return;
    }
    record->pending = true;
    ++record->server->pending_clients;
    record->deadline = wl_event_loop_add_timer(record->server->loop, client_expired, record);
    if (!record->deadline || wl_event_source_timer_update(record->deadline, CLIENT_DEADLINE_MS) < 0)
        wl_client_post_no_memory(record->client);
}

static void client_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_client *record = wl_container_of(listener, record, destroy);
    if (record->deadline) wl_event_source_remove(record->deadline);
    if (record->pending) --record->server->pending_clients;
    listener_remove(&record->destroy);
    wl_list_remove(&record->link);
    free(record);
}

static void client_created(struct wl_listener *listener, void *data) {
    struct cm_server *server = wl_container_of(listener, server, client_created);
    struct wl_client *client = data;
    if (server->pending_clients >= PENDING_LIMIT) {
        wl_client_post_implementation_error(client, "Cinmux pending client limit exceeded");
        return;
    }
    struct cm_client *record = calloc(1, sizeof(*record));
    if (!record) {
        wl_client_post_no_memory(client);
        return;
    }
    record->server = server;
    record->client = client;
    wl_list_insert(&server->clients, &record->link);
    record->destroy.notify = client_destroyed;
    wl_client_add_destroy_listener(client, &record->destroy);
    arm_client_deadline(record);
}

static void configure_view(struct cm_view *view) {
    if (!view->expected || !view->toplevel->base->initialized) return;
    struct cm_expected *expected = view->expected;
    wlr_xdg_toplevel_set_size(view->toplevel, expected->width, expected->height);
    wlr_xdg_toplevel_set_bounds(view->toplevel, expected->width, expected->height);
    wlr_xdg_toplevel_set_wm_capabilities(view->toplevel, 0);
    wlr_xdg_toplevel_set_activated(view->toplevel,
        view == selected_view(view->server) && view->server->exposed && view->server->wants_focus);
}

static void reject_view(struct cm_view *view) {
    if (view->rejected) return;
    view->rejected = true;
    wlr_xdg_toplevel_send_close(view->toplevel);
}

static void ready_view(struct cm_view *view) {
    if (!view->expected || view->ready || view->failed || !view_surface(view)->mapped) return;
    if (!surface_image(view_surface(view))) {
        fail_view(view, "Foot's shared-memory buffer could not be imported by wlroots/pixman.");
        return;
    }
    view->ready = true;
    update_focus(view->server);
    if (view->server->callbacks.view_ready)
        view->server->callbacks.view_ready(view->server->ctx, view->expected->id);
    emit_frame(view);
}

static bool match_view(struct cm_view *view) {
    if (view->expected) return true;
    if (view->rejected) return false;
    const char *app_id = view->toplevel->app_id;
    if (!app_id || !*app_id) return false;
    if (strncmp(app_id, APP_PREFIX, sizeof(APP_PREFIX) - 1) != 0) {
        reject_view(view);
        return false;
    }
    struct cm_expected *expected = find_expected(view->server, app_id + sizeof(APP_PREFIX) - 1);
    if (!expected) return false; /* QProcess::started can arrive after app-id. */
    pid_t pid;
    uid_t uid;
    gid_t gid;
    struct wl_client *client = wl_resource_get_client(view_surface(view)->resource);
    wl_client_get_credentials(client, &pid, &uid, &gid);
    if ((int64_t)pid != expected->pid || uid != getuid() || expected->view) {
        reject_view(view);
        return false;
    }
    view->expected = expected;
    expected->view = view;
    struct cm_client *record = find_client(view->server, client);
    if (record && record->pending) {
        record->pending = false;
        --view->server->pending_clients;
        if (record->deadline) {
            wl_event_source_remove(record->deadline);
            record->deadline = NULL;
        }
    }
    view->announced = true;
    if (view->server->callbacks.view_added)
        view->server->callbacks.view_added(view->server->ctx, expected->id);
    if (!view->expected) return false;
    wlr_surface_for_each_surface(view_surface(view), surface_output, view->server);
    configure_view(view);
    ready_view(view);
    return true;
}

static void view_mapped(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, map);
    if (!match_view(view) || view->failed) return;
    wlr_surface_for_each_surface(view_surface(view), surface_output, view->server);
    ready_view(view);
}

static void view_unmapped(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, unmap);
    fail_view(view, "Foot's terminal surface was unmapped. Reconnect to the running session.");
}

static void view_committed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, commit);
    if (!match_view(view)) return;
    struct wlr_surface *surface = view_surface(view);
    if (view->toplevel->base->initial_commit) configure_view(view);
    if (wlr_surface_state_has_buffer(&surface->current) && !wlr_surface_get_texture(surface)) {
        fail_view(view, "wlroots could not import Foot's committed shared-memory buffer.");
        return;
    }
    wlr_surface_for_each_surface(surface, surface_output, view->server);
    if (surface->current.committed & (WLR_SURFACE_STATE_BUFFER |
        WLR_SURFACE_STATE_SURFACE_DAMAGE | WLR_SURFACE_STATE_BUFFER_DAMAGE |
        WLR_SURFACE_STATE_SCALE | WLR_SURFACE_STATE_VIEWPORT)) emit_frame(view);
}

static void view_app_id(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, app_id);
    if (view->expected) {
        const char *app_id = view->toplevel->app_id;
        if (!app_id || strncmp(app_id, APP_PREFIX, sizeof(APP_PREFIX) - 1) != 0 ||
            strcmp(app_id + sizeof(APP_PREFIX) - 1, view->expected->id) != 0) {
            fail_view(view, "Foot changed its terminal session identity.");
            reject_view(view);
        }
        return;
    }
    match_view(view);
}

static void view_maximize(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, maximize);
    if (view->toplevel->base->initialized)
        wlr_xdg_toplevel_set_maximized(view->toplevel, false);
}

static void view_fullscreen(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, fullscreen);
    if (view->toplevel->base->initialized)
        wlr_xdg_toplevel_set_fullscreen(view->toplevel, false);
}

static void view_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_view *view = wl_container_of(listener, view, destroy);
    struct cm_server *server = view->server;
    struct cm_expected *expected = view->expected;
    if (expected) expected->view = NULL;
    listener_remove(&view->destroy);
    listener_remove(&view->commit);
    listener_remove(&view->map);
    listener_remove(&view->unmap);
    listener_remove(&view->app_id);
    listener_remove(&view->maximize);
    listener_remove(&view->fullscreen);
    listener_remove(&view->cursor_commit);
    listener_remove(&view->cursor_destroy);
    wl_list_remove(&view->link);
    if (!server->destroying) {
        arm_client_deadline(find_client(server, wl_resource_get_client(view->toplevel->resource)));
        update_focus(server);
        if (expected && view->announced && !view->failed && server->callbacks.view_lost)
            server->callbacks.view_lost(server->ctx, expected->id,
                "Foot disconnected. Reconnect to the running session.");
    }
    free(view);
}

static void new_toplevel(struct wl_listener *listener, void *data) {
    struct cm_server *server = wl_container_of(listener, server, new_toplevel);
    struct wlr_xdg_toplevel *toplevel = data;
    struct wl_client *client = wl_resource_get_client(toplevel->resource);
    struct cm_view *other;
    wl_list_for_each(other, &server->views, link) {
        if (wl_resource_get_client(other->toplevel->resource) == client) {
            wlr_xdg_toplevel_send_close(toplevel);
            return;
        }
    }
    struct cm_view *view = calloc(1, sizeof(*view));
    if (!view) {
        wl_client_post_no_memory(client);
        return;
    }
    view->server = server;
    view->toplevel = toplevel;
    listener_init(&view->cursor_commit);
    listener_init(&view->cursor_destroy);
    wl_list_insert(&server->views, &view->link);
    listen(&toplevel->events.destroy, &view->destroy, view_destroyed);
    listen(&toplevel->events.set_app_id, &view->app_id, view_app_id);
    listen(&toplevel->events.request_maximize, &view->maximize, view_maximize);
    listen(&toplevel->events.request_fullscreen, &view->fullscreen, view_fullscreen);
    struct wlr_surface *surface = view_surface(view);
    listen(&surface->events.commit, &view->commit, view_committed);
    listen(&surface->events.map, &view->map, view_mapped);
    listen(&surface->events.unmap, &view->unmap, view_unmapped);
    match_view(view);
}

static void new_popup(struct wl_listener *listener, void *data) {
    (void)listener;
    wlr_xdg_popup_destroy(data);
}

static void decoration_requested(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_decoration *record = wl_container_of(listener, record, request);
    if (!record->decoration->toplevel->base->initialized) return;
    wlr_xdg_toplevel_decoration_v1_set_mode(record->decoration,
        WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

static void decoration_committed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_decoration *record = wl_container_of(listener, record, commit);
    if (record->decoration->toplevel->base->initial_commit)
        decoration_requested(&record->request, NULL);
}

static void decoration_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_decoration *record = wl_container_of(listener, record, destroy);
    listener_remove(&record->request);
    listener_remove(&record->destroy);
    listener_remove(&record->commit);
    wl_list_remove(&record->link);
    free(record);
}

static void new_decoration(struct wl_listener *listener, void *data) {
    struct cm_server *server = wl_container_of(listener, server, new_decoration);
    struct wlr_xdg_toplevel_decoration_v1 *decoration = data;
    struct cm_decoration *record = calloc(1, sizeof(*record));
    if (!record) {
        wl_resource_post_no_memory(decoration->resource);
        return;
    }
    record->decoration = decoration;
    wl_list_insert(&server->decoration_list, &record->link);
    listen(&decoration->events.request_mode, &record->request, decoration_requested);
    listen(&decoration->events.destroy, &record->destroy, decoration_destroyed);
    listen(&decoration->toplevel->base->surface->events.commit, &record->commit, decoration_committed);
    decoration_requested(&record->request, NULL);
}

static void text_input_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_text_input *record = wl_container_of(listener, record, destroy);
    listener_remove(&record->destroy);
    wl_list_remove(&record->link);
    free(record);
}

static void new_text_input(struct wl_listener *listener, void *data) {
    struct cm_server *server = wl_container_of(listener, server, new_text_input);
    struct wlr_text_input_v3 *input = data;
    if (input->seat != server->seat) return;
    struct cm_text_input *record = calloc(1, sizeof(*record));
    if (!record) {
        wl_resource_post_no_memory(input->resource);
        return;
    }
    record->input = input;
    wl_list_insert(&server->text_inputs, &record->link);
    listen(&input->events.destroy, &record->destroy, text_input_destroyed);
    synchronize_text_focus(server);
}

static void selection_send(struct wlr_data_source *source, const char *mime, int32_t fd) {
    struct cm_selection *selection = wl_container_of(source, selection, source);
    struct cm_server *server = selection->server;
    if (!server->destroying && server->callbacks.send_selection)
        server->callbacks.send_selection(server->ctx, selection->token, mime, fd);
    else close(fd);
}

static void selection_destroy(struct wlr_data_source *source) {
    struct cm_selection *selection = wl_container_of(source, selection, source);
    if (selection->server->callbacks.selection_released)
        selection->server->callbacks.selection_released(selection->server->ctx, selection->token);
    free(selection);
}

static const struct wlr_data_source_impl selection_impl = {
    .send = selection_send,
    .destroy = selection_destroy,
};

static void selection_changed(struct wl_listener *listener, void *data) {
    (void)data;
    struct cm_server *server = wl_container_of(listener, server, set_selection);
    ++server->selection_generation;
    if (!server->selection_generation) ++server->selection_generation;
    if (server->destroying || server->host_selection || !server->callbacks.selection) return;
    struct wlr_data_source *source = server->seat->selection_source;
    const char *const *mimes = source ? source->mime_types.data : NULL;
    size_t count = source ? source->mime_types.size / sizeof(char *) : 0;
    server->callbacks.selection(server->ctx, server->selection_generation, mimes, count);
}

static void request_selection(struct wl_listener *listener, void *data) {
    struct cm_server *server = wl_container_of(listener, server, request_selection);
    struct wlr_seat_request_set_selection_event *event = data;
    server->host_selection = false;
    wlr_seat_set_selection(server->seat, event->source, event->serial);
}

static const struct wlr_keyboard_impl keyboard_impl = { .name = "cinmux-host-keyboard" };

struct cm_server *cm_server_create(const char *socket_name, const struct cm_callbacks *callbacks,
                                  void *ctx, char *error, size_t error_capacity) {
    const char *failure = "Cannot allocate the native Wayland compositor.";
    struct cm_server *server = calloc(1, sizeof(*server));
    if (!server) goto failed;
    if (callbacks) server->callbacks = *callbacks;
    server->ctx = ctx;
    server->scale = 1;
    server->output_width = 800;
    server->output_height = 600;
    wl_list_init(&server->expected);
    wl_list_init(&server->views);
    wl_list_init(&server->clients);
    wl_list_init(&server->decoration_list);
    wl_list_init(&server->text_inputs);
    listener_init(&server->client_created);
    listener_init(&server->new_toplevel);
    listener_init(&server->new_popup);
    listener_init(&server->new_decoration);
    listener_init(&server->new_text_input);
    listener_init(&server->request_cursor);
    listener_init(&server->request_selection);
    listener_init(&server->set_selection);
    server->display = wl_display_create();
    if (!server->display) goto failed;
    server->loop = wl_display_get_event_loop(server->display);
    server->backend = wlr_headless_backend_create(server->loop);
    if (!server->backend) {
        failure = "Cannot create the wlroots headless backend.";
        goto failed;
    }
    server->renderer = wlr_pixman_renderer_create();
    if (!server->renderer) {
        failure = "Cannot create the wlroots pixman shared-memory renderer.";
        goto failed;
    }
    if (!wlr_renderer_init_wl_shm(server->renderer, server->display)) {
        failure = "Cannot initialize the wlroots shared-memory protocol.";
        goto failed;
    }
    if (!wlr_compositor_create(server->display, 6, server->renderer) ||
        !wlr_subcompositor_create(server->display) ||
        !wlr_data_device_manager_create(server->display) ||
        !wlr_viewporter_create(server->display)) {
        failure = "Cannot create the required Wayland compositor protocols.";
        goto failed;
    }
    server->seat = wlr_seat_create(server->display, "cinmux");
    server->shell = wlr_xdg_shell_create(server->display, 7);
    server->decorations = wlr_xdg_decoration_manager_v1_create(server->display);
    server->text_manager = wlr_text_input_manager_v3_create(server->display);
    if (!server->seat || !server->shell || !server->decorations || !server->text_manager) {
        failure = "Cannot create the native seat, XDG shell, decorations, or text-input protocol.";
        goto failed;
    }
    server->xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!server->xkb_context) {
        failure = "Cannot initialize the keyboard layout context.";
        goto failed;
    }
    wlr_keyboard_init(&server->keyboard, &keyboard_impl, "Cinmux host keyboard");
    server->keyboard_initialized = true;
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(server->xkb_context, NULL,
                                                        XKB_KEYMAP_COMPILE_NO_FLAGS);
    bool keyboard_ok = keymap && wlr_keyboard_set_keymap(&server->keyboard, keymap);
    if (keymap) xkb_keymap_unref(keymap);
    if (!keyboard_ok) {
        failure = "Cannot initialize the default keyboard layout.";
        goto failed;
    }
    wlr_keyboard_set_repeat_info(&server->keyboard, 25, 600);
    wlr_seat_set_keyboard(server->seat, &server->keyboard);
    wlr_seat_set_capabilities(server->seat, WL_SEAT_CAPABILITY_KEYBOARD | WL_SEAT_CAPABILITY_POINTER);
    server->allocator = wlr_allocator_autocreate(server->backend, server->renderer);
    server->output = wlr_headless_add_output(server->backend, 800, 600);
    if (!server->allocator || !server->output ||
        !wlr_output_init_render(server->output, server->allocator, server->renderer)) {
        failure = "Cannot initialize the native headless output.";
        goto failed;
    }
    wlr_output_set_name(server->output, "Cinmux");
    wlr_output_set_description(server->output, "Cinmux embedded terminal output");
    if (!wlr_backend_start(server->backend)) {
        failure = "Cannot start the native headless backend.";
        goto failed;
    }
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    wlr_output_state_set_custom_mode(&state, 800, 600, 60000);
    wlr_output_state_set_scale(&state, 1);
    bool output_ok = wlr_output_commit_state(server->output, &state);
    wlr_output_state_finish(&state);
    if (!output_ok) {
        failure = "Cannot configure the native headless output.";
        goto failed;
    }
    wlr_output_create_global(server->output, server->display);
    if (!server->output->global) {
        failure = "Cannot publish the native Wayland output.";
        goto failed;
    }
    listen(&server->shell->events.new_toplevel, &server->new_toplevel, new_toplevel);
    listen(&server->shell->events.new_popup, &server->new_popup, new_popup);
    listen(&server->decorations->events.new_toplevel_decoration, &server->new_decoration, new_decoration);
    listen(&server->text_manager->events.new_text_input, &server->new_text_input, new_text_input);
    listen(&server->seat->events.request_set_cursor, &server->request_cursor, request_cursor);
    listen(&server->seat->events.request_set_selection, &server->request_selection, request_selection);
    listen(&server->seat->events.set_selection, &server->set_selection, selection_changed);
    server->client_created.notify = client_created;
    wl_display_add_client_created_listener(server->display, &server->client_created);
    if (!socket_name || !*socket_name || wl_display_add_socket(server->display, socket_name) < 0) {
        if (error && error_capacity)
            snprintf(error, error_capacity, "Cannot create the private Wayland socket: %s", strerror(errno));
        cm_server_destroy(server);
        return NULL;
    }
    if (error && error_capacity) error[0] = '\0';
    return server;
failed:
    if (error && error_capacity) snprintf(error, error_capacity, "%s", failure);
    if (server) cm_server_destroy(server);
    return NULL;
}

void cm_server_destroy(struct cm_server *server) {
    if (!server) return;
    server->destroying = true;
    listener_remove(&server->client_created);
    listener_remove(&server->new_toplevel);
    listener_remove(&server->new_popup);
    listener_remove(&server->new_decoration);
    listener_remove(&server->new_text_input);
    listener_remove(&server->request_cursor);
    listener_remove(&server->request_selection);
    listener_remove(&server->set_selection);
    if (server->display) wl_display_destroy_clients(server->display);
    if (server->seat) wlr_seat_set_selection(server->seat, NULL, wl_display_next_serial(server->display));
    if (server->keyboard_initialized) wlr_keyboard_finish(&server->keyboard);
    if (server->backend) wlr_backend_destroy(server->backend);
    if (server->allocator) wlr_allocator_destroy(server->allocator);
    if (server->display) wl_display_destroy(server->display);
    if (server->renderer) wlr_renderer_destroy(server->renderer);
    if (server->xkb_context) xkb_context_unref(server->xkb_context);
    struct cm_expected *expected, *tmp;
    wl_list_for_each_safe(expected, tmp, &server->expected, link) {
        wl_list_remove(&expected->link);
        free(expected->id);
        free(expected);
    }
    free(server);
}

int cm_server_fd(struct cm_server *server) {
    return server ? wl_event_loop_get_fd(server->loop) : -1;
}

void cm_server_dispatch(struct cm_server *server) {
    if (!server || server->destroying) return;
    wl_event_loop_dispatch(server->loop, 0);
    wl_display_flush_clients(server->display);
}

void cm_server_expect(struct cm_server *server, const char *id, int64_t pid) {
    if (!server || !id || !*id || pid <= 0) return;
    struct cm_expected *expected = find_expected(server, id);
    if (expected && expected->pid != pid) {
        cm_server_forget(server, id);
        expected = NULL;
    }
    if (!expected) {
        expected = calloc(1, sizeof(*expected));
        if (!expected) return;
        expected->id = strdup(id);
        if (!expected->id) {
            free(expected);
            return;
        }
        expected->pid = pid;
        expected->width = server->output_width;
        expected->height = server->output_height;
        wl_list_insert(&server->expected, &expected->link);
    }
    struct cm_view *view;
    wl_list_for_each(view, &server->views, link) {
        if (!view->expected) match_view(view);
    }
}

void cm_server_forget(struct cm_server *server, const char *id) {
    if (!server) return;
    struct cm_expected *expected = find_expected(server, id);
    if (!expected) return;
    if (server->selected == expected) {
        server->selected = NULL;
        server->wants_focus = false;
        cm_server_pointer_leave(server);
    }
    struct cm_view *view = expected->view;
    if (view) {
        view->expected = NULL;
        view->announced = false;
        reject_view(view);
        arm_client_deadline(find_client(server, wl_resource_get_client(view->toplevel->resource)));
    }
    wl_list_remove(&expected->link);
    free(expected->id);
    free(expected);
    update_focus(server);
}

void cm_server_configure(struct cm_server *server, const char *id, int width, int height) {
    if (!server) return;
    struct cm_expected *expected = find_expected(server, id);
    if (!expected || width <= 0 || height <= 0) return;
    if (expected->width == width && expected->height == height) return;
    expected->width = width;
    expected->height = height;
    if (expected->view) configure_view(expected->view);
}

void cm_server_select(struct cm_server *server, const char *id, bool exposed) {
    if (!server) return;
    struct cm_expected *expected = find_expected(server, id);
    bool changed = server->selected != expected;
    bool reveal = exposed && (!server->exposed || changed);
    if (changed || !exposed) cm_server_pointer_leave(server);
    server->selected = expected;
    server->exposed = exposed;
    if (changed) server->wants_focus = false;
    update_focus(server);
    struct cm_view *view = selected_view(server);
    if (view && reveal) {
        emit_frame(view);
        emit_cursor(view);
    }
}

void cm_server_focus(struct cm_server *server, const char *id, bool focused) {
    if (!server) return;
    server->wants_focus = focused && server->selected && id && strcmp(id, server->selected->id) == 0;
    update_focus(server);
}

void cm_server_output(struct cm_server *server, int width, int height, int scale) {
    if (!server || width <= 0 || height <= 0) return;
    if (scale < 1) scale = 1;
    if (width > INT_MAX / scale || height > INT_MAX / scale) return;
    if (server->output_width == width && server->output_height == height && server->scale == scale) return;
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    wlr_output_state_set_custom_mode(&state, width * scale, height * scale, 60000);
    wlr_output_state_set_scale(&state, (float)scale);
    bool ok = wlr_output_commit_state(server->output, &state);
    wlr_output_state_finish(&state);
    if (!ok) {
        struct cm_view *view = selected_view(server);
        if (view) fail_view(view, "The native terminal output could not be resized.");
        return;
    }
    server->output_width = width;
    server->output_height = height;
    server->scale = scale;
    struct cm_view *view;
    wl_list_for_each(view, &server->views, link) {
        if (!view->expected) continue;
        wlr_surface_for_each_surface(view_surface(view), surface_output, server);
        if (view->cursor_surface) surface_output(view->cursor_surface, 0, 0, server);
    }
}

static void surface_frame_done(struct wlr_surface *surface, int sx, int sy, void *data) {
    (void)sx;
    (void)sy;
    wlr_surface_send_frame_done(surface, data);
}

void cm_server_frames(struct cm_server *server, bool visible) {
    if (!server) return;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    struct cm_view *view;
    wl_list_for_each(view, &server->views, link) {
        if (!view->expected) continue;
        bool shown = server->exposed && view == selected_view(server);
        if (shown != visible) continue;
        wlr_surface_for_each_surface(view_surface(view), surface_frame_done, &now);
        if (view->cursor_surface) wlr_surface_send_frame_done(view->cursor_surface, &now);
    }
    wl_display_flush_clients(server->display);
}

void cm_server_keymap(struct cm_server *server, const char *text) {
    if (!server || !text || !*text) return;
    struct xkb_keymap *keymap = xkb_keymap_new_from_string(server->xkb_context, text,
        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) return;
    if (wlr_keyboard_set_keymap(&server->keyboard, keymap)) server->host_keymap = true;
    xkb_keymap_unref(keymap);
    wlr_seat_keyboard_notify_modifiers(server->seat, &server->keyboard.modifiers);
}

void cm_server_key(struct cm_server *server, uint32_t key, bool pressed, bool deliver, uint32_t time) {
    if (!server) return;
    struct wlr_keyboard_key_event event = {
        .time_msec = time,
        .keycode = key,
        .update_state = !server->host_keymap,
        .state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED,
    };
    /* No key listener forwards the event: Qt separately decides shortcut ownership. */
    wlr_keyboard_notify_key(&server->keyboard, &event);
    if (deliver) wlr_seat_keyboard_notify_key(server->seat, time, key, event.state);
    wlr_seat_keyboard_notify_modifiers(server->seat, &server->keyboard.modifiers);
}

void cm_server_modifiers(struct cm_server *server, uint32_t depressed, uint32_t latched,
                         uint32_t locked, uint32_t group) {
    if (!server) return;
    wlr_keyboard_notify_modifiers(&server->keyboard, depressed, latched, locked, group);
    wlr_seat_keyboard_notify_modifiers(server->seat, &server->keyboard.modifiers);
}

void cm_server_pointer(struct cm_server *server, const char *id, double x, double y, uint32_t time) {
    if (!server || !server->exposed) return;
    struct cm_view *view = selected_view(server);
    if (!view || !id || view->failed || strcmp(id, view->expected->id) != 0 ||
        !view_surface(view)->mapped) return;
    double sx, sy;
    struct wlr_surface *surface = wlr_surface_surface_at(view_surface(view), x, y, &sx, &sy);
    if (!surface) {
        cm_server_pointer_leave(server);
        return;
    }
    wlr_seat_pointer_notify_enter(server->seat, surface, sx, sy);
    wlr_seat_pointer_notify_motion(server->seat, time, sx, sy);
    wlr_seat_pointer_notify_frame(server->seat);
}

void cm_server_pointer_leave(struct cm_server *server) {
    if (!server) return;
    wlr_seat_pointer_notify_clear_focus(server->seat);
    wlr_seat_pointer_notify_frame(server->seat);
}

void cm_server_button(struct cm_server *server, uint32_t button, bool pressed, uint32_t time) {
    if (!server) return;
    wlr_seat_pointer_notify_button(server->seat, time, button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(server->seat);
}

void cm_server_scroll(struct cm_server *server, double horizontal, double vertical,
                      int discrete_h, int discrete_v, uint32_t time) {
    if (!server) return;
    enum wl_pointer_axis_source source = discrete_h || discrete_v
        ? WL_POINTER_AXIS_SOURCE_WHEEL : WL_POINTER_AXIS_SOURCE_CONTINUOUS;
    if (horizontal || discrete_h)
        wlr_seat_pointer_notify_axis(server->seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            horizontal, discrete_h * 120, source, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    if (vertical || discrete_v)
        wlr_seat_pointer_notify_axis(server->seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            vertical, discrete_v * 120, source, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    wlr_seat_pointer_notify_frame(server->seat);
}

void cm_server_text(struct cm_server *server, const char *preedit, int cursor_begin,
                    int cursor_end, const char *commit) {
    if (!server) return;
    struct wlr_surface *surface = server->seat->keyboard_state.focused_surface;
    if (!surface) return;
    struct cm_text_input *record;
    wl_list_for_each(record, &server->text_inputs, link) {
        struct wlr_text_input_v3 *input = record->input;
        if (input->focused_surface != surface || !input->current_enabled) continue;
        if (preedit) wlr_text_input_v3_send_preedit_string(input, preedit, cursor_begin, cursor_end);
        if (commit) wlr_text_input_v3_send_commit_string(input, commit);
        wlr_text_input_v3_send_done(input);
    }
}

void cm_server_offer_selection(struct cm_server *server, const char *const *mimes,
                               size_t count, uint64_t token) {
    if (!server) return;
    struct cm_selection *selection = NULL;
    if (count) {
        selection = calloc(1, sizeof(*selection));
        if (!selection) {
            if (server->callbacks.selection_released) server->callbacks.selection_released(server->ctx, token);
            return;
        }
        selection->server = server;
        selection->token = token;
        wlr_data_source_init(&selection->source, &selection_impl);
        for (size_t i = 0; i < count; ++i) {
            char *mime = mimes[i] ? strdup(mimes[i]) : NULL;
            char **slot = mime ? wl_array_add(&selection->source.mime_types, sizeof(*slot)) : NULL;
            if (!slot) {
                free(mime);
                wlr_data_source_destroy(&selection->source);
                return;
            }
            *slot = mime;
        }
    }
    server->host_selection = true;
    wlr_seat_set_selection(server->seat, selection ? &selection->source : NULL,
                          wl_display_next_serial(server->display));
    if (!selection && server->callbacks.selection_released)
        server->callbacks.selection_released(server->ctx, token);
    wl_display_flush_clients(server->display);
}

bool cm_server_receive_selection(struct cm_server *server, uint64_t generation, const char *mime, int fd) {
    if (fd < 0) return false;
    if (!server || server->host_selection || generation != server->selection_generation || !mime ||
        !server->seat->selection_source) {
        close(fd);
        return false;
    }
    struct wlr_data_source *source = server->seat->selection_source;
    char **offered;
    wl_array_for_each(offered, &source->mime_types) {
        if (strcmp(*offered, mime) == 0) {
            wlr_data_source_send(source, mime, fd);
            wl_display_flush_clients(server->display);
            return true;
        }
    }
    close(fd);
    return false;
}
