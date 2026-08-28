//! Win32, COM, GDI+, and accessibility API declarations and interop bindings.

const std = @import("std");

pub const c = @cImport({
    @cInclude("windows.h");
    @cInclude("imm.h");
    @cInclude("shellapi.h");
});

// Win32 pseudohandle with 1-byte alignment to satisfy Zig strict pointer alignment rules
pub const HWND_TOPMOST: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

// GDI+ Flat API Structures
pub const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: c.BOOL = c.FALSE,
    SuppressExternalCodecs: c.BOOL = c.FALSE,
};

pub const RectF = extern struct {
    X: f32,
    Y: f32,
    Width: f32,
    Height: f32,
};

// GDI+ Flat API Exported Functions
pub extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdiplusShutdown(token: usize) callconv(.winapi) void;
pub extern "gdiplus" fn GdipCreateFromHDC(hdc: c.HDC, graphics: **anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteGraphics(graphics: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipSetSmoothingMode(graphics: *anyopaque, mode: c_int) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipSetTextRenderingHint(graphics: *anyopaque, hint: c_int) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreateSolidFill(color: u32, brush: **anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteBrush(brush: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreateFontFamilyFromName(name: [*:0]const u16, fontCollection: ?*anyopaque, fontFamily: **anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteFontFamily(fontFamily: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreateFont(fontFamily: *anyopaque, emSize: f32, style: c_int, unit: c_int, font: **anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteFont(font: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreateStringFormat(formatAttributes: c_int, language: u16, stringFormat: **anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipSetStringFormatAlign(stringFormat: *anyopaque, align_: c_int) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipSetStringFormatLineAlign(stringFormat: *anyopaque, align_: c_int) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeleteStringFormat(stringFormat: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDrawString(graphics: *anyopaque, string: [*:0]const u16, length: c_int, font: *anyopaque, layoutRect: *const RectF, stringFormat: *anyopaque, brush: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipCreatePath(brushMode: c_int, path: **anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipDeletePath(path: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipAddPathArc(path: *anyopaque, x: f32, y: f32, width: f32, height: f32, startAngle: f32, sweepAngle: f32) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipClosePathFigure(path: *anyopaque) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipMeasureString(graphics: *anyopaque, string: [*]const u16, length: c_int, font: *anyopaque, layoutRect: *const RectF, stringFormat: ?*anyopaque, boundingBox: *RectF, codepointsFitted: ?*c_int, linesFilled: ?*c_int) callconv(.winapi) c_int;
pub extern "gdiplus" fn GdipFillPath(graphics: *anyopaque, brush: *anyopaque, path: *anyopaque) callconv(.winapi) c_int;

// Windows Registry API Exports
pub extern "advapi32" fn RegOpenKeyExW(hkey: *anyopaque, subkey: [*:0]const u16, options: u32, access: u32, result: **anyopaque) callconv(.winapi) c_int;
pub extern "advapi32" fn RegQueryValueExW(hkey: *anyopaque, name: [*:0]const u16, reserved: ?*u32, typ: ?*u32, data: ?*anyopaque, cb: ?*u32) callconv(.winapi) c_int;
pub extern "advapi32" fn RegSetValueExW(hkey: *anyopaque, name: [*:0]const u16, reserved: u32, typ: u32, data: *const anyopaque, cb: u32) callconv(.winapi) c_int;
pub extern "advapi32" fn RegDeleteValueW(hkey: *anyopaque, name: [*:0]const u16) callconv(.winapi) c_int;
pub extern "advapi32" fn RegCloseKey(hkey: *anyopaque) callconv(.winapi) c_int;
pub extern "advapi32" fn RegCreateKeyExW(hkey: *anyopaque, subkey: [*:0]const u16, reserved: u32, class_: ?[*:0]const u16, options: u32, sam: u32, sa: ?*anyopaque, result: **anyopaque, disposition: ?*u32) callconv(.winapi) c_int;

pub const HKCU_VALUE: *anyopaque = @ptrFromInt(0x80000001); // HKEY_CURRENT_USER

// OLE Automation SafeArray Structures
pub const SAFEARRAYBOUND = extern struct {
    cElements: u32,
    lLbound: i32,
};

pub const SafeArray = extern struct {
    cDims: u16,
    fFeatures: u16,
    cbElements: u32,
    cLocks: u32,
    pvData: ?*anyopaque,
    rgsabound: [1]SAFEARRAYBOUND,
};

// UI Automation GUID Identifiers
pub const CLSID_CUIAutomation = c.GUID{ .Data1 = 0xff48dba4, .Data2 = 0x60ef, .Data3 = 0x4201, .Data4 = .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e } };
pub const IID_IUIAutomation = c.GUID{ .Data1 = 0x30cbe57d, .Data2 = 0xd9d0, .Data3 = 0x452a, .Data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee } };
pub const IID_IUIAutomationTextPattern = c.GUID{ .Data1 = 0x32eba289, .Data2 = 0x3583, .Data3 = 0x42c9, .Data4 = .{ 0x9c, 0x59, 0x3b, 0x6d, 0x9a, 0x1e, 0x9b, 0x6a } };
pub const IID_IUIAutomationTextPattern2 = c.GUID{ .Data1 = 0x506a921a, .Data2 = 0xfcc9, .Data3 = 0x409f, .Data4 = .{ 0xb2, 0x3b, 0x37, 0xeb, 0x74, 0x10, 0x68, 0x72 } };
pub const IID_IUIAutomation2 = c.GUID{ .Data1 = 0x34723aff, .Data2 = 0x0c9d, .Data3 = 0x49d0, .Data4 = .{ 0x98, 0x96, 0x7a, 0xb5, 0x2d, 0xf8, 0xcd, 0x8a } };

pub const UIA_TextPatternId: c_int = 10014;
pub const UIA_TextPattern2Id: c_int = 10024;
pub const TextUnit_Character: c_int = 0;

// UI Automation COM Virtual Tables
pub const IUIAutomationElement = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomationElement) callconv(.winapi) c.ULONG,
        reserved: [11]*anyopaque, // Slots 3..13
        GetCurrentPatternAs: *const fn (*IUIAutomationElement, patternId: c_int, riid: *const c.GUID, patternObject: *?*anyopaque) callconv(.winapi) c.HRESULT, // Slot 14
    },
};

pub const IUIAutomationTextPattern = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomationTextPattern) callconv(.winapi) c.ULONG,
        RangeFromPoint: *anyopaque,
        RangeFromChild: *anyopaque,
        GetSelection: *const fn (*IUIAutomationTextPattern, *?*IUIAutomationTextRangeArray) callconv(.winapi) c.HRESULT,
    },
};

pub const IUIAutomationTextPattern2 = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomationTextPattern2) callconv(.winapi) c.ULONG,
        RangeFromPoint: *anyopaque,
        RangeFromChild: *anyopaque,
        GetSelection: *const fn (*IUIAutomationTextPattern2, *?*IUIAutomationTextRangeArray) callconv(.winapi) c.HRESULT, // Slot 5
        GetVisibleRanges: *anyopaque,
        get_DocumentRange: *anyopaque,
        get_SupportedTextSelection: *anyopaque,
        RangeFromAnnotation: *anyopaque,
        GetCaretRange: *const fn (*IUIAutomationTextPattern2, *c.BOOL, *?*IUIAutomationTextRange) callconv(.winapi) c.HRESULT, // Slot 10
    },
};

pub const IUIAutomationTextRangeArray = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomationTextRangeArray) callconv(.winapi) c.ULONG,
        get_Length: *const fn (*IUIAutomationTextRangeArray, *c_int) callconv(.winapi) c.HRESULT,
        GetElement: *const fn (*IUIAutomationTextRangeArray, c_int, *?*IUIAutomationTextRange) callconv(.winapi) c.HRESULT,
    },
};

