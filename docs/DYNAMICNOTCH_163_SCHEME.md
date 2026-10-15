# DynamicNotch v1.6.3 - Drawing, UI & Animation Scheme

Extracted 2026-10-13 from the exact v1.6.3 tag (commit `deacd0f4`,
worktree `~/DynamicNotch-1.6.3` on the Mac; main clone `~/DynamicNotchSrc`
left untouched at HEAD `55b99702`). Every value below names its source
file. This is the reference for the NotchSend port: radii, springs and the
drawing model are copied verbatim; deviations are listed in §8.

Machine context used for the worked numbers: MacBook Air M2 built-in
display, `NSScreen.frame` = 1470×956 pt, physical notch 179×32 pt
(`auxiliaryTopLeftArea.width` = 645.5, `safeAreaInsets.top` = 32).

---

## 1. Window scheme - fixed canvas, window never resizes

Source: `DynamicNotch/Application/AppDelegate/AppDelegate+Window.swift`,
`DynamicNotch/Application/Windows/OverlayWindowLayout.swift`,
`DynamicNotch/Application/Panels/OverlayPanelFactory.swift`,
`DynamicNotch/Application/Panels/OverlayPanelWindow.swift`,
`DynamicNotch/Application/Windows/OverlayWindowLevel.swift`.

- **One fixed-size window.** The panel is created once with
  `OverlayWindowLayout.appCanvasSize = CGSize(width: 1000, height: 1000)`.
  The window frame is never animated: `updateWindowFrame()` re-anchors it
  with `window.setFrame(targetFrame, display: true, animate: false)` and
  the *same* size. All open/close motion happens **inside** the window,
  in SwiftUI. (This is the opposite of the old NotchSend design, which
  spring-animated the window frame at 120 Hz.)
- **Anchor:** `OverlayWindowLayout.topAnchoredFrame(on:size:yOffset: 1)`:
  `x = floor(screen.frame.midX − size.width/2)`,
  `y = screen.frame.maxY − size.height + 1`.
  The default `yOffset = 1` lifts the window 1 pt above the screen top;
  the content then offsets itself back down by 1 pt (§4), so the visible
  shape lands exactly flush. Worked numbers here: window frame
  (235, −43, 1000×1000).
- **Panel class:** `OverlayPanelWindow: NSPanel` overriding
  `canBecomeKey`, `canBecomeMain`, `isKeyWindow`, `isMainWindow` → all true.
- **Style mask:** `[.borderless, .nonactivatingPanel]`, backing `.buffered`,
  `defer: false`.
- **Configuration** (`OverlayPanelFactory.configure`):
  `isReleasedWhenClosed = false`, `isFloatingPanel = true`,
  `isOpaque = false`, `backgroundColor = .clear`,
  `hidesOnDeactivate = false`, `isMovable = false`, `hasShadow = false`,
  `animationBehavior = .none`, `acceptsMouseMovedEvents = true`.
- **Level:** `OverlayWindowLevel.interactiveNotch = NSWindow.Level.mainMenu + 3`
  (raw 27 - just above the menu bar, *not* screen-saver level).
- **Collection behavior:** `[.canJoinAllSpaces, .stationary, .ignoresCycle]`
  + `.fullScreenAuxiliary`.
- **Content:** an `NSHostingView` filling the window
  (`Features/Notch/Views/NotchHostingView.swift` - plain subclass,
  `acceptsFirstResponder`/`acceptsFirstMouse` true, `hitTest` = super).
  Root view: `ZStack(alignment: .top)` with
  `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`
  (`Features/Notch/Views/NotchView.swift`) - the surface is top-anchored
  and horizontally centered on the canvas.
- **Private API note:** `createNotchWindow()` also calls
  `SkyLightOperator.shared.delegateWindow(window, to: .notchSurface)`
  (SkyLight private framework bridging). See §8 - not replicated.
- **Click-through:** v1.6.3 has *no* explicit `ignoresMouseEvents` and no
  hit-test filtering for this window (the string appears only in an
  unrelated screenshot panel). The window is non-opaque/clear and the only
  hittable SwiftUI surface is the notch shape itself
  (`NotchBackgroundSurface` sets `.contentShape(shape)`), so clicks
  outside the visible shape never land on app content. See §8 for how
  NotchSend guarantees the same contract explicitly.

