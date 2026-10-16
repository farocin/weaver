---
status: proposed
---

# The widget host is the daemon; the OS restarts it

ADR 0020 put every Widget in one `weaver-widget --host` process, but
`weaverd` stayed a second process beside it to supervise it. With ten clock
Widgets on Windows (2026-10-16, private working set, same session):

| | MiB |
|---|---:|
| widget host | 6.77 |
| `weaverd` | 0.9 |
| Rainmeter 4.5, all ten skins in one process | 5.3–5.6 |

`weaverd` is about 40% of what still separates us from Rainmeter. A bare
Windows process costs 0.32 MiB, so slimming it to a supervisor saves about
0.6 MiB; removing it saves all 0.9 MiB.

What the supervisor buys is recovery from a host crash. A Widget's
JavaScript faults are already contained inside the host: its heap cap, turn
budget and error surface. So a host crash is a Weaver bug, and restarting
helps in only two cases. Either the crash came from one Widget, and the
restart skips that Widget (quarantine), or the crash was transient. A blind
restart after a deterministic crash just crashes again. Rainmeter never
restarts at all.

Decision (Dara, 2026-10-16): there is no supervisor process on Windows. The
widget host is the daemon. It asks the OS to restart it after a crash,
quarantines a Widget only when the crash is clearly that Widget's, and stops
asking after three crashes in ten minutes. `weaver status` says what
happened, even when nothing restarted. macOS keeps its process per Widget
and its `weaverd` until it moves to one host; launchd's `KeepAlive` is the
equivalent there, and is unmeasured.

## How the OS restart behaves

A test process registered with `RegisterApplicationRestart` and crashed.
Receipts are in the PR that adds this ADR.

- After running 62–70 s, it was restarted 5–37 s after the crash, with no
  dialog on screen. Treat those times as what one machine did, not a
  promise. The documented contract mentions user consent.
- After running 10 s, it was not restarted. Windows only restarts a process
  that ran at least 60 s.
- Windows only restarts a crash that Windows Error Reporting handles. Zig's
  default segfault handler, and an error mode inherited from a parent with
  `SEM_NOGPFAULTERRORBOX` (Git Bash has it), each stopped the restart.
- The spike's restarted instance exited at once. The real host still has to
  show that it restarts long-lived, crashes a second time, and comes back
  without a console window. `weaver-widget.exe` is a console-subsystem
  program today, and Windows restarts console programs in a new console. So
  the daemon host becomes a GUI-subsystem program. That is part of step 5's
  receipts.

## The host as daemon

**Control comes up before any Widget.** The singleton and the
`Local\WeaverHost*` control objects (probe, reload with acknowledgement,
down, status request) exist, and the host reports ready, before it
evaluates any Widget. A Widget that hangs or crashes at load cannot keep
`weaver down`, status or a fixed install from reaching the host.

**Zero Widgets, and Widgets in place.** The host runs with no Widgets: its
primary window is a hidden window of its own, and every Widget is a
secondary window, which Native already reconciles at runtime. Native stops
quitting when the last widget window closes. Loading or unloading a Widget
never restarts the process. That requires per-Widget resource lifetimes:
- fonts that can be unregistered, because Native font IDs are permanent
  today;
- each Widget's allocations in its own arena, freed when it unloads;
- a generation number on each slot, so a queued timer or wake for an
  unloaded Widget is dropped and never reaches a new one in the same slot.

