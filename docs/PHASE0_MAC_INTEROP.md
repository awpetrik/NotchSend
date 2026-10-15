# Phase 0 - Mac ↔ Phone Interop Runbook

Status: prepared 2026-10-13. VM side is DONE (build clean, loopback self-test
passed 3× incl. one independent re-run). This runbook is the only remaining
piece of Phase 0: the exit criteria in BLUEPRINT.md §14 against the
**unmodified official LocalSend app on the owner's Android phone**.

Why it was blocked: SSH from the VM to the Mac failed twice on 2026-10-13
(~15:49 and ~16:02 WIB) with `proxy closed connection during CONNECT`,
before any TCP connection reached the Mac (Mac asleep or Tailscale inactive
on it; the SSH configuration itself was not changed and last worked
normally). Note: the Muse device session for the Mac reported the Mac as
last seen 2026-10-13T09:07:20Z (16:07 WIB), i.e. the Mac was awake by then,
retry SSH first; if it connects, steps 1–3 below can be driven from the VM
and only the phone taps remain the owner's.

## Exit criteria being closed (BLUEPRINT.md §14, Phase 0)

1. Official app on the phone sends a 3-file batch (photo, PDF, >500 MB
   video) to the daemon; files arrive intact (SHA-256 match).
2. Reject path verified (sender sees declined, no file lands).
3. Timeout path verified (no answer → request expires, no file lands).
4. Daemon sends a file back to the phone; the phone accepts it.
5. Local Network permission prompt behaviour recorded (prompt appears
   exactly once; discovery survives a deny → allow change).

## Step 0 - Prereqs on the Mac

- Mac and phone on the **same home Wi-Fi/LAN** (the VM is not on that LAN;
  the daemon must run on the Mac).
- Official LocalSend app on the Mac **quit** - it and the daemon both want
  port 53317 (BLUEPRINT §8 / mockup M16). The phone app stays as-is.
- Rust toolchain on the Mac: `cargo --version`. If missing, install via
  rustup (`https://rustup.rs`, default stable) - owner's hands, one time.
- Test files ready on the phone: one photo, one PDF, one video > 500 MB.

## Step 1 - Get the source onto the Mac

The workspace lives on the VM at `~/workspace/localsend-notch/notchsend/`
and is **not pushed to any git remote**. Once SSH to the Mac works again,
copy it from the VM (example target `~/notchsend` on the Mac):

```bash
# from the VM, via the existing tailscale-ssh wrapper
~/workspace/bin/mac-ssh "mkdir -p ~/notchsend"
# then rsync/scp the notchsend/ directory contents to ~/notchsend/
# (exclude target/ - it is a Linux build and ~large; the Mac builds its own)
```

## Step 2 - Build + start the daemon (on the Mac)

```bash
cd ~/notchsend
bash tools/run-on-mac.sh start
```

The script does the preflight (cargo present, TCP 53317 free, warns if a
LocalSend process is running), builds release binaries, starts `notchsendd`
in the background (alias `NotchSend`, downloads → `~/Downloads`, identity +
socket in `~/.notchsend/`, log → `~/.notchsend/daemon.log`), and prints
`notchsendctl status` (alias, fingerprint, port).

Defaults verified from `crates/daemon/src/main.rs`: port 53317, approval
timeout 60 s, auto-accept OFF, persistent identity in the data dir
(fingerprint = SHA-256 of the cert DER - stable across restarts).

Watch events in a second terminal:

```bash
bash tools/run-on-mac.sh watch
```

## Step 3 - Receive test (phone → Mac), criterion 1

1. On the phone's official LocalSend app, select the 3 files (photo, PDF,
   >500 MB video) and send to **NotchSend**.
2. The `watch` terminal shows the incoming request with a `request_id`;
   the phone stays blocked waiting - that is the approval gate working.
3. Accept: `~/notchsend/target/release/notchsendctl --socket ~/.notchsend/daemon.sock accept <request_id>`
4. Evidence to capture:
   - `watch` shows progress events and `session_completed`.
   - Files land in `~/Downloads` (no leftover `.part` files).
   - `ls -l` sizes match the phone's reported sizes exactly.
   - `shasum -a 256 <file>` for each file - record the values; the daemon
     verifies size/SHA-256 from the transfer metadata during upload, and
     the recorded hashes are the reference for any later re-check.
   - The video plays / the photo and PDF open.
5. Local Network prompt (criterion 5): note whether macOS showed the Local
   Network permission prompt for the daemon process, and whether it
   appeared once only. If it was denied earlier: System Settings →
   Privacy & Security → Local Network → allow, then confirm discovery
   still works without restarting the daemon (or note that a restart was
   needed - either outcome is a valid recording, it just has to be known).

## Step 4 - Reject test (criterion 2)

Phone sends any small file → in `watch`, note the `request_id` →
`notchsendctl ... reject <request_id>`. Expected: phone shows the transfer
declined; nothing new in `~/Downloads`.

## Step 5 - Timeout test (criterion 3)

Phone sends any small file → do nothing. Expected: after ~60 s the request
expires (`request_expired` in `watch`), the phone reports failure, no file
lands.

## Step 6 - Send-back test (Mac → phone), criterion 4

1. `bash tools/run-on-mac.sh status` → `peers` lists the phone
   (ip:port + fingerprint).
2. Send the received PDF back:
   `notchsendctl --socket ~/.notchsend/daemon.sock send --to <phone_ip:53317> --fingerprint <phone_fingerprint> ~/Downloads/<pdf>`
3. Owner taps **Accept** in the official app on the phone. Expected: CLI
   prints progress then `SEND OK`; the file is intact on the phone.

## Step 7 - Wrap up

```bash
bash tools/run-on-mac.sh stop
```

Record the results against criteria 1–5 (pass/fail + the evidence above).
All five passing closes Phase 0 officially; Phase 1 (hardening:
LaunchAgent packaging, single-instance lock, PIN both directions,
authority-client tightening of the IPC accept path, 429 rate limit,
receive-session TTL, `bytes_per_sec` in progress events) starts only on
the owner's go.

## Known spike compromises carried into this test (from the Phase 0 report)

- Any connected IPC client may accept/reject (authority-client rule is
  Phase 1). Fine on the owner's own Mac for this test.
- No 429 rate-limit and no receive-session TTL yet.
- Progress events lack `bytes_per_sec` (irrelevant to interop verdicts).
- `http-body-util` pinned to 0.1 by the VM registry mirror; the Mac build
  uses the same Cargo.lock, so behaviour matches the self-tested build.
