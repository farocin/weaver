const std = @import("std");
const supervisor = @import("supervisor.zig");
const backoff = @import("backoff.zig");
const registry = @import("registry.zig");

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("psapi.h");
    @cInclude("tlhelp32.h");
});

const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostSingletonV2");
const shutdown_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostShutdownV2");
const reload_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadV2");
const reload_signal_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadSignalV2");
const reload_success_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadSuccessV2");
const reload_failure_event_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\WeaverHostReloadFailureV2");
const env_renderer_pipe = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_PIPE");
const env_renderer_log = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_RENDERER_LOG");
const env_art_cache = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_ART_CACHE");
const env_control_pipe = std.unicode.utf8ToUtf16LeStringLiteral("WEAVER_CONTROL_PIPE");
const max_widgets = supervisor.max_widgets;
/// Widgets the shared host can hold: its hidden anchor window takes one of
/// Native's 32 windows (the runtime's `max_anchored_widgets`).
const max_hosted_widgets = max_widgets - 1;
/// How long the shared host may take to answer an add or remove before the
/// daemon gives up on it. Receipt (2026-10-16, rm-bench/control-test.ps1):
/// adding a clock answers in 6-15 ms, removing one in under 5 ms. Five
/// seconds is what a hosted widget already had to load and connect.
const control_answer_timeout_ms: u32 = 5_000;
/// How long the host may take to launch a dev widget: the widget has 5 s to
/// open its provider pipe (runtime/src/dev_widgets.zig connect_timeout_ms),
/// then the usual answer time.
const dev_launch_answer_timeout_ms: u32 = 5_000 + control_answer_timeout_ms;
/// How long the host may take to stop a dev widget: a graceful stop waits
/// 1.5 s for its window to close and 1 s for it to exit (dev_widgets.zig
/// close_wait_ms, exit_wait_ms), then the usual answer time.
const dev_stop_answer_timeout_ms: u32 = 2_500 + control_answer_timeout_ms;
/// The longest answer the host sends: runtime/src/host_control.zig
/// max_answer_bytes.
const max_answer_bytes: usize = 1024;
const max_path_bytes: usize = 2048;
const invalid_handle = c.INVALID_HANDLE_VALUE;

const WindowsSlotState = struct {
    /// A dev widget's process, which the shared host launched in its job:
    /// opened by its PID to watch it and sample its cost.
    process: c.HANDLE = null,
    pid: u32 = 0,
    previous_process_ticks: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,
    backend_path_buffer: [max_path_bytes]u8 = undefined,
    backend_path_len: usize = 0,
    /// The widget runs inside the shared host (`SharedHost`) rather than
    /// a process of its own; `process` stays null.
    hosted: bool = false,
    /// Its slot in the shared host while it is being added or runs there:
    /// the `id` of its control commands, and how the host's crash record
    /// names it (plus one).
    host_slot: ?u16 = null,

    fn backendPath(self: *const WindowsSlotState) []const u8 {
        return self.backend_path_buffer[0..self.backend_path_len];
    }

    fn averages(self: *const WindowsSlotState) struct { private_mb: f64, cpu: f64 } {
        if (self.sample_count == 0) return .{ .private_mb = 0, .cpu = 0 };
        var private_total: u64 = 0;
        var cpu_total: f64 = 0;
        for (self.private_samples[0..self.sample_count]) |value| private_total += value;
        for (self.cpu_samples[0..self.sample_count]) |value| cpu_total += value;
        return .{
            .private_mb = @as(f64, @floatFromInt(private_total)) / @as(f64, @floatFromInt(self.sample_count)) / (1024.0 * 1024.0),
            .cpu = cpu_total / @as(f64, @floatFromInt(self.sample_count)),
        };
    }
};

const Slot = supervisor.Slot(WindowsSlotState);

const WindowsRendererState = struct {
    process: c.HANDLE = null,
    pid: u32 = 0,
    previous_process_ticks: u64 = 0,
    previous_sample_ms: u64 = 0,
    private_samples: [15]u64 = [_]u64{0} ** 15,
    cpu_samples: [15]f64 = [_]f64{0} ** 15,
    sample_count: usize = 0,
    sample_cursor: usize = 0,

    fn averages(self: *const WindowsRendererState) struct { private_mb: f64, cpu: f64 } {
        if (self.sample_count == 0) return .{ .private_mb = 0, .cpu = 0 };
        var private_total: u64 = 0;
        var cpu_total: f64 = 0;
        for (self.private_samples[0..self.sample_count]) |value| private_total += value;
        for (self.cpu_samples[0..self.sample_count]) |value| cpu_total += value;
        return .{
            .private_mb = @as(f64, @floatFromInt(private_total)) / @as(f64, @floatFromInt(self.sample_count)) / (1024.0 * 1024.0),
            .cpu = cpu_total / @as(f64, @floatFromInt(self.sample_count)),
        };
    }
};

const RendererState = supervisor.RendererState(WindowsRendererState);

/// Every widget not in `--dev` runs in one `weaver-widget --host` process
/// (ADR 0020), added and removed over its control pipe while the others
/// keep running (ADR 0022). Hosted slots hold no process of their own. The
/// host also runs the providers, and launches `--dev` widgets in a job of
/// its own, so they die with it (ADR 0022 step 3). When the host dies, its
/// record (`HostRecord`) says whether a widget's code crashed it.
const SharedHost = struct {
    process: WindowsRendererState = .{},
    started_ms: u64 = 0,
    launches: u64 = 0,
    /// The daemon's end of the control pipe (`host_control` in the runtime).
    control: c.HANDLE = invalid_handle,
    /// Signals the control pipe's overlapped reads and writes.
    control_event: c.HANDLE = null,
    threads: u32 = 0,
};

/// The host's record of itself, `%LOCALAPPDATA%\weaver\host.record`: the
/// layout of `Record` in runtime/src/crash_record.zig, which the host keeps
/// mapped and fills when it crashes. Change both together.
const HostRecord = extern struct {
    magic: u32,
    version: u32,
    generation: u64,
    pid: u32,
    state: u32,
    start_time: u64,
    turn_slot: u32,
    turn_thread: u32,
    turn_bundle: u64,
    crash_kind: u32,
    crash_code: u32,
    crash_thread: u32,
    /// The crashed widget's host slot plus one, for `crash_widget_turn`.
    crash_slot: u32,
    crash_bundle: u64,
    crash_time: u64,

    const magic_value: u32 = 0x5248_5657;
    const version_value: u32 = 1;
    const state_running: u32 = 1;
    const state_stopped: u32 = 2;
    /// The crash happened while that widget's own code ran.
    const crash_widget_turn: u32 = 1;

    comptime {
        std.debug.assert(@sizeOf(HostRecord) == 80);
    }
};

/// Widgets quarantined because their own code crashed the host (ADR 0022),
/// kept in crash-ledger.json so a quarantine outlives weaverd. An entry
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