pub const IUIAutomationTextRange = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomationTextRange) callconv(.winapi) c.ULONG,
        Clone: *anyopaque,
        Compare: *anyopaque,
        CompareEndpoints: *anyopaque,
        ExpandToEnclosingUnit: *const fn (*IUIAutomationTextRange, unit: c_int) callconv(.winapi) c.HRESULT,
        FindAttribute: *anyopaque,
        FindText: *anyopaque,
        GetAttributeValue: *anyopaque,
        GetBoundingRectangles: *const fn (*IUIAutomationTextRange, *?*SafeArray) callconv(.winapi) c.HRESULT,
    },
};

pub const IUIAutomation = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *const fn (*IUIAutomation, riid: *const c.GUID, ppv: *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomation) callconv(.winapi) c.ULONG,
        reserved: [5]*anyopaque, // Slots 3..7
        GetFocusedElement: *const fn (*IUIAutomation, *?*IUIAutomationElement) callconv(.winapi) c.HRESULT, // Slot 8
    },
};

pub const IUIAutomation2 = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IUIAutomation2) callconv(.winapi) c.ULONG,
        reserved: [55]*anyopaque,
        get_ConnectionTimeout: *anyopaque,
        put_ConnectionTimeout: *const fn (*IUIAutomation2, timeout_ms: c.DWORD) callconv(.winapi) c.HRESULT,
        get_TransactionTimeout: *anyopaque,
        put_TransactionTimeout: *const fn (*IUIAutomation2, timeout_ms: c.DWORD) callconv(.winapi) c.HRESULT,
    },
};

