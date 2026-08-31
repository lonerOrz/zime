//! Multi-tier text caret detection strategy across Win32, Thread-Attach IMM32/Caret, MSAA, and UI Automation.

const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const hook = @import("hook.zig");
const c = win.c;

var g_uia: ?*win.IUIAutomation = null;
var g_uia_inited: bool = false;

/// Result structure describing screen anchor coordinate and detection source.
pub const AnchorResult = struct {
    point: geometry.Point,
    is_caret: bool,
};

/// Resets cached caret state (compatibility stub).
pub fn invalidateCaretCache() void {}

/// Initializes UI Automation singleton instance with fallback handling.
fn ensureUia() bool {
    if (g_uia_inited) return g_uia != null;
    g_uia_inited = true;

    _ = win.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);

    const hr = win.CoCreateInstance(
        &win.CLSID_CUIAutomation8,
        null,
        c.CLSCTX_INPROC_SERVER,
        &win.IID_IUIAutomation,
        @ptrCast(&g_uia),
    );
    if (hr != 0 or g_uia == null) {
        _ = win.CoCreateInstance(
            &win.CLSID_CUIAutomation,
            null,
            c.CLSCTX_INPROC_SERVER,
            &win.IID_IUIAutomation,
            @ptrCast(&g_uia),
        );
    }

    if (g_uia) |uia| {
        var uia2: ?*win.IUIAutomation2 = null;
        if (uia.lpVtbl.QueryInterface(uia, &win.IID_IUIAutomation2, @ptrCast(&uia2)) == 0 and uia2 != null) {
            defer _ = uia2.?.lpVtbl.Release(uia2.?);
            _ = uia2.?.lpVtbl.put_ConnectionTimeout(uia2.?, config.uia_ipc_timeout_ms);
            _ = uia2.?.lpVtbl.put_TransactionTimeout(uia2.?, config.uia_ipc_timeout_ms);
        }
    }
    return g_uia != null;
}

pub fn deinit() void {
    if (g_uia) |u| {
        _ = u.lpVtbl.Release(u);
        g_uia = null;
    }
    if (g_uia_inited) {
        win.CoUninitialize();
        g_uia_inited = false;
    }
}

/// Resolves screen coordinates of the active text caret or smart fallback location.
pub fn resolveAnchor(dpi_scale: f32, text_width: i32) ?AnchorResult {
    const hwnd_fg = c.GetForegroundWindow() orelse return getSmartFallback(null, dpi_scale, text_width);

    var target_tid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd_fg, &target_tid);

    // --- Tier 1: Win32 native caret (system-wide active thread prioritized) ---
    var gui_info = std.mem.zeroes(c.GUITHREADINFO);
    gui_info.cbSize = @sizeOf(c.GUITHREADINFO);

    var has_caret = false;
    if (c.GetGUIThreadInfo(0, &gui_info) != 0 and gui_info.hwndCaret != null) {
        has_caret = true;
    } else if (target_tid != 0 and c.GetGUIThreadInfo(target_tid, &gui_info) != 0 and gui_info.hwndCaret != null) {
        has_caret = true;
    }

    const hwnd_focus = if (gui_info.hwndFocus != null) gui_info.hwndFocus else hwnd_fg;

    // --- Tier 1: Win32 native caret ---
    if (has_caret and gui_info.hwndCaret != null) {
        const rc = gui_info.rcCaret;
        if ((rc.bottom - rc.top > 0) or (rc.right - rc.left > 0)) {
            var pt = c.POINT{
                .x = rc.left,
                .y = rc.bottom + geometry.scaleInt(config.caret_bottom_gap, dpi_scale),
            };
            _ = c.ClientToScreen(gui_info.hwndCaret.?, &pt);
            if (pt.x != 0 or pt.y != 0) {
                return .{
                    .point = clampWithMonitor(.{ .x = pt.x, .y = pt.y }, dpi_scale, text_width),
                    .is_caret = true,
                };
            }
        }
    }

    // --- Tier 2: Attached thread caret and cross-thread IMM32 context (covers Zed typing) ---
    if (target_tid != 0) {
        if (queryAttachedThread(target_tid, hwnd_focus, hwnd_fg)) |t_pt| {
            var pt = t_pt;
            pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
            return .{
                .point = clampWithMonitor(pt, dpi_scale, text_width),
                .is_caret = true,
            };
        }
    }

    // --- Tier 3: Direct IMM32 composition and candidate window ---
    const imm_targets = [_]?c.HWND{ hwnd_focus, hwnd_fg, gui_info.hwndCaret };
    for (imm_targets) |t_opt| {
        if (t_opt) |target_hwnd| {
            if (queryImmCaret(target_hwnd)) |imm_pt| {
                var pt = imm_pt;
                pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
                return .{
                    .point = clampWithMonitor(pt, dpi_scale, text_width),
                    .is_caret = true,
                };
            }
        }
    }

    // --- Tier 4: MSAA caret object ---
    if (hwnd_focus != null) {
        if (queryMsaaCaret(hwnd_focus)) |msaa_pt| {
            var pt = msaa_pt;
            pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
            return .{
                .point = clampWithMonitor(pt, dpi_scale, text_width),
                .is_caret = true,
            };
        }
    }
    if (hwnd_fg != null and hwnd_fg != hwnd_focus) {
        if (queryMsaaCaret(hwnd_fg)) |msaa_pt| {
            var pt = msaa_pt;
            pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
            return .{
                .point = clampWithMonitor(pt, dpi_scale, text_width),
                .is_caret = true,
            };
        }
    }

    // --- Tier 5: UI Automation (File Explorer search box, VS Code, Chrome, Terminal) ---
    if (queryUiaCaret(hwnd_focus, hwnd_fg, dpi_scale)) |uia_pt| {
        var pt = uia_pt;
        pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
        return .{
            .point = clampWithMonitor(pt, dpi_scale, text_width),
            .is_caret = true,
        };
    }

    // --- Tier 6: Dynamic smart fallback (Desktop, non-caret windows, or raw cursor) ---
    return getSmartFallback(hwnd_fg, dpi_scale, text_width);
}

