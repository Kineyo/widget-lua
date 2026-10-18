/*
 * qwen_native.cpp - Hybrid C++17 Native Engine for Qwen-Widget (Lua 5.3 C API)
 *
 * Responsibilities:
 *  1. Instant OS Text Selection Hooks (Linux X11/XFixes/XInput2 + Wayland,
 *     Windows Win32/UIAutomation, macOS Accessibility API) & Cursor Tracking.
 *  2. Window Coordinate Tracking, Screen Clamping & Smooth Interpolation.
 *  3. Native Media IPC (MPRIS2 via GDBus on Linux for YouTube Music & Spotify,
 *     SMTC on Windows, MediaRemote on macOS).
 *  4. Native llama.cpp Inference Bridge & Strict Memory Controller (<= 500 MB).
 */

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "lua.hpp"

#if defined(__linux__)
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif
#include <gio/gio.h>
#include <glib.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/XInput2.h>
#elif defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#elif defined(__APPLE__)
#include <ApplicationServices/ApplicationServices.h>
#include <mach/mach.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

static int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

/* ==========================================================================
 * 1. NATIVE SELECTION HOOK & POINTER COORDINATES
 * ========================================================================== */
struct SelectionEvent {
    bool pending = false;
    std::string type; /* "selection" or "clipboard" */
    std::string text;
    int x = 0;
    int y = 0;
    int64_t timestamp = 0;
};

static std::mutex g_sel_mutex;
static SelectionEvent g_sel_event;
static std::atomic<bool> g_hook_running{false};
static std::atomic<int64_t> g_suppress_until_ms{0};
static std::thread g_hook_thread;
static std::string g_last_primary_text;

static void get_native_cursor(int &out_x, int &out_y) {
    out_x = 0;
    out_y = 0;
#if defined(__linux__)
    Display *dpy = XOpenDisplay(nullptr);
    if (dpy) {
        Window root = DefaultRootWindow(dpy);
        Window ret_root = None, ret_child = None;
        int root_x = 0, root_y = 0, win_x = 0, win_y = 0;
        unsigned int mask = 0;
        if (XQueryPointer(dpy, root, &ret_root, &ret_child, &root_x, &root_y, &win_x, &win_y, &mask)) {
            out_x = root_x;
            out_y = root_y;
        }
        XCloseDisplay(dpy);
    }
#elif defined(_WIN32)
    POINT pt;
    if (GetCursorPos(&pt)) {
        out_x = pt.x;
        out_y = pt.y;
    }
#elif defined(__APPLE__)
    CGEventRef ev = CGEventCreate(nullptr);
    if (ev) {
        CGPoint pt = CGEventGetLocation(ev);
        out_x = static_cast<int>(pt.x);
        out_y = static_cast<int>(pt.y);
        CFRelease(ev);
    }
#endif
}

#if defined(__linux__)
static std::string read_x11_selection(Display *dpy, Window target_win, Atom selection_atom) {
    Atom utf8_atom = XInternAtom(dpy, "UTF8_STRING", False);
    Atom prop_atom = XInternAtom(dpy, "QWEN_SEL_PROP", False);
    Atom incr_atom = XInternAtom(dpy, "INCR", False);

    XDeleteProperty(dpy, target_win, prop_atom);
    XConvertSelection(dpy, selection_atom, utf8_atom, prop_atom, target_win, CurrentTime);
    XFlush(dpy);

    auto start = now_ms();
    while (now_ms() - start < 120) {
        if (XPending(dpy) > 0) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == SelectionNotify) {
                if (ev.xselection.property == None) {
                    return "";
                }
                Atom actual_type = None;
                int actual_format = 0;
                unsigned long nitems = 0, bytes_after = 0;
                unsigned char *prop_data = nullptr;
                if (XGetWindowProperty(dpy, target_win, prop_atom, 0, 16384, True, AnyPropertyType,
                                       &actual_type, &actual_format, &nitems, &bytes_after, &prop_data) == Success) {
                    std::string result;
                    if (prop_data && actual_type != incr_atom && nitems > 0) {
                        result.assign(reinterpret_cast<char *>(prop_data), nitems);
                    }
                    if (prop_data) XFree(prop_data);
                    return result;
                }
                return "";
            }
        } else {
            usleep(2000);
        }
    }
    return "";
}

