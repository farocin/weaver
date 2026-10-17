//! The widget host is the daemon (ADR 0022 step 4). The registry, the
//! control objects the CLI uses, `status.json`, the crash ledger and the
//! shared renderer moved here from `weaverd`, which now only starts this
//! process and restarts it after a crash (host/src/windows_host.zig).
//!
//! Control comes up before any widget: `Objects.claim` creates the
//! singleton and the reload and shutdown events in `runHost`, before the
//! host evaluates a single bundle, so `weaver down`, status and a fixed
//! install always reach it.
//!
//! Management runs off the UI thread, on a thread of its own (`run`): it
//! reconciles the registry, decides when each widget runs, starts and
//! watches dev widgets and the renderer, and writes status every 2 s. The
//! UI thread only applies a prepared load or unload (main.zig
//! `applyControl`), and the reload acknowledgement goes out after it has.
//! Work that reads files through std.Io or runs `node` (registry reads,
//! bundling, manifests) runs on a short-lived worker (`onWorker`): std.Io's
//! Windows file calls take 256-512 KiB stack frames, and a thread's stack
//! stays as deep as it ever went, so the long-lived thread only uses
//! small_fs.
//!
//! A crash is recorded by crash_record.zig. The next host reads that record
//! before it opens its own: a crash inside a widget's turn quarantines that
//! widget's bundle in `crash-ledger.json` (`applyCulprit`); any other crash
//! quarantines no one, and `weaverd` restarts the host with every widget
//! backed off, or held once the crashes pass the restart budget
//! (`applyRestart`).
const std = @import("std");
const contract = @import("host_contract");
const supervisor = @import("host_supervisor");
const backoff = supervisor.backoff;
const registry = supervisor.registry;
const crash_record = @import("crash_record.zig");
const dev_widgets = @import("dev_widgets.zig");
const host_control = @import("host_control.zig");
const provider_service = @import("provider_service.zig");
const small_fs = @import("small_fs.zig");
const widget_log = @import("widget_log.zig");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("tlhelp32.h");
});

const max_widgets = supervisor.max_widgets;
/// Widgets the host can run at once: its hidden anchor window takes one of
/// Native's 32 windows (main.zig `max_anchored_widgets`, which pins this).
pub const max_hosted_widgets = max_widgets - 1;
const max_path_bytes = supervisor.max_path_bytes;
/// How long the UI thread may take to apply a load or unload before the
/// host counts itself wedged and exits, for `weaverd` to restart it.
/// Receipt (2026-10-16, rm-bench/control-test.ps1): adding a clock answers
/// in 6-15 ms, removing one in under 5 ms. Five seconds is what weaverd
/// gave the host for the same answer.
const apply_timeout_ms: u64 = 5_000;
/// weaverd's cadence, unchanged: supervision every 250 ms, costs and status
/// every 2 s (15 samples make the 30 s average status shows), thread
/// counts every 30 s (one system-wide snapshot each).
const tick_ms: u32 = 250;
const status_interval_ms: u64 = 2_000;
const thread_sample_interval_ms: u64 = 30_000;
const cost_samples: usize = 15;
/// The management thread's stack. It only uses small_fs, JSON encoding
/// into the heap and Win32 calls; everything that takes std.Io frames runs
/// on a worker. Receipt (2026-10-17, ReleaseFast, resident stack pages by
/// QueryWorkingSetEx, through installs, reinstall, a GPU widget, a dev
/// widget, uninstalls and down): 28 KiB at most. 256 KiB is 9x that.
const management_stack_bytes: usize = 256 * 1024;
/// A worker's stack. Receipt (same runs, plus a registration the host had
/// to bundle with `node` itself): 456 KiB at most, std.Io's Windows file
/// frames. 2 MiB is 4.5x that; the worker exits when its job is done, and
/// its stack with it.
const worker_stack_bytes: usize = 2 * 1024 * 1024;
/// Registry and ledger reads: weaverd's limits. 32 registrations of two
/// 2 KiB paths each is under 160 KiB.
const max_registry_bytes: usize = 256 * 1024;
const max_manifest_bytes: usize = 64 * 1024;
/// The node bundler's output, captured only to drain its pipes.
const max_bundler_output_bytes: usize = 64 * 1024;

const invalid_handle = win.INVALID_HANDLE_VALUE;

/// The named objects the CLI reaches the host through
/// (host/src/host_contract.zig). Held for the host's whole life.
pub const Objects = struct {
    mutex: win.HANDLE,
    shutdown: win.HANDLE,
    reload: win.HANDLE,
    reload_success: win.HANDLE,
    reload_failure: win.HANDLE,

    /// Create them all, or fail with `error.AlreadyRunning` when another
    /// host holds the singleton.
    pub fn claim() !Objects {
        const mutex = win.CreateMutexW(null, 0, contract.singleton_mutex) orelse return error.CreateMutexFailed;
        if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) {
            _ = win.CloseHandle(mutex);
            return error.AlreadyRunning;
        }
        return .{
            .mutex = mutex,
            .shutdown = win.CreateEventW(null, 1, 0, contract.shutdown_event) orelse return error.CreateEventFailed,
            .reload = win.CreateEventW(null, 0, 0, contract.reload_event) orelse return error.CreateEventFailed,
            .reload_success = win.CreateEventW(null, 1, 0, contract.reload_success_event) orelse return error.CreateEventFailed,
            .reload_failure = win.CreateEventW(null, 1, 0, contract.reload_failure_event) orelse return error.CreateEventFailed,
        };
    }
};

/// How `weaverd` restarted this host, from its environment
/// (`contract.env_host_crashes`).
pub const Restart = struct {
    /// Crashes no widget was blamed for, within `backoff.crash_window_ms`.
    crashes: u32 = 0,
    exit_code: ?u32 = null,

    pub fn fromEnvironment(environment: *const std.process.Environ.Map) Restart {
        const crashes = environment.get(contract.env_host_crashes) orelse return .{};
        return .{
            .crashes = std.fmt.parseInt(u32, crashes, 10) catch 0,
            .exit_code = if (environment.get(contract.env_host_exit_code)) |code| std.fmt.parseInt(u32, code, 10) catch null else null,
        };
    }
};

