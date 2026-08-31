//! Global hooks for monitoring input events, focus changes, and mouse tracking.

const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const overlay = @import("overlay.zig");
const geometry = @import("geometry.zig");
const caret = @import("caret.zig");
const c = win.c;

pub const ID_TIMER_DELAYED_CHECK: usize = config.TIMER_DEBOUNCE_CHECK;

var g_kb_hook: c.HHOOK = null;
var g_mouse_hook: c.HHOOK = null;
var g_win_hook: c.HWINEVENTHOOK = null;
var g_hwnd_host: c.HWND = null;
var g_instance: c.HINSTANCE = null;
var g_window_changed: bool = false;
var g_current_mode: config.IndicatorMode = .caret_focus;

pub var g_last_click_point: ?geometry.Point = null;
pub var g_last_click_hwnd: c.HWND = null;

/// Synchronizes working mode with the hook engine.
pub fn setMode(mode: config.IndicatorMode) void {
    g_current_mode = mode;
}

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
                c.VK_PROCESSKEY,
                => {
                    requestCheck(@intCast(config.debounce_key_ms));
                },
                else => {},
            }
        } else if (is_down) {
            if (kbd.vkCode == c.VK_CAPITAL) {
                requestCheck(@intCast(config.debounce_key_ms));
            }
        }
    }
    return c.CallNextHookEx(g_kb_hook, code, wparam, lparam);
}

/// Low-level mouse hook callback.
fn lowLevelMouseProc(code: c_int, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (code >= 0) {
        const mouse: *c.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (wparam == c.WM_LBUTTONDOWN or wparam == c.WM_LBUTTONUP or wparam == c.WM_RBUTTONDOWN) {
            g_last_click_point = geometry.Point{ .x = mouse.pt.x, .y = mouse.pt.y };
            g_last_click_hwnd = c.WindowFromPoint(mouse.pt);
            caret.invalidateCaretCache();
        } else if (wparam == c.WM_MOUSEMOVE) {
            // ONLY update position during mouse_follow mode; strictly avoid waking up overlay in caret_focus mode
            if (g_current_mode == .mouse_follow) {
                overlay.updateMousePosition(mouse.pt.x, mouse.pt.y);
            }
        }
    }
    return c.CallNextHookEx(g_mouse_hook, code, wparam, lparam);
}

/// Win32 global system event hook callback.
fn winEventProc(
    _: c.HWINEVENTHOOK,
    event: c.DWORD,
    _: c.HWND,
    _: c.LONG,
    _: c.LONG,
    _: c.DWORD,
    _: c.DWORD,
) callconv(.winapi) void {
    if (event == c.EVENT_SYSTEM_FOREGROUND or event == c.EVENT_OBJECT_FOCUS) {
        g_window_changed = true;
        caret.invalidateCaretCache();
        requestCheck(@intCast(config.debounce_window_ms));
    }
}

/// Installs keyboard, mouse, and window event hooks.
pub fn installHooks(hwnd_host: c.HWND, instance: c.HINSTANCE, initial_mode: config.IndicatorMode) void {
    g_hwnd_host = hwnd_host;
    g_instance = instance;
    g_current_mode = initial_mode;

    g_kb_hook = c.SetWindowsHookExW(c.WH_KEYBOARD_LL, lowLevelKeyboardProc, instance, 0);
    g_mouse_hook = c.SetWindowsHookExW(c.WH_MOUSE_LL, lowLevelMouseProc, instance, 0);

    g_win_hook = c.SetWinEventHook(
        c.EVENT_SYSTEM_FOREGROUND,
        c.EVENT_OBJECT_FOCUS,
        null,
        winEventProc,
        0,
        0,
        c.WINEVENT_OUTOFCONTEXT | c.WINEVENT_SKIPOWNPROCESS,
    );
}

/// Uninstalls all installed global hooks.
pub fn uninstallHooks() void {
    if (g_mouse_hook) |hook| {
        _ = c.UnhookWindowsHookEx(hook);
        g_mouse_hook = null;
    }
    if (g_kb_hook) |hk| {
        _ = c.UnhookWindowsHookEx(hk);
        g_kb_hook = null;
    }
    if (g_win_hook) |wh| {
        _ = c.UnhookWinEvent(wh);
        g_win_hook = null;
    }
}
