# NotchSend

LocalSend on macOS, answered from the MacBook notch instead of a window.

The official LocalSend app handles transfers inside its own window.
NotchSend splits the job into two processes:

- `notchsendd`, a Rust daemon, owns the LocalSend v2.2 protocol:
  discovery, the HTTPS endpoints, and all transfer state.
- A Swift app draws one panel anchored to the physical notch. Incoming
  requests, progress, peer picking, and results all happen there.

The two talk over NDJSON on a Unix socket with 0600 permissions. Only
the daemon holds state, so if the notch app quits or crashes, the
receiver keeps running. The trade-off runs the other way too: with no
UI connected, an incoming request is declined immediately rather than
held or silently accepted. An `--auto-accept` flag exists on the
daemon and is off by default.

## Requirements

- A Mac with a notch. The panel geometry is measured from the physical
  notch rect at runtime, so there is little for the app to draw on a
  display without one. macOS 14 or later; the app build targets
  `arm64-apple-macosx14.0`.
- No Xcode. The app compiles with `swiftc` from the Command Line Tools.
- A Rust toolchain for the daemon and the CLI.
- The official LocalSend app must not be running on the Mac. Both
  programs want TCP 53317, and they cannot share it.

## Build and run

Daemon and tools (any machine with a Rust toolchain):

```sh
cd daemon
cargo build --release
```

Notch app (on the Mac):

```sh
cd app
./build.sh            # produces ./build/NotchSend.app
```

There is also a helper for running the daemon on the Mac. It builds
the release binaries, refuses to start while port 53317 is taken,
starts the daemon in the background, and prints the control commands:

```sh
cd daemon
tools/run-on-mac.sh start    # also: stop, status, watch
```

Received files land in `~/Downloads` by default, and daemon state
lives in `~/.notchsend`. These are the flags `notchsendd` takes:

| Flag | Default |
|---|---|
| `--alias NAME` | `NotchSend` |
| `--port N` | `53317` |
| `--download-dir DIR` | `~/Downloads` |
| `--data-dir DIR` | `~/.notchsend` |
| `--socket-path PATH` | `<data-dir>/daemon.sock` |
| `--approval-timeout-secs N` | `60` |
| `--pin PIN` | none |
| `--auto-accept` | off |

`notchsendctl` is the terminal client for the same socket. It has
`status`, `peers`, `watch`, `accept <request_id>`,
`reject <request_id>`, `cancel <session_id>`, `rescan`, and
`send --to <ip:port> <paths...>` subcommands.

## Development

```sh
cd daemon
tools/selftest.sh
```

That builds the workspace and runs a loopback self-test between two
daemon instances: an accepted transfer (SHA-256 of the landed file
matches), a rejected transfer (nothing is written), and an approval
timeout (the request expires). Live interop against the official
Android app was done by hand on 2026-10-13 and passed for discovery in
both directions, one received photo, two files sent in one session,
and a reject on the phone side. Full record: `docs/PHASE0_RESULTS.md`.

## Project layout

- `daemon/` - Rust workspace: `crates/protocol`, `crates/core`,
  `crates/daemon` (binary `notchsendd`), `tools/notchsendctl`, and the
  self-test and Mac helper scripts.
- `app/` - Swift notch app: sources, `Info.plist`, `build.sh`.
- `mockups/` - the 16 approved UI states (M01-M16) on one HTML page.
- `docs/` - `BLUEPRINT.md` (architecture, IPC specification, security
  notes, phase plan), the Phase 0 reports, the Phase 1 gap plan, and
  the DynamicNotch v1.6.3 scheme extraction.

## Known issues and gaps

- There is no LaunchAgent packaging yet, so the daemon is started by
  hand. A reboot or a crash takes the receiver down, and nothing
  announces the loss; senders just stop seeing the Mac. Closing this is
  the first item in `docs/PHASE1_AND_GAP_PLAN.md`.
- If the port is already taken when the daemon starts, the bind fails
  once and the daemon stays half up. It does not retry yet.
- Any client connected to the control socket can approve or reject an
  incoming request. Restricting approvals to the notch app is Phase 1
  work. The socket is 0600, so only local processes can reach it.
- No HTTP 429 rate limiting and no receive-session TTL yet. A session
  that gets approved but never uploads holds the single transfer slot.
- Receiving is verified live for one file at a time. A 3-file batch
  received in one session is still untested, and the largest file
  transferred so far is 5 MiB. The planned check is one batch plus one
  file over 500 MB.
- The PIN entry screen in the app (M09) is drawn but not wired up; the
  daemon does not do PIN re-entry yet.
- Progress events carry percent and byte counts, no transfer speed.

## License

Not settled for the repository as a whole. The Rust workspace declares
MIT in its `Cargo.toml`. The Swift app takes its notch shape, drawing,
and animation from DynamicNotch v1.6.3
(https://github.com/jackson-storm/dynamicnotch), which is GPL-3.0. One
deviation is deliberate (home panel width and expanded corner radii)
and is recorded in `docs/DYNAMICNOTCH_163_SCHEME.md` section 9. The
owner picks the repository licence before any public release.
