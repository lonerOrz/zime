const std = @import("std");
const win = @import("win.zig");
const ime = @import("ime.zig");
const caret = @import("caret.zig");
const config = @import("config.zig");
const geometry = @import("geometry.zig");
const c = win.c;

var g_hwnd_overlay: c.HWND = null;
var g_gdiplus_token: usize = 0;

// Long-lived GDI+ objects (process lifetime).
var g_font_family: ?*anyopaque = null;
var g_str_format: ?*anyopaque = null;
var g_brush_bg: ?*anyopaque = null;
var g_brush_zh: ?*anyopaque = null;
var g_brush_en: ?*anyopaque = null;

// DPI-keyed render pool: mem DC, DIB, graphics, font, pen, pill path are
// rebuilt only when the monitor DPI scale changes, so steady-state toggling
// performs zero GDI/GDI+ allocation.
const RenderCache = struct {
    scale: f32 = 0.0,
    width_px: i32 = 0,
    height_px: i32 = 0,
    hdc_mem: ?c.HDC = null,
    hbmp_mem: ?c.HBITMAP = null,
    pixel_bits: ?[*]u8 = null,
    graphics: ?*anyopaque = null,
    pen_border: ?*anyopaque = null,
    font: ?*anyopaque = null,
    path_pill: ?*anyopaque = null,

    fn release(self: *RenderCache) void {
        if (self.path_pill) |p| _ = win.GdipDeletePath(p);
        if (self.font) |f| _ = win.GdipDeleteFont(f);
        if (self.pen_border) |pen| _ = win.GdipDeletePen(pen);
        if (self.graphics) |g| _ = win.GdipDeleteGraphics(g);
        if (self.hbmp_mem) |bmp| _ = c.DeleteObject(bmp);
        if (self.hdc_mem) |dc| _ = c.DeleteDC(dc);
        self.* = .{};
    }

    fn ensure(self: *RenderCache, dpi_scale: f32, hdc_screen: c.HDC) !void {
        if (self.scale == dpi_scale and self.hdc_mem != null) return;
        self.release();

        const font_family = g_font_family orelse return error.NoFontFamily;

        const w = geometry.scaleInt(config.base_width, dpi_scale);
        const h = geometry.scaleInt(config.base_height, dpi_scale);
        const radius = geometry.scale(config.base_corner_radius, dpi_scale);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);

        const mem_dc = c.CreateCompatibleDC(hdc_screen) orelse return error.CreateDcFailed;
        errdefer _ = c.DeleteDC(mem_dc);

        // Negative height => top-down DIB, matching GDI+ pixel addressing.
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

        var pen: *anyopaque = undefined;
        if (win.GdipCreatePen1(config.color_border, 1.0 * dpi_scale, 2, &pen) != 0) return error.CreatePenFailed; // UnitPixel
        errdefer _ = win.GdipDeletePen(pen);

        var font_obj: *anyopaque = undefined;
        if (win.GdipCreateFont(font_family, geometry.scale(config.base_font_size, dpi_scale), 1, 2, &font_obj) != 0) return error.CreateFontFailed; // Bold, UnitPixel
        errdefer _ = win.GdipDeleteFont(font_obj);

        var path: *anyopaque = undefined;
        if (win.GdipCreatePath(0, &path) != 0) return error.CreatePathFailed; // FillModeAlternate
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
        self.pen_border = pen;
        self.font = font_obj;
        self.path_pill = path;
    }
};

var g_cache = RenderCache{};

pub fn init(instance: c.HINSTANCE) void {
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

    caret.init();

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
        @intFromFloat(config.base_width),
        @intFromFloat(config.base_height),
        null,
        null,
        instance,
        null,
    );
}

