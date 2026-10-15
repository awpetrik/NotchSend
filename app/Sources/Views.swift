import SwiftUI
import AppKit

// Visual spec: mockups M01-M16 (~/workspace/localsend-notch/mockups/index.html).
// Palette is DynamicNotch's own: black surface, #F5F5F7 text, #A1A1A6 secondary,
// system blue #0A84FF only for primary action + progress, green/red/amber status only.
// Icons are SF Symbols only. No emoji anywhere.

enum Theme {
    static let text = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let sub = Color(red: 0.631, green: 0.631, blue: 0.651)
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let amber = Color(red: 1.0, green: 0.839, blue: 0.039)
    static let ghost = Color(red: 0.173, green: 0.173, blue: 0.180)
    static let divider = Color(red: 0.173, green: 0.173, blue: 0.180)
    static let field = Color(red: 0.110, green: 0.110, blue: 0.118)
}

// MARK: - DynamicNotch v1.6.3 drawing scheme (DYNAMICNOTCH_163_SCHEME.md)
//
// The window is a fixed 1000x1000 canvas (main.swift); everything visual
// lives in the surface below: a black NotchShape whose size and corner
// radii animate in one SwiftUI spring transaction, content masked by the
// same shape, stretched/blurred by ResizeAwareBlur while the surface
// morphs. Values are DynamicNotch v1.6.3's, copied from its sources.

/// DynamicNotch's NotchShape (Shared/UI/Shapes/NotchShape.swift), verbatim:
/// concave (inverted) top fillets flare the shape to the full rect width
/// at the top edge; convex bottom corners; radii are animatable data so
/// they morph together with the size.
struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        return path
    }
}

/// DynamicNotch's NotchTransitionModifier, verbatim.
struct NotchTransitionModifier: ViewModifier {
    var blur: CGFloat = 0
    var opacity: Double = 1
    var offsetY: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: max(0.001, scaleX), y: max(0.001, scaleY), anchor: anchor)
            .offset(y: offsetY)
            .blur(radius: max(0, blur))
            .opacity(max(0, min(1, opacity)))
            .compositingGroup()
    }
}

/// DynamicNotch's NotchTransitionMetrics, verbatim.
enum NotchTransitionMetrics {
    static func verticalCompensationOffset(for notchHeight: CGFloat, baseHeight: CGFloat, isNotchlessScreen: Bool = false) -> CGFloat {
        let multiplier: CGFloat = isNotchlessScreen ? 0.65 : 0.75
        return -(max(0, notchHeight - baseHeight) * multiplier)
    }

    static func compactScaleX(for notchWidth: CGFloat, baseWidth: CGFloat) -> CGFloat {
        let extraWidth = notchWidth - baseWidth
        guard extraWidth > 70 else {
            return 0.8
        }
        let progress = (extraWidth - 70.0) / 70.0
        let scale = 0.8 - (progress * 0.3)
        return min(0.8, max(0.2, scale))
    }

    static func compactScaleY(for notchHeight: CGFloat, baseHeight: CGFloat) -> CGFloat {
        guard notchHeight > baseHeight else {
            return 1.0
        }
        let extraHeight = notchHeight - baseHeight
        let progress = min(1.0, extraHeight / 140.0)
        return 1.0 - (progress * 0.6)
    }
}

extension AnyTransition {
    /// DynamicNotch's notchCompact transition, values verbatim.
    static func notchCompact(
        notchWidth: CGFloat = 0,
        notchHeight: CGFloat,
        baseWidth: CGFloat = 0,
        baseHeight: CGFloat,
        isNotchlessScreen: Bool = false
    ) -> AnyTransition {
        let verticalOffset = NotchTransitionMetrics.verticalCompensationOffset(
            for: notchHeight, baseHeight: baseHeight, isNotchlessScreen: isNotchlessScreen)
        let scaleX = NotchTransitionMetrics.compactScaleX(for: notchWidth, baseWidth: baseWidth)
        let scaleY = NotchTransitionMetrics.compactScaleY(for: notchHeight, baseHeight: baseHeight)

        return .asymmetric(
            insertion: .modifier(
                active: NotchTransitionModifier(blur: 15, opacity: 0, offsetY: verticalOffset, scaleX: scaleX, scaleY: scaleY, anchor: .center),
                identity: NotchTransitionModifier(anchor: .center)),
            removal: .modifier(
                active: NotchTransitionModifier(blur: 15, opacity: 0, offsetY: verticalOffset, scaleX: scaleX, scaleY: scaleY, anchor: .center),
                identity: NotchTransitionModifier(anchor: .center)))
    }

