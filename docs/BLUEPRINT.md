# Blueprint - LocalSend Notch for macOS

**Subtitle:** LocalSend daemon in Rust (separate process) with all send/receive
confirmation and progress presented from the MacBook notch, using a fork of
DynamicNotch as the Swift UI layer.

| Field | Value |
|---|---|
| Document status | Approved - mockups M01–M16 approved by owner 2026-10-13 without corrections; Phase 0 awaits an explicit go |
| Version | 1.0 (2026-10-13) |
| Owner | Rivaldi |
| Target machine | MacBook Air M2 (Mac14,2, physical notch), macOS 26 |
| Upstream references | `localsend/localsend` + `localsend/protocol` v2.2, `jackson-storm/dynamicnotch` |
| Working name | `notchsend` (daemon binary: `notchsendd`) - open decision D1 |

---

## 1. Purpose and scope

### 1.1 Problem

The official LocalSend app must stay open as a foreground application to
receive files. Receiving requires switching to its window to accept a
transfer, and transfer progress lives inside that window. On a Mac with a
notch, none of that interaction needs a window at all.

### 1.2 Goal

A system in which:

1. A background daemon is always discoverable as a LocalSend receiver on the
   LAN, whether or not any UI is running.
2. Every interactive decision - accept/reject an incoming transfer, pick a
   peer to send to, cancel a running transfer - happens in the notch.
3. Every transfer state - pending, in progress (with progress bar, byte
   counts, rate), completed, failed - is presented from the notch.
4. Interoperability with unmodified official LocalSend clients (Android,
   iOS, Windows, Linux, macOS) is preserved.

### 1.3 Non-goals (v1)

- Web Send / browser share (the download API, `prepare-download` + `GET /`).
- Internet / WebRTC transfer (LocalSend v3 draft territory).
- Receiving while the Mac is asleep or the user is logged out.
- Replacing the official app's history, favorites, and settings surface.
  Settings are minimal and live in the fork's existing settings UI.
- Support for Macs without a notch (floating-island fallback is a later
  phase, reusing DynamicNotch behaviour where it already exists).

---

## 2. Architecture decision summary

| # | Decision | Rationale |
|---|---|---|
| A1 | Two processes: a Rust daemon and a Swift notch app. | Daemon lifetime must not depend on UI lifetime; a UI crash must never take the receiver with it, and vice versa. |
| A2 | The daemon is written in Rust, implementing LocalSend protocol v2.2 directly. | Upstream LocalSend's own core is Rust (Tokio / Hyper / Reqwest / Rustls) with an explicit approval-before-upload server design and streamed, progress-reporting saves. The protocol logic is therefore written against a reference that already exists in the same language. |
| A3 | The notch UI is a fork of DynamicNotch with one new feature module; the fork's engine, coordinator, and settings are reused, not rewritten. | DynamicNotch already provides the notch window, a queue-driven presentation engine (`NotchEngine`), event routing (`NotchEventCoordinator`), a content registry, and analogous features (Download, AirDrop handoff, Drag & Drop). |
| A4 | Daemon and UI communicate over a Unix domain socket using newline-delimited JSON (NDJSON). | Local-only, no open port, permission is the filesystem permission on the socket (0600) plus peer-UID verification. Messages are human-inspectable during development (`socat` / a debug CLI can stand in for the UI). |
| A5 | The daemon is the single owner of all protocol and transfer state. The UI is a stateless projector of daemon state. | There is exactly one source of truth. The UI can disconnect, crash, and reconnect, then resynchronise from a single `snapshot` message. |
| A6 | The daemon runs as a per-user LaunchAgent, not a root LaunchDaemon. | It needs the user's `~/Downloads`, Keychain-free credential files, and socket directory; it must not run with privileges it does not need. |
| A7 | The TLS identity (self-signed certificate and key) is generated once and persisted. | The LocalSend fingerprint is the uppercase hex SHA-256 of the certificate DER. Regenerating it on every start makes the Mac appear as a new device to every peer. |
| A8 | Exactly one transfer session is active at a time. Additional incoming requests are rejected `409`; outgoing requests are queued by the daemon and surfaced in the notch. | Matches the protocol's session model and the reference behaviour; queueing policy belongs to the state owner (the daemon), not the UI. |

Rejected alternatives are recorded in §13.

---

## 3. System overview

