import Foundation
import Combine
import AppKit
import SwiftUI

enum Presentation: Equatable {
    case idle
    case home
    case confirm
    case minimal
    case expandedTransfer
    case preparing
    case waiting
    case pinEntry
    case peerPicker
    case dropOverlay
    case card
}

struct CardInfo {
    enum Kind { case completedReceive, completedSend, failed, notice }
    var kind: Kind
    var title: String
    var subtitle: String
    var savedPaths: [String] = []
    var canRetry: Bool = false
    var expiresAt: Date
}

struct SendContext {
    var peer: Peer
    var paths: [String]
    var sessionId: String? = nil
    var phase: String = "preparing" // preparing | waiting (inferred)
    var startedAt = Date()
    var cancelRequested = false
}

/// The view model: a stateless projector of daemon state, per BLUEPRINT §2 A5.
/// All mutations happen on the main queue.
final class AppState: ObservableObject {
    // Connection / daemon info
    @Published var connected = false
    @Published var daemonAlias = ""
    @Published var daemonFingerprint = ""
    @Published var daemonPort = 53317

    // Daemon state projections
    @Published var peers: [Peer] = []
    @Published var pending: PendingRequest? = nil
    @Published var session: SessionState? = nil
    @Published var pendingSend: SendContext? = nil
    @Published var pinContext: SendContext? = nil
    @Published var pinMessage: String = ""
    let pinEntry = PinEntryModel()
    @Published var card: CardInfo? = nil
    @Published var lastTransfer: LastTransfer? = nil

    // UI-only state
    @Published var homeOpen = false
    @Published var pickerPaths: [String]? = nil
    @Published var dropTargeted = false
    @Published var dropCount = 0
    @Published var dropTotal: UInt64 = 0
    @Published var transferExpanded = false
    /// Panel-level hover state (NSTrackingArea on the panel container view,
    /// see main.swift). Drives hover-to-expand: idle -> M15 home,
    /// minimal transfer (M02/M10) -> expanded (M03/M11).
    @Published var hovering = false
    /// Click-pinned expansion: clicking the notch toggles this so trackpad /
    /// Magic Mouse users can keep the expanded state without hovering.
    @Published var clickPinned = false
    private var hoverGraceWork: DispatchWorkItem? = nil

    // Presentation (computed by refresh)
    @Published var presentation: Presentation = .idle
    /// The VISIBLE black shape's size (DynamicNotch scheme: the window is a
    /// fixed 1000x1000 canvas; only this surface animates, in-window).
    @Published var surfaceSize: CGSize = .zero
    @Published var surfaceRadiusTop: CGFloat = 0
    @Published var surfaceRadiusBottom: CGFloat = 0
    /// DynamicNotch press/hover "squeeze" (NotchCustomScaleModifier):
    /// scaleEffect on the surface, anchor .top, compact presentations only.
    @Published var pressScale: CGFloat = 1

    // MARK: - DynamicNotch v1.6.3 geometry (DYNAMICNOTCH_163_SCHEME.md §2)
    //
    // baseWidth  = notchWidth + 14 * widthScale + (settings.notchWidth + 2),
    //              settings.notchWidth defaults to 0
    // baseHeight = notchHeight + settings.notchHeight (defaults 0)
    // scale = max(0.35, screenWidth / 1440); widthScale eases scale > 1 by 0.35
    // baseRadius = baseHeight / 3; default radii (baseRadius - 4, baseRadius)
    var dnBaseSize: CGSize {
        let scale = max(0.35, screenWidth / 1440)
        let widthScale = scale > 1 ? 1 + (scale - 1) * 0.35 : scale
        return CGSize(width: notchSize.width + 14 * widthScale + 2,
                      height: notchSize.height)
    }
    var dnBaseRadius: CGFloat { dnBaseSize.height / 3 }

    /// Expanded-form presentations use the expanded content transition and
    /// suppress the press squeeze (DynamicNotch shouldApplyPressScale).
    var isExpandedForm: Bool {
        switch presentation {
        case .confirm, .expandedTransfer, .home, .peerPicker, .pinEntry, .dropOverlay:
            return true
        case .card:
            return card?.kind != .notice
        default:
            return false
        }
    }