    /// DynamicNotch's notchExpanded transition, values verbatim
    /// (notch-screen branch: removal scaleX 0.4).
    static func notchExpanded(
        notchHeight: CGFloat,
        baseHeight: CGFloat,
        isNotchlessScreen: Bool = false
    ) -> AnyTransition {
        let verticalOffset = NotchTransitionMetrics.verticalCompensationOffset(
            for: notchHeight, baseHeight: baseHeight, isNotchlessScreen: isNotchlessScreen)

        return .asymmetric(
            insertion: .modifier(
                active: NotchTransitionModifier(blur: 30, opacity: 0, offsetY: verticalOffset, scaleX: 0.6, scaleY: 0.2, anchor: .center),
                identity: NotchTransitionModifier(anchor: .center)),
            removal: .modifier(
                active: NotchTransitionModifier(blur: 30, opacity: 0, offsetY: verticalOffset, scaleX: 0.4, scaleY: 0.2, anchor: .center),
                identity: NotchTransitionModifier(anchor: .center)))
    }
}

/// DynamicNotch's ResizeAwareBlurModifier with the swipe-interaction
/// inputs removed (NotchSend has no swipe gestures): identical math on
/// the remaining path - content scales by animatedSize/targetSize and
/// blurs/fades in proportion to the surface's size delta while it morphs.
/// Metrics verbatim: maxBlurRadius 20, maxNormalizedDelta 0.1,
/// maxOpacityReduction 0.9.
struct ResizeAwareBlurModifier: AnimatableModifier {
    private var animatedWidth: CGFloat
    private var animatedHeight: CGFloat
    private let targetWidth: CGFloat
    private let targetHeight: CGFloat
    private let baseHeight: CGFloat

    private enum Metrics {
        static let maxBlurRadius: CGFloat = 20
        static let maxNormalizedDelta: CGFloat = 0.1
        static let maxOpacityReduction: Double = 0.9
    }

    init(size: CGSize, baseHeight: CGFloat) {
        animatedWidth = size.width
        animatedHeight = size.height
        targetWidth = size.width
        targetHeight = size.height
        self.baseHeight = baseHeight
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(animatedWidth, animatedHeight) }
        set {
            animatedWidth = newValue.first
            animatedHeight = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let widthDelta = normalizedDelta(abs(targetWidth - animatedWidth), relativeTo: targetWidth)
        let heightDelta = normalizedDelta(abs(targetHeight - animatedHeight), relativeTo: targetHeight)
        let normalizedProgress = max(widthDelta, heightDelta)
        let blurRadius = normalizedProgress * Metrics.maxBlurRadius
        let opacity = max(0, 1 - (Double(normalizedProgress) * Metrics.maxOpacityReduction))

        let xScale: CGFloat = targetWidth > 0 ? (animatedWidth / targetWidth) : 1.0
        let yScale: CGFloat = targetHeight > 0 ? (animatedHeight / targetHeight) : 1.0

        return content
            .scaleEffect(x: xScale, y: yScale, anchor: .center)
            .blur(radius: blurRadius)
            .opacity(opacity)
            .compositingGroup()
    }

    private func normalizedDelta(_ delta: CGFloat, relativeTo target: CGFloat) -> CGFloat {
        guard target > 0 else { return 0 }
        return min((delta / target) / Metrics.maxNormalizedDelta, 1)
    }
}