```
                        LAN
                         │
        ┌────────────────┼─────────────────────┐
        │  Official LocalSend peers (phone, PC) │
        └────────────────┬─────────────────────┘
                         │  LocalSend v2.2
                         │  UDP multicast 224.0.0.167:53317 (discovery)
                         │  HTTPS 53317, mutual TLS (transfer)
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  notchsendd - Rust daemon (LaunchAgent, always on)           │
│                                                              │
│  discovery ── https server ── session manager ── file writer │
│       │             │               │                │       │
│  peer registry   prepare-upload  approval gate   .part files │
│                  upload/cancel   progress events  sha256     │
│                                     │                        │
│                              control server (Unix socket)    │
└──────────────────────────────────┬───────────────────────────┘
                                   │ NDJSON over Unix socket
                                   │ ~/Library/Application Support/
                                   │   NotchSend/daemon.sock (0600)
                                   ▼
┌──────────────────────────────────────────────────────────────┐
│  DynamicNotch fork - Swift app (menu-bar agent)              │
│                                                              │
│  DaemonClient ──► LocalSendEventHandler ──► NotchEngine      │
│        ▲                (NotchEventCoordinator)     │          │
│        │                                            ▼          │
│  LocalSendViewModel ──► Minimal / Expanded / Peer-picker     │
│                         notch views                          │
│  Drag & Drop overlay ──► send command ──► (back to daemon)   │
└──────────────────────────────────────────────────────────────┘
```

Trust boundaries:

- **LAN boundary** - crossed by the LocalSend protocol. Peers are
  unauthenticated by default; optional PIN and fingerprint pinning apply
  (see §10).
- **Local IPC boundary** - crossed only by processes running as the same
  user. Enforced by socket file permissions and `getpeereid` UID check.
- There is no third boundary: the UI holds no credentials and no protocol
  state, so compromising the UI yields no more than the user already has.

---

## 4. Component design - Rust daemon (`notchsendd`)

### 4.1 Workspace layout

```
notchsend/
├── Cargo.toml                 # workspace
├── crates/
│   ├── protocol/              # DTOs and constants for LocalSend v2.2 only.
│   │                          # No I/O. Serde models for MulticastDto,
│   │                          # RegisterDto, InfoDto, FileDto,
│   │                          # PrepareUploadRequest/Response.
│   ├── core/                  # Transfer engine: discovery, HTTPS server and
│   │                          # client, session manager, file writer/reader.
│   │                          # Emits typed events; knows nothing about
│   │                          # sockets, notch, or JSON IPC.
│   └── daemon/                # Binary crate: config, control server
│                              # (Unix socket), logging, signal handling,
│                              # launchd integration. Wires core to IPC.
└── tools/
    └── notchsendctl/          # Debug/CLI client for the control socket.
                               # Doubles as the Phase 0 test harness: it can
                               # accept, reject, send, and print progress
                               # without any Swift existing yet.
```

The `core`/`daemon` split exists for one reason: every protocol behaviour
must be testable from `notchsendctl` and from Rust integration tests before
any Swift is written.

### 4.2 Crate selection

| Concern | Crate | Note |
|---|---|---|
| Async runtime | `tokio` (multi-thread) | Same runtime as upstream core. |
| HTTPS server | `hyper` 1.x + `tokio-rustls` | Server must request a client certificate (mutual TLS): in HTTPS mode the sender's fingerprint is derived from its client certificate, and the JSON `fingerprint` field is ignored. |
| HTTPS client | `reqwest` with `rustls-tls` and a custom certificate verifier | The verifier pins the peer certificate to the fingerprint learned during discovery instead of doing hostname/CA verification. |
| Certificates | `rcgen` + `rustls-pki-types` | One RSA-2048 self-signed certificate, `CN=LocalSend User`, no expiry, generated on first run and persisted (§9). |
| Multicast | `socket2` + `tokio::net::UdpSocket` | Join `224.0.0.167` on every active IPv4 interface; `SO_REUSEADDR`/reuse-port behaviour matched to the reference so the daemon can coexist with discovery probes during development. |
| Serialisation | `serde` / `serde_json` | Protocol DTOs and IPC messages share derives but live in separate modules; wire formats must never leak into each other. |
| Hashing | `sha2` | File SHA-256 verification and fingerprint derivation. |
| Config | `serde` + `toml` | One config file (§9). |
| Logging | `tracing` + `tracing-subscriber` | Structured logs to file (§8.4); `RUST_LOG`-style filter via env for development. |

Versions are pinned in `Cargo.lock` at implementation time; this blueprint
intentionally does not pin patch versions.

### 4.3 Protocol implementation scope

**Discovery**

- Announce on start and respond to announcements: multicast JSON with
  `announce: true/false`, containing alias, version, device model/type,
  fingerprint, port, and protocol.
- Answer peer announcements additionally with `POST /api/localsend/v2/register`
  to the announcer (UDP reply as fallback), mirroring the reference flow.
- Maintain a peer registry keyed by fingerprint, with last-seen timestamps
  and a TTL (default 60 s, entry is stale after two missed announce cycles).
- Ignore own announcements (fingerprint equality).
- HTTP subnet-scan fallback is **out of scope for v1**; multicast plus
  register fallback covers the home/office LAN case. Recorded as a known
  limitation (§12).

**Receive path (upload API)**

