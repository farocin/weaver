const std = @import("std");
const bridge = @import("bridge.zig");
const platform = @import("platform/root.zig");
const qjs = @import("qjs.zig");
const provider_mod = @import("provider.zig");
const tree_mod = @import("tree.zig");
const storage_mod = @import("storage.zig");
const widget_diagnostic = @import("widget_diagnostic.zig");
const js_heap = @import("js_heap.zig");
const c = qjs.c;

// QuickJS receipt (2026-07-29): a synthetic worst-good retained view with
// 1,024 JS node records measured 629,335 allocator bytes (553,712 live).
// 32 MiB leaves >50x headroom. It is each engine's heap range (js_heap.zig):
// address space only, committed as the engine allocates.
pub const memory_limit_bytes: usize = 32 * 1024 * 1024;
/// Engines one process can hold at once, one heap range each: every hosted
/// widget, plus one more so a dev hot swap can build its candidate beside
/// the engine it replaces. A last range holds runtime-level allocations.
/// main.zig pins max_host_widgets against it.
pub const max_engines: usize = 33;
// The same 1,024-record evaluation measured 8-11 ms in Debug on the Windows
// test runner. 100 ms leaves >9x measured headroom while still interrupting a
// runaway callback. This watchdog retains no memory.
pub const turn_budget_ms: u64 = 100;
// QuickJS's upstream 1 MiB default measured only 16 calls of a trivial
// recursive JS function. 4 MiB measured 70 calls, clearing the receipted
// 32-level widget-tree contract by >2x. runtime/build.zig reserves a 16 MiB
// process stack (4x this guard); stack pages commit only as recursion uses them.
pub const max_stack_bytes: usize = 4 * 1024 * 1024;
// Four simultaneous fetch slots can reject together; eight pending promise
// records leave 2x burst headroom. Each record is 32 bytes, so the fixed
// metadata costs 256 bytes; referenced JS values already live in QuickJS.
const max_pending_rejections: usize = 8;
// Exception detail ultimately enters widget_log's 8 KiB line buffer. 6,000
// bytes leaves >2 KiB for logger framing; this is one turn-lifetime stack
// buffer, not retained isolate memory. The visible first line is 150 bytes,
// enough for the longest current named budget diagnostic (<128 bytes).
const max_exception_detail_bytes: usize = 6000;
const max_visible_rejection_bytes: usize = 150;

pub const Error = error{
    OutOfMemory,
    QuickJs,
    ScriptException,
};

const PendingRejection = struct {
    promise: c.JSValue = qjs.undefinedValue(),
    reason: c.JSValue = qjs.undefinedValue(),
};

/// The one QuickJS runtime every engine in the process shares (ADR 0021):
/// atoms, shapes and the engine itself are paid once. Each widget keeps its
/// own realm (JSContext, built-ins, globals) and its own heap range, so its
/// memory cap stays exact. Created with the first engine, freed with the
/// last.
const Shared = struct {
    runtime: *c.JSRuntime,
    heap: js_heap.Heap,
    engines: usize = 0,
    /// Heap ranges handed to live engines.
    owners_in_use: std.StaticBitSet(max_engines) = .initEmpty(),
};

var shared: ?Shared = null;
/// The engine whose turn is running: the interrupt budget is its.
var executing_engine: ?*Engine = null;

/// Set by the host: route logs and the crash breadcrumb to `engine`'s
/// widget, whose code is about to run inside another widget's turn (one of
/// its queued jobs, see `pumpJobs`).
pub var enter_widget: ?*const fn (engine: *Engine) void = null;

/// The engine whose realm `context` is, through its opaque: the engine's
/// bridge state. Null once the engine is being destroyed.
fn engineOf(context: *c.JSContext) ?*Engine {
    const state: *bridge.State = @ptrCast(@alignCast(c.JS_GetContextOpaque(context) orelse return null));
    return @fieldParentPtr("bridge_state", state);
}

const heap_functions: c.JSMallocFunctions = .{
    .js_calloc = heapCalloc,
    .js_malloc = heapMalloc,
    .js_free = heapFree,
    .js_realloc = heapRealloc,
    .js_malloc_usable_size = heapUsableSize,
};

fn heap() *js_heap.Heap {
    return &shared.?.heap;
}

fn heapCalloc(_: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const bytes = std.math.mul(usize, count, size) catch return null;
    const block = heap().alloc(bytes) orelse return null;
    @memset(@as([*]u8, @ptrCast(block))[0..bytes], 0);
    return block;
}

fn heapMalloc(_: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return heap().alloc(size);
}

fn heapFree(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    heap().free(ptr orelse return);
}

fn heapRealloc(_: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return heap().realloc(ptr, size);
}

fn heapUsableSize(ptr: ?*const anyopaque) callconv(.c) usize {
    return heap().usableSize(ptr orelse return 0);
}

