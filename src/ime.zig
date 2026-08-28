//! IME (Input Method Editor) state detection logic across Win32 and modern Windows applications.

const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const c = win.c;

const IMC_GETCONVERSIONMODE: c.WPARAM = 0x0001;
const IMC_GETOPENSTATUS: c.WPARAM = 0x0005;
const WM_IME_CONTROL: c.UINT = 0x0283;
const SMTO_ABORTIFHUNG: c.UINT = 0x0002;
const IME_CMODE_NATIVE: u32 = 0x0001;
const IME_CMODE_NOCONVERSION: u32 = 0x0100;

/// Input method state representation
pub const ImeState = enum {
    chinese,
    english,
};

/// Queries current IME state for active foreground control.
pub fn queryCurrentState() ImeState {
    const hwnd_fg = c.GetForegroundWindow() orelse return .english;

    // Retrieve active GUI thread across entire system
    var gui_info = std.mem.zeroes(c.GUITHREADINFO);
    gui_info.cbSize = @sizeOf(c.GUITHREADINFO);
    const has_gui = (c.GetGUIThreadInfo(0, &gui_info) != 0);

    const hwnd_focus = if (has_gui and gui_info.hwndFocus != null) gui_info.hwndFocus else hwnd_fg;

    // Get active thread ID of focused control
    var target_tid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd_focus, &target_tid);
    if (target_tid == 0) _ = c.GetWindowThreadProcessId(hwnd_fg, &target_tid);

    // 1. Check keyboard layout (HKL)
    var hkl = c.GetKeyboardLayout(target_tid);
    if (hkl == null) hkl = c.GetKeyboardLayout(0);
    const lang_id: u16 = @truncate(@intFromPtr(hkl));
    const primary_lang: u16 = lang_id & 0x03FF;

    // Non-CJK layouts are always English
    if (primary_lang != 0x04 and primary_lang != 0x11 and primary_lang != 0x12) {
        return .english;
    }

    // 2. Check Caps Lock
    if ((c.GetKeyState(c.VK_CAPITAL) & 0x0001) != 0) {
        return .english;
    }

    // 3. Query IME control window
    const targets = [_]?c.HWND{
        hwnd_focus,
        hwnd_fg,
        if (has_gui) gui_info.hwndCaret else null,
    };

    for (targets) |t_opt| {
        const target = t_opt orelse continue;
        const h_ime = c.ImmGetDefaultIMEWnd(target);
        if (h_ime == null) continue;

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

        if (res_open != 0 and is_open == 0) {
            return .english;
        }

        if (res_conv != 0) {
            const mode = @as(u32, @truncate(conv_mode));
            if ((mode & IME_CMODE_NOCONVERSION) != 0) return .english;
            if ((mode & IME_CMODE_NATIVE) != 0) {
                return .chinese;
            } else {
                return .english;
            }
        }

        if (res_open != 0 and is_open != 0) {
            return .chinese;
        }
    }

    // 4. Fallback for elevated or modern sandboxed windows
    if (primary_lang == 0x04) {
        return .chinese;
    }

    return .english;
}