pub fn deinit() void {
    caret.deinit();
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

pub fn show(state: ime.ImeState) void {
    const hwnd = g_hwnd_overlay orelse return;

    const dpi = win.GetDpiForWindow(hwnd);
    const dpi_scale: f32 = @as(f32, @floatFromInt(if (dpi > 0) dpi else 96)) / 96.0;

    const hdc_screen = c.GetDC(null);
    defer _ = c.ReleaseDC(null, hdc_screen);

    g_cache.ensure(dpi_scale, hdc_screen) catch return;
    const cache = &g_cache;
    const w = cache.width_px;
    const h = cache.height_px;
    const graphics = cache.graphics.?;

    // The cached DIB keeps last frame's pixels; clear before drawing.
    @memset(cache.pixel_bits.?[0..@intCast(w * h * 4)], 0);

    const path = cache.path_pill.?;
    if (g_brush_bg) |b| _ = win.GdipFillPath(graphics, b, path);
    _ = win.GdipDrawPath(graphics, cache.pen_border.?, path);

    // GDI+ writes premultiplied ARGB into the DIB directly.
    const text: [*:0]const u16 = if (state == .chinese)
        std.unicode.utf8ToUtf16LeStringLiteral("中")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("英");
    const text_brush = if (state == .chinese) g_brush_zh else g_brush_en;

    if (text_brush) |tb| {
        const layout_rect = win.RectF{ .X = 0, .Y = 0, .Width = @floatFromInt(w), .Height = @floatFromInt(h) };
        _ = win.GdipDrawString(graphics, text, 1, cache.font.?, &layout_rect, g_str_format.?, tb);
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

pub fn hide() void {
    if (g_hwnd_overlay != null) {
        _ = c.ShowWindow(g_hwnd_overlay, c.SW_HIDE);
    }
}

/// Tray icon drawn at runtime in the same style as the HUD pill.
/// Uses only primitives proven on every machine: DIB + GdipCreateFromHDC
/// (the HUD render path) plus plain-GDI CreateIconIndirect for the HICON.
pub fn createTrayIcon(size_px: i32) ?c.HICON {
    const brush_bg = g_brush_bg orelse return null;

    const hdc_screen = c.GetDC(null);
    defer _ = c.ReleaseDC(null, hdc_screen);
    const mem_dc = c.CreateCompatibleDC(hdc_screen) orelse return null;
    defer _ = c.DeleteDC(mem_dc);

    // 32bpp top-down DIB => per-pixel alpha survives CreateIconIndirect.
    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = size_px;
    bmi.bmiHeader.biHeight = -size_px;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;
    var bits_ptr: ?*anyopaque = null;
    const color_bmp = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &bits_ptr, null, 0) orelse return null;
    defer _ = c.DeleteObject(color_bmp);
    _ = c.SelectObject(mem_dc, color_bmp);

    var gfx: *anyopaque = undefined;
    if (win.GdipCreateFromHDC(mem_dc, &gfx) != 0) return null;
    defer _ = win.GdipDeleteGraphics(gfx);
    _ = win.GdipSetSmoothingMode(gfx, 4);

    // Full-bleed pill (inset 0.5): at tray sizes a 1px transparent ring reads
    // as a broken background.
    const fs: f32 = @floatFromInt(size_px);
    const radius = fs * 0.28;
    const d = radius * 2.0;
    var path: *anyopaque = undefined;
    if (win.GdipCreatePath(0, &path) != 0) return null; // FillModeAlternate
    defer _ = win.GdipDeletePath(path);
    _ = win.GdipAddPathArc(path, 0.5, 0.5, d, d, 180.0, 90.0);
    _ = win.GdipAddPathArc(path, fs - d - 0.5, 0.5, d, d, 270.0, 90.0);
    _ = win.GdipAddPathArc(path, fs - d - 0.5, fs - d - 0.5, d, d, 0.0, 90.0);
    _ = win.GdipAddPathArc(path, 0.5, fs - d - 0.5, d, d, 90.0, 90.0);
    _ = win.GdipClosePathFigure(path);

    _ = win.GdipFillPath(gfx, brush_bg, path);

    // Real typeface 中, pixel-centered via MeasureString ink box: StringFormat
    // centering trusts line-box metrics that skew CJK glyphs at tray sizes;
    // the typographic format reports pure ink bounds so centering is exact.
    var fmt_typo: *anyopaque = undefined;
    if (win.GdipStringFormatGetGenericTypographic(&fmt_typo) != 0) return null;
    defer _ = win.GdipDeleteStringFormat(fmt_typo);
    const font_family = g_font_family orelse return null;
    const brush_zh = g_brush_zh orelse return null;

    var font_obj: *anyopaque = undefined;
    if (win.GdipCreateFont(font_family, fs * 0.66, 1, 2, &font_obj) != 0) return null; // Bold, UnitPixel
    defer _ = win.GdipDeleteFont(font_obj);
    _ = win.GdipSetTextRenderingHint(gfx, 4); // AntiAliasGridFit

    const zh = std.unicode.utf8ToUtf16LeStringLiteral("中");
    const full = win.RectF{ .X = 0, .Y = 0, .Width = fs, .Height = fs };
    var bbox: win.RectF = undefined;
    _ = win.GdipMeasureString(gfx, zh.ptr, 1, font_obj, &full, fmt_typo, &bbox, null, null);
    const layout = win.RectF{
        .X = (fs - bbox.Width) / 2 - bbox.X,
        .Y = (fs - bbox.Height) / 2 - bbox.Y,
        .Width = fs,
        .Height = fs,
    };
    _ = win.GdipDrawString(gfx, zh.ptr, 1, font_obj, &layout, fmt_typo, brush_zh);

    // Zeroed mask: CreateBitmap's bits are undefined when null is passed.
    var mask_bits: [128]u8 = @splat(0); // ponytail: covers up to 32px icons
    const mask_bmp = c.CreateBitmap(size_px, size_px, 1, 1, &mask_bits) orelse return null;
    defer _ = c.DeleteObject(mask_bmp);

    var ii = std.mem.zeroes(c.ICONINFO);
    ii.fIcon = c.TRUE;
    ii.hbmMask = mask_bmp;
    ii.hbmColor = color_bmp;
    return c.CreateIconIndirect(&ii);
}
