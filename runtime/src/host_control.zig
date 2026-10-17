//! The daemon's line to an anchored widget host (ADR 0022): which widgets
//! the host runs, its dev widgets, and its providers' counters. `weaverd`
//! creates a pipe per host launch, names it in WEAVER_CONTROL_PIPE, and
//! writes one JSON command per line:
//!
//!     {"add":{"id":3,"dir":"...\\dist","backend":"...backend-..."}}
//!     {"remove":{"id":3}}
//!     {"launchDev":{"id":7,"dir":"...\\dist","backend":"...","subscribe":["cpu"],"capabilities":[],"gpu":false}}
//!     {"stopDev":{"id":7,"graceful":true}}
//!     {"providers":{}}
//!
//! An `add` id is the daemon's slot for the widget in the host: the host
//! runs it in that slot, and the crash breadcrumb names it as `id + 1`. A
//! dev id is the widget's slot in the daemon's registry. The host answers
//! each command on the same pipe once it has taken effect, or why it did
//! not:
//!
//!     {"added":3,"ok":true}   {"added":3,"ok":false,"error":"ManifestInvalid"}
//!     {"removed":3,"ok":true} {"removed":3,"ok":false,"error":"NoWidgetInSlot"}
//!     {"launchedDev":7,"ok":true,"pid":1234}   {"stoppedDev":7,"ok":true}
//!     {"providers":{"systemSampleCount":12,...},"failed":{"hosted":[3],"dev":[]},"ok":true}
//!     {"ok":false,"error":"InvalidCommand"}   (a line that is not a command)
//!
//! `failed` names the widgets whose provider channel failed since the last
//! `providers` command, for the daemon to restart. When the daemon closes
//! the pipe, the host exits.
//!
//! The reader runs on its own thread and never touches widgets: it hands
//! `add` and `remove` to the UI thread and waits for their outcome, and
//! carries out the rest itself.
const std = @import("std");
const builtin = @import("builtin");

/// Longest command line: three paths of at most 32,767 UTF-16 units each
/// (Windows' long-path ceiling) as UTF-8, plus the JSON around them.
pub const max_line_bytes: usize = 3 * 3 * 32 * 1024 + 256;

/// Longest answer: a `providers` answer with every counter at its widest
/// and every widget failed measures 589 bytes (the test below). weaverd's
/// answer buffer (host/src/windows_host.zig ControlAnswer) is this size.
pub const max_answer_bytes: usize = 1024;

pub const Add = struct {
    id: u16,
    dir: []const u8,
    backend: ?[]const u8 = null,
};

pub const LaunchDev = struct {
    id: u16,
    dir: []const u8,
    backend: ?[]const u8 = null,
    /// Its manifest's `subscribe` and `capabilities`, as weaverd read them.
    subscribe: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
    gpu: bool = false,
};

pub const StopDev = struct {
    id: u16,
    graceful: bool = false,
};

pub const Command = union(enum) {
    add: Add,
    remove: struct { id: u16 },
    launch_dev: LaunchDev,
    stop_dev: StopDev,
    providers,

    /// Whether the UI thread carries it out (it touches widgets).
    pub fn forUiThread(self: Command) bool {
        return switch (self) {
            .add, .remove => true,
            .launch_dev, .stop_dev, .providers => false,
        };
    }
};

pub const ParseError = error{ InvalidCommand, OutOfMemory };

/// Parse one command line; the strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!Command {
    const Wire = struct {
        add: ?Add = null,
        remove: ?struct { id: u16 } = null,
        launchDev: ?LaunchDev = null,
        stopDev: ?StopDev = null,
        providers: ?struct {} = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommand,
    };
    var found: ?Command = null;
    var count: usize = 0;
    if (wire.add) |add| {
        found = .{ .add = add };
        count += 1;
    }
    if (wire.remove) |remove| {
        found = .{ .remove = .{ .id = remove.id } };
        count += 1;
    }
    if (wire.launchDev) |launch| {
        found = .{ .launch_dev = launch };
        count += 1;
    }
    if (wire.stopDev) |stop| {
        found = .{ .stop_dev = stop };
        count += 1;
    }
    if (wire.providers != null) {
        found = .providers;
        count += 1;
    }
    if (count != 1) return error.InvalidCommand;
    return found.?;
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

/// Write the answer to an `add`, `remove` or `stopDev` (one line).
pub fn answer(writer: *std.Io.Writer, command: Command, failure: ?anyerror) !void {
    const verb: []const u8, const id: u16 = switch (command) {
        .add => |add| .{ "added", add.id },
        .remove => |remove| .{ "removed", remove.id },
        .stop_dev => |stop| .{ "stoppedDev", stop.id },
        .launch_dev, .providers => unreachable,
    };
    if (failure) |err|
        try writer.print("{{\"{s}\":{d},\"ok\":false,\"error\":\"{s}\"}}\n", .{ verb, id, @errorName(err) })
    else
        try writer.print("{{\"{s}\":{d},\"ok\":true}}\n", .{ verb, id });
}

/// Write the answer to a `launchDev`: the dev widget's PID, or why it did
/// not launch.
pub fn answerLaunched(writer: *std.Io.Writer, id: u16, result: anyerror!u32) !void {
    if (result) |pid|
        try writer.print("{{\"launchedDev\":{d},\"ok\":true,\"pid\":{d}}}\n", .{ id, pid })
    else |err|
        try writer.print("{{\"launchedDev\":{d},\"ok\":false,\"error\":\"{s}\"}}\n", .{ id, @errorName(err) });
}

