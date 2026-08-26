const std = @import("std");
const ime = @import("ime.zig");
const hook = @import("hook.zig");
const overlay = @import("overlay.zig");
const config = @import("config.zig");
const win = @import("win.zig");
const c = win.c;

const WM_TRAY: c.UINT = config.WM_TRAY_CALLBACK;
const ID_TIMER_AUTOHIDE: usize = config.TIMER_AUTOHIDE;
const ID_TRAY_EXIT: usize = config.MENU_TRAY_EXIT;
const ID_TRAY_AUTOSTART: usize = config.MENU_TRAY_AUTOSTART;
const ID_TRAY_RESTART: usize = config.MENU_TRAY_RESTART;
const IDI_INFORMATION: usize = 32516;

var g_hwnd_main: c.HWND = null;
var g_nid: c.NOTIFYICONDATAW = undefined;
var g_last_state: ?ime.ImeState = null;
var g_h_mutex: ?c.HANDLE = null;

const run_subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const run_value_name = std.unicode.utf8ToUtf16LeStringLiteral("Zime");

const KEY_QUERY: u32 = 0x0001;
const KEY_SET: u32 = 0x0002;

/// Checks if autostart registry entry exists.
fn autostartEnabled() bool {
    var hk: *anyopaque = undefined;
    if (win.RegOpenKeyExW(win.HKCU_VALUE, run_subkey.ptr, 0, KEY_QUERY, &hk) != 0) return false;
    defer _ = win.RegCloseKey(hk);

    var value_type: u32 = 0;
    var cb: u32 = 0;
    return win.RegQueryValueExW(hk, run_value_name.ptr, null, &value_type, null, &cb) == 0;
}

/// Enables or disables login autostart via HKCU Run registry key.
fn setAutostart(enable: bool) void {
    var hk: *anyopaque = undefined;
    if (win.RegOpenKeyExW(win.HKCU_VALUE, run_subkey.ptr, 0, KEY_QUERY | KEY_SET, &hk) != 0) return;
    defer _ = win.RegCloseKey(hk);

    if (enable) {
        var path_buf: [260]u16 = undefined;
        const n = c.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (n == 0 or n >= path_buf.len - 2) return;

        // Wrap path with quotes for spaces support (e.g. "C:\Program Files\Zime\zime.exe")
        var quoted: [264]u16 = undefined;
        quoted[0] = '"';
        @memcpy(quoted[1 .. n + 1], path_buf[0..n]);
        quoted[n + 1] = '"';
        quoted[n + 2] = 0;

        // Include terminating null character (n + 3 u16 units)
        const bytes = (@as(u32, @intCast(n)) + 3) * @sizeOf(u16);
        _ = win.RegSetValueExW(hk, run_value_name.ptr, 0, 1, &quoted, bytes); // 1 = REG_SZ
    } else {
        _ = win.RegDeleteValueW(hk, run_value_name.ptr);
    }
}

/// Spawns a new instance and exits current process.
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

/// Main window procedure handling timers, tray callbacks, and commands.
fn windowProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_TIMER => {
            if (wparam == hook.ID_TIMER_DELAYED_CHECK) {
                _ = c.KillTimer(hwnd, hook.ID_TIMER_DELAYED_CHECK);

                const current = ime.queryCurrentState();
                if (g_last_state == null or g_last_state.? != current) {
                    g_last_state = current;
                    overlay.show(current);
                    _ = c.SetTimer(hwnd, ID_TIMER_AUTOHIDE, @intCast(config.autohide_duration_ms), null);
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
                _ = c.AppendMenuW(hmenu, item_flags, ID_TRAY_AUTOSTART, std.unicode.utf8ToUtf16LeStringLiteral("开机自启").ptr);
                _ = c.AppendMenuW(hmenu, c.MF_SEPARATOR, 0, null);
                _ = c.AppendMenuW(hmenu, c.MF_STRING, ID_TRAY_RESTART, std.unicode.utf8ToUtf16LeStringLiteral("重启 Zime").ptr);
                _ = c.AppendMenuW(hmenu, c.MF_STRING, ID_TRAY_EXIT, std.unicode.utf8ToUtf16LeStringLiteral("退出 Zime").ptr);
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
    // Initialize COM for UI Automation caret query
    _ = win.CoInitializeEx(null, 0x2); // COINIT_APARTMENTTHREADED
    defer win.CoUninitialize();

    // Enable Per-Monitor DPI Awareness V2
    _ = win.SetProcessDpiAwarenessContext(-4); // PER_MONITOR_AWARE_V2

    // Enforce single instance
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

    // Register and create hidden host window
    const main_cls = std.unicode.utf8ToUtf16LeStringLiteral("ZimeEventHost");
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = main_cls.ptr;
    _ = c.RegisterClassExW(&wc);
    g_hwnd_main = c.CreateWindowExW(0, main_cls.ptr, main_cls.ptr, 0, 0, 0, 0, 0, null, null, instance, null);

    overlay.init(instance);
    defer overlay.deinit();

    g_last_state = ime.queryCurrentState();

    // Setup system tray icon
    g_nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    g_nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    g_nid.hWnd = g_hwnd_main;
    g_nid.uID = 1;
    g_nid.uFlags = c.NIF_ICON | c.NIF_MESSAGE | c.NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;

    const cx_icon = c.GetSystemMetrics(c.SM_CXSMICON);
    g_nid.hIcon = overlay.createTrayIcon(cx_icon) orelse @ptrCast(@alignCast(c.LoadImageW(
        null,
        @as([*:0]const u16, @ptrFromInt(IDI_INFORMATION)),
        c.IMAGE_ICON,
        cx_icon,
        cx_icon,
        c.LR_SHARED,
    )));
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Zime 输入法指示器");
    @memcpy(g_nid.szTip[0..tip.len], tip);
    _ = c.Shell_NotifyIconW(c.NIM_ADD, &g_nid);

    hook.installHooks(g_hwnd_main, instance);
    defer hook.uninstallHooks();

    // Message loop
    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}
