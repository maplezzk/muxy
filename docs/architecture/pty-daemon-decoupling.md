# Terminal Host Decoupling: muxy-server Options

> Status: **P1 implemented** (A1-shim, minimal closed loop)
> Date: 2026-07-25 (decision), 2026-07-26 (P1 implementation)
> Branch: feat_to_server

## 1. Background and Goal

### 1.1 Problem

Muxy's terminal processes (shells / agents) are owned by Ghostty surfaces created
inside the app process (`Muxy/Views/Terminal/GhosttyTerminalNSView.swift` calls
`ghostty_surface_new`; the PTY is created with the surface). When the app exits,
the PTYs close and every running agent receives SIGHUP and dies.

Layout metadata (project/worktree/split/tab) is persisted
(`Muxy/Models/Workspace/AppState.swift`), but PTYs, scrollback, and running
processes are not. Reopening the app restarts every shell from scratch.

### 1.2 Goal (Phase 1: minimal closed loop)

1. Quitting Muxy does **not** kill agents / shells running in panes.
2. Reopening Muxy **re-attaches** every pane to its original session and restores
   the visible screen.
3. The server starts on demand; single client (the local app); no multi-client work.

### 1.3 Non-goals (Phase 1)

- Multiple clients attached to one pane (app + CLI + mobile simultaneously)
- App as a pure cell-grid renderer (cell-level rendering protocol)
- Session survival across daemon crashes (FD handoff / live upgrade)
- SSH remote panes

### 1.4 Reference: herdr

herdr (`~/CliProject/herdr`) is a Rust implementation that already proves this
architecture: a background server owns all PTYs, the TUI is a pluggable client,
and closing the TUI never affects sessions. It served as the design reference and
as a zero-code experience calibration tool (`herdr terminal attach <id>` inside a
muxy pane gives the same "close app, session survives" behavior today).

---

## 2. Key facts from code research

### 2.1 muxy side

| Fact | Implication |
|---|---|
| Ghostty surface config passes `GHOSTTY_PLATFORM_MACOS` + the current `NSView` pointer | surface/PTY is tightly coupled to an AppKit view; cannot move into a UI-less process as-is |
| `materializeHeadless()` exists but is a method of `GhosttyTerminalNSView` | offscreen-NSView works; a truly UI-free Ghostty surface is **unverified** |
| GhosttyKit is a prebuilt static library; the repo only wraps headers | headless capability cannot be confirmed from source; needs experiments |
| Mobile remote exists: WebSocket server embedded in the app, output = full cell snapshot (as ANSI) + raw PTY bytes, single-owner takeover | a "serialize terminal, render elsewhere" data path already works, and **mobile clients already run their own vt against raw bytes** |
| The `muxy` CLI talks to the running app over a unix socket | a client entry exists, but its endpoint is the app, not a daemon |
| Pane launch command is customizable (`TabArea.swift` `startupCommand`; the agent tab launcher uses it) | **a shim injection point exists**, no ghostty call-path changes needed |
| AppState / GhosttyService / TerminalViewRegistry are `@MainActor` singletons | app-side work must respect main-actor confinement, but doesn't block the daemon itself |

### 2.2 herdr side

Full report: `~/CliProject/herdr/.local/prd/external-gui-client-feasibility.md`

| Fact | Implication |
|---|---|
| Server owns all PTYs; two client protocols: bincode wire (`PROTOCOL_VERSION=18`, strict equality) + JSON API (~80 methods) | external clients can attach, but the protocol is dual-track with zero version tolerance |
| `herdr terminal attach <id>` exists: thin client rendering `TerminalAnsi` | a ready-made attach shim usable for experience calibration |
| Persistence = layout + ANSI replay; process re-attach requires explicit `--handoff` | "close client, keep session" works out of the box |
| No auth/rate limit; socket is 0o600 owner-only | acceptable for single-user local use |
| 91 commits in api/protocol over 3 months; migrating to server-owned protocol | a moving target as an external dependency |

---

## 3. Options considered

