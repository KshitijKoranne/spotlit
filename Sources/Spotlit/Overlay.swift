import SwiftUI
import AppKit
import Combine
@preconcurrency import ScreenCaptureKit
import CoreImage

struct Ripple: Identifiable {
    let id = UUID()
    let point: CGPoint
    let right: Bool
}

/// Watches the mouse (no permission needed) and keys (via KeyTap).
@MainActor
final class Tracker: ObservableObject {
    @Published var moving = false
    @Published var idle = false
    @Published var clickFlash = false
    @Published var shaking = false
    @Published var holding = false
    @Published var ripples: [Ripple] = []
    @Published var keys: [String] = []
    /// Called on every pointer move, outside SwiftUI, so nothing re-renders per move.
    var onMove: ((CGPoint) -> Void)?

    private var monitors: [Any] = []
    private var flashEnd, keysEnd: Task<Void, Never>?
    private var lastMove: TimeInterval = 0, settleTimer: Timer?
    private var lastX: CGFloat = 0, lastDir: CGFloat = 0, turns: [Date] = []
    private var lastKeyPlain = false, lastKeyTime = Date.distantPast
    private var holdTimer: Timer?

    func start() {
        watch([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in self?.moved() }
        watch([.leftMouseDown, .rightMouseDown]) { [weak self] e in self?.clicked(right: e.type == .rightMouseDown) }
        KeyTap.shared.onKey = { [weak self] in self?.key($0) }
    }

    /// Hold-key mode reads ⌥ without any permission. The poll runs only while hold-key mode is on.
    func watchHold(_ on: Bool) {
        if on, holdTimer == nil {
            holdTimer = repeating(0.05) { [weak self] in
                guard let self else { return }
                let h = NSEvent.modifierFlags.contains(.option)
                if h != self.holding { self.holding = h }
            }
        } else if !on, let t = holdTimer {
            t.invalidate()
            holdTimer = nil
            if holding { holding = false }
        }
    }

    private func watch(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    @discardableResult
    private func after(_ seconds: Double, _ f: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if !Task.isCancelled { f() }
        }
    }

    private func moved() {
        let p = NSEvent.mouseLocation
        onMove?(p)
        lastMove = ProcessInfo.processInfo.systemUptime
        if !moving { moving = true }
        if idle { idle = false }
        // ponytail: one timer for "stopped moving" and "idle"; it moves its own fire date from lastMove.
        if settleTimer == nil { settleTimer = repeating(0.5) { [weak self] in self?.settle() } }
        detectShake(p.x)
    }

    private func settle() {
        let still = ProcessInfo.processInfo.systemUptime - lastMove
        let idleAfter = max(0.5, UserDefaults.standard.double(forKey: "idleDelay"))
        if still >= 0.5, moving { moving = false }
        if still >= idleAfter {
            idle = true
            settleTimer?.invalidate()
            settleTimer = nil
        } else {
            settleTimer?.fireDate = Date(timeIntervalSinceNow: (moving ? 0.5 : idleAfter) - still)
        }
    }

    // ponytail: 4 direction changes in 0.7 s = shake. Tune if it fires too easily.
    private func detectShake(_ x: CGFloat) {
        let dx = x - lastX
        guard abs(dx) > 12 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if lastDir != 0, dir != lastDir {
            let now = Date()
            turns = turns.filter { now.timeIntervalSince($0) < 0.7 } + [now]
            if turns.count >= 4, UserDefaults.standard.bool(forKey: "shake") {
                turns = []
                shaking = true
                after(1.0) { [weak self] in self?.shaking = false }
            }
        }
        lastDir = dir
        lastX = x
    }

    private func clicked(right: Bool) {
        clickFlash = true
        flashEnd?.cancel()
        flashEnd = after(0.7) { [weak self] in self?.clickFlash = false }
        guard UserDefaults.standard.bool(forKey: "clicksOn") else { return }
        let r = Ripple(point: NSEvent.mouseLocation, right: right)
        ripples.append(r)
        after(0.9) { [weak self] in self?.ripples.removeAll { $0.id == r.id } }
    }

    private func key(_ e: NSEvent) {
        guard !e.isARepeat else { return } // a held key shows once
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: [String] = []
        if f.contains(.control) { mods.append("⌃") }
        if f.contains(.option) { mods.append("⌥") }
        if f.contains(.shift) { mods.append("⇧") }
        if f.contains(.command) { mods.append("⌘") }
        let shortcut = f.contains(.command) || f.contains(.control) || f.contains(.option)
        // Plain typing shows what ⇧ types ("A", "!"); named keys keep their ⇧ (⇧ ⇥).
        guard let name = HotKeys.keyName(e, typed: !shortcut) else { return }
        if UserDefaults.standard.string(forKey: "keysMode") == "shortcuts", !shortcut { return }
        let caps = (shortcut || HotKeys.glyphs[e.keyCode] != nil ? mods : []) + [name]

        let now = Date()
        if !shortcut, lastKeyPlain, now.timeIntervalSince(lastKeyTime) < 1.2 {
            keys = Array((keys + caps).suffix(12))
        } else {
            keys = caps
        }
        lastKeyPlain = !shortcut
        lastKeyTime = now
        keysEnd?.cancel()
        keysEnd = after(1.6) { [weak self] in self?.keys = [] }
    }
}

/// Live screen image for the magnifier. Needs Screen Recording permission.
/// Frames arrive and are cropped on a background queue; only the small lens image reaches the main thread.
@MainActor
final class Magnifier: NSObject, ObservableObject {
    @Published var image: CGImage?
    @Published private(set) var allowed = CGPreflightScreenCaptureAccess()
    private var stream: SCStream?
    private var screenFrame: CGRect = .zero
    private var scale: CGFloat = 2
    private var starting = false, on = false