## 2. Geometry derivation - base size from the physical notch

Sources: `Shared/Extensions/extension+NSScreen.swift`,
`Features/Notch/ViewModels/NotchViewModel.swift` (`updateDimensions`),
`Core/NotchEngine/Models/NotchModel.swift`,
`Core/SettingsEngine/GeneralSettingsStorage.swift` (defaults).

- `NSScreen.notchSize`:
  `width = frame.width − (auxiliaryTopLeftArea.width + auxiliaryTopRightArea.width)`,
  `height = auxiliaryTopLeftArea.height`. `topInset = safeAreaInsets.top`;
  `isDynamicIsland = (topInset == 0)`.
- Screen scale: `scale = max(0.35, screenWidth / 1440)`;
  `widthScale = scale > 1 ? 1 + (scale − 1) × 0.35 : scale`.
  Here: scale = 1.0208, widthScale = 1.0073.
- Base (idle) size, notch screens:
  - `baseWidth = notchSize.width + 14·widthScale + (settings.notchWidth + 2)`
    → 179 + 14.10 + 2 = **195.1 pt**
  - `baseHeight = notchSize.height + settings.notchHeight + 0`
    → **32 pt** (the `+1` adjustment applies only to notchless/island screens)
  - Settings defaults: `notchWidth = 0`, `notchHeight = 0`.
- **Base corner radius:** `NotchModel.cornerRadius` uses
  `baseRadius = baseHeight / 3` → 32/3 ≈ **10.67 pt**.
  No-content and default-content radii (compact *and* expanded default,
  `Core/NotchEngine/Protocols/NotchContentProtocol.swift`):
  `(top: baseRadius − 4, bottom: baseRadius)` → **(6.67, 10.67)**.
- Per-content overrides exist; the file-transfer analog
  (`Features/Download/Content/DownloadNotchContent.swift`):
  compact size = base + (70|90) wide × base height, default radii;
  expanded size = (baseWidth + 150) × (baseHeight + 65),
  **expanded radii (top: 24, bottom: 34)**.
  Other expanded examples: NowPlaying (34, 44) at base+200 × base+160;
  Calendar and DragAndDrop combined (24, 36).
- Interactive size = content size + gesture offsets (swipe stretch,
  focus-close stretch, pulse) - NotchSend has no swipe gestures; only the
  pulse terms exist in the model and are not used.
- Closing is staged for height: when the new height is smaller,
  `stagedNotchHeight` is animated separately with the surface-size
  animation (`NotchViewModel.scheduleStagedHeightUpdate` /
  `applyStagedHeight`), so width and height don't have to settle in the
  same transaction.

## 3. The notch shape path

Source: `Shared/UI/Shapes/NotchShape.swift`,
`Features/Notch/Components/NotchBackgroundSurface.swift`,
`Features/Notch/Components/NotchSurfaceContainerView.swift`.

`NotchShape(topCornerRadius, bottomCornerRadius)` in SwiftUI coordinates
(y down, rect = the drawn surface rect):

1. Start at `(minX, minY)` - the top-left corner, *on* the top edge.
2. **Concave (inverted) top-left fillet:** quad curve to
   `(minX + topR, minY + topR)`, control `(minX + topR, minY)`.
   The shape spans the **full rect width at the top edge** and pinches in
   to the body width `topR` below the edge - this flare is what melts the
   shape into the menu bar beside the physical notch.
3. Straight side down to `(minX + topR, maxY − bottomR)`.
4. **Convex bottom-left corner:** quad curve to
   `(minX + topR + bottomR, maxY)`, control `(minX + topR, maxY)`.
5. Bottom edge to `(maxX − topR − bottomR, maxY)`, mirrored corner and
   side up the right, concave fillet back to `(maxX, minY)`.

Consequences:
- Body width at mid-height = `rect.width − 2·topR`. For the idle rect
  (195.1 wide, topR 6.67): body ≈ 181.8 pt vs the 179 pt physical notch,
  DynamicNotch's idle shape is deliberately a few points wider than the
  hardware notch, flaring at the top.
