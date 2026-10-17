//! What `weaverd` and the Windows widget host agree on (ADR 0022 step 4):
//! the named objects the CLI reaches the host through, the host's exit codes,
//! the environment `weaverd` restarts it with, and the layout of the host's
//! record. weaverd compiles this file directly; the runtime compiles it as
//! its `host_contract` module (runtime/build.zig). One definition, so the
//! two sides cannot drift.
const std = @import("std");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Held by the running host for its whole life: `weaver status` and `up`
/// probe it (`weaverd --probe`), and a second host exits when it exists.
pub const singleton_mutex = L("Local\\WeaverHostSingletonV2");
/// Manual reset: `weaver down` sets it, and the host stops.
pub const shutdown_event = L("Local\\WeaverHostShutdownV2");
/// Auto reset: the registry changed; the host reconciles and answers on
/// one of the two events below.
pub const reload_event = L("Local\\WeaverHostReloadV2");
/// Serializes CLI processes that signal a reload (`weaverd --signal-reload`).
pub const reload_signal_mutex = L("Local\\WeaverHostReloadSignalV2");
/// Manual reset: the reload took effect, and any widget it removed is gone
/// from the host, so the CLI may delete superseded install directories.
pub const reload_success_event = L("Local\\WeaverHostReloadSuccessV2");
/// Manual reset: the registry could not be read; nothing changed. Its
/// existence is also how the CLI tells the host can acknowledge reloads.
pub const reload_failure_event = L("Local\\WeaverHostReloadFailureV2");

/// The host exited because another host already runs: `weaverd` stops
/// rather than restart it. Every other non-zero exit is a crash.
pub const exit_already_running: u32 = 3;
/// The host's UI thread did not apply a widget's load or unload within the
/// management thread's deadline, and the host stopped itself so `weaverd`
/// restarts it, as `weaverd` stopped a host that did not answer.
pub const exit_wedged: u32 = 4;

/// Set by `weaverd` when it restarts a host after a crash it could not
/// attribute to one widget: how many such crashes happened within
/// `backoff.crash_window_ms`. The host backs every widget off by that
/// count, or holds them all stopped once it passes `backoff.restart_limit`.
pub const env_host_crashes = "WEAVER_HOST_CRASHES";
/// The crashed host's exit code, for the reason widgets show in status.
pub const env_host_exit_code = "WEAVER_HOST_EXIT_CODE";

pub const record_magic: u32 = 0x5248_5657; // "WVHR"
pub const record_version: u32 = 2;

pub const RecordState = enum(u32) { none = 0, running = 1, stopped = 2, _ };

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
    /// The exception code, or the runtime's panic code.
    code: u32 = 0,
    thread: u32 = 0,
    /// For `widget_turn`: the widget's slot plus one and its bundle.
    slot: u32 = 0,
    bundle: u64 = 0,
    /// When it happened, as a Windows FILETIME.
    time: u64 = 0,
};

/// Which widget a host slot holds, written when the host adds it: the next
/// host turns a crash's slot into a widget to quarantine with this.
pub const SlotIdentity = extern struct {
    /// Wyhash (seed 0) of its registered name; zero for an empty slot.
    name_hash: u64 = 0,
    /// Its bundle.js modification time when it was added, in nanoseconds
    /// since the Unix epoch: the bundle the quarantine holds.
    artifact: i64 = 0,
};

/// Host slots the record names: the runtime's `max_host_widgets`, which
/// pins it (runtime/src/main.zig).
pub const record_slots: usize = 32;

/// `%LOCALAPPDATA%\weaver\host.record`, which the host keeps mapped
/// (runtime/src/crash_record.zig) and the next host and `weaverd` read.
pub const Record = extern struct {
    magic: u32,
    version: u32,
    /// One more than the previous host's: tells a reader which start a
    /// record belongs to.
    generation: u64,
    pid: u32,
    state: RecordState,
    /// Process creation time (FILETIME): with `pid`, tells this process
    /// from a later one that reused its PID.
    start_time: u64,
    turn: Turn,
    crash: Crash,
    slots: [record_slots]SlotIdentity,
};

comptime {
    // The first 80 bytes kept their version-1 layout.
    std.debug.assert(@offsetOf(Record, "slots") == 80);
    std.debug.assert(@sizeOf(Record) == 80 + record_slots * 16);
}

/// The record in `bytes`, if it is one this version wrote.
pub fn parseRecord(bytes: []const u8) ?Record {
    if (bytes.len != @sizeOf(Record)) return null;
    const record = std.mem.bytesToValue(Record, bytes[0..@sizeOf(Record)]);
    if (record.magic != record_magic or record.version != record_version) return null;
    return record;
}
