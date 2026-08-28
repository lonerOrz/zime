//! Global hooks for monitoring input events and window focus changes.

const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const c = win.c;

pub const ID_TIMER_DELAYED_CHECK: usize = config.TIMER_DEBOUNCE_CHECK;

var g_kb_hook: c.HHOOK = null;
var g_win_hook: c.HWINEVENTHOOK = null;
var g_hwnd_host: c.HWND = null;
var g_window_changed: bool = false;

/// Consumes the global flag indicating if the foreground window has changed.
pub fn consumeWindowChange() bool {
    const changed = g_window_changed;
    g_window_changed = false;
    return changed;
}

/// Requests a debounced state check by posting a timer message to the host window.
fn requestCheck(delay_ms: c.UINT) void {
    if (g_hwnd_host != null) {
        _ = c.SetTimer(g_hwnd_host, ID_TIMER_DELAYED_CHECK, delay_ms, null);
    }
}

/// Low-level keyboard hook callback.
fn lowLevelKeyboardProc(code: c_int, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (code >= 0) {
        const kbd: *c.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const is_up = (wparam == c.WM_KEYUP or wparam == c.WM_SYSKEYUP);
        const is_down = (wparam == c.WM_KEYDOWN or wparam == c.WM_SYSKEYDOWN);

        if (is_up) {
            switch (kbd.vkCode) {
                c.VK_SHIFT,
                c.VK_LSHIFT,
                c.VK_RSHIFT,
                c.VK_CONTROL,
                c.VK_LCONTROL,
                c.VK_RCONTROL,
                c.VK_MENU,
                c.VK_LMENU,
                c.VK_RMENU,
                c.VK_LWIN,
                c.VK_RWIN,
                c.VK_SPACE,
                c.VK_CAPITAL,
                => {
                    requestCheck(@intCast(config.debounce_key_ms));
                },
                else => {},
            }
        } else if (is_down and kbd.vkCode == c.VK_CAPITAL) {
            requestCheck(@intCast(config.debounce_key_ms));
        }
    }
    return c.CallNextHookEx(g_kb_hook, code, wparam, lparam);
}

/// Win32 Global System Event hook callback.
fn winEventProc(
    _: c.HWINEVENTHOOK,
    _: c.DWORD,
    _: c.HWND,
    _: c.LONG,
    _: c.LONG,
    _: c.DWORD,
    _: c.DWORD,
) callconv(.winapi) void {
    g_window_changed = true;
    requestCheck(@intCast(config.debounce_window_ms));
}

/// Installs the global keyboard and window event hooks.
pub fn installHooks(hwnd_host: c.HWND, instance: c.HINSTANCE) void {
    g_hwnd_host = hwnd_host;
    g_kb_hook = c.SetWindowsHookExW(c.WH_KEYBOARD_LL, lowLevelKeyboardProc, instance, 0);
    g_win_hook = c.SetWinEventHook(
        c.EVENT_SYSTEM_FOREGROUND,
        c.EVENT_SYSTEM_FOREGROUND,
        null,
        winEventProc,
        0,
        0,
        c.WINEVENT_OUTOFCONTEXT | c.WINEVENT_SKIPOWNPROCESS,
    );
}

/// Uninstalls all installed global hooks.
pub fn uninstallHooks() void {
    if (g_kb_hook != null) {
        _ = c.UnhookWindowsHookEx(g_kb_hook);
        g_kb_hook = null;
    }
    if (g_win_hook != null) {
        _ = c.UnhookWinEvent(g_win_hook);
        g_win_hook = null;
    }
}