pub const Options = struct {
    io: std.Io,
    /// The host's environment, which the renderer inherits with its pipe
    /// and log added.
    environment: *const std.process.Environ.Map,
    /// `%LOCALAPPDATA%\weaver`.
    data_directory: []const u8,
    renderer_pipe_name: []const u8,
    force_software: bool,
    service: *provider_service.Service,
    devs: *dev_widgets.DevWidgets,
    /// Hand a load or unload to the UI thread and wake it (main.zig).
    post: *const fn (*host_control.Pending) void,
    /// The previous host's record, read before this one opened its own.
    previous: ?contract.Record,
    restart: Restart,
};

/// A process's cost, sampled every `status_interval_ms`: what status
/// averages over the last `cost_samples` samples.
const Costs = struct {
    previous_ticks: u64 = 0,
    previous_ms: u64 = 0,
    private_samples: [cost_samples]u64 = @splat(0),
    cpu_samples: [cost_samples]f64 = @splat(0),
    count: usize = 0,
    cursor: usize = 0,

    fn reset(self: *Costs, process: win.HANDLE, now_ms: u64) void {
        self.* = .{ .previous_ticks = processTicks(process), .previous_ms = now_ms };
    }

    fn sample(self: *Costs, process: win.HANDLE, now_ms: u64) void {
        var counters = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS_EX);
        counters.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS_EX);
        if (win.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(win.PROCESS_MEMORY_COUNTERS_EX)) == 0) return;
        const ticks = processTicks(process);
        const elapsed_ms = now_ms -| self.previous_ms;
        const tick_delta = ticks -| self.previous_ticks;
        const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
        self.private_samples[self.cursor] = counters.PrivateUsage;
        self.cpu_samples[self.cursor] = @round(cpu * 10.0) / 10.0;
        self.cursor = (self.cursor + 1) % cost_samples;
        self.count = @min(self.count + 1, cost_samples);
        self.previous_ticks = ticks;
        self.previous_ms = now_ms;
    }

    fn averages(self: *const Costs) struct { private_mb: f64, cpu: f64 } {
        if (self.count == 0) return .{ .private_mb = 0, .cpu = 0 };
        var private_total: u64 = 0;
        var cpu_total: f64 = 0;
        for (self.private_samples[0..self.count]) |value| private_total += value;
        for (self.cpu_samples[0..self.count]) |value| cpu_total += value;
        const count: f64 = @floatFromInt(self.count);
        return .{ .private_mb = @as(f64, @floatFromInt(private_total)) / count / (1024.0 * 1024.0), .cpu = cpu_total / count };
    }
};

const SlotState = struct {
    /// It runs in this process.
    hosted: bool = false,
    /// Its slot in the host while it is being added or runs there.
    host_slot: ?u16 = null,
    /// A dev widget whose process runs (its handle is in `DevWidgets`).
    dev_running: bool = false,
    pid: u32 = 0,
    threads: u32 = 0,
    costs: Costs = .{},
};

const Slot = supervisor.Slot(SlotState);

const RendererProcess = struct {
    process: ?win.HANDLE = null,
    pid: u32 = 0,
    threads: u32 = 0,
    costs: Costs = .{},
};

/// Widgets quarantined because their own code crashed the host (ADR 0022),
/// kept in crash-ledger.json so a quarantine outlives the host. An entry
/// holds while the widget's bundle is the one that crashed: a reinstall or
/// a new bundle (a new bundle.js modification time) lifts it.
const Ledger = struct {
    entries: [max_widgets]Entry = undefined,
    count: usize = 0,

    const Entry = struct {
        name: [supervisor.max_name_bytes]u8 = undefined,
        name_len: usize = 0,
        artifact: i128 = 0,
        code: u32 = 0,

        fn nameSlice(self: *const Entry) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    const Wire = struct {
        quarantined: []const struct { name: []const u8, artifact: []const u8, code: u32 } = &.{},
    };

    fn find(self: *const Ledger, name: []const u8) ?usize {
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (std.mem.eql(u8, entry.nameSlice(), name)) return index;
        }
        return null;
    }

    fn put(self: *Ledger, name: []const u8, artifact: i128, code: u32) void {
        const index = self.find(name) orelse index: {
            if (self.count == self.entries.len or name.len > supervisor.max_name_bytes) return;
            self.count += 1;
            break :index self.count - 1;
        };
        const entry = &self.entries[index];
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = name.len;
        entry.artifact = artifact;
        entry.code = code;
    }

    fn remove(self: *Ledger, index: usize) void {
        self.entries[index] = self.entries[self.count - 1];
        self.count -= 1;
    }

    fn parse(self: *Ledger, allocator: std.mem.Allocator, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        self.count = 0;
        for (parsed.value.quarantined) |entry| {
            self.put(entry.name, std.fmt.parseInt(i128, entry.artifact, 10) catch continue, entry.code);
        }
    }

    fn write(self: *const Ledger, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"quarantined\":[");
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("{{\"name\":{f},\"artifact\":\"{d}\",\"code\":{d}}}", .{ std.json.fmt(entry.nameSlice(), .{}), entry.artifact, entry.code });
        }
        try writer.writeAll("]}\n");
    }
};

