//! Multi-tier text caret detection strategy across Win32, IMM32, MSAA, and UI Automation.

const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const c = win.c;

var g_uia: ?*win.IUIAutomation = null;
var g_uia_inited: bool = false;

pub const AnchorResult = struct {
    point: geometry.Point,
    is_caret: bool,
};

/// Ensures UI Automation COM singleton is initialized with timeout.
fn ensureUia() bool {
    if (g_uia_inited) return g_uia != null;
    g_uia_inited = true;

    _ = win.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    _ = win.CoCreateInstance(
        &win.CLSID_CUIAutomation,
        null,
        c.CLSCTX_INPROC_SERVER,
        &win.IID_IUIAutomation,
        @ptrCast(&g_uia),
    );

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

/// Releases global UI Automation instance.
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

/// Resolves the screen anchor point using a 5-tier strategy.
pub fn resolveAnchor(dpi_scale: f32, text_width: i32) ?AnchorResult {
    const hwnd_fg = c.GetForegroundWindow() orelse return getMouseFallback(dpi_scale, text_width);

    var gui_info = std.mem.zeroes(c.GUITHREADINFO);
    gui_info.cbSize = @sizeOf(c.GUITHREADINFO);
    const has_gui = (c.GetGUIThreadInfo(0, &gui_info) != 0);

    const hwnd_focus = if (has_gui and gui_info.hwndFocus != null) gui_info.hwndFocus else hwnd_fg;
    const hwnd_caret = if (has_gui) gui_info.hwndCaret else null;

    // --- Tier 1: Win32 native caret ---
    if (hwnd_caret != null) {
        const rc = gui_info.rcCaret;
        if ((rc.bottom - rc.top > 0) or (rc.right - rc.left > 0)) {
            var pt = c.POINT{
                .x = rc.left,
                .y = rc.bottom + geometry.scaleInt(config.caret_bottom_gap, dpi_scale),
            };
            _ = c.ClientToScreen(hwnd_caret, &pt);
            if (pt.x != 0 or pt.y != 0) {
                return .{
                    .point = clampWithMonitor(.{ .x = pt.x, .y = pt.y }, dpi_scale, text_width),
                    .is_caret = true,
                };
            }
        }
    }

    // --- Tier 2: MSAA accessible caret (QQ NT, Chrome, Electron, VS Code) ---
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

    // --- Tier 3: IMM32 composition window ---
    if (hwnd_focus != null) {
        if (queryImmCaret(hwnd_focus)) |imm_pt| {
            var pt = imm_pt;
            pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
            return .{
                .point = clampWithMonitor(pt, dpi_scale, text_width),
                .is_caret = true,
            };
        }
    }

    // --- Tier 4: UI Automation TextPattern2 / TextPattern (modern Notepad, Windows Terminal) ---
    if (queryUiaCaret()) |uia_pt| {
        var pt = uia_pt;
        pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
        return .{
            .point = clampWithMonitor(pt, dpi_scale, text_width),
            .is_caret = true,
        };
    }

    // --- Fallback: mouse cursor position ---
    return getMouseFallback(dpi_scale, text_width);
}

fn getMouseFallback(dpi_scale: f32, text_width: i32) ?AnchorResult {
    var mouse_pt = c.POINT{ .x = 0, .y = 0 };
    if (c.GetCursorPos(&mouse_pt) != 0) {
        const fallback = geometry.Point{
            .x = mouse_pt.x + geometry.scaleInt(config.mouse_offset_x, dpi_scale),
            .y = mouse_pt.y + geometry.scaleInt(config.mouse_offset_y, dpi_scale),
        };
        return .{
            .point = clampWithMonitor(fallback, dpi_scale, text_width),
            .is_caret = false,
        };
    }
    return null;
}

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
    @as(*align(@alignOf(c.VARIANT)) u16, @ptrCast(&vt)).* = 3; // VT_I4

    if (acc.lpVtbl.accLocation(acc, &x, &y, &w, &h, vt) == 0 and h > 0) {
        if (x != 0 or y != 0) {
            return .{ .x = x, .y = y + h };
        }
    }
    return null;
}

fn queryImmCaret(hwnd: c.HWND) ?geometry.Point {
    const himc = c.ImmGetContext(hwnd) orelse return null;
    defer _ = c.ImmReleaseContext(hwnd, himc);

    var form = std.mem.zeroes(c.COMPOSITIONFORM);
    if (c.ImmGetCompositionWindow(himc, &form) != 0 and form.dwStyle != 0) {
        var pt = c.POINT{ .x = form.ptCurrentPos.x, .y = form.ptCurrentPos.y };
        _ = c.ClientToScreen(hwnd, &pt);
        if (pt.x != 0 or pt.y != 0) return .{ .x = pt.x, .y = pt.y };
    }
    return null;
}

fn queryUiaCaret() ?geometry.Point {
    if (!ensureUia()) return null;
    const uia = g_uia orelse return null;

    var elem: ?*win.IUIAutomationElement = null;
    if (uia.lpVtbl.GetFocusedElement(uia, &elem) != 0 or elem == null) return null;
    defer _ = elem.?.lpVtbl.Release(elem.?);

    // Try TextPattern2
    var tp2_ptr: ?*anyopaque = null;
    if (elem.?.lpVtbl.GetCurrentPatternAs(elem.?, win.UIA_TextPattern2Id, &win.IID_IUIAutomationTextPattern2, &tp2_ptr) == 0 and tp2_ptr != null) {
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
    if (elem.?.lpVtbl.GetCurrentPatternAs(elem.?, win.UIA_TextPatternId, &win.IID_IUIAutomationTextPattern, &tp_ptr) == 0 and tp_ptr != null) {
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
