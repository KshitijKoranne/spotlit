import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreImage

struct Ripple: Identifiable {
    let id = UUID()
    let point: CGPoint
    let right: Bool
}

/// Watches the mouse (no permission needed) and keys (via KeyTap).
final class Tracker: ObservableObject {
    @Published var point = NSEvent.mouseLocation
    @Published var moving = false
    @Published var idle = false
    @Published var clickFlash = false
    @Published var shaking = false
    @Published var holding = false
    @Published var ripples: [Ripple] = []
    @Published var keys: [String] = []

    private var monitors: [Any] = []
    private var moveStop, idleStart, flashEnd, keysEnd: DispatchWorkItem?
    private var lastX: CGFloat = 0, lastDir: CGFloat = 0, turns: [Date] = []
    private var lastKeyPlain = false, lastKeyTime = Date.distantPast
    private var holdTimer: Timer?

    func start() {
        watch([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in self?.moved() }
        watch([.leftMouseDown, .rightMouseDown]) { [weak self] e in self?.clicked(right: e.type == .rightMouseDown) }
        KeyTap.shared.onKey = { [weak self] in self?.key($0) }
        // Hold-key mode reads ⌥ state without any permission.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, UserDefaults.standard.bool(forKey: "holdMode") else { return }
            let h = NSEvent.modifierFlags.contains(.option)
            if h != self.holding { self.holding = h }
        }
    }

    private func watch(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    @discardableResult
    private func after(_ seconds: Double, _ f: @escaping () -> Void) -> DispatchWorkItem {
        let w = DispatchWorkItem(block: f)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        return w
    }

    private func moved() {
        point = NSEvent.mouseLocation
        if !moving { moving = true }
        if idle { idle = false }
        moveStop?.cancel(); idleStart?.cancel()
        moveStop = after(0.5) { [weak self] in self?.moving = false }
        idleStart = after(max(0.5, UserDefaults.standard.double(forKey: "idleDelay"))) { [weak self] in self?.idle = true }
        detectShake(point.x)
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
        point = NSEvent.mouseLocation
        clickFlash = true
        flashEnd?.cancel()
        flashEnd = after(0.7) { [weak self] in self?.clickFlash = false }
        guard UserDefaults.standard.bool(forKey: "clicksOn") else { return }
        let r = Ripple(point: point, right: right)
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
final class Magnifier: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var image: CGImage?
    @Published private(set) var allowed = CGPreflightScreenCaptureAccess()
    private var stream: SCStream?
    private var last: CIImage? // last complete frame; idle frames carry no image
    private var screenFrame: CGRect = .zero
    private var scale: CGFloat = 2
    private var starting = false, on = false
    private let ctx = CIContext(options: [.cacheIntermediates: false])

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
            if Store.shared.isPro, !UserDefaults.standard.bool(forKey: "askedScreen") { request() } // a free preview never prompts
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
                    cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
                    cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    cfg.showsCursor = false
                    cfg.queueDepth = 3
                    let s = SCStream(filter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []),
                                     configuration: cfg, delegate: self)
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                    // Set first: the first complete frame, the only one on a static screen, can beat startCapture's return.
                    screenFrame = screen.frame
                    scale = screen.backingScaleFactor
                    stream = s
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
        last = nil
        image = nil
    }

    /// Crops the lens from the last complete frame. Runs per frame, per pointer move and per settings change.
    func crop(_ m: CGPoint = NSEvent.mouseLocation) {
        guard let last else { return }
        guard NSMouseInRect(m, screenFrame, false) else { stop(); start(); return } // pointer went to another screen
        let d = UserDefaults.standard
        let n = (d.double(forKey: "magSize") / max(1, d.double(forKey: "magZoom")) * scale).rounded() // whole pixels, no resampling
        let r = CGRect(x: ((m.x - screenFrame.minX) * scale - n / 2).rounded(), y: ((m.y - screenFrame.minY) * scale - n / 2).rounded(),
                       width: n, height: n)
        // ponytail: black past this display's edge, even where another display continues.
        image = ctx.createCGImage(last.composited(over: CIImage(color: .black)), from: r)
    }

    func stream(_ s: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, s === stream, // ignore frames from a stopped stream
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[SCStreamFrameInfo.status] as? Int) == SCFrameStatus.complete.rawValue,
              let pb = buffer.imageBuffer else { return }
        last = CIImage(cvPixelBuffer: pb) // holds one of the 3 queued buffers until the next complete frame
        crop()
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard s === stream else { return }
            NSLog("Spotlit magnifier stopped: \(error.localizedDescription)")
            let worked = last != nil
            stream = nil
            stop()
            if (error as? SCStreamError)?.code == .userStopped {
                UserDefaults.standard.set(false, forKey: "magOn") // stopped from the system menu: show it as off
            } else if worked {
                start() // ponytail: only a stream that showed a frame restarts, so one that dies at birth cannot loop
            }
        }
    }
}