/// The host's answer to one control command.
const ControlAnswer = struct {
    ok: bool = false,
    /// A launched dev widget's process.
    pid: u32 = 0,
    buffer: [max_answer_bytes]u8 = undefined,
    len: usize = 0,
    error_start: usize = 0,
    error_len: usize = 0,

    /// The error that stopped the command; empty when it took effect.
    fn errorName(self: *const ControlAnswer) []const u8 {
        return self.buffer[self.error_start..][0..self.error_len];
    }

    /// The whole answer line, without its newline.
    fn text(self: *const ControlAnswer) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// What the host last said of its providers (`{"providers":{}}`), for
/// status. The counters add up across host restarts (`provider_totals`), as
/// they did while weaverd ran the providers itself.
const ProviderReport = struct {
    counters: Counters = .{},
    audio_capture_active: bool = false,
    audio_silent: bool = true,
    audio_availability_buffer: [32]u8 = undefined,
    audio_availability_len: usize = 0,
    audio_last_error: i32 = 0,

    const Counters = struct {
        system_sample_count: u64 = 0,
        system_frames: u64 = 0,
        audio_frames: u64 = 0,
        media_frames: u64 = 0,
        audio_capture_starts: u64 = 0,
        audio_provider_frames: u64 = 0,

        fn plus(a: Counters, b: Counters) Counters {
            var sum: Counters = .{};
            inline for (std.meta.fields(Counters)) |field| @field(sum, field.name) = @field(a, field.name) + @field(b, field.name);
            return sum;
        }
    };

    /// The answer's wire shape (runtime/src/host_control.zig answerProviders).
    const Wire = struct {
        providers: struct {
            systemSampleCount: u64 = 0,
            systemFrames: u64 = 0,
            audioCaptureActive: bool = false,
            audioSilent: bool = true,
            audioPipeFrames: u64 = 0,
            audioAvailability: []const u8 = "idle",
            audioCaptureStarts: u64 = 0,
            audioProviderFrames: u64 = 0,
            audioLastError: i32 = 0,
            mediaPipeFrames: u64 = 0,
        } = .{},
        failed: struct { hosted: []const u16 = &.{}, dev: []const u16 = &.{} } = .{},
    };

    fn availability(self: *const ProviderReport) []const u8 {
        return if (self.audio_availability_len == 0) "idle" else self.audio_availability_buffer[0..self.audio_availability_len];
    }
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    registry_path: []const u8,
    status_path: []const u8,
    status_temp_path: []const u8,
    /// The shared host's record (`HostRecord`).
    record_path: []const u8,
    ledger_path: []const u8,
    ledger_temp_path: []const u8,
    ledger: Ledger = .{},
    runtime_exe: []const u8,
    renderer_exe: []const u8,
    renderer_pipe_name: []const u8,
    renderer_log_path: []const u8,
    cli_script: []const u8,
    art_cache_root: []const u8,
    force_software: bool,
    renderer: RendererState = .{},
    shared: SharedHost = .{},
    slots: [max_widgets]Slot = [_]Slot{.{}} ** max_widgets,
    /// The running host's providers, as it last reported them.
    provider_report: ProviderReport = .{},
    /// Earlier hosts' last counters.
    provider_totals: ProviderReport.Counters = .{},
    /// A widget that uses the providers has run in this host: its last
    /// counters are read before the host stops.
    provider_host_used: bool = false,
    thread_sample_ms: u64 = 0,
    slot_threads: [max_widgets]u32 = [_]u32{0} ** max_widgets,
    renderer_threads: u32 = 0,
    status_write_failures: u64 = 0,
    renderer_failure_count: u64 = 0,
    renderer_failure_reason: [256]u8 = undefined,
    renderer_failure_reason_len: usize = 0,

    fn loadRegistry(self: *Host) !void {
        const owned_bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.registry_path, self.allocator, .limited(256 * 1024)) catch |err| switch (err) {
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

    /// Drop quarantines of widgets no longer registered: an uninstall ends
    /// one, and the ledger holds at most one entry per registered widget,
    /// so it never fills.
    fn pruneLedger(self: *Host) void {
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

    pub fn running(self: *const Host, index: usize) bool {
        return self.slots[index].platform.process != null or self.slots[index].platform.hosted;
    }

    pub fn stop(self: *Host, index: usize, graceful: bool) void {
        self.stopSlot(&self.slots[index], graceful);
    }

    fn supervise(self: *Host, now_ms: u64) void {
        self.superviseRenderer(now_ms);
        self.settleSharedHostExit(now_ms);
        var start_hosted = false;
        for (&self.slots) |*slot| {
            if (!slot.used or !slot.enabled) continue;
            const process_running = slot.platform.process != null or slot.platform.hosted;
            const process_exited = if (slot.platform.process) |process| c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0 else false;
            switch (supervisor.nextSlotAction(slot, self.sourceExists(slot.source()), process_running, process_exited, now_ms)) {
                .none => {},
                .stop_missing => self.stopSlot(slot, true),
                .handle_exit => self.handleExit(slot, now_ms),
                .launch => if (slot.dev) {
                    self.launchDev(slot, now_ms);
                } else {
                    start_hosted = true;
                },
            }
        }
        if (start_hosted) self.startHostedWidgets(now_ms);
        self.superviseRenderer(now_ms);
    }

    /// A `--dev` widget keeps a process of its own, so its hot-swap
    /// listener and dev reloads touch only it. The shared host launches it,
    /// in a job only the host holds, and serves its providers (ADR 0022 step
    /// 3); weaverd watches it by its PID and restarts it.
    fn launchDev(self: *Host, slot: *Slot, now_ms: u64) void {
        self.prepareSlot(slot, now_ms) catch |err| return supervisor.recordLaunchFailure(slot, now_ms, err);
        self.ensureSharedHost(now_ms) catch |err| return supervisor.recordLaunchFailure(slot, now_ms, err);
        const line = self.launchDevCommand(slot) catch |err| {
            self.stopIdleHost();
            return supervisor.recordLaunchFailure(slot, now_ms, err);
        };
        defer self.allocator.free(line);
        const answer = self.controlRequest(line, dev_launch_answer_timeout_ms) catch |err| {
            // No widget code runs in the host for a launch: a host that
            // does not answer has a stuck control thread.
            if (err == error.HostTimedOut) {
                std.log.warn("shared widget host did not answer within {d} ms while launching dev widget '{s}'; stopping it", .{ dev_launch_answer_timeout_ms, slot.name() });
                _ = c.TerminateProcess(self.shared.process.process.?, 1);
            }
            return supervisor.recordLaunchFailure(slot, now_ms, err);
        };
        if (!answer.ok) {
            self.stopIdleHost();
            return supervisor.recordLaunchFailureNamed(slot, now_ms, answer.errorName());
        }
        // The host holds its own handle until weaverd sends stopDev, so this
        // PID is the widget's for as long as the host answers for it.
        const access = c.SYNCHRONIZE | c.PROCESS_QUERY_LIMITED_INFORMATION | c.PROCESS_VM_READ;
        const process = c.OpenProcess(access, 0, answer.pid) orelse {
            self.stopDevInHost(slot, false);
            self.stopIdleHost();
            return supervisor.recordLaunchFailure(slot, now_ms, error.DevProcessUnavailable);
        };
        slot.platform.process = process;
        slot.platform.pid = answer.pid;
        self.thread_sample_ms = 0;
        self.markSlotRunning(slot, process, now_ms);
    }

    fn launchDevCommand(self: *Host, slot: *Slot) ![]u8 {
        const dist = try self.distPath(slot);
        defer self.allocator.free(dist);
        var subscribe: [4][]const u8 = undefined;
        var count: usize = 0;
        inline for (.{ .{ slot.wants_cpu, "cpu" }, .{ slot.wants_memory, "memory" }, .{ slot.wants_audio, "audio" }, .{ slot.wants_media, "media" } }) |entry| {
            if (entry[0]) {
                subscribe[count] = entry[1];
                count += 1;
            }
        }
        const capabilities: []const []const u8 = if (slot.wants_media_transport) &.{"media-transport"} else &.{};
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer line.deinit();
        try line.writer.print("{{\"launchDev\":{{\"id\":{d},\"dir\":{f},\"backend\":{f},\"subscribe\":{f},\"capabilities\":{f},\"gpu\":{}}}}}\n", .{
            self.slotIndex(slot),
            std.json.fmt(dist, .{}),
            std.json.fmt(slot.platform.backendPath(), .{}),
            std.json.fmt(subscribe[0..count], .{}),
            std.json.fmt(capabilities, .{}),
            slot.wants_gpu,
        });
        return line.toOwnedSlice();
    }

    /// Tell the host to stop dev widget `slot` and let go of it. A host
    /// that is gone has taken it with it.
    fn stopDevInHost(self: *Host, slot: *Slot, graceful: bool) void {
        if (self.shared.process.process == null) return;
        var buffer: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "{{\"stopDev\":{{\"id\":{d},\"graceful\":{}}}}}\n", .{ self.slotIndex(slot), graceful }) catch unreachable;
        const answer = self.controlRequest(line, dev_stop_answer_timeout_ms) catch |err| {
            if (err == error.HostTimedOut) {
                std.log.warn("shared widget host did not answer within {d} ms while stopping dev widget '{s}'; stopping it", .{ dev_stop_answer_timeout_ms, slot.name() });
                _ = c.TerminateProcess(self.shared.process.process.?, 1);
            }
            return;
        };
        if (!answer.ok) std.log.warn("shared widget host could not stop dev widget '{s}': {s}", .{ slot.name(), answer.errorName() });
    }

    fn slotIndex(self: *const Host, slot: *const Slot) usize {
        return (@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot);
    }

    fn distPath(self: *Host, slot: *const Slot) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ slot.source(), "dist" });
    }

    /// Bundle, read the manifest, and clear the slot's backend status file:
    /// everything a launch needs before the host loads or launches it.
    fn prepareSlot(self: *Host, slot: *Slot, now_ms: u64) !void {
        try self.ensureBundle(slot.source());
        const dist = try std.fs.path.join(self.allocator, &.{ slot.source(), "dist" });
        defer self.allocator.free(dist);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ dist, "widget.json" });
        defer self.allocator.free(manifest_path);
        const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, .limited(64 * 1024));
        defer self.allocator.free(manifest_bytes);
        const Manifest = struct {
            subscribe: []const []const u8 = &.{},
            capabilities: []const []const u8 = &.{},
            renderBackend: []const u8 = "software",
        };
        const manifest = try std.json.parseFromSlice(Manifest, self.allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
        defer manifest.deinit();
        supervisor.selectManifest(slot, manifest.value.subscribe, manifest.value.capabilities, manifest.value.renderBackend, self.force_software);
        if (slot.wants_gpu) self.ensureRenderer(now_ms) catch {
            // ensureRenderer records the named failure for status and owns
            // retry/backoff. The widget may still start so it can reconnect
            // as soon as the shared renderer recovers.
        };
        const backend_hash = std.hash.Wyhash.hash(0, slot.name());
        const backend_path = try std.fmt.bufPrint(&slot.platform.backend_path_buffer, "{s}.backend-{x}", .{ self.status_path, backend_hash });
        slot.platform.backend_path_len = backend_path.len;
        std.Io.Dir.cwd().deleteFile(self.io, backend_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Process-wide environment every widget of a launch shares.
    fn setSharedEnv(self: *Host, wants_gpu: bool, wants_media: bool) !void {
        if (wants_gpu) try setEnv(self.allocator, env_renderer_pipe, self.renderer_pipe_name);
        if (wants_media) try setEnv(self.allocator, env_art_cache, self.art_cache_root);
    }

    fn clearSharedEnv(_: *Host) void {
        clearEnv(env_renderer_pipe);
        clearEnv(env_art_cache);
    }

    const Started = struct { process: c.HANDLE, pid: u32 };

    fn startProcess(self: *Host, command: []const u8) !Started {
        const command_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, command);
        defer self.allocator.free(command_w);
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var process_info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &process_info) == 0) return error.CreateProcessFailed;
        _ = c.CloseHandle(process_info.hThread);
        self.thread_sample_ms = 0;
        return .{ .process = process_info.hProcess, .pid = process_info.dwProcessId };
    }

    /// Mark the slot running, its cost sampled from `process`.
    fn markSlotRunning(self: *Host, slot: *Slot, process: c.HANDLE, now_ms: u64) void {
        if (usesProviders(slot)) self.provider_host_used = true;
        supervisor.markRunning(slot, now_ms, self.artifactMtime(slot.source()));
        slot.platform.previous_process_ticks = processTicks(process);
        slot.platform.previous_sample_ms = now_ms;
        slot.platform.sample_count = 0;
        slot.platform.sample_cursor = 0;
    }

    /// Add every hosted slot whose (re)start is due to the shared host,
    /// starting the host if it is not running. The widgets already in it
    /// keep running.
    fn startHostedWidgets(self: *Host, now_ms: u64) void {
        for (&self.slots) |*slot| {
            if (!slot.used or !slot.enabled or slot.dev or slot.platform.hosted) continue;
            const due = slot.state == .starting or (slot.state == .backoff and now_ms >= slot.next_restart_ms);
            if (!due or !self.sourceExists(slot.source())) continue;
            self.addHosted(slot, now_ms);
        }
    }

    fn addHosted(self: *Host, slot: *Slot, now_ms: u64) void {
        slot.platform.host_slot = self.freeHostSlot() orelse {
            slot.state = .stopped;
            slot.setReason("the shared widget host already runs {d} widgets, its limit (max_hosted_widgets); remove one, then reinstall this one", .{max_hosted_widgets});
            return;
        };
        self.prepareSlot(slot, now_ms) catch |err| return self.failLaunch(slot, now_ms, err);
        if (self.quarantined(slot)) {
            slot.platform.host_slot = null;
            return;
        }
        self.ensureSharedHost(now_ms) catch |err| return self.failLaunch(slot, now_ms, err);
        // The bundle about to load, noted before it runs: if loading it
        // crashes the host, this is the bundle quarantined (not the one
        // before it), and a load that fails stays stopped until a new one.
        slot.artifact_mtime = self.artifactMtime(slot.source());
        const line = self.addCommand(slot) catch |err| return self.failLaunch(slot, now_ms, err);
        defer self.allocator.free(line);
        const process = self.shared.process.process.?;
        const pid = self.shared.process.pid;
        const answer = self.controlRequest(line, control_answer_timeout_ms) catch |err| {
            // The host died or hung loading this widget. It is a member
            // now, so the exit is settled once and the host's record
            // decides who pays.
            slot.platform.hosted = true;
            slot.platform.pid = pid;
            if (err == error.HostTimedOut) {
                std.log.warn("shared widget host did not answer within {d} ms while adding '{s}'; stopping it", .{ control_answer_timeout_ms, slot.name() });
                _ = c.TerminateProcess(process, 1);
            }
            return;
        };
        if (!answer.ok) {
            // Loading is deterministic (a broken bundle or manifest), so
            // the slot stops until it is reinstalled or its source changes.
            slot.platform.host_slot = null;
            slot.state = .stopped;
            slot.setReason("widget did not load in the shared host: {s}; see 'weaver logs {s}'", .{ answer.errorName(), slot.name() });
            self.stopIdleHost();
            return;
        }
        slot.platform.hosted = true;
        slot.platform.pid = pid;
        // Its providers are the host's own, in process: nothing to connect.
        self.markSlotRunning(slot, process, now_ms);
    }

    /// Whether the ledger holds `slot` back: its bundle is the one that
    /// crashed the host. An entry for an older bundle is dropped.
    fn quarantined(self: *Host, slot: *Slot) bool {
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

    fn quarantine(self: *Host, slot: *Slot, code: u32) void {
        // The bundle that crashed is the one it was launched with
        // (`markRunning` noted its time), not whatever is on disk now: a
        // fixed bundle built while the old one ran must not inherit this.
        const artifact = if (slot.artifact_mtime != 0) slot.artifact_mtime else self.artifactMtime(slot.source());
        slot.artifact_mtime = artifact;
        slot.state = .stopped;
        slot.setReason("quarantined: its code crashed the widget host (exception 0x{X:0>8}); reinstall or update it to run it again", .{code});
        self.ledger.put(slot.name(), artifact, code);
        self.writeLedger();
    }

    fn loadLedger(self: *Host) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.ledger_path, self.allocator, .limited(256 * 1024)) catch return;
        defer self.allocator.free(bytes);
        self.ledger.parse(self.allocator, bytes) catch |err| std.log.warn("crash ledger ignored: {s}", .{@errorName(err)});
    }

    fn writeLedger(self: *Host) void {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        self.ledger.write(&output.writer) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = self.ledger_temp_path, .data = output.written() }) catch |err| return std.log.warn("crash ledger not written: {s}", .{@errorName(err)});
        cwd.rename(self.ledger_temp_path, cwd, self.ledger_path, self.io) catch |err| std.log.warn("crash ledger not published: {s}", .{@errorName(err)});
    }

    /// The record of the host that just exited, if it is that host's: the
    /// same PID and process start time.
    fn readHostRecord(self: *Host, process: c.HANDLE, pid: u32) ?HostRecord {
        var bytes: [@sizeOf(HostRecord)]u8 = undefined;
        const read = std.Io.Dir.cwd().readFile(self.io, self.record_path, &bytes) catch return null;
        if (read.len != bytes.len) return null;
        const record = std.mem.bytesToValue(HostRecord, &bytes);
        if (record.magic != HostRecord.magic_value or record.version != HostRecord.version_value or record.pid != pid) return null;
        // `open` writes `running` last; anything else was never finished.
        if (record.state != HostRecord.state_running and record.state != HostRecord.state_stopped) return null;
        var created: c.FILETIME = undefined;
        var unused: c.FILETIME = undefined;
        if (c.GetProcessTimes(process, &created, &unused, &unused, &unused) == 0) return null;
        const start: u64 = (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
        if (record.start_time != start) return null;
        return record;
    }

    fn failLaunch(_: *Host, slot: *Slot, now_ms: u64, err: anyerror) void {
        slot.platform.host_slot = null;
        supervisor.recordLaunchFailure(slot, now_ms, err);
    }

    /// The lowest shared-host slot no widget holds.
    fn freeHostSlot(self: *const Host) ?u16 {
        var taken: [max_hosted_widgets]bool = @splat(false);
        for (&self.slots) |*slot| {
            if (slot.platform.host_slot) |host_slot| taken[host_slot] = true;
        }
        for (taken, 0..) |is_taken, host_slot| {
            if (!is_taken) return @intCast(host_slot);
        }
        return null;
    }

    /// The registry slot running in shared-host slot `host_slot`.
    fn slotInHost(self: *Host, host_slot: u16) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.platform.hosted and slot.platform.host_slot == host_slot) return slot;
        }
        return null;
    }

    fn addCommand(self: *Host, slot: *Slot) ![]u8 {
        const dist = try self.distPath(slot);
        defer self.allocator.free(dist);
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer line.deinit();
        try line.writer.print("{{\"add\":{{\"id\":{d},\"dir\":{f},\"backend\":{f}}}}}\n", .{ slot.platform.host_slot.?, std.json.fmt(dist, .{}), std.json.fmt(slot.platform.backendPath(), .{}) });
        return line.toOwnedSlice();
    }

    /// One widget leaves the shared host and the others keep running; the
    /// host stops with its last widget, dev widgets included.
    fn removeHosted(self: *Host, slot: *Slot) void {
        var buffer: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "{{\"remove\":{{\"id\":{d}}}}}\n", .{slot.platform.host_slot.?}) catch unreachable;
        const answer = self.controlRequest(line, control_answer_timeout_ms);
        if (answer) |result| {
            self.releaseHostedSlot(slot);
            if (!result.ok) std.log.warn("shared widget host could not remove '{s}': {s}", .{ slot.name(), result.errorName() });
        } else |err| {
            // Its teardown runs its code (a storage flush can call its
            // toJSON), so the host can die removing it. Settle that exit
            // while it is still a member, so the host's record can name it.
            if (c.WaitForSingleObject(self.shared.process.process.?, 1000) == c.WAIT_OBJECT_0) {
                return self.settleSharedHostExit(c.GetTickCount64());
            }
            // Wedged: stop it, and the others start again in a new one.
            std.log.warn("shared widget host did not answer removing '{s}': {s}; restarting it", .{ slot.name(), @errorName(err) });
            self.releaseHostedSlot(slot);
            return self.stopSharedHost(false);
        }
        self.stopIdleHost();
    }

    /// Widgets that live in the shared host or its job: hosted widgets and
    /// running dev widgets.
    fn memberCount(self: *const Host) usize {
        var count: usize = 0;
        for (&self.slots) |*slot| count += @intFromBool(slot.platform.hosted or (slot.dev and slot.platform.process != null));
        return count;
    }

    /// The host stops with its last member.
    fn stopIdleHost(self: *Host) void {
        if (self.memberCount() == 0) self.stopSharedHost(true);
    }

    /// Start the shared host with no widgets, unless it is running: a
    /// hidden anchor window and a control pipe only it may open.
    fn ensureSharedHost(self: *Host, now_ms: u64) !void {
        if (self.shared.process.process != null) return;
        self.shared.launches += 1;
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "\\\\.\\pipe\\weaver-control-{d}-{d}", .{ c.GetCurrentProcessId(), self.shared.launches });
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, name);
        defer self.allocator.free(name_w);
        const control = c.CreateNamedPipeW(
            name_w.ptr,
            c.PIPE_ACCESS_DUPLEX | c.FILE_FLAG_OVERLAPPED | c.FILE_FLAG_FIRST_PIPE_INSTANCE,
            c.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | c.PIPE_WAIT,
            1,
            4096,
            4096,
            0,
            null,
        );
        if (control == invalid_handle) return error.CreatePipeFailed;
        errdefer _ = c.CloseHandle(control);
        const control_event = c.CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        errdefer _ = c.CloseHandle(control_event);
        try setEnv(self.allocator, env_control_pipe, name);
        defer clearEnv(env_control_pipe);
        // Every widget may be added later, so the host gets what any of
        // them could need.
        try self.setSharedEnv(true, true);
        defer self.clearSharedEnv();
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\" --host", .{self.runtime_exe});
        defer self.allocator.free(command);
        const started = try self.startProcess(command);
        errdefer {
            _ = c.TerminateProcess(started.process, 1);
            _ = c.CloseHandle(started.process);
        }
        if (!connectPipe(control, started.process, started.pid, 5_000)) return error.ConnectPipeFailed;
        self.shared.process = .{ .process = started.process, .pid = started.pid, .previous_process_ticks = processTicks(started.process), .previous_sample_ms = now_ms };
        self.shared.started_ms = now_ms;
        self.shared.control = control;
        self.shared.control_event = control_event;
    }

    /// Send one command line to the shared host and wait up to `timeout_ms`
    /// for its answer.
    fn controlRequest(self: *Host, line: []const u8, timeout_ms: u32) !ControlAnswer {
        const shared = &self.shared;
        const process = shared.process.process orelse return error.HostNotRunning;
        const deadline = c.GetTickCount64() + timeout_ms;
        var written: usize = 0;
        while (written < line.len) {
            written += try controlIo(.write, shared.control, shared.control_event, @constCast(line[written..]), process, deadline);
        }
        var answer: ControlAnswer = .{};
        var filled: usize = 0;
        while (std.mem.indexOfScalar(u8, answer.buffer[0..filled], '\n') == null) {
            if (filled == answer.buffer.len) return error.ControlAnswerTooLong;
            filled += try controlIo(.read, shared.control, shared.control_event, answer.buffer[filled..], process, deadline);
        }
        answer.len = std.mem.indexOfScalar(u8, answer.buffer[0..filled], '\n').?;
        const text = answer.text();
        var scratch: [max_answer_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&scratch);
        const Wire = struct { ok: bool = false, @"error": []const u8 = "", pid: u32 = 0 };
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), text, .{ .ignore_unknown_fields = true }) catch return error.ControlAnswerInvalid;
        answer.ok = wire.ok;
        answer.pid = wire.pid;
        // The name is a substring of the answer: an error name needs no
        // escapes. Kept as a position, so the answer can be copied.
        if (std.mem.indexOf(u8, text, wire.@"error")) |at| {
            answer.error_start = at;
            answer.error_len = wire.@"error".len;
        }
        return answer;
    }

    fn closeControl(self: *Host) void {
        if (self.shared.control != invalid_handle) _ = c.CloseHandle(self.shared.control);
        if (self.shared.control_event) |event| _ = c.CloseHandle(event);
        self.shared.control = invalid_handle;
        self.shared.control_event = null;
    }

    /// The shared host exited, and its job took its dev widgets with it. If
    /// its record shows that a widget's own code crashed it, that widget is
    /// quarantined and the others start again at once. Any other end (a
    /// crash outside widget code or in a provider, a kill, a fault no
    /// handler saw) names no widget, and every member pays a crash backoff.
    fn settleSharedHostExit(self: *Host, now_ms: u64) void {
        const process = self.shared.process.process orelse return;
        if (c.WaitForSingleObject(process, 0) != c.WAIT_OBJECT_0) return;
        var exit_code: c.DWORD = 1;
        _ = c.GetExitCodeProcess(process, &exit_code);
        const record = self.readHostRecord(process, self.shared.process.pid);
        const blamed: ?*Slot = blamed: {
            const crash = record orelse break :blamed null;
            if (crash.crash_kind != HostRecord.crash_widget_turn or crash.crash_slot == 0 or crash.crash_slot > max_hosted_widgets) break :blamed null;
            break :blamed self.slotInHost(@intCast(crash.crash_slot - 1));
        };
        for (&self.slots) |*slot| {
            if (slot.dev and slot.platform.process != null) {
                self.closeProcess(slot);
            } else if (slot.platform.hosted) {
                self.releaseHostedSlot(slot);
            } else continue;
            // Blame first: a widget removed because its source went
            // missing can crash the host in its teardown, and the same
            // bundle put back must stay quarantined.
            if (blamed == slot) {
                self.quarantine(slot, record.?.crash_code);
            } else if (!self.sourceExists(slot.source())) {
                _ = supervisor.nextSlotAction(slot, false, false, false, now_ms);
            } else if (blamed == null) {
                supervisor.recordCrash(slot, now_ms, exit_code);
            } else {
                slot.state = .starting;
                slot.next_restart_ms = 0;
            }
        }
        if (blamed) |slot| {
            std.log.warn("shared widget host crashed in '{s}' (exception 0x{X:0>8}); it is quarantined", .{ slot.name(), record.?.crash_code });
        } else if (record) |crash| {
            std.log.warn("shared widget host exited with code {d}; its record names no widget (crash kind {d})", .{ exit_code, crash.crash_kind });
        }
        self.closeSharedHost();
    }

    /// Stop the shared host: closing its control pipe tells it to exit.
    /// Members still due to run start again in a new host; the caller
    /// decides the state of a slot it is stopping.
    fn stopSharedHost(self: *Host, graceful: bool) void {
        const process = self.shared.process.process orelse return;
        if (graceful and self.provider_host_used) {
            // Its last counters, before they go with it.
            var scratch: [2 * max_answer_bytes]u8 = undefined;
            _ = self.queryProviders(&scratch);
        }
        self.closeControl();
        if (!graceful or c.WaitForSingleObject(process, 1500) != c.WAIT_OBJECT_0) _ = c.TerminateProcess(process, 0);
        _ = c.WaitForSingleObject(process, 1000);
        for (&self.slots) |*slot| {
            if (slot.dev and slot.platform.process != null) {
                // Its job ended it with the host.
                self.closeProcess(slot);
            } else if (slot.platform.hosted) {
                self.releaseHostedSlot(slot);
            } else continue;
            if (slot.state == .running) {
                slot.state = .starting;
                slot.next_restart_ms = 0;
            }
        }
        self.closeSharedHost();
    }

    fn releaseHostedSlot(_: *Host, slot: *Slot) void {
        slot.platform.hosted = false;
        slot.platform.host_slot = null;
        slot.platform.pid = 0;
    }

    fn closeSharedHost(self: *Host) void {
        self.provider_host_used = false;
        self.provider_totals = self.provider_totals.plus(self.provider_report.counters);
        self.provider_report = .{};
        if (self.shared.process.process) |process| _ = c.CloseHandle(process);
        self.shared.process = .{};
        self.closeControl();
        self.thread_sample_ms = 0;
    }

    fn rendererDesired(self: *const Host) bool {
        return supervisor.rendererDesired(&self.slots, self.force_software);
    }

    fn superviseRenderer(self: *Host, now_ms: u64) void {
        const renderer_running = self.renderer.platform.process != null;
        const exited = if (self.renderer.platform.process) |process| c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0 else false;
        switch (supervisor.nextRendererAction(renderer_running, exited, self.rendererDesired(), now_ms, self.renderer.next_restart_ms)) {
            .none => {},
            .handle_exit => {
                const process = self.renderer.platform.process.?;
                var exit_code: c.DWORD = 1;
                _ = c.GetExitCodeProcess(process, &exit_code);
                _ = c.CloseHandle(process);
                self.renderer.platform.process = null;
                self.renderer.platform.pid = 0;
                self.thread_sample_ms = 0;
                supervisor.recordRendererExit(&self.renderer, now_ms);
                self.noteRendererFailure(
                    "renderer process exited: code={d}; retrying in {d}ms",
                    .{ exit_code, self.renderer.next_restart_ms -| now_ms },
                );
            },
            .stop => {
                const process = self.renderer.platform.process.?;
                _ = c.TerminateProcess(process, 0);
                _ = c.WaitForSingleObject(process, 1000);
                _ = c.CloseHandle(process);
                self.renderer = .{};
                self.thread_sample_ms = 0;
            },
            .launch => self.ensureRenderer(now_ms) catch {
                self.renderer.next_restart_ms = now_ms + 1000;
            },
        }
    }

    fn ensureRenderer(self: *Host, now_ms: u64) !void {
        if (self.force_software or self.renderer.platform.process != null or now_ms < self.renderer.next_restart_ms) return;
        self.startRenderer(now_ms) catch |err| {
            self.noteRendererFailure(
                "renderer launch failed: {s}; retrying in 1000ms",
                .{@errorName(err)},
            );
            return err;
        };
        self.noteRendererRecovery();
    }

    fn startRenderer(self: *Host, now_ms: u64) !void {
        const command = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.renderer_exe});
        defer self.allocator.free(command);
        const command_w_const = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, command);
        defer self.allocator.free(command_w_const);
        const command_w = try self.allocator.dupeZ(u16, command_w_const);
        defer self.allocator.free(command_w);
        const pipe_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_pipe_name);
        defer self.allocator.free(pipe_w);
        const log_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, self.renderer_log_path);
        defer self.allocator.free(log_w);
        if (c.SetEnvironmentVariableW(env_renderer_pipe, pipe_w.ptr) == 0) return error.SetEnvironmentFailed;
        if (c.SetEnvironmentVariableW(env_renderer_log, log_w.ptr) == 0) return error.SetEnvironmentFailed;
        defer {
            _ = c.SetEnvironmentVariableW(env_renderer_pipe, null);
            _ = c.SetEnvironmentVariableW(env_renderer_log, null);
        }
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var info: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(null, command_w.ptr, null, null, 0, c.CREATE_NO_WINDOW, null, null, &startup, &info) == 0) return error.CreateRendererFailed;
        _ = c.CloseHandle(info.hThread);
        self.renderer.platform.process = info.hProcess;
        self.renderer.platform.pid = info.dwProcessId;
        self.thread_sample_ms = 0;
        self.renderer.started_ms = now_ms;
        self.renderer.platform.previous_process_ticks = processTicks(info.hProcess);
        self.renderer.platform.previous_sample_ms = now_ms;
        self.renderer.platform.sample_count = 0;
        self.renderer.platform.sample_cursor = 0;
    }

    fn noteRendererFailure(self: *Host, comptime format: []const u8, args: anytype) void {
        self.renderer_failure_count += 1;
        if (self.renderer_failure_count == 1) {
            var writer = std.Io.Writer.fixed(&self.renderer_failure_reason);
            writer.print(format, args) catch {
                writer = std.Io.Writer.fixed(&self.renderer_failure_reason);
                writer.writeAll("renderer unavailable; retrying") catch unreachable;
            };
            self.renderer_failure_reason_len = writer.buffered().len;
            std.log.err(
                "{s}; affected GPU widgets expose this failure through weaver status; repeated failures are suppressed until recovery",
                .{self.renderer_failure_reason[0..self.renderer_failure_reason_len]},
            );
        }
    }

    fn noteRendererRecovery(self: *Host) void {
        if (self.renderer_failure_count == 0) return;
        std.log.info("renderer recovered after {d} consecutive failures", .{self.renderer_failure_count});
        self.renderer_failure_count = 0;
        self.renderer_failure_reason_len = 0;
    }

    /// A dev widget's process exited. The host still holds its pipe and
    /// handle until told to let go.
    fn handleExit(self: *Host, slot: *Slot, now_ms: u64) void {
        var exit_code: c.DWORD = 1;
        _ = c.GetExitCodeProcess(slot.platform.process, &exit_code);
        self.stopDevInHost(slot, false);
        self.closeProcess(slot);
        self.stopIdleHost();
        if (!self.sourceExists(slot.source())) {
            _ = supervisor.nextSlotAction(slot, false, false, false, now_ms);
            return;
        }
        supervisor.recordCrash(slot, now_ms, exit_code);
    }

    fn stopSlot(self: *Host, slot: *Slot, graceful: bool) void {
        if (slot.platform.hosted) return self.removeHosted(slot);
        if (slot.platform.process == null) return;
        self.stopDevInHost(slot, graceful);
        self.closeProcess(slot);
        self.stopIdleHost();
    }

    fn closeProcess(self: *Host, slot: *Slot) void {
        if (slot.platform.process) |process| _ = c.CloseHandle(process);
        slot.platform.process = null;
        slot.platform.pid = 0;
        self.thread_sample_ms = 0;
        slot.platform.previous_process_ticks = 0;
    }

    fn sampleCosts(self: *Host, now_ms: u64) void {
        sampleProcess(&self.shared.process, now_ms);
        for (&self.slots) |*slot| {
            const process = slot.platform.process orelse continue;
            var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
            if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) == 0) continue;
            const ticks = processTicks(process);
            const elapsed_ms = now_ms -| slot.platform.previous_sample_ms;
            const tick_delta = ticks -| slot.platform.previous_process_ticks;
            const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
            slot.platform.private_samples[slot.platform.sample_cursor] = counters.PrivateUsage;
            slot.platform.cpu_samples[slot.platform.sample_cursor] = @round(cpu * 10.0) / 10.0;
            slot.platform.sample_cursor = (slot.platform.sample_cursor + 1) % slot.platform.private_samples.len;
            slot.platform.sample_count = @min(slot.platform.sample_count + 1, slot.platform.private_samples.len);
            slot.platform.previous_process_ticks = ticks;
            slot.platform.previous_sample_ms = now_ms;
        }
        if (self.renderer.platform.process) |process| {
            var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
            counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
            if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) != 0) {
                const ticks = processTicks(process);
                const elapsed_ms = now_ms -| self.renderer.platform.previous_sample_ms;
                const tick_delta = ticks -| self.renderer.platform.previous_process_ticks;
                const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
                self.renderer.platform.private_samples[self.renderer.platform.sample_cursor] = counters.PrivateUsage;
                self.renderer.platform.cpu_samples[self.renderer.platform.sample_cursor] = @round(cpu * 10.0) / 10.0;
                self.renderer.platform.sample_cursor = (self.renderer.platform.sample_cursor + 1) % self.renderer.platform.private_samples.len;
                self.renderer.platform.sample_count = @min(self.renderer.platform.sample_count + 1, self.renderer.platform.private_samples.len);
                self.renderer.platform.previous_process_ticks = ticks;
                self.renderer.platform.previous_sample_ms = now_ms;
            }
        }
    }

    fn restartAfterMediaChannelFailure(self: *Host, slot: *Slot, now_ms: u64) void {
        std.log.warn("restarting widget {s} after fatal provider channel failure", .{slot.name()});
        self.stopSlot(slot, false);
        supervisor.recordChannelFailure(slot, now_ms);
    }

    fn usesProviders(slot: *const Slot) bool {
        return slot.wants_cpu or slot.wants_memory or slot.wants_audio or slot.wants_media or slot.wants_media_transport;
    }

    fn hasProviderMember(self: *const Host) bool {
        for (&self.slots, 0..) |*slot, index| {
            if (self.running(index) and usesProviders(slot)) return true;
        }
        return false;
    }

    /// Ask the host for its providers' counters, and for the widgets whose
    /// provider channel failed since the last ask: those restart on their
    /// crash budget, as when weaverd ran the providers. It asks while a
    /// member uses the providers, and after the last one goes until the
    /// host reports audio idle (its audio worker closes the capture a moment
    /// after the widget leaves), so status never keeps a stale "live".
    fn refreshProviders(self: *Host, now_ms: u64) void {
        const report = &self.provider_report;
        const settled = !report.audio_capture_active and std.mem.eql(u8, report.availability(), "idle");
        if (!self.hasProviderMember() and settled) return;
        var scratch: [2 * max_answer_bytes]u8 = undefined;
        const wire = self.queryProviders(&scratch) orelse return;
        for (wire.failed.hosted) |host_slot| {
            const slot = self.slotInHost(host_slot) orelse continue;
            self.restartAfterMediaChannelFailure(slot, now_ms);
        }
        for (wire.failed.dev) |id| {
            if (id >= max_widgets) continue;
            const slot = &self.slots[id];
            const process = slot.platform.process orelse continue;
            // A dev widget that exited broke its pipe: that is its crash.
            if (c.WaitForSingleObject(process, 0) == c.WAIT_OBJECT_0) {
                self.handleExit(slot, now_ms);
            } else {
                self.restartAfterMediaChannelFailure(slot, now_ms);
            }
        }
    }

    /// The host's `providers` answer, its counters taken into
    /// `provider_report`; null when the host is not running or did not
    /// answer. The answer's lists live in `scratch`.
    fn queryProviders(self: *Host, scratch: []u8) ?ProviderReport.Wire {
        if (self.shared.process.process == null) return null;
        const answer = self.controlRequest("{\"providers\":{}}\n", control_answer_timeout_ms) catch |err| {
            if (err == error.HostTimedOut) {
                std.log.warn("shared widget host did not answer within {d} ms for its providers; stopping it", .{control_answer_timeout_ms});
                _ = c.TerminateProcess(self.shared.process.process.?, 1);
            }
            return null;
        };
        var fixed = std.heap.FixedBufferAllocator.init(scratch);
        const wire = std.json.parseFromSliceLeaky(ProviderReport.Wire, fixed.allocator(), answer.text(), .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.warn("shared widget host's providers answer is invalid: {s}", .{@errorName(err)});
            return null;
        };
        const value = wire.providers;
        self.provider_report.counters = .{
            .system_sample_count = value.systemSampleCount,
            .system_frames = value.systemFrames,
            .audio_frames = value.audioPipeFrames,
            .media_frames = value.mediaPipeFrames,
            .audio_capture_starts = value.audioCaptureStarts,
            .audio_provider_frames = value.audioProviderFrames,
        };
        self.provider_report.audio_capture_active = value.audioCaptureActive;
        self.provider_report.audio_silent = value.audioSilent;
        self.provider_report.audio_last_error = value.audioLastError;
        const label_len = @min(value.audioAvailability.len, self.provider_report.audio_availability_buffer.len);
        @memcpy(self.provider_report.audio_availability_buffer[0..label_len], value.audioAvailability[0..label_len]);
        self.provider_report.audio_availability_len = label_len;
        return wire;
    }

    fn writeStatus(self: *Host, now_ms: u64) void {
        if (self.thread_sample_ms == 0 or now_ms -| self.thread_sample_ms >= 30_000) {
            self.slot_threads = [_]u32{0} ** max_widgets;
            self.renderer_threads = 0;
            self.shared.threads = 0;
            collectThreadCounts(self, &self.slot_threads, &self.renderer_threads);
            self.thread_sample_ms = now_ms;
        }
        var entries: [max_widgets + 2]supervisor.StatusEntry = undefined;
        var entry_count: usize = 0;
        var backend_allocations = [_]?[]u8{null} ** max_widgets;
        defer for (backend_allocations) |value| if (value) |bytes| self.allocator.free(bytes);
        if (self.shared.process.process != null) {
            const average = self.shared.process.averages();
            entries[entry_count] = .{
                .name = "host",
                .pid = self.shared.process.pid,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = self.shared.threads,
                .backend = "-",
                .uptime_seconds = (now_ms -| self.shared.started_ms) / 1000,
                .state = .running,
                .reason = "",
                .host_row = true,
            };
            entry_count += 1;
        }
        if (self.renderer.platform.process != null) {
            const average = self.renderer.platform.averages();
            entries[entry_count] = .{
                .name = "renderer",
                .pid = self.renderer.platform.pid,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = self.renderer_threads,
                .backend = "gpu",
                .uptime_seconds = (now_ms -| self.renderer.started_ms) / 1000,
                .state = .running,
                .reason = "",
            };
            entry_count += 1;
        }
        for (&self.slots, 0..) |*slot, slot_index| {
            if (!slot.used) continue;
            const average = slot.platform.averages();
            var backend: []const u8 = "-";
            if ((slot.platform.process != null or slot.platform.hosted) and slot.platform.backend_path_len > 0) {
                backend_allocations[slot_index] = std.Io.Dir.cwd().readFileAlloc(self.io, slot.platform.backendPath(), self.allocator, .limited(16)) catch null;
                if (backend_allocations[slot_index]) |value| backend = value;
            }
            const slot_reason = slot.reason();
            const reason = if (slot_reason.len > 0)
                slot_reason
            else if (slot.wants_gpu and self.renderer_failure_reason_len > 0)
                self.renderer_failure_reason[0..self.renderer_failure_reason_len]
            else
                "";
            entries[entry_count] = .{
                .name = slot.name(),
                .pid = slot.platform.pid,
                .private_mb = average.private_mb,
                .cpu_percent = average.cpu,
                .threads = if (slot.platform.hosted) 0 else self.slot_threads[slot_index],
                .backend = backend,
                .uptime_seconds = if (slot.platform.process != null or slot.platform.hosted) (now_ms -| slot.started_ms) / 1000 else 0,
                .state = slot.state,
                .reason = reason,
                .hosted = slot.platform.hosted,
            };
            entry_count += 1;
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const report = &self.provider_report;
        const counters = self.provider_totals.plus(report.counters);
        supervisor.writeStatus(&output.writer, c.GetCurrentProcessId(), .{
            .system_subscribers = supervisor.systemSubscriberCount(&self.slots, self),
            .system_sample_count = counters.system_sample_count,
            .system_frames = counters.system_frames,
            .audio_capture_active = report.audio_capture_active,
            .audio_silent = report.audio_silent,
            .audio_pipe_frames = counters.audio_frames,
            .media_pipe_frames = counters.media_frames,
            .media_availability = "available",
            .media_subscribers = supervisor.subscriptionCount(&self.slots, .media, self),
            .audio_availability = report.availability(),
            .audio_subscribers = supervisor.subscriptionCount(&self.slots, .audio, self),
            .audio_capture_starts = counters.audio_capture_starts,
            .audio_provider_frames = counters.audio_provider_frames,
            .audio_last_error = report.audio_last_error,
        }, entries[0..entry_count]) catch |err| return self.noteStatusWriteFailure("encode", err);
        var cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = self.status_temp_path, .data = output.written() }) catch |err| return self.noteStatusWriteFailure("write temporary file", err);
        cwd.rename(self.status_temp_path, cwd, self.status_path, self.io) catch |err| return self.noteStatusWriteFailure("publish", err);
        self.noteStatusWriteRecovery();
    }

    fn noteStatusWriteFailure(self: *Host, operation: []const u8, err: anyerror) void {
        self.status_write_failures += 1;
        if (self.status_write_failures == 1) {
            std.log.err(
                "host status publication degraded while attempting to {s}: {s}; path={s}; repeated failures are suppressed until recovery",
                .{ operation, @errorName(err), self.status_path },
            );
        }
    }

    fn noteStatusWriteRecovery(self: *Host) void {
        if (self.status_write_failures == 0) return;
        std.log.info("host status publication recovered after {d} consecutive failures", .{self.status_write_failures});
        self.status_write_failures = 0;
    }

    fn ensureBundle(self: *Host, source: []const u8) !void {
        const source_path = try std.fs.path.join(self.allocator, &.{ source, "widget.tsx" });
        defer self.allocator.free(source_path);
        const bundle_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" });
        defer self.allocator.free(bundle_path);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ source, "dist", "widget.json" });
        defer self.allocator.free(manifest_path);
        const source_stat = try std.Io.Dir.cwd().statFile(self.io, source_path, .{});
        const bundle_stat = std.Io.Dir.cwd().statFile(self.io, bundle_path, .{}) catch null;
        const manifest_stat = std.Io.Dir.cwd().statFile(self.io, manifest_path, .{}) catch null;
        if (bundle_stat != null and manifest_stat != null and bundle_stat.?.mtime.nanoseconds >= source_stat.mtime.nanoseconds) return;
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "node", self.cli_script, "bundle", source },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .create_no_window = true,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.BundleFailed,
            else => return error.BundleFailed,
        }
    }

    pub fn artifactMtime(self: *Host, source: []const u8) i128 {
        const path = std.fs.path.join(self.allocator, &.{ source, "dist", "bundle.js" }) catch return 0;
        defer self.allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return 0;
        return stat.mtime.nanoseconds;
    }

    fn sourceExists(self: *Host, source: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(self.io, source, .{}) catch return false;
        return true;
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-down")) return signalEvent(shutdown_event_name);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--signal-reload")) return signalReloadAndWait();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe")) {
        const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, mutex_name);
        if (handle == null) return error.HostNotRunning;
        _ = c.CloseHandle(handle);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--probe-reload-ready")) {
        const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, mutex_name);
        if (handle == null) return error.HostNotRunning;
        _ = c.CloseHandle(handle);
        const ready = c.OpenEventW(c.SYNCHRONIZE, 0, reload_failure_event_name);
        if (ready == null) return error.HostNotRunning;
        _ = c.CloseHandle(ready);
        return;
    }
    const mutex = c.CreateMutexW(null, 0, mutex_name) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(mutex);
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) return;
    const shutdown_event = c.CreateEventW(null, 1, 0, shutdown_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(shutdown_event);
    const reload_event = c.CreateEventW(null, 0, 0, reload_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_event);
    const reload_success_event = c.CreateEventW(null, 1, 0, reload_success_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_success_event);
    const reload_failure_event = c.CreateEventW(null, 1, 0, reload_failure_event_name) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(reload_failure_event);
    const local_app_data = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    const directory = try std.fs.path.join(allocator, &.{ local_app_data, "weaver" });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    const registry_path = try std.fs.path.join(allocator, &.{ directory, "registry.json" });
    defer allocator.free(registry_path);
    const status_path = try std.fs.path.join(allocator, &.{ directory, "status.json" });
    defer allocator.free(status_path);
    const status_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{status_path});
    defer allocator.free(status_temp_path);
    const record_path = try std.fs.path.join(allocator, &.{ directory, "host.record" });
    defer allocator.free(record_path);
    const ledger_path = try std.fs.path.join(allocator, &.{ directory, "crash-ledger.json" });
    defer allocator.free(ledger_path);
    const ledger_temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{ledger_path});
    defer allocator.free(ledger_temp_path);
    cleanupBackendStatusFiles(init.io, directory);
    // The shared host owns the art cache (ADR 0022 step 3); weaverd only
    // names it in WEAVER_ART_CACHE.
    const art_cache_root = try std.fs.path.join(allocator, &.{ directory, "artcache" });
    defer allocator.free(art_cache_root);
    const repo_root = try repositoryRoot(allocator);
    defer allocator.free(repo_root);
    const runtime_exe = try std.fs.path.join(allocator, &.{ repo_root, "runtime", "zig-out", "bin", "weaver-widget.exe" });
    defer allocator.free(runtime_exe);
    const renderer_exe = try std.fs.path.join(allocator, &.{ repo_root, "renderer", "zig-out", "bin", "weaver-renderer.exe" });
    defer allocator.free(renderer_exe);
    const renderer_pipe_name = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\weaver-renderer-{d}", .{c.GetCurrentProcessId()});
    defer allocator.free(renderer_pipe_name);
    const renderer_log_path = try std.fmt.allocPrint(allocator, "{s}.renderer.log", .{status_path});
    defer allocator.free(renderer_log_path);
    std.Io.Dir.cwd().deleteFile(init.io, renderer_log_path) catch {};
    const cli_script = try std.fs.path.join(allocator, &.{ repo_root, "cli", "dist", "index.js" });
    defer allocator.free(cli_script);
    var host: Host = .{
        .io = init.io,
        .allocator = allocator,
        .repo_root = repo_root,
        .registry_path = registry_path,
        .status_path = status_path,
        .status_temp_path = status_temp_path,
        .record_path = record_path,
        .ledger_path = ledger_path,
        .ledger_temp_path = ledger_temp_path,
        .runtime_exe = runtime_exe,
        .renderer_exe = renderer_exe,
        .renderer_pipe_name = renderer_pipe_name,
        .renderer_log_path = renderer_log_path,
        .cli_script = cli_script,
        .art_cache_root = art_cache_root,
        .force_software = if (init.environ_map.get("WEAVER_FORCE_SOFTWARE")) |value| std.mem.eql(u8, value, "1") else false,
    };
    host.loadLedger();
    try host.loadRegistry();
    var next_cost_ms: u64 = 0;
    while (true) {
        const handles = [_]c.HANDLE{ shutdown_event, reload_event };
        const wait = c.WaitForMultipleObjects(handles.len, &handles, 0, 250);
        if (wait == c.WAIT_OBJECT_0) break;
        if (wait == c.WAIT_OBJECT_0 + 1) {
            host.loadRegistry() catch {
                _ = c.SetEvent(reload_failure_event);
                continue;
            };
            _ = c.SetEvent(reload_success_event);
        }
        const now = c.GetTickCount64();
        host.supervise(now);
        if (now >= next_cost_ms) {
            host.refreshProviders(now);
            host.sampleCosts(now);
            host.writeStatus(now);
            next_cost_ms = now + 2000;
        }
    }
    // Dev widgets close their windows first; the host's job would end them.
    for (&host.slots) |*slot| if (slot.platform.process != null) host.stopSlot(slot, true);
    host.stopSharedHost(true);
    if (host.renderer.platform.process) |process| {
        _ = c.TerminateProcess(process, 0);
        _ = c.WaitForSingleObject(process, 1000);
        _ = c.CloseHandle(process);
        host.renderer.platform.process = null;
    }
    host.writeStatus(c.GetTickCount64());
}