Native already gives each view a stable slot (native#41).

**Management off the UI thread.** Registry reconciliation, bundle freshness
(which may run `node`), dev admission and provider teardown run on a
management thread. The UI thread only applies a prepared load or unload.
The reload acknowledgement, which tells the CLI it may delete superseded
install directories, is sent after that apply.

**Providers on threads that own them.** In `weaverd`, audio and media are
sampled on its main loop; that does not carry over. In the host:
- each provider (system sampling, audio, media, media commands) gets a
  worker thread that initialises COM and creates, polls, commands and
  destroys its objects;
- Widgets get frames through an in-process queue with the existing
  semantics: manifest authorisation, the per-widget command rate limit,
  acknowledgements and rejections, fatal-channel handling, wakes only on
  frames or acknowledgements, idle when nothing subscribes, and the
  meaning of the existing counters;
- one owner holds the artwork cache;
- the UI thread never runs provider code.

**Children die with the host.** The renderer and `--dev` Widget processes
run in a job object that kills them when the host's handle closes. A
restarted host starts them again. Dev Widgets get their providers from the
host over the existing authenticated pipes.

**One status writer, and a record that survives the crash.** Each host
start writes a generation record to `%LOCALAPPDATA%\weaver\host.json`
before loading any Widget: generation number, PID, process start time and
state `running`. The record also carries:
- **Clean exit:** a clean exit writes `stopped`.
- **Crash:** the crash path writes `crashed`, before the fail-fast. That
  covers the panic wrapper, after its diagnostics, and an unhandled-exception
  filter for access violations. The entry names the faulting thread's kind
  (UI or provider) and, for a UI-thread crash during a Widget's turn, that
  Widget's name and bundle identity.
- **Torn record:** if the crash path couldn't write, a record still
  `running` whose process is gone (PID and start time no longer match)
  means it crashed.

The CLI reads this record whether or not anything restarted, so `weaver
status` can say "not running: crashed at 14:02 in Clock (quarantined)" or
"not running: crashed three times in ten minutes; run `weaver up`". A
restarted host consumes the record exactly once, by generation.

**Quarantine only on evidence.** A crash on the UI thread inside a Widget's
turn quarantines that Widget's bundle identity, kept in
`%LOCALAPPDATA%\weaver\crash-ledger.json`. A new bundle or a reinstall
clears it. A crash on a provider thread, or outside any turn, quarantines
nothing and counts only toward the restart cap.

**Stopping and the cap.** `weaver down` writes a stop marker before it
signals the host. A host restarted by the OS reads it first and exits
without loading anything, so a pending restart cannot bring Widgets back
after `down`. The marker clears when `weaver up` runs. The fourth crash
within ten minutes leaves the host down (it doesn't re-register), and the
next `weaver up` starts a fresh count. The CLI edits the registry and the
crash ledger itself while the host is down; it already owns the registry.

**Panics and exits.** Only daemon mode re-registers for restart and routes
crashes to fail-fast. Dev, capture and macOS behave as today. A startup
error returned from `main` is an ordinary exit: a clean `stopped` record
with the reason, and no restart.

## What this gives up

- **First-minute crashes stay down** until `weaver up`. Weaver has no login
  start today, so nothing brings the host back at login either.
- **Restart is slower:** seconds to tens of seconds, against about 1 s.
- **One process holds everything.** A fault in provider code (WinRT,
  WASAPI) now takes the Widgets down with it. Today it takes `weaverd` down,
  and nothing restarts that.
- **A Windows-specific recovery path.**

## Order of work

Each step is its own PR, measured and reviewed. `weaverd` keeps supervising
until step 5 replaces it.

1. **In-place membership.** The host:
   - runs with zero Widgets and a hidden primary window;
   - has per-Widget resource lifetimes (fonts, arena, slot generations);
   - takes add and remove commands from `weaverd`, with acknowledgement.

   `weaverd` stops rebuilding the host when membership changes. Receipts:
   empty startup, all loads failing, removing the last Widget, adding again,
   and a hundred replacements with fonts and timers, with memory flat.
2. **Crash record and attribution.** `host.json`, UI-thread attribution and
   the ledger. `weaverd` reads them, replacing its attribution, and keeps
   restarting.
3. **Providers in the host,** on owned worker threads, serving hosted
   Widgets in process and dev Widgets over pipes. One artwork cache owner.
   `weaverd` stops running providers.
4. **Registry, control, status, renderer and dev launch move into the
   host,** with the job object. `weaverd` only starts the host and restarts
   it after a crash.
5. **OS restart.** GUI subsystem, `RegisterApplicationRestart`, stop
   marker, crash cap; then `weaverd` is deleted. Receipts: the real host
   restarted after a UI-thread crash and after a provider-thread crash,
   twice each, with no console window. Also `down` during a pending
   restart, and the cap.

## Consequences

- Ten clocks: about 0.9 MiB less, the host's own growth from the moved code
  aside, which each PR measures.
- Live install, uninstall and reload stop restarting every other Widget
  (step 1).
- Fewer moving parts: one process, one status writer, no pipes for hosted
  Widgets, and a crash record that says what happened.