/// One clear, click-through window per screen, above everything.
final class Overlay {
    static let shared = Overlay()
    let tracker = Tracker()
    let magnifier = Magnifier()
    private var windows: [NSWindow] = []
    private var follow: AnyCancellable?

    func start() {
        rebuild()
        tracker.start()
        follow = tracker.$point.sink { [weak self] in self?.magnifier.crop($0) } // a static screen sends no frames
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.sync() }
        sync()
    }

    private func rebuild() {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let host = NSHostingView(rootView: OverlayView(frame: screen.frame, t: tracker, mag: magnifier, store: .shared))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        magnifier.stop() // screens changed; sync() restarts it with the new geometry
        sync()
    }

    /// Matches running services to settings. Called on every settings change; each step is cheap.
    private func sync() {
        let d = UserDefaults.standard
        let on = d.bool(forKey: "enabled")
        windows.forEach { $0.sharingType = d.bool(forKey: "inRecordings") ? .readOnly : .none }
        on && d.bool(forKey: "keysOn") ? KeyTap.shared.start() : KeyTap.shared.stop()
        on && d.bool(forKey: "magOn") ? magnifier.start() : magnifier.stop()
        magnifier.crop() // magZoom and magSize apply without a pointer move
    }
}

/// Solid hex colors, or PRO gradients stored as "g:name".
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

struct OverlayView: View {
    let frame: CGRect
    @ObservedObject var t: Tracker
    @ObservedObject var mag: Magnifier
    @ObservedObject var store: Store
    @AppStorage("enabled") private var enabled = true
    @AppStorage("haloMode") private var mode = "always"
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"
    @AppStorage("opacity") private var opacity = 0.35
    @AppStorage("leftColor") private var leftColor = "#FFB020"
    @AppStorage("rightColor") private var rightColor = "#0A84FF"
    @AppStorage("clickAnim") private var clickAnim = "ripple"
    @AppStorage("dimOn") private var dimOn = false
    @AppStorage("dimAmount") private var dimAmount = 0.55
    @AppStorage("dimSize") private var dimSize = 170.0
    @AppStorage("keysOn") private var keysOn = false
    @AppStorage("keysPos") private var keysPos = "bottom"
    @AppStorage("keysSize") private var keysSize = 24.0
    @AppStorage("magOn") private var magOn = false
    @AppStorage("magSize") private var magSize = 200.0
    @AppStorage("magShape") private var magShape = "circle"
    @AppStorage("holdMode") private var holdMode = false

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
    private var here: Bool { frame.insetBy(dx: -1, dy: -1).contains(t.point) }
    private var active: Bool { enabled && here && (!holdMode || t.holding) }

    private var haloOn: Bool {
        if enabled && here && t.shaking { return true }
        guard active else { return false }
        switch mode {
        case "moving": return t.moving
        case "click": return t.clickFlash
        case "idle": return t.idle
        case "never": return false
        default: return true
        }
    }

    var body: some View {
        let p = local(t.point)
        ZStack {
            if enabled && dimOn && (!holdMode || t.holding) {
                Rectangle().fill(RadialGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.6),
                            .init(color: .black.opacity(dimAmount), location: 1)],
                    center: UnitPoint(x: p.x / frame.width, y: p.y / frame.height),
                    startRadius: 0, endRadius: dimSize))
            }
            if active && magOn, let img = mag.image {
                let lens = magShape == "circle" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: magSize, height: magSize)
                    .clipShape(lens)
                    .overlay(lens.stroke(.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    .position(p)
            }
            if enabled {
                ForEach(t.ripples.filter { frame.contains($0.point) }) { r in
                    ClickView(paint: r.right ? rightColor : leftColor, style: clickAnim).position(local(r.point))
                }
            }
            HaloView(shape: shape, size: size, style: style, color: color, opacity: opacity)
                .scaleEffect(t.shaking ? 2.4 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: t.shaking)
                .opacity(haloOn ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: haloOn)
                .position(p)
            if enabled && keysOn && here && !t.keys.isEmpty {
                KeysView(keys: t.keys, size: keysSize)
                    .position(x: frame.width / 2, y: keysPos == "top" ? 120 : keysPos == "center" ? frame.height / 2 : frame.height - 150)
            }
            if here, let label = store.previewing {
                HStack(spacing: 8) {
                    ProBadge()
                    Text("Previewing \(label)").font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .position(x: frame.width / 2, y: 64)
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
final class AutoOn: ObservableObject {
    static let shared = AutoOn()
    @Published var rules: [AppRule] = (try? JSONDecoder().decode([AppRule].self, from: UserDefaults.standard.data(forKey: "appRules") ?? Data())) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: "appRules") }
    }
    private var saved: [String: Any]?

    func start() {
        prune()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(app?.bundleIdentifier)
        }
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
