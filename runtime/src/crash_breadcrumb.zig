//! Which hosted widget was running when the host process died. The daemon
//! creates a 4-byte shared mapping per host launch and names it in
//! WEAVER_CRASH_BREADCRUMB; the host writes the running widget's position
//! in its `--host` argument list (plus one; zero is "between widgets")
//! every time it enters a widget. The daemon reads the value after the
//! process is gone, so attribution needs no crash handler and survives any
//! kind of fault: a Zig panic, an access violation in QuickJS, a driver
//! crash.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

var cell: ?*volatile u32 = null;

extern "kernel32" fn OpenFileMappingW(access: u32, inherit: windows.BOOL, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn MapViewOfFile(mapping: windows.HANDLE, access: u32, offset_high: u32, offset_low: u32, bytes: usize) callconv(.winapi) ?*anyopaque;

/// Map the daemon's breadcrumb. A missing or unmappable name leaves
/// attribution off: the host still runs, its crashes are just unattributed.
pub fn open(name: []const u8) void {
    if (builtin.os.tag != .windows) return;
    var wide: [128:0]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, name) catch return;
    if (length >= wide.len) return;
    wide[length] = 0;
    const file_map_write: u32 = 0x0002;
    const mapping = OpenFileMappingW(file_map_write, .FALSE, &wide) orelse return;
    const view = MapViewOfFile(mapping, file_map_write, 0, 0, @sizeOf(u32)) orelse return;
    cell = @ptrCast(@alignCast(view));
}

/// Record that the widget at `argument` (its position in `--host`) is
/// running now.
pub fn mark(argument: u16) void {
    if (cell) |value| value.* = @as(u32, argument) + 1;
}