    /// The spike daemon does NOT send expires_at with incoming_request
    /// (blueprint §5.4 says it should). The running daemon is launched with
    /// --approval-timeout-secs 120, so the countdown assumes 120 s.
    let assumedApprovalTimeout: Int = 120
    @Published var approvalSecondsLeft: Int = 120

    var notchSize: CGSize = CGSize(width: 200, height: 32)
    var screenWidth: CGFloat = 1280

    let client: DaemonClient
    private var sendCommandId: String? = nil
    private var retryContext: SendContext? = nil
    private var tickTimer: Timer? = nil
    private var lastPresentation: Presentation = .idle

    init(socketPath: String) {
        client = DaemonClient(socketPath: socketPath)
        client.onMessage = { [weak self] msg in
            DispatchQueue.main.async { self?.handle(msg) }
        }
        client.onConnectionChange = { [weak self] up in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.connected = up
                Log.line("IPC connected=\(up)")
                self.refresh()
            }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func start() { client.start() }

    // MARK: - Tick (countdown, card expiry, waiting inference, staleness)

    private func tick() {
        var changed = false
        if let p = pending {
            let left = assumedApprovalTimeout - Int(Date().timeIntervalSince(p.receivedAt))
            let clamped = max(0, left)
            if clamped != approvalSecondsLeft { approvalSecondsLeft = clamped; changed = true }
            if left <= 0 { pending = nil; changed = true } // silent close, M14 rule
        }
        if let c = card, Date() >= c.expiresAt {
            card = nil
            changed = true
        }
        if var ps = pendingSend, ps.phase == "preparing",
           Date().timeIntervalSince(ps.startedAt) > 2.5 {
            // No daemon event separates "hashing" from "waiting for the peer
            // to answer prepare-upload" (only session_state=preparing exists),
            // so M08 is inferred presentation-side after 2.5 s.
            ps.phase = "waiting"
            pendingSend = ps
            changed = true
        }
        if changed { refresh() }
    }

    // MARK: - Presentation resolution

    func refresh(animating: Bool = true) {
        let next: Presentation
        if pending != nil {
            next = .confirm
        } else if pinContext != nil {
            next = .pinEntry
        } else if card != nil {
            next = .card
        } else if dropTargeted {
            next = .dropOverlay
        } else if pickerPaths != nil {
            next = .peerPicker
        } else if let ps = pendingSend {
            next = ps.phase == "waiting" ? .waiting : .preparing
        } else if session != nil {
            next = (transferExpanded || hovering || clickPinned) ? .expandedTransfer : .minimal
        } else if homeOpen || hovering || clickPinned {
            next = .home
        } else {
            next = .idle
        }
        let nextSize = surfaceSizeFor(next)
        let nextRadii = radiiFor(next)
        let changed = next != presentation
            || nextSize != surfaceSize
            || nextRadii.top != surfaceRadiusTop
            || nextRadii.bottom != surfaceRadiusBottom
        if changed {
            // DynamicNotch scheme: the mutation itself is wrapped in the
            // specific spring (NotchEngine wraps every model mutation in
            // withAnimation(animations.*)); SwiftUI then animates the
            // surface frame, the shape radii and the content as one.
            let spring = animating ? springFor(from: presentation, to: next,
                                               fromSize: surfaceSize, toSize: nextSize)
                                   : nil
            let apply = {
                self.presentation = next
                self.surfaceSize = nextSize
                self.surfaceRadiusTop = nextRadii.top
                self.surfaceRadiusBottom = nextRadii.bottom
                if self.isExpandedFormFor(next) { self.pressScale = 1 }
            }
            if let spring = spring {
                withAnimation(spring, apply)
            } else {
                apply()
            }
        }
        if next != lastPresentation {
            Log.line("STATE \(describe(next)) size=\(Int(surfaceSize.width))x\(Int(surfaceSize.height))")
            lastPresentation = next
        }
    }

    /// NotchAnimations.balanced (DYNAMICNOTCH_163_SCHEME.md §5):
    /// expand = spring(0.50, damping 0.75, blend 1.0);
    /// close / contentUpdate = spring(0.50, blend 1.0) (default damping).
    private func springFor(from: Presentation, to: Presentation,
                           fromSize: CGSize, toSize: CGSize) -> Animation {
        if to == .idle && from != .idle {
            return .spring(response: 0.50, blendDuration: 1.0) // closeLiveActivity
        }
        let fromArea = fromSize.width * fromSize.height
        let toArea = toSize.width * toSize.height
        if toArea > fromArea {
            return .spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0) // expandLiveActivity
        }
        if toArea < fromArea {
            return .spring(response: 0.50, blendDuration: 1.0) // closeLiveActivity
        }
        return .spring(response: 0.50, blendDuration: 1.0) // contentUpdate
    }

