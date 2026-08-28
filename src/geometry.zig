const std = @import("std");
const config = @import("config.zig");

/// 2D integral coordinate point
pub const Point = struct {
    x: i32,
    y: i32,
};

/// 2D bounding rectangle
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Scales a floating point value by the given DPI ratio.
pub inline fn scale(val: f32, dpi_scale: f32) f32 {
    return val * dpi_scale;
}

/// Scales a floating point value by DPI ratio and converts it to integer pixels.
pub inline fn scaleInt(val: f32, dpi_scale: f32) i32 {
    return @intFromFloat(val * dpi_scale);
}

/// Restrains the indicator coordinate within the target monitor work area.
/// Automatically flips the indicator above the anchor point if it overflows the bottom edge.
pub fn clampToWorkArea(pt: Point, dpi_scale: f32, work_area: Rect, text_width: i32) Point {
    const width = text_width + scaleInt(config.padding_left + config.padding_right, dpi_scale);
    const height = scaleInt(config.base_font_size + config.padding_top + config.padding_bottom, dpi_scale);
    var result = pt;

    // Horizontal boundary clamping
    if (result.x + width > work_area.right) {
        result.x = work_area.right - width - config.screen_margin;
    }
    if (result.x < work_area.left) {
        result.x = work_area.left + config.screen_margin;
    }

    // Vertical boundary clamping and flip on bottom overflow
    if (result.y + height > work_area.bottom) {
        result.y = pt.y - height - scaleInt(config.overflow_flip_offset, dpi_scale);
    }
    if (result.y < work_area.top) {
        result.y = work_area.top + config.screen_margin;
    }

    return result;
}

test "clampToWorkArea normal placement" {
    const screen = Rect{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const clamped = clampToWorkArea(.{ .x = 100, .y = 100 }, 1.0, screen, 16);
    try std.testing.expectEqual(@as(i32, 100), clamped.x);
    try std.testing.expectEqual(@as(i32, 100), clamped.y);
}

test "clampToWorkArea right and bottom overflow" {
    const screen = Rect{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const clamped = clampToWorkArea(.{ .x = 1900, .y = 1070 }, 1.0, screen, 16);
    try std.testing.expectEqual(@as(i32, 1884), clamped.x);
    try std.testing.expectEqual(@as(i32, 1023), clamped.y);
}