/// Queries caret and IMM32 candidate/composition under thread attachment.
fn queryAttachedThread(target_tid: c.DWORD, hwnd_focus: c.HWND, hwnd_fg: c.HWND) ?geometry.Point {
    const current_tid = c.GetCurrentThreadId();
    if (target_tid == current_tid) return null;

    if (c.AttachThreadInput(current_tid, target_tid, c.TRUE) != 0) {
        defer _ = c.AttachThreadInput(current_tid, target_tid, c.FALSE);

        const raw_focus = c.GetFocus();
        const focus_wnd = if (raw_focus != null and c.IsWindow(raw_focus) != 0) raw_focus else hwnd_focus;

        // Check thread Win32 caret
        var pt = c.POINT{ .x = 0, .y = 0 };
        if (c.GetCaretPos(&pt) != 0 and (pt.x != 0 or pt.y != 0)) {
            _ = c.ClientToScreen(focus_wnd, &pt);
            if (pt.x != 0 or pt.y != 0) return .{ .x = pt.x, .y = pt.y };
        }

        // Check thread-attached IMM32 context
        const targets = [_]c.HWND{ focus_wnd, hwnd_fg };
        for (targets) |target| {
            if (queryImmCaret(target)) |imm_pt| return imm_pt;
        }
    }
    return null;
}

/// Queries IMM32 candidate and composition forms for caret location.
fn queryImmCaret(hwnd: c.HWND) ?geometry.Point {
    if (c.IsWindow(hwnd) == 0) return null;

    const himc = c.ImmGetContext(hwnd) orelse return null;
    defer _ = c.ImmReleaseContext(hwnd, himc);

    var i: c.DWORD = 0;
    while (i < 4) : (i += 1) {
        var cand = std.mem.zeroes(c.CANDIDATEFORM);
        cand.dwIndex = i;
        if (c.ImmGetCandidateWindow(himc, i, &cand) != 0) {
            if (cand.dwStyle == c.CFS_EXCLUDE) {
                const w = cand.rcArea.right - cand.rcArea.left;
                const h = cand.rcArea.bottom - cand.rcArea.top;
                if (w > 0 and h > 0) {
                    var pt = c.POINT{ .x = cand.rcArea.left, .y = cand.rcArea.bottom };
                    _ = c.ClientToScreen(hwnd, &pt);
                    return .{ .x = pt.x, .y = pt.y };
                }
            } else if (cand.ptCurrentPos.x != 0 or cand.ptCurrentPos.y != 0) {
                var pt = cand.ptCurrentPos;
                _ = c.ClientToScreen(hwnd, &pt);
                if (pt.x != 0 or pt.y != 0) return .{ .x = pt.x, .y = pt.y };
            }
        }
    }

    var form = std.mem.zeroes(c.COMPOSITIONFORM);
    if (c.ImmGetCompositionWindow(himc, &form) != 0) {
        if (form.dwStyle == c.CFS_RECT) {
            const w = form.rcArea.right - form.rcArea.left;
            const h = form.rcArea.bottom - form.rcArea.top;
            if (w > 0 and h > 0) {
                var pt = c.POINT{ .x = form.rcArea.left, .y = form.rcArea.bottom };
                _ = c.ClientToScreen(hwnd, &pt);
                return .{ .x = pt.x, .y = pt.y };
            }
        } else if (form.ptCurrentPos.x != 0 or form.ptCurrentPos.y != 0) {
            var pt = form.ptCurrentPos;
            _ = c.ClientToScreen(hwnd, &pt);
            if (pt.x != 0 or pt.y != 0) return .{ .x = pt.x, .y = pt.y };
        }
    }

    return null;
}