| Endpoint | Behaviour |
|---|---|
| `GET /api/localsend/v2/info` | Returns alias, version, device model/type, fingerprint, `download: false`. |
| `POST /api/localsend/v2/register` | Registers/refreshes a peer; returns local device info. |
| `POST /api/localsend/v2/prepare-upload` | Validates PIN (401), validates body (400), checks session slot (409 if busy), then **suspends the response** pending the approval gate (§4.4). On accept: creates a session, returns `sessionId` and one random token per accepted file. Files may be partially accepted. On reject: 403. |
| `POST /api/localsend/v2/upload?sessionId&fileId&token` | Validates session, token, and that the source IP matches the `prepare-upload` IP (403 otherwise). Streams the body to a `.part` file while emitting progress; verifies byte count and, if metadata carried `sha256`, the digest (422 on mismatch). Atomically renames `.part` to the final collision-safe name on success. |
| `POST /api/localsend/v2/cancel?sessionId` | Aborts the session, deletes `.part` files, emits a cancelled event. |

Filenames are sanitised before touching disk: strip path components, reject
absolute paths and traversal, and resolve collisions by numeric suffix
(`file (1).ext`), never by overwrite.

**Send path**

1. Resolve target from the peer registry (or accept an explicit address
   from the UI for a peer that has not announced yet).
2. `POST prepare-upload` with file metadata (UUID per file, name, size,
   MIME type, SHA-256 computed while streaming the first pass - see the
   note below), presenting the daemon's own certificate as client identity.
3. On 200, upload each file as a single streamed request. Concurrency 2,
   matching the official app. Progress is counted from bytes written to the
   TLS stream.
4. On cancel from the UI, abort in-flight requests and send `cancel`.

Note on hashing outgoing files: computing SHA-256 requires one read pass.
The daemon hashes while uploading is not possible (the hash must be known
before `prepare-upload`), so sending a large file costs one pre-pass read.
This is local disk I/O on an SSD and is reported to the UI as a brief
`preparing` state, not hidden.

### 4.4 Session state machine and the approval gate

The approval gate is the heart of the design and exists because
`prepare-upload` semantics allow it: the sender waits for the response
while the receiver decides.

```
                 prepare-upload
   IDLE ─────────────────────────► PENDING_APPROVAL
                                        │          │
                              accept ───┘          └─── reject / timeout
                                ▼                             │
                          RECEIVING ◄── upload (per file)     ▼
                                │                        IDLE (403 sent)
                 all files done │  cancel / error / peer disconnect
                                ▼          │
                             COMPLETED     ▼
                                        FAILED ──► IDLE
```

Rules:

- `PENDING_APPROVAL` holds the HTTP response open. It emits exactly one
  `incoming_request` IPC event (§5).
- Approval timeout: default **60 s**, configurable. On expiry the daemon
  rejects with 403 and emits `request_expired`. The timeout must stay well
  below sender-side timeouts so the sender shows "declined", not a hang.
- If **no UI client is connected** to the control socket, incoming requests
  are rejected immediately with 403. Rationale: parking a sender for 60 s
  when nobody can answer is strictly worse than an immediate decline, and
  silently auto-accepting is a security regression. An explicit
  `auto_accept` config option (default off) overrides this for users who
  want a pure drop-box; see decision D2.
- Each file transitions `queued → transferring → verifying → done|failed`
  independently; the session completes when all files are terminal.
- All state transitions are emitted as IPC events in order, with a
  monotonically increasing daemon-side sequence number so the UI can detect
  gaps after a reconnect and request a fresh `snapshot`.

### 4.5 Progress reporting

- Granularity: per file and per session (aggregate bytes / total bytes).
- Throttling: at most one progress event per file per **100 ms**, or on a
  1 %-of-file delta, whichever comes later; a final 100 % event always
  fires. This bounds IPC and SwiftUI re-render load on multi-GB transfers
  without visible bar stutter.
- Each progress event carries `bytes_done`, `bytes_total`, and a
  daemon-computed `bytes_per_sec` (exponential moving average, 2 s window)
  so the UI never does its own rate math and two UI clients can never
  disagree.
- Progress is counted from bytes actually consumed from / written to the
  TLS stream, not from socket buffer hand-off.

---

## 5. IPC specification - daemon ↔ notch UI

### 5.1 Transport

- Unix domain stream socket at
  `~/Library/Application Support/NotchSend/daemon.sock`, permissions 0600,
  directory 0700.
- Framing: one JSON object per line (NDJSON), UTF-8, max line 64 KiB
  (file metadata for very large batches is the only unbounded input;
  batches above the limit are paginated by the daemon).
- Multiple UI clients may connect; all receive events, but **only the first
  connected client is the approval authority** - accept/reject commands
  from non-authority clients are refused with `not_authority`. This
  prevents two UI instances (e.g. a stale one) from racing a decision.

### 5.2 Handshake and resynchronisation

