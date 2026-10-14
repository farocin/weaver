---
status: proposed
---

# All Widgets run in one GPUI runtime process; isolation moves to the QuickJS runtime

Weaver's memory per Widget is dominated by the OS process each Widget runs in.
On Windows, ten 60 fps copies of `examples/m4b-synthetic` on today's stack
(one `weaver-widget` process per Widget plus the shared `weaver-renderer`)
hold 130 MiB private working set and 572 MiB private bytes. A port of the same
scene to ten windows of one GPUI
([Zed's](https://github.com/zed-industries/zed/tree/main/crates/gpui) Rust UI
framework) process holds 28 MiB and 120 MiB. CPU is lower for GPUI on the
median (17% vs 36% as normal windows, 31% vs 37% on the desktop layer), but
the desktop-layer ranges overlap, and the GPUI port runs the bar math in Rust
where Weaver runs it in JS. Receipts:
[`spikes/gpui-host`](../../spikes/gpui-host/README.md).

The memory gap comes from process topology: every Weaver Widget process holds
11.4 MiB private working set and 50.6 MiB private bytes, and within GPUI
alone three windows cost 18 MiB in one process against 44 MiB as three
processes.

Decision: Weaver runs every Widget inside one runtime process built on GPUI.
That process owns every Widget window and the GPU device. Each Widget gets its
own QuickJS runtime on its own thread, with its own memory limit, stack limit
and interrupt handler. `weaverd` stays the supervisor and Provider host.
Widget source, the SDK, and `.weave` files do not change.

Today a Widget's reconciler mutates its retained tree synchronously inside its
own process (ADR 0009). Under this decision the tree lives on the Widget's
thread and each committed batch crosses to GPUI's UI thread. That is a new
boundary; its ownership, ordering and backpressure rules are designed in the
migration plan, not assumed.

## What this gives up

ADR 0010 rejected moving Widget logic into a shared process because it would
destroy "the crash-isolation and capability model that process-per-widget
provides". Both halves are real costs here.

- **Crash isolation.** JS faults stay per-Widget: exceptions, runaway loops
  (the interrupt handler) and heap exhaustion (the per-runtime limit) stop one
  Widget, as today. A native fault in our Rust code, GPUI, QuickJS, or the
  graphics driver now stops every Widget. `weaverd` restarts the runtime, and
  every Widget loses its in-memory state (`useState`, timers, open requests);
  only `useStorage` values survive, minus writes still inside its 200 ms
  debounce. ADRs 0010 and 0018 accepted a shorter outage: a renderer crash
  blanked pixels while Widget logic and state kept running. **This decision
  asks for acceptance of the larger trade.** A Widget that repeatedly
  triggers a native fault must also be identified and quarantined, as the
  supervisor does for a crashing process today.
- **Capabilities.** QuickJS has no ambient authority: Weaver compiles it
  without `quickjs-libc`, so a Widget can only call host functions registered
  into its own runtime, and the capability wall (ADR 0002) stays at that
  binding. What changes is identity. `weaverd` authenticates each Provider
  pipe by the client's process ID and authorizes media control per Widget
  slot. One process means one ID, so the runtime must carry per-Widget
  identity on every Provider and capability call instead. Separately, a
  QuickJS engine exploit already reaches the user's account today; in one
  process it also reaches other Widgets' memory, including their stored state.

Honest billing (ADR 0005) moves from OS counters to runtime accounting. A
Widget's row covers its QuickJS heap, retained tree, textures, its thread's CPU
time, and UI-thread time spent on its window; shared costs are a separate
runtime row. The cutover gate is attribution, not arithmetic: adding,
changing or removing one Widget must move that Widget's row by what it costs.

## Considered options

- **Keep the current stack.** Measured above.
- **One GPUI process per Widget.** Three single-window GPUI processes cost
  44 MiB and 198 threads, more threads than today's stack and only slightly
  less memory. The win requires one process.
- **One process on the Native fork.** A real alternative. Native already keeps
  a window map and a shared D3D renderer with one engine and many surfaces, so
  this is consolidation work, not a new renderer. It is unmeasured. GPUI is
  proposed because it already runs many windows from one process on D3D11
  and Metal, with Taffy layout and platform text, maintained upstream; the
  migration plan measures the Native consolidation before this ADR is
  accepted.

## Consequences

This ADR is accepted or rejected at the end of phase 1 of
[`docs/gpui-runtime-migration.md`](../gpui-runtime-migration.md). If accepted,
it supersedes the process-per-Widget half of ADR 0007 (one runtime image and
source-only Widgets stay), the substrate choice in ADR 0008, and the shared
renderer processes of ADRs 0010 and 0018. Those ADRs are marked superseded at
cutover, not before.