/// Queries accessible caret location using Microsoft Active Accessibility (MSAA).
fn queryMsaaCaret(hwnd: c.HWND) ?geometry.Point {
    var p_acc: ?*anyopaque = null;
    if (win.AccessibleObjectFromWindow(hwnd, win.OBJID_CARET, &win.IID_IAccessible, &p_acc) != 0 or p_acc == null) {
        return null;
    }
    const acc: *win.IAccessible = @ptrCast(@alignCast(p_acc.?));
    defer _ = acc.lpVtbl.Release(acc);

    var x: c.LONG = 0;
    var y: c.LONG = 0;
    var w: c.LONG = 0;
    var h: c.LONG = 0;

    var vt = std.mem.zeroes(c.VARIANT);
    @as(*align(@alignOf(c.VARIANT)) u16, @ptrCast(&vt)).* = 3;

    if (acc.lpVtbl.accLocation(acc, &x, &y, &w, &h, vt) == 0 and h > 0) {
        if (x != 0 or y != 0) {
            return .{ .x = x, .y = y + h };
        }
    }
    return null;
}

/// Queries UI Automation text patterns and element bounding rectangles.
fn queryUiaCaret(hwnd_focus: ?c.HWND, hwnd_fg: ?c.HWND, dpi_scale: f32) ?geometry.Point {
    if (!ensureUia()) return null;
    const uia = g_uia orelse return null;

    var elem: ?*win.IUIAutomationElement = null;
    _ = uia.lpVtbl.GetFocusedElement(uia, &elem);

    if (elem == null and hwnd_focus != null) {
        _ = uia.lpVtbl.ElementFromHandle(uia, hwnd_focus.?, &elem);
    }
    if (elem == null and hwnd_fg != null) {
        _ = uia.lpVtbl.ElementFromHandle(uia, hwnd_fg.?, &elem);
    }

    const focused = elem orelse return null;
    defer _ = focused.lpVtbl.Release(focused);

    // Try TextPattern2
    var tp2_ptr: ?*anyopaque = null;
    if (focused.lpVtbl.GetCurrentPatternAs(focused, win.UIA_TextPattern2Id, &win.IID_IUIAutomationTextPattern2, &tp2_ptr) == 0 and tp2_ptr != null) {
        const tp2: *win.IUIAutomationTextPattern2 = @ptrCast(@alignCast(tp2_ptr.?));
        defer _ = tp2.lpVtbl.Release(tp2);

        var is_active: c.BOOL = 0;
        var caret_range: ?*win.IUIAutomationTextRange = null;
        if (tp2.lpVtbl.GetCaretRange(tp2, &is_active, &caret_range) == 0 and caret_range != null) {
            defer _ = caret_range.?.lpVtbl.Release(caret_range.?);
            if (getPointFromRange(caret_range.?)) |pt| return pt;
        }
    }

    // Try TextPattern
    var tp_ptr: ?*anyopaque = null;
    if (focused.lpVtbl.GetCurrentPatternAs(focused, win.UIA_TextPatternId, &win.IID_IUIAutomationTextPattern, &tp_ptr) == 0 and tp_ptr != null) {
        const tp: *win.IUIAutomationTextPattern = @ptrCast(@alignCast(tp_ptr.?));
        defer _ = tp.lpVtbl.Release(tp);

        var selection_array: ?*win.IUIAutomationTextRangeArray = null;
        if (tp.lpVtbl.GetSelection(tp, &selection_array) == 0 and selection_array != null) {
            defer _ = selection_array.?.lpVtbl.Release(selection_array.?);

            var count: c_int = 0;
            _ = selection_array.?.lpVtbl.get_Length(selection_array.?, &count);
            if (count > 0) {
                var range: ?*win.IUIAutomationTextRange = null;
                if (selection_array.?.lpVtbl.GetElement(selection_array.?, 0, &range) == 0 and range != null) {
                    defer _ = range.?.lpVtbl.Release(range.?);
                    if (getPointFromRange(range.?)) |pt| return pt;
                }
            }
        }
    }

    // 3. Fallback: Element bounding box (covers empty edit/search controls like File Explorer search box)
    var rc_elem = std.mem.zeroes(c.RECT);
    if (focused.lpVtbl.get_CurrentBoundingRectangle(focused, &rc_elem) == 0) {
        const ew = rc_elem.right - rc_elem.left;
        const eh = rc_elem.bottom - rc_elem.top;
        if (ew > 0 and eh > 0 and ew < 1200 and eh < 200) {
            return geometry.Point{
                .x = rc_elem.left + geometry.scaleInt(4, dpi_scale),
                .y = rc_elem.bottom,
            };
        }
    }

    return null;
}
fn getPointFromRange(range: *win.IUIAutomationTextRange) ?geometry.Point {
    var psa: ?*win.SafeArray = null;
    _ = range.lpVtbl.GetBoundingRectangles(range, &psa);

    if (psa == null or psa.?.cDims < 1 or psa.?.rgsabound[0].cElements < 4) {
        if (psa) |p| _ = win.SafeArrayDestroy(p);
        psa = null;
        _ = range.lpVtbl.ExpandToEnclosingUnit(range, win.TextUnit_Character);
        _ = range.lpVtbl.GetBoundingRectangles(range, &psa);
    }

    if (psa == null) return null;
    defer _ = win.SafeArrayDestroy(psa.?);

    if (psa.?.cDims < 1 or psa.?.cbElements != 8 or psa.?.rgsabound[0].cElements < 4) return null;

    var p_data: ?*anyopaque = null;
    if (win.SafeArrayAccessData(psa.?, &p_data) != 0 or p_data == null) return null;
    defer _ = win.SafeArrayUnaccessData(psa.?);

    const bounds: [*]f64 = @ptrCast(@alignCast(p_data.?));
    const bx = bounds[0];
    const by = bounds[1];
    const bw = bounds[2];
    const bh = bounds[3];

    if (!std.math.isFinite(bx) or !std.math.isFinite(by) or !std.math.isFinite(bh)) return null;
    if (bx == 0 and by == 0 and bw == 0 and bh == 0) return null;
    if (bh <= 0 or bh > 4096) return null;

    return .{ .x = @intFromFloat(bx), .y = @intFromFloat(by + bh) };
}