On connect, the client sends `hello`; the daemon replies with `welcome`
(protocol version, daemon version, its own fingerprint and alias) followed
immediately by a `snapshot` containing the complete current state: peer
list, any pending request, any active session with per-file progress, and
config summary. The UI renders from the snapshot alone; live events then
keep it current. **No state is ever reconstructed from event history.**

```json
{"type":"hello","client":"DynamicNotch","ipc_version":1}
{"type":"welcome","ipc_version":1,"daemon_version":"0.1.0",
 "alias":"Rivaldi's MacBook Air","fingerprint":"AB12…"}
{"type":"snapshot","seq":41,"peers":[…],"pending":null,"session":null}
```

### 5.3 Commands (UI → daemon)

| Command | Fields | Effect |
|---|---|---|
| `accept` | `request_id`, optional `file_ids` (subset) | Releases the approval gate; daemon answers `prepare-upload` with tokens for the accepted files. |
| `reject` | `request_id` | Answers `prepare-upload` with 403. |
| `send` | `peer_fingerprint` (or `address`), `paths[]` | Starts an outgoing session; daemon replies with a `session_id` or an `error`. Absolute paths, same-user only - the socket permission is the authorisation. |
| `cancel` | `session_id` | Cancels an incoming or outgoing session. |
| `rescan` | - | Triggers an immediate multicast announce sweep. |
| `set_config` | partial config object | Runtime-mutable keys only (alias, PIN, auto-accept, download dir). Others require daemon restart and are reported as such. |
| `shutdown` | - | Graceful daemon stop (used by the installer/updater, not the notch UI). |

Every command carries a client-chosen `id`; the daemon answers with a
`result` message echoing that `id`, success or a structured error
(`code`, `message`). Commands are idempotent where the domain allows it
(double `accept` on the same request returns the original outcome).

### 5.4 Events (daemon → UI)

| Event | Payload (essentials) | Notch mapping (§6) |
|---|---|---|
| `peer_found` / `peer_lost` | fingerprint, alias, device type/model, address | Peer picker content |
| `incoming_request` | `request_id`, sender info, files[] (name, size, type), total size, expires_at | **Expanded** confirmation |
| `request_expired` | `request_id` | Dismiss confirmation |
| `session_started` | `session_id`, direction, peer, files[] | Live activity begins |
| `progress` | `session_id`, `file_id`, bytes done/total, rate, aggregate % | Minimal-view bar |
| `file_completed` | `session_id`, `file_id`, saved path | - |
| `session_completed` | `session_id`, saved paths[] | Completion card |
| `session_failed` | `session_id`, file, error code/message | Error card |
| `session_cancelled` | `session_id`, by (peer / user) | Brief notice, auto-hide |
| `daemon_status` | discoverable on/off, port conflict, last error | Settings / status icon |

### 5.5 Worked example - receiving

```json
→ {"type":"event","event":"incoming_request","seq":42,"request_id":"r-7f3",
   "sender":{"alias":"Pixel 9","device_type":"mobile"},
   "files":[{"id":"f1","name":"IMG_2041.jpg","size":4821331},
            {"id":"f2","name":"notes.pdf","size":188402}],
   "total_size":5009733,"expires_at":"2026-10-13T08:28:15Z"}
← {"type":"accept","id":"c-19","request_id":"r-7f3"}
→ {"type":"event","event":"session_started","seq":43,"session_id":"s-91", …}
→ {"type":"event","event":"progress","seq":44,"session_id":"s-91",
   "file_id":"f1","bytes_done":2410000,"bytes_total":4821331,
   "bytes_per_sec":18300000,"aggregate_pct":44}
→ {"type":"event","event":"session_completed","seq":51,"session_id":"s-91",
   "saved_paths":["~/Downloads/IMG_2041.jpg","~/Downloads/notes.pdf"]}
```

---

## 6. Component design - Swift notch UI (DynamicNotch fork)

### 6.1 Placement in the fork

A single new feature module mirroring the fork's existing feature layout;
no changes to the notch window, engine, or coordinator core.

```
DynamicNotch/Features/LocalSend/
├── Content/LocalSendNotchContent.swift      # registers with the content registry
├── ViewModels/LocalSendViewModel.swift      # @MainActor projector of daemon state
├── Views/LocalSendMinimalView.swift         # icon + progress bar + %
├── Views/LocalSendExpandedView.swift        # confirmation + detail + peer picker
├── Views/LocalSendCompletedView.swift       # saved files + Reveal in Finder
├── Services/DaemonClient.swift              # socket, NDJSON codec, reconnect
├── Services/LocalSendEventHandler.swift     # coordinator handler: events → engine
└── Models/…                                 # Codable mirrors of IPC messages
```

`AppContainer` gains one registration block (client, view model, handler),
exactly as other features are composed. `DaemonClient` owns reconnection
with backoff (0.5 s → 5 s cap) and treats every (re)connect identically:
`hello` → `snapshot` → live events.

### 6.2 Presentation mapping