pub const Daemon = struct {
    options: Options,
    objects: Objects,
    allocator: std.mem.Allocator,
    pid: u32,
    registry_path: []const u8,
    status_path: []const u8,
    status_temp_path: []const u8,
    ledger_path: []const u8,
    ledger_temp_path: []const u8,
    renderer_log_path: []const u8,
    renderer_exe: []const u8,
    cli_script: []const u8,
    slots: [max_widgets]Slot,
    ledger: Ledger = .{},
    renderer: supervisor.RendererState(RendererProcess) = .{},
    renderer_failure_count: u64 = 0,
    renderer_failure_reason: [256]u8 = undefined,
    renderer_failure_reason_len: usize = 0,
    costs: Costs = .{},
    threads: u32 = 0,
    started_ms: u64,
    thread_sample_ms: u64 = 0,
    status_write_failures: u64 = 0,

    /// Everything the management thread needs, before it starts. Paths
    /// come from the data directory and this executable's place in the
    /// repository (runtime/zig-out/bin), as weaverd found them from its own.
    pub fn create(options: Options, objects: Objects) !*Daemon {
        const allocator = std.heap.page_allocator;
        const repo = try repositoryRoot(allocator);
        const self = try allocator.create(Daemon);
        const status_path = try std.fs.path.join(allocator, &.{ options.data_directory, "status.json" });
        const ledger_path = try std.fs.path.join(allocator, &.{ options.data_directory, "crash-ledger.json" });
        self.* = .{
            .options = options,
            .objects = objects,
            .allocator = allocator,
            .pid = win.GetCurrentProcessId(),
            .registry_path = try std.fs.path.join(allocator, &.{ options.data_directory, "registry.json" }),
            .status_path = status_path,
            .status_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{status_path}),
            .ledger_path = ledger_path,
            .ledger_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{ledger_path}),
            .renderer_log_path = try std.fmt.allocPrint(allocator, "{s}.renderer.log", .{status_path}),
            .renderer_exe = try std.fs.path.join(allocator, &.{ repo, "renderer", "zig-out", "bin", "weaver-renderer.exe" }),
            .cli_script = try std.fs.path.join(allocator, &.{ repo, "cli", "dist", "index.js" }),
            .slots = @splat(.{}),
            .started_ms = win.GetTickCount64(),
        };
        self.costs.reset(win.GetCurrentProcess(), self.started_ms);
        return self;
    }

    /// Start the management thread. The UI thread must be able to take a
    /// wake by now: every load and unload rides one.
    pub fn start(self: *Daemon) !void {
        const thread = try std.Thread.spawn(.{ .stack_size = management_stack_bytes }, run, .{self});
        thread.detach();
    }

    fn run(self: *Daemon) void {
        // It runs no widget's code.
        widget_log.detachThread();
        onWorker(begin, .{self}) catch |err| note("the registry could not be read at startup: {s}; widgets start on the next reload", .{@errorName(err)});
        var next_status_ms: u64 = 0;
        while (true) {
            const handles = [_]win.HANDLE{ self.objects.shutdown, self.objects.reload };
            const wait = win.WaitForMultipleObjects(handles.len, &handles, 0, tick_ms);
            if (wait == win.WAIT_OBJECT_0) break;
            if (wait == win.WAIT_OBJECT_0 + 1) {
                // Any widget this reload removed is out of the host when
                // the worker returns: the CLI may delete its directory.
                if (onWorker(loadRegistry, .{self})) |_| {
                    _ = win.SetEvent(self.objects.reload_success);
                } else |err| {
                    note("registry reload failed: {s}; nothing changed", .{@errorName(err)});
                    _ = win.SetEvent(self.objects.reload_failure);
                }
            }
            const now = win.GetTickCount64();
            self.supervise(now);
            if (now >= next_status_ms) {
                self.sampleCosts(now);
                self.writeStatus(now);
                next_status_ms = now + status_interval_ms;
            }
        }
        self.stopAll();
        crash_record.markStopped();
        std.process.exit(0);
    }

    /// The first work of a host start, before any widget loads.
    fn begin(self: *Daemon) !void {
        cleanupBackendStatusFiles(self.options.io, self.options.data_directory);
        small_fs.delete(self.options.io, self.renderer_log_path) catch {};
        self.loadLedger();
        try self.loadRegistry();
        self.applyCulprit();
        self.applyRestart(win.GetTickCount64());
    }

    // ---- Registry -------------------------------------------------------

    fn loadRegistry(self: *Daemon) !void {
        const owned_bytes = std.Io.Dir.cwd().readFileAlloc(self.options.io, self.registry_path, self.allocator, .limited(max_registry_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (owned_bytes) |bytes| self.allocator.free(bytes);
        const bytes = owned_bytes orelse "{\"widgets\":[]}";
        const parsed = try registry.parse(self.allocator, bytes);
        defer parsed.deinit();
        try supervisor.reconcile(&self.slots, parsed.value.widgets, self);
        self.pruneLedger();
    }

    /// For `supervisor.reconcile`: the widget in registry slot `index` runs.
    pub fn running(self: *const Daemon, index: usize) bool {
        const slot = &self.slots[index];
        return slot.platform.hosted or slot.platform.dev_running;
    }

    pub fn stop(self: *Daemon, index: usize, graceful: bool) void {
        self.stopSlot(&self.slots[index], graceful);
    }

    pub fn artifactMtime(self: *Daemon, source: []const u8) i128 {
        const path = std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" }) catch return 0;
        defer self.allocator.free(path);
        return small_fs.modified(self.options.io, path) orelse 0;
    }

    fn sourceExists(self: *Daemon, source: []const u8) bool {
        return small_fs.modified(self.options.io, source) != null;
    }

    fn slotIndex(self: *const Daemon, slot: *const Slot) u16 {
        return @intCast((@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot));
    }

    // ---- Crash record, restart and quarantine ---------------------------

    /// The previous host crashed in a widget's turn: quarantine that
    /// widget's bundle, the one it was added with (`crash_record.noteSlot`).
    fn applyCulprit(self: *Daemon) void {
        const record = self.options.previous orelse return;
        if (record.state != .running or record.crash.kind != .widget_turn) return;
        if (record.crash.slot == 0 or record.crash.slot > record.slots.len) return;
        const identity = record.slots[record.crash.slot - 1];
        if (identity.name_hash == 0) return;
        for (&self.slots) |*slot| {
            if (!slot.used or nameHash(slot.name()) != identity.name_hash) continue;
            self.ledger.put(slot.name(), identity.artifact, record.crash.code);
            self.writeLedger();
            note("the previous host crashed in '{s}' (exception 0x{X:0>8}); it is quarantined", .{ slot.name(), record.crash.code });
            return;
        }
    }

    /// weaverd restarted this host after crashes no widget was blamed for:
    /// every widget pays the backoff it paid when weaverd restarted each
    /// one, and once the crashes pass the budget they are all held stopped
    /// until a reinstall, or `weaver down` and `up`, as they were then.
    fn applyRestart(self: *Daemon, now_ms: u64) void {
        const restart = self.options.restart;
        if (restart.crashes == 0) return;
        const held = restart.crashes > backoff.restart_limit;
        const window_minutes = backoff.crash_window_ms / 60_000;
        for (&self.slots) |*slot| {
            if (!slot.used or !slot.enabled or slot.state != .starting) continue;
            if (held) {
                if (self.quarantined(slot)) continue;
                // A reinstall changes the artifact; reconcile compares
                // against this.
                slot.artifact_mtime = self.artifactMtime(slot.source());
                slot.state = .stopped;
                slot.setReason("held: the widget host crashed {d} times within {d} minutes with no widget to blame (restart_limit={d}); reinstall this widget, or run 'weaver down' then 'weaver up'", .{ restart.crashes, window_minutes, backoff.restart_limit });
            } else {
                slot.state = .backoff;
                slot.next_restart_ms = now_ms + backoff.delayMs(restart.crashes);
                slot.setReason("the widget host crashed{s}{?d}; restart {d} in {d}s", .{
                    if (restart.exit_code != null) ": exit_code=" else "",
                    restart.exit_code,
                    restart.crashes,
                    backoff.delayMs(restart.crashes) / 1000,
                });
            }
        }
    }

    /// Whether the ledger holds `slot` back: its bundle is the one that
    /// crashed the host. An entry for an older bundle is dropped.
    fn quarantined(self: *Daemon, slot: *Slot) bool {
        const index = self.ledger.find(slot.name()) orelse return false;
        const entry = self.ledger.entries[index];
        const artifact = self.artifactMtime(slot.source());
        if (artifact == 0 or artifact != entry.artifact) {
            self.ledger.remove(index);
            self.writeLedger();
            return false;
        }
        // A reinstall changes the artifact; the reconcile compares against this.
        slot.artifact_mtime = artifact;
        slot.state = .stopped;
        slot.setReason("quarantined: its code crashed the widget host (exception 0x{X:0>8}); reinstall or update it to run it again", .{entry.code});
        return true;
    }

    /// Drop quarantines of widgets no longer registered: an uninstall ends
    /// one, and the ledger holds at most one entry per registered widget,
    /// so it never fills.
    fn pruneLedger(self: *Daemon) void {
        var pruned = false;
        var index: usize = 0;
        while (index < self.ledger.count) {
            const name = self.ledger.entries[index].nameSlice();
            const registered = for (&self.slots) |*slot| {
                if (slot.used and std.mem.eql(u8, slot.name(), name)) break true;
            } else false;
            if (registered) {
                index += 1;
                continue;
            }
            self.ledger.remove(index);
            pruned = true;
        }
        if (pruned) self.writeLedger();
    }

    fn loadLedger(self: *Daemon) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.options.io, self.ledger_path, self.allocator, .limited(max_registry_bytes)) catch return;
        defer self.allocator.free(bytes);
        self.ledger.parse(self.allocator, bytes) catch |err| note("crash ledger ignored: {s}", .{@errorName(err)});
    }

    fn writeLedger(self: *Daemon) void {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        self.ledger.write(&output.writer) catch return;
        small_fs.write(self.options.io, self.ledger_temp_path, output.written()) catch |err| return note("crash ledger not written: {s}", .{@errorName(err)});
        small_fs.rename(self.options.io, self.ledger_temp_path, self.ledger_path) catch |err| note("crash ledger not published: {s}", .{@errorName(err)});
    }

    // ---- Supervision ----------------------------------------------------

    fn supervise(self: *Daemon, now_ms: u64) void {
        self.superviseRenderer(now_ms);
        self.takeProviderFailures(now_ms);
        var launch_due = false;
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.used or !slot.enabled) continue;
            const exited = slot.platform.dev_running and self.devExited(slot);
            switch (supervisor.nextSlotAction(slot, self.sourceExists(slot.source()), self.running(index), exited, now_ms)) {
                .none => {},
                .stop_missing => self.stopSlot(slot, true),
                .handle_exit => self.handleDevExit(slot, now_ms),
                .launch => launch_due = true,
            }
        }
        if (launch_due) onWorker(launchDue, .{ self, now_ms }) catch |err| note("could not start a widget: {s}", .{@errorName(err)});
        self.superviseRenderer(now_ms);
    }

    /// Start every widget whose (re)start is due. Runs on a worker: it may
    /// bundle, and reads each manifest.
    fn launchDue(self: *Daemon, now_ms: u64) !void {
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.used or !slot.enabled or self.running(index)) continue;
            const due = slot.state == .starting or (slot.state == .backoff and now_ms >= slot.next_restart_ms);
            if (!due or !self.sourceExists(slot.source())) continue;
            if (slot.dev) self.launchDev(slot, now_ms) else self.addHosted(slot, now_ms);
        }
    }

    /// Bundle, read the manifest, and clear the slot's backend status file:
    /// everything a launch needs before the host loads or launches it.
    fn prepareSlot(self: *Daemon, slot: *Slot, now_ms: u64) !void {
        try self.ensureBundle(slot.source());
        const manifest_path = try std.fs.path.join(self.allocator, &.{ slot.source(), "dist", "widget.json" });
        defer self.allocator.free(manifest_path);
        const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(self.options.io, manifest_path, self.allocator, .limited(max_manifest_bytes));
        defer self.allocator.free(manifest_bytes);
        const Manifest = struct {
            subscribe: []const []const u8 = &.{},
            capabilities: []const []const u8 = &.{},
            renderBackend: []const u8 = "software",
        };
        const manifest = try std.json.parseFromSlice(Manifest, self.allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
        defer manifest.deinit();
        supervisor.selectManifest(slot, manifest.value.subscribe, manifest.value.capabilities, manifest.value.renderBackend, self.options.force_software);
        if (slot.wants_gpu) self.ensureRenderer(now_ms) catch {
            // ensureRenderer records the named failure for status and owns
            // retry/backoff. The widget may still start so it can reconnect
            // as soon as the shared renderer recovers.
        };
        var buffer: [max_path_bytes]u8 = undefined;
        try small_fs.delete(self.options.io, try self.backendPath(slot, &buffer));
    }

    /// Where the widget reports its renderer, or why it did not load: a
    /// sidecar of status.json named by its name's hash.
    fn backendPath(self: *const Daemon, slot: *const Slot, buffer: *[max_path_bytes]u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}.backend-{x}", .{ self.status_path, std.hash.Wyhash.hash(0, slot.name()) });
    }

    fn ensureBundle(self: *Daemon, source: []const u8) !void {
        const source_path = try std.fs.path.join(self.allocator, &.{ source, "widget.tsx" });
        defer self.allocator.free(source_path);
        const bundle_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" });
        defer self.allocator.free(bundle_path);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "widget.json" });
        defer self.allocator.free(manifest_path);
        const source_stat = try std.Io.Dir.cwd().statFile(self.options.io, source_path, .{});
        const bundle_stat = std.Io.Dir.cwd().statFile(self.options.io, bundle_path, .{}) catch null;
        const manifest_stat = std.Io.Dir.cwd().statFile(self.options.io, manifest_path, .{}) catch null;
        if (bundle_stat != null and manifest_stat != null and bundle_stat.?.mtime.nanoseconds >= source_stat.mtime.nanoseconds) return;
        const result = try std.process.run(self.allocator, self.options.io, .{
            .argv = &.{ "node", self.cli_script, "bundle", source },
            .stdout_limit = .limited(max_bundler_output_bytes),
            .stderr_limit = .limited(max_bundler_output_bytes),
            .create_no_window = true,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.BundleFailed,
            else => return error.BundleFailed,
        }
    }

    fn distPath(self: *Daemon, slot: *const Slot) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ slot.source(), "dist" });
    }

    fn markSlotRunning(self: *Daemon, slot: *Slot, now_ms: u64) void {
        supervisor.markRunning(slot, now_ms, self.artifactMtime(slot.source()));
        slot.platform.costs = .{};
        self.thread_sample_ms = 0;
    }

    /// Load the widget into a free host slot, through the UI thread.
    fn addHosted(self: *Daemon, slot: *Slot, now_ms: u64) void {
        const host_slot = self.freeHostSlot() orelse {
            slot.state = .stopped;
            slot.setReason("the widget host already runs {d} widgets, its limit (max_hosted_widgets); remove one, then reinstall this one", .{max_hosted_widgets});
            return;
        };
        slot.platform.host_slot = host_slot;
        self.prepareSlot(slot, now_ms) catch |err| return self.failLaunch(slot, now_ms, err);
        if (self.quarantined(slot)) {
            slot.platform.host_slot = null;
            return;
        }
        // The bundle about to load, noted before it runs: if loading it
        // crashes the host, this is the bundle the next host quarantines
        // (not the one before it).
        slot.artifact_mtime = self.artifactMtime(slot.source());
        crash_record.noteSlot(host_slot, nameHash(slot.name()), std.math.cast(i64, slot.artifact_mtime) orelse 0);
        const dist = self.distPath(slot) catch |err| return self.failLaunch(slot, now_ms, err);
        defer self.allocator.free(dist);
        var backend: [max_path_bytes]u8 = undefined;
        const backend_path = self.backendPath(slot, &backend) catch |err| return self.failLaunch(slot, now_ms, err);
        self.apply(.{ .add = .{ .id = host_slot, .dir = dist, .backend = backend_path } }) catch |err| {
            // Loading is deterministic (a broken bundle or manifest), so
            // the slot stops until it is reinstalled or its source changes.
            slot.platform.host_slot = null;
            slot.state = .stopped;
            slot.setReason("widget did not load in the shared host: {s}; see 'weaver logs {s}'", .{ @errorName(err), slot.name() });
            return;
        };
        slot.platform.hosted = true;
        slot.platform.pid = self.pid;
        self.markSlotRunning(slot, now_ms);
    }

    fn failLaunch(_: *Daemon, slot: *Slot, now_ms: u64, err: anyerror) void {
        slot.platform.host_slot = null;
        supervisor.recordLaunchFailure(slot, now_ms, err);
    }

    /// One widget leaves the host; the others keep running.
    fn removeHosted(self: *Daemon, slot: *Slot) void {
        self.apply(.{ .remove = .{ .id = slot.platform.host_slot.? } }) catch |err| {
            note("could not remove '{s}': {s}", .{ slot.name(), @errorName(err) });
        };
        slot.platform.hosted = false;
        slot.platform.host_slot = null;
        slot.platform.pid = 0;
    }

    /// Hand `command` to the UI thread and wait until it has taken effect.
    /// A UI thread that does not get to it in `apply_timeout_ms` is stuck
    /// (in a widget's native code, or in Native itself): the host exits, and
    /// weaverd restarts it as it restarted a host that did not answer.
    fn apply(self: *Daemon, command: host_control.Command) !void {
        var pending: host_control.Pending = .{ .command = command };
        self.options.post(&pending);
        const deadline = win.GetTickCount64() + apply_timeout_ms;
        while (!pending.done.isSet()) {
            const now = win.GetTickCount64();
            if (now >= deadline) {
                note("the UI thread did not apply a widget {s} within {d} ms; the host is stuck and exits for weaverd to restart it", .{ @tagName(command), apply_timeout_ms });
                _ = win.TerminateProcess(win.GetCurrentProcess(), contract.exit_wedged);
            }
            pending.done.waitTimeout(self.options.io, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(deadline - now)),
                .clock = .awake,
            } }) catch {};
        }
        if (pending.failure) |err| return err;
    }

    /// The lowest host slot no widget holds.
    fn freeHostSlot(self: *const Daemon) ?u16 {
        var taken: [max_hosted_widgets]bool = @splat(false);
        for (&self.slots) |*slot| {
            if (slot.platform.host_slot) |host_slot| taken[host_slot] = true;
        }
        for (taken, 0..) |is_taken, host_slot| {
            if (!is_taken) return @intCast(host_slot);
        }
        return null;
    }

    /// The registry slot running in host slot `host_slot`.
    fn slotInHost(self: *Daemon, host_slot: u16) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.platform.hosted and slot.platform.host_slot == host_slot) return slot;
        }
        return null;
    }

    /// A `--dev` widget keeps a process of its own, so its hot-swap
    /// listener and dev reloads touch only it. It runs in the host's job
    /// and gets its providers from the host over its pipe.
    fn launchDev(self: *Daemon, slot: *Slot, now_ms: u64) void {
        self.prepareSlot(slot, now_ms) catch |err| return supervisor.recordLaunchFailure(slot, now_ms, err);
        const dist = self.distPath(slot) catch |err| return supervisor.recordLaunchFailure(slot, now_ms, err);
        defer self.allocator.free(dist);
        var backend: [max_path_bytes]u8 = undefined;
        const pid = self.options.devs.launch(.{
            .id = self.slotIndex(slot),
            .dir = dist,
            .backend = self.backendPath(slot, &backend) catch |err| return supervisor.recordLaunchFailure(slot, now_ms, err),
            .wants = wantsOf(slot),
            .gpu = slot.wants_gpu,
        }) catch |err| return supervisor.recordLaunchFailure(slot, now_ms, err);
        slot.platform.dev_running = true;
        slot.platform.pid = pid;
        self.markSlotRunning(slot, now_ms);
        if (self.options.devs.process(self.slotIndex(slot))) |process| slot.platform.costs.reset(process, now_ms);
    }

    fn devExited(self: *Daemon, slot: *const Slot) bool {
        const process = self.options.devs.process(self.slotIndex(slot)) orelse return true;
        return win.WaitForSingleObject(process, 0) == win.WAIT_OBJECT_0;
    }

    fn stopDev(self: *Daemon, slot: *Slot, graceful: bool) void {
        self.options.devs.stop(self.slotIndex(slot), graceful) catch {};
        slot.platform.dev_running = false;
        slot.platform.pid = 0;
        self.thread_sample_ms = 0;
    }

    /// A dev widget's process exited: that is its crash.
    fn handleDevExit(self: *Daemon, slot: *Slot, now_ms: u64) void {
        var exit_code: win.DWORD = 1;
        if (self.options.devs.process(self.slotIndex(slot))) |process| _ = win.GetExitCodeProcess(process, &exit_code);
        self.stopDev(slot, false);
        if (!self.sourceExists(slot.source())) {
            _ = supervisor.nextSlotAction(slot, false, false, false, now_ms);
            return;
        }
        supervisor.recordCrash(slot, now_ms, exit_code);
    }

    fn stopSlot(self: *Daemon, slot: *Slot, graceful: bool) void {
        if (slot.platform.hosted) return self.removeHosted(slot);
        if (slot.platform.dev_running) self.stopDev(slot, graceful);
    }

    /// Widgets whose provider channel failed since the last tick restart on
    /// their crash budget, as when weaverd ran the providers.
    fn takeProviderFailures(self: *Daemon, now_ms: u64) void {
        const failures = self.options.service.takeFailures();
        for (0..32) |bit| {
            const mask = @as(u32, 1) << @intCast(bit);
            if (failures.hosted & mask != 0) {
                if (self.slotInHost(@intCast(bit))) |slot| self.restartAfterChannelFailure(slot, now_ms);
            }
            if (failures.dev & mask != 0 and bit < max_widgets) {
                const slot = &self.slots[bit];
                if (!slot.platform.dev_running) continue;
                // A dev widget that exited broke its pipe: that is its crash.
                if (self.devExited(slot)) self.handleDevExit(slot, now_ms) else self.restartAfterChannelFailure(slot, now_ms);
            }
        }
    }

    fn restartAfterChannelFailure(self: *Daemon, slot: *Slot, now_ms: u64) void {
        note("restarting widget {s} after fatal provider channel failure", .{slot.name()});
        self.stopSlot(slot, false);
        supervisor.recordChannelFailure(slot, now_ms);
    }

    /// `weaver down`: dev widgets close their windows, the renderer stops,
    /// and status says nothing runs. Widgets in the host go with it.
    fn stopAll(self: *Daemon) void {
        for (&self.slots) |*slot| {
            if (slot.platform.dev_running) self.stopDev(slot, true);
            if (slot.platform.hosted) {
                slot.platform.hosted = false;
                slot.platform.host_slot = null;
                slot.platform.pid = 0;
            }
            if (slot.state == .running) slot.state = .starting;
        }
        self.stopRenderer();
        self.writeStatus(win.GetTickCount64());
    }

    // ---- Renderer -------------------------------------------------------

    fn superviseRenderer(self: *Daemon, now_ms: u64) void {
        const process = self.renderer.platform.process;
        const exited = if (process) |handle| win.WaitForSingleObject(handle, 0) == win.WAIT_OBJECT_0 else false;
        switch (supervisor.nextRendererAction(process != null, exited, supervisor.rendererDesired(&self.slots, self.options.force_software), now_ms, self.renderer.next_restart_ms)) {
            .none => {},
            .handle_exit => {
                var exit_code: win.DWORD = 1;
                _ = win.GetExitCodeProcess(process.?, &exit_code);
                _ = win.CloseHandle(process.?);
                self.renderer.platform = .{};
                self.thread_sample_ms = 0;
                supervisor.recordRendererExit(&self.renderer, now_ms);
                self.noteRendererFailure("renderer process exited: code={d}; retrying in {d}ms", .{ exit_code, self.renderer.next_restart_ms -| now_ms });
            },
            .stop => self.stopRenderer(),
            .launch => self.ensureRenderer(now_ms) catch {
                self.renderer.next_restart_ms = now_ms + 1000;
            },
        }
    }

    fn stopRenderer(self: *Daemon) void {
        const process = self.renderer.platform.process orelse return;
        _ = win.TerminateProcess(process, 0);
        _ = win.WaitForSingleObject(process, 1000);
        _ = win.CloseHandle(process);
        self.renderer = .{};
        self.thread_sample_ms = 0;
    }

    fn ensureRenderer(self: *Daemon, now_ms: u64) !void {
        if (self.options.force_software or self.renderer.platform.process != null or now_ms < self.renderer.next_restart_ms) return;
        self.startRenderer(now_ms) catch |err| {
            self.noteRendererFailure("renderer launch failed: {s}; retrying in 1000ms", .{@errorName(err)});
            return err;
        };
        if (self.renderer_failure_count > 0) {
            note("renderer recovered after {d} consecutive failures", .{self.renderer_failure_count});
            self.renderer_failure_count = 0;
            self.renderer_failure_reason_len = 0;
        }
    }

    /// The shared renderer, in the host's job: it never outlives the host.
    fn startRenderer(self: *Daemon, now_ms: u64) !void {
        // Built for this start and freed after it: a clone on the page
        // allocator keeps a page per variable.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var environment = try self.options.environment.clone(arena_state.allocator());
        try environment.put("WEAVER_RENDERER_PIPE", self.options.renderer_pipe_name);
        try environment.put("WEAVER_RENDERER_LOG", self.renderer_log_path);
        const block = try environment.createWindowsBlock(self.allocator, .{});
        defer block.deinit(self.allocator);
        const line = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.renderer_exe});
        defer self.allocator.free(line);
        const line_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, line);
        defer self.allocator.free(line_w);
        const started = try self.options.devs.startInJob(line_w, &block);
        self.renderer.platform = .{ .process = started.process, .pid = started.pid };
        self.renderer.platform.costs.reset(started.process, now_ms);
        self.renderer.started_ms = now_ms;
        self.thread_sample_ms = 0;
    }

    fn noteRendererFailure(self: *Daemon, comptime format: []const u8, args: anytype) void {
        self.renderer_failure_count += 1;
        if (self.renderer_failure_count != 1) return;
        var writer = std.Io.Writer.fixed(&self.renderer_failure_reason);
        writer.print(format, args) catch {
            writer = std.Io.Writer.fixed(&self.renderer_failure_reason);
            writer.writeAll("renderer unavailable; retrying") catch unreachable;
        };
        self.renderer_failure_reason_len = writer.buffered().len;
        note("{s}; affected GPU widgets expose this failure through weaver status; repeated failures are suppressed until recovery", .{self.renderer_failure_reason[0..self.renderer_failure_reason_len]});
    }

    // ---- Status ---------------------------------------------------------

    fn sampleCosts(self: *Daemon, now_ms: u64) void {
        self.costs.sample(win.GetCurrentProcess(), now_ms);
        if (self.renderer.platform.process) |process| self.renderer.platform.costs.sample(process, now_ms);
        for (&self.slots) |*slot| {
            if (!slot.platform.dev_running) continue;
            const process = self.options.devs.process(self.slotIndex(slot)) orelse continue;
            slot.platform.costs.sample(process, now_ms);
        }
    }

    fn countThreads(self: *Daemon) void {
        self.threads = 0;
        self.renderer.platform.threads = 0;
        for (&self.slots) |*slot| slot.platform.threads = 0;
        const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0);
        if (snapshot == invalid_handle) return;
        defer _ = win.CloseHandle(snapshot);
        var entry = std.mem.zeroes(win.THREADENTRY32);
        entry.dwSize = @sizeOf(win.THREADENTRY32);
        if (win.Thread32First(snapshot, &entry) == 0) return;
        while (true) {
            const owner = entry.th32OwnerProcessID;
            if (owner == self.pid) self.threads += 1;
            if (self.renderer.platform.pid != 0 and owner == self.renderer.platform.pid) self.renderer.platform.threads += 1;
            for (&self.slots) |*slot| {
                if (slot.platform.dev_running and slot.platform.pid == owner) slot.platform.threads += 1;
            }
            if (win.Thread32Next(snapshot, &entry) == 0) break;
        }
    }

    fn writeStatus(self: *Daemon, now_ms: u64) void {
        if (self.thread_sample_ms == 0 or now_ms -| self.thread_sample_ms >= thread_sample_interval_ms) {
            self.countThreads();
            self.thread_sample_ms = now_ms;
        }
        var entries: [max_widgets + 2]supervisor.StatusEntry = undefined;
        var count: usize = 0;
        const host_cost = self.costs.averages();
        entries[count] = .{
            .name = "host",
            .pid = self.pid,
            .private_mb = host_cost.private_mb,
            .cpu_percent = host_cost.cpu,
            .threads = self.threads,
            .backend = "-",
            .uptime_seconds = (now_ms -| self.started_ms) / 1000,
            .state = .running,
            .reason = "",
            .host_row = true,
        };
        count += 1;
        if (self.renderer.platform.process != null) {
            const cost = self.renderer.platform.costs.averages();
            entries[count] = .{
                .name = "renderer",
                .pid = self.renderer.platform.pid,
                .private_mb = cost.private_mb,
                .cpu_percent = cost.cpu,
                .threads = self.renderer.platform.threads,
                .backend = "gpu",
                .uptime_seconds = (now_ms -| self.renderer.started_ms) / 1000,
                .state = .running,
                .reason = "",
            };
            count += 1;
        }
        // A backend file holds "gpu", "software" or a short failure; one
        // longer than 16 bytes reads as no report, as weaverd read it.
        var backends: [max_widgets][17]u8 = undefined;
        for (&self.slots, 0..) |*slot, index| {
            if (!slot.used) continue;
            const live = slot.platform.hosted or slot.platform.dev_running;
            var backend: []const u8 = "-";
            var path_buffer: [max_path_bytes]u8 = undefined;
            if (live) if (self.backendPath(slot, &path_buffer)) |path| {
                if (small_fs.readSmall(self.options.io, path, &backends[index])) |bytes| {
                    if (bytes.len <= 16) backend = bytes;
                }
            } else |_| {};
            const own_reason = slot.reason();
            const reason = if (own_reason.len > 0)
                own_reason
            else if (slot.wants_gpu and self.renderer_failure_reason_len > 0)
                self.renderer_failure_reason[0..self.renderer_failure_reason_len]
            else
                "";
            const cost = slot.platform.costs.averages();
            entries[count] = .{
                .name = slot.name(),
                .pid = slot.platform.pid,
                .private_mb = cost.private_mb,
                .cpu_percent = cost.cpu,
                .threads = if (slot.platform.hosted) 0 else slot.platform.threads,
                .backend = backend,
                .uptime_seconds = if (live) (now_ms -| slot.started_ms) / 1000 else 0,
                .state = slot.state,
                .reason = reason,
                .hosted = slot.platform.hosted,
            };
            count += 1;
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const providers = self.options.service.snapshot();
        supervisor.writeStatus(&output.writer, self.pid, .{
            .system_subscribers = supervisor.systemSubscriberCount(&self.slots, self),
            .system_sample_count = providers.system_sample_count,
            .system_frames = providers.system_frames,
            .audio_capture_active = providers.audio_capture_active,
            .audio_silent = providers.audio_silent,
            .audio_pipe_frames = providers.audio_frames,
            .media_pipe_frames = providers.media_frames,
            .media_availability = "available",
            .media_subscribers = supervisor.subscriptionCount(&self.slots, .media, self),
            .audio_availability = providers.audio_availability.label(),
            .audio_subscribers = supervisor.subscriptionCount(&self.slots, .audio, self),
            .audio_capture_starts = providers.audio_capture_starts,
            .audio_provider_frames = providers.audio_provider_frames,
            .audio_last_error = providers.audio_last_error,
        }, entries[0..count]) catch |err| return self.noteStatusWriteFailure("encode", err);
        small_fs.write(self.options.io, self.status_temp_path, output.written()) catch |err| return self.noteStatusWriteFailure("write temporary file", err);
        small_fs.rename(self.options.io, self.status_temp_path, self.status_path) catch |err| return self.noteStatusWriteFailure("publish", err);
        if (self.status_write_failures > 0) {
            note("host status publication recovered after {d} consecutive failures", .{self.status_write_failures});
            self.status_write_failures = 0;
        }
    }

    fn noteStatusWriteFailure(self: *Daemon, operation: []const u8, err: anyerror) void {
        self.status_write_failures += 1;
        if (self.status_write_failures == 1) {
            note("host status publication degraded while attempting to {s}: {s}; path={s}; repeated failures are suppressed until recovery", .{ operation, @errorName(err), self.status_path });
        }
    }
};

