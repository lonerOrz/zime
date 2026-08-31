//! Main application entry point, tray icon management, and message dispatcher.

const std = @import("std");
const ime = @import("ime.zig");
const hook = @import("hook.zig");
const overlay = @import("overlay.zig");
const config = @import("config.zig");
const win = @import("win.zig");
const i18n = @import("i18n.zig");
const c = win.c;

const WM_TRAY: c.UINT = config.WM_TRAY_CALLBACK;
const ID_TIMER_AUTOHIDE: usize = config.TIMER_AUTOHIDE;
const ID_TRAY_EXIT: usize = config.MENU_TRAY_EXIT;
const ID_TRAY_AUTOSTART: usize = config.MENU_TRAY_AUTOSTART;
const ID_TRAY_RESTART: usize = config.MENU_TRAY_RESTART;
const ID_TRAY_LANG_ZH: usize = config.MENU_TRAY_LANG_ZH;
const ID_TRAY_LANG_EN: usize = config.MENU_TRAY_LANG_EN;
const ID_TRAY_MODE_CARET: usize = config.MENU_TRAY_MODE_CARET;
const ID_TRAY_MODE_MOUSE: usize = config.MENU_TRAY_MODE_MOUSE;

fn makeResourcePtr(id: usize) [*c]const c_ushort {
    const u = union(enum) {
        i: usize,
        p: [*c]const c_ushort,
    };
    return @unionInit(u, "p", id).p;
}

var g_hwnd_main: c.HWND = null;
var g_nid: c.NOTIFYICONDATAW = undefined;
var g_last_state: ?ime.ImeState = null;
var g_h_mutex: ?c.HANDLE = null;
var g_instance: c.HINSTANCE = null;
var g_lang: i18n.Language = .auto;
var g_mode: config.IndicatorMode = .caret_focus;
var g_strs: i18n.Strings = undefined;

const run_subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const run_value_name = std.unicode.utf8ToUtf16LeStringLiteral("Zime");

const config_subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Zime");
const mode_value_name = std.unicode.utf8ToUtf16LeStringLiteral("mode");

const KEY_QUERY: u32 = 0x0001;
const KEY_SET: u32 = 0x0002;

fn autostartEnabled() bool {
    var hk: *anyopaque = undefined;
    if (win.RegOpenKeyExW(win.HKCU_VALUE, run_subkey.ptr, 0, KEY_QUERY, &hk) != 0) return false;
    defer _ = win.RegCloseKey(hk);

    var value_type: u32 = 0;
    var cb: u32 = 0;
    return win.RegQueryValueExW(hk, run_value_name.ptr, null, &value_type, null, &cb) == 0;
}

fn setAutostart(enable: bool) void {
    var hk: *anyopaque = undefined;
    if (win.RegOpenKeyExW(win.HKCU_VALUE, run_subkey.ptr, 0, KEY_QUERY | KEY_SET, &hk) != 0) return;
    defer _ = win.RegCloseKey(hk);

    if (enable) {
        var path_buf: [260]u16 = undefined;
        const n = c.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (n == 0 or n >= path_buf.len - 2) return;

        var quoted: [264]u16 = undefined;
        quoted[0] = '"';
        @memcpy(quoted[1 .. n + 1], path_buf[0..n]);
        quoted[n + 1] = '"';
        quoted[n + 2] = 0;

        const bytes = (@as(u32, @intCast(n)) + 3) * @sizeOf(u16);
        _ = win.RegSetValueExW(hk, run_value_name.ptr, 0, 1, &quoted, bytes);
    } else {
        _ = win.RegDeleteValueW(hk, run_value_name.ptr);
    }
}

fn setLanguage(lang: i18n.Language) void {
    g_lang = lang;
    g_strs = i18n.I18n.getStrings(lang);
    i18n.I18n.persistLanguage(lang);

    const tip = g_strs.tray_tooltip;
    const tip_len = std.mem.len(tip);
    @memset(g_nid.szTip[0..], 0);
    @memcpy(g_nid.szTip[0..tip_len], tip[0..tip_len]);
    _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &g_nid);

    overlay.setLanguage(lang);
    if (g_last_state) |state| {
        if (overlay.show(state, g_mode)) {
            if (g_mode == .caret_focus) {
                _ = c.SetTimer(g_hwnd_main, ID_TIMER_AUTOHIDE, @intCast(config.autohide_duration_ms), null);
            }
        }
    }
}