fn acquireShared() !*Shared {
    if (shared == null) {
        // The heap must be in place first: creating the runtime allocates.
        shared = .{
            .runtime = undefined,
            .heap = try js_heap.Heap.init(std.heap.page_allocator, .{ .owners = max_engines + 1, .range_bytes = memory_limit_bytes }),
        };
        const runtime = c.JS_NewRuntime2(&heap_functions, null) orelse {
            shared.?.heap.deinit(std.heap.page_allocator);
            shared = null;
            return error.OutOfMemory;
        };
        shared.?.runtime = runtime;
        c.JS_SetMaxStackSize(runtime, max_stack_bytes);
        c.JS_SetInterruptHandler(runtime, interruptHandler, null);
        c.JS_SetHostPromiseRejectionTracker(runtime, promiseRejectionTracker, null);
    }
    return &shared.?;
}

fn releaseShared(owner: js_heap.Owner) void {
    const state = &shared.?;
    state.owners_in_use.unset(owner);
    state.engines -= 1;
    if (state.engines != 0) return;
    state.heap.current = state.heap.hostOwner();
    c.JS_FreeRuntime(state.runtime);
    state.heap.deinit(std.heap.page_allocator);
    shared = null;
}

/// A single-widget QuickJS realm in the shared runtime. It runs only when the
/// Native SDK main loop enters `fireTimer`; no JS thread, OS timer, or hidden
/// render loop exists.
pub const Engine = struct {
    runtime: *c.JSRuntime,
    context: *c.JSContext,
    /// This engine's heap range: what it allocates, and its memory cap.
    owner: js_heap.Owner,
    /// The host's handle for this engine's widget, for `enter_widget`.
    host_widget: ?*anyopaque = null,
    bridge_state: bridge.State,
    provider: *provider_mod.Client,
    deadline_ms: u64 = 0,
    executing: bool = false,
    capture_clock_ms: ?u64 = null,
    pending_rejections: [max_pending_rejections]PendingRejection = [_]PendingRejection{.{}} ** max_pending_rejections,

    pub fn create(
        allocator: std.mem.Allocator,
        tree: *tree_mod.Tree,
        storage: *storage_mod.Store,
        origins: []const []const u8,
        provider: *provider_mod.Client,
        media_transport_enabled: bool,
        capture_mode: bool,
    ) !*Engine {
        const self = allocator.create(Engine) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        const state = acquireShared() catch return error.OutOfMemory;
        const owner: js_heap.Owner = @intCast(blk: {
            var free = state.owners_in_use.complement().iterator(.{});
            break :blk free.next() orelse return error.OutOfMemory;
        });
        state.owners_in_use.set(owner);
        state.engines += 1;
        errdefer releaseShared(owner);
        const previous_owner = state.heap.current;
        state.heap.current = owner;
        defer state.heap.current = previous_owner;
        const runtime = state.runtime;
        const context = c.JS_NewContext(runtime) orelse return error.OutOfMemory;
        errdefer c.JS_FreeContext(context);
        self.* = .{
            .runtime = runtime,
            .context = context,
            .owner = owner,
            .bridge_state = undefined,
            .provider = provider,
        };
        self.bridge_state = .{
            .tree = tree,
            .storage = storage,
            .provider = provider,
            .origins = origins,
            .media_transport_enabled = media_transport_enabled,
            .capture_mode = capture_mode,
        };
        bridge.install(context, &self.bridge_state) catch return error.QuickJs;
        return self;
    }

    pub fn destroy(self: *Engine, allocator: std.mem.Allocator) void {
        const state = &shared.?;
        const previous_owner = state.heap.current;
        state.heap.current = self.owner;
        self.flushStorage();
        // The job queue is the shared runtime's: this realm's queued jobs
        // would otherwise run in another widget's turn, after the bridge
        // state they call into is gone.
        c.JS_DropPendingJobs(state.runtime, self.context);
        for (&self.pending_rejections) |*pending| {
            c.JS_FreeValue(self.context, pending.promise);
            c.JS_FreeValue(self.context, pending.reason);
            pending.* = .{};
        }
        bridge.deinit(self.context, &self.bridge_state);
        c.JS_SetContextOpaque(self.context, null);
        c.JS_FreeContext(self.context);
        if (state.engines > 1) {
            // The realm's cycles go now, not at some later widget's GC, so
            // the range is empty before another engine takes it. Collecting
            // them can queue the realm's FinalizationRegistry callbacks.
            c.JS_RunGC(state.runtime);
            c.JS_DropPendingJobs(state.runtime, self.context);
        }
        state.heap.current = if (previous_owner == self.owner) state.heap.hostOwner() else previous_owner;
        releaseShared(self.owner);
        allocator.destroy(self);
    }

    pub fn evaluate(self: *Engine, source: []const u8, file_name: [*:0]const u8) Error!void {
        // The parser accepts a length but still uses one sentinel byte for
        // its end token. Widget files come from readFileAlloc, whose spare
        // capacity is not initialized, so make that byte explicit.
        const terminated = std.heap.page_allocator.dupeZ(u8, source) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(terminated);
        self.beginTurn();
        defer self.endTurn();
        const function = try self.compile(terminated, file_name);
        const result = c.JS_EvalFunction(self.context, function);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    /// Compile `source` into a function owned by this engine's heap range,
    /// holding only the bytecode. The parser's working memory is many
    /// short-lived blocks; made in the widget's range, they would stay
    /// resident between its long-lived ones. So compile in the shared host
    /// range, which every compile reuses, and copy the finished bytecode
    /// across.
    fn compile(self: *Engine, source: [:0]const u8, file_name: [*:0]const u8) Error!c.JSValue {
        var size: usize = 0;
        const written = written: {
            heap().current = heap().hostOwner();
            defer heap().current = self.owner;
            const compiled = c.JS_Eval(self.context, source.ptr, source.len, file_name, c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_COMPILE_ONLY);
            if (c.JS_IsException(compiled)) break :written null;
            defer c.JS_FreeValue(self.context, compiled);
            break :written c.JS_WriteObject(self.context, &size, compiled, c.JS_WRITE_OBJ_BYTECODE);
        } orelse return self.reportException();
        defer c.js_free(self.context, written);
        const function = c.JS_ReadObject(self.context, written, size, c.JS_READ_OBJ_BYTECODE);
        if (c.JS_IsException(function)) return self.reportException();
        return function;
    }

    /// Feed an explicit capture fixture through the same provider callback
    /// installed by `native.onProvider`. The capture bootstrap owns when this
    /// is called; ordinary desktop provider frames still arrive from Client.
    pub fn dispatchProviderFixture(self: *Engine, line: []const u8) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchProvider(self.context, &self.bridge_state, line)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn setCaptureClock(self: *Engine, epoch_ms: u64) !void {
        // JavaScript numbers preserve every integer only through 2^53 - 1;
        // the capture clock must remain byte-exact when it crosses into JS.
        const max_safe_integer: u64 = 9_007_199_254_740_991;
        if (epoch_ms > max_safe_integer) return error.CaptureClockOutOfRange;
        const script = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "Object.defineProperty(globalThis, '__weaverCaptureNowMs', {{ value: {d}, writable: true, configurable: false }});",
            .{epoch_ms},
        );
        defer std.heap.page_allocator.free(script);
        try self.evaluate(script, "weaver-capture-clock.js");
        self.capture_clock_ms = epoch_ms;
    }

    pub fn advanceCaptureClock(self: *Engine, milliseconds: u64) !void {
        const current = self.capture_clock_ms orelse return;
        const max_safe_integer: u64 = 9_007_199_254_740_991;
        if (milliseconds > max_safe_integer - current) return error.CaptureClockOutOfRange;
        const next = current + milliseconds;
        const script = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "globalThis.__weaverCaptureNowMs = {d};",
            .{next},
        );
        defer std.heap.page_allocator.free(script);
        try self.evaluate(script, "weaver-capture-clock-advance.js");
        self.capture_clock_ms = next;
    }

    pub fn timers(self: *const Engine) []const bridge.TimerSlot {
        return &self.bridge_state.timers;
    }

    /// The shared runtime's totals, every engine included.
    pub fn memoryUsage(self: *const Engine) c.JSMemoryUsage {
        var usage: c.JSMemoryUsage = undefined;
        c.JS_ComputeMemoryUsage(self.runtime, &usage);
        return usage;
    }

    /// Bytes this engine's own heap range holds.
    pub fn heapBytes(self: *const Engine) usize {
        return heap().usedBytes(self.owner);
    }

    pub fn heapGrownBytes(self: *const Engine) usize {
        return heap().grownBytes(self.owner);
    }

    pub fn setTree(self: *Engine, tree: *tree_mod.Tree) void {
        self.bridge_state.tree = tree;
    }

    pub fn setHotSwapSeed(self: *Engine, seed: []const u8) Error!void {
        const previous_owner = self.chargeHeap();
        defer heap().current = previous_owner;
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const value = c.JS_NewStringLen(self.context, seed.ptr, seed.len);
        if (c.JS_IsException(value) or c.JS_SetPropertyStr(self.context, global, "__weaverHotSwapSeed", value) < 0) return error.QuickJs;
    }

    pub fn captureHotSwap(self: *Engine, allocator: std.mem.Allocator) ?[]u8 {
        const result = self.callGlobal("__weaverCaptureHotSwap") catch |err| {
            std.log.warn("dev hot swap state capture failed; candidate will use fresh state: {s}", .{@errorName(err)});
            return null;
        };
        defer c.JS_FreeValue(self.context, result);
        if (!c.JS_IsString(result)) return null;
        const previous_owner = self.chargeHeap();
        defer heap().current = previous_owner;
        var len: usize = 0;
        const raw = c.JS_ToCStringLen2(self.context, &len, result, false) orelse {
            std.log.warn("dev hot swap state capture could not be converted to UTF-8; candidate will use fresh state", .{});
            return null;
        };
        defer c.JS_FreeCString(self.context, raw);
        return allocator.dupe(u8, raw[0..len]) catch |err| {
            std.log.warn("dev hot swap state capture allocation failed; candidate will use fresh state: {s}", .{@errorName(err)});
            return null;
        };
    }

    pub fn hotSwapAccepted(self: *Engine) bool {
        const result = self.callGlobal("__weaverHotSwapAccepted") catch |err| {
            std.log.warn("dev hot swap state acceptance check failed; candidate will use fresh state: {s}", .{@errorName(err)});
            return false;
        };
        defer c.JS_FreeValue(self.context, result);
        return c.JS_ToBool(self.context, result) == 1;
    }

    pub fn fireTimer(self: *Engine, timer_id: u64, timestamp_ns: u64) Error!void {
        const timer = for (&self.bridge_state.timers) |*candidate| {
            if (candidate.active and candidate.id == timer_id) break candidate;
        } else return;
        if (!c.JS_IsFunction(self.context, timer.callback)) return;
        self.beginTurn();
        defer self.endTurn();
        const timestamp = c.JS_NewFloat64(self.context, @as(f64, @floatFromInt(timestamp_ns)) / @as(f64, std.time.ns_per_s));
        defer c.JS_FreeValue(self.context, timestamp);
        var arguments = [_]c.JSValue{timestamp};
        const result = c.JS_Call(self.context, timer.callback, qjs.undefinedValue(), arguments.len, &arguments);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn fireEvent(self: *Engine, node_id: tree_mod.NodeId, kind: []const u8, payload: ?bridge.EventPayload) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchEvent(self.context, &self.bridge_state, node_id, kind, payload)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn hasCanvasFrames(self: *const Engine) bool {
        return bridge.hasCanvasFrames(&self.bridge_state);
    }

    pub fn fireCanvasFrames(self: *Engine, timestamp_ns: u64) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchCanvasFrames(self.context, &self.bridge_state, timestamp_ns)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn fireCanvasResize(self: *Engine, node_id: tree_mod.NodeId, width: f32, height: f32) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchCanvasResize(self.context, &self.bridge_state, node_id, width, height)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn hasActiveFetches(self: *const Engine) bool {
        return bridge.hasActiveFetches(&self.bridge_state);
    }

    pub fn activeFetchCount(self: *const Engine) usize {
        return bridge.activeFetchCount(&self.bridge_state);
    }

    pub fn renderFailed(self: *const Engine) bool {
        return bridge.renderFailed(&self.bridge_state);
    }

    pub fn drainFetches(self: *Engine) Error!void {
        self.beginTurn();
        defer self.endTurn();
        bridge.drainFetches(self.context, &self.bridge_state);
        try self.pumpJobs();
    }

    pub fn hasHostProvider(self: *const Engine) bool {
        return self.provider.isAvailable();
    }

    pub fn nextMediaDeadlineMs(self: *const Engine) ?u64 {
        return bridge.nextMediaDeadlineMs(&self.bridge_state);
    }

    pub fn drainProviders(self: *Engine) Error!usize {
        self.beginTurn();
        defer self.endTurn();
        var line_buffer: [provider_mod.max_line_bytes]u8 = undefined;
        var count: usize = 0;
        while (self.provider.take(&line_buffer)) |line| {
            if (!bridge.dispatchProvider(self.context, &self.bridge_state, line)) return self.reportException();
            count += 1;
        }
        if (!bridge.dispatchMediaAcks(self.context, &self.bridge_state)) return self.reportException();
        try self.pumpJobs();
        return count;
    }

    /// Run every queued job before the turn ends, each in a turn of the
    /// widget whose realm queued it. The queue is the shared runtime's: a
    /// garbage collection in this turn can queue another widget's
    /// FinalizationRegistry callbacks, and a job left behind would run in
    /// the next widget's turn. A job that throws is reported and the rest
    /// still run.
    fn pumpJobs(self: *Engine) Error!void {
        var failure: ?Error = null;
        while (c.JS_GetPendingJobContext(self.runtime)) |job_context| {
            const job_engine = engineOf(job_context) orelse {
                // A realm whose engine is being destroyed.
                c.JS_DropPendingJobs(self.runtime, job_context);
                continue;
            };
            if (job_engine == self) {
                self.runJob() catch |err| {
                    failure = err;
                };
            } else {
                self.runJobOf(job_engine);
            }
        }
        if (failure) |err| return err;
        self.flushUnhandledRejections();
    }

    fn runJob(self: *Engine) Error!void {
        var job_context: ?*c.JSContext = null;
        if (c.JS_ExecutePendingJob(self.runtime, &job_context) < 0) return self.reportExceptionFrom(job_context orelse self.context);
    }

    /// Run the next job, queued by `other`'s realm, as a turn of `other`:
    /// its budget, its heap, its log. This turn then resumes with the
    /// budget it had left.
    fn runJobOf(self: *Engine, other: *Engine) void {
        const remaining_ms = self.deadline_ms -| platform.monotonicMilliseconds();
        if (enter_widget) |enter| enter(other);
        other.beginTurn();
        // A failure is already in `other`'s log; this turn is not at fault.
        other.runJob() catch {};
        other.flushUnhandledRejections();
        other.endTurn();
        if (enter_widget) |enter| enter(self);
        self.deadline_ms = platform.monotonicMilliseconds() + remaining_ms;
        executing_engine = self;
        heap().current = self.owner;
    }

    /// Charge QuickJS allocations to this engine outside a turn; returns
    /// the owner to restore.
    fn chargeHeap(self: *const Engine) js_heap.Owner {
        const previous = heap().current;
        heap().current = self.owner;
        return previous;
    }

    fn callGlobal(self: *Engine, name: [*:0]const u8) Error!c.JSValue {
        self.beginTurn();
        defer self.endTurn();
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, name);
        defer c.JS_FreeValue(self.context, callback);
        if (!c.JS_IsFunction(self.context, callback)) return error.QuickJs;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        if (c.JS_IsException(result)) {
            c.JS_FreeValue(self.context, result);
            return self.reportException();
        }
        return result;
    }

    fn beginTurn(self: *Engine) void {
        // QuickJS records its C-stack top when the runtime is created, but
        // platform callbacks can enter from a materially deeper native
        // dispatch path (notably canvas resize during a near-cap rebuild).
        // A turn starts with no live JS frames, so refresh the reference
        // point before applying the receipted recursion guard above.
        if (!self.executing) c.JS_UpdateStackTop(self.runtime);
        self.deadline_ms = platform.monotonicMilliseconds() + turn_budget_ms;
        self.executing = true;
        executing_engine = self;
        heap().current = self.owner;
    }

    fn endTurn(self: *Engine) void {
        self.executing = false;
        executing_engine = null;
        heap().current = heap().hostOwner();
    }

    /// SDK storage normally flushes on its 200 ms native debounce. A clean
    /// window close gets one final synchronous hook. weaverd posts WM_CLOSE
    /// before its bounded termination fallback, so ordinary dev restarts,
    /// uninstall, and host shutdown all take this path; only a crashed or
    /// externally force-killed widget relies on the completed debounce.
    fn flushStorage(self: *Engine) void {
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, "__weaverFlushStorage");
        defer c.JS_FreeValue(self.context, callback);
        if (!c.JS_IsFunction(self.context, callback)) return;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) logExceptionFrom(self.context, self.bridge_state.emit_error_logs);
    }

    fn reportException(self: *Engine) Error {
        return self.reportExceptionFrom(self.context);
    }

    fn reportExceptionFrom(self: *Engine, context: *c.JSContext) Error {
        logExceptionFrom(context, self.bridge_state.emit_error_logs);
        return error.ScriptException;
    }

    fn flushUnhandledRejections(self: *Engine) void {
        for (&self.pending_rejections) |*pending| {
            if (c.JS_IsUndefined(pending.promise)) continue;
            var detail_buffer: [max_exception_detail_bytes]u8 = undefined;
            const details = valueDetails(self.context, pending.reason, &detail_buffer);
            if (self.bridge_state.emit_error_logs) widget_diagnostic.report("widget unhandled promise rejection:\n{s}", .{details});
            self.bridge_state.render_failed = true;
            var visible_buffer: [tree_mod.max_text_bytes]u8 = undefined;
            const first_line_length = std.mem.indexOfScalar(u8, details, '\n') orelse details.len;
            const first_line = validUtf8Prefix(details[0..first_line_length], max_visible_rejection_bytes);
            const visible = std.fmt.bufPrint(
                &visible_buffer,
                "unhandled promise rejection\n{s}",
                .{first_line},
            ) catch "Unhandled promise rejection; see the per-widget log";
            self.bridge_state.tree.showError(visible);
            c.JS_FreeValue(self.context, pending.promise);
            c.JS_FreeValue(self.context, pending.reason);
            pending.* = .{};
        }
    }
};

