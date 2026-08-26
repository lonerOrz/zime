const std = @import("std");
const win = @import("win.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const c = win.c;

var g_uia: ?*win.IUIAutomation = null;

/// Initializes the UI Automation client and caps IPC timeout.
pub fn init() void {
    _ = win.CoCreateInstance(
        &win.CLSID_CUIAutomation,
        null,
        c.CLSCTX_INPROC_SERVER,
        &win.IID_IUIAutomation,
        @ptrCast(&g_uia),
    );

    // Limit cross-process IPC duration to prevent hook thread hangs
    if (g_uia) |uia| {
        var uia2: ?*win.IUIAutomation2 = null;
        if (uia.lpVtbl.QueryInterface(uia, &win.IID_IUIAutomation2, @ptrCast(&uia2)) == 0 and uia2 != null) {
            defer _ = uia2.?.lpVtbl.Release(uia2.?);
            _ = uia2.?.lpVtbl.put_ConnectionTimeout(uia2.?, config.uia_ipc_timeout_ms);
            _ = uia2.?.lpVtbl.put_TransactionTimeout(uia2.?, config.uia_ipc_timeout_ms);
        }
    }
}

/// Releases the global UI Automation instance.
pub fn deinit() void {
    if (g_uia) |u| {
        _ = u.lpVtbl.Release(u);
        g_uia = null;
    }
}

/// Resolves HUD anchor position: Win32 caret -> UIA selection -> Mouse cursor.
pub fn resolveAnchor(dpi_scale: f32) geometry.Point {
    const hwnd_fg = c.GetForegroundWindow();
    if (hwnd_fg != null) {
        var thread_id: c.DWORD = 0;
        _ = c.GetWindowThreadProcessId(hwnd_fg, &thread_id);

        // Tier 1: Classic Win32 caret (Notepad, standard edit controls)
        var gui_info = std.mem.zeroes(c.GUITHREADINFO);
        gui_info.cbSize = @sizeOf(c.GUITHREADINFO);
        if (c.GetGUIThreadInfo(thread_id, &gui_info) != 0) {
            const target_hwnd = if (gui_info.hwndCaret != null) gui_info.hwndCaret else gui_info.hwndFocus;
            if (target_hwnd != null and (gui_info.rcCaret.bottom - gui_info.rcCaret.top) > 0) {
                var pt = c.POINT{
                    .x = gui_info.rcCaret.left,
                    .y = gui_info.rcCaret.bottom + geometry.scaleInt(config.caret_bottom_gap, dpi_scale),
                };
                _ = c.ClientToScreen(target_hwnd, &pt);
                return clampWithMonitor(.{ .x = pt.x, .y = pt.y }, dpi_scale);
            }
        }

        // Tier 2: Modern apps (Chromium, VS Code, Windows Terminal) via UIA
        if (queryUiaCaret()) |uia_pt| {
            var pt = uia_pt;
            pt.y += geometry.scaleInt(config.caret_bottom_gap, dpi_scale);
            return clampWithMonitor(pt, dpi_scale);
        }
    }

    // Tier 3: Fallback near mouse cursor
    var mouse_pt: c.POINT = undefined;
    _ = c.GetCursorPos(&mouse_pt);
    const fallback = geometry.Point{
        .x = mouse_pt.x + geometry.scaleInt(config.mouse_offset_x, dpi_scale),
        .y = mouse_pt.y + geometry.scaleInt(config.mouse_offset_y, dpi_scale),
    };
    return clampWithMonitor(fallback, dpi_scale);
}

/// Queries text selection bounds from the focused UI Automation element.
fn queryUiaCaret() ?geometry.Point {
    const uia = g_uia orelse return null;

    var elem: ?*win.IUIAutomationElement = null;
    if (uia.lpVtbl.GetFocusedElement(uia, &elem) != 0 or elem == null) return null;
    defer _ = elem.?.lpVtbl.Release(elem.?);

    var pattern_unk: ?*anyopaque = null;
    if (elem.?.lpVtbl.GetCurrentPatternAs(elem.?, win.UIA_TextPatternId, &win.IID_IUIAutomationTextPattern, &pattern_unk) != 0 or pattern_unk == null) return null;
    const text_pattern: *win.IUIAutomationTextPattern = @ptrCast(@alignCast(pattern_unk.?));
    defer _ = text_pattern.lpVtbl.Release(text_pattern);

    var selection_array: ?*win.IUIAutomationTextRangeArray = null;
    if (text_pattern.lpVtbl.GetSelection(text_pattern, &selection_array) != 0 or selection_array == null) return null;
    defer _ = selection_array.?.lpVtbl.Release(selection_array.?);

    var count: c_int = 0;
    _ = selection_array.?.lpVtbl.get_Length(selection_array.?, &count);
    if (count == 0) return null;

    var range: ?*win.IUIAutomationTextRange = null;
    if (selection_array.?.lpVtbl.GetElement(selection_array.?, 0, &range) != 0 or range == null) return null;
    defer _ = range.?.lpVtbl.Release(range.?);

    var psa: ?*win.SafeArray = null;
    _ = range.?.lpVtbl.GetBoundingRectangles(range.?, &psa);

    // Expand collapsed selection by one character if bounding rect is empty
    if (psa == null or psa.?.cDims < 1 or psa.?.rgsabound[0].cElements < 4) {
        if (psa) |p| _ = win.SafeArrayDestroy(p);
        psa = null;
        _ = range.?.lpVtbl.ExpandToEnclosingUnit(range.?, win.TextUnit_Character);
        _ = range.?.lpVtbl.GetBoundingRectangles(range.?, &psa);
    }

    if (psa == null) return null;
    defer _ = win.SafeArrayDestroy(psa.?);

    // Validate SafeArray element properties (expecting double array)
    if (psa.?.cDims < 1 or psa.?.cbElements != 8 or psa.?.rgsabound[0].cElements < 4) return null;

    var p_data: ?*anyopaque = null;
    if (win.SafeArrayAccessData(psa.?, &p_data) != 0 or p_data == null) return null;
    defer _ = win.SafeArrayUnaccessData(psa.?);

    const bounds: [*]f64 = @ptrCast(@alignCast(p_data.?));
    const bx = bounds[0];
    const by = bounds[1];
    const bh = bounds[3]; // [left, top, width, height]

    if (!std.math.isFinite(bx) or !std.math.isFinite(by) or !std.math.isFinite(bh)) return null;
    if (bx <= 0 and by <= 0) return null;
    if (bh <= 0 or bh > 4096) return null;

    return .{ .x = @intFromFloat(bx), .y = @intFromFloat(by + bh) };
}

/// Clamps target coordinate inside monitor work area bounds.
fn clampWithMonitor(pt: geometry.Point, dpi_scale: f32) geometry.Point {
    const hmon = c.MonitorFromPoint(c.POINT{ .x = pt.x, .y = pt.y }, c.MONITOR_DEFAULTTONEAREST);
    var mi = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(hmon, &mi) != 0) {
        return geometry.clampToWorkArea(pt, dpi_scale, .{
            .left = mi.rcWork.left,
            .top = mi.rcWork.top,
            .right = mi.rcWork.right,
            .bottom = mi.rcWork.bottom,
        });
    }
    return pt;
}