    private func isExpandedFormFor(_ p: Presentation) -> Bool {
        switch p {
        case .confirm, .expandedTransfer, .home, .peerPicker, .pinEntry, .dropOverlay:
            return true
        case .card:
            return card?.kind != .notice
        default:
            return false
        }
    }

    /// Corner radii per DynamicNotch: compact states use the protocol
    /// default (baseRadius - 4, baseRadius); expanded states use the
    /// Download content's expanded radii (24, 34); the drop overlay uses
    /// DragAndDrop's (24, 36). See DYNAMICNOTCH_163_SCHEME.md §2.
    private func radiiFor(_ p: Presentation) -> (top: CGFloat, bottom: CGFloat) {
        let base = dnBaseRadius
        switch p {
        case .idle, .minimal, .preparing, .waiting:
            return (base - 4, base)
        case .card:
            return card?.kind == .notice ? (base - 4, base) : (24, 34)
        case .dropOverlay:
            return (24, 36)
        case .pinEntry:
            return (24, 34)
        case .confirm, .expandedTransfer, .home, .peerPicker:
            // Owner-directed deviation from v1.6.3's (24, 34): top radius
            // 30 so the concave neck reads as part of the notch instead of
            // a plain box (owner photo verdict, 2026-10-15). Recorded in
            // DYNAMICNOTCH_163_SCHEME.md §9.
            return (30, 34)
        }
    }

    private func describe(_ p: Presentation) -> String {
        switch p {
        case .idle: return "idle(notch)"
        case .home: return "home(M15)"
        case .confirm: return "confirm(M01)"
        case .minimal: return (session?.direction == "send") ? "minimal-send(M10)" : "minimal-receive(M02)"
        case .expandedTransfer: return (session?.direction == "send") ? "expanded-send(M11)" : "expanded-receive(M03)"
        case .preparing: return "preparing(M07)"
        case .waiting: return "waiting(M08)"
        case .pinEntry: return "pin(M09)"
        case .peerPicker: return "peer-picker(M06)"
        case .dropOverlay: return "drop-overlay(M05)"
        case .card: return "card(M04/M12/M13/M14)"
        }
    }

    /// Surface rect per presentation. These are DynamicNotch-style drawn
    /// rects (the visible black shape, flare included), sized so the
    /// content area inside the shape body (rect minus 2 * topRadius,
    /// minus the 5 pt content mask inset) keeps the mockups' room:
    /// expanded rects are the old window sizes + 48 wide / + 10 high.
    func surfaceSizeFor(_ p: Presentation) -> CGSize {
        let maxW = screenWidth - 24
        func cl(_ w: CGFloat, _ h: CGFloat) -> CGSize {
            CGSize(width: min(w, maxW), height: h)
        }
        switch p {
        case .idle:
            return dnBaseSize
        case .minimal:
            return cl(388, 46)
        case .preparing, .waiting:
            return cl(448, 46)
        case .card:
            if let c = card, c.kind == .notice { return cl(348, 46) }
            return cl(528, 78)
        case .confirm:
            guard let p = pending else { return cl(608, 270) }
            let rows = min(p.files.count, 3) + (p.files.count > 3 ? 1 : 0)
            return cl(608, CGFloat(128 + rows * 36) + 10)
        case .expandedTransfer:
            guard let s = session else { return cl(608, 250) }
            let rows = min(s.files.count, 5)
            return cl(608, CGFloat(118 + rows * 46) + 10)
        case .home:
            // Width 560 (owner-directed, see radiiFor note): the first
            // build's M15 width; the wider 608 rect read as a flat box.
            // Height tracks the Batch 1/2 home layout: top pad 18 +
            // header 38 + bottom 16 chrome, peer rows 58, last-transfer
            // row 54, drop hint 46; the M16 block replaces peers + hint
            // when the daemon is down.
            if !connected { return cl(560, 206) }
            var h: CGFloat = 72 + 8 + 46
            h += CGFloat(min(peers.count, 5)) * 58
            if lastTransfer != nil { h += 54 }
            return cl(560, max(h, 176) + 10)
        case .peerPicker:
            let rows = max(peers.count, 1)
            return cl(608, CGFloat(84 + rows * 56 + 52) + 10)
        case .dropOverlay:
            return cl(608, 158)
        case .pinEntry:
            return cl(528, 228)
        }
    }