    // Touched only on `frames`.
    private nonisolated let frames = DispatchQueue(label: "in.kjrlabs.spotlit.magnifier")
    private nonisolated(unsafe) var live: SCStream? // frames from any other stream are dropped
    private nonisolated(unsafe) var last: CIImage? // last complete frame; idle frames carry no image
    private nonisolated(unsafe) var lens = CGRect.zero
    private nonisolated let ctx = CIContext(options: [.cacheIntermediates: false])

    /// macOS shows its prompt only once. After that, open System Settings.
    func request() {
        let d = UserDefaults.standard
        if d.bool(forKey: "askedScreen") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            d.set(true, forKey: "askedScreen")
            CGRequestScreenCaptureAccess()
        }
    }

    func start() {
        on = true
        guard stream == nil, !starting else { return }
        let ok = CGPreflightScreenCaptureAccess()
        if allowed != ok { allowed = ok }
        guard ok else {
            if !UserDefaults.standard.bool(forKey: "askedScreen") { request() }
            return
        }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            var delays: [UInt64] = [0, 1, 3] // ponytail: 3 tries in 4 s, then it waits for a settings or display change
            while !delays.isEmpty {
                try? await Task.sleep(nanoseconds: delays.removeFirst() * 1_000_000_000)
                guard on else { return } // stop() ends the retries
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard on else { return }
                    let mouse = NSEvent.mouseLocation
                    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
                          let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    let cfg = SCStreamConfiguration()
                    // ponytail: the whole display at full resolution. A lens-sized sourceRect would need a reconfigure
                    // as the pointer moves; the crop below runs off the main thread and reads back only the lens.
                    cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
                    cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    cfg.showsCursor = false
                    cfg.queueDepth = 3
                    let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []),
                                     configuration: cfg, delegate: self)
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
                    // Set first: the first complete frame, the only one on a static screen, can beat startCapture's return.
                    screenFrame = screen.frame
                    scale = screen.backingScaleFactor
                    stream = s
                    frames.async { self.live = s }
                    crop()
                    try await s.startCapture()
                    if stream === s { return }
                    try? await s.stopCapture() // stop() ran while starting
                    delays.insert(0, at: 0) // so a start() since then retries now, free
                } catch {
                    stream = nil // only this task sets stream while starting
                    NSLog("Spotlit magnifier: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        on = false
        stream?.stopCapture()
        stream = nil
        frames.async { [weak self] in self?.live = nil; self?.last = nil }
        if image != nil { image = nil }
    }

    /// Sets the lens rectangle. Runs per pointer move and settings change; frames reuse it.
    func crop(_ m: CGPoint = NSEvent.mouseLocation) {
        guard stream != nil else { return }
        guard NSMouseInRect(m, screenFrame, false) else { stop(); start(); return } // pointer went to another screen
        let d = UserDefaults.standard
        let n = (d.double(forKey: "magSize") / max(1, d.double(forKey: "magZoom")) * scale).rounded() // whole pixels, no resampling
        let r = CGRect(x: ((m.x - screenFrame.minX) * scale - n / 2).rounded(), y: ((m.y - screenFrame.minY) * scale - n / 2).rounded(),
                       width: n, height: n)
        frames.async { [weak self] in
            self?.lens = r
            self?.render()
        }
    }

    /// On `frames`: renders the lens from the last frame and hands it to the main thread.
    private nonisolated func render() {
        // ponytail: black past this display's edge, even where another display continues.
        guard let last, !lens.isEmpty, let cg = ctx.createCGImage(last.composited(over: CIImage(color: .black)), from: lens) else { return }
        Task { @MainActor [weak self] in
            if let self, self.stream != nil { self.image = cg }
        }
    }
}

