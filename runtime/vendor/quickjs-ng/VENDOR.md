# QuickJS-NG

- Upstream: https://github.com/quickjs-ng/quickjs
- Version: `v0.15.1`
- Commit: `fd0a0210b7be00957751871e7e01b8291268fc29`
- License: MIT (see `LICENSE`)

M0 embeds only the core engine (`quickjs.c`, `dtoa.c`, `libregexp.c`, and
`libunicode.c`) and their headers. `quickjs-libc.c` is deliberately omitted:
widgets receive Weaver's small `native` global, not QuickJS's OS or std modules.

## Local changes

- `JS_DropPendingJobs(rt, ctx)` (`quickjs.c`, `quickjs.h`): drops the queued
  jobs of one context. Weaver's widgets share one runtime (ADR 0021), so a
  widget's realm can go while other realms keep running; upstream only drops
  jobs when the whole runtime is freed.