    // MARK: - Incoming messages

    private func handle(_ msg: JObj) {
        switch msg.str("type") ?? "" {
        case "welcome":
            daemonAlias = msg.str("alias") ?? ""
            daemonFingerprint = msg.str("fingerprint") ?? ""
            daemonPort = msg.int("port") ?? 53317
        case "snapshot":
            applySnapshot(msg)
        case "result":
            handleResult(msg)
        case "event":
            handleEvent(msg)
        default:
            break
        }
        refresh()
    }

    private func applySnapshot(_ msg: JObj) {
        if let arr = msg.arr("peers") {
            peers = arr.compactMap { ($0 as? JObj).flatMap(Peer.parse) }
                .sorted { ($0.isOnline ? 0 : 1, $0.alias) < ($1.isOnline ? 0 : 1, $1.alias) }
        }
        if let p = msg.obj("pending") {
            pending = parsePending(p)
            approvalSecondsLeft = assumedApprovalTimeout
        } else {
            pending = nil
        }
        if session == nil, let s = msg.obj("session") {
            session = parseSnapshotSession(s)
        }
        Log.line("SNAPSHOT peers=\(peers.count) pending=\(pending != nil) session=\(session != nil)")
    }

    private func parsePending(_ p: JObj) -> PendingRequest? {
        guard let rid = p.str("request_id") else { return nil }
        let sender = p.obj("sender")
        let files = (p.arr("files") ?? []).compactMap { ($0 as? JObj).flatMap(TransferFile.parse) }
        return PendingRequest(
            requestId: rid,
            senderAlias: sender?.str("alias") ?? "Perangkat",
            senderType: sender?.str("deviceType") ?? sender?.str("device_type"),
            senderIP: p.str("sender_ip") ?? sender?.str("ip") ?? "",
            files: files,
            totalSize: p.u64("total_size"),
            receivedAt: Date()
        )
    }

    private func parseSnapshotSession(_ s: JObj) -> SessionState? {
        guard let sid = s.str("session_id") else { return nil }
        let files = (s.arr("files") ?? []).compactMap { ($0 as? JObj).flatMap(TransferFile.parse) }
        var st = SessionState(
            id: sid,
            direction: s.str("direction") ?? "receive",
            peerAlias: s.str("peer_alias") ?? "",
            peerAddress: nil,
            files: files,
            totalSize: s.u64("total_size")
        )
        st.aggregateDone = files.reduce(0) { $0 + $1.bytesDone }
        return st
    }

    private func handleResult(_ msg: JObj) {
        guard let id = msg.str("id") else { return }
        if id == sendCommandId {
            if msg.bool("ok"), let sid = msg.str("session_id") {
                if var ps = pendingSend {
                    ps.sessionId = sid
                    if ps.cancelRequested {
                        client.command(["type": "cancel", "session_id": sid])
                        pendingSend = nil
                    } else {
                        pendingSend = ps
                    }
                }
            } else if !msg.bool("ok") {
                let m = msg.str("message") ?? "Perintah kirim ditolak daemon"
                showFailed(direction: "send", code: "command", message: m)
                pendingSend = nil
            }
        }
    }