/// Takes the pending exception off `context`; logs it unless a test has
/// silenced the engine's error logs.
fn logExceptionFrom(context: *c.JSContext, emit: bool) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);
    if (!emit) return;
    var buffer: [max_exception_detail_bytes]u8 = undefined;
    widget_diagnostic.report("widget JavaScript exception:\n{s}", .{valueDetails(context, exception, &buffer)});
}

fn valueDetails(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    if (c.JS_IsError(value)) return errorValueDetails(context, value, buffer);
    var len: usize = 0;
    const raw = c.JS_ToCStringLen2(context, &len, value, false) orelse return "JavaScript value could not be formatted";
    defer c.JS_FreeCString(context, raw);
    const source = validUtf8Prefix(raw[0..len], buffer.len);
    @memcpy(buffer[0..source.len], source);
    return buffer[0..source.len];
}

fn errorValueDetails(context: *c.JSContext, value: c.JSValueConst, buffer: []u8) []const u8 {
    const name_value = c.JS_GetPropertyStr(context, value, "name");
    defer c.JS_FreeValue(context, name_value);
    const message_value = c.JS_GetPropertyStr(context, value, "message");
    defer c.JS_FreeValue(context, message_value);
    const stack_value = c.JS_GetPropertyStr(context, value, "stack");
    defer c.JS_FreeValue(context, stack_value);

    var name_len: usize = 0;
    const name_raw = c.JS_ToCStringLen2(context, &name_len, name_value, false);
    defer if (name_raw) |raw| c.JS_FreeCString(context, raw);
    var message_len: usize = 0;
    const message_raw = c.JS_ToCStringLen2(context, &message_len, message_value, false);
    defer if (message_raw) |raw| c.JS_FreeCString(context, raw);
    var stack_len: usize = 0;
    const stack_raw = c.JS_ToCStringLen2(context, &stack_len, stack_value, false);
    defer if (stack_raw) |raw| c.JS_FreeCString(context, raw);

    const name = if (name_raw) |raw| raw[0..name_len] else "Error";
    const message = if (message_raw) |raw| raw[0..message_len] else "";
    const stack = if (stack_raw) |raw| raw[0..stack_len] else "";
    if (message.len == 0 or std.mem.indexOf(u8, stack, message) != null) {
        const source = if (stack.len > 0) stack else name;
        const copied = validUtf8Prefix(source, buffer.len);
        @memcpy(buffer[0..copied.len], copied);
        return buffer[0..copied.len];
    }

    var cursor: usize = 0;
    appendDetail(buffer, &cursor, name);
    appendDetail(buffer, &cursor, ": ");
    appendDetail(buffer, &cursor, message);
    if (stack.len > 0) {
        appendDetail(buffer, &cursor, "\n");
        appendDetail(buffer, &cursor, stack);
    }
    return buffer[0..cursor];
}

