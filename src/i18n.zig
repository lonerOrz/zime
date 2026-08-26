const std = @import("std");
const win = @import("win.zig");
const c = win.c;

pub const Language = enum {
    auto,
    en,
    zh_CN,

    pub fn fromString(str: []const u8) Language {
        if (std.ascii.eqlIgnoreCase(str, "zh") or
            std.ascii.eqlIgnoreCase(str, "zh_cn") or
            std.ascii.eqlIgnoreCase(str, "zh-cn"))
        {
            return .zh_CN;
        }
        if (std.ascii.eqlIgnoreCase(str, "en") or
            std.ascii.eqlIgnoreCase(str, "en_us") or
            std.ascii.eqlIgnoreCase(str, "en-us"))
        {
            return .en;
        }
        return .auto;
    }

    pub fn toString(self: Language) []const u8 {
        return switch (self) {
            .auto => "auto",
            .en => "en",
            .zh_CN => "zh_CN",
        };
    }
};

pub const Strings = struct {
    tray_tooltip: [*:0]const u16,
    menu_autostart: [*:0]const u16,
    menu_restart: [*:0]const u16,
    menu_exit: [*:0]const u16,
    menu_language: [*:0]const u16,
    overlay_cn: [*:0]const u16,
    overlay_en: [*:0]const u16,
};

const STRINGS_EN = blk: {
    @setEvalBranchQuota(20000);
    break :blk Strings{
        .tray_tooltip = std.unicode.utf8ToUtf16LeStringLiteral("Zime - IME Indicator"),
        .menu_autostart = std.unicode.utf8ToUtf16LeStringLiteral("Run on Startup"),
        .menu_restart = std.unicode.utf8ToUtf16LeStringLiteral("Restart Zime"),
        .menu_exit = std.unicode.utf8ToUtf16LeStringLiteral("Exit Zime"),
        .menu_language = std.unicode.utf8ToUtf16LeStringLiteral("Language"),
        .overlay_cn = std.unicode.utf8ToUtf16LeStringLiteral("C"),
        .overlay_en = std.unicode.utf8ToUtf16LeStringLiteral("E"),
    };
};

const STRINGS_ZH = blk: {
    @setEvalBranchQuota(20000);
    break :blk Strings{
        .tray_tooltip = std.unicode.utf8ToUtf16LeStringLiteral("Zime 输入法指示器"),
        .menu_autostart = std.unicode.utf8ToUtf16LeStringLiteral("开机自启"),
        .menu_restart = std.unicode.utf8ToUtf16LeStringLiteral("重启 Zime"),
        .menu_exit = std.unicode.utf8ToUtf16LeStringLiteral("退出 Zime"),
        .menu_language = std.unicode.utf8ToUtf16LeStringLiteral("语言"),
        .overlay_cn = std.unicode.utf8ToUtf16LeStringLiteral("中"),
        .overlay_en = std.unicode.utf8ToUtf16LeStringLiteral("英"),
    };
};

pub const I18n = struct {
    pub const lang_subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Zime");
    pub const lang_value_name = std.unicode.utf8ToUtf16LeStringLiteral("language");

    pub fn loadPersistedLanguage() Language {
        var hk: *anyopaque = undefined;
        if (win.RegOpenKeyExW(win.HKCU_VALUE, lang_subkey.ptr, 0, 0x0001, &hk) != 0)
            return .auto;
        defer _ = win.RegCloseKey(hk);

        var value_type: u32 = 0;
        var lang_id: u32 = 0;
        var cb: u32 = @sizeOf(u32);
        if (win.RegQueryValueExW(hk, lang_value_name.ptr, null, &value_type, &lang_id, &cb) != 0)
            return .auto;
        return switch (lang_id) {
            1 => .zh_CN,
            2 => .en,
            else => .auto,
        };
    }

    pub fn persistLanguage(lang: Language) void {
        var hk: *anyopaque = undefined;
        if (win.RegCreateKeyExW(win.HKCU_VALUE, lang_subkey.ptr, 0, null, 0, 0x0002, null, &hk, null) != 0) return;
        defer _ = win.RegCloseKey(hk);

        const val: u32 = switch (lang) {
            .zh_CN => 1,
            .en => 2,
            .auto => 0,
        };
        const cb = @sizeOf(u32);
        _ = win.RegSetValueExW(hk, lang_value_name.ptr, 0, 4, &val, cb);
    }

    pub fn resolveLanguage(persisted: Language) Language {
        if (persisted != .auto) return persisted;
        const lang_id = c.GetUserDefaultUILanguage();
        if ((lang_id & 0x03FF) == 0x0004) return .zh_CN;
        return .en;
    }

    pub fn getStrings(lang: Language) Strings {
        return switch (resolveLanguage(lang)) {
            .zh_CN => STRINGS_ZH,
            else => STRINGS_EN,
        };
    }
};

test "language string roundtrip" {
    try std.testing.expectEqual(Language.zh_CN, Language.fromString("zh_CN"));
    try std.testing.expectEqual(Language.zh_CN, Language.fromString("ZH-CN"));
    try std.testing.expectEqual(Language.en, Language.fromString("en"));
    try std.testing.expectEqual(Language.auto, Language.fromString("fr"));
}
