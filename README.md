# Server Gauge

Menu-bar Mac app (à la RAM Gauge) that shows **which project dev servers are
running** — project folder, port(s), and memory for the whole process tree —
with a stop button per server.

## How it works
- Finds every process listening on a TCP port (`lsof`), keeps only ones whose
  working directory is under your home folder (i.e. project servers, not
  system daemons; `~/Library` — Postgres.app etc. — is excluded too).
- The working directory names the project ("Semler Brossy Clients :3000"),
  walking up past generic monorepo folders so `eddy/packages/web` reads "eddy".
- Memory is summed across the server's process group — the real footprint,
  not the 12 MB wrapper holding the socket. Listeners in the same tree
  (monorepo web + api) merge into one row with both ports.
- ✕ sends SIGTERM to the whole process group. Rescans every 10 s.

## Claude Code alerts
Server Gauge also posts a macOS notification when a Claude Code session
finishes a turn ("<project> — Claude is done") or is waiting on you
("<project> — Claude needs your input"). Global `Stop`, `Notification`,
and `UserPromptSubmit` hooks in `~/.claude/settings.json` drop JSON event
files into `~/.claude/servergauge-events/`; the app watches that folder,
posts the notification, and deletes the file.

The menu bar mirrors the state: an orange bell that pulses (with a count)
while any session waits on input, a green checkmark for finished sessions
you haven't looked at yet. The panel lists each pending item with a dismiss button. State
clears itself — answering a session (UserPromptSubmit) clears its bell,
opening then closing the panel clears checkmarks, and unseen "done"s
expire after 30 minutes. Events queued while the app isn't running are
discarded on launch. Requires notification permission (System Settings →
Notifications → Server Gauge).

`make-icon.swift` regenerates `AppIcon.icns` (run `swift make-icon.swift`
if the design changes); build.sh copies it into the bundle.

## Build & run
```bash
./build.sh
open "Server Gauge.app"
```
Menu-bar only (no dock icon). To keep it across restarts: System Settings →
General → Login Items → add `Server Gauge.app`.

## Headless check
```bash
./.build/release/ServerGauge --scan
```
prints `project | command | ports | MB | cwd` per server.