fn appendDetail(buffer: []u8, cursor: *usize, value: []const u8) void {
    const copied = validUtf8Prefix(value, buffer.len -| cursor.*);
    @memcpy(buffer[cursor.* .. cursor.* + copied.len], copied);
    cursor.* += copied.len;
}

fn validUtf8Prefix(value: []const u8, maximum: usize) []const u8 {
    var length = @min(value.len, maximum);
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    return value[0..length];
}

fn promiseRejectionTracker(
    context: ?*c.JSContext,
    promise: c.JSValueConst,
    reason: c.JSValueConst,
    is_handled: bool,
    opaque_context: ?*anyopaque,
) callconv(.c) void {
    _ = opaque_context;
    const js = context orelse return;
    const self = engineOf(js) orelse return;
    const promise_pointer = c.JS_VALUE_GET_PTR(promise);
    for (&self.pending_rejections) |*pending| {
        if (c.JS_IsUndefined(pending.promise) or c.JS_VALUE_GET_PTR(pending.promise) != promise_pointer) continue;
        if (is_handled) {
            c.JS_FreeValue(js, pending.promise);
            c.JS_FreeValue(js, pending.reason);
            pending.* = .{};
        }
        return;
    }
    if (is_handled) return;
    for (&self.pending_rejections) |*pending| {
        if (!c.JS_IsUndefined(pending.promise)) continue;
        pending.* = .{
            .promise = c.JS_DupValue(js, promise),
            .reason = c.JS_DupValue(js, reason),
        };
        return;
    }
    var buffer: [tree_mod.max_text_bytes]u8 = undefined;
    std.log.err("widget unhandled promise rejection queue exhausted; newest rejection:\n{s}", .{valueDetails(js, reason, &buffer)});
}