- `animatableData = AnimatablePair(topCornerRadius, bottomCornerRadius)`
  - **the radii animate in the same transaction as the size**, which is
  what makes the morph look like one continuous material instead of a
  resize plus a radius jump.
- Fill: `.black` (`NotchBackgroundStyle.black` is the only style case).
- Stroke: the same shape stroked on top, `lineWidth: 2.0`
  (`NotchBackgroundSurface` as instantiated by the container), color =
  content `strokeColor` (protocol default `.white.opacity(0.2)`) ×
  settings `notchStrokeOpacity` (default 0.6), so ≈ white at 0.12 opacity.
  Shown only when the stroke setting is on (default
  `notchStrokeEnabled = true`; settings store lists width 2.5) **and**
  `shouldRenderStroke` (content is displayed, or briefly held after
  content hides). Pure idle (no content) → no stroke, plain black.
- **Content mask:** content is clipped by the same shape with radii
  reduced by 2 (`max(0, r − 2)`), `.padding(.horizontal, 5)`,
  `.padding(.bottom, 3)` - content never touches the shape's side or
  bottom edge; the top is unclipped (content may extend into the flare
  zone beside the camera).

## 4. Surface container & content layout

Sources: `Features/Notch/Components/NotchSurfaceContainerView.swift`,
`NotchView.swift` (via `NotchInteractiveBodyView.swift`),
`Core/NotchEngine/Models/NotchTransitionMetrics.swift`,
`Shared/Extensions/extension+AnyTransition.swift`,
`Shared/UI/Modifiers/ResizeAwareBlurModifier.swift`.

- The surface container is `.frame(width: presentedSize.width,
  height: presentedSize.height)` and `.offset(y: isDynamicIsland ? 3 : 1)`
  - **+1 pt down on notch screens**, cancelling the window's +1 lift (§1):
  visible shape top == screen top, exactly.
- **Shadow:** none at base height. When
  `presentedHeight ≥ baseHeight + 30`: `.shadow(color: .black.opacity(0.1),
  radius: 20)` on the container (a SwiftUI shadow, not a window shadow).
- **Press squeeze:** surface, content and mask all get
  `.scaleEffect(pressScale, anchor: .top)` - but not for expanded
  presentations (`shouldApplyPressScale` is false when expanded, when
  presentation-hidden, or for screenshot content). Scale factor:
  **1.08 on notch screens** (1.14 island),
  `Shared/UI/Modifiers/NotchCustomScaleModifier.swift`.
- **"Ears":** compact contents are wider than the base rect region beside
  the notch (e.g. NowPlaying compact = baseWidth + 70 at baseHeight),
  leading/trailing elements render in the flare-extended body left and
  right of the physical camera area, all inside the one black shape.
- Forced dark appearance: `.environment(\.colorScheme, .dark)` on the
  interactive body.
- **Content transitions** (`contentTransition(...)` in the view model,
  applied per content identity): an `AnyTransition` built on
  `NotchTransitionModifier` (blur + opacity + offsetY + scale, anchor
  `.center`):
  - Compact content: active state blur **15**, opacity 0,
    offsetY = `−(max(0, h − baseH) × 0.75)`,
    scaleX = `compactScaleX` (0.8 when extra width ≤ 70, decreasing to a
    0.2 floor as extra width grows), scaleY = `1 − min(1, extraH/140) × 0.6`.
  - Expanded content: blur **30**, opacity 0, same offsetY,
    insertion scale (0.6, 0.2), removal scaleX 0.4 (notch screens),
    scaleY 0.2.
- **ResizeAwareBlur** (the fluidity ingredient): an `AnimatableModifier`
  whose `animatableData` carries the surface's *animated* size. While the
  surface morphs, content is
  `scaleEffect(animatedSize / targetSize, anchor: .center)`,
  blurred by `progress × 20` and faded by `1 − progress × 0.9`, where
  `progress = max over axes of min((|Δ| / target) / 0.1, 1)`.
  Content therefore stretches and softens *with* the shape instead of
  reflowing in discrete jumps, then sharpens at the target.
  (`Metrics`: maxBlurRadius 20, maxNormalizedDelta 0.1,
  maxOpacityReduction 0.9.)