    private func handleEvent(_ msg: JObj) {
        let event = msg.str("event") ?? ""
        switch event {
        case "peer_found":
            if let peer = Peer.parse(msg) {
                if let i = peers.firstIndex(where: { $0.fingerprint == peer.fingerprint }) {
                    peers[i] = peer
                } else {
                    peers.append(peer)
                }
                peers.sort { ($0.isOnline ? 0 : 1, $0.alias) < ($1.isOnline ? 0 : 1, $1.alias) }
            }
        case "incoming_request":
            pending = parsePending(msg)
            approvalSecondsLeft = assumedApprovalTimeout
            homeOpen = false
            clickPinned = false
            pickerPaths = nil
            card = nil
        case "request_expired":
            if let rid = msg.str("request_id"), pending?.requestId == rid {
                pending = nil // silent, per mockup M14
            }
        case "session_started":
            startSession(msg)
        case "session_state":
            if msg.str("state") == "preparing", var ps = pendingSend {
                ps.phase = "preparing"
                if let sid = msg.str("session_id") { ps.sessionId = sid }
                pendingSend = ps
            }
        case "progress":
            updateProgress(msg)
        case "file_completed":
            if var s = session, let fid = msg.str("file_id"),
               let i = s.files.firstIndex(where: { $0.id == fid }) {
                s.files[i].status = "done"
                s.files[i].bytesDone = s.files[i].size
                if let sp = msg.str("saved_path") { s.files[i].savedPath = sp }
                session = s
            }
        case "session_completed":
            finishSession(msg)
        case "session_failed":
            failSession(msg)
        case "session_cancelled":
            let by = msg.str("by") ?? "user"
            let sPrev = session
            let psPrev = pendingSend
            session = nil
            pendingSend = nil
            clickPinned = false
            showNotice(by == "peer" ? "Dibatalkan oleh pengirim" : "Transfer dibatalkan")
            if let s = sPrev {
                recordLastTransfer(direction: s.direction, alias: s.peerAlias,
                                   names: s.files.map { $0.name }, total: s.totalSize,
                                   saved: [], outcome: .cancelled)
            } else if let ps = psPrev {
                recordLastTransfer(direction: "send", alias: ps.peer.alias,
                                   names: ps.paths.map { URL(fileURLWithPath: $0).lastPathComponent },
                                   total: ps.pathsTotal, saved: [], outcome: .cancelled)
            } else {
                recordLastTransfer(direction: "receive", alias: "", names: [],
                                   total: 0, saved: [], outcome: .cancelled)
            }
        default:
            break
        }
    }

    private func startSession(_ msg: JObj) {
        guard let sid = msg.str("session_id") else { return }
        let direction = msg.str("direction") ?? "receive"
        let files = (msg.arr("files") ?? []).compactMap { ($0 as? JObj).flatMap(TransferFile.parse) }
        var alias = ""
        var address: String? = nil
        if let peer = msg.obj("peer") {
            if let a = peer.str("alias") { alias = a }
            if let ad = peer.str("address") { address = ad; alias = pendingSend?.peer.alias ?? alias }
        }
        if direction == "receive" { pending = nil }
        if direction == "send" { pendingSend = nil }
        session = SessionState(
            id: sid, direction: direction, peerAlias: alias, peerAddress: address,
            files: files, totalSize: msg.u64("total_size")
        )
        transferExpanded = false
    }

    private func updateProgress(_ msg: JObj) {
        guard var s = session, msg.str("session_id") == s.id else { return }
        if let fid = msg.str("file_id"), let i = s.files.firstIndex(where: { $0.id == fid }) {
            s.files[i].bytesDone = msg.u64("bytes_done")
            if s.files[i].status == "queued" { s.files[i].status = "transferring" }
        }
        let done = msg.u64("aggregate_done")
        let now = Date()
        let dt = now.timeIntervalSince(s.lastSampleTime)
        if dt >= 0.25 {
            let inst = Double(done >= s.lastSampleDone ? done - s.lastSampleDone : 0) / dt
            s.rate = s.rate == 0 ? inst : (s.rate * 0.6 + inst * 0.4)
            s.lastSampleTime = now
            s.lastSampleDone = done
        }
        s.aggregateDone = done
        session = s
    }

    /// Records the home page's last-transfer summary and logs it with the
    /// real file count, first file name and total size so the row's data
    /// is verifiable headlessly.
    private func recordLastTransfer(direction: String, alias: String,
                                    names: [String], total: UInt64,
                                    saved: [String],
                                    outcome: LastTransfer.Outcome,
                                    title: String = "") {
        lastTransfer = LastTransfer(
            direction: direction, peerAlias: alias, fileNames: names,
            totalSize: total, savedPaths: saved, finishedAt: Date(),
            outcome: outcome, title: title)
        Log.line("LASTTRANSFER outcome=\(outcome) direction=\(direction) files=\(names.count) first=\(names.first ?? "-") total=\(total)")
    }

