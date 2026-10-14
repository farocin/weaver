---
status: proposed
---

# All Widgets run in one GPUI runtime process; isolation moves to the QuickJS context

Weaver's per-Widget cost is dominated by the OS process, not by rendering. On
Windows, ten 60 fps Widgets on today's stack (one `weaver-widget` process per
Widget plus the shared `weaver-renderer`) cost 41–43% of one core and
130 MiB private working set; the same ten Widgets as windows of one GPUI
([Zed's](https://github.com/zed-industries/zed/tree/main/crates/gpui) Rust UI
framework) process cost 22–28% and 28 MiB, with desktop-layer behavior and
Win+D survival intact (receipts:
[`spikes/gpui-host`](../../spikes/gpui-host/README.md)). Each extra GPUI
window costs about 1.4 MiB, against about 11.4 MiB per Widget process today.

Decision: Weaver runs every Widget inside one runtime process built on GPUI.
That process owns every Widget window and the one GPU device. Each Widget gets
its own QuickJS runtime on its own thread with its own memory limit and
interrupt handler; its reconciler still sends retained-tree mutation ops
(ADR 0009), now over an in-process channel to the UI thread instead of a pipe.
`weaverd` stays the supervisor and Provider host. Widget source, the SDK, and
`.weave` files do not change.

ADR 0010 rejected moving Widget logic into a shared process because it would
destroy "the crash-isolation and capability model that process-per-widget
provides". This ADR answers both halves:

- **Capabilities.** QuickJS has no ambient authority: Weaver embeds it without
  `quickjs-libc`, so a Widget can only call host functions registered into its
  own context. The capability wall (ADR 0002) is enforced at that binding.
  The OS process boundary never added to it: every Widget process ran as the
  same user with no OS sandbox. One thing does widen: a QuickJS engine exploit
  already reaches the user's account today, and in one process it also reaches
  other Widgets' memory, including their scoped state.
- **Crash isolation.** JS faults stay per-Widget: exceptions, runaway loops
  (interrupt handler) and memory exhaustion (per-runtime limit) stop one
  Widget, as today. What is given up: a native fault in our Rust code, GPUI,
  or the graphics driver now takes down every Widget. `weaverd` restarts the
  runtime and Widgets restore from scoped state. This is the blast radius
  ADR 0010 and ADR 0018 already accepted for a renderer crash.

Honest billing (ADR 0005) moves from OS counters to runtime accounting: each
Widget's row is its QuickJS heap, retained tree and surface textures, plus its
JS thread's CPU time and the UI-thread time spent laying out and painting its
window. Runtime overhead is its own row. The rows must sum to the process
total, and that check is part of the cutover gate.

## Considered options

- **Keep the current stack.** Measured above. Memory scales by ~11 MiB of
  private working set and ~50 MiB of private bytes per Widget, and the shared
  renderer adds IPC and a second process to every frame.
- **One GPUI process per Widget.** Rejected by measurement: 14.5 MiB and 66
  threads per process before drawing, worse than today.
- **One process on the Native fork.** Possible, but the fork would have to grow
  a multi-window, single-device GPU renderer on D3D11 and Metal. GPUI already
  is one, maintained upstream, with Taffy layout and platform text. We fork
  GPUI where Weaver needs more (gradients beyond linear, desktop windowing).

## Consequences

This supersedes the process-per-Widget half of ADR 0007 (one shared runtime
image and source-only Widgets stay), the substrate choice in ADR 0008, and the
shared renderer processes of ADR 0010 and ADR 0018. Those ADRs are marked
superseded only when the cutover in
[`docs/gpui-runtime-migration.md`](../gpui-runtime-migration.md) passes its
gates. Until then this ADR stays `proposed`, and the open questions listed
there can still reject it.
