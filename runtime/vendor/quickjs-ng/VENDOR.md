# QuickJS-NG

- Upstream: https://github.com/quickjs-ng/quickjs
- Version: `v0.15.1`
- Commit: `fd0a0210b7be00957751871e7e01b8291268fc29`
- License: MIT (see `LICENSE`)

M0 embeds only the core engine (`quickjs.c`, `dtoa.c`, `libregexp.c`, and
`libunicode.c`) and their headers. `quickjs-libc.c` is deliberately omitted:
widgets receive Weaver's small `native` global, not QuickJS's OS or std modules.

## Local changes

- Each context queues its own jobs (`JSContext.job_list` in `quickjs.c`).
  Weaver's widgets share one runtime, one context each (ADR 0021); with the
  runtime's single queue, one widget's promise jobs ran in another's turn.
  `JS_EnqueueJob` appends to the job's context; `JS_ExecuteContextJob(ctx)`
  and `JS_IsContextJobPending(ctx)` (`quickjs.h`) run and check one context's
  queue; the runtime-wide `JS_IsJobPending`, `JS_GetPendingJobContext` and
  `JS_ExecutePendingJob` scan contexts in creation order. A context marks
  its queued jobs for the collector and frees them with itself, so a
  dropped context's jobs never outlive it.
- `JS_SetChargeJobFunc(rt, func)` (`quickjs.h`): `JS_EnqueueJob` calls `func`
  around allocating a job, so a garbage collection in one widget's turn
  charges another widget's queued cleanup job to that widget's heap.
- `JS_SetChargeSharedFunc(rt, func)` (`quickjs.h`): QuickJS calls `func`
  around growing a runtime-wide table (atom hash and array, shape hash), so
  the table is charged to the host's heap, not to the widget whose turn grew
  it; otherwise it stayed in that widget's range after the widget was gone,
  and the next widget given the range had less room.
- `JS_DropRuntimeException(rt)`: clears the runtime's pending exception when
  a context failed to build and none is left to take it from; the slot is
  shared by every widget.
- `JS_GetDOMExceptionFields(ctx, val, &name, &message)`: reads a
  DOMException's fields without its prototype getters, so diagnostics can
  show one without running code.
