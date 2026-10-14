# Native one-process spike

Question 1 behind [ADR 0019](../../docs/adr/0019-one-gpui-runtime-process.md):
does running every Widget inside one Native process close the memory gap to
GPUI, without moving to GPUI?

Answer: no. On Native, a Widget costs about the same whether it has its own
process or is a thread of a shared one. The cost is state each Widget touches
at startup, and part of it can be cut without changing the process model.

## Machine and builds

Same machine and scene as [`spikes/gpui-host`](../gpui-host/README.md),
measured 2026-10-14 (Ryzen 7 5800X, RTX 4070, Windows 10.0.26200,
1920x1080 at 143 Hz, 96 DPI), with ordinary desktop load in the background.

Weaver `origin/master` at `e583ec8`, Native fork at `464ff65f`, with
[`runtime.patch`](runtime.patch) and [`native-sdk.patch`](native-sdk.patch)
applied, runtime and renderer built with `-Doptimize=ReleaseFast`. The patches
are spike code, not product code:

- `weaver-widget --multi <dist>...` starts one thread per Widget, each with a
  16 MiB stack reservation committed on demand (the main thread's own
  arrangement), and runs the ordinary Widget entry point on it: its own
  Native host, window, message loop, QuickJS runtime and renderer connection.
- Process-global runtime state becomes per-thread. The canvas command scratch
  becomes a per-thread heap buffer, so 256 KiB is not copied into every
  thread's TLS. Cross-thread wakes (dev reload, Providers) are not carried
  over; the scene uses neither.
- The shared-memory name for retained pixels gains the thread ID, so two
  Widgets in one process cannot collide.
- `WEAVER_SPIKE_LAZY_MODEL=1` builds the Model field by field instead of
  `WidgetApp.create`'s `self.model = .{}` (see below).
- `WEAVER_MEMORY_RECEIPT=1` also logs the field layout of the large structs.

## Scene and method

Ten tiled copies of `examples/m4b-synthetic` (480x320, 28 bars at 60 fps).
[`measure.ps1`](measure.ps1) bundles them, starts one `weaver-renderer` on a
private pipe and either ten `weaver-widget` processes or one `--multi`
process, without `weaverd`, under a scratch `LOCALAPPDATA`. It never touches a
running daemon or the user's registry, samples only the processes it
started, and deletes everything in `finally`. Counters are the ones in
`spikes/gpui-host`: private working set from
`Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`, private bytes
from `PrivateMemorySize64`, CPU from a 15-second `TotalProcessorTime` delta,
with every CPU endpoint read before any memory counter.

## Results: ten Widgets

Two rounds of two trials each, configurations interleaved. Raw output:
[`matrix-2026-10-14.log`](matrix-2026-10-14.log). Totals include the renderer
(16.3–16.8 MiB, 15–21% CPU).

| Widgets run as | Model setup | Private WS | Private bytes | Threads | CPU |
|---|---|---:|---:|---:|---:|
| 10 processes (today) | `create` | 133.4–137.7 MiB | 575–579 MiB | 118–131 | 46–53% |
| 1 process, 10 threads | `create` | 121.4–124.3 MiB | 555–559 MiB | 87–88 | 43–53% |
| 10 processes | lazy | 93.4–95.2 MiB | 576–579 MiB | 118–132 | 48–51% |
| 1 process, 10 threads | lazy | 77.3–83.3 MiB | 554–558 MiB | 87–88 | 46–56% |

For comparison, one GPUI process with ten windows held 28 MiB at 16–39% CPU
on the same machine.

Every Widget presented at 60 fps except the one in tile 6 (x=960, y=320),
which reported 115–400 presents per second in every configuration; that is
unexplained and not specific to this spike. CPU ranges overlap across all
four rows.

Window-only captures (Windows Graphics Capture of each Widget's HWND) show the
lazy-setup Widgets in one process drawing the same scene as today's
processes. The card background is missing in both, as it was in the
`spikes/gpui-host` captures.

## Where a Widget's memory goes

One Widget process, today's build, after warm-up: 11.4 MiB private working
set, of which 10.3 MiB is private allocations and 1.05 MiB is copy-on-write
image pages. [`regions.ps1`](regions.ps1) groups resident pages by allocation;
the field layout comes from `WEAVER_MEMORY_RECEIPT=1`.

| Allocation | Committed | Resident |
|---|---:|---:|
| `WidgetApp` (Model, retained tree, Native UI app state) | 7.3 MiB | 5.1 MiB |
| Main thread stack | 2.5 MiB | 2.5 MiB |
| Heap (QuickJS and the rest) | 1.0 MiB | 0.9 MiB |
| CPU copy of the Widget's pixels (480x320x4) | 0.6 MiB | 0.6 MiB |
| Native `Runtime` | 28.8 MiB | 0.4 MiB |

- **`WidgetApp`.** The resident range is offsets 0–5192 KiB: the whole
  Model, including the retained tree's 1024-node array (1.9 MiB) and 8-canvas
  array (2.3 MiB), then Native's `virtual_extent_tables` (385 KiB) and
  `effects` (493 KiB). The tree arrays are declared `undefined` and tracked by
  occupancy bits, but `WidgetApp.create` assigns `self.model = .{}`, which
  copies a full default image of the 4.3 MB Model. Building the Model field by
  field leaves those arrays untouched: one Widget drops to 7.1 MiB private
  working set and `WidgetApp` to 1.0 MiB resident.
- **Stack.** [`frames.ps1`](frames.ps1) lists functions whose frames exceed
  64 KiB. The Windows stack probe touches every page of such a frame on
  entry. Native's `rebuild` (1071 KiB), `refreshCanvasWidgetDisplayList`
  (1090 KiB) and `runWithOptions` (666 KiB), and Weaver's `main` (281 KiB),
  are fixed-capacity scratch arrays on the stack. Moving the display-list
  scratch into `Runtime` shrank that frame but left resident stack at
  2.4 MiB, so the deepest chain runs through other large frames; finding and
  moving all of them is a Native refactor, not done here.
- **Private bytes** are dominated by Native's 28.8 MiB `Runtime` struct,
  committed in full by `page_allocator.create` and almost entirely untouched.
  That is commit charge, not RAM in use.

## Reproduce

```powershell
# From a Weaver checkout at e583ec8 with the fork at 464ff65f:
git apply spikes/native-one-process/runtime.patch
git -C runtime/native-sdk apply ../../spikes/native-one-process/native-sdk.patch
# Build runtime and renderer with -Doptimize=ReleaseFast, then:
.\spikes\native-one-process\measure.ps1 -Topology processes -Widgets 10
.\spikes\native-one-process\measure.ps1 -Topology one -Widgets 10
$env:WEAVER_SPIKE_LAZY_MODEL = '1'   # then rerun both
.\spikes\native-one-process\measure.ps1 -Topology processes -Widgets 1 -Regions
.\spikes\native-one-process\frames.ps1
```
