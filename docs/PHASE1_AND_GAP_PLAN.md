# Phase 1 Readiness & Gap-Closure Plan - NotchSend

| Field | Value |
|---|---|
| Date | 2026-10-13 (evening) |
| Status | Prepared, awaiting owner lock - no code written |
| Basis | `BLUEPRINT.md` §8/§14 Phase 1 + §16 D1–D5; `PHASE0_RESULTS.md` §3–§4; notch app built & running 2026-10-13 |

## 1. Why this is next, and why the order changed

The blueprint sequenced Phase 1 (daemon hardening) before Phase 2 (notch
UI). In practice the notch app was built first (2026-10-13, installed at
`~/Applications/NotchSend.app` on the Mac, geometry verified 0.0 offset).
That leaves the system in an asymmetric state:

- The UI is a real installed app; the daemon underneath it is still the
  Phase 0 spike, started manually from an SSH session.
- The spike daemon is the component that owns TCP 53317. The official
  LocalSend app was quit during Phase 0 testing and remains closed.
- The spike has **no LaunchAgent packaging** (verified 2026-10-13: no
  launchd references in `app/` or `notchsend/`), **no retry of a failed
  initial bind** (reproduced in the field on day one, when the official
  app held the port), and no single-instance lock.

Consequence: a Mac reboot, a daemon crash, or the SSH-launched process
being cleaned up silently removes the machine's only LocalSend receiver.
Nothing announces the loss; senders simply stop seeing the Mac. This is
the highest-priority gap - ahead of feature completeness - because the
project has already replaced the owner's working receiver.

## 2. Work blocks, in priority order

### A. Survivability (daily-use blockers)

1. LaunchAgent packaging per blueprint §8: per-user agent, plist in
   `~/Library/LaunchAgents/` (or `SMAppService.agent` registration from
   the app), start at login, restart on crash.
2. Bind retry with backoff on 53317 instead of failing once and staying
   half-up (HTTPS down, discovery up - the exact field failure).
3. Single-instance lock so a second daemon cannot start against the
   same socket/identity.
4. Config file (alias, download dir, approval timeout, auto-accept)
   replacing spike hard-codes; log rotation so a 24-hour soak and daily
   use do not grow unbounded logs.

Exit check for this block alone: reboot the Mac, log in, send one file
from the phone with no SSH session involved - the notch app approves and
the file lands intact.

### B. Session safety

1. Receive-session TTL: an accepted-but-never-uploaded session must
   release the single session slot (spike compromise, `PHASE0_RESULTS.md`
   §4).
2. `.part` files move to a staging subfolder; an interrupted transfer
   must never leave a corrupt file under its final name (blueprint
   Phase 1 exit criterion: kill -9 mid-transfer, slot recovers).
3. Single-authority IPC approval: in the spike, any connected IPC client
   may approve/reject. Restrict approval authority to the notch app /
   owner control client.
4. Approval timeout locked at the D5 value (see §4), enforced by the
   daemon, not by whichever client happens to be connected.

### C. Protocol completeness

1. PIN support in both directions - this is also what unblocks the M09
   PIN view in the notch app, which is currently built but unconnected
   because the spike daemon does not support PIN re-entry.
2. 429 rate limiting on the receive endpoints (spike compromise).
3. `bytes_per_sec` in progress events (blueprint §4.5), so the expanded
   notch cards can show real transfer speed instead of only percent.

### D. Phase 0 gap closure (one short session, phone + Mac together)

Still unverified from `PHASE0_RESULTS.md` §3 - cheap to close together:

1. Receive a 3-file batch (photo + PDF + large video) in one session
   from the official Android app.
2. Receive one file >500 MB; verify SHA-256 of the landed file against
   the phone-announced hash.
3. In the same session, the already-pending owner test: approve from
   the notch UI itself (not the terminal).

## 3. What this plan deliberately does not do

- No daemon changes, no packaging, and no LaunchAgent install happen
  before the owner's lock - per the owner's standing rule that
  execution waits for approval.
- The 24-hour soak and full interop matrix remain Phase 1 exit criteria
  (blueprint §14); block A–C completion is not "Phase 1 done".

## 4. Decisions needed - one lock covers all five

Blueprint §16 defaults were written before the app existed; all five
still fit the current state. Recommendation: adopt all defaults as-is.

| # | Decision | Recommended lock |
|---|---|---|
| D1 | Name | `notchsend` / NotchSend, descriptive subtitle only |
| D2 | UI not running | Immediate decline; `auto_accept` stays opt-in (now a real case: quitting the notch app must not silently hold or accept transfers) |
| D3 | Trusted peers | Data model reserved; policy deferred until after the receive flow is hardened |
| D4 | Download dir | `~/Downloads` (matches official app expectation; current spike behaviour) |
| D5 | Approval timeout | 60 s |

## 5. Suggested execution order once locked

A (survivability) → D (gap closure, needs one owner session anyway) →
B (session safety) → C (protocol completeness) → 24-hour soak →
Phase 1 exit check. Block A is the only block whose absence can lose
the owner a transfer before he notices anything is wrong.