    private func finishSession(_ msg: JObj) {
        let direction = msg.str("direction") ?? session?.direction ?? "receive"
        let saved = (msg.arr("saved_paths") ?? []).compactMap { $0 as? String }
        let n = session?.files.count ?? saved.count
        let alias = session?.peerAlias ?? ""
        let names = session?.files.map { $0.name }
            ?? saved.map { URL(fileURLWithPath: $0).lastPathComponent }
        let total = session?.totalSize
            ?? (direction == "receive" ? sizeOfFiles(saved) : 0)
        session = nil
        pendingSend = nil
        clickPinned = false
        if direction == "receive" {
            card = CardInfo(
                kind: .completedReceive,
                title: "\(n) file diterima\(alias.isEmpty ? "" : " dari \(alias)")",
                subtitle: saved.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                savedPaths: saved,
                expiresAt: Date().addingTimeInterval(4)
            )
            recordLastTransfer(direction: "receive", alias: alias, names: names,
                               total: total, saved: saved, outcome: .completed)
        } else {
            card = CardInfo(
                kind: .completedSend,
                title: "Terkirim\(alias.isEmpty ? "" : " ke \(alias)")",
                subtitle: "\(n) file terkirim, \(fmtClock(Date()))",
                expiresAt: Date().addingTimeInterval(4)
            )
            recordLastTransfer(direction: "send", alias: alias, names: names,
                               total: total, saved: [], outcome: .completed)
        }
    }

    private func failSession(_ msg: JObj) {
        let direction = msg.str("direction") ?? session?.direction ?? (pendingSend != nil ? "send" : "receive")
        let code = msg.str("error") ?? "error"
        let message = msg.str("message") ?? ""
        session = nil
        clickPinned = false
        if direction == "send", code == "pin_required" {
            // Daemon surfaces pin_required and accepts `pin` on retry: M09 is live.
            var ctx = pendingSend ?? retryContext
            if ctx != nil {
                ctx!.sessionId = nil
                pinContext = ctx
                pinMessage = message
            }
            pendingSend = nil
            return
        }
        if direction == "send", let ps = pendingSend { retryContext = ps }
        pendingSend = nil
        showFailed(direction: direction, code: code, message: message)
    }

    private func showFailed(direction: String, code: String, message: String) {
        let alias = session?.peerAlias ?? pendingSend?.peer.alias ?? retryContext?.peer.alias ?? ""
        let title: String
        switch code {
        case "declined": title = "Ditolak oleh \(alias.isEmpty ? "penerima" : alias)"
        case "busy": title = "\(alias.isEmpty ? "Tujuan" : alias) lagi sibuk"
        case "checksum_mismatch": title = "Checksum tidak cocok, file ditolak"
        case "size_mismatch": title = "Ukuran file tidak cocok"
        case "io_error": title = "Koneksi bermasalah"
        case "upload_failed": title = "Upload gagal"
        case "cancelled": title = "Transfer dibatalkan"
        default: title = "Transfer gagal"
        }
        card = CardInfo(
            kind: .failed,
            title: title,
            subtitle: message,
            canRetry: direction == "send" && retryContext != nil,
            expiresAt: Date().addingTimeInterval(5)
        )
        // Capture what identifies the failed transfer for the home row:
        // the live session if it still exists, else the send context
        // (its file names come from the picked paths). A receive that
        // failed before session start leaves names empty and the row
        // falls back to this failure title.
        let fNames: [String]
        let fTotal: UInt64
        if let s = session {
            fNames = s.files.map { $0.name }
            fTotal = s.totalSize
        } else if direction == "send", let ctx = pendingSend ?? retryContext {
            fNames = ctx.paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            fTotal = ctx.pathsTotal
        } else {
            fNames = []
            fTotal = 0
        }
        recordLastTransfer(direction: direction, alias: alias, names: fNames,
                           total: fTotal, saved: [], outcome: .failed, title: title)
    }

