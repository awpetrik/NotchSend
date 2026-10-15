import AppKit
import SwiftUI
import Combine

// NotchSend: menu-bar agent whose only window follows DynamicNotch
// v1.6.3's windowing scheme exactly (DYNAMICNOTCH_163_SCHEME.md §1):
//
// - ONE fixed-size window: a 1000x1000 canvas, anchored top-center on the
//   notch screen with OverlayWindowLayout.topAnchoredFrame (yOffset = 1).
//   The window frame NEVER moves or resizes after creation; all motion is
//   the SwiftUI surface inside it (size + corner radii spring together).
// - The visible black shape is centered on the canvas, so its centerX is
//   the screen's centerX == the physical notch's centerX, and the
//   surface's +1 pt downward offset (Views.swift) cancels the window's
//   +1 pt lift, so the shape's top lands exactly on the screen's top edge.
//   Both diffs are computed and logged at launch (must be 0.0).
// - The container view hit-tests ONLY inside the current visible shape
//   rect, so the menu bar and apps behind stay clickable everywhere else
//   on the canvas, and drag & drop targets only the shape.

struct NotchGeometry {
    let screenFrame: NSRect
    let leftArea: NSRect
    let rightArea: NSRect
    let safeTop: CGFloat
    let notchRect: NSRect

    var centerX: CGFloat { notchRect.midX }
    var topY: CGFloat { screenFrame.maxY }

    /// The visible shape's rect on screen for a given surface size:
    /// centered on the notch center, top flush with the screen top.
    func shapeRectOnScreen(size: CGSize) -> NSRect {
        NSRect(x: centerX - size.width / 2, y: topY - size.height,
               width: size.width, height: size.height)
    }

    static func compute() -> NotchGeometry? {
        let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil })
            ?? NSScreen.main
        guard let screen = screen else { return nil }
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let notchWidth = screen.frame.width - (left.width + right.width)
        let notchHeight = left.height > 0 ? left.height : screen.safeAreaInsets.top
        guard notchWidth > 0, notchHeight > 0 else { return nil }
        let rect = NSRect(
            x: screen.frame.minX + left.width,
            y: screen.frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        return NotchGeometry(
            screenFrame: screen.frame, leftArea: left, rightArea: right,
            safeTop: screen.safeAreaInsets.top, notchRect: rect
        )
    }
}

/// DynamicNotch's OverlayPanelWindow overrides, verbatim.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// NSView that fills the fixed canvas: owns drag & drop, hover tracking
/// and hit-testing - all scoped to the CURRENT VISIBLE SHAPE rect, which
/// the delegate updates whenever AppState.surfaceSize changes.
final class DropContainerView: NSView {
    var state: AppState?
    private var dragDepth = 0
    /// Shape rect in this view's coordinates (AppKit, y up). The canvas is
    /// 1000x1000; the shape hangs from the top, its top edge 1 pt below
    /// the canvas top (the surface's +1 offset in Views.swift).
    private(set) var shapeRect: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setShapeRect(_ rect: NSRect) {
        shapeRect = rect
        rebuildTrackingAreas()
    }

