//! weaverd on Windows (ADR 0022 step 4): it starts the widget host
//! (`weaver-widget --host`), and restarts it after a crash. The host is the
//! daemon: it owns the registry, the control objects, status, the crash
//! ledger, the providers, dev widgets and the renderer
//! (runtime/src/daemon.zig). Step 5 replaces this process with the OS's
//! restart, and deletes it.
//!
//! weaverd also carries the CLI's client side of the host's control
//! objects (`--probe`, `--probe-reload-ready`, `--signal-reload`,
//! `--signal-down`): a small process the CLI can spawn quickly.
const std = @import("std");
const backoff = @import("backoff.zig");
const contract = @import("host_contract.zig");

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

/// How long `--signal-reload` waits for another CLI's reload to finish, and
/// then for the host's acknowledgement: weaverd's limits, which reloads have
/// always met.
const reload_signal_wait_ms: u32 = 10_000;
const reload_answer_wait_ms: u32 = 10_000;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1) return supervise(init);
    if (args.len == 2) {
        const command = args[1];
        if (std.mem.eql(u8, command, "--signal-down")) return signalEvent(contract.shutdown_event);
        if (std.mem.eql(u8, command, "--signal-reload")) return signalReloadAndWait();
        if (std.mem.eql(u8, command, "--probe")) return probeMutex(contract.singleton_mutex);
        if (std.mem.eql(u8, command, "--probe-reload-ready")) {
            try probeMutex(contract.singleton_mutex);
            return probeEvent(contract.reload_failure_event);
        }
    }
    // An unknown argument must not start a supervisor against the real
    // profile.
    std.debug.print("usage: weaverd [--probe | --probe-reload-ready | --signal-reload | --signal-down]\n", .{});
    return error.InvalidArguments;
}

/// What weaverd knows across host starts: the crashes no widget was blamed
/// for, and how it started the host now running.
const Supervision = struct {
    crash_times: [backoff.history_capacity]u64 = @splat(0),
    crash_count: usize = 0,
    /// Passed to the next host (`contract.env_host_crashes`): zero for a
    /// fresh start.
    crashes: usize = 0,
    exit_code: u32 = 0,

    const Decision = enum { stop, restart, give_up };

    /// The host now running holds every widget stopped.
    fn held(self: *const Supervision) bool {
        return self.crashes > backoff.restart_limit;
    }

    /// The host exited with `exit_code`. `stopped` is what its record says
    /// (a clean `weaver down`, or a startup error returned from main), and
    /// `attributed` whether it crashed inside a widget's turn.
    fn hostExited(self: *Supervision, exit_code: u32, stopped: bool, attributed: bool, now_ms: u64) Decision {
        if (stopped or exit_code == 0 or exit_code == contract.exit_already_running) return .stop;
        // The next host quarantines that widget; the others start at once,
        // and the crash counts toward nothing, as when weaverd ran them.
        if (attributed) return .restart;
        // A host holding every widget still crashed: the fault is the
        // host's own, and restarting it again would only loop.
        if (self.held()) return .give_up;
        _ = backoff.recordCrash(&self.crash_times, &self.crash_count, now_ms);
        self.crashes = self.crash_count;
        self.exit_code = exit_code;
        return .restart;
    }
};

fn supervise(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const local_app_data = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    const record_path = try std.fs.path.join(allocator, &.{ local_app_data, "weaver", "host.record" });
    defer allocator.free(record_path);
    const record_path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, record_path);
    defer allocator.free(record_path_w);
    const repo_root = try repositoryRoot(allocator);
    defer allocator.free(repo_root);
    const runtime_exe = try std.fs.path.join(allocator, &.{ repo_root, "runtime", "zig-out", "bin", "weaver-widget.exe" });
    defer allocator.free(runtime_exe);
    var supervision: Supervision = .{};
    while (true) {
        const host = try startHost(allocator, runtime_exe, &supervision);
        _ = c.WaitForSingleObject(host.process, c.INFINITE);
        var exit_code: c.DWORD = 1;
        _ = c.GetExitCodeProcess(host.process, &exit_code);
        const record = readHostRecord(record_path_w, host.process, host.pid);
        _ = c.CloseHandle(host.process);
        const stopped = if (record) |value| value.state == .stopped else false;
        const attributed = if (record) |value| value.state == .running and value.crash.kind == .widget_turn else false;
        switch (supervision.hostExited(exit_code, stopped, attributed, c.GetTickCount64())) {
            .stop => return,
            .restart => {},
            .give_up => {
                std.debug.print("weaverd: the widget host crashed again while it held every widget (exit code 0x{X:0>8}); not restarting it. Run 'weaver up' to try again.\n", .{exit_code});
                return;
            },
        }
    }
}

