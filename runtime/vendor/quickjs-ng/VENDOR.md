# QuickJS-NG

- Upstream: https://github.com/quickjs-ng/quickjs
- Version: `v0.15.1`
- Commit: `fd0a0210b7be00957751871e7e01b8291268fc29`
- License: MIT (see `LICENSE`)

M0 embeds only the core engine (`quickjs.c`, `dtoa.c`, `libregexp.c`, and
`libunicode.c`) and their headers. `quickjs-libc.c` is deliberately omitted:
widgets receive Weaver's small `native` global, not QuickJS's OS or std modules.

## Weaver changes

- `js_error_set_stackTraceLimit` releases the value it replaces, as
  `js_error_set_prepareStackTrace` already does. Upstream (checked against
  quickjs-ng master, October 2026) keeps every replaced value alive until
  the context is freed, and the context's leak check then fails at teardown.