/// Run `function` on a short-lived worker with `worker_stack_bytes`, and
/// wait for it. The management thread never runs alongside it.
fn onWorker(comptime function: anytype, args: anytype) !void {
    const Call = struct {
        args: @TypeOf(args),
        result: anyerror!void = {},

        fn run(call: *@This()) void {
            widget_log.detachThread();
            call.result = @call(.auto, function, call.args);
        }
    };
    var call: Call = .{ .args = args };
    const thread = try std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, Call.run, .{&call});
    thread.join();
    return call.result;
}

/// What the slot's manifest asks of the providers, as the daemon read it.
fn wantsOf(slot: *const Slot) provider_service.Wants {
    return .{
        .cpu = slot.wants_cpu,
        .memory = slot.wants_memory,
        .audio = slot.wants_audio,
        .media = slot.wants_media,
        .media_transport = slot.wants_media_transport,
    };
}

/// The name identity a host slot records (`contract.SlotIdentity`). Never
/// zero, which marks an empty slot.
fn nameHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name) | 1;
}

/// Host-level notices. The host has no console under weaverd; a developer
/// who starts it by hand sees them.
fn note(comptime format: []const u8, args: anytype) void {
    std.debug.print("weaver-widget --host: " ++ format ++ "\n", args);
}

/// Put the renderer pipe in this process's environment, where Native's
/// shared-renderer client reads it when a GPU widget's window opens.
pub fn exportRendererPipe(name: []const u8) !void {
    var wide: [256:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, name);
    if (length >= wide.len) return error.NameTooLong;
    wide[length] = 0;
    if (win.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_PIPE"), &wide) == 0) return error.SetEnvironmentFailed;
}

fn repositoryRoot(allocator: std.mem.Allocator) ![]u8 {
    const path_w = try allocator.alloc(u16, 32768);
    defer allocator.free(path_w);
    const length = win.GetModuleFileNameW(null, path_w.ptr, @intCast(path_w.len));
    if (length == 0 or length == path_w.len) return error.ExecutablePathFailed;
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_w[0..length]);
    defer allocator.free(path);
    // <repo>\runtime\zig-out\bin\weaver-widget.exe
    var root: []const u8 = path;
    for (0..4) |_| root = std.fs.path.dirname(root) orelse return error.ExecutablePathFailed;
    return allocator.dupe(u8, root);
}