extension AppState {
    /// DynamicNotch's contentTransition selection: expanded presentations
    /// get notchExpanded, compact ones notchCompact, both driven by
    /// spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)
    /// (expandLiveActivityContentTransition / openContentTransition /
    /// closeLiveActivityContentTransition are all that value in balanced).
    var contentTransition: AnyTransition {
        let spring = Animation.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)
        if isExpandedForm {
            let t = AnyTransition.notchExpanded(notchHeight: surfaceSize.height, baseHeight: dnBaseSize.height)
            return .asymmetric(insertion: t.animation(spring), removal: t.animation(spring))
        }
        let t = AnyTransition.notchCompact(
            notchWidth: surfaceSize.width, notchHeight: surfaceSize.height,
            baseWidth: dnBaseSize.width, baseHeight: dnBaseSize.height)
        return .asymmetric(insertion: t.animation(spring), removal: t.animation(spring))
    }

    /// Extra insets so content clears the shape's concave flare: content
    /// starts ~16 pt inside the shape body on expanded states (the state
    /// views carry their own ~20 pt padding on top of the body inset).
    var contentInsetH: CGFloat {
        switch presentation {
        case .idle: return 0
        case .minimal, .preparing, .waiting: return 2
        case .card: return 18
        default: return 20
        }
    }
    var contentInsetTop: CGFloat {
        switch presentation {
        case .confirm, .expandedTransfer, .home, .peerPicker, .pinEntry, .dropOverlay: return 8
        default: return 0
        }
    }
}

/// Root view: DynamicNotch's NotchView layout - a top-anchored ZStack
/// filling the fixed canvas, surface centered horizontally at the top.
struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            SurfaceView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// DynamicNotch's surface assembly (NotchSurfaceContainerView +
/// NotchInteractiveBodyView): black shape + stroke overlay, content
/// masked by the shape (radii - 2, inset 5 horizontal / 3 bottom),
/// press squeeze anchored at the top, shadow only when tall, and the
/// +1 pt downward offset that cancels the window's +1 pt lift so the
/// visible shape is exactly flush with the screen top.
struct SurfaceView: View {
    @EnvironmentObject var state: AppState

    private var shape: NotchShape {
        NotchShape(topCornerRadius: state.surfaceRadiusTop,
                   bottomCornerRadius: state.surfaceRadiusBottom)
    }
    private var maskShape: NotchShape {
        NotchShape(topCornerRadius: max(0, state.surfaceRadiusTop - 2),
                   bottomCornerRadius: max(0, state.surfaceRadiusBottom - 2))
    }
    private var strokeOn: Bool { state.presentation != .idle }
    private var squeeze: CGFloat { state.isExpandedForm ? 1 : state.pressScale }

    var body: some View {
        ZStack {
            shape
                .fill(Color.black)
                .overlay {
                    shape.stroke(strokeOn ? Color.white.opacity(0.12) : .clear, lineWidth: 2)
                }
            content
                .mask {
                    maskShape
                        .padding(.horizontal, 5)
                        .padding(.bottom, 3)
                }
        }
        .frame(width: state.surfaceSize.width, height: state.surfaceSize.height)
        .scaleEffect(x: squeeze, y: squeeze, anchor: .top)
        .shadow(
            color: state.surfaceSize.height >= state.dnBaseSize.height + 30
                ? Color.black.opacity(0.1) : .clear,
            radius: 20)
        .offset(y: 1)
        // DynamicNotch binds strokeVisibility (spring 0.50, blend 1.0) to
        // the stroke's visibility.
        .animation(.spring(response: 0.50, blendDuration: 1.0), value: strokeOn)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch state.presentation {
            case .idle: IdleView()
            case .home: HomeView()
            case .confirm: ConfirmView()
            case .minimal: MinimalView()
            case .expandedTransfer: ExpandedTransferView()
            case .preparing: PreparingView()
            case .waiting: WaitingView()
            case .pinEntry: PinView(entry: state.pinEntry)
            case .peerPicker: PeerPickerView()
            case .dropOverlay: DropOverlayView()
            case .card: CardView()
            }
        }
        .padding(.horizontal, state.contentInsetH)
        .padding(.top, state.contentInsetTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ResizeAwareBlurModifier(size: state.surfaceSize, baseHeight: state.dnBaseSize.height))
        .id(state.presentation)
        .transition(state.contentTransition)
    }
}