fn cleanupBackendStatusFiles(io: std.Io, directory_path: []const u8) void {
    var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
        std.log.warn("could not inspect renderer status sidecars: {s}", .{@errorName(err)});
        return;
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch |err| {
        std.log.warn("renderer status sidecar scan stopped: {s}", .{@errorName(err)});
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "status.json.backend-")) continue;
        directory.deleteFile(io, entry.name) catch |err| {
            std.log.warn("could not remove orphan renderer status sidecar {s}: {s}", .{ entry.name, @errorName(err) });
        };
    }
}

fn signalEvent(name: [*:0]const u16) !void {
    const event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(event);
    if (c.SetEvent(event) == 0) return error.SignalFailed;
}

fn signalReloadAndWait() !void {
    const signal_mutex = c.CreateMutexW(null, 0, reload_signal_mutex_name) orelse return error.CreateMutexFailed;
    defer _ = c.CloseHandle(signal_mutex);
    const mutex_wait = c.WaitForSingleObject(signal_mutex, 10_000);
    if (mutex_wait != c.WAIT_OBJECT_0 and mutex_wait != c.WAIT_ABANDONED) return error.ReloadSignalBusy;
    defer _ = c.ReleaseMutex(signal_mutex);

    const desired_access = c.SYNCHRONIZE | c.EVENT_MODIFY_STATE;
    const success_event = c.OpenEventW(desired_access, 0, reload_success_event_name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(success_event);
    const failure_event = c.OpenEventW(desired_access, 0, reload_failure_event_name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(failure_event);
    const reload_event = c.OpenEventW(c.EVENT_MODIFY_STATE, 0, reload_event_name) orelse return error.HostNotRunning;
    defer _ = c.CloseHandle(reload_event);
    if (c.ResetEvent(success_event) == 0 or c.ResetEvent(failure_event) == 0) return error.SignalFailed;
    if (c.SetEvent(reload_event) == 0) return error.SignalFailed;
    const acknowledgements = [_]c.HANDLE{ success_event, failure_event };
    const wait = c.WaitForMultipleObjects(acknowledgements.len, &acknowledgements, 0, 10_000);
    if (wait == c.WAIT_OBJECT_0) return;
    if (wait == c.WAIT_OBJECT_0 + 1) return error.RegistryReloadFailed;
    return error.RegistryReloadTimedOut;
}

fn repositoryRoot(allocator: std.mem.Allocator) ![]u8 {
    var path_w: [32768]u16 = undefined;
    const length = c.GetModuleFileNameW(null, &path_w, path_w.len);
    if (length == 0 or length == path_w.len) return error.ExecutablePathFailed;
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_w[0..length]);
    defer allocator.free(path);
    const bin_dir = std.fs.path.dirname(path) orelse return error.ExecutablePathFailed;
    const zig_out = std.fs.path.dirname(bin_dir) orelse return error.ExecutablePathFailed;
    const host_dir = std.fs.path.dirname(zig_out) orelse return error.ExecutablePathFailed;
    const repo = std.fs.path.dirname(host_dir) orelse return error.ExecutablePathFailed;
    return allocator.dupe(u8, repo);
}

fn sampleProcess(state: *WindowsRendererState, now_ms: u64) void {
    const process = state.process orelse return;
    var counters: c.PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(c.PROCESS_MEMORY_COUNTERS_EX);
    counters.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
    if (c.GetProcessMemoryInfo(process, @ptrCast(&counters), @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX)) == 0) return;
    const ticks = processTicks(process);
    const elapsed_ms = now_ms -| state.previous_sample_ms;
    const tick_delta = ticks -| state.previous_process_ticks;
    const cpu = if (elapsed_ms == 0) 0 else 100.0 * @as(f64, @floatFromInt(tick_delta)) / 10_000.0 / @as(f64, @floatFromInt(elapsed_ms));
    state.private_samples[state.sample_cursor] = counters.PrivateUsage;
    state.cpu_samples[state.sample_cursor] = @round(cpu * 10.0) / 10.0;
    state.sample_cursor = (state.sample_cursor + 1) % state.private_samples.len;
    state.sample_count = @min(state.sample_count + 1, state.private_samples.len);
    state.previous_process_ticks = ticks;
    state.previous_sample_ms = now_ms;
}