fn interruptHandler(_: ?*c.JSRuntime, _: ?*anyopaque) callconv(.c) c_int {
    const self = executing_engine orelse return 0;
    return if (self.executing and platform.monotonicMilliseconds() >= self.deadline_ms) 1 else 0;
}

fn createTestEngine(tree: *tree_mod.Tree, store: *storage_mod.Store, provider: *provider_mod.Client) !*Engine {
    return Engine.create(std.testing.allocator, tree, store, &.{}, provider, false, false);
}

test "diagnostic truncation preserves UTF-8 boundaries" {
    const details = "failure 💥";
    try std.testing.expectEqualStrings("failure ", validUtf8Prefix(details, details.len - 1));
    try std.testing.expectEqualStrings(details, validUtf8Prefix(details, details.len));
}

test "capture mode bridge capability is runtime-owned" {
    var tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    const engine = try Engine.create(std.testing.allocator, &tree, &store, &.{}, &provider, false, true);
    defer engine.destroy(std.testing.allocator);

    try engine.evaluate(
        \\try { globalThis.native = { captureMode: false }; } catch {}
        \\try { native.captureMode = false; } catch {}
        \\if (native.captureMode !== true) throw new Error("captureMode was replaced by widget code");
    , "capture-mode-test.js");
}

test "a forced max_nodes failure is rolled back, named, and replaced by an error surface" {
    var tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const committed = try tree.createNode(.text);
    try tree.setText(committed, "healthy");
    try tree.setRoot(committed);

    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    const engine = try createTestEngine(&tree, &store, &provider);
    defer engine.destroy(std.testing.allocator);
    engine.bridge_state.emit_error_logs = false;

    var requested_buffer: [32]u8 = undefined;
    const requested = try std.fmt.bufPrint(&requested_buffer, "{d}", .{tree_mod.max_nodes + 1});
    const script = try std.mem.concat(std.testing.allocator, u8, &.{
        \\native.beginBatch();
        \\try {
        \\  for (let index = 0; index <
        ,
        requested,
        \\; index += 1) native.createNode("panel");
        \\  native.endBatch();
        \\} catch (error) {
        \\  native.abortBatch();
        \\  native.reportError("render", String(error) + "\n" + (error.stack || ""));
        \\}
    });
    defer std.testing.allocator.free(script);
    try engine.evaluate(script, "budget-test.js");

    try std.testing.expect(engine.renderFailed());
    try std.testing.expectEqual(@as(usize, 2), tree.nodeCount());
    try std.testing.expectEqual(tree_mod.Kind.column, (try tree.nodeConst(tree.root.?)).kind);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "node capacity exhausted: max_nodes={d}, asked for {d}",
        .{ tree_mod.max_nodes, tree_mod.max_nodes + 1 },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, (try tree.nodeConst(2)).textSlice(), expected) != null);
}

