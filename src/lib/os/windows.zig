//! Exposes Windows specific functionality.
pub const BOOL = c_int;
pub const CHAR = u8;
pub const WCHAR = u16;
pub const DWORD = u32;
pub const HANDLE = *anyopaque;
pub const HMODULE = *opaque {};
pub const FARPROC = *opaque {};
pub const LPCWSTR = [*:0]const WCHAR;
pub const LPCSTR = [*:0]const CHAR;

pub extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: LPCWSTR,
    hFile: ?HANDLE,
    dwFlags: DWORD,
) callconv(.winapi) ?HMODULE;

pub extern "kernel32" fn GetProcAddress(
    hModule: HMODULE,
    lpProcName: LPCSTR,
) callconv(.winapi) ?FARPROC;

pub extern "kernel32" fn FreeLibrary(
    hModule: HMODULE,
) callconv(.winapi) BOOL;