extension Magnifier: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ s: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, s === live,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[SCStreamFrameInfo.status] as? Int) == SCFrameStatus.complete.rawValue,
              let pb = buffer.imageBuffer else { return }
        last = CIImage(cvPixelBuffer: pb) // holds one of the 3 queued buffers until the next complete frame
        render()
    }

    nonisolated func stream(_ s: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.stopped(s, error) }
    }

    private func stopped(_ s: SCStream, _ error: Error) {
        guard s === stream else { return }
        NSLog("Spotlit magnifier stopped: \(error.localizedDescription)")
        let worked = image != nil
        stop()
        if (error as? SCStreamError)?.code == .userStopped {
            UserDefaults.standard.set(false, forKey: "magOn") // stopped from the system menu: show it as off
        } else if worked {
            start() // ponytail: only a stream that showed a frame restarts, so one that dies at birth cannot loop
        }
    }
}

/// Per screen, one clear click-through window for the dim, clicks and keys; plus one small window
/// that follows the pointer with the halo and lens. A pointer move only moves that window and the dim layer.
@MainActor
final class Overlay {
    static let shared = Overlay()
    /// The pointer window's side: the largest halo while shaking (160 × 2.4) or lens (360), plus shadows.
    static let span: CGFloat = 440
    let tracker = Tracker()
    let magnifier = Magnifier()
    private var screens: [(window: NSWindow, shade: CALayer, hole: CALayer)] = []
    private let pointer = Overlay.window(CGRect(x: 0, y: 0, width: Overlay.span, height: Overlay.span))
    private var dimOn = false, dimScreen = -2, dimColor = NSColor.clear.cgColor, holeKey = ""
    private var subs: Set<AnyCancellable> = []