    private func showNotice(_ text: String) {
        card = CardInfo(kind: .notice, title: text, subtitle: "",
                        expiresAt: Date().addingTimeInterval(2))
    }

    // MARK: - Hover & click expansion

    /// Panel-level hover from NSTrackingArea (main.swift). Enter applies
    /// immediately (no hover delay); exit waits out a 0.25 s grace period so
    /// brief slips off the edge don't slam the notch shut. States that must
    /// persist (M01 confirmation, PIN, timed cards) ignore hover by priority
    /// in refresh(); drag targeting outranks it there too.
    func hoverChanged(_ inside: Bool) {
        if inside {
            hoverGraceWork?.cancel()
            hoverGraceWork = nil
            if !hovering {
                hovering = true
                Log.line("HOVER enter")
                // DynamicNotch hover squeeze (startHoverAnimation):
                // pressScale -> 1.08 with .easeOut(min(0.25, hoverDelay)).
                // If refresh() expands into an expanded-form state it
                // resets pressScale to 1 inside the expansion transaction.
                if !isExpandedForm {
                    withAnimation(.easeOut(duration: 0.25)) { self.pressScale = 1.08 }
                }
                refresh()
            }
        } else {
            hoverGraceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.hovering else { return }
                self.hovering = false
                Log.line("HOVER exit")
                // DynamicNotch resetHoverState: easeOut(0.12) back to 1.
                withAnimation(.easeOut(duration: 0.12)) { self.pressScale = 1 }
                self.refresh()
            }
            hoverGraceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// Click toggles a pinned expansion: click the idle notch to keep M15
    /// open without hovering; click again to let it collapse. The press
    /// itself gets DynamicNotch's press squeeze: easeOut(0.25) up to 1.08,
    /// easeOut(0.25) back (pressHoldDuration default 0.25).
    func notchClicked() {
        if !isExpandedForm {
            withAnimation(.easeOut(duration: 0.25)) { self.pressScale = 1.08 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self, !self.isExpandedForm else { return }
                withAnimation(.easeOut(duration: 0.25)) { self.pressScale = 1 }
            }
        }
        clickPinned.toggle()
        Log.line("CLICK pin=\(clickPinned)")
        refresh()
    }

    // MARK: - User actions

    func acceptPending() {
        guard let p = pending else { return }
        client.command(["type": "accept", "request_id": p.requestId])
    }

    func rejectPending() {
        guard let p = pending else { return }
        client.command(["type": "reject", "request_id": p.requestId])
        pending = nil
        refresh()
    }

    func cancelActive() {
        if let s = session {
            client.command(["type": "cancel", "session_id": s.id])
        } else if var ps = pendingSend {
            if let sid = ps.sessionId {
                client.command(["type": "cancel", "session_id": sid])
                pendingSend = nil
            } else {
                // session_id not known yet (send result still in flight):
                // keep the context so handleResult cancels it on arrival.
                ps.cancelRequested = true
                pendingSend = ps
            }
        }
        refresh()
    }

    func startSend(peer: Peer, paths: [String], pin: String? = nil) {
        let ctx = SendContext(peer: peer, paths: paths)
        pendingSend = ctx
        retryContext = ctx
        pickerPaths = nil
        homeOpen = false
        var cmd: JObj = ["type": "send", "address": peer.address,
                         "fingerprint": peer.fingerprint, "paths": paths]
        if let pin = pin { cmd["pin"] = pin }
        sendCommandId = client.command(cmd)
        refresh()
    }

    func submitPin(_ pin: String) {
        guard let ctx = pinContext else { return }
        pinContext = nil
        startSend(peer: ctx.peer, paths: ctx.paths, pin: pin)
    }

    func cancelPin() {
        pinContext = nil
        refresh()
    }

    func retryFailed() {
        guard let ctx = retryContext else { return }
        card = nil
        startSend(peer: ctx.peer, paths: ctx.paths)
    }

    func filesDropped(_ urls: [URL]) {
        dropTargeted = false
        let paths = urls.map { $0.path }
        pickerPaths = paths
        refresh()
    }

    func openHome() { homeOpen = true; refresh() }
    func closeHome() {
        homeOpen = false
        pickerPaths = nil
        refresh()
    }

    func revealInFinder(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        card = nil
        refresh()
    }
}
