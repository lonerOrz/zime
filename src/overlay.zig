const std = @import("std");
const win = @import("win.zig");
const ime = @import("ime.zig");
const caret = @import("caret.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const i18n = @import("i18n.zig");
const c = win.c;

var g_hwnd_overlay: c.HWND = null;
var g_gdiplus_token: usize = 0;
var g_lang: i18n.Language = .auto;

// Process-lifetime GDI+ resources
var g_font_family: ?*anyopaque = null;
var g_str_format: ?*anyopaque = null;
var g_brush_bg: ?*anyopaque = null;
var g_brush_zh: ?*anyopaque = null;
var g_brush_en: ?*anyopaque = null;

/// DPI-keyed cache to avoid GDI/GDI+ allocations during steady-state rendering.
const RenderCache = struct {
    scale: f32 = 0.0,
    width_px: i32 = 0,
    height_px: i32 = 0,
    hdc_mem: ?c.HDC = null,
    hbmp_mem: ?c.HBITMAP = null,
    pixel_bits: ?[*]u8 = null,
    graphics: ?*anyopaque = null,
    font: ?*anyopaque = null,
    path_pill: ?*anyopaque = null,
    state: ime.ImeState = .english,

    fn release(self: *RenderCache) void {
        if (self.path_pill) |p| _ = win.GdipDeletePath(p);
        if (self.font) |f| _ = win.GdipDeleteFont(f);
        if (self.graphics) |g| _ = win.GdipDeleteGraphics(g);
        if (self.hbmp_mem) |bmp| _ = c.DeleteObject(bmp);
        if (self.hdc_mem) |dc| _ = c.DeleteDC(dc);
        self.* = .{};
    }

    fn ensure(self: *RenderCache, dpi_scale: f32, hdc_screen: c.HDC, text_width: i32, state: ime.ImeState) !bool {
        if (self.scale == dpi_scale and self.width_px == text_width and self.hdc_mem != null and self.state == state) return false;
        self.release();

        const font_family = g_font_family orelse return error.NoFontFamily;

        const h = geometry.scaleInt(
            config.base_font_size + config.padding_top + config.padding_bottom,
            dpi_scale,
        );
        const w = text_width + geometry.scaleInt(config.padding_left + config.padding_right, dpi_scale);
        const radius = geometry.scale(config.base_corner_radius, dpi_scale);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);

        const mem_dc = c.CreateCompatibleDC(hdc_screen) orelse return error.CreateDcFailed;
        errdefer _ = c.DeleteDC(mem_dc);

        // Top-down 32bpp DIB section
        var bmi = std.mem.zeroes(c.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits_ptr: ?*anyopaque = null;
        const bmp = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &bits_ptr, null, 0) orelse return error.CreateDibFailed;
        errdefer _ = c.DeleteObject(bmp);
        _ = c.SelectObject(mem_dc, bmp);

        var gfx: *anyopaque = undefined;
        if (win.GdipCreateFromHDC(mem_dc, &gfx) != 0) return error.CreateGraphicsFailed;
        errdefer _ = win.GdipDeleteGraphics(gfx);
        _ = win.GdipSetSmoothingMode(gfx, 4); // AntiAlias
        _ = win.GdipSetTextRenderingHint(gfx, 4); // AntiAliasGridFit

        var font_obj: *anyopaque = undefined;
        if (win.GdipCreateFont(font_family, geometry.scale(config.base_font_size, dpi_scale), 1, 2, &font_obj) != 0) return error.CreateFontFailed; // Bold, UnitPixel
        errdefer _ = win.GdipDeleteFont(font_obj);

        var path: *anyopaque = undefined;
        if (win.GdipCreatePath(0, &path) != 0) return error.CreatePathFailed;
        errdefer _ = win.GdipDeletePath(path);

        const d = radius * 2.0;
        _ = win.GdipAddPathArc(path, 1.0, 1.0, d, d, 180.0, 90.0);
        _ = win.GdipAddPathArc(path, fw - d - 1.0, 1.0, d, d, 270.0, 90.0);
        _ = win.GdipAddPathArc(path, fw - d - 1.0, fh - d - 1.0, d, d, 0.0, 90.0);
        _ = win.GdipAddPathArc(path, 1.0, fh - d - 1.0, d, d, 90.0, 90.0);
        _ = win.GdipClosePathFigure(path);

        self.scale = dpi_scale;
        self.width_px = w;
        self.height_px = h;
        self.hdc_mem = mem_dc;
        self.hbmp_mem = bmp;
        self.pixel_bits = @ptrCast(bits_ptr);
        self.graphics = gfx;
        self.font = font_obj;
        self.path_pill = path;
        self.state = state;
        return true;
    }
};

var g_cache = RenderCache{};

/// Initializes GDI+, global brushes, and the layered HUD window.
pub fn init(instance: c.HINSTANCE, lang: i18n.Language) void {
    g_lang = lang;
    var gdi_input = win.GdiplusStartupInput{};
    _ = win.GdiplusStartup(&g_gdiplus_token, &gdi_input, null);

    _ = win.GdipCreateFontFamilyFromName(std.unicode.utf8ToUtf16LeStringLiteral("Microsoft YaHei UI").ptr, null, @ptrCast(&g_font_family));
    _ = win.GdipCreateStringFormat(0, 0, @ptrCast(&g_str_format));
    if (g_str_format) |sf| {
        _ = win.GdipSetStringFormatAlign(sf, 1); // Center
        _ = win.GdipSetStringFormatLineAlign(sf, 1); // Center
    }

    _ = win.GdipCreateSolidFill(config.color_bg, @ptrCast(&g_brush_bg));
    _ = win.GdipCreateSolidFill(config.color_text_chinese, @ptrCast(&g_brush_zh));
    _ = win.GdipCreateSolidFill(config.color_text_english, @ptrCast(&g_brush_en));

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZimeOverlayHUD");
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = c.DefWindowProcW;
    wc.hInstance = instance;
    wc.lpszClassName = class_name.ptr;
    _ = c.RegisterClassExW(&wc);

    g_hwnd_overlay = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST | c.WS_EX_NOACTIVATE,
        class_name.ptr,
        null,
        c.WS_POPUP,
        -500,
        -500,
        @intFromFloat(config.padding_left + config.padding_right),
        @intFromFloat(config.base_font_size + config.padding_top + config.padding_bottom),
        null,
        null,
        instance,
        null,
    );
}

