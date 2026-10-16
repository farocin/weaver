//! The daemon's line to an anchored widget host (ADR 0022 step 1): which
//! widgets the host runs. `weaverd` creates a pipe per host launch, names it
//! in WEAVER_CONTROL_PIPE, and writes one JSON command per line:
//!
//!     {"add":{"id":3,"dir":"...\\dist","pipe":"\\\\.\\pipe\\...","backend":"...backend-..."}}
//!     {"remove":{"id":3}}
//!
//! `id` is the daemon's slot for the widget: the host runs it in that slot,
//! and the crash breadcrumb names it as `id + 1`. The host answers each
//! command on the same pipe once it has taken effect, or why it did not:
//!
//!     {"added":3,"ok":true}   {"added":3,"ok":false,"error":"ManifestInvalid"}
//!     {"removed":3,"ok":true} {"removed":3,"ok":false,"error":"NoWidgetInSlot"}
//!     {"ok":false,"error":"InvalidCommand"}   (a line that is not a command)
//!
//! When the daemon closes the pipe, the host exits.
//!
//! The reader runs on its own thread and never touches widgets; it hands
//! each command to the UI thread and waits for its outcome.
const std = @import("std");
const builtin = @import("builtin");

/// Longest command line: three paths of at most 32,767 UTF-16 units each
/// (Windows' long-path ceiling) as UTF-8, plus the JSON around them.
pub const max_line_bytes: usize = 3 * 3 * 32 * 1024 + 256;

pub const Add = struct {
    id: u16,
    dir: []const u8,
    pipe: ?[]const u8 = null,
    backend: ?[]const u8 = null,
};

pub const Command = union(enum) {
    add: Add,
    remove: struct { id: u16 },
};

pub const ParseError = error{ InvalidCommand, OutOfMemory };

/// Parse one command line; the strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!Command {
    const Wire = struct {
        add: ?struct { id: u16, dir: []const u8, pipe: ?[]const u8 = null, backend: ?[]const u8 = null } = null,
        remove: ?struct { id: u16 } = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommand,
    };
    if (wire.add != null and wire.remove != null) return error.InvalidCommand;
    if (wire.add) |add| return .{ .add = .{ .id = add.id, .dir = add.dir, .pipe = add.pipe, .backend = add.backend } };
    if (wire.remove) |remove| return .{ .remove = .{ .id = remove.id } };
    return error.InvalidCommand;
}

/// One command handed to the UI thread, and its outcome handed back.
pub const Pending = struct {
    command: Command,
    /// What the reader prepared off the UI thread for an `add`.
    prepared: ?*anyopaque = null,
    /// Set by the UI thread: null when it took effect, else why not.
    failure: ?anyerror = null,
    done: std.Io.Event = .unset,
};

/// The command waiting for the UI thread. The reader posts one and waits
/// for it to be done, so there is never more than one.
pub const Mailbox = struct {
    pending: std.atomic.Value(?*Pending) = .init(null),

    pub fn post(self: *Mailbox, pending: *Pending) void {
        const previous = self.pending.swap(pending, .acq_rel);
        std.debug.assert(previous == null);
    }

    pub fn take(self: *Mailbox) ?*Pending {
        return self.pending.swap(null, .acq_rel);
    }

    pub fn waiting(self: *Mailbox) bool {
        return self.pending.load(.acquire) != null;
    }
};

/// Write the answer to `command` (one line).
pub fn answer(writer: *std.Io.Writer, command: Command, failure: ?anyerror) !void {
    const verb: []const u8, const id: u16 = switch (command) {
        .add => |add| .{ "added", add.id },
        .remove => |remove| .{ "removed", remove.id },
    };
    if (failure) |err|
        try writer.print("{{\"{s}\":{d},\"ok\":false,\"error\":\"{s}\"}}\n", .{ verb, id, @errorName(err) })
    else
        try writer.print("{{\"{s}\":{d},\"ok\":true}}\n", .{ verb, id });
}

/// Answer a line that is not a command (one line).
pub fn refuse(writer: *std.Io.Writer, err: anyerror) !void {
    try writer.print("{{\"ok\":false,\"error\":\"{s}\"}}\n", .{@errorName(err)});
}

