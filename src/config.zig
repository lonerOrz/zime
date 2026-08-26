// Base geometry at 96 DPI (logical pixels)
pub const base_width: f32 = 32.0;
pub const base_height: f32 = 20.0;
pub const base_corner_radius: f32 = 5.0;
pub const base_font_size: f32 = 11.0;

// Positioning and anchor offsets
pub const caret_bottom_gap: f32 = 4.0;
pub const mouse_offset_x: f32 = 12.0;
pub const mouse_offset_y: f32 = 16.0;
pub const overflow_flip_offset: f32 = 28.0;
pub const screen_margin: i32 = 4;

// ARGB color definitions
pub const color_bg: u32 = 0x4D1A1A1E;
pub const color_border: u32 = 0x28FFFFFF;
pub const color_text_chinese: u32 = 0xFF00D4FF;
pub const color_text_english: u32 = 0xFFFFFFFF;

// Timing and IPC timeouts in milliseconds
pub const debounce_key_ms: u32 = 40;
pub const debounce_window_ms: u32 = 50;
pub const autohide_duration_ms: u32 = 850;
pub const uia_ipc_timeout_ms: u32 = 20;
pub const ime_msg_timeout_ms: u32 = 15;

// Win32 message, timer, and menu identifiers
pub const WM_TRAY_CALLBACK: u32 = 0x0400 + 1; // WM_USER + 1
pub const TIMER_DEBOUNCE_CHECK: usize = 101;
pub const TIMER_AUTOHIDE: usize = 201;
pub const MENU_TRAY_EXIT: usize = 301;
pub const MENU_TRAY_AUTOSTART: usize = 302;
pub const MENU_TRAY_RESTART: usize = 303;
pub const IDI_APP_ICON: usize = 1;