// MARK: - Idle (exactly the physical notch; invisible)

struct IdleView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Color.black
            .contentShape(Rectangle())
            .onTapGesture { state.notchClicked() }
    }
}

// MARK: - M02 / M10 minimal live activity

struct MinimalView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let s = state.session {
            HStack(spacing: 10) {
                Image(systemName: s.direction == "receive" ? "arrow.down" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.blue)
                    .overlay(Image(systemName: "tray").font(.system(size: 15)).foregroundColor(Theme.blue).offset(y: 6))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(s.direction == "receive"
                             ? (s.currentFile?.name ?? "")
                             : "Ke \(s.peerAlias): \(s.currentFile?.name ?? "")")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((s.fraction * 100).rounded()))%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text)
                    }
                    ProgressBar(fraction: s.fraction, color: Theme.blue)
                }
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            // Expansion is driven by the panel-level NSTrackingArea +
            // AppState.hovering; a click pins it open (see notchClicked()).
            .onTapGesture { state.notchClicked() }
        }
    }
}

struct ProgressBar: View {
    var fraction: Double
    var color: Color = Theme.blue
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(Color(red: 0.227, green: 0.227, blue: 0.235))
                RoundedRectangle(cornerRadius: height / 2).fill(color)
                    .frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - M03 / M11 expanded transfer

struct ExpandedTransferView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let s = state.session {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.direction == "receive"
                             ? "Menerima\(s.peerAlias.isEmpty ? "" : " dari \(s.peerAlias)")"
                             : "Mengirim\(s.peerAlias.isEmpty ? "" : " ke \(s.peerAlias)")")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(Theme.text)
                        Text(subline(s))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.sub)
                    }
                    Spacer()
                    Text("\(Int((s.fraction * 100).rounded()))%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                }
                ProgressBar(fraction: s.fraction)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(s.files) { f in
                        FileRow(f: f)
                        if f.id != s.files.last?.id { Divider().background(Theme.divider) }
                    }
                }
                .padding(.top, 6)
                Button(action: { state.cancelActive() }) {
                    Text("Batalkan transfer")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.red)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ghost))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .contentShape(Rectangle())
            // Collapse on mouse-exit is handled centrally: panel tracking
            // area -> AppState.hoverChanged(false) with a 0.25 s grace.
        }
    }

    private func subline(_ s: SessionState) -> String {
        var parts = ["\(fmtBytes(s.aggregateDone)) dari \(fmtBytes(s.totalSize))"]
        let r = fmtRate(s.rate)
        if !r.isEmpty { parts.append(r) }
        if s.rate > 0, s.aggregateDone < s.totalSize {
            parts.append(fmtETA(Double(s.totalSize - s.aggregateDone) / s.rate))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct FileRow: View {
    var f: TransferFile
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(f.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                if f.status == "done" {
                    Text("Selesai").font(.system(size: 11.5)).foregroundColor(Theme.green)
                } else if f.status == "verifying" {
                    Text("Memeriksa…").font(.system(size: 11.5)).foregroundColor(Theme.sub)
                } else if f.status == "transferring" {
                    ProgressBar(fraction: f.fraction).frame(width: 220)
                } else {
                    Text("Menunggu giliran").font(.system(size: 11.5)).foregroundColor(Theme.sub)
                }
            }
            Spacer()
            Text(f.status == "done" ? fmtBytes(f.size) : "\(fmtBytes(f.bytesDone)) / \(fmtBytes(f.size))")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.sub)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - M01 confirmation

struct ConfirmView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let p = state.pending {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(p.senderAlias) mau kirim \(p.files.count) file")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Text("Total \(fmtBytes(p.totalSize)), ke Downloads")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.sub)
                    }
                    Spacer()
                    Text(fmtCountdown(state.approvalSecondsLeft))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.amber)
                }
                VStack(spacing: 0) {
                    ForEach(Array(p.files.prefix(3))) { f in
                        ConfirmFileRow(name: f.name, size: f.size, type: f.fileType)
                        Divider().background(Theme.divider)
                    }
                    if p.files.count > 3 {
                        ConfirmFileRow(name: "+\(p.files.count - 3) file lain",
                                       size: p.files.dropFirst(3).reduce(0) { $0 + $1.size },
                                       type: nil)
                    }
                }
                .padding(.top, 10)
                HStack(spacing: 10) {
                    Button(action: { state.rejectPending() }) {
                        Text("Tolak")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ghost))
                    }
                    .buttonStyle(.plain)
                    Button(action: { state.acceptPending() }) {
                        Text("Terima \(p.files.count) file")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.blue))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
    }
}