    func start() {
        let host = NSHostingView(rootView: PointerView(t: tracker, mag: magnifier, store: .shared))
        host.sizingOptions = []
        pointer.contentView = host
        pointer.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1) // above the screen windows
        tracker.onMove = { [weak self] in self?.moved($0) }
        tracker.start()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        // Sleep ends the capture stream; start a fresh one on wake.
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.magnifier.stop(); self?.sync() }
            }
        }
        // @Published sends before the value is set, so read it on the next run-loop turn.
        Store.shared.$isPro.merge(with: tracker.$holding).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }.store(in: &subs)
        rebuild()
    }

    private static func window(_ frame: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return w
    }

    private func rebuild() {
        screens.forEach { $0.window.close() }
        screens = NSScreen.screens.map { screen in
            let w = Self.window(screen.frame)
            let root = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let shade = NSView(frame: root.bounds) // layer-hosting: the dim is plain layers, moved without redrawing
            shade.layer = CALayer()
            shade.wantsLayer = true
            let hole = CALayer()
            hole.contentsGravity = .center
            hole.contentsScale = screen.backingScaleFactor
            hole.isHidden = true
            shade.layer!.addSublayer(hole)
            let host = NSHostingView(rootView: ScreenView(frame: screen.frame, t: tracker))
            host.sizingOptions = []
            host.frame = root.bounds
            root.addSubview(shade)
            root.addSubview(host)
            w.contentView = root
            w.setFrame(screen.frame, display: false)
            return (w, shade.layer!, hole)
        }
        holeKey = ""
        magnifier.stop() // screens changed; sync() restarts it with the new geometry
        sync()
    }

    /// Matches windows and services to settings. Called on every settings change; each step is cheap.
    private func sync() {
        let d = UserDefaults.standard, store = Store.shared
        let on = d.bool(forKey: "enabled")
        let hold = on && store.on("holdMode")
        tracker.watchHold(hold)
        let held = !hold || tracker.holding
        let dim = on && held && store.on("dimOn")
        let sharing: NSWindow.SharingType = d.bool(forKey: "inRecordings") ? .readOnly : .none
        // Nothing to draw: windows leave the screen, so the window server skips them.
        let screensShown = on && (dim || d.bool(forKey: "clicksOn") || store.on("keysOn"))
        for s in screens { show(s.window, screensShown, sharing) }
        let pointerShown = on && (d.string(forKey: "haloMode") != "never" || d.bool(forKey: "shake") || store.on("magOn"))
        if pointerShown, !pointer.isVisible { place(NSEvent.mouseLocation) }
        show(pointer, pointerShown, sharing)
        on && store.on("keysOn") ? KeyTap.shared.start() : KeyTap.shared.stop()
        on && held && store.on("magOn") ? magnifier.start() : magnifier.stop()
        magnifier.crop() // magZoom and magSize apply without a pointer move
        setDim(dim)
    }

    private func show(_ w: NSWindow, _ on: Bool, _ sharing: NSWindow.SharingType) {
        if w.sharingType != sharing { w.sharingType = sharing }
        if on != w.isVisible { on ? w.orderFrontRegardless() : w.orderOut(nil) }
    }

    private func moved(_ p: CGPoint) {
        if pointer.isVisible { place(p) }
        if dimOn { placeDim(p) }
        magnifier.crop(p) // returns at once unless the magnifier runs
    }

    private func place(_ p: CGPoint) { pointer.setFrameOrigin(CGPoint(x: p.x - Self.span / 2, y: p.y - Self.span / 2)) }

    /// The dim is a solid shade with a clear hole: a small pre-drawn radial image, ringed by a border
    /// wide enough to cover the screen from any pointer spot. Drawn once per setting, then only moved.
    private func setDim(_ on: Bool) {
        let d = UserDefaults.standard
        let r = d.double(forKey: "dimSize"), a = d.double(forKey: "dimAmount")
        dimOn = on
        let key = "\(on) \(r) \(a)"
        guard key != holeKey else { return }
        holeKey = key
        dimColor = NSColor.black.withAlphaComponent(a).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in screens {
            let ring = hypot(s.window.frame.width, s.window.frame.height)
            s.hole.contents = on ? Self.holeImage(radius: r, color: dimColor, scale: s.hole.contentsScale) : nil
            s.hole.bounds = CGRect(x: 0, y: 0, width: 2 * (r + ring), height: 2 * (r + ring))
            s.hole.borderWidth = ring
            s.hole.borderColor = dimColor
            s.hole.isHidden = true
            s.shade.backgroundColor = nil
        }
        CATransaction.commit()
        dimScreen = -2
        if on { placeDim(NSEvent.mouseLocation) }
    }

    /// The hole follows the pointer on its screen; other screens are evenly dimmed.
    private func placeDim(_ p: CGPoint) {
        let i = screens.firstIndex { NSMouseInRect(p, $0.window.frame, false) } ?? -1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if i != dimScreen {
            for (j, s) in screens.enumerated() {
                s.hole.isHidden = j != i
                s.shade.backgroundColor = j == i ? nil : dimColor
            }
            dimScreen = i
        }
        if i >= 0 {
            let o = screens[i].window.frame.origin
            screens[i].hole.position = CGPoint(x: p.x - o.x, y: p.y - o.y)
        }
        CATransaction.commit()
    }

    /// Clear inside 60% of the radius, fading to `color` at the edge and beyond.
    private static func holeImage(radius r: CGFloat, color: CGColor, scale: CGFloat) -> CGImage? {
        let px = Int((2 * r * scale).rounded())
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: nil, colors: [NSColor.clear.cgColor, NSColor.clear.cgColor, color] as CFArray,
                                 locations: [0, 0.6, 1]) else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: .drawsAfterEndLocation)
        return ctx.makeImage()
    }
}

