---
status: proposed
---

# Widgets share one QuickJS runtime, each in its own realm

ADR 0020 put every Widget in one host process but kept a QuickJS runtime per
Widget, and named the engine as the next per-Widget cost. Dara chose
(2026-10-15) to share the runtime and keep a realm per Widget: one
`JSRuntime` for the process, one `JSContext` (built-ins, globals) per Widget.
Sharing the realm as well was set aside: Widgets could then reach each other's
globals.

A shared runtime alone did not save memory. QuickJS's per-runtime malloc
accounting cannot cap one realm, so every Widget's allocations go through a
heap (`runtime/src/js_heap.zig`) that gives each Widget its own reserved
address range: a pointer names its owner, so the cap stays exact (32 MiB, as
before) and a Widget's bytes are countable on their own. But compiling a
bundle leaves thousands of freed parser blocks between the Widget's
long-lived ones, and those pages stay resident: a clock Widget held 270 KiB
live in 473 KiB committed. So bundles compile in the shared host range,
which every compile reuses and which is trimmed afterwards, and only the
finished bytecode is copied into the Widget's range (QuickJS's own
bytecode writer and reader, in memory; no bytecode is ever read from disk).
The Widget now commits 311 KiB for the same 270 KiB.

| `examples/clock`, Windows, private working set, no `weaverd` | per-Widget runtime | shared runtime |
|---|---:|---:|
| one Widget | 4.14–4.16 MiB | 3.91 MiB |
| ten Widgets in one host | 11.17–11.30 MiB | 9.57–9.64 MiB |
| ten Widgets, CPU over 60 s | 0.65% | 0.26–0.34% |

Same session, alternating builds, `E:\w\rm-bench\multi-measure.ps1`.

## What this gives up

- **A QuickJS fault reaches every Widget.** A bug inside the engine (not a
  Widget's exception) can now corrupt state shared by every realm. The host
  already shares one process and thread (ADR 0020), so this widens nothing
  the crash breadcrumb and restart don't already cover.
- **Collection is runtime-wide.** A garbage collection walks every realm,
  so one Widget's churn costs its neighbours' objects a visit. Ten clocks
  over 60 s still measured less CPU than ten runtimes.
- **Shared atoms are charged to whoever made them.** Interned strings
  created while compiling land in the host range. Ones a Widget creates at
  run time land in its range and can outlive it when another Widget uses
  the same string; a later Widget reusing that range sees those few bytes
  as taken.

The memory cap, the interrupt budget and exceptions stay per Widget: a
Widget that fills its range gets `InternalError: out of memory` while its
neighbours keep running (`runtime/src/js_engine.zig` tests this).