struct ConfirmFileRow: View {
    var name: String
    var size: UInt64
    var type: String?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: (type?.hasPrefix("image") ?? false) ? "photo" : "doc")
                .font(.system(size: 14))
                .foregroundColor(Theme.sub)
                .frame(width: 18)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            Spacer()
            Text(fmtBytes(size))
                .font(.system(size: 11.5))
                .foregroundColor(Theme.sub)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - M04 / M12 / M13 / M14 cards

struct CardView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let c = state.card {
            switch c.kind {
            case .notice:
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.sub)
                    Text(c.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.sub)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .completedReceive, .completedSend:
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        if !c.subtitle.isEmpty {
                            Text(c.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.sub)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if c.kind == .completedReceive, !c.savedPaths.isEmpty {
                        Button(action: { state.revealInFinder(paths: c.savedPaths) }) {
                            Text("Lihat di Finder")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 32)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.ghost))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            case .failed:
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        if !c.subtitle.isEmpty {
                            Text(c.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.sub)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if c.canRetry {
                        Button(action: { state.retryFailed() }) {
                            Text("Kirim ulang")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 32)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.ghost))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - M05 drop overlay

struct DropOverlayView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.tray")
                .font(.system(size: 26))
                .foregroundColor(Theme.text)
            Text("Lepas buat kirim \(state.dropCount) file")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("total \(fmtBytes(state.dropTotal))")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.sub)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundColor(Color(red: 0.282, green: 0.282, blue: 0.290))
                .padding(10)
        )
    }
}

// MARK: - M06 peer picker

struct PeerPickerView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Kirim \(state.pickerPaths?.count ?? 0) file ke…")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(Theme.text)
                Spacer()
                Text(fmtBytes(state.pickerPathsTotal))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.sub)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.ghost))
            }
            if state.peers.isEmpty {
                Text("Tidak ada device di jaringan ini")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.sub)
                    .padding(.vertical, 16)
                Button(action: { state.client.command(["type": "rescan"]); state.refresh() }) {
                    Text("Pindai ulang")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 17).fill(Theme.ghost))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 2) {
                    ForEach(state.peers) { peer in
                        PeerRow(peer: peer) {
                            if let paths = state.pickerPaths {
                                state.startSend(peer: peer, paths: paths)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                Button(action: { state.pickerPaths = nil; state.refresh() }) {
                    Text("Batal")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ghost))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

struct PeerRow: View {
    var peer: Peer
    var action: () -> Void
    var body: some View {
        Button(action: { if peer.isOnline { action() } }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(peer.isOnline ? Theme.green : Color(red: 0.388, green: 0.388, blue: 0.400))
                    .frame(width: 8, height: 8)
                Image(systemName: peer.symbol)
                    .font(.system(size: 18))
                    .foregroundColor(Theme.text)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.alias)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(peer.isOnline ? peer.metaLine : "Terakhir terlihat \(relSeen(peer.lastSeen))")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.sub)
                }
                Spacer()
                if peer.isOnline {
                    Text("Kirim").font(.system(size: 12)).foregroundColor(Theme.sub)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(peer.isOnline ? 1 : 0.42)
    }
}

func relSeen(_ epoch: UInt64) -> String {
    let now = UInt64(Date().timeIntervalSince1970)
    let d = now >= epoch ? now - epoch : 0
    if d < 60 { return "barusan" }
    if d < 3600 { return "\(d / 60) menit lalu" }
    return "\(d / 3600) jam lalu"
}

// MARK: - M07 preparing / M08 waiting

struct PreparingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).colorScheme(.dark)
            VStack(alignment: .leading, spacing: 1) {
                Text("Menyiapkan file…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text(state.pendingSend.map { "\($0.paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""), menghitung checksum" } ?? "")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.sub)
                    .lineLimit(1)
            }
            Spacer()
            MiniCancelButton()
        }
        .padding(.horizontal, 16)
    }
}