/// Solid hex colors (free ones, or any custom color with PRO), or PRO gradients stored as "g:name".
enum Paint {
    static let free = ["#FFB020", "#FF453A", "#FF2D92", "#34C759", "#0A84FF", "#BF5AF2", "#FFFFFF"]
    static let pro = ["g:sunset", "g:aurora", "g:ocean", "g:candy", "g:prism"]
    static let gradients: [String: [Color]] = [
        "sunset": [Color(hex: "#FFB020"), Color(hex: "#FF5E62"), Color(hex: "#FF2D92")],
        "aurora": [Color(hex: "#7CF7D4"), Color(hex: "#5AA9FF"), Color(hex: "#B57CFF")],
        "ocean": [Color(hex: "#00C6FB"), Color(hex: "#005BEA")],
        "candy": [Color(hex: "#FF9CEE"), Color(hex: "#9CF0FF")],
        "prism": [.red, .orange, .yellow, .green, .blue, .purple],
    ]
    static let defaults = ["haloColor": "#FFB020", "leftColor": "#FFB020", "rightColor": "#0A84FF"]
    /// The color that takes effect: gradients and custom colors need PRO. The stored choice is kept for when PRO returns.
    @MainActor static func effective(_ value: String, _ key: String) -> String {
        Store.shared.isPro || free.contains(value) ? value : defaults[key] ?? free[0]
    }
    static func colors(_ s: String) -> [Color] { gradients[String(s.dropFirst(2))] ?? [Color(hex: s)] }
    static func base(_ s: String) -> Color { colors(s)[0] }
    static func style(_ s: String, _ opacity: Double = 1) -> AnyShapeStyle {
        let c = colors(s).map { $0.opacity(opacity) }
        return c.count == 1 ? AnyShapeStyle(c[0]) : AnyShapeStyle(AngularGradient(colors: c + [c[0]], center: .center))
    }
}

struct HaloShape: Shape {
    let kind: String
    func path(in r: CGRect) -> Path {
        switch kind {
        case "squircle":
            return RoundedRectangle(cornerRadius: r.width * 0.3, style: .continuous).path(in: r)
        case "rhombus":
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
            return p
        default:
            return Circle().path(in: r)
        }
    }
}

/// The halo itself. Also used for previews in Settings and onboarding.
struct HaloView: View {
    let shape: String, size: Double, style: String, color: String, opacity: Double
    var body: some View {
        HaloShape(kind: shape)
            .fill(style == "fill" ? Paint.style(color, opacity) : AnyShapeStyle(Color.clear))
            .overlay(HaloShape(kind: shape).stroke(Paint.style(color, min(1, opacity + 0.5)), lineWidth: style == "fill" ? 1.5 : 3))
            .shadow(color: Paint.base(color).opacity(0.35), radius: 10)
            .frame(width: size, height: size)
    }
}


/// The halo and lens, in the small window that follows the pointer.
struct PointerView: View {
    @ObservedObject var t: Tracker
    @ObservedObject var mag: Magnifier
    @ObservedObject var store: Store
    @AppStorage("haloMode") private var mode = "always"
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"
    @AppStorage("opacity") private var opacity = 0.35
    @AppStorage("magSize") private var magSize = 200.0
    @AppStorage("magShape") private var magShape = "circle"
    @AppStorage("holdMode") private var holdMode = false

    private var haloOn: Bool {
        if t.shaking { return true }
        guard !(holdMode && store.isPro) || t.holding else { return false }
        switch mode {
        case "moving": return t.moving
        case "click": return t.clickFlash
        case "idle": return t.idle
        case "never": return false
        default: return true
        }
    }

    var body: some View {
        ZStack {
            if let img = mag.image { // set only while the magnifier runs, which Overlay.sync decides
                let lens = magShape == "circle" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: magSize, height: magSize)
                    .clipShape(lens)
                    .overlay(lens.stroke(.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            }
            HaloView(shape: shape, size: size, style: style, color: Paint.effective(color, "haloColor"), opacity: opacity)
                .scaleEffect(t.shaking ? 2.4 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: t.shaking)
                .opacity(haloOn ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: haloOn)
        }
        .frame(width: Overlay.span, height: Overlay.span)
        .allowsHitTesting(false)
    }
}

/// Clicks and keys on one screen. Redraws only when they change, never per pointer move.
struct ScreenView: View {
    let frame: CGRect
    @ObservedObject var t: Tracker
    @ObservedObject private var store = Store.shared
    @AppStorage("leftColor") private var leftColor = "#FFB020"
    @AppStorage("rightColor") private var rightColor = "#0A84FF"
    @AppStorage("clickAnim") private var clickAnim = "ripple"
    @AppStorage("keysOn") private var keysOn = false
    @AppStorage("keysPos") private var keysPos = "bottom"
    @AppStorage("keysSize") private var keysSize = 24.0

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }

    var body: some View {
        ZStack {
            ForEach(t.ripples.filter { frame.contains($0.point) }) { r in
                ClickView(paint: r.right ? Paint.effective(rightColor, "rightColor") : Paint.effective(leftColor, "leftColor"),
                          style: store.isPro ? clickAnim : "ripple")
                    .position(local(r.point))
            }
            // ponytail: keycaps show on the pointer's screen as of the last key.
            if keysOn && !t.keys.isEmpty && NSMouseInRect(NSEvent.mouseLocation, frame, false) {
                KeysView(keys: t.keys, size: keysSize)
                    .position(x: frame.width / 2, y: keysPos == "top" ? 120 : keysPos == "center" ? frame.height / 2 : frame.height - 150)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .allowsHitTesting(false)
    }
}

/// Click feedback: ripple (free), pulse, shrink and glitter (PRO).
struct ClickView: View {
    let paint: String
    let style: String
    @State private var go = false
    private static let sparks = (0..<14).map { i in (angle: Double(i) / 14 * 2 * .pi + .random(in: -0.2...0.2), dist: Double.random(in: 34...62), size: Double.random(in: 7...13)) }

    var body: some View {
        ZStack {
            if style == "glitter" {
                ForEach(0..<Self.sparks.count, id: \.self) { i in
                    let s = Self.sparks[i]
                    Image(systemName: "sparkle")
                        .font(.system(size: s.size, weight: .bold))
                        .foregroundStyle(Paint.colors(paint)[i % Paint.colors(paint).count])
                        .offset(x: go ? cos(s.angle) * s.dist : 0, y: go ? sin(s.angle) * s.dist : 0)
                        .scaleEffect(go ? 0.4 : 1.2)
                        .rotationEffect(.degrees(go ? 180 : 0))
                }
                .opacity(go ? 0 : 1)
            } else {
                Circle()
                    .stroke(Paint.style(paint), lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .scaleEffect(go ? end : start)
                    .opacity(go ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: style == "glitter" ? 0.8 : 0.6)) { go = true } }
    }

    private var start: CGFloat { style == "shrink" ? 1.9 : style == "pulse" ? 0.7 : 0.3 }
    private var end: CGFloat { style == "shrink" ? 0.3 : style == "pulse" ? 1.2 : 1.6 }
}

struct KeysView: View {
    let keys: [String]
    var size: Double = 24
    var body: some View {
        HStack(spacing: size / 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, size * 0.58)
                    .frame(minWidth: size * 2, minHeight: size * 2)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: size / 2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size / 2, style: .continuous).strokeBorder(.white.opacity(0.15)))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}


// MARK: Auto-on per app

struct AppRule: Codable, Identifiable, Hashable {
    var id: String { bundle }
    let bundle: String
    let name: String
    var preset: String
    var showInRecordings: Bool
}

/// Turns Spotlit on with a preset while a chosen app is in front. PRO.
@MainActor
final class AutoOn: ObservableObject {
    static let shared = AutoOn()
    @Published var rules: [AppRule] = (try? JSONDecoder().decode([AppRule].self, from: UserDefaults.standard.data(forKey: "appRules") ?? Data())) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "appRules") }
    }
    /// The user's own settings while a rule app is in front. Stored, so quitting there restores them next launch.
    private var saved: [String: Any]? {
        get { UserDefaults.standard.dictionary(forKey: "autoOnSaved") }
        set { UserDefaults.standard.set(newValue, forKey: "autoOnSaved") }
    }

    func start() {
        prune()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.activated(id) }
        }
        activated(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) // the app in front at launch
    }

    /// Anything that names a deleted preset falls back to Default.
    func prune() {
        func gone(_ name: String?) -> Bool { Presets.values(name ?? "") == nil }
        for i in rules.indices where gone(rules[i].preset) { rules[i].preset = "Default" }
        if saved != nil, gone(saved?["preset"] as? String) { saved?["preset"] = "Default" }
        if gone(UserDefaults.standard.string(forKey: "preset")) { UserDefaults.standard.set("Default", forKey: "preset") }
    }

    private func activated(_ id: String?) {
        guard id != Bundle.main.bundleIdentifier else { return }
        let d = UserDefaults.standard
        if Store.shared.isPro, let rule = rules.first(where: { $0.bundle == id }) {
            if saved == nil { saved = Presets.snapshot(extra: ["enabled", "inRecordings", "preset"]) }
            d.set(true, forKey: "enabled")
            Presets.apply(rule.preset)
            d.set(rule.showInRecordings, forKey: "inRecordings")
        } else if let s = saved {
            s.forEach { d.set($1, forKey: $0) }
            saved = nil
        }
    }
}