test "unhandled promise rejection is visible while a handled rejection stays healthy" {
    var rejected_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer rejected_tree.deinit();
    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    const rejected = try createTestEngine(&rejected_tree, &store, &provider);
    defer rejected.destroy(std.testing.allocator);
    rejected.bridge_state.emit_error_logs = false;
    try rejected.evaluate("Promise.resolve().then(() => { throw new Error('async exploded'); });", "promise-test.js");
    try std.testing.expect(rejected.renderFailed());
    try std.testing.expect(std.mem.indexOf(u8, (try rejected_tree.nodeConst(2)).textSlice(), "async exploded") != null);

    var handled_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer handled_tree.deinit();
    const handled = try createTestEngine(&handled_tree, &store, &provider);
    defer handled.destroy(std.testing.allocator);
    try handled.evaluate("Promise.reject(new Error('expected')).catch(() => {});", "handled-promise-test.js");
    try std.testing.expect(!handled.renderFailed());
}

test "a widget at its memory cap leaves its neighbour's realm untouched" {
    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    var neighbour_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer neighbour_tree.deinit();
    const neighbour = try createTestEngine(&neighbour_tree, &store, &provider);
    defer neighbour.destroy(std.testing.allocator);
    try neighbour.evaluate("globalThis.kept = new Array(1000).fill(7);", "neighbour.js");
    const neighbour_bytes = neighbour.heapBytes();

    var hog_tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer hog_tree.deinit();
    const hog = try createTestEngine(&hog_tree, &store, &provider);
    try hog.evaluate(
        \\globalThis.hog = [];
        \\let message = "";
        \\try { for (;;) hog.push(new ArrayBuffer(4 * 1024 * 1024)); } catch (error) { message = String(error); }
        \\if (!message.includes("out of memory")) throw new Error("expected out of memory, got " + message);
    , "hog.js");
    try std.testing.expect(hog.heapBytes() > memory_limit_bytes / 2);
    try std.testing.expect(hog.heapBytes() <= memory_limit_bytes);
    hog.destroy(std.testing.allocator);

    try std.testing.expectEqual(neighbour_bytes, neighbour.heapBytes());
    try neighbour.evaluate("if (kept.length !== 1000 || kept[999] !== 7) throw new Error('neighbour lost its state');", "neighbour-check.js");
}