/// The providers' counters, under the names weaverd's status publishes
/// them with (host/src/supervisor.zig ProviderStatus).
pub const ProviderStatus = struct {
    system_sample_count: u64 = 0,
    system_frames: u64 = 0,
    audio_capture_active: bool = false,
    audio_silent: bool = true,
    audio_frames: u64 = 0,
    audio_availability: []const u8 = "idle",
    audio_capture_starts: u64 = 0,
    audio_provider_frames: u64 = 0,
    audio_last_error: i32 = 0,
    media_frames: u64 = 0,
};

/// Write the answer to `providers`: the counters, and the hosted slots and
/// dev ids (a bit each) whose provider channel failed.
pub fn answerProviders(writer: *std.Io.Writer, status: ProviderStatus, failed_hosted: u32, failed_dev: u32) !void {
    try writer.print(
        "{{\"providers\":{{\"systemSampleCount\":{d},\"systemFrames\":{d},\"audioCaptureActive\":{},\"audioSilent\":{},\"audioPipeFrames\":{d},\"audioAvailability\":\"{s}\",\"audioCaptureStarts\":{d},\"audioProviderFrames\":{d},\"audioLastError\":{d},\"mediaPipeFrames\":{d}}},\"failed\":{{\"hosted\":",
        .{ status.system_sample_count, status.system_frames, status.audio_capture_active, status.audio_silent, status.audio_frames, status.audio_availability, status.audio_capture_starts, status.audio_provider_frames, status.audio_last_error, status.media_frames },
    );
    try writeIds(writer, failed_hosted);
    try writer.writeAll(",\"dev\":");
    try writeIds(writer, failed_dev);
    try writer.writeAll("},\"ok\":true}\n");
}

fn writeIds(writer: *std.Io.Writer, bits: u32) !void {
    try writer.writeByte('[');
    var first = true;
    for (0..32) |id| {
        if (bits & (@as(u32, 1) << @intCast(id)) == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{d}", .{id});
    }
    try writer.writeByte(']');
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
    const add = try parse(arena, "{\"add\":{\"id\":3,\"dir\":\"C:\\\\w\\\\dist\",\"backend\":\"b\"}}");
    try std.testing.expectEqual(@as(u16, 3), add.add.id);
    try std.testing.expectEqualStrings("C:\\w\\dist", add.add.dir);
    try std.testing.expectEqualStrings("b", add.add.backend.?);
    try std.testing.expect(add.forUiThread());
    const launch = try parse(arena, "{\"launchDev\":{\"id\":7,\"dir\":\"d\",\"subscribe\":[\"cpu\"],\"capabilities\":[\"media-transport\"],\"gpu\":true}}");
    try std.testing.expectEqual(@as(u16, 7), launch.launch_dev.id);
    try std.testing.expectEqualStrings("cpu", launch.launch_dev.subscribe[0]);
    try std.testing.expect(launch.launch_dev.gpu and !launch.forUiThread());
    const stop = try parse(arena, "{\"stopDev\":{\"id\":7,\"graceful\":true}}");
    try std.testing.expect(stop.stop_dev.graceful);
    try std.testing.expectEqual(Command.providers, try parse(arena, "{\"providers\":{}}"));
    try std.testing.expectError(error.InvalidCommand, parse(arena, "{\"providers\":{},\"stopDev\":{\"id\":1}}"));
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
    try answerLaunched(&output.writer, 7, 1234);
    try answerLaunched(&output.writer, 8, error.ConnectPipeFailed);
    try answer(&output.writer, .{ .stop_dev = .{ .id = 7 } }, null);
    try std.testing.expectEqualStrings(
        "{\"added\":2,\"ok\":true}\n{\"added\":4,\"ok\":false,\"error\":\"ManifestInvalid\"}\n" ++
            "{\"removed\":4,\"ok\":true}\n{\"removed\":5,\"ok\":false,\"error\":\"NoWidgetInSlot\"}\n" ++
            "{\"ok\":false,\"error\":\"InvalidCommand\"}\n" ++
            "{\"launchedDev\":7,\"ok\":true,\"pid\":1234}\n{\"launchedDev\":8,\"ok\":false,\"error\":\"ConnectPipeFailed\"}\n" ++
            "{\"stoppedDev\":7,\"ok\":true}\n",
        output.written(),
    );
}

test "a providers answer names the counters and the failed widgets, within max_answer_bytes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try answerProviders(&output.writer, .{ .system_sample_count = 12, .audio_frames = 3 }, (1 << 3) | (1 << 30), 0);
    try std.testing.expectEqualStrings(
        "{\"providers\":{\"systemSampleCount\":12,\"systemFrames\":0,\"audioCaptureActive\":false,\"audioSilent\":true,\"audioPipeFrames\":3,\"audioAvailability\":\"idle\",\"audioCaptureStarts\":0,\"audioProviderFrames\":0,\"audioLastError\":0,\"mediaPipeFrames\":0},\"failed\":{\"hosted\":[3,30],\"dev\":[]},\"ok\":true}\n",
        output.written(),
    );
    output.clearRetainingCapacity();
    const max = std.math.maxInt(u64);
    try answerProviders(&output.writer, .{
        .system_sample_count = max,
        .system_frames = max,
        .audio_silent = false,
        .audio_frames = max,
        .audio_availability = "authorization-required",
        .audio_capture_starts = max,
        .audio_provider_frames = max,
        .audio_last_error = std.math.minInt(i32),
        .media_frames = max,
    }, std.math.maxInt(u32), std.math.maxInt(u32));
    try std.testing.expectEqual(@as(usize, 589), output.written().len);
    try std.testing.expect(output.written().len <= max_answer_bytes);
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