const Started = struct { process: c.HANDLE, pid: u32 };

/// `"<runtime>" --host`, told which restart it is (`contract.env_host_*`).
fn startHost(allocator: std.mem.Allocator, runtime_exe: []const u8, supervision: *const Supervision) !Started {
    const crashes_w = std.unicode.utf8ToUtf16LeStringLiteral(contract.env_host_crashes);
    const exit_code_w = std.unicode.utf8ToUtf16LeStringLiteral(contract.env_host_exit_code);
    if (supervision.crashes == 0) {
        _ = c.SetEnvironmentVariableW(crashes_w, null);
        _ = c.SetEnvironmentVariableW(exit_code_w, null);
    } else {
        var buffer: [24]u8 = undefined;
        try setEnv(allocator, crashes_w, try std.fmt.bufPrint(&buffer, "{d}", .{supervision.crashes}));
        try setEnv(allocator, exit_code_w, try std.fmt.bufPrint(&buffer, "{d}", .{supervision.exit_code}));
    }
    const command = try std.fmt.allocPrint(allocator, "\"{s}\" --host", .{runtime_exe});
    defer allocator.free(command);
    const command_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
    defer allocator.free(command_w);
    var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    var info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
    if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &info) == 0) return error.CreateProcessFailed;
    _ = c.CloseHandle(info.hThread);
    return .{ .process = info.hProcess, .pid = info.dwProcessId };
}

/// The record of the host that just exited, if it is that host's: the
/// same PID and process start time. Read with Win32 directly: std.Io's
/// Windows file calls take 256-512 KiB stack frames, which would stay
/// resident in weaverd for the rest of its life.
fn readHostRecord(path: [:0]const u16, process: c.HANDLE, pid: u32) ?contract.Record {
    var bytes: [@sizeOf(contract.Record)]u8 = undefined;
    const file = c.CreateFileW(path.ptr, c.GENERIC_READ, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return null;
    defer _ = c.CloseHandle(file);
    var read: c.DWORD = 0;
    if (c.ReadFile(file, &bytes, bytes.len, &read, null) == 0) return null;
    const record = contract.parseRecord(bytes[0..read]) orelse return null;
    if (record.pid != pid) return null;
    var created: c.FILETIME = undefined;
    var unused: c.FILETIME = undefined;
    if (c.GetProcessTimes(process, &created, &unused, &unused, &unused) == 0) return null;
    const start: u64 = (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
    if (record.start_time != start) return null;
    return record;
}

/// Succeeds while the host holds the named object.
fn probeMutex(name: [*:0]const u16) !void {
    const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, name) orelse return error.HostNotRunning;
    _ = c.CloseHandle(handle);
}

fn probeEvent(name: [*:0]const u16) !void {
    const handle = c.OpenEventW(c.SYNCHRONIZE, 0, name) orelse return error.HostNotRunning;
    _ = c.CloseHandle(handle);
}

fn signalEvent(name: [*:0]const u16) !void {
    const event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(event);
    if (c.SetEvent(event) == 0) return error.SignalFailed;
}

fn signalReloadAndWait() !void {
    const signal_mutex = c.CreateMutexW(null, 0, contract.reload_signal_mutex) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(signal_mutex);
    const mutex_wait = c.WaitForSingleObject(signal_mutex, reload_signal_wait_ms);
    if (mutex_wait != c.WAIT_OBJECT_0 and mutex_wait != c.WAIT_ABANDONED) return error.ReloadSignalBusy;
    defer _ = c.ReleaseMutex(signal_mutex);

    const desired_access = c.SYNCHRONIZE | c.EVENT_MODIFY_STATE;
    const success_event = c.OpenEventW(desired_access, 0, contract.reload_success_event) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(success_event);
    const failure_event = c.OpenEventW(desired_access, 0, contract.reload_failure_event) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(failure_event);
    const reload_event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, contract.reload_event) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(reload_event);
    if (c.ResetEvent(success_event) == 0 or c.ResetEvent(failure_event) == 0) return error.SignalFailed;
    if (c.SetEvent(reload_event) == 0) return error.SignalFailed;
    const acknowledgements = [_]c.HANDLE{ success_event, failure_event };
    const wait = c.WaitForMultipleObjects(acknowledgements.len, &acknowledgements, 0, reload_answer_wait_ms);
    if (wait == c.WAIT_OBJECT_0) return;
    if (wait == c.WAIT_OBJECT_0 + 1) return error.RegistryReloadFailed;
    return error.RegistryReloadTimedOut;
}