struct WaitingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 15))
                .foregroundColor(Theme.sub)
            VStack(alignment: .leading, spacing: 1) {
                Text("Menunggu \(state.pendingSend?.peer.alias ?? "peer") menerima…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(state.pendingSend.map { "\($0.paths.count) file, \(fmtBytes($0.pathsTotal))" } ?? "")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.sub)
            }
            Spacer()
            MiniCancelButton()
        }
        .padding(.horizontal, 16)
    }
}

struct MiniCancelButton: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Button(action: { state.cancelActive() }) {
            Text("Batal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ghost))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - M09 PIN entry

// NOTE: @State/@FocusState are macros whose plugin (SwiftUIMacros) is NOT
// shipped with Command Line Tools, so PIN state lives in an ObservableObject.
final class PinEntryModel: ObservableObject {
    @Published var pin: String = ""
}

struct PinView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var entry: PinEntryModel
    private var pin: String { entry.pin }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(state.pinContext?.peer.alias ?? "Peer") minta PIN")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("PIN yang diatur di device tujuan, lalu Enter buat kirim ulang")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.sub)
                }
            }
            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { i in
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.field)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(i == pin.count ? Theme.blue : Color(red: 0.227, green: 0.227, blue: 0.235), lineWidth: 1))
                                .frame(width: 44, height: 52)
                            if i < pin.count {
                                Text(String(Array(pin)[i]))
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(Theme.text)
                            }
                        }
                    }
                }
                TextField("", text: $entry.pin)
                    .textFieldStyle(.plain)
                    .opacity(0.03)
                    .onSubmit { if !pin.isEmpty { state.submitPin(pin) } }
            }
            .padding(.top, 14)
            HStack(spacing: 10) {
                Button(action: { state.cancelPin() }) {
                    Text("Batal")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ghost))
                }
                .buttonStyle(.plain)
                Button(action: { if !pin.isEmpty { state.submitPin(pin) } }) {
                    Text("Kirim dengan PIN")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.blue))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .onAppear { entry.pin = "" }
    }
}

// MARK: - M15 last-transfer row

/// Two-line summary of the most recent finished transfer: file name,
/// then direction + size + time. A completed receive with saved files
/// gets a Finder action; failed/cancelled rows carry their outcome icon.
struct LastTransferRow: View {
    @EnvironmentObject var state: AppState
    var last: LastTransfer

    private var icon: (name: String, color: Color) {
        switch last.outcome {
        case .completed: return ("checkmark.circle", Theme.green)
        case .cancelled: return ("xmark.circle", Theme.sub)
        case .failed: return ("exclamationmark.circle", Theme.red)
        }
    }

    private var line1: String {
        if last.outcome == .failed, !last.title.isEmpty { return last.title }
        if let first = last.fileNames.first {
            return last.fileNames.count > 1
                ? "\(first) +\(last.fileNames.count - 1) file lain"
                : first
        }
        if !last.title.isEmpty { return last.title }
        return "Transfer terakhir"
    }

    private var line2: String {
        var parts: [String] = []
        if !last.peerAlias.isEmpty {
            parts.append(last.direction == "receive" ? "dari \(last.peerAlias)" : "ke \(last.peerAlias)")
        }
        if last.totalSize > 0 { parts.append(fmtBytes(last.totalSize)) }
        parts.append(fmtClock(last.finishedAt))
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.name)
                .font(.system(size: 15))
                .foregroundColor(icon.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(line1)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(line2)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.sub)
                    .lineLimit(1)
            }
            Spacer()
            if last.outcome == .completed, last.direction == "receive",
               !last.savedPaths.isEmpty {
                Button(action: { state.revealInFinder(paths: last.savedPaths) }) {
                    Text("Lihat di Finder")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.ghost))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - M15 home (+ M16 trouble block)