/// The client end of the daemon's control pipe (Windows only).
pub const Pipe = struct {
    handle: std.os.windows.HANDLE,

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
    extern "kernel32" fn ReadFile(handle: std.os.windows.HANDLE, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn WriteFile(handle: std.os.windows.HANDLE, buffer: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn CloseHandle(handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;

    pub fn connect(name: []const u8) !Pipe {
        if (builtin.os.tag != .windows) return error.Unsupported;
        var wide: [512:0]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(&wide, name) catch return error.InvalidPipeName;
        if (length >= wide.len) return error.InvalidPipeName;
        wide[length] = 0;
        const generic_read: u32 = 0x80000000;
        const generic_write: u32 = 0x40000000;
        const open_existing: u32 = 3;
        const handle = CreateFileW(&wide, generic_read | generic_write, 0, null, open_existing, 0, null);
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.ConnectFailed;
        return .{ .handle = handle };
    }

    /// Bytes into `buffer`; zero when the daemon closed its end.
    pub fn read(self: Pipe, buffer: []u8) usize {
        var read_len: u32 = 0;
        if (ReadFile(self.handle, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(u32))), &read_len, null) == .FALSE) return 0;
        return read_len;
    }

    pub fn writeAll(self: Pipe, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            var written: u32 = 0;
            if (WriteFile(self.handle, remaining.ptr, @intCast(remaining.len), &written, null) == .FALSE) return error.WriteFailed;
            remaining = remaining[written..];
        }
    }

    pub fn close(self: Pipe) void {
        _ = CloseHandle(self.handle);
    }
};

/// Splits a byte stream into lines no longer than `max_line_bytes`.
pub const LineReader = struct {
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,

    /// The next complete line, without its newline; null when the buffered
    /// bytes hold none yet.
    pub fn next(self: *LineReader) ?[]const u8 {
        const newline = std.mem.indexOfScalar(u8, self.buffer[self.start..self.end], '\n') orelse return null;
        const line = self.buffer[self.start .. self.start + newline];
        self.start += newline + 1;
        return std.mem.trimEnd(u8, line, "\r");
    }

    /// Room to read into, after moving unread bytes to the front; empty when
    /// a line has outgrown the buffer.
    pub fn space(self: *LineReader) []u8 {
        if (self.start > 0) {
            std.mem.copyForwards(u8, self.buffer[0 .. self.end - self.start], self.buffer[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        return self.buffer[self.end..];
    }

    pub fn filled(self: *LineReader, count: usize) void {
        self.end += count;
    }
};

test "commands parse, and anything else is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const add = try parse(arena, "{\"add\":{\"id\":3,\"dir\":\"C:\\\\w\\\\dist\",\"pipe\":\"\\\\\\\\.\\\\pipe\\\\p\",\"backend\":\"b\"}}");
    try std.testing.expectEqual(@as(u16, 3), add.add.id);
    try std.testing.expectEqualStrings("C:\\w\\dist", add.add.dir);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\p", add.add.pipe.?);
    const remove = try parse(arena, "{\"remove\":{\"id\":7}}");
    try std.testing.expectEqual(@as(u16, 7), remove.remove.id);
    try std.testing.expectError(error.InvalidCommand, parse(arena, "{}"));
    try std.testing.expectError(error.InvalidCommand, parse(arena, "{\"add\":{\"id\":1,\"dir\":\"d\"},\"remove\":{\"id\":1}}"));
    try std.testing.expectError(error.InvalidCommand, parse(arena, "not json"));
}

test "answers name the command and its outcome" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try answer(&output.writer, .{ .add = .{ .id = 2, .dir = "d" } }, null);
    try answer(&output.writer, .{ .add = .{ .id = 4, .dir = "d" } }, error.ManifestInvalid);
    try answer(&output.writer, .{ .remove = .{ .id = 4 } }, null);
    try answer(&output.writer, .{ .remove = .{ .id = 5 } }, error.NoWidgetInSlot);
    try refuse(&output.writer, error.InvalidCommand);
    try std.testing.expectEqualStrings(
        "{\"added\":2,\"ok\":true}\n{\"added\":4,\"ok\":false,\"error\":\"ManifestInvalid\"}\n" ++
            "{\"removed\":4,\"ok\":true}\n{\"removed\":5,\"ok\":false,\"error\":\"NoWidgetInSlot\"}\n" ++
            "{\"ok\":false,\"error\":\"InvalidCommand\"}\n",
        output.written(),
    );
}

test "the mailbox holds one command until it is taken" {
    var mailbox: Mailbox = .{};
    try std.testing.expect(!mailbox.waiting());
    var pending: Pending = .{ .command = .{ .remove = .{ .id = 1 } } };
    mailbox.post(&pending);
    try std.testing.expect(mailbox.waiting());
    try std.testing.expectEqual(&pending, mailbox.take().?);
    try std.testing.expect(mailbox.take() == null);
}

test "lines split across reads come out whole" {
    var storage: [64]u8 = undefined;
    var reader: LineReader = .{ .buffer = &storage };
    const parts = [_][]const u8{ "{\"a\":1}\n{\"b\"", ":2}\r\n" };
    const expected = [_][]const u8{ "{\"a\":1}", "{\"b\":2}" };
    var count: usize = 0;
    for (parts) |part| {
        const room = reader.space();
        @memcpy(room[0..part.len], part);
        reader.filled(part.len);
        // A line is valid until the next `space`.
        while (reader.next()) |line| : (count += 1) try std.testing.expectEqualStrings(expected[count], line);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
