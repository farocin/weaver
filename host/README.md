# weaverd

On macOS, `weaverd` is a standalone native process, not a Native SDK
application. It owns singleton acquisition, registration reconciliation,
crash/backoff supervision, process cost sampling, acknowledged
reload/shutdown, and provider lifetime/fan-out.

On Windows the widget host is the daemon (ADR 0022 step 4,
runtime/src/daemon.zig): it owns the singleton and the control objects, the
registry, status, the crash ledger, the providers, `--dev` widgets and the
shared renderer, the last two in a job only it holds. `weaverd` only starts
the host and restarts it after a crash (src/windows_host.zig), and is the
CLI's quick client for the host's control objects (`--probe`,
`--probe-reload-ready`, `--signal-reload`, `--signal-down`). The registry
slots, backoff and status format stay in src/supervisor.zig, which both
platforms compile; src/host_contract.zig holds what weaverd and the Windows
host agree on.

The macOS host reads the shared renderer's wire contract from the pinned
Native SDK submodule. Initialize it with `git submodule update --init
runtime/native-sdk` from the repository root before building.

Build and test on macOS 14.2 or later, from `host`:

```sh
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
codesign --verify --deep --strict zig-out/Weaverd.app
```

The macOS build emits an ad-hoc-signed `Weaverd.app` agent with bundle ID
`com.sunkenintime.weaver.host`, deployment floor 14.2, and the System Audio
Recording usage description. The CLI launches only its nested executable so
authorization, daemon work, and status share one stable identity. This is a
developer build, not a Developer ID/notarized distribution claim.

Widget launches wait for a valid hello reply from the shared renderer's
message loop. Registering its service name alone does not establish readiness.
Pending widgets report the wait in status without consuming restart attempts,
and host reload/shutdown remain available while startup is pending. A renderer
exit clears readiness before another process starts. Existing widgets retain
their state and use the Native SDK's reconnect behavior; this launch gate does
not promote a widget that already selected software during a renderer outage
or a later packet/presentation refusal.

On Windows, build with the repository's Zig toolchain and an installed Windows
10 SDK:

```powershell
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
```

The runtime's build (runtime/build.zig) discovers the SDK and compiles the
Windows providers here with its C++/WinRT projection plus `windowsapp.lib`;
no package-manager C++ dependency is required. weaverd itself no longer
links them. The TypeScript CLI remains the sole Widget checker/bundler on both
platforms. The host invokes it only when `widget.tsx` is newer than
`dist/bundle.js` or the dist manifest is missing.

Persistent state lives at `%LOCALAPPDATA%\weaver` on Windows and
`~/Library/Application Support/Weaver` on macOS. macOS logs live at
`~/Library/Logs/Weaver`. Windows uses named synchronization objects; widgets
in the host get provider frames in process, and each subscribed `--dev`
widget gets one pipe from the host. macOS uses one acknowledged
control Unix socket and one unguessable, user-only provider socket per Widget
that subscribes to an available host provider; stale child ownership is
validated against the exact runtime executable before recovery.

Provider ownership stays obvious:

- CPU and memory are sampled once only while subscribed, then fanned out.
- Audio uses one capture and the shared 2048-point FFT, 32-band AGC/silence
  pipeline. macOS uses the public Core Audio process tap from 14.2 and explicit
  authorization; Windows uses WASAPI loopback.
- Windows media uses the public system media-session manager. macOS media is
  explicitly unavailable, allocates no endpoint or polling timer, emits no
  fabricated frame, and never loads private MediaRemote.