fn cleanupBackendStatusFiles(io: std.Io, directory_path: []const u8) void {
    var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
        note("could not inspect renderer status sidecars: {s}", .{@errorName(err)});
        return;
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch |err| {
        note("renderer status sidecar scan stopped: {s}", .{@errorName(err)});
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "status.json.backend-")) continue;
        directory.deleteFile(io, entry.name) catch |err| {
            note("could not remove orphan renderer status sidecar {s}: {s}", .{ entry.name, @errorName(err) });
        };
    }
}

fn processTicks(process: win.HANDLE) u64 {
    var created: win.FILETIME = undefined;
    var exited: win.FILETIME = undefined;
    var kernel: win.FILETIME = undefined;
    var user: win.FILETIME = undefined;
    if (win.GetProcessTimes(process, &created, &exited, &kernel, &user) == 0) return 0;
    return fileTime(kernel) + fileTime(user);
}

fn fileTime(value: win.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

test "the crash ledger round-trips and keeps one entry per widget" {
    var ledger: Ledger = .{};
    ledger.put("Clock", 1234567890123456789, 0xC000_0005);
    ledger.put("Clock \"two\"", -1, 1);
    ledger.put("Clock", 42, 3);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try ledger.write(&output.writer);
    var read: Ledger = .{};
    try read.parse(std.testing.allocator, output.written());
    try std.testing.expectEqual(@as(usize, 2), read.count);
    const clock = read.entries[read.find("Clock").?];
    try std.testing.expectEqual(@as(i128, 42), clock.artifact);
    try std.testing.expectEqual(@as(u32, 3), clock.code);
    try std.testing.expect(read.find("Clock \"two\"") != null);
    read.remove(read.find("Clock").?);
    try std.testing.expect(read.find("Clock") == null);
}

test "weaverd's restart environment reads back, and a fresh start has none" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectEqual(Restart{}, Restart.fromEnvironment(&environment));
    try environment.put(contract.env_host_crashes, "2");
    try environment.put(contract.env_host_exit_code, "3221225477");
    try std.testing.expectEqual(Restart{ .crashes = 2, .exit_code = 0xC000_0005 }, Restart.fromEnvironment(&environment));
}
