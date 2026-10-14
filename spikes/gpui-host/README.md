# GPUI runtime spike

Question behind [ADR 0019](../../docs/adr/0019-one-gpui-runtime-process.md):
what do Weaver-shaped Widgets cost as windows of one
[GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) process,
compared with today's stack (one `weaver-widget` process per Widget plus the
shared `weaver-renderer`)?

Measured 2026-10-14 on Windows 11 (10.0.26200), 1920x1080 primary, GPUI pinned
to Zed `2dcc4cc0`, release build. Weaver baseline is `origin/master` at
`e583ec8`, ReleaseFast.

## Scene

`examples/m4b-synthetic`: a 480x320 card, two text labels, and 28 rounded bars
redrawn at 60 fps. `--mode canvas` in [`src/main.rs`](src/main.rs) ports it to
GPUI with the same bar math and draws the bars with `paint_quad`. Both stacks
used normal-layer windows tiled so every window was fully visible, and both ran
back to back in the same session.

## Counters

Same as [`docs/m4a-results.md`](../../docs/m4a-results.md): private working
set is `Win32_PerfFormattedData_PerfProc_Process.WorkingSetPrivate`, private
bytes is `PrivateMemorySize64`, CPU is a 15-second `TotalProcessorTime` delta as
a percent of one logical core. Weaver totals are renderer plus Widgets;
`weaverd` (0.5–0.8%, 1.8 MiB) is excluded.

## Results

| Widgets | Stack | CPU | Private WS | Private bytes | Threads | FPS each |
|---:|---|---:|---:|---:|---:|---:|
| 10 | weaver `e583ec8` (2 trials) | 41.0–43.2% | 129.8–130.5 MiB | 572 MiB | 119–123 | 60 |
| 10 | GPUI, one process (2 trials) | 22.0–28.2% | 28.2–28.3 MiB | 119–122 MiB | 69–71 | ~58 |
| 10 | GPUI, one process, desktop layer, after Win+D | 30.2% | 28.2 MiB | 122 MiB | 69 | ~58 |

Earlier the same day, against weaver binaries built 2026-08-30 from
`agent/gradient-exploration` (same counters):

| Widgets | Stack | CPU | Private WS | Private bytes | Threads |
|---:|---|---:|---:|---:|---:|
| 1 | GPUI | 3.8–5.9% | 14.4 MiB | 64 MiB | 66 |
| 1 | weaver | 5.0% | 25.0 MiB | 108 MiB | 68 |
| 3 | GPUI, one process | 10.9–17.3% | 18.2 MiB | 77 MiB | 68 |
| 3 | weaver | 13.5% | 48.9 MiB | 211 MiB | 79 |
| 10 | GPUI, one process | 23.6–29.9% | 28.5 MiB | 121 MiB | 70 |
| 10 | weaver (2 trials) | 42.9–49.9% | 130–139 MiB | 571–580 MiB | 120–131 |

Other runs:

- One GPUI process per Widget does not pay: three processes with one window
  each cost 43.5 MiB and 198 threads. A GPUI process costs ~14 MiB and ~66
  threads before it draws; each extra window costs ~1.4 MiB.
- `--mode viz` lays out 32 flex `div` bars with Taffy every frame instead of
  painting quads: 10 windows cost 29.7–36.7% and 29.6 MiB, still below
  today's stack.
- `--mode clock` (220x90 card, text changes once a second): 14.1 MiB, 0.62%
  CPU in its one clean sample. July's weaver clock receipt is 13.5 MiB, 0.31%.

## Desktop layer

`--desktop` applies Weaver's desktop-layer recipe
(`attachDesktopWindow` in the Native fork's `webview2_host.cpp`) to GPUI's
HWND from outside the crate, without forking GPUI: `WS_EX_NOACTIVATE`,
`WS_EX_TOOLWINDOW`, a WorkerW parent, `HWND_BOTTOM`. Ten Widgets stayed on the
desktop through Win+D with no taskbar buttons, at the cost in the table above.

![GPUI Widgets on the desktop after Win+D](gpui-desktop-after-wind.png)

On this Windows build the wallpaper WorkerW is a child of Progman, so the
top-level enumeration Weaver uses finds nothing and no parent was attached. The
Widgets survived Win+D anyway. Weaver's Native host uses the same lookup.

## Not measured

- macOS.
- Click-through (`WS_EX_TRANSPARENT`).
- JavaScript. QuickJS is already measured at +0.64 MiB and 16 ms cold start
  (ADR 0008).
- FPS is counted differently: GPUI counts `render()` calls (~58/s, timer
  driven), Weaver counts presents (60/s).

## Reproduce

```powershell
cargo build --release
.\measure.ps1 -Mode canvas -Windows 10
# For running weaver widgets:
.\measure-names.ps1
```

Pass `--desktop` to `gpui-spike.exe` for the desktop-layer run. Don't drive
Win+D from a script without saving the window list first: a synthetic Win+D
lost its toggle state and had to be undone window by window.
