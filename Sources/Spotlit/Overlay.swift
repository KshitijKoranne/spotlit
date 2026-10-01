import SwiftUI
import AppKit

struct Ripple: Identifiable {
    let id = UUID()
    let point: CGPoint
    let right: Bool
}

/// Watches the mouse and keyboard. Mouse monitors need no permission; keys need Accessibility.
final class Tracker: ObservableObject {
    @Published var point = NSEvent.mouseLocation
    @Published var moving = false
    @Published var idle = false
    @Published var clickFlash = false
    @Published var shaking = false
    @Published var ripples: [Ripple] = []
    @Published var keys: [String] = []

    private var monitors: [Any] = []
    private var keyMonitor: Any?
    private var keyMonitorTrusted = false
    private var moveStop, idleStart, flashEnd, keysEnd: DispatchWorkItem?
    private var lastX: CGFloat = 0, lastDir: CGFloat = 0, turns: [Date] = []
    private var lastKeyPlain = false, lastKeyTime = Date.distantPast

    func start() {
        watch([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in self?.moved() }
        watch([.leftMouseDown, .rightMouseDown]) { [weak self] e in self?.clicked(right: e.type == .rightMouseDown) }
        updateKeyMonitor()
    }

    private func watch(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    /// Adds or removes the key monitor. Re-adds it once Accessibility is granted.
    func updateKeyMonitor() {
        let on = UserDefaults.standard.bool(forKey: "keysOn")
        let trusted = AXIsProcessTrusted()
        if let m = keyMonitor, !on || (trusted && !keyMonitorTrusted) {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
            keys = []
        }
        if on, keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.key($0) }
            keyMonitorTrusted = trusted
        }
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
        idleStart = after(2) { [weak self] in self?.idle = true }
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
        after(0.7) { [weak self] in self?.ripples.removeAll { $0.id == r.id } }
    }

    private func key(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: [String] = []
        if f.contains(.control) { mods.append("⌃") }
        if f.contains(.option) { mods.append("⌥") }
        if f.contains(.shift) { mods.append("⇧") }
        if f.contains(.command) { mods.append("⌘") }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 76: "⌤",
                                         117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let name = special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty else { return }
        let shortcut = f.contains(.command) || f.contains(.control) || f.contains(.option)
        if UserDefaults.standard.string(forKey: "keysMode") == "shortcuts", !shortcut { return }

        let now = Date()
        if !shortcut, lastKeyPlain, now.timeIntervalSince(lastKeyTime) < 1.2 {
            keys = Array((keys + [name]).suffix(12))
        } else {
            keys = (shortcut ? mods : []) + [name]
        }
        lastKeyPlain = !shortcut
        lastKeyTime = now
        keysEnd?.cancel()
        keysEnd = after(1.6) { [weak self] in self?.keys = [] }
    }
}

/// One clear, click-through window per screen, above everything.
final class Overlay {
    static let shared = Overlay()
    let tracker = Tracker()
    private var windows: [NSWindow] = []

    func start() {
        rebuild()
        tracker.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.applySharing() }
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
            let host = NSHostingView(rootView: OverlayView(frame: screen.frame, t: tracker))
            host.sizingOptions = []
            host.frame = CGRect(origin: .zero, size: screen.frame.size)
            w.contentView = host
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        applySharing()
    }

    private func applySharing() {
        let show = UserDefaults.standard.bool(forKey: "inRecordings")
        windows.forEach { $0.sharingType = show ? .readOnly : .none }
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

struct OverlayView: View {
    let frame: CGRect
    @ObservedObject var t: Tracker
    @AppStorage("enabled") private var enabled = true
    @AppStorage("haloMode") private var mode = "always"
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"
    @AppStorage("opacity") private var opacity = 0.35
    @AppStorage("leftColor") private var leftColor = "#FFB020"
    @AppStorage("rightColor") private var rightColor = "#0A84FF"
    @AppStorage("dimOn") private var dimOn = false
    @AppStorage("dimAmount") private var dimAmount = 0.55
    @AppStorage("dimSize") private var dimSize = 170.0
    @AppStorage("keysOn") private var keysOn = false

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
    private var here: Bool { frame.insetBy(dx: -1, dy: -1).contains(t.point) }

    private var haloOn: Bool {
        guard enabled, here else { return false }
        if t.shaking { return true }
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
        let c = Color(hex: color)
        ZStack {
            if enabled && dimOn {
                Rectangle().fill(RadialGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.6),
                            .init(color: .black.opacity(dimAmount), location: 1)],
                    center: UnitPoint(x: p.x / frame.width, y: p.y / frame.height),
                    startRadius: 0, endRadius: dimSize))
            }
            if enabled {
                ForEach(t.ripples.filter { frame.contains($0.point) }) { r in
                    RippleView(color: Color(hex: r.right ? rightColor : leftColor)).position(local(r.point))
                }
            }
            HaloShape(kind: shape)
                .fill(style == "fill" ? c.opacity(opacity) : .clear)
                .overlay(HaloShape(kind: shape).stroke(c.opacity(min(1, opacity + 0.5)), lineWidth: style == "fill" ? 1.5 : 3))
                .shadow(color: c.opacity(0.35), radius: 10)
                .frame(width: size, height: size)
                .scaleEffect(t.shaking ? 2.4 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: t.shaking)
                .opacity(haloOn ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: haloOn)
                .position(p)
            if enabled && keysOn && here && !t.keys.isEmpty {
                KeysView(keys: t.keys).position(x: frame.width / 2, y: frame.height - 150)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .allowsHitTesting(false)
    }
}

struct RippleView: View {
    let color: Color
    @State private var go = false
    var body: some View {
        Circle()
            .stroke(color, lineWidth: 3)
            .frame(width: 44, height: 44)
            .scaleEffect(go ? 1.6 : 0.3)
            .opacity(go ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { go = true } }
    }
}

struct KeysView: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 48, minHeight: 48)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }
}
