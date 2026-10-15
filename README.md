# NotchSend

LocalSend transfers for macOS, driven from the MacBook notch.

NotchSend splits LocalSend into two processes:

- `notchsendd`, a Rust daemon that owns the LocalSend v2.2 protocol,
  discovery, and all transfer state. It is meant to run always-on as a
  per-user LaunchAgent.
- A Swift notch app that is only the UI: incoming-transfer confirmation,
  progress, peer picking, and results all render in a panel anchored to
  the physical notch. The app talks to the daemon over NDJSON on a Unix
  socket with 0600 permissions. If the UI quits or crashes, the receiver
  keeps running.

## Status

Work in progress, developed and tested on the owner's MacBook Air and
Android phone.

- Phase 0 spike: done. The Rust workspace builds clean, its loopback
  self-test passes (accept, reject, and approval-timeout paths), and live
  interop against the official LocalSend Android app passed on
  2026-10-13: discovery both ways, receiving a photo with a matching
  SHA-256, sending two files in one session, and a phone-side reject.
  Details in `docs/PHASE0_RESULTS.md`.
- Notch app: built and running. It is compiled with `swiftc` from the
  Command Line Tools (the Mac has no Xcode). Its drawing, layout, and
  animation follow the DynamicNotch v1.6.3 scheme, with one documented
  owner-directed deviation (home panel width and expanded corner radii);
  the panel is anchored to the measured physical notch rect with zero
  center and top offset. Details and the deviation record are in
  `docs/DYNAMICNOTCH_163_SCHEME.md` section 9.
- Not done yet: Phase 1 daemon hardening and LaunchAgent packaging,
  receive-side tests with a 3-file batch and files over 500 MB, and an
  owner-driven end-to-end test through the notch UI against a phone.
  Open decisions and the phase plan are in `docs/BLUEPRINT.md` and
  `docs/PHASE1_AND_GAP_PLAN.md`.

## Layout

- `daemon/` - Rust workspace: `crates/protocol`, `crates/core`,
  `crates/daemon` (binary `notchsendd`), `tools/notchsendctl` (CLI
  client for the control socket), plus self-test scripts.
- `app/` - Swift notch app sources, `Info.plist`, and `build.sh`.
- `mockups/` - the 16 approved UI states (M01-M16) as one HTML page.
- `docs/` - `BLUEPRINT.md` (architecture, IPC specification, security
  notes, phase plan), the Phase 0 result reports, and the DynamicNotch
  v1.6.3 scheme extraction.

## Build

Daemon and tools (any machine with a Rust toolchain):

```sh
cd daemon
cargo build --release
```

Notch app (Mac with Command Line Tools only):

```sh
cd app
./build.sh
```

## License note

The Rust workspace declares MIT in its `Cargo.toml`. The Swift notch
app adapts its notch shape and its drawing and animation scheme from
DynamicNotch (https://github.com/jackson-storm/dynamicnotch), which is
GPL-3.0. The licence for this repository as a whole has not been chosen
yet; the owner settles it before any public release.