## 5. Animation parameters - the `balanced` preset, verbatim

Source: `Features/Notch/NotchAnimations.swift` (the only preset,
`NotchAnimationPreset.balanced`). Constants: `baseResponse = 0.50`,
`damping = 0.75`, `expandDamping = 0.75`, `blend = 1.0`,
`hideShowDelay = 0.32`, `queuePacingDelay = 0.1`.

| Animation | Value |
|---|---|
| contentUpdate | `.spring(response: 0.50, blendDuration: 1.0)` - dampingFraction omitted ⇒ SwiftUI default 0.825 |
| contentHide | `.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)` |
| contentShow | `.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)` |
| openContentTransition | `.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)` |
| expandLiveActivity | `.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)` |
| expandLiveActivityContentTransition | `.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)` |
| closeLiveActivity | `.spring(response: 0.50, blendDuration: 1.0)` (default damping) |
| closeLiveActivityContentTransition | `.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 1.0)` |
| stretchReset / strokeVisibility / notchVisibility / focusCloseStretch | `.spring(response: 0.50, blendDuration: 1.0)` (default damping) |

Mechanism (source: `Core/NotchEngine/NotchEngine.swift`,
`Features/Notch/ViewModels/NotchViewModel.swift`):

- **Every state mutation is wrapped at the mutation site** in
  `withAnimation(animations.<specific>)` (contentUpdate for content
  swaps, expandLiveActivity for expansion, closeLiveActivity for closing,
  contentHide/contentShow for visibility). Views then animate frame,
  shape radii and content in that one transaction. A few view-level
  `.animation(...)` bindings exist (strokeVisibility → stroke on/off,
  notchVisibility → showNotch, contentHide → fullscreen-hide).
- The surface-size animation used directly is
  `surfaceSizeAnimation = animations.contentUpdate` (nil during swipe).
- Geometry recomputation (`updateDimensions`) is wrapped in
  `.interactiveSpring(response: 0.25, dampingFraction: 0.85)`.
- Expansion sequencing (`ExpansionTransitionTiming`): 16 ms preparation
  delay before the engine processes the tap, 120 ms before the
  "expanding" flag resets.
- Press animation: `withAnimation(.easeOut(duration: pressHoldDuration))`
  to the scale factor, then `.easeOut(duration: 0.25)` back to 1.
  Hover animation: `.easeOut(duration: min(0.25, notchHoverExpandDelay))`
  to the factor; reset on leave with `.easeOut(duration: 0.12)`.
- Pulse: size += (30, 10) with `.spring(response: 0.4,
  dampingFraction: 0.55, blendDuration: 0)`, reset after 0.12 s with
  `.spring(response: 0.4, dampingFraction: 0.65, blendDuration: 0)`;
  radii grow by `pulseHeight × 0.3` while pulsed.
- There is **no custom frame animator and no display-link integrator**
  anywhere in the scheme - fluidity comes from SwiftUI springs on the
  in-window surface plus ResizeAwareBlur, which is exactly what the old
  NotchSend 120 Hz window-frame integrator could not reproduce.

## 6. Hover / press behaviour in v1.6.3

Source: `Shared/UI/Modifiers/NotchCustomScaleModifier.swift`,
`ApplicationSettingsStore.swift`, `GeneralSettingsStorage.swift`.

- Hover is handled by `.onHover` inside the pressable modifier on the
  surface (hit bounds = the presented size rect), not by a window-level
  tracking area.
- Defaults: tap-to-expand **on**; expand interaction registered default
  `pressAndHold` in the storage defaults dictionary (the settings store's
  property wrapper falls back to `.hover`); collapse interaction default
  `.click` (i.e. hover-leave collapse is *off* by default);
  `notchPressHoldDuration = 0.25` (range 0.20–0.60); hover haptics default
  **off**.
- On hover enter (when hover expansion applies): the squeeze starts
  immediately (`startHoverAnimation`, above), expansion itself is
  scheduled after `notchHoverExpandDelay` (= pressHoldDuration, 0.25 s),
  with an optional `.levelChange` haptic.
