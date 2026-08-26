const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const c = win.c;

// IMM32 constants omitted from standard MinGW headers
const IMC_GETCONVERSIONMODE = 0x0001;
const IMC_GETOPENSTATUS = 0x0005;
const WM_IME_CONTROL = 0x0283;
const SMTO_ABORTIFHUNG = 0x0002;
const IME_CMODE_NATIVE = 0x0001;

pub const ImeState = enum {
    chinese,
    english,
};

/// Queries the current IME state for the active or focused window.
pub fn queryCurrentState() ImeState {
    const hwnd_fg = c.GetForegroundWindow() orelse return .english;
    var fg_thread: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd_fg, &fg_thread);

    var hwnd_target = hwnd_fg;

    // Use focused child control if available
    var gui_info = std.mem.zeroes(c.GUITHREADINFO);
    gui_info.cbSize = @sizeOf(c.GUITHREADINFO);
    if (c.GetGUIThreadInfo(fg_thread, &gui_info) != 0 and gui_info.hwndFocus != null) {
        hwnd_target = gui_info.hwndFocus;
    }

    var h_ime = c.ImmGetDefaultIMEWnd(hwnd_target);
    if (h_ime == null and hwnd_target != hwnd_fg) {
        h_ime = c.ImmGetDefaultIMEWnd(hwnd_fg);
    }
    // No IME window available (e.g. exclusive fullscreen games, raw consoles)
    if (h_ime == null) return .english;

    // Check IME open/closed status
    var is_open: c.DWORD_PTR = 0;
    const res_open = c.SendMessageTimeoutW(
        h_ime,
        WM_IME_CONTROL,
        IMC_GETOPENSTATUS,
        0,
        SMTO_ABORTIFHUNG,
        config.ime_msg_timeout_ms,
        &is_open,
    );
    if (res_open != 0 and is_open == 0) {
        return .english;
    }

    // Check conversion mode (Native Chinese vs Alphanumeric)
    var conv_mode: c.DWORD_PTR = 0;
    const res_conv = c.SendMessageTimeoutW(
        h_ime,
        WM_IME_CONTROL,
        IMC_GETCONVERSIONMODE,
        0,
        SMTO_ABORTIFHUNG,
        config.ime_msg_timeout_ms,
        &conv_mode,
    );

    if (res_conv != 0) {
        return if ((@as(u32, @intCast(conv_mode)) & IME_CMODE_NATIVE) != 0) .chinese else .english;
    }

    return if (is_open != 0) .chinese else .english;
}
