# GPUI runtime migration plan

Status: proposed with [ADR 0019](adr/0019-one-gpui-runtime-process.md).
Receipts so far: [`spikes/gpui-host`](../spikes/gpui-host/README.md).

## Why

Ten animated Widgets cost 130 MiB of private working set on today's stack
and 28 MiB as windows of one GPUI process. The difference is the process
model: ~11.4 MiB and ~50 MiB of private bytes per Widget process, plus a
renderer process and a pipe on every frame. Widget source, the SDK
([`sdk/CONTRACT.md`](../sdk/CONTRACT.md)) and `.weave` files stay exactly as
they are. Developers and their agents should not be able to tell anything
changed except the bill.

## What stays, what goes

| Piece | Fate |
|---|---|
| TSX, `@weaver/sdk`, reconciler, class compiler, `weaver check` | Stays. The class compiler gains a GPUI style target. |
| Retained-tree mutation ops (ADR 0009) | Stays. Ops travel over an in-process channel instead of a pipe. |
| QuickJS-NG, memory limit, interrupt handler | Stays. One runtime per Widget, each on its own thread. |
| `weaverd` supervision, registry, Providers | Stays. It supervises one runtime process instead of N. |
| `weaver-widget` (Native fork runtime) | Replaced by the GPUI runtime process. |
| `weaver-renderer` and the macOS render host | Retired. The runtime owns the one GPU device. |
| Native SDK fork | Retired after cutover. Gradient, DPI and windowing knowledge is ported, not lost. |

## Open questions that can still reject ADR 0019

Each one is settled by a receipt in `spikes/gpui-host`, not by argument.

1. **macOS.** Run the same spike on the MacBook: ten canvas Widgets in one
   process, physical footprint and CPU, against the ADR 0018 receipts
   (32–36 MiB per Widget). ADR 0012 measured ~93–103 MiB of AppKit and QuickJS
   per Widget process, so one process should win by more there, but that is a
   prediction.
2. **Idle-zero (ADR 0005).** Ten static clocks in one GPUI process must sit at
   ~0% CPU between ticks. The spike's single clock measured 0.62% in its one
   clean sample; find every wakeup before trusting it.
3. **Click-through.** `WS_EX_TRANSPARENT` on GPUI windows, and per-region hit
   testing for Widgets that are partly interactive.
4. **Software fallback and `weaver capture`.** GPUI's Windows renderer can
   create a WARP (software D3D11) device. Confirm it renders pixel-close to
   hardware, and decide whether `weaver capture` renders headlessly through
   GPUI or keeps a reference rasterizer.
5. **Billing accuracy.** Prototype per-Widget rows and check that they sum to
   the process total under load.
6. **One Widget cannot starve the others.** A Widget whose JS is busy must not
   delay another Widget's frames, and a Widget emitting huge op batches must
   hit a named limit with a fix-it message rather than stall the UI thread.

If any of these fails in a way we cannot fix, ADR 0019 is rejected and the
Native stack stays.

## Phases

Each phase lands as its own PRs with receipts. Nothing switches the default
until phase 6.

1. **Close the open questions above.** Gate: every question has a receipt;
   ADR 0019 moves to `accepted` or is rejected.
2. **Runtime skeleton.** A Rust GPUI runtime process supervised by `weaverd`
   loads Widget bundles, runs QuickJS per Widget, applies ops to a retained
   tree, and renders it as GPUI elements. Canvas maps to GPUI `canvas` with
   the existing command buffer. Gate: `examples/clock` and
   `examples/m4b-synthetic` match Native captures, idle-zero holds, and the
   memory receipt stays near the spike's.
3. **Element and styling parity.** Text, images, icons, shadows, gradients,
   interaction, drag and geometry (ADR 0016), per-monitor DPI. GPUI only has
   linear gradients; port radial, conic, mesh and Oklab from the gradient
   work into our GPUI fork's shaders. Gate: every `examples/styling-*` and
   `examples/m4b-parity` within today's parity tolerance.
4. **Providers, capabilities, billing.** Provider frames arrive in process.
   The capability wall binds per QuickJS context. `weaver status` shows
   per-Widget rows plus a runtime row. Gate: rows sum to the process total.
5. **macOS runtime.** Same process on Metal, desktop-level windows, Spaces and
   Stage Manager behavior. Gate: the macOS receipts from question 1 hold with
   real Widgets.
6. **Cutover.** Flip the default behind a flag, run the noro-player gate and the
   [skin parity targets](skin-parity-targets.md) on both OSes, then delete the
   Native runtime and renderer paths and mark ADRs 0007, 0008, 0010 and 0018
   superseded.

## Fork policy

GPUI is pinned to a Zed commit and forked where Weaver needs more
(gradients, desktop windowing if outside-the-crate calls stop being enough).
Changes that make sense upstream go upstream, as with the Native fork.