/// Updates the language used by the overlay (called from main when user changes language).
pub fn setLanguage(lang: i18n.Language) void {
    g_lang = lang;
    g_cache.scale = 0;
}

/// Releases HUD window and GDI+ resources.
pub fn deinit() void {
    g_cache.release();

    if (g_brush_en) |b| _ = win.GdipDeleteBrush(b);
    if (g_brush_zh) |b| _ = win.GdipDeleteBrush(b);
    if (g_brush_bg) |b| _ = win.GdipDeleteBrush(b);
    if (g_str_format) |sf| _ = win.GdipDeleteStringFormat(sf);
    if (g_font_family) |ff| _ = win.GdipDeleteFontFamily(ff);
    if (g_gdiplus_token != 0) {
        win.GdiplusShutdown(g_gdiplus_token);
        g_gdiplus_token = 0;
    }
}

/// Renders and displays the indicator pill near active caret.
pub fn show(state: ime.ImeState) void {
    const hwnd = g_hwnd_overlay orelse return;

    const dpi = win.GetDpiForWindow(hwnd);
    const dpi_scale: f32 = @as(f32, @floatFromInt(if (dpi > 0) dpi else 96)) / 96.0;

    const hdc_screen = c.GetDC(null);
    defer _ = c.ReleaseDC(null, hdc_screen);

    const resolved = i18n.I18n.resolveLanguage(g_lang);
    const text: [*:0]const u16 = switch (resolved) {
        .zh_CN => if (state == .chinese)
            std.unicode.utf8ToUtf16LeStringLiteral("中")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("英"),
        else => if (state == .chinese)
            std.unicode.utf8ToUtf16LeStringLiteral("C")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("E"),
    };
    const text_width = measureTextWidth(dpi_scale, text);

    const size_changed = g_cache.ensure(dpi_scale, hdc_screen, text_width, state) catch return;
    const cache = &g_cache;
    const w = cache.width_px;
    const h = cache.height_px;
    if (size_changed) _ = c.MoveWindow(hwnd, -500, -500, w, h, c.FALSE);
    const graphics = cache.graphics.?;

    const buf_len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    @memset(cache.pixel_bits.?[0..buf_len], 0);

    const path = cache.path_pill.?;
    if (g_brush_bg) |b| _ = win.GdipFillPath(graphics, b, path);

    const text_brush = if (state == .chinese) g_brush_zh else g_brush_en;

    if (text_brush) |tb| {
        const layout_rect = win.RectF{ .X = 0, .Y = 0, .Width = @floatFromInt(w), .Height = @floatFromInt(h) };
        const text_len = @as(c_int, @intCast(std.mem.len(text)));
        _ = win.GdipDrawString(graphics, text, text_len, cache.font.?, &layout_rect, g_str_format.?, tb);
    }

    const pt = caret.resolveAnchor(dpi_scale);

    var pt_src = c.POINT{ .x = 0, .y = 0 };
    var pt_dst = c.POINT{ .x = pt.x, .y = pt.y };
    var sz = c.SIZE{ .cx = w, .cy = h };
    var blend = c.BLENDFUNCTION{
        .BlendOp = c.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = c.AC_SRC_ALPHA,
    };
    _ = c.UpdateLayeredWindow(hwnd, hdc_screen, &pt_dst, &sz, cache.hdc_mem.?, &pt_src, 0, &blend, c.ULW_ALPHA);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
}

/// Measures text width in pixels at the given DPI scale.
fn measureTextWidth(dpi_scale: f32, text: [*:0]const u16) i32 {
    const font_family = g_font_family orelse return @intFromFloat(config.padding_left + config.padding_right);
    var font_obj: *anyopaque = undefined;
    const font_size = geometry.scale(config.base_font_size, dpi_scale);
    if (win.GdipCreateFont(font_family, font_size, 1, 2, &font_obj) != 0) return @intFromFloat(config.padding_left + config.padding_right);
    defer _ = win.GdipDeleteFont(font_obj);

    var gfx: *anyopaque = undefined;
    const mem_dc = c.CreateCompatibleDC(null) orelse return @intFromFloat(config.padding_left + config.padding_right);
    defer _ = c.DeleteDC(mem_dc);
    if (win.GdipCreateFromHDC(mem_dc, &gfx) != 0) return @intFromFloat(config.padding_left + config.padding_right);

    var bbox: win.RectF = undefined;
    _ = win.GdipMeasureString(gfx, text, @as(c_int, @intCast(std.mem.len(text))), font_obj, &win.RectF{ .X = 0, .Y = 0, .Width = 9999.0, .Height = 9999.0 }, null, &bbox, null, null);
    return @intFromFloat(@ceil(bbox.Width));
}
pub fn hide() void {
    if (g_hwnd_overlay != null) {
        _ = c.ShowWindow(g_hwnd_overlay, c.SW_HIDE);
    }
}
