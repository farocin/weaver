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

Decision (Dara, 2026-10-16): there is no supervisor process. On Windows the
widget host is the daemon. It asks the OS to restart it after a crash,
quarantines the Widget it was running when it died, and stops asking after
three restarts in ten minutes. `weaver status` says what happened.

## How the OS restart behaves

Receipts are in the PR that adds this ADR. A test process registered with
`RegisterApplicationRestart` and crashed:

- After running 62–70 s, it was restarted 5–37 s after the crash, with no
  dialog on screen.
- After running 10 s, it was not restarted. Windows only restarts a process
  that ran at least 60 s. That is a built-in guard against crash loops, and
  it also means a host that dies in its first minute stays down until
  `weaver up` or the next login.
- Windows only sees the crash if Windows Error Reporting handles it. Zig's
  default segfault handler catches the crash and exits quietly. A parent
  running with `SEM_NOGPFAULTERRORBOX` (Git Bash does) hands that error mode
  down. Either one stops the restart. So the host sets `SetErrorMode(0)`,
  turns off Zig's segfault handler, and ends a panic with
  `RaiseFailFastException`.

macOS keeps its process per Widget and its `weaverd` for now (ADR 0020).
When it moves to one host, launchd's `KeepAlive` is the equivalent; that is
not measured yet.

## What moves into the host

Everything `weaverd` does today except creating processes it doesn't need.
The map comes from a read-through of `windows_host.zig`:

- **Singleton and CLI control:** the `Local\WeaverHost*` objects (probe,
  reload with acknowledgement, down, status request). The CLI's commands
  keep their meaning, and `weaver up` starts the host.
- **Registry reconciliation, bundle freshness, widget admission and
  removal**, now inside the running process. Today any change of membership
  rebuilds the whole process. The host gains loading and unloading of a
  Widget's window, engine and tree in place, and it runs with zero Widgets.
- **Providers** (CPU and memory sampling, WASAPI audio, media and artwork
  through WinRT, media commands) on their own threads, as in `weaverd`. They
  never run on the UI thread, because blocking WinRT calls there would stall
  every Widget. Hosted Widgets read frames through an in-process queue, not
  a pipe.
- **Dev Widgets:** the host launches `--dev` processes and serves their
  providers over the existing authenticated pipes.
- **The renderer process** and its restart backoff.
- **status.json:** one writer again. It keeps `hostPid`, now the widget
  host, and gains the last crash and the quarantine list.
- **Crash ledger:** per-Widget crash history, quarantine and the restart
  count, persisted in `%LOCALAPPDATA%\weaver\crash-ledger.json`, because
  the process that keeps it is the one that dies. A new bundle or a reinstall
  clears that Widget's record, as a new artifact does today.
- **Crash attribution:** the breadcrumb becomes a small file the host maps,
  naming the Widget whose work is running. It is cleared between turns, so
  a crash outside any Widget's turn charges no Widget.

## What this gives up

- **First-minute crashes stay down.** A host that crashes within 60 s of
  starting is not restarted, and every Widget is gone until `weaver up` or
  the next login. `weaverd` restarted it within about a second.
- **Restart is slower:** 5–37 s, against about 1 s.
- **One process holds everything.** A fault in provider code (WinRT, WASAPI)
  now takes the Widgets down with it. Today it takes `weaverd` down, and
  nothing restarts that.
- **Status while the host is down comes from the file it left.** The CLI
  checks whether `hostPid` is alive and reports "not running", with the last
  crash it recorded.
- A Windows-specific restart path. macOS gets its own when it moves to one
  host.

## Order of work

Each step is its own PR, measured and reviewed:

1. The host runs with zero Widgets, and loads and unloads one in place.
2. The crash ledger and file breadcrumb. `weaverd` still supervises, but
   reads them.
3. Providers inside the host on worker threads. Hosted Widgets drop their
   pipes; `weaverd` keeps serving dev Widgets.
4. Registry, CLI control, status, the renderer and dev launching move into
   the host. `weaverd` becomes a thin launcher.
5. OS restart, quarantine and the restart cap. The thin launcher is deleted.

## Consequences

- Ten clocks: about 0.9 MiB less, the host's own growth from the moved code
  aside, which each PR measures.
- Live install, uninstall and reload stop restarting every other Widget, a
  side effect of step 1.
- Fewer moving parts: one process, one status writer, no pipes for hosted
  Widgets.