fn setEnv(allocator: std.mem.Allocator, name: [*:0]const u16, value: []const u8) !void {
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
    defer allocator.free(value_w);
    if (c.SetEnvironmentVariableW(name, value_w.ptr) == 0) return error.SetEnvironmentFailed;
}

fn clearEnv(name: [*:0]const u16) void {
    _ = c.SetEnvironmentVariableW(name, null);
}

fn setEnvUtf8(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(name_w);
    try setEnv(allocator, name_w.ptr, value);
}

fn clearEnvUtf8(allocator: std.mem.Allocator, name: []const u8) void {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch return;
    defer allocator.free(name_w);
    clearEnv(name_w.ptr);
}

fn processTicks(process: c.HANDLE) u64 {
    var created: c.FILETIME = undefined;
    var exited: c.FILETIME = undefined;
    var kernel: c.FILETIME = undefined;
    var user: c.FILETIME = undefined;
    if (c.GetProcessTimes(process, &created, &exited, &kernel, &user) == 0) return 0;
    return fileTime(kernel) + fileTime(user);
}

fn fileTime(value: c.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

fn collectThreadCounts(host: *Host, slot_counts: *[max_widgets]u32, renderer_count: *u32) void {
    const snapshot = c.CreateToolhelp32Snapshot(c.TH32CS_SNAPTHREAD, 0);
    if (snapshot == invalid_handle) return;
    defer _ = c.CloseHandle(snapshot);
    var entry: c.THREADENTRY32 = std.mem.zeroes(c.THREADENTRY32);
    entry.dwSize = @sizeOf(c.THREADENTRY32);
    if (c.Thread32First(snapshot, &entry) == 0) return;
    while (true) {
        if (entry.th32OwnerProcessID == host.renderer.platform.pid) renderer_count.* += 1;
        if (host.shared.process.pid != 0 and entry.th32OwnerProcessID == host.shared.process.pid) host.shared.threads += 1;
        for (&host.slots, 0..) |slot, index| {
            if (slot.platform.pid != 0 and entry.th32OwnerProcessID == slot.platform.pid) slot_counts[index] += 1;
        }
        if (c.Thread32Next(snapshot, &entry) == 0) break;
    }
}

fn connectPipe(pipe: c.HANDLE, process: c.HANDLE, expected_pid: u32, timeout_ms: u64) bool {
    const deadline = c.GetTickCount64() +| timeout_ms;
    while (true) {
        const now = c.GetTickCount64();
        if (now >= deadline or !connectPipeOnce(pipe, process, deadline - now)) return false;
        const actual_pid = namedPipeClientPid(pipe) orelse {
            _ = c.DisconnectNamedPipe(pipe);
            return false;
        };
        if (actual_pid == expected_pid) return true;
        std.log.warn(
            "rejecting control pipe client pid={d}; expected widget host pid={d}",
            .{ actual_pid, expected_pid },
        );
        // Reset the sole pipe instance before accepting any bytes. The
        // authorized child is the only process permitted to cross this
        // endpoint boundary.
        _ = c.DisconnectNamedPipe(pipe);
    }
}

fn connectPipeOnce(pipe: c.HANDLE, process: c.HANDLE, timeout_ms: u64) bool {
    const event = c.CreateEventW(null, 0, 0, null) orelse return false;
    defer _ = c.CloseHandle(event);
    var overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = event;
    if (c.ConnectNamedPipe(pipe, &overlapped) == 0) {
        const pipe_error = c.GetLastError();
        if (pipe_error == c.ERROR_PIPE_CONNECTED) {
            _ = c.SetEvent(event);
        } else if (pipe_error == c.ERROR_IO_PENDING) {
            const handles = [_]c.HANDLE{ event, process };
            const wait = c.WaitForMultipleObjects(handles.len, &handles, 0, @intCast(timeout_ms));
            if (wait != c.WAIT_OBJECT_0) {
                _ = c.CancelIoEx(pipe, &overlapped);
                var cancelled_bytes: c.DWORD = 0;
                _ = c.GetOverlappedResult(pipe, &overlapped, &cancelled_bytes, 1);
                return false;
            }
            var transferred: c.DWORD = 0;
            if (c.GetOverlappedResult(pipe, &overlapped, &transferred, 0) == 0) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn namedPipeClientPid(pipe: c.HANDLE) ?u32 {
    var pid: c.ULONG = 0;
    if (c.GetNamedPipeClientProcessId(pipe, &pid) == 0) return null;
    return @intCast(pid);
}

const ControlIo = enum { read, write };

/// One overlapped read or write on the control pipe, bounded by `deadline`
/// and abandoned if the host exits.
fn controlIo(direction: ControlIo, pipe: c.HANDLE, event: c.HANDLE, bytes: []u8, process: c.HANDLE, deadline: u64) !usize {
    var overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    overlapped.hEvent = event;
    _ = c.ResetEvent(event);
    const length: c.DWORD = @intCast(@min(bytes.len, std.math.maxInt(c.DWORD)));
    const started = switch (direction) {
        .read => c.ReadFile(pipe, bytes.ptr, length, null, &overlapped),
        .write => c.WriteFile(pipe, bytes.ptr, length, null, &overlapped),
    };
    if (started == 0 and c.GetLastError() != c.ERROR_IO_PENDING) return error.ControlPipeFailed;
    const now = c.GetTickCount64();
    const remaining: c.DWORD = @intCast(@min(deadline -| now, std.math.maxInt(c.DWORD) - 1));
    const handles = [_]c.HANDLE{ event, process };
    const wait = c.WaitForMultipleObjects(handles.len, &handles, 0, remaining);
    var transferred: c.DWORD = 0;
    if (wait != c.WAIT_OBJECT_0) {
        _ = c.CancelIoEx(pipe, &overlapped);
        _ = c.GetOverlappedResult(pipe, &overlapped, &transferred, 1);
        return if (wait == c.WAIT_OBJECT_0 + 1) error.HostExited else error.HostTimedOut;
    }
    if (c.GetOverlappedResult(pipe, &overlapped, &transferred, 0) == 0) return error.ControlPipeFailed;
    if (transferred == 0) return error.ControlPipeFailed;
    return transferred;
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

test {
    _ = registry;
    _ = backoff;
}

test "the control pipe rejects a connected client whose pid is not the launched host" {
    var name_buffer: [160]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buffer,
        "\\\\.\\pipe\\weaver-hijack-test-{d}-{d}",
        .{ c.GetCurrentProcessId(), c.GetTickCount64() },
    );
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
    defer std.testing.allocator.free(name_w);
    const pipe = c.CreateNamedPipeW(
        name_w.ptr,
        c.PIPE_ACCESS_DUPLEX | c.FILE_FLAG_OVERLAPPED,
        c.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | c.PIPE_WAIT,
        1,
        512,
        512,
        0,
        null,
    );
    try std.testing.expect(pipe != invalid_handle);
    defer _ = c.CloseHandle(pipe);

    const Connector = struct {
        fn run(path: [*:0]const u16) void {
            const client = c.CreateFileW(path, c.GENERIC_READ | c.GENERIC_WRITE, 0, null, c.OPEN_EXISTING, 0, null);
            if (client != invalid_handle) {
                c.Sleep(500);
                _ = c.CloseHandle(client);
            }
        }
    };
    const connector = try std.Thread.spawn(.{}, Connector.run, .{name_w.ptr});
    defer connector.join();
    try std.testing.expect(!connectPipe(
        pipe,
        c.GetCurrentProcess(),
        c.GetCurrentProcessId() + 1,
        200,
    ));
}
