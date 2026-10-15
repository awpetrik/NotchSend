# Phase 0 Results - NotchSend Protocol Spike

| Field | Value |
|---|---|
| Date | 2026-10-13 |
| Code | `~/workspace/localsend-notch/notchsend/` (also copied to `~/notchsend` on the Mac) |
| Daemon under test | `notchsendd` 0.1.0 on MacBook Air (macOS 27.0.1, arm64), port 53317 |
| Peer under test | Official LocalSend app, Android (Poco, alias "Bright Lettuce", protocol 2.2) |
| Verdict | Phase 0 passed with two recorded gaps (see §3) |

## 1. Loopback self-test (VM, two daemon instances)

`tools/selftest.sh` passed 3 consecutive runs (including one independent
re-run by the reviewing agent):

- Accept path: 1.5 MB random file transferred, SHA-256 identical,
  progress events and `session_completed` observed.
- Reject path: sender received a structured `declined` result, no file
  written.
- Timeout path: no approval within 5 s produced `request_expired`,
  no file written.

## 2. Live interop test (real phone, real Mac, 2026-10-13 ~16:21–16:25 WIB)

Setup facts established along the way:

- The official LocalSend app was running on the Mac and held TCP 53317;
  the spike daemon failed its first bind with "Address already in use"
  (the blueprint §11 case, reproduced in the field on day one). The app
  was quit with the owner's approval, the daemon was restarted, and it
  bound 53317 cleanly. The spike daemon does not yet retry a failed
  initial bind; this is Phase 1 hardening work.
- macOS did not present a Local Network or firewall prompt for the
  SSH-launched daemon during this test, and discovery worked in both
  directions immediately (the phone appeared in the daemon's peer
  registry; the daemon appeared on the phone as "Rivaldi's MacBook Air").

Results:

| Case | Result | Evidence |
|---|---|---|
| Discovery, both directions | PASS | `peer_found` event for the phone; daemon selectable on the phone |
| Receive 1 photo (1,953,601 B) with manual approval from the terminal | PASS | Request held at the approval gate, accepted via `notchsendctl accept`; progress 5% → 100%; `session_completed`; landed file SHA-256 `6f7af80a…` identical to the hash announced in the file metadata |
| Send 2 files in one session (118 B text + 5 MiB random) | PASS | `session_completed`, SEND OK; 5 MiB file SHA-256 `d6a08126…` as prepared |
| Send rejected on the phone | PASS | After two sends that the phone accepted, a third send was declined on the phone; daemon reported `session_failed` with structured error `declined` ("peer declined the transfer") instead of hanging |
| Approval timeout against the real phone | Not run | Covered by loopback test; running it live would park the owner's phone UI for the timeout duration |

## 3. Gaps against the blueprint's Phase 0 exit criteria

1. The receive test used a single photo, not the specified 3-file batch
   (photo + PDF + large video) in one session. Multi-file sessions are
   proven in the send direction against the real app, and the receive
   session code accepts a file map, but the exact batch shape is
   unverified.
2. No file larger than 5 MiB was transferred; the >500 MB case is
   unverified. Nothing in the protocol path is size-dependent (upload is
   a single streamed body, progress is byte-counted), but per this
   project's standard, unverified means unverified.

Both gaps are cheap to close in one short follow-up session and do not
block Phase 1 design work; they remain open checklist items, not
assumptions.

## 4. Spike compromises (carried from the build report)

- `http-body-util` pinned to the 0.1 line (VM registry mirror).
- RSA-2048 key generated via the `rsa` crate and fed to rcgen (rcgen has
  no RSA keygen); the resulting identity matches the reference shape.
- Any connected IPC client may approve/reject in the spike; the
  single-authority rule is Phase 1.
- No 429 rate limiting and no receive-session TTL yet; a session that is
  accepted but never uploaded holds the single session slot.
- Progress events do not yet carry `bytes_per_sec` (blueprint §4.5).
- `.part` files are written beside the final file rather than in a
  staging subfolder.

## 5. State after the test

The spike daemon was left running on the Mac (with a `watch` control
client attached) and the official LocalSend app left closed, pending the
owner's word on which receiver should own port 53317 day to day.