- Hover-leave collapse (only when collapse interaction = hoverLeaves):
  delayed so at least 0.5 s passes since expansion, then 0.05 s; it
  re-checks the real mouse location against the active notch rect before
  collapsing.

## 7. Worked numbers for this machine (1470×956, notch 179×32)

- Window: frame (235, −43) size 1000×1000, level mainMenu+3.
- Idle surface: 195.1 × 32, radii (6.67, 10.67), body width ≈ 181.8,
  visible top at screen top (window +1 lift, content +1 offset).
- baseRadius = 10.67; expanded-transfer radii (24, 34).

## 8. Port notes - what NotchSend does differently, and why

- **Hover timing (owner-locked behaviour, kept):** NotchSend expands
  *immediately* on hover enter and collapses after a 0.25 s exit grace
  (owner requirement from the first build), instead of v1.6.3's 0.25 s
  hover delay and click-collapse default. The squeeze values, springs,
  radii and drawing are v1.6.3's; only the trigger timing is NotchSend's.
- **Hit region:** v1.6.3 relies on the non-opaque window + SwiftUI
  contentShape. NotchSend implements the same contract explicitly: the
  panel's container view returns a hit only inside the current visible
  shape rect (updated whenever the presented size changes), so the menu
  bar and apps behind stay clickable everywhere else on the 1000×1000
  canvas, and drag & drop targets only the shape.
- **SkyLight delegation not replicated:** `SkyLightOperator` uses the
  private SkyLight framework (window-server surface delegation for
  lock-screen/fullscreen presentation). It has no effect on the drawing,
  radii or animation scheme; the swiftc single-module build does not link
  private frameworks. Practical impact: presentation over the lock screen
  (not a NotchSend feature) is absent; fullscreen behaviour relies on
  `.fullScreenAuxiliary` as before.
- **Content sizes are NotchSend's own** (mockups M01–M16 were approved
  with their own layouts). They are expressed as DynamicNotch-style
  surface rects: compact states use the default radii formula
  `(baseHeight/3 − 4, baseHeight/3)`; expanded states use the Download
  content's expanded radii (24, 34); the drop overlay uses DragAndDrop's
  (24, 36). Content is additionally inset by the mask scheme of §3 and by
  the top-flare clearance (content top starts below the concave fillet).
- **Engine scheduling not ported:** hideShowDelay 0.32 / queuePacingDelay
  0.1 belong to DynamicNotch's multi-content queue; NotchSend's state
  machine (blueprint priority order) keeps its own timings.
- Swipe gestures, focus-close stretch and the notch pulse exist in
  v1.6.3's model but have no NotchSend counterpart and were not ported.
- Panel configuration order matters (found during the port, verified in
  the launch log): `isFloatingPanel = true` must be assigned *before*
  `level`, exactly as in `OverlayPanelFactory.configure` - assigning it
  afterwards makes AppKit reset the level to floating (3) instead of
  mainMenu + 3 (27).

## 9. Owner-directed deviations (2026-10-15, Batch 2 neck fix)

The owner reviewed a photograph of the M15 home panel on the real
machine and judged that, despite the verbatim v1.6.3 radii, the panel
still read as a plain widened black box rather than an extension of
the physical notch. Three deliberate deviations from §2/§8 were made
on his order; everything else (window scheme, springs, transitions,
compact-state radii, drop overlay radii) stays exactly v1.6.3.

- **Home width 608 → 560 pt** (`surfaceSizeFor(.home)`): the first
  build's M15 width. The wider rect's long, flat top edge is what made
  the panel read as a box; other states keep their widths.
- **Large expanded top radius 24 → 30** (`radiiFor` for home, confirm,
  peerPicker, expandedTransfer): deepens the concave top flare so the
  neck connecting the shape to the screen edge is visible at reading
  distance. Bottom radius stays 34; card and PIN keep (24, 34).
- **Content top padding 14 → 18** in the same four large states, so
  the first content row clears the deeper flare.

These are presentation values, not scheme changes: the shape still
grows symmetrically from the notch anchor, and the launch log's
shapeRect verification (centerXdiff 0.0, topGap 0.0) still applies.
