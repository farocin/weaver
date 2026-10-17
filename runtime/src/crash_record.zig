//! The widget host's record of itself (ADR 0022): which generation of the
//! host is running, and, when it dies, whether a widget's code was running
//! on the thread that crashed. A daemon host keeps it mapped from
//! `%LOCALAPPDATA%\weaver\host.record`; the daemon reads it after the
//! process is gone. Mapped file pages outlive the process, so a crash needs
//! no flush, and the crash path only does plain stores into a slot that
//! was there from the start: the faulting thread's stack and heap may be
//! broken.
//!
//! A crash is attributed to a widget only on evidence: the thread that
//! crashed was running that widget's JavaScript turn (`beginTurn`). Any
//! other crash, and a host that is gone with no crash written (killed, or a
//! fault no handler saw), names no widget.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const magic: u32 = 0x5248_5657; // "WVHR"
pub const version: u32 = 1;

pub const State = enum(u32) { none = 0, running = 1, stopped = 2, _ };

pub const CrashKind = enum(u32) {
    none = 0,
    /// The thread was running a widget's turn: `Crash.slot` names it.
    widget_turn = 1,
    /// The UI thread, outside any widget's turn.
    ui = 2,
    /// Any other thread outside a widget's turn.
    other = 3,
    _,
};

/// The exception code recorded for a Zig panic (`notePanic`): "panic" in
/// the customer bit range of NTSTATUS, so it never collides with a real
/// exception code.
pub const panic_code: u32 = 0xE057_0001;

/// The widget whose turn is running, and on which thread.
pub const Turn = extern struct {
    /// Its slot in the host plus one; zero between turns.
    slot: u32 = 0,
    thread: u32 = 0,
    /// Wyhash of its bundle.js, as loaded.
    bundle: u64 = 0,
};

pub const Crash = extern struct {
    kind: CrashKind = .none,
    /// The exception code, or `panic_code`.
    code: u32 = 0,
    thread: u32 = 0,
    /// For `widget_turn`: the widget's slot plus one and its bundle.
    slot: u32 = 0,
    bundle: u64 = 0,
    /// When it happened, as a Windows FILETIME.
    time: u64 = 0,
};

/// The file's layout. weaverd mirrors it (host/src/windows_host.zig,
/// `HostRecord`); change both together and bump `version`.
pub const Record = extern struct {
    magic: u32,
    version: u32,
    /// One more than the previous host's: tells a reader which start a
    /// record belongs to.
    generation: u64,
    pid: u32,
    state: State,
    /// Process creation time (FILETIME): with `pid`, tells this process
    /// from a later one that reused its PID.
    start_time: u64,
    turn: Turn,
    crash: Crash,
};

comptime {
    std.debug.assert(@sizeOf(Record) == 80);
}