fn repositoryRoot(allocator: std.mem.Allocator) ![]u8 {
    // Windows' longest path, on the heap rather than weaverd's stack.
    const path_w = try allocator.alloc(u16, 32768);
    defer allocator.free(path_w);
    const length = c.GetModuleFileNameW(null, path_w.ptr, @intCast(path_w.len));
    if (length == 0 or length == path_w.len) return error.ExecutablePathFailed;
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_w[0..length]);
    defer allocator.free(path);
    // <repo>\host\zig-out\bin\weaverd.exe
    var root: []const u8 = path;
    for (0..4) |_| root = std.fs.path.dirname(root) orelse return error.ExecutablePathFailed;
    return allocator.dupe(u8, root);
}

fn setEnv(allocator: std.mem.Allocator, name: [*:0]const u16, value: []const u8) !void {
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(value_w);
    if (c.SetEnvironmentVariableW(name, value_w.ptr) == 0) return error.SetEnvironmentFailed;
}

test "a clean exit stops weaverd, and a widget's crash restarts at once without counting" {
    var supervision: Supervision = .{};
    try std.testing.expectEqual(Supervision.Decision.stop, supervision.hostExited(0, false, false, 1_000));
    try std.testing.expectEqual(Supervision.Decision.stop, supervision.hostExited(1, true, false, 1_000));
    try std.testing.expectEqual(Supervision.Decision.stop, supervision.hostExited(contract.exit_already_running, false, false, 1_000));
    try std.testing.expectEqual(Supervision.Decision.restart, supervision.hostExited(0xC000_0005, false, true, 1_000));
    try std.testing.expectEqual(@as(usize, 0), supervision.crashes);
}

test "crashes no widget is blamed for back off, then hold every widget, then give up" {
    var supervision: Supervision = .{};
    for (1..backoff.restart_limit + 2) |count| {
        try std.testing.expectEqual(Supervision.Decision.restart, supervision.hostExited(0xC000_0005, false, false, count * 1_000));
        try std.testing.expectEqual(count, supervision.crashes);
        try std.testing.expectEqual(@as(u32, 0xC000_0005), supervision.exit_code);
    }
    try std.testing.expect(supervision.held());
    // A widget's crash in a held host keeps it held.
    try std.testing.expectEqual(Supervision.Decision.restart, supervision.hostExited(0xC000_0005, false, true, 9_000));
    try std.testing.expect(supervision.held());
    try std.testing.expectEqual(Supervision.Decision.give_up, supervision.hostExited(1, false, false, 10_000));
}

test "crashes outside the window are forgotten" {
    var supervision: Supervision = .{};
    _ = supervision.hostExited(1, false, false, 1_000);
    _ = supervision.hostExited(1, false, false, 2_000);
    _ = supervision.hostExited(1, false, false, 1_000 + backoff.crash_window_ms + 1);
    try std.testing.expectEqual(@as(usize, 2), supervision.crashes);
}

test "the record reads back only at this version and size" {
    var record = std.mem.zeroes(contract.Record);
    record.magic = contract.record_magic;
    record.version = contract.record_version;
    record.pid = 7;
    record.crash.kind = .widget_turn;
    try std.testing.expectEqual(@as(u32, 7), contract.parseRecord(std.mem.asBytes(&record)).?.pid);
    try std.testing.expect(contract.parseRecord(std.mem.asBytes(&record)[0..80]) == null);
    record.version = 1;
    try std.testing.expect(contract.parseRecord(std.mem.asBytes(&record)) == null);
}