DynamicNotch distinguishes **live activities** (persist while active) from
**temporary activities** (show, then auto-hide). LocalSend uses both:

| Daemon state | Presentation | Priority / behaviour |
|---|---|---|
| Incoming request pending | Expanded view, temporary-but-sticky: stays until accept, reject, or `expires_at`. Shows sender alias/type, file list (first 3 + "+N more"), total size, **Accept** / **Decline** buttons. Hover-expand rules are bypassed; this is the one LocalSend state allowed to expand uninvited, because the sender is blocked waiting. | Highest. Interrupts other temporary activities; does not interrupt an active transfer's live activity visually - it replaces the expanded layer only. |
| Transferring (either direction) | Live activity. Minimal view: direction icon, aggregate progress bar, %, rate. Expand on hover/click: per-file rows with individual bars and a Cancel button. | Standard live-activity priority, user-reorderable in the fork's existing priority settings. |
| Completed | Temporary card (4 s): checkmark, "3 files from Pixel 9", first filename, **Show in Finder** button. Click opens Finder at the first saved file. | Normal temporary priority. |
| Failed / cancelled | Temporary card (5 s): reason in plain language ("Sender cancelled", "Connection lost", "Not enough disk space"), no raw error codes. | Normal temporary priority. |
| Idle | Nothing. The notch is unchanged from stock DynamicNotch behaviour. A small LocalSend page in the expanded home view shows daemon status and known peers, and is the send entry point when opened deliberately. | - |

### 6.3 Sending from the notch

Two entry points, both ending in the same `send` command:

1. **Drag & Drop** - the fork already has a drag-and-drop destination
   overlay on the notch. Dropping files shows the peer picker (expanded
   view: online peers with alias and device icon; stale peers greyed).
   Tapping a peer sends `send` with the dropped paths.
2. **Finder / share entry (Phase 3, optional)** - a Finder Sync extension
   or a macOS Services item "Send via NotchSend" that forwards paths to
   the UI, which opens the same peer picker. Not required for v1.

While `preparing` (hashing large outgoing files, §4.3) the expanded view
shows an indeterminate state with the filename, so the picker never looks
frozen.

### 6.4 UI rules carried over from the owner's standing preferences

