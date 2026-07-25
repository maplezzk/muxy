# Daemon Sessions

Muxy keeps terminal sessions alive after the app quits. Agents and shells
running in panes are not killed when you close Muxy, and every pane re-attaches
to its original session — with its screen contents restored — on the next
launch.

Enabled by default. Toggle in **Settings → General → Terminal → Keep sessions
alive after quit** (`muxy.terminal.daemonSessions`).

## How it works

Each pane runs a small shim process (`muxyd shim <pane-id>`) instead of talking
to a shell directly. The shim forwards bytes between the pane and `muxyd`, a
background daemon that owns the real PTY and the shell or agent inside it.

- **Quit Muxy** → the shims exit, but `muxyd` and all sessions keep running.
- **Relaunch Muxy** → each pane spawns its shim again, which re-attaches to the
  same session (pane IDs are persisted) and replays the scrollback buffer.
- **Close a pane explicitly** → the session is killed, same as before.

The daemon starts on demand: the first shim that cannot reach it spawns it
detached. It exits on its own after a minute with no sessions and no clients.

## Notes and limits

- Scrollback replay is capped at 1 MB per session. Full-screen apps (vim, htop)
  redraw on the resize that follows a re-attach.
- SSH remote panes are not daemon-backed in this phase; only local panes.
- If the daemon itself crashes, its sessions are lost (the app falls back to
  starting fresh shells on next launch).
- The `muxyd` binary lives inside the app bundle (`Contents/MacOS/muxyd`) and
  can be used directly for debugging:

```bash
muxyd list            # list live sessions
muxyd kill <uuid>     # terminate a session
```

- Socket and log live in `~/Library/Application Support/Muxy/muxyd.sock` and
  `muxyd.log`. Override with `MUXYD_SOCKET_PATH` / `MUXYD_LOG_PATH` (and point
  the app at a custom binary with `MUXYD_BINARY_PATH`).

Design rationale and rejected alternatives:
[pty-daemon-decoupling](../architecture/pty-daemon-decoupling.md).