// Microsoft Active Accessibility (MSAA) Declarations
pub const IID_IAccessible = c.GUID{ .Data1 = 0x618736e0, .Data2 = 0x3c3d, .Data3 = 0x11cf, .Data4 = .{ 0x81, 0x0c, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
pub const OBJID_CARET: c.DWORD = 0xFFFFFFF8; // -8
pub const CHILDID_SELF: c_long = 0;

pub const IAccessible = extern struct {
    lpVtbl: *const extern struct {
        QueryInterface: *anyopaque,
        AddRef: *anyopaque,
        Release: *const fn (*IAccessible) callconv(.winapi) c.ULONG,
        reserved: [19]*anyopaque, // Slots 3..21 (IDispatch + first 15 IAccessible methods)
        accLocation: *const fn (*IAccessible, *c.LONG, *c.LONG, *c.LONG, *c.LONG, c.VARIANT) callconv(.winapi) c.HRESULT, // Slot 22
    },
};

pub extern "oleacc" fn AccessibleObjectFromWindow(hwnd: c.HWND, dwId: c.DWORD, riid: *const c.GUID, ppvObject: *?*anyopaque) callconv(.winapi) c.HRESULT;

// User32 Window Positioning Export with 1-byte aligned handle parameters
pub extern "user32" fn SetWindowPos(hWnd: ?*anyopaque, hWndInsertAfter: ?*anyopaque, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: c.UINT) callconv(.winapi) c.BOOL;

// OLE Automation and DPI Awareness Function Exports
pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: c.DWORD) callconv(.winapi) c.HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(rclsid: *const c.GUID, pUnkOuter: ?*anyopaque, dwClsContext: c.DWORD, riid: *const c.GUID, ppv: *?*anyopaque) callconv(.winapi) c.HRESULT;
pub extern "oleaut32" fn SafeArrayAccessData(psa: *SafeArray, ppvData: *?*anyopaque) callconv(.winapi) c.HRESULT;
pub extern "oleaut32" fn SafeArrayUnaccessData(psa: *SafeArray) callconv(.winapi) c.HRESULT;
pub extern "oleaut32" fn SafeArrayDestroy(psa: *SafeArray) callconv(.winapi) c.HRESULT;

pub extern "user32" fn GetDpiForWindow(hwnd: c.HWND) callconv(.winapi) c.UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) c.BOOL;