```text
A. Self-built muxy-server (Swift daemon)
   A1. Daemon owns PTYs/processes only; app keeps Ghostty vt + rendering
       A1-shim:  an attach shim runs inside each pane (dtach architecture)  ← chosen
       A1-full:  daemon hands raw PTY fds to app surfaces (needs ghostty changes)
   A2. Daemon owns Ghostty surfaces + vt; app is a pure cell renderer

B. herdr as the backend
   B1. muxy as a full herdr GUI client (JSON API + wire protocol)
   B2. muxy panes run `herdr terminal attach` as their launch command
```

### 3.1 Option A1-shim (chosen): lightweight daemon + in-pane attach shim

```text
┌──────────────────────────── Muxy.app ────────────────────────────┐
│  pane 1: Ghostty surface ── PTY ── shim (muxyd shim <paneID>)    │
│  pane 2: Ghostty surface ── PTY ── shim (muxyd shim <paneID>)    │
│  (ghostty vt / rendering / CJK / themes / selection unchanged)   │
└──────────────────────────────│───────────────────────────────────┘
                               │ unix socket (framed protocol)
┌──────────────────────────────▼───────────────────────────────────┐
│  muxyd (spawned on demand, setsid, stays resident)               │
│  session registry: {sessionID → PTY master, ring buffer, meta}   │
│  session 1: PTY ── zsh ── claude (agent)                         │
│  session 2: PTY ── zsh                                           │
│  · byte forwarding · scrollback ring buffer · TIOCSWINSZ ·       │
│  · sideband metadata (fg pid, cwd, exit status)                  │
└──────────────────────────────────────────────────────────────────┘
```

Key design decisions:

- **The daemon does not run a vt.** It forwards bytes and keeps a ring buffer
  only. The app's Ghostty surface remains the single vt implementation:
  zero rendering fidelity risk (CJK, themes, selection all untouched), and the
  same "raw bytes, client-side vt" shape as the existing mobile data path.
- **sessionID = paneID.** Pane IDs are persisted in workspace snapshots
  (`TerminalTabSnapshot.paneID`), so relaunch restores panes with the same IDs
  and the shim re-attaches by identity. Explicit pane close = kill session;
  app quit = sessions survive (the app never enumerates views on terminate).
- **OSC passthrough is free.** cwd (OSC 7), notifications, command tracking
  (OSC 133), and progress travel in the byte stream, so most terminal metadata
  features need no change. Only foreground-PID queries move to a daemon RPC
  (`DaemonSessionMetadataStore`).
- **Shim spawn-on-demand.** The shim connects to the daemon socket; on failure
  it spawns `muxyd daemon` detached (setsid via posix_spawn) and retries.

### 3.2 Rejected: A1-full (daemon-provided PTY fds)

Would need changes inside ghostty's IO path; GhosttyKit is prebuilt, so
feasibility is uncontrollable. The shim achieves the same decoupling without
touching ghostty.

### 3.3 Rejected for now: A2 (daemon-owned Ghostty surfaces)

Blocked on an unverified precondition: Ghostty surfaces require a macOS NSView
(`GhosttyTerminalNSView.swift:132-150`). A UI-less daemon surface needs upstream
verification. Even then it requires a new cell-level rendering protocol plus a
custom cell renderer in the app — far more work and risk than A1-shim. A1-shim
does not close this door: the daemon already owns sessions and the byte stream,
so a vt layer can be added inside the daemon later.

### 3.4 Rejected: B1 (muxy as full herdr GUI client)

Model mismatch everywhere (muxy projects/worktrees/split-areas/VCS/extensions
vs herdr workspaces/tabs/panes), a custom cell renderer, no cell-level deltas,
strict `PROTOCOL_VERSION` equality against a fast-moving protocol, and herdr's
third-party governance. Would mean rewriting muxy on top of herdr.

### 3.5 B2 (herdr attach shim): calibration tool only

`herdr terminal attach` inside a muxy pane demonstrates the target UX today
with zero code. Not acceptable as a production dependency: double vt emulation
(fidelity risk), degraded terminal metadata features (fg process becomes the
attach client), `ctrl+b` escape conflicts, external binary distribution, and
third-party governance.

