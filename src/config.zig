//! Global configuration and constants for layout, timers, styling, and IPC.

/// Working mode of the IME indicator HUD
pub const IndicatorMode = enum(u32) {
    caret_focus = 0, // Mode 1: Caret Focus & Switch (Auto-hiding HUD at caret)
    mouse_follow = 1, // Mode 2: Mouse Follow (Persistent HUD pinned to mouse cursor)
};

// Visual layout metrics (scaled by DPI at runtime)
pub const padding_left: f32 = 8.0;
pub const padding_right: f32 = 8.0;
pub const padding_top: f32 = 4.0;
pub const padding_bottom: f32 = 4.0;
pub const base_corner_radius: f32 = 5.0;
pub const base_font_size: f32 = 11.0;

// Placement and anchor offsets
pub const caret_bottom_gap: f32 = 4.0;
pub const mouse_offset_x: f32 = 18.0;
pub const mouse_offset_y: f32 = 24.0;
pub const overflow_flip_offset: f32 = 28.0;
pub const screen_margin: i32 = 4;

// ARGB 32-bit color values
pub const color_bg: u32 = 0xD91E1E24;
pub const color_border: u32 = 0x33FFFFFF;
pub const color_text_chinese: u32 = 0xFF00D4FF;
pub const color_text_english: u32 = 0xFFFFFFFF;

// Timing thresholds and IPC timeouts in milliseconds
pub const debounce_key_ms: u32 = 40;
pub const debounce_window_ms: u32 = 60;
pub const autohide_duration_ms: u32 = 800;
pub const uia_ipc_timeout_ms: u32 = 150;
pub const ime_msg_timeout_ms: u32 = 80;

// Win32 message and timer identifiers
pub const WM_TRAY_CALLBACK: u32 = 0x0400 + 1; // WM_USER + 1
pub const WM_MOUSE_MOVE_NOTIFY: u32 = 0x0400 + 2; // WM_USER + 2
pub const TIMER_DEBOUNCE_CHECK: usize = 101;
pub const TIMER_AUTOHIDE: usize = 201;

// Tray menu command identifiers
pub const MENU_TRAY_EXIT: usize = 301;
pub const MENU_TRAY_AUTOSTART: usize = 302;
pub const MENU_TRAY_RESTART: usize = 303;
pub const MENU_TRAY_LANGUAGE: usize = 304;
pub const MENU_TRAY_LANG_ZH: usize = 305;
pub const MENU_TRAY_LANG_EN: usize = 306;
pub const MENU_TRAY_MODE_CARET: usize = 307;
pub const MENU_TRAY_MODE_MOUSE: usize = 308;

// Resource identifier for application icon
pub const IDI_APP_ICON: usize = 1;
