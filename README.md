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
- ✕ sends SIGTERM to the whole process group. Refreshes every 5 s while open.

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