test "a throwing job does not leave the widget's later jobs to another widget's turn" {
    var tree: tree_mod.Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    var provider: provider_mod.Client = .{};
    try provider.init(std.testing.io, null);
    defer provider.deinit();
    var store: storage_mod.Store = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .directory = ".",
        .path = "weaver-js-engine-test-storage.json",
        .temporary_path = "weaver-js-engine-test-storage.tmp",
    };
    const engine = try createTestEngine(&tree, &store, &provider);
    defer engine.destroy(std.testing.allocator);
    engine.bridge_state.emit_error_logs = false;

    try std.testing.expectError(error.ScriptException, engine.evaluate(
        \\queueMicrotask(() => { throw new Error("first job"); });
        \\queueMicrotask(() => { globalThis.second = true; });
    , "jobs.js"));
    // The runtime's job queue is shared: whatever is left would run in the
    // next widget's turn.
    try std.testing.expect(!c.JS_IsJobPending(engine.runtime));
    try engine.evaluate("if (globalThis.second !== true) throw new Error('second job did not run');", "jobs-check.js");
}

const TestWidgets = struct {
    provider: provider_mod.Client = .{},
    store: storage_mod.Store = undefined,
    trees: [2]tree_mod.Tree = undefined,

    fn init(self: *TestWidgets) !void {
        try self.provider.init(std.testing.io, null);
        self.store = .{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .directory = ".",
            .path = "weaver-js-engine-test-storage.json",
            .temporary_path = "weaver-js-engine-test-storage.tmp",
        };
        for (&self.trees) |*tree| tree.* = .{ .allocator = std.testing.allocator };
    }

    fn deinit(self: *TestWidgets) void {
        for (&self.trees) |*tree| tree.deinit();
        self.provider.deinit();
    }

    fn engine(self: *TestWidgets, index: usize) !*Engine {
        return createTestEngine(&self.trees[index], &self.store, &self.provider);
    }
};

