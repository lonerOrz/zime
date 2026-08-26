const std = @import("std");
const config = @import("config.zig");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Scales a floating-point value by DPI scale factor.
pub inline fn scale(val: f32, dpi_scale: f32) f32 {
    return val * dpi_scale;
}

/// Scales a floating-point value to an integer pixel dimension.
pub inline fn scaleInt(val: f32, dpi_scale: f32) i32 {
    return @intFromFloat(val * dpi_scale);
}

/// Clamps HUD within monitor work area; flips above anchor on overflow.
pub fn clampToWorkArea(pt: Point, dpi_scale: f32, work_area: Rect) Point {
    const width = scaleInt(config.base_width, dpi_scale);
    const height = scaleInt(config.base_height, dpi_scale);
    var result = pt;

    // Horizontal clamping
    if (result.x + width > work_area.right) result.x = work_area.right - width - config.screen_margin;
    if (result.x < work_area.left) result.x = work_area.left + config.screen_margin;

    // Vertical flipping on bottom overflow, then top clamping
    if (result.y + height > work_area.bottom) {
        result.y = pt.y - height - scaleInt(config.overflow_flip_offset, dpi_scale);
    }
    if (result.y < work_area.top) result.y = work_area.top + config.screen_margin;

    return result;
}

test "clampToWorkArea normal placement" {
    const screen = Rect{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const clamped = clampToWorkArea(.{ .x = 100, .y = 100 }, 1.0, screen);
    try std.testing.expectEqual(@as(i32, 100), clamped.x);
    try std.testing.expectEqual(@as(i32, 100), clamped.y);
}

test "right overflow clamps x; bottom overflow flips above anchor" {
    const screen = Rect{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    // width 46: right limit = 1920 - 46 - 4 = 1870
    // height 28, flip offset 28: y = 1070 - 28 - 28 = 1014
    const clamped = clampToWorkArea(.{ .x = 1900, .y = 1070 }, 1.0, screen);
    try std.testing.expectEqual(@as(i32, 1870), clamped.x);
    try std.testing.expectEqual(@as(i32, 1014), clamped.y);
}

test "flip above top edge clamps to work area top" {
    const tight = Rect{ .left = 0, .top = 100, .right = 800, .bottom = 120 };
    // flipped y = 118 - 28 - 28 = 62 < top(100) -> clamped to 104
    const clamped = clampToWorkArea(.{ .x = 400, .y = 118 }, 1.0, tight);
    try std.testing.expectEqual(@as(i32, 104), clamped.y);
}