    // MARK: Hit testing - only the visible shape is interactive. Points
    // elsewhere on the canvas return nil, so the event falls through to
    // the menu bar / the app behind (this is also what scopes drag & drop
    // targeting to the shape).

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shapeRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Hover tracking - an explicit tracking area matching the shape
    // rect (not the whole canvas), rebuilt on every size change. The view
    // frame itself never changes in the fixed-canvas scheme, so
    // updateTrackingAreas is driven manually via setShapeRect.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingAreas()
    }

    private func rebuildTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        guard shapeRect.width > 0, shapeRect.height > 0 else { return }
        addTrackingArea(NSTrackingArea(
            rect: shapeRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        state?.hoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        state?.hoverChanged(false)
    }

    // MARK: Drag & drop (unchanged behaviour; AppKit only offers drags
    // that hit-test inside the shape rect)

    private func dragURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objs = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts)
        return (objs as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = dragURLs(sender)
        if urls.isEmpty { return [] }
        dragDepth += 1
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let st = self.state else { return }
            st.dropCount = urls.count
            st.dropTotal = urls.reduce(0) { acc, u in
                acc + UInt64(((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            st.dropTargeted = true
            st.refresh()
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragDepth = 0
        DispatchQueue.main.async { [weak self] in
            guard let st = self?.state else { return }
            st.dropTargeted = false
            st.refresh()
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = dragURLs(sender)
        dragDepth = 0
        if urls.isEmpty { return false }
        DispatchQueue.main.async { [weak self] in
            self?.state?.filesDropped(urls)
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var container: DropContainerView!
    var state: AppState!
    var geometry: NotchGeometry!
    var statusItem: NSStatusItem!
    var cancellables = Set<AnyCancellable>()

    /// DynamicNotch: OverlayWindowLayout.appCanvasSize.
    static let canvasSize = CGSize(width: 1000, height: 1000)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("=== NotchSend launching ===")
        guard let geo = NotchGeometry.compute() else {
            Log.line("GEOMETRY FATAL: no notch screen found (auxiliaryTopLeftArea missing)")
            return
        }
        geometry = geo
        Log.line("GEOMETRY screen.frame=\(rectStr(geo.screenFrame)) auxLeft=\(rectStr(geo.leftArea)) auxRight=\(rectStr(geo.rightArea)) safeAreaInsets.top=\(geo.safeTop)")
        Log.line("GEOMETRY notchRect=\(rectStr(geo.notchRect)) notchCenterX=\(geo.centerX) screenTop=\(geo.topY)")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        state = AppState(socketPath: "\(home)/.notchsend/daemon.sock")
        state.notchSize = geo.notchRect.size
        state.screenWidth = geo.screenFrame.width
        Log.line("GEOMETRY dnBaseSize=\(sizeStr(state.dnBaseSize)) dnBaseRadius=\(state.dnBaseRadius)")

        // OverlayWindowLayout.topAnchoredFrame(on:size:yOffset: 1), verbatim:
        //   x = floor(screen.midX - size.width/2)
        //   y = screen.maxY - size.height + 1
        let canvas = AppDelegate.canvasSize
        let frame = NSRect(
            x: floor(geo.screenFrame.midX - canvas.width / 2),
            y: geo.screenFrame.maxY - canvas.height + 1,
            width: canvas.width, height: canvas.height
        )
        panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // OverlayPanelFactory.configure, verbatim values AND order,
        // isFloatingPanel must come before level: assigning it afterwards
        // makes AppKit reset the level to floating (3).
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level.mainMenu + 3 // OverlayWindowLevel.interactiveNotch
        Log.line("GEOMETRY windowFrame=\(rectStr(panel.frame)) level=\(panel.level.rawValue) canvas=\(sizeStr(canvas))")

        container = DropContainerView(frame: NSRect(origin: .zero, size: canvas))
        container.state = state
        let hosting = NSHostingView(rootView: ContentView().environmentObject(state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        // Lay out the idle surface before the first frame is shown, then
        // verify the VISIBLE SHAPE's geometry (not the window's): idle and
        // one expanded size. Diffs must be 0.0.
        state.refresh(animating: false)
        container.setShapeRect(shapeRectInWindow(state.surfaceSize))
        verify(stateName: "idle", size: state.surfaceSize)
        verify(stateName: "expanded-sample(home)", size: state.surfaceSizeFor(.home))
        panel.orderFrontRegardless()

        // The hit/hover region follows the presented surface size.
        state.$surfaceSize
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self = self, size.width > 0, size.height > 0 else { return }
                self.container.setShapeRect(self.shapeRectInWindow(size))
            }
            .store(in: &cancellables)

        setupStatusItem()
        state.start()
        Log.line("=== NotchSend up, panel at notch ===")
    }

    /// Shape rect in window/container coordinates (AppKit, y up): the
    /// shape is horizontally centered on the canvas and hangs from its
    /// top, its top edge 1 pt below the canvas top (the +1 surface offset
    /// in Views.swift, cancelling the window's +1 lift).
    private func shapeRectInWindow(_ size: CGSize) -> NSRect {
        let canvas = AppDelegate.canvasSize
        return NSRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - 1) - size.height,
            width: size.width, height: size.height
        )
    }

    private func verify(stateName: String, size: CGSize) {
        let r = geometry.shapeRectOnScreen(size: size)
        let dx = r.midX - geometry.centerX
        let topGap = geometry.topY - r.maxY
        Log.line("GEOMETRY verify state=\(stateName) shapeRect=\(rectStr(r)) centerXdiff=\(cleanZero(dx)) topGap=\(cleanZero(topGap))")
    }

    /// Sub-micron floating point residue (fractional surface widths like
    /// 195.1) is reported as the 0.0 it physically is.
    private func cleanZero(_ v: CGFloat) -> String {
        abs(v) < 0.0005 ? "0.0" : String(format: "%.4f", v)
    }

    private func rectStr(_ r: NSRect) -> String {
        String(format: "(x=%.1f y=%.1f w=%.1f h=%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }

    private func sizeStr(_ s: CGSize) -> String {
        String(format: "(w=%.1f h=%.1f)", s.width, s.height)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: "NotchSend")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Buka Halaman Notch", action: #selector(openHome), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Berhenti NotchSend", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func openHome() { state.openHome() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