var test_entered: [4]?*Engine = @splat(null);
var test_entered_count: usize = 0;

fn recordEnteredWidget(engine: *Engine) void {
    if (test_entered_count < test_entered.len) test_entered[test_entered_count] = engine;
    test_entered_count += 1;
}

test "another widget's queued job runs as that widget's turn" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const owner = try widgets.engine(0);
    defer owner.destroy(std.testing.allocator);
    const bystander = try widgets.engine(1);
    defer bystander.destroy(std.testing.allocator);

    try owner.evaluate(
        \\globalThis.registry = new FinalizationRegistry(() => { globalThis.cleaned = new ArrayBuffer(1024 * 1024); });
        \\// A cycle: only the collector frees it, not its last reference.
        \\(() => { const target = {}; target.self = target; registry.register(target, "token"); })();
    , "owner.js");
    // A collection anywhere queues the owner's cleanup callback; the
    // bystander's turn is the next to pump the shared queue.
    c.JS_RunGC(owner.runtime);
    try std.testing.expect(c.JS_IsJobPending(owner.runtime));
    const owner_bytes = owner.heapBytes();
    const bystander_bytes = bystander.heapBytes();
    test_entered_count = 0;
    enter_widget = recordEnteredWidget;
    defer enter_widget = null;
    try bystander.evaluate("globalThis.ran = true;", "bystander.js");

    try std.testing.expect(!c.JS_IsJobPending(owner.runtime));
    try std.testing.expect(owner.heapBytes() >= owner_bytes + 1024 * 1024);
    try std.testing.expect(bystander.heapBytes() < bystander_bytes + 64 * 1024);
    try std.testing.expectEqual(@as(usize, 2), test_entered_count);
    try std.testing.expectEqual(owner, test_entered[0].?);
    try std.testing.expectEqual(bystander, test_entered[1].?);
    try owner.evaluate("if (!(globalThis.cleaned instanceof ArrayBuffer)) throw new Error('cleanup did not run');", "owner-check.js");
}

test "a destroyed widget's queued jobs never run" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const survivor = try widgets.engine(1);
    defer survivor.destroy(std.testing.allocator);
    const failed = try widgets.engine(0);
    failed.bridge_state.emit_error_logs = false;
    try std.testing.expectError(error.ScriptException, failed.evaluate(
        \\Promise.resolve().then(() => native.createNode("panel"));
        \\throw new Error("load failed");
    , "failed.js"));
    try std.testing.expect(c.JS_IsJobPending(survivor.runtime));
    failed.destroy(std.testing.allocator);
    try std.testing.expect(!c.JS_IsJobPending(survivor.runtime));
    try survivor.evaluate("globalThis.alive = true;", "survivor.js");
}

test "freed small blocks give their capacity back to the widget" {
    var widgets: TestWidgets = .{};
    try widgets.init();
    defer widgets.deinit();
    const engine = try widgets.engine(0);
    defer engine.destroy(std.testing.allocator);
    // 100,000 short strings, in turns that each fit the turn budget.
    try engine.evaluate("globalThis.strings = [];", "churn.js");
    for (0..10) |_| try engine.evaluate("for (let index = 0; index < 10000; index += 1) strings.push('x'.repeat(100) + index);", "churn.js");
    try engine.evaluate("globalThis.strings = null;", "churn.js");
    c.JS_RunGC(engine.runtime);
    try engine.evaluate("globalThis.big = new ArrayBuffer(24 * 1024 * 1024);", "big.js");
}