struct HomeView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Single status system: dot + title + subtitle. (The old
            // "Daemon jalan" chip repeated the same fact a third time.)
            HStack(spacing: 10) {
                Circle()
                    .fill(state.connected ? Theme.green : Theme.amber)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.connected ? "NotchSend aktif" : "Tidak bisa menerima file")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(state.connected
                         ? "Terlihat sebagai \"\(state.daemonAlias)\" di jaringan ini"
                         : "Daemon tidak terhubung")
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.sub)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: { state.closeHome() }) {
                    Text("Tutup")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 15).fill(Theme.ghost))
                }
                .buttonStyle(.plain)
            }

            if !state.connected {
                // M16
                VStack(alignment: .leading, spacing: 8) {
                    Text("Jalankan daemon buat mulai menerima dan mengirim file. Mengirim dan menerima dua-duanya butuh daemon.")
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.sub)
                    HStack(spacing: 10) {
                        Button(action: { DaemonLauncher.launch() }) {
                            Text("Jalankan daemon")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(RoundedRectangle(cornerRadius: 17).fill(Theme.blue))
                        }
                        .buttonStyle(.plain)
                        Button(action: { DaemonLauncher.openLog() }) {
                            Text("Buka log daemon")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(RoundedRectangle(cornerRadius: 17).fill(Theme.ghost))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 12)
            }

            if state.connected {
                // Online peers first, stable within each group (filter
                // preserves order); offline rows dim as a whole.
                let ordered = state.peers.filter { $0.isOnline } + state.peers.filter { !$0.isOnline }
                VStack(spacing: 0) {
                    ForEach(ordered.prefix(5)) { peer in
                        HStack(spacing: 10) {
                            Circle().fill(peer.isOnline ? Theme.green : Color(red: 0.388, green: 0.388, blue: 0.400))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(peer.alias)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.text)
                                Text(peer.isOnline ? "\(peer.metaLine), terlihat \(relSeen(peer.lastSeen))"
                                                   : "Terakhir terlihat \(relSeen(peer.lastSeen))")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(Theme.sub)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(action: { pickFiles(for: peer) }) {
                                Text("Kirim file")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 36)
                                    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.blue))
                            }
                            .buttonStyle(.plain)
                            .disabled(!peer.isOnline)
                        }
                        .padding(.vertical, 10)
                        .opacity(peer.isOnline ? 1 : 0.45)
                        if peer.fingerprint != ordered.prefix(5).last?.fingerprint {
                            Divider().background(Theme.divider)
                        }
                    }
                    if let last = state.lastTransfer {
                        LastTransferRow(last: last)
                    }
                }
                .padding(.top, 8)

                // Drop hint: discoverability for M05 drag & drop. A plain
                // dashed outline with no fill and no action, deliberately
                // not button-shaped.
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.sub)
                    Text("Tarik file ke notch buat kirim cepat")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.sub)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundColor(Color(red: 0.282, green: 0.282, blue: 0.290))
                )
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private func pickFiles(for peer: Peer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            let paths = panel.urls.map { $0.path }
            if !paths.isEmpty {
                state.startSend(peer: peer, paths: paths)
            }
        }
    }
}

// MARK: - Daemon launcher (M16 action)

enum DaemonLauncher {
    static var daemonBinary: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("notchsend/target/debug/notchsendd").path
    }
    static func exists() -> Bool { FileManager.default.isExecutableFile(atPath: daemonBinary) }

    static func launch() {
        guard exists() else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: daemonBinary)
        p.arguments = [
            "--alias", "Rivaldi's MacBook Air",
            "--port", "53317",
            "--download-dir", "\(home)/Downloads",
            "--data-dir", "\(home)/.notchsend",
            "--socket-path", "\(home)/.notchsend/daemon.sock",
            "--approval-timeout-secs", "120",
        ]
        p.standardOutput = FileHandle(forWritingAtPath: "\(home)/.notchsend/daemon.log")
        p.standardError = p.standardOutput
        try? p.run()
        Log.line("DAEMON launched via M16 button")
    }

    static func openLog() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.notchsend/daemon.log"))
    }
}