var record: ?*volatile Record = null;
var ui_thread: u32 = 0;

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CreateFileMappingW(file: windows.HANDLE, security: ?*anyopaque, protect: u32, size_high: u32, size_low: u32, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn MapViewOfFile(mapping: windows.HANDLE, access: u32, offset_high: u32, offset_low: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetProcessTimes(process: windows.HANDLE, creation: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetSystemTimeAsFileTime(time: *u64) callconv(.winapi) void;
extern "kernel32" fn SetUnhandledExceptionFilter(filter: ?*const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn RaiseFailFastException(record: ?*windows.EXCEPTION_RECORD, context: ?*windows.CONTEXT, flags: u32) callconv(.winapi) noreturn;

/// Map the record at `path` (creating it), start a new generation marked
/// running, and route unhandled exceptions through `noteCrash`. Called on
/// the UI thread, before any widget loads. A record that can't be opened
/// leaves attribution off; the host still runs.
pub fn open(path: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    var wide: [1024:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, path);
    if (length >= wide.len) return error.NameTooLong;
    wide[length] = 0;
    const generic_read: u32 = 0x8000_0000;
    const generic_write: u32 = 0x4000_0000;
    // Readers (the daemon) and deletion may share it; another writer may
    // not: two hosts on one record would mix one's identity with the
    // other's crash. A second host runs without attribution instead.
    const share_read_delete: u32 = 0x1 | 0x4;
    const open_always: u32 = 4;
    const file = CreateFileW(&wide, generic_read | generic_write, share_read_delete, null, open_always, 0, null);
    if (file == windows.INVALID_HANDLE_VALUE) return error.RecordInUse;
    defer _ = CloseHandle(file);
    // A mapping larger than the file extends it.
    const page_readwrite: u32 = 0x04;
    const mapping = CreateFileMappingW(file, null, page_readwrite, 0, @sizeOf(Record), null) orelse return error.MapFailed;
    defer _ = CloseHandle(mapping);
    const file_map_write: u32 = 0x0002;
    const view = MapViewOfFile(mapping, file_map_write, 0, 0, @sizeOf(Record)) orelse return error.MapFailed;
    const mapped: *volatile Record = @ptrCast(@alignCast(view));
    const previous = if (mapped.magic == magic and mapped.version == version) mapped.generation else 0;
    var created: u64 = 0;
    var unused: u64 = 0;
    _ = GetProcessTimes(GetCurrentProcess(), &created, &unused, &unused, &unused);
    // Running is written last: a reader never sees a running record with
    // another start's fields.
    mapped.state = .none;
    mapped.magic = magic;
    mapped.version = version;
    mapped.generation = previous + 1;
    mapped.pid = GetCurrentProcessId();
    mapped.start_time = created;
    mapped.turn = .{};
    mapped.crash = .{};
    mapped.state = .running;
    ui_thread = GetCurrentThreadId();
    record = mapped;
    _ = SetUnhandledExceptionFilter(onUnhandledException);
}

/// Stop recording and unmap the record (tests; a host keeps it to the end).
pub fn close() void {
    const mapped = record orelse return;
    record = null;
    _ = SetUnhandledExceptionFilter(null);
    _ = UnmapViewOfFile(@volatileCast(mapped));
}

/// The host is exiting on purpose.
pub fn markStopped() void {
    const mapped = record orelse return;
    mapped.state = .stopped;
}

/// A widget's turn starts on this thread: `slot` is its slot in the host.
pub fn beginTurn(slot: u16, bundle: u64) void {
    const mapped = record orelse return;
    mapped.turn.thread = GetCurrentThreadId();
    mapped.turn.bundle = bundle;
    mapped.turn.slot = @as(u32, slot) + 1;
}

pub fn endTurn() void {
    const mapped = record orelse return;
    mapped.turn.slot = 0;
}

/// Fill the crash slot for a crash on the calling thread: plain stores, no
/// allocation, no locks. The first crash wins.
pub fn noteCrash(code: u32) void {
    const mapped = record orelse return;
    if (mapped.crash.kind != .none) return;
    const thread = GetCurrentThreadId();
    const turn_slot = mapped.turn.slot;
    const in_turn = turn_slot != 0 and mapped.turn.thread == thread;
    var now: u64 = 0;
    GetSystemTimeAsFileTime(&now);
    mapped.crash.code = code;
    mapped.crash.thread = thread;
    mapped.crash.slot = if (in_turn) turn_slot else 0;
    mapped.crash.bundle = if (in_turn) mapped.turn.bundle else 0;
    mapped.crash.time = now;
    mapped.crash.kind = if (in_turn) .widget_turn else if (thread == ui_thread) .ui else .other;
}

/// A Zig panic, before its diagnostics run.
pub fn notePanic() void {
    noteCrash(panic_code);
}

fn onUnhandledException(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    noteCrash(info.ExceptionRecord.ExceptionCode);
    // Fail fast whether or not the store landed: nothing else may run on a
    // broken thread, and Windows Error Reporting still sees the crash.
    RaiseFailFastException(info.ExceptionRecord, info.ContextRecord, 0);
}

test "a crash in a widget's turn names it; one outside a turn names no one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var storage: Record = std.mem.zeroes(Record);
    record = &storage;
    defer record = null;
    ui_thread = GetCurrentThreadId();
    beginTurn(4, 0xabcd);
    noteCrash(0xC000_0005);
    try std.testing.expectEqual(CrashKind.widget_turn, storage.crash.kind);
    try std.testing.expectEqual(@as(u32, 5), storage.crash.slot);
    try std.testing.expectEqual(@as(u64, 0xabcd), storage.crash.bundle);
    // The first crash wins.
    noteCrash(panic_code);
    try std.testing.expectEqual(@as(u32, 0xC000_0005), storage.crash.code);

    storage.crash = .{};
    endTurn();
    notePanic();
    try std.testing.expectEqual(CrashKind.ui, storage.crash.kind);
    try std.testing.expectEqual(@as(u32, 0), storage.crash.slot);

    // A turn running on another thread doesn't make this thread's crash its.
    storage.crash = .{};
    beginTurn(2, 1);
    storage.turn.thread +%= 1;
    const Other = struct {
        fn crash() void {
            noteCrash(0xC000_0005);
        }
    };
    const thread = try std.Thread.spawn(.{}, Other.crash, .{});
    thread.join();
    try std.testing.expectEqual(CrashKind.other, storage.crash.kind);
}

test "a new start takes the next generation and clears the last crash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "host.record" });
    defer std.testing.allocator.free(path);
    try open(path);
    const first = record.?.generation;
    noteCrash(0xC000_0005);
    close();
    try open(path);
    defer close();
    try std.testing.expectEqual(first + 1, record.?.generation);
    try std.testing.expectEqual(State.running, record.?.state);
    try std.testing.expectEqual(CrashKind.none, record.?.crash.kind);
    try std.testing.expectEqual(GetCurrentProcessId(), record.?.pid);
}