/// Dynamically determines fallback coordinates using active cursor position or last click.
fn getSmartFallback(hwnd_fg: ?c.HWND, dpi_scale: f32, text_width: i32) ?AnchorResult {
    // 1. Check last-clicked position within the foreground window
    if (hook.g_last_click_hwnd) |click_hwnd| {
        if (hook.g_last_click_point != null and hwnd_fg != null) {
            const fg_hwnd = hwnd_fg.?;
            if (c.IsWindow(click_hwnd) != 0 and (click_hwnd == fg_hwnd or c.GetAncestor(click_hwnd, win.GA_ROOT) == fg_hwnd)) {
                const last_pt = hook.g_last_click_point.?;
                const pt = geometry.Point{
                    .x = last_pt.x + geometry.scaleInt(config.mouse_offset_x, dpi_scale),
                    .y = last_pt.y + geometry.scaleInt(config.mouse_offset_y, dpi_scale),
                };
                return .{ .point = clampWithMonitor(pt, dpi_scale, text_width), .is_caret = false };
            }
        }
    }

    // 2. Real-time dynamic mouse position (Desktop & non-caret windows)
    var mouse_pt = c.POINT{ .x = 0, .y = 0 };
    if (c.GetCursorPos(&mouse_pt) != 0) {
        const pt = geometry.Point{
            .x = mouse_pt.x + geometry.scaleInt(config.mouse_offset_x, dpi_scale),
            .y = mouse_pt.y + geometry.scaleInt(config.mouse_offset_y, dpi_scale),
        };
        return .{ .point = clampWithMonitor(pt, dpi_scale, text_width), .is_caret = false };
    }
    return null;
}

fn clampWithMonitor(pt: geometry.Point, dpi_scale: f32, text_width: i32) geometry.Point {
    const hmon = c.MonitorFromPoint(c.POINT{ .x = pt.x, .y = pt.y }, c.MONITOR_DEFAULTTONEAREST);
    var mi = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(hmon, &mi) != 0) {
        return geometry.clampToWorkArea(pt, dpi_scale, .{
            .left = mi.rcWork.left,
            .top = mi.rcWork.top,
            .right = mi.rcWork.right,
            .bottom = mi.rcWork.bottom,
        }, text_width);
    }
    return pt;
}