---

## 4. Comparison matrix

| Dimension | A1-shim (chosen) | A2 | B1 | B2 |
|---|---|---|---|---|
| Meets minimal loop | yes | yes (if headless works) | yes | yes |
| Technical risk | **low** (proven pattern) | high (unverified headless) | medium | low |
| Effort | medium (~2k LOC + tests) | large (renderer rewrite) | very large | tiny |
| Rendering fidelity | **lossless** (ghostty in place) | depends on new renderer | double vt + new renderer | double vt |
| Terminal metadata (agent status, cwd) | OSC passthrough + daemon sideband | rewiring needed | rewiring needed | degraded |
| Fits mobile data path | **same shape** (raw bytes + client vt) | conflicts | conflicts | same shape, uncontrollable |
| External dependency/governance | none | none | strong + moving target | strong |

## 5. Phase plan

- **P0 (zero code)**: use `herdr terminal attach` inside muxy to calibrate UX
  expectations for detach/reattach.
- **P1 (minimal closed loop — this branch)**: muxyd + shim + app-side launch
  command / restore changes + agent-status sideband. Acceptance: quitting the
  app does not kill agents; relaunch re-attaches all panes with the screen
  restored; `scripts/checks.sh` green plus new integration tests.
- **P2**: daemon takes over the CLI socket endpoint (`muxy` CLI talks to the
  daemon, no app required); evaluate moving the mobile remote server endpoint
  into the daemon.
- **P3**: verify Ghostty headless feasibility (decides A2); daemon FD-handoff
  live upgrade.

## 6. Open questions resolved in P1

1. Single `muxyd` binary with subcommands (`daemon` / `shim` / `list` / `kill`).
2. sessionID = paneID (simplest restore path; explicit close kills the session).
3. Ring buffer 1 MB per session; full replay on attach (resize-driven redraw
   handles full-screen apps).
4. Default behavior keeps sessions; **Settings → Terminal → Keep sessions alive
   after quit** controls it.
5. Repo docs are English (this file translated from the original Chinese draft).

---

## Appendix: evidence index

### muxy

- surface creation bound to NSView: `Muxy/Views/Terminal/GhosttyTerminalNSView.swift:132-150,203`
- global ghostty runtime main-actor singleton: `Muxy/Services/Terminal/GhosttyService.swift:8-16`
- pane→view registry: `Muxy/Services/Terminal/TerminalViewRegistry.swift:3-10`
- layout persistence (no session persistence): `Muxy/Models/Workspace/AppState.swift:109-114,130-188`
- no PTY cleanup on terminate: `Muxy/MuxyApp.swift:533-566`
- launch command injection point: `Muxy/Models/Workspace/TabArea.swift:26-27`, `Muxy/Services/Terminal/TerminalLaunchCommand.swift`
- mobile raw-bytes streaming: `Muxy/Services/Terminal/RemoteTerminalStreamer.swift:44-65`
- mobile snapshot (cell grid → ANSI): `Muxy/Services/Terminal/RemoteTerminalSnapshotBuilder.swift:5-88`
- single-owner takeover: `Muxy/Services/UIHosts/PaneOwnershipStore.swift:64-72`
- agent status reads foreground PID: `Muxy/Services/AI/AgentStatusStore.swift:94-105`
- embedded server lifecycle tied to app: `Muxy/Services/Mobile/MobileServerService.swift:98-150`
- GhosttyKit prebuilt: `GhosttyKit/module.modulemap`, `Package.swift:83-102`

### herdr

- wire protocol version: `src/protocol/wire.rs:16` (`PROTOCOL_VERSION: u32 = 18`)
- render encodings: `src/protocol/wire.rs:38-44` (SemanticFrame / TerminalAnsi)
- pane attach modes: `src/protocol/wire.rs:369,396,402`
- attach CLI: `src/cli.rs:509-517`, `src/client/mod.rs:837-845`
- JSON API methods: `src/api/schema.rs:43` onward (~80 methods)
- full report: `~/CliProject/herdr/.local/prd/external-gui-client-feasibility.md`