- No emoji as icons; SF Symbols / the fork's icon components only.
- Minimal animation beyond the fork's own notch transitions; no entrance
  stagger on file rows (the user may be mid-task; the notch must feel
  instant, and confirmation is on a sender's clock).
- Prices do not apply here, but the equivalent rule does: numbers
  (sizes, rates, %) are plain primary text, colour is reserved for
  status (error red, warning amber) and primary actions.

---

## 7. End-to-end flows

### 7.1 Receive with confirmation

1. Phone sends `prepare-upload`. Daemon validates PIN/body, allocates the
   session slot, enters `PENDING_APPROVAL`, emits `incoming_request`,
   and holds the HTTP response.
2. Notch expands with the confirmation. Owner taps **Accept**
   (or a subset of files).
3. UI sends `accept`. Daemon answers the phone `200 {sessionId, tokens}`.
4. Phone uploads files (up to 2 concurrently). Daemon streams each to
   `.part`, emits throttled `progress`, verifies size/SHA-256, renames.
5. Daemon emits `session_completed` with saved paths; notch shows the
   completion card; slot returns to `IDLE`.

### 7.2 Reject, timeout, and absent-UI flows

- **Reject:** UI `reject` → daemon answers 403 → phone shows "declined".
- **Timeout (60 s):** daemon answers 403, emits `request_expired`, notch
  dismisses the confirmation without a failure card (nothing failed; the
  owner simply did not answer).
- **UI not running:** daemon rejects immediately (403) unless
  `auto_accept = true` (§4.4). The daemon never queues a request for a UI
  that might start later.

### 7.3 Send

1. Owner drops files on the notch (or picks Send from the LocalSend page),
   selects a peer.
2. UI sends `send`. Daemon hashes files (`preparing`), calls the peer's
   `prepare-upload`, and waits - the notch shows "Waiting for \<peer\> to
   accept…" as a live activity, with Cancel.
3. Peer accepts → daemon uploads with progress → completion card.
   Peer declines (403) → failure card "Declined by \<peer\>". Peer requires
   a PIN (401) → expanded view shows a PIN field; submission retries the
   same `send` with the PIN attached.

### 7.4 UI crash / restart mid-transfer

The daemon is unaffected and finishes or fails the transfer on its own.
The restarted UI reconnects, receives a `snapshot` (active session with
current per-file progress, or the completed session's result retained for
10 minutes for exactly this case), and re-renders. No transfer decision
is ever lost because a view went away - except approval: if the UI dies
while `PENDING_APPROVAL`, the request simply times out as in §7.2, which
the daemon logs as `ui_disconnected_during_approval`.

---

## 8. Lifecycle: installation, supervision, updates

### 8.1 Packaging

One `.app` bundle (the DynamicNotch fork) containing the daemon binary at
`Contents/MacOS/notchsendd` (or `Contents/Helpers/`). The app registers
the daemon as a LaunchAgent on first launch using `SMAppService.agent`
with a bundled agent plist; on older deployment targets, fall back to
writing the plist to `~/Library/LaunchAgents/` and `launchctl bootstrap`.

### 8.2 LaunchAgent definition (essentials)

```xml
<key>Label</key>            <string>space.rivaldi.notchsendd</string>
<key>ProgramArguments</key> <array>
  <string>/Applications/NotchSend.app/Contents/MacOS/notchsendd</string>
  <string>--config</string>
  <string>/Users/rivaldi/Library/Application Support/NotchSend/config.toml</string>
</array>
<key>RunAtLoad</key>   <true/>
<key>KeepAlive</key>   <dict>
  <key>SuccessfulExit</key><false/>   <!-- restart on crash, stay down on clean stop -->
</dict>
<key>ThrottleInterval</key> <integer>5</integer>
<key>ProcessType</key>      <string>Background</string>
```

### 8.3 Start/stop semantics

- Clean exit (SIGTERM, `shutdown` command) → launchd does not relaunch.
- Crash → relaunch after throttle interval; the daemon re-announces on
  the LAN and rebinds 53317. Peers see a brief disappearance, which the
  protocol's announce cycle absorbs.
- The daemon takes a single-instance lock on its socket: a second start
  attempt detects the live socket, verifies the peer, and exits 0 with a
  log line instead of fighting over the port.

### 8.4 Logging

- Daemon: `tracing` to a rotating file
  (`~/Library/Logs/NotchSend/daemon.log`, 5 MB × 4) - file logging chosen
  over unified-log-only because transfer debugging routinely involves the
  owner reading logs after the fact.
- UI: the fork's existing logging.
- Log lines never contain file contents; they contain names, sizes,
  fingerprints (truncated to 8 chars), and session IDs.
- Local Network privacy (macOS): the daemon triggers the Local Network
  permission prompt on first multicast/HTTPS activity. The app bundle's
  usage description must cover it, and Phase 0 exit criteria include the
  prompt appearing exactly once and discovery surviving a deny→allow
  change.

### 8.5 Updates

App and daemon ship together in the bundle and version-lock to each other
via the IPC `hello`/`welcome` exchange: on `ipc_version` mismatch the UI
shows "Daemon is updating" rather than an error, the app asks launchd to
restart the agent (picking up the new binary), and the UI reconnects.
There is no independent daemon update channel in v1.

---

## 9. Configuration and storage

```
~/Library/Application Support/NotchSend/
├── config.toml          (0644)
├── identity/
│   ├── cert.pem         (0644 - public)
│   └── key.pem          (0600 - private)
├── daemon.sock          (0600, runtime)
└── state.json           (trusted peers, last session result)
```

```toml
alias        = "Rivaldi's MacBook Air"
device_type  = "desktop"
port         = 53317
download_dir = "~/Downloads"
pin          = ""              # empty = no PIN
auto_accept  = false           # see §4.4 - decision D2
approval_timeout_secs = 60
discoverable = true
```

- `download_dir`, `port`, and `identity/` require a daemon restart to
  change; the UI must say so instead of silently ignoring edits.
- Trusted peers (decision D3): peers whose past transfers the owner
  accepted can optionally be remembered by fingerprint, enabling a future
  per-peer auto-accept. The data model reserves the table in `state.json`
  now; the policy ships only if D3 is approved.

---

## 10. Security considerations

| Threat | Mitigation |
|---|---|
| Arbitrary LAN device sends files | Nothing is written outside `.part` staging until approval; without approval nothing persists. Optional PIN (401 challenge) for hostile networks. Default posture is prompt-every-time. |
| Malicious filename (`../../…`, absolute paths) | Sanitisation in §4.3; final path is always `download_dir` + sanitised base name; collision suffixing prevents overwrite of existing files. |
| Token replay from a different host | `upload` is bound to the `prepare-upload` source IP; token mismatch or IP mismatch → 403. |
| Fake peer / cert substitution when sending | Client verifies the peer certificate against the fingerprint learned in discovery (pinning), not against a CA or hostname. |
| Corrupted or truncated transfer accepted as good | Byte-count check on every file; SHA-256 check whenever metadata provides a digest; mismatch → 422 and the `.part` file is deleted, never renamed. |
| Local process impersonating the UI | Socket is 0600 in a 0700 directory; daemon verifies peer UID via `getpeereid`. Same-user malware is out of scope (it already has the user's files). |
| Private key theft | Key file 0600 under the user's Application Support; never logged, never sent over IPC. |
| Resource exhaustion (giant/hanging uploads) | Session slot is singular; per-file and per-session size are those declared in metadata and enforced while streaming (abort if the stream exceeds the declared size); approval and session TTLs bound how long a hostile peer can hold the slot. Rate limiting on `prepare-upload` (429) matches reference behaviour. |

What this design deliberately does **not** claim: LocalSend's LAN trust
model is "anyone on the network whom you approve (or who knows the PIN)".
That is the protocol's model, not a defect this project fixes.

---

## 11. Error handling - user-visible cases

| Condition | Daemon behaviour | Notch presentation |
|---|---|---|
| Port 53317 already bound (official app running) | Daemon starts, marks itself non-discoverable, emits `daemon_status{port_conflict}`; retries bind every 30 s. | Status icon on the LocalSend page: "LocalSend app is using the port - quit it to receive here." No modal, no repeated nagging. |
| Multicast blocked / Local Network permission denied | Discovery degrades to register-callback only; daemon reports `discovery_degraded`. | One temporary card on first occurrence; status page explains the setting to change. |
| Disk full mid-receive | Abort session, delete `.part`, emit `session_failed{disk_full}`. | Failure card: "Not enough disk space." |
| Sender disconnects mid-file | Session fails for remaining files; completed files stay (they were verified and renamed). | Failure card names how many of N files arrived. |
| UI sends `accept` after timeout | Daemon returns `result{error: request_expired}` for that command ID. | Confirmation already dismissed; no card. |
| Peer requires PIN when sending | Daemon surfaces `pin_required` as a session state. | Expanded PIN entry (§7.3). Three wrong attempts → 429 handling and a plain-language lockout message. |

---

## 12. Known limitations (v1)

- No subnet-scan discovery fallback; networks that filter multicast will
  show fewer peers than the official app (which scans). Register-callback
  discovery still finds peers that announce to us.
- One active session at a time (§2 A8). A second sender gets 409 ("busy")
  exactly as with the reference implementation's single-session posture.
- No transfer resume. A failed multi-GB file restarts from zero; the
  protocol offers no range mechanism to build resume on.
- No download API / Web Send (§1.3).
- Notch presentation assumes the built-in display; if the notch display
  sleeps or is mirrored away, transfers continue in the daemon and events
  are reflected in the next snapshot/UI session.

---

## 13. Alternatives considered and rejected

| Alternative | Why rejected |
|---|---|
| Fork the official Flutter app and add a headless mode | The app's server, discovery, and UI state are built around a running Flutter engine and its isolate model; making it a reliable always-on macOS agent means fighting that architecture, and the notch UI would still need a separate native app. Two codebases, worst option. |
| Rust embedded in the Swift app via UniFFI (single process) | Sound technology - and the owner's existing Rust↔Kotlin UniFFI experience transfers - but it couples lifetimes: quitting or crashing the notch app kills the receiver, which contradicts the core requirement (§1.2.1). Retained as a fallback if separate-process packaging proves impractical. |
| Existing third-party daemons (Python `localsendd`, Go CLIs) as the shipped daemon | Excellent references and Phase 0 test doubles (§14), but shipping a Python interpreter dependency or adopting a codebase whose approval model is auto-accept-first adds a dependency the owner does not control, in service of saving the one part of this project that is best understood. Their socket-IPC shape, however, directly informed §5. |
| Swift daemon | Viable, but the reference protocol core is Rust; a Swift server means re-deriving mutual-TLS pinning, multicast, and streaming-save behaviour without a same-language reference, for no user-visible gain. |
| XPC instead of a Unix socket for IPC | XPC is the platform-blessed route but requires the daemon to be an XPC service bundled and entitlement-matched with the app, and makes the Phase 0 CLI harness and cross-language debugging materially harder. NDJSON over a Unix socket is inspectable with standard tools and keeps the daemon usable without the app. Revisit if the project ever targets the Mac App Store (sandboxing would force this). |

---

## 14. Implementation phases

Each phase has exit criteria. No phase is considered done on "code
written"; the criteria are the definition of done.

### Phase 0 - Protocol spike (Rust only, no Swift)

- `protocol` + minimal `core`: discovery announce/respond, `info`,
  `register`, receive path with approval driven by `notchsendctl`
  (accept/reject from the terminal), progress printed by the CLI.
- **Exit criteria:** an unmodified official LocalSend app on the owner's
  Android phone sends a 3-file batch (photo, PDF, >500 MB video) to the
  daemon; files arrive intact (SHA-256 match), reject path verified,
  timeout path verified; the daemon sends a file back to the phone and
  the phone accepts it. Local Network permission prompt behaviour
  recorded.

### Phase 1 - Daemon hardening

- Full §4.3 scope, PIN both directions, trusted-peer storage (data only),
  config file, LaunchAgent packaging, single-instance lock, log rotation,
  `snapshot` + full IPC surface (§5) implemented against the CLI.
- **Exit criteria:** 24-hour soak on the owner's Mac (no crash, no port
  or socket leak, memory stable); kill -9 mid-transfer leaves no corrupt
  final file and the daemon recovers the slot; interop matrix (§15)
  passes.

### Phase 2 - Notch integration (receive)

- Fork DynamicNotch; add the §6 module; `DaemonClient` with reconnect +
  snapshot resync; confirmation, live progress, completion/failure cards.
- **Exit criteria:** full §7.1/§7.2 flows driven only from the notch on
  the real machine; UI killed and relaunched mid-transfer (§7.4) behaves
  as specified; with the UI closed, senders get an immediate decline.

### Phase 3 - Sending from the notch

- Drag & drop peer picker, `send` flow incl. PIN entry and
  waiting-for-accept state; optional Finder/Services entry point.
- **Exit criteria:** §7.3 flows pass against phone and a second computer;
  cancel from the notch works in both directions.

### Phase 4 - Packaging and polish

- Signed/notarised build (Developer ID), first-run onboarding for the
  Local Network prompt and daemon registration, settings page
  (alias, download dir, PIN, auto-accept), update flow (§8.5).
- **Exit criteria:** clean install on a fresh user account works end to
  end; uninstall removes the LaunchAgent, socket, and identity.

### Effort shape (not a schedule)

Phase 0 is days, not weeks - the protocol surface for receive is small
and reference implementations exist in the same language. Phase 1 is the
largest Rust block. Phase 2 is mostly projection code (daemon state →
SwiftUI) and should be smaller than Phase 1 if the §5 snapshot contract
holds. Phase 4's cost is dominated by signing/notarisation mechanics,
not features.

---

## 15. Testing strategy

- **Unit (Rust):** DTO round-trips against protocol fixtures; filename
  sanitisation and collision naming; fingerprint derivation against the
  reference test vector; state-machine transitions incl. timeout and
  double-accept idempotency.
- **Integration (Rust):** two daemon instances on loopback (multicast
  stubbed, explicit addresses) exchanging files both directions; IPC
  contract tests driving the socket with recorded NDJSON scripts,
  including reconnect-and-snapshot mid-transfer.
- **Interop matrix (manual, scripted checklist):** official LocalSend on
  Android and on a second desktop OS, each direction, with PIN on and
  off, small batch and single >1 GB file. Re-run on any protocol-code
  change.
- **UI (Swift):** view-model tests feeding recorded IPC event streams
  (the daemon is not needed to test presentation mapping); one manual
  pass per §7 flow per release.
- **Failure injection:** kill the UI mid-approval; kill the daemon
  mid-upload; fill the disk; revoke Local Network permission. Each maps
  to a row in §11 and must present as specified.

---

## 16. Open decisions for the owner

| # | Decision | Options | Default in this blueprint |
|---|---|---|---|
| D1 | Product/binary name | `notchsend` / reuse "LocalSend Notch" descriptively (trademark care: LocalSend is upstream's name) | `notchsend`, descriptive subtitle only |
| D2 | Behaviour when the UI is not running | Immediate decline / auto-accept into `~/Downloads` / auto-accept from trusted peers only | Immediate decline; `auto_accept` opt-in |
| D3 | Trusted peers | Not in v1 / remember-and-auto-accept per fingerprint / remember but still prompt, with sender badge in the notch | Data model reserved; policy deferred to after Phase 2 |
| D4 | Default download directory | `~/Downloads` / `~/Downloads/NotchSend` subfolder | `~/Downloads` (matches official app expectation) |
| D5 | Approval timeout | 30 s / 60 s / 120 s | 60 s |

---

## Appendix A - IPC message catalogue (normative list)

Commands: `hello`, `accept`, `reject`, `send`, `cancel`, `rescan`,
`set_config`, `shutdown`.
Responses: `welcome`, `snapshot`, `result`.
Events: `peer_found`, `peer_lost`, `incoming_request`,
`request_expired`, `session_started`, `session_state` (incl.
`pin_required`, `preparing`), `progress`, `file_completed`,
`session_completed`, `session_failed`, `session_cancelled`,
`daemon_status`.

All messages are JSON objects with a `type` field; events additionally
carry `seq` (monotonic per daemon run) and `session_id`/`request_id`
where applicable. Unknown fields must be ignored by both sides; unknown
message types are logged and ignored, never fatal. `ipc_version` is
negotiated in `hello`/`welcome`; a major-version mismatch puts the UI in
the updating state (§8.5) rather than attempting partial operation.

## Appendix B - Glossary

- **Approval gate** - the daemon holding a `prepare-upload` HTTP response
  open while the owner decides in the notch (§4.4).
- **Authority client** - the first connected IPC client, the only one
  whose accept/reject commands are honoured (§5.1).
- **Fingerprint** - uppercase hex SHA-256 of a device's self-signed
  certificate DER; the device's identity in discovery and TLS pinning.
- **Snapshot** - the daemon's complete current state, sent on every IPC
  connect, from which the UI renders without event history (§5.2).