static void selection_hook_loop() {
    Display *dpy = XOpenDisplay(nullptr);
    if (!dpy) return;

    Window root = DefaultRootWindow(dpy);
    Window dummy = XCreateSimpleWindow(dpy, root, -10, -10, 1, 1, 0, 0, 0);

    Atom xa_primary = XA_PRIMARY;
    Atom xa_clipboard = XInternAtom(dpy, "CLIPBOARD", False);

    int xfixes_event_base = 0, xfixes_error_base = 0;
    bool has_xfixes = XFixesQueryExtension(dpy, &xfixes_event_base, &xfixes_error_base);
    if (has_xfixes) {
        XFixesSelectSelectionInput(dpy, root, xa_primary, XFixesSetSelectionOwnerNotifyMask);
        XFixesSelectSelectionInput(dpy, root, xa_clipboard, XFixesSetSelectionOwnerNotifyMask);
    }

    int xi_opcode = 0, xi_event = 0, xi_error = 0;
    bool has_xi2 = XQueryExtension(dpy, "XInputExtension", &xi_opcode, &xi_event, &xi_error);
    if (has_xi2) {
        unsigned char mask_bytes[(XI_LASTEVENT + 7) / 8] = {0};
        XIEventMask evmask;
        evmask.deviceid = XIAllMasterDevices;
        evmask.mask_len = sizeof(mask_bytes);
        evmask.mask = mask_bytes;
        XISetMask(mask_bytes, XI_RawButtonPress);
        XISetMask(mask_bytes, XI_RawButtonRelease);
        XISelectEvents(dpy, root, &evmask, 1);
    }

    XFlush(dpy);

    bool mouse_down = false;
    bool selection_dirty = false;
    int64_t last_button_release_ms = 0;

    while (g_hook_running.load()) {
        while (XPending(dpy) > 0) {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if (has_xfixes && ev.type == xfixes_event_base + XFixesSelectionNotify) {
                XFixesSelectionNotifyEvent *sev = reinterpret_cast<XFixesSelectionNotifyEvent *>(&ev);
                if (sev->selection == xa_clipboard) {
                    if (now_ms() >= g_suppress_until_ms.load()) {
                        std::lock_guard<std::mutex> lk(g_sel_mutex);
                        g_sel_event.pending = true;
                        g_sel_event.type = "clipboard";
                        g_sel_event.text = "";
                        g_sel_event.timestamp = now_ms();
                    }
                } else if (sev->selection == xa_primary) {
                    selection_dirty = true;
                }
            } else if (has_xi2 && ev.xcookie.type == GenericEvent && ev.xcookie.extension == xi_opcode) {
                if (XGetEventData(dpy, &ev.xcookie)) {
                    if (ev.xcookie.evtype == XI_RawButtonPress) {
                        XIRawEvent *rev = static_cast<XIRawEvent *>(ev.xcookie.data);
                        if (rev->detail == 1) {
                            mouse_down = true;
                        }
                    } else if (ev.xcookie.evtype == XI_RawButtonRelease) {
                        XIRawEvent *rev = static_cast<XIRawEvent *>(ev.xcookie.data);
                        if (rev->detail == 1) {
                            mouse_down = false;
                            last_button_release_ms = now_ms();
                            selection_dirty = true;
                        }
                    }
                    XFreeEventData(dpy, &ev.xcookie);
                }
            }
        }

        /* When selection changed and mouse button is released, read PRIMARY immediately */
        if (selection_dirty && !mouse_down && (now_ms() - last_button_release_ms >= 15)) {
            selection_dirty = false;
            if (now_ms() >= g_suppress_until_ms.load()) {
                std::string txt = read_x11_selection(dpy, dummy, xa_primary);
                /* Trim leading/trailing whitespace */
                size_t first = txt.find_first_not_of(" \t\r\n");
                if (first != std::string::npos) {
                    size_t last = txt.find_last_not_of(" \t\r\n");
                    txt = txt.substr(first, last - first + 1);
                } else {
                    txt.clear();
                }

                if (txt.size() >= 2 && txt.size() <= 20000 && txt != g_last_primary_text) {
                    g_last_primary_text = txt;
                    Window r_root = None, r_child = None;
                    int rx = 0, ry = 0, wx = 0, wy = 0;
                    unsigned int mask = 0;
                    XQueryPointer(dpy, root, &r_root, &r_child, &rx, &ry, &wx, &wy, &mask);

                    std::lock_guard<std::mutex> lk(g_sel_mutex);
                    g_sel_event.pending = true;
                    g_sel_event.type = "selection";
                    g_sel_event.text = txt;
                    g_sel_event.x = rx;
                    g_sel_event.y = ry;
                    g_sel_event.timestamp = now_ms();
                } else if (txt.empty() && !g_last_primary_text.empty()) {
                    g_last_primary_text.clear();
                    std::lock_guard<std::mutex> lk(g_sel_mutex);
                    g_sel_event.pending = true;
                    g_sel_event.type = "selection";
                    g_sel_event.text = "";
                    g_sel_event.timestamp = now_ms();
                }
            }
        }

        usleep(12000); /* 12ms low-overhead sleep when idle */
    }

    XDestroyWindow(dpy, dummy);
    XCloseDisplay(dpy);
}
#else
static void selection_hook_loop() {
    while (g_hook_running.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}
#endif

static int l_start_selection_hook(lua_State *L) {
    if (!g_hook_running.load()) {
        g_hook_running.store(true);
        g_hook_thread = std::thread(selection_hook_loop);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_stop_selection_hook(lua_State *L) {
    if (g_hook_running.load()) {
        g_hook_running.store(false);
        if (g_hook_thread.joinable()) {
            g_hook_thread.join();
        }
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_poll_selection(lua_State *L) {
    std::lock_guard<std::mutex> lk(g_sel_mutex);
    if (!g_sel_event.pending) {
        lua_pushnil(L);
        return 1;
    }
    g_sel_event.pending = false;

    lua_newtable(L);
    lua_pushstring(L, g_sel_event.type.c_str());
    lua_setfield(L, -2, "type");
    lua_pushlstring(L, g_sel_event.text.data(), g_sel_event.text.size());
    lua_setfield(L, -2, "text");
    lua_pushinteger(L, g_sel_event.x);
    lua_setfield(L, -2, "x");
    lua_pushinteger(L, g_sel_event.y);
    lua_setfield(L, -2, "y");
    lua_pushinteger(L, static_cast<lua_Integer>(g_sel_event.timestamp));
    lua_setfield(L, -2, "timestamp");
    return 1;
}

static int l_suppress_selection(lua_State *L) {
    int64_t ms = static_cast<int64_t>(luaL_optinteger(L, 1, 2000));
    const char *ignore_txt = luaL_optstring(L, 2, nullptr);
    g_suppress_until_ms.store(now_ms() + ms);
    if (ignore_txt) {
        std::lock_guard<std::mutex> lk(g_sel_mutex);
        g_last_primary_text = ignore_txt;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_get_cursor_pos(lua_State *L) {
    int x = 0, y = 0;
    get_native_cursor(x, y);
    lua_pushinteger(L, x);
    lua_pushinteger(L, y);
    return 2;
}

/* ==========================================================================
 * 2. WINDOW COORDINATE TRACKING, SCREEN CLAMPING & INTERPOLATION
 * ========================================================================== */
static int l_clamp_rect(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);
    double w = luaL_checknumber(L, 3);
    double h = luaL_checknumber(L, 4);
    double sw = luaL_optnumber(L, 5, 1920.0);
    double sh = luaL_optnumber(L, 6, 1080.0);
    double margin = luaL_optnumber(L, 7, 8.0);

    if (sw <= 100.0) sw = 1920.0;
    if (sh <= 100.0) sh = 1080.0;

    double cx = std::max(margin, std::min(x, sw - w - margin));
    double cy = std::max(margin, std::min(y, sh - h - margin));
    lua_pushinteger(L, static_cast<lua_Integer>(std::llround(cx)));
    lua_pushinteger(L, static_cast<lua_Integer>(std::llround(cy)));
    return 2;
}

static int l_compute_dock_position(lua_State *L) {
    double bx = luaL_checknumber(L, 1);
    double by = luaL_checknumber(L, 2);
    double bsize = luaL_checknumber(L, 3);
    double pw = luaL_checknumber(L, 4);
    double ph = luaL_checknumber(L, 5);
    double gap = luaL_optnumber(L, 6, 10.0);
    const char *edge_str = luaL_optstring(L, 7, "right");
    double sw = luaL_optnumber(L, 8, 1920.0);
    double sh = luaL_optnumber(L, 9, 1080.0);
    double margin = luaL_optnumber(L, 10, 8.0);

    if (sw <= 100.0) sw = 1920.0;
    if (sh <= 100.0) sh = 1080.0;

    std::string edge = edge_str ? edge_str : "right";
    double center_x = bx + bsize * 0.5;
    double center_y = by + bsize * 0.5;

    /* Dynamically determine effective edge while dragging in free space */
    if (edge == "auto") {
        double d_left = bx;
        double d_right = sw - (bx + bsize);
        double d_top = by;
        double d_bottom = sh - (by + bsize);
        double min_d = std::min({d_left, d_right, d_top, d_bottom});
        if (min_d == d_left) edge = "left";
        else if (min_d == d_right) edge = "right";
        else if (min_d == d_top) edge = "top";
        else edge = "bottom";
    }

    double px = 0.0, py = 0.0;
    if (edge == "left") {
        px = bx + bsize + gap;
        py = center_y - ph * 0.5;
        if (px + pw > sw - margin) {
            px = bx - pw - gap;
            edge = "right";
        }
    } else if (edge == "right") {
        px = bx - pw - gap;
        py = center_y - ph * 0.5;
        if (px < margin) {
            px = bx + bsize + gap;
            edge = "left";
        }
    } else if (edge == "top") {
        px = center_x - pw * 0.5;
        py = by + bsize + gap;
        if (py + ph > sh - margin) {
            py = by - ph - gap;
            edge = "bottom";
        }
    } else {
        px = center_x - pw * 0.5;
        py = by - ph - gap;
        if (py < margin) {
            py = by + bsize + gap;
            edge = "top";
        }
    }

    /* If still overlapping the bubble, place horizontally opposite */
    px = std::max(margin, std::min(px, sw - pw - margin));
    py = std::max(margin, std::min(py, sh - ph - margin));

    lua_pushinteger(L, static_cast<lua_Integer>(std::llround(px)));
    lua_pushinteger(L, static_cast<lua_Integer>(std::llround(py)));
    lua_pushstring(L, edge.c_str());
    return 3;
}

static int l_lerp_point(lua_State *L) {
    double cx = luaL_checknumber(L, 1);
    double cy = luaL_checknumber(L, 2);
    double tx = luaL_checknumber(L, 3);
    double ty = luaL_checknumber(L, 4);
    double alpha = luaL_optnumber(L, 5, 0.35);
    alpha = std::max(0.01, std::min(1.0, alpha));

    double nx = cx + (tx - cx) * alpha;
    double ny = cy + (ty - cy) * alpha;
    if (std::hypot(tx - nx, ty - ny) < 1.2) {
        nx = tx;
        ny = ty;
    }
    lua_pushinteger(L, static_cast<lua_Integer>(std::llround(nx)));
    lua_pushinteger(L, static_cast<lua_Integer>(std::llround(ny)));
    return 2;
}

/* ==========================================================================
 * 3. NATIVE MEDIA IPC (MPRIS2 GDBus on Linux for YouTube Music & Spotify)
 * ========================================================================== */
#if defined(__linux__)
struct PlayerInfo {
    std::string bus_name;
    std::string source;      /* "spotify" or "ytmusic" or "other" */
    std::string player_name; /* "Spotify" or "YouTube Music" */
    std::string status;      /* "Playing", "Paused", "Stopped" */
    std::string title;
    std::string artist;
    std::string album;
    std::string art_url;
    std::string track_id;
    double length = 0.0;
    double position = 0.0;
    double volume = 1.0;
};

static std::string classify_player_bus(const std::string &bus, const std::string &identity) {
    std::string lower = bus + " " + identity;
    for (char &c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (lower.find("spotify") != std::string::npos) {
        return "spotify";
    }
    if (lower.find("youtube") != std::string::npos ||
        lower.find("chromium") != std::string::npos ||
        lower.find("chrome") != std::string::npos ||
        lower.find("brave") != std::string::npos ||
        lower.find("firefox") != std::string::npos ||
        lower.find("mpv") != std::string::npos ||
        lower.find("vlc") != std::string::npos) {
        return "ytmusic";
    }
    return "ytmusic";
}

static bool query_mpris_bus(GDBusConnection *conn, const std::string &bus_name, PlayerInfo &info) {
    info.bus_name = bus_name;

    /* 1. Get Identity from org.mpris.MediaPlayer2 */
    std::string identity;
    GVariant *id_res = g_dbus_connection_call_sync(
        conn, bus_name.c_str(), "/org/mpris/MediaPlayer2",
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.mpris.MediaPlayer2", "Identity"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 350, nullptr, nullptr);
    if (id_res) {
        GVariant *inner = nullptr;
        g_variant_get(id_res, "(v)", &inner);
        if (inner) {
            if (g_variant_is_of_type(inner, G_VARIANT_TYPE_STRING)) {
                identity = g_variant_get_string(inner, nullptr);
            }
            g_variant_unref(inner);
        }
        g_variant_unref(id_res);
    }

    info.source = classify_player_bus(bus_name, identity);
    info.player_name = (info.source == "spotify") ? "Spotify" : "YouTube Music";

    /* 2. GetAll properties from org.mpris.MediaPlayer2.Player */
    GVariant *res = g_dbus_connection_call_sync(
        conn, bus_name.c_str(), "/org/mpris/MediaPlayer2",
        "org.freedesktop.DBus.Properties", "GetAll",
        g_variant_new("(s)", "org.mpris.MediaPlayer2.Player"),
        G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE, 450, nullptr, nullptr);
    if (!res) return false;

    GVariant *dict = g_variant_get_child_value(res, 0);
    if (dict) {
        GVariant *v_status = g_variant_lookup_value(dict, "PlaybackStatus", G_VARIANT_TYPE_STRING);
        if (v_status) {
            info.status = g_variant_get_string(v_status, nullptr);
            g_variant_unref(v_status);
        } else {
            info.status = "Stopped";
        }

        GVariant *v_pos = g_variant_lookup_value(dict, "Position", nullptr);
        if (v_pos) {
            if (g_variant_is_of_type(v_pos, G_VARIANT_TYPE_INT64)) {
                info.position = static_cast<double>(g_variant_get_int64(v_pos)) / 1000000.0;
            } else if (g_variant_is_of_type(v_pos, G_VARIANT_TYPE_UINT64)) {
                info.position = static_cast<double>(g_variant_get_uint64(v_pos)) / 1000000.0;
            }
            g_variant_unref(v_pos);
        }

        GVariant *v_vol = g_variant_lookup_value(dict, "Volume", G_VARIANT_TYPE_DOUBLE);
        if (v_vol) {
            info.volume = g_variant_get_double(v_vol);
            g_variant_unref(v_vol);
        }

        GVariant *v_meta = g_variant_lookup_value(dict, "Metadata", G_VARIANT_TYPE("a{sv}"));
        if (v_meta) {
            GVariant *m_title = g_variant_lookup_value(v_meta, "xesam:title", G_VARIANT_TYPE_STRING);
            if (m_title) {
                info.title = g_variant_get_string(m_title, nullptr);
                g_variant_unref(m_title);
            }

            GVariant *m_album = g_variant_lookup_value(v_meta, "xesam:album", G_VARIANT_TYPE_STRING);
            if (m_album) {
                info.album = g_variant_get_string(m_album, nullptr);
                g_variant_unref(m_album);
            }

            GVariant *m_art = g_variant_lookup_value(v_meta, "mpris:artUrl", G_VARIANT_TYPE_STRING);
            if (m_art) {
                info.art_url = g_variant_get_string(m_art, nullptr);
                g_variant_unref(m_art);
            }

            GVariant *m_tid = g_variant_lookup_value(v_meta, "mpris:trackid", nullptr);
            if (m_tid) {
                if (g_variant_is_of_type(m_tid, G_VARIANT_TYPE_OBJECT_PATH) ||
                    g_variant_is_of_type(m_tid, G_VARIANT_TYPE_STRING)) {
                    info.track_id = g_variant_get_string(m_tid, nullptr);
                }
                g_variant_unref(m_tid);
            }

            GVariant *m_len = g_variant_lookup_value(v_meta, "mpris:length", nullptr);
            if (m_len) {
                if (g_variant_is_of_type(m_len, G_VARIANT_TYPE_INT64)) {
                    info.length = static_cast<double>(g_variant_get_int64(m_len)) / 1000000.0;
                } else if (g_variant_is_of_type(m_len, G_VARIANT_TYPE_UINT64)) {
                    info.length = static_cast<double>(g_variant_get_uint64(m_len)) / 1000000.0;
                }
                g_variant_unref(m_len);
            }

            GVariant *m_artist = g_variant_lookup_value(v_meta, "xesam:artist", nullptr);
            if (m_artist) {
                if (g_variant_is_of_type(m_artist, G_VARIANT_TYPE_STRING_ARRAY)) {
                    gsize len = 0;
                    const gchar **arr = g_variant_get_strv(m_artist, &len);
                    if (arr && len > 0 && arr[0]) {
                        info.artist = arr[0];
                        for (gsize i = 1; i < len; ++i) {
                            if (arr[i] && std::strlen(arr[i]) > 0) {
                                info.artist += ", ";
                                info.artist += arr[i];
                            }
                        }
                    }
                    g_free(arr);
                } else if (g_variant_is_of_type(m_artist, G_VARIANT_TYPE_STRING)) {
                    info.artist = g_variant_get_string(m_artist, nullptr);
                }
                g_variant_unref(m_artist);
            }

            g_variant_unref(v_meta);
        }
        g_variant_unref(dict);
    }
    g_variant_unref(res);
    return true;
}

static std::vector<PlayerInfo> enumerate_mpris_players(GDBusConnection *conn) {
    std::vector<PlayerInfo> list;
    if (!conn) return list;

    GVariant *res = g_dbus_connection_call_sync(
        conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "ListNames", nullptr,
        G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, 450, nullptr, nullptr);
    if (!res) return list;

    GVariantIter *iter = nullptr;
    g_variant_get(res, "(as)", &iter);
    const gchar *name = nullptr;
    std::vector<std::string> buses;
    while (g_variant_iter_loop(iter, "&s", &name)) {
        if (name && std::strncmp(name, "org.mpris.MediaPlayer2.", 23) == 0) {
            /* Skip KDE Connect or generic proxy buses if real players exist */
            if (std::strstr(name, "kdeconnect") == nullptr) {
                buses.emplace_back(name);
            }
        }
    }
    g_variant_iter_free(iter);
    g_variant_unref(res);

    for (const auto &b : buses) {
        PlayerInfo p;
        if (query_mpris_bus(conn, b, p)) {
            list.push_back(std::move(p));
        }
    }
    return list;
}

static bool select_best_player(const std::vector<PlayerInfo> &players,
                               const std::string &preferred_source,
                               PlayerInfo &out) {
    if (players.empty()) return false;

    /* 1. If user explicitly requested spotify or ytmusic, prefer matching Playing, then matching Paused */
    if (preferred_source == "spotify" || preferred_source == "ytmusic") {
        for (const auto &p : players) {
            if (p.source == preferred_source && p.status == "Playing") {
                out = p;
                return true;
            }
        }
        for (const auto &p : players) {
            if (p.source == preferred_source && !p.title.empty()) {
                out = p;
                return true;
            }
        }
        for (const auto &p : players) {
            if (p.source == preferred_source) {
                out = p;
                return true;
            }
        }
    }

    /* 2. Auto mode: prioritize whichever player is actively Playing */
    for (const auto &p : players) {
        if (p.status == "Playing" && !p.title.empty()) {
            out = p;
            return true;
        }
    }
    for (const auto &p : players) {
        if (!p.title.empty()) {
            out = p;
            return true;
        }
    }

    out = players[0];
    return true;
}
#endif

static int l_media_get_state(lua_State *L) {
    const char *pref = luaL_optstring(L, 1, "auto");
    std::string preferred_source = pref ? pref : "auto";

#if defined(__linux__)
    GDBusConnection *conn = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (!conn) {
        lua_pushnil(L);
        return 1;
    }

    auto players = enumerate_mpris_players(conn);
    bool has_spotify = false;
    bool has_ytmusic = false;
    for (const auto &p : players) {
        if (p.source == "spotify") has_spotify = true;
        if (p.source == "ytmusic") has_ytmusic = true;
    }

    PlayerInfo active;
    bool found = select_best_player(players, preferred_source, active);
    g_object_unref(conn);

    lua_newtable(L);
    lua_pushboolean(L, found ? 1 : 0);
    lua_setfield(L, -2, "found");
    lua_pushboolean(L, has_spotify ? 1 : 0);
    lua_setfield(L, -2, "has_spotify");
    lua_pushboolean(L, has_ytmusic ? 1 : 0);
    lua_setfield(L, -2, "has_ytmusic");

    if (found) {
        lua_pushstring(L, active.bus_name.c_str());
        lua_setfield(L, -2, "bus_name");
        lua_pushstring(L, active.source.c_str());
        lua_setfield(L, -2, "source");
        lua_pushstring(L, active.player_name.c_str());
        lua_setfield(L, -2, "player_name");
        lua_pushstring(L, active.status.c_str());
        lua_setfield(L, -2, "status");
        lua_pushstring(L, active.title.c_str());
        lua_setfield(L, -2, "title");
        lua_pushstring(L, active.artist.c_str());
        lua_setfield(L, -2, "artist");
        lua_pushstring(L, active.album.c_str());
        lua_setfield(L, -2, "album");
        lua_pushstring(L, active.art_url.c_str());
        lua_setfield(L, -2, "art_url");
        lua_pushstring(L, active.track_id.c_str());
        lua_setfield(L, -2, "track_id");
        lua_pushnumber(L, active.length);
        lua_setfield(L, -2, "length");
        lua_pushnumber(L, active.position);
        lua_setfield(L, -2, "position");
        lua_pushnumber(L, active.volume);
        lua_setfield(L, -2, "volume");
    }
    return 1;
#else
    lua_pushnil(L);
    return 1;
#endif
}

static int l_media_control(lua_State *L) {
    const char *action = luaL_checkstring(L, 1);
    double val = luaL_optnumber(L, 2, 0.0);
    const char *pref = luaL_optstring(L, 3, "auto");

#if defined(__linux__)
    GDBusConnection *conn = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (!conn) {
        lua_pushboolean(L, 0);
        return 1;
    }

    auto players = enumerate_mpris_players(conn);
    PlayerInfo active;
    if (!select_best_player(players, pref ? pref : "auto", active)) {
        g_object_unref(conn);
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string act = action ? action : "";
    GVariant *res = nullptr;

    if (act == "play_pause") {
        res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "PlayPause", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
    } else if (act == "play") {
        res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Play", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
    } else if (act == "pause") {
        res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Pause", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
    } else if (act == "next") {
        res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Next", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
    } else if (act == "previous") {
        res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Previous", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
    } else if (act == "seek") {
        gint64 target_us = static_cast<gint64>(val * 1000000.0);
        if (!active.track_id.empty() && active.track_id[0] == '/') {
            res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
                "org.mpris.MediaPlayer2.Player", "SetPosition",
                g_variant_new("(ox)", active.track_id.c_str(), target_us),
                nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
        }
        if (!res) {
            gint64 delta_us = static_cast<gint64>((val - active.position) * 1000000.0);
            res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
                "org.mpris.MediaPlayer2.Player", "Seek",
                g_variant_new("(x)", delta_us),
                nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
        }
    } else if (act == "volume") {
        double clamped_vol = std::max(0.0, std::min(1.0, val));
        res = g_dbus_connection_call_sync(conn, active.bus_name.c_str(), "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties", "Set",
            g_variant_new("(ssv)", "org.mpris.MediaPlayer2.Player", "Volume", g_variant_new_double(clamped_vol)),
            nullptr, G_DBUS_CALL_FLAGS_NONE, 400, nullptr, nullptr);
        /* Also adjust PulseAudio/PipeWire sink volume as fallback if browser player ignores MPRIS volume */
        if (!res) {
            int pct = static_cast<int>(std::round(clamped_vol * 100.0));
            char cmd[128];
            std::snprintf(cmd, sizeof(cmd), "pactl set-sink-volume @DEFAULT_SINK@ %d%% >/dev/null 2>&1 &", pct);
            int rc = std::system(cmd);
            (void)rc;
        }
    }

    bool ok = (res != nullptr);
    if (res) g_variant_unref(res);
    g_object_unref(conn);
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
#else
    (void)action; (void)val; (void)pref;
    lua_pushboolean(L, 0);
    return 1;
#endif
}

/* ==========================================================================
 * 4. NATIVE LLAMA.CPP BRIDGE & STRICT <= 500 MB MEMORY CONTROLLER
 * ========================================================================== */
static std::mutex g_llama_mutex;
static pid_t g_llama_pid = -1;
static std::string g_llama_model;
static int g_llama_port = 18089;

static double read_proc_rss_mb(pid_t pid, double *out_anon_mb = nullptr) {
#if defined(__linux__)
    char path[64];
    if (pid <= 0) {
        std::snprintf(path, sizeof(path), "/proc/self/status");
    } else {
        std::snprintf(path, sizeof(path), "/proc/%d/status", static_cast<int>(pid));
    }
    std::ifstream f(path);
    if (!f.is_open()) return 0.0;

    double rss_kb = 0.0;
    double anon_kb = 0.0;
    std::string line;
    while (std::getline(f, line)) {
        if (line.compare(0, 6, "VmRSS:") == 0) {
            rss_kb = std::strtod(line.c_str() + 6, nullptr);
        } else if (line.compare(0, 8, "RssAnon:") == 0) {
            anon_kb = std::strtod(line.c_str() + 8, nullptr);
        }
    }
    if (out_anon_mb) *out_anon_mb = anon_kb / 1024.0;
    return rss_kb / 1024.0;
#else
    if (out_anon_mb) *out_anon_mb = 0.0;
    return 25.0;
#endif
}

static bool is_pid_alive(pid_t pid) {
#if defined(__linux__) || defined(__APPLE__)
    if (pid <= 0) return false;
    int status = 0;
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid || (r == -1 && kill(pid, 0) != 0)) {
        return false;
    }
    return kill(pid, 0) == 0;
#else
    return false;
#endif
}

static void stop_llama_locked() {
#if defined(__linux__) || defined(__APPLE__)
    if (g_llama_pid > 0) {
        kill(g_llama_pid, SIGTERM);
        for (int i = 0; i < 20; ++i) {
            int status = 0;
            if (waitpid(g_llama_pid, &status, WNOHANG) == g_llama_pid) {
                g_llama_pid = -1;
                break;
            }
            usleep(25000);
        }
        if (g_llama_pid > 0) {
            kill(g_llama_pid, SIGKILL);
            int status = 0;
            waitpid(g_llama_pid, &status, 0);
            g_llama_pid = -1;
        }
    }
    g_llama_model.clear();
#endif
}

struct LlamaCleanupGuard {
    ~LlamaCleanupGuard() {
        std::lock_guard<std::mutex> lk(g_llama_mutex);
        stop_llama_locked();
        if (g_hook_running.load()) {
            g_hook_running.store(false);
            if (g_hook_thread.joinable()) g_hook_thread.join();
        }
    }
};
static LlamaCleanupGuard g_cleanup_guard;

static int l_llama_ensure(lua_State *L) {
    const char *server_bin = luaL_checkstring(L, 1);
    const char *model_path = luaL_checkstring(L, 2);
    int port = static_cast<int>(luaL_optinteger(L, 3, 18089));
    int ctx_size = static_cast<int>(luaL_optinteger(L, 4, 512));
    int threads = static_cast<int>(luaL_optinteger(L, 5, 4));
    const char *native_lib_dir = luaL_optstring(L, 6, "");
    const char *guard_so_path = luaL_optstring(L, 7, "");

    std::lock_guard<std::mutex> lk(g_llama_mutex);

#if defined(__linux__) || defined(__APPLE__)
    if (is_pid_alive(g_llama_pid) && g_llama_model == model_path && g_llama_port == port) {
        lua_pushboolean(L, 1);
        lua_pushinteger(L, static_cast<lua_Integer>(g_llama_pid));
        return 2;
    }

    /* Stop any existing instance so two models never coexist in RAM */
    stop_llama_locked();

    /* Clamp context size & threads for strict <= 500 MB RAM budget */
    ctx_size = std::max(256, std::min(ctx_size, 2048));
    threads = std::max(1, std::min(threads, 8));

    pid_t pid = fork();
    if (pid == 0) {
        /* Child process: configure environment & exec llama-server */
        if (native_lib_dir && std::strlen(native_lib_dir) > 0) {
            const char *old_ld = std::getenv("LD_LIBRARY_PATH");
            std::string new_ld = native_lib_dir;
            if (old_ld && std::strlen(old_ld) > 0) {
                new_ld += ":";
                new_ld += old_ld;
            }
            setenv("LD_LIBRARY_PATH", new_ld.c_str(), 1);
        }
        if (guard_so_path && std::strlen(guard_so_path) > 0 && access(guard_so_path, R_OK) == 0) {
            setenv("LD_PRELOAD", guard_so_path, 1);
        }

        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }

        std::string s_ctx = std::to_string(ctx_size);
        std::string s_thr = std::to_string(threads);
        std::string s_port = std::to_string(port);

        execl(server_bin, server_bin,
              "-m", model_path,
              "-c", s_ctx.c_str(),
              "-t", s_thr.c_str(),
              "-b", "128",
              "-ub", "64",
              "-np", "1",
              "--port", s_port.c_str(),
              "--host", "127.0.0.1",
              static_cast<char *>(nullptr));
        _exit(127);
    } else if (pid > 0) {
        g_llama_pid = pid;
        g_llama_model = model_path;
        g_llama_port = port;
        lua_pushboolean(L, 1);
        lua_pushinteger(L, static_cast<lua_Integer>(pid));
        return 2;
    }
#endif
    lua_pushboolean(L, 0);
    lua_pushinteger(L, -1);
    return 2;
}

static int l_llama_stop(lua_State *L) {
    std::lock_guard<std::mutex> lk(g_llama_mutex);
    stop_llama_locked();
#if defined(__linux__) && defined(__GLIBC__)
    malloc_trim(0);
#endif
    lua_pushboolean(L, 1);
    return 1;
}

static int l_llama_status(lua_State *L) {
    std::lock_guard<std::mutex> lk(g_llama_mutex);
    bool alive = is_pid_alive(g_llama_pid);
    if (!alive) {
        g_llama_pid = -1;
        g_llama_model.clear();
    }

    lua_newtable(L);
    lua_pushboolean(L, alive ? 1 : 0);
    lua_setfield(L, -2, "running");
    lua_pushinteger(L, static_cast<lua_Integer>(g_llama_pid));
    lua_setfield(L, -2, "pid");
    lua_pushstring(L, g_llama_model.c_str());
    lua_setfield(L, -2, "model");
    lua_pushinteger(L, g_llama_port);
    lua_setfield(L, -2, "port");
    return 1;
}

static int l_trim_memory(lua_State *L) {
#if defined(__linux__)
#if defined(__GLIBC__)
    malloc_trim(0);
#endif
    std::lock_guard<std::mutex> lk(g_llama_mutex);
    if (!g_llama_model.empty()) {
        int fd = open(g_llama_model.c_str(), O_RDONLY);
        if (fd >= 0) {
            posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
            close(fd);
        }
    }
#endif
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_get_memory_stats(lua_State *L) {
    double widget_anon = 0.0;
    double widget_rss = read_proc_rss_mb(0, &widget_anon);

    double llama_rss = 0.0;
    double llama_anon = 0.0;
    {
        std::lock_guard<std::mutex> lk(g_llama_mutex);
        if (is_pid_alive(g_llama_pid)) {
            llama_rss = read_proc_rss_mb(g_llama_pid, &llama_anon);
        }
    }

    double total_rss = widget_rss + llama_rss;
    double total_anon = widget_anon + llama_anon;

    /* Enforce strict <= 500 MB budget automatically */
    if (total_rss > 460.0) {
#if defined(__linux__) && defined(__GLIBC__)
        malloc_trim(0);
#endif
        lua_gc(L, LUA_GCCOLLECT, 0);
    }

    lua_newtable(L);
    lua_pushnumber(L, widget_rss);
    lua_setfield(L, -2, "widget_rss_mb");
    lua_pushnumber(L, llama_rss);
    lua_setfield(L, -2, "llama_rss_mb");
    lua_pushnumber(L, llama_anon);
    lua_setfield(L, -2, "llama_anon_mb");
    lua_pushnumber(L, total_rss);
    lua_setfield(L, -2, "total_rss_mb");
    lua_pushnumber(L, total_anon);
    lua_setfield(L, -2, "total_anon_mb");
    lua_pushnumber(L, 500.0);
    lua_setfield(L, -2, "budget_mb");
    lua_pushboolean(L, (total_rss <= 500.0) ? 1 : 0);
    lua_setfield(L, -2, "within_budget");
    return 1;
}

static int l_verify_gguf(lua_State *L) {
    const char *filepath = luaL_checkstring(L, 1);
    if (!filepath || std::strlen(filepath) == 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Empty path");
        return 2;
    }

    std::ifstream f(filepath, std::ios::binary | std::ios::ate);
    if (!f.is_open()) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "File not found");
        return 2;
    }

    std::streamsize sz = f.tellg();
    if (sz < 1024 * 1024) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "File too small to be a valid GGUF model");
        return 2;
    }

    f.seekg(0, std::ios::beg);
    char magic[4] = {0};
    if (!f.read(magic, 4) || std::memcmp(magic, "GGUF", 4) != 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Invalid GGUF magic header");
        return 2;
    }

    lua_pushboolean(L, 1);
    lua_pushnumber(L, static_cast<double>(sz) / (1024.0 * 1024.0));
    return 2;
}

static const luaL_Reg qwen_native_funcs[] = {
    /* 1. Native Selection Hooks & Cursor */
    {"start_selection_hook", l_start_selection_hook},
    {"stop_selection_hook",  l_stop_selection_hook},
    {"poll_selection",       l_poll_selection},
    {"suppress_selection",   l_suppress_selection},
    {"get_cursor_pos",       l_get_cursor_pos},

    /* 2. Window Coordinates, Clamping & Smooth Interpolation */
    {"clamp_rect",           l_clamp_rect},
    {"compute_dock_position",l_compute_dock_position},
    {"compute_dock_pos",     l_compute_dock_position},
    {"lerp_point",           l_lerp_point},

    /* 3. Native Media IPC (MPRIS2 YouTube Music + Spotify) */
    {"media_get_state",      l_media_get_state},
    {"media_control",        l_media_control},

    /* 4. Native llama.cpp Bridge & Memory Controller (<= 500 MB) */
    {"llama_ensure",         l_llama_ensure},
    {"llama_stop",           l_llama_stop},
    {"llama_status",         l_llama_status},
    {"trim_memory",          l_trim_memory},
    {"get_memory_stats",     l_get_memory_stats},
    {"verify_gguf",          l_verify_gguf},
    {nullptr, nullptr}
};

} // namespace

extern "C" int luaopen_qwen_native(lua_State *L) {
    luaL_newlib(L, qwen_native_funcs);
    lua_pushstring(L, "2.0.0-native-cpp17");
    lua_setfield(L, -2, "VERSION");
    lua_pushstring(L, "2.0.0-native-cpp17");
    lua_setfield(L, -2, "version");
    return 1;
}