fn loadPersistedMode() config.IndicatorMode {
    var hk: *anyopaque = undefined;
    if (win.RegOpenKeyExW(win.HKCU_VALUE, config_subkey.ptr, 0, KEY_QUERY, &hk) != 0) return .caret_focus;
    defer _ = win.RegCloseKey(hk);

    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (win.RegQueryValueExW(hk, mode_value_name.ptr, null, null, &val, &cb) == 0) {
        return if (val == 1) .mouse_follow else .caret_focus;
    }
    return .caret_focus;
}

fn persistMode(mode: config.IndicatorMode) void {
    var hk: *anyopaque = undefined;
    if (win.RegCreateKeyExW(win.HKCU_VALUE, config_subkey.ptr, 0, null, 0, KEY_SET, null, &hk, null) != 0) return;
    defer _ = win.RegCloseKey(hk);

    const val: u32 = @intFromEnum(mode);
    _ = win.RegSetValueExW(hk, mode_value_name.ptr, 0, 4, &val, @sizeOf(u32));
}

fn setMode(mode: config.IndicatorMode) void {
    if (g_mode == mode) return;
    g_mode = mode;
    persistMode(mode);
    hook.setMode(mode);

    if (mode == .mouse_follow) {
        _ = c.KillTimer(g_hwnd_main, ID_TIMER_AUTOHIDE);
        const current = ime.queryCurrentState();
        g_last_state = current;
        _ = overlay.show(current, .mouse_follow);
    } else {
        _ = c.KillTimer(g_hwnd_main, ID_TIMER_AUTOHIDE);
        overlay.hide();
    }
}

fn restartSelf() void {
    var path_buf: [260]u16 = undefined;
    const n = c.GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (n == 0 or n >= path_buf.len) return;

    if (g_h_mutex) |m| {
        _ = c.CloseHandle(m);
        g_h_mutex = null;
    }

    var si = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi: c.PROCESS_INFORMATION = undefined;

    if (c.CreateProcessW(&path_buf, null, null, null, 0, 0, null, null, &si, &pi) != 0) {
        _ = c.CloseHandle(pi.hProcess);
        _ = c.CloseHandle(pi.hThread);
    }

    _ = c.DestroyWindow(g_hwnd_main);
}

fn windowProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_TIMER => {
            if (wparam == hook.ID_TIMER_DELAYED_CHECK) {
                _ = c.KillTimer(hwnd, hook.ID_TIMER_DELAYED_CHECK);

                const current = ime.queryCurrentState();
                g_last_state = current;

                if (g_mode == .caret_focus) {
                    _ = c.KillTimer(hwnd, ID_TIMER_AUTOHIDE);
                    if (overlay.show(current, .caret_focus)) {
                        _ = c.SetTimer(hwnd, ID_TIMER_AUTOHIDE, @intCast(config.autohide_duration_ms), null);
                    }
                } else {
                    _ = overlay.show(current, .mouse_follow);
                }
            } else if (wparam == ID_TIMER_AUTOHIDE) {
                _ = c.KillTimer(hwnd, ID_TIMER_AUTOHIDE);
                overlay.hide();
            }
        },
        WM_TRAY => {
            if (lparam == c.WM_RBUTTONUP or lparam == c.WM_LBUTTONDBLCLK) {
                var pt: c.POINT = undefined;
                _ = c.GetCursorPos(&pt);
                const hmenu = c.CreatePopupMenu();
                defer _ = c.DestroyMenu(hmenu);

                const item_flags: c.UINT = @intCast(if (autostartEnabled()) c.MF_CHECKED else c.MF_UNCHECKED);
                _ = c.AppendMenuW(hmenu, item_flags, ID_TRAY_AUTOSTART, g_strs.menu_autostart);
                _ = c.AppendMenuW(hmenu, c.MF_SEPARATOR, 0, null);

                // Mode radio selection
                const caret_checked: c.UINT = @intCast(if (g_mode == .caret_focus) c.MF_CHECKED else c.MF_UNCHECKED);
                const mouse_checked: c.UINT = @intCast(if (g_mode == .mouse_follow) c.MF_CHECKED else c.MF_UNCHECKED);
                _ = c.AppendMenuW(hmenu, caret_checked, ID_TRAY_MODE_CARET, g_strs.menu_mode_caret);
                _ = c.AppendMenuW(hmenu, mouse_checked, ID_TRAY_MODE_MOUSE, g_strs.menu_mode_mouse);
                _ = c.AppendMenuW(hmenu, c.MF_SEPARATOR, 0, null);

                // Language submenu
                if (c.CreatePopupMenu()) |hlang| {
                    const lang_checked_zh = if (g_lang == .zh_CN) c.MF_CHECKED else c.MF_UNCHECKED;
                    const lang_checked_en = if (g_lang == .en) c.MF_CHECKED else c.MF_UNCHECKED;
                    _ = c.AppendMenuW(hlang, @intCast(lang_checked_zh), ID_TRAY_LANG_ZH, std.unicode.utf8ToUtf16LeStringLiteral("中文").ptr);
                    _ = c.AppendMenuW(hlang, @intCast(lang_checked_en), ID_TRAY_LANG_EN, std.unicode.utf8ToUtf16LeStringLiteral("English").ptr);
                    _ = c.AppendMenuW(hmenu, @intCast(c.MF_POPUP), @intFromPtr(hlang), g_strs.menu_language);
                }

                _ = c.AppendMenuW(hmenu, c.MF_SEPARATOR, 0, null);
                _ = c.AppendMenuW(hmenu, c.MF_STRING, ID_TRAY_RESTART, g_strs.menu_restart);
                _ = c.AppendMenuW(hmenu, c.MF_STRING, ID_TRAY_EXIT, g_strs.menu_exit);

                _ = c.SetForegroundWindow(hwnd);
                _ = c.TrackPopupMenu(hmenu, c.TPM_BOTTOMALIGN | c.TPM_LEFTALIGN, pt.x, pt.y, 0, hwnd, null);
                _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
            }
        },
        c.WM_COMMAND => {
            switch (@as(u16, @truncate(wparam))) {
                ID_TRAY_EXIT => _ = c.DestroyWindow(hwnd),
                ID_TRAY_RESTART => restartSelf(),
                ID_TRAY_AUTOSTART => setAutostart(!autostartEnabled()),
                ID_TRAY_LANG_ZH => setLanguage(.zh_CN),
                ID_TRAY_LANG_EN => setLanguage(.en),
                ID_TRAY_MODE_CARET => setMode(.caret_focus),
                ID_TRAY_MODE_MOUSE => setMode(.mouse_follow),
                else => {},
            }
        },
        c.WM_DESTROY => {
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &g_nid);
            c.PostQuitMessage(0);
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

pub fn main() !void {
    _ = win.SetProcessDpiAwarenessContext(-4);

    g_h_mutex = c.CreateMutexW(null, c.TRUE, std.unicode.utf8ToUtf16LeStringLiteral("Zime_SingleInstance"));
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
        if (g_h_mutex) |m| _ = c.CloseHandle(m);
        g_h_mutex = null;
        return;
    }
    defer if (g_h_mutex) |m| {
        _ = c.CloseHandle(m);
    };

    const instance: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    g_instance = instance;

    const persisted = i18n.I18n.loadPersistedLanguage();
    const lang = i18n.I18n.resolveLanguage(persisted);
    g_lang = lang;
    g_strs = i18n.I18n.getStrings(lang);
    g_mode = loadPersistedMode();

    const raw_icon_big = c.LoadImageW(instance, makeResourcePtr(config.IDI_APP_ICON), c.IMAGE_ICON, 0, 0, c.LR_DEFAULTCOLOR);
    const h_icon_big: c.HICON = if (raw_icon_big) |h| @ptrFromInt(@intFromPtr(h)) else @ptrFromInt(0);

    const raw_icon_sm = c.LoadImageW(instance, makeResourcePtr(config.IDI_APP_ICON), c.IMAGE_ICON, 0, 0, c.LR_DEFAULTCOLOR);
    const h_icon_sm: c.HICON = if (raw_icon_sm) |h| @ptrFromInt(@intFromPtr(h)) else @ptrFromInt(0);

    const main_cls = std.unicode.utf8ToUtf16LeStringLiteral("ZimeEventHost");
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = main_cls.ptr;
    wc.hIcon = h_icon_big;
    wc.hIconSm = h_icon_sm;
    _ = c.RegisterClassExW(&wc);

    g_hwnd_main = c.CreateWindowExW(
        c.WS_EX_TOOLWINDOW | c.WS_EX_APPWINDOW,
        main_cls.ptr,
        main_cls.ptr,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    );

    overlay.init(instance, lang);
    defer overlay.deinit();

    g_nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    g_nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    g_nid.hWnd = g_hwnd_main;
    g_nid.uID = 1;
    g_nid.uFlags = c.NIF_ICON | c.NIF_MESSAGE | c.NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon = h_icon_sm;

    const tip = g_strs.tray_tooltip;
    const tip_len = std.mem.len(tip);
    @memcpy(g_nid.szTip[0..tip_len], tip[0..tip_len]);
    _ = c.Shell_NotifyIconW(c.NIM_ADD, &g_nid);

    hook.installHooks(g_hwnd_main, instance, g_mode);
    if (g_mode == .mouse_follow) {
        const current = ime.queryCurrentState();
        g_last_state = current;
        _ = overlay.show(current, .mouse_follow);
    }
    defer hook.uninstallHooks();

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}
