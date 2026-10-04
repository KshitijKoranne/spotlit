import SwiftUI
import StoreKit

@main
struct SpotlitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("enabled") private var enabled = true

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            Image(systemName: enabled ? "cursorarrow.rays" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Presets.builtIn["Default"]!.merging([
            "enabled": true, "preset": "Default", "shake": true, "inRecordings": true, "holdMode": false,
            "idleDelay": 2.0, "keysPos": "bottom", "keysSize": 24.0, "magShape": "circle",
            "hk.toggle": "1,6144,⌃⌥S", "hk.next": "35,6144,⌃⌥P", "hk.dim": "2,6144,⌃⌥D",
            "hk.keys": "40,6144,⌃⌥K", "hk.mag": "6,6144,⌃⌥Z",
        ]) { a, _ in a })
        NSApp.setActivationPolicy(.accessory)
        // Unit tests run inside the app: no tour, overlay or shortcuts.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Review.countLaunch()
        Store.shared.start()
        Overlay.shared.start()
        AutoOn.shared.start()
        HotKeys.reload()
        Onboarding.showIfNeeded()
    }

    /// Opening Spotlit again from Finder or Launchpad shows Settings, since it has no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.settings()
        return false
    }
}

/// Asks for a rating once, after 5 launches and 3 days since the first.
@MainActor
enum Review {
    static func countLaunch() {
        let d = UserDefaults.standard
        if d.object(forKey: "firstLaunch") == nil { d.set(Date(), forKey: "firstLaunch") }
        d.set(d.integer(forKey: "launches") + 1, forKey: "launches")
    }

    static func askIfDue(in vc: NSViewController?) {
        let d = UserDefaults.standard
        guard let vc, !d.bool(forKey: "reviewAsked"), d.integer(forKey: "launches") >= 5,
              let first = d.object(forKey: "firstLaunch") as? Date, Date().timeIntervalSince(first) >= 3 * 24 * 3600 else { return }
        d.set(true, forKey: "reviewAsked")
        AppStore.requestReview(in: vc) // StoreKit decides whether it really shows
    }
}

/// Settings the presets save and restore.
@MainActor
enum Presets {
    static let keys = ["haloMode", "shape", "size", "haloStyle", "haloColor", "opacity", "clicksOn", "leftColor",
                       "rightColor", "clickAnim", "dimOn", "dimAmount", "dimSize", "keysOn", "keysMode",
                       "magOn", "magZoom", "magSize"]
    static let builtInNames = ["Default", "Demo", "Teach", "Record"]
    static let builtIn: [String: [String: Any]] = {
        let base: [String: Any] = [
            "haloMode": "always", "shape": "circle", "size": 56.0, "haloStyle": "fill", "haloColor": "#FFB020",
            "opacity": 0.35, "clicksOn": true, "leftColor": "#FFB020", "rightColor": "#0A84FF", "clickAnim": "ripple",
            "dimOn": false, "dimAmount": 0.55, "dimSize": 170.0, "keysOn": false, "keysMode": "all",
            "magOn": false, "magZoom": 2.0, "magSize": 200.0,
        ]
        func with(_ c: [String: Any]) -> [String: Any] { base.merging(c) { _, new in new } }
        return [
            "Default": base,
            "Demo": with(["size": 72.0, "haloStyle": "ring", "opacity": 0.6, "dimOn": true]),
            "Teach": with(["haloMode": "moving", "shape": "squircle", "size": 60.0, "haloColor": "#34C759", "keysOn": true]),
            "Record": with(["size": 48.0, "haloColor": "#0A84FF", "opacity": 0.3, "keysOn": true, "keysMode": "shortcuts"]),
        ]
    }()

    static var custom: [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: "customPresets") as? [String: [String: Any]] ?? [:]
    }
    static var names: [String] { builtInNames + custom.keys.sorted() }
    static func values(_ name: String) -> [String: Any]? { builtIn[name] ?? custom[name] }

    /// Applies without a PRO check. Used by Auto-on.
    static func apply(_ name: String) {
        guard let v = values(name) else { return }
        v.forEach { UserDefaults.standard.set($1, forKey: $0) }
        UserDefaults.standard.set(name, forKey: "preset")
    }

    /// User choice: presets other than Default need PRO.
    static func choose(_ name: String) {
        if name == "Default" || Store.shared.allow() { apply(name) }
    }

    static func next() {
        let n = names
        let i = n.firstIndex(of: UserDefaults.standard.string(forKey: "preset") ?? "") ?? -1
        choose(n[(i + 1) % n.count])
    }

    static func snapshot(extra: [String] = []) -> [String: Any] {
        var r: [String: Any] = [:]
        for k in keys + extra { r[k] = UserDefaults.standard.object(forKey: k) }
        return r
    }

    /// Trimmed name to save under: an existing custom name keeps its spelling. Nil if empty or built-in.
    static func saveName(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func same(_ s: String) -> Bool { s.caseInsensitiveCompare(n) == .orderedSame }
        if n.isEmpty || builtInNames.contains(where: same) { return nil }
        return custom.keys.first(where: same) ?? n
    }

    static func save(_ name: String) {
        guard let name = saveName(name) else { return }
        var c = custom
        c[name] = snapshot()
        UserDefaults.standard.set(c, forKey: "customPresets")
        UserDefaults.standard.set(name, forKey: "preset")
    }

    static func delete(_ name: String) {
        var c = custom
        c[name] = nil
        UserDefaults.standard.set(c, forKey: "customPresets")
        if UserDefaults.standard.string(forKey: "preset") == name { apply("Default") }
        AutoOn.shared.prune()
    }
}

/// Plain AppKit windows so an accessory app can open them from anywhere.
@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]
    /// Closed windows leave the cache, so the next show builds a fresh view and the old one is freed.
    private static let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
        let w = n.object as? NSWindow
        MainActor.assumeIsolated {
            guard let w, let id = open.first(where: { $0.value === w })?.key else { return }
            open[id] = nil
            if id == "onboarding" { UserDefaults.standard.set(true, forKey: "onboarded") } // closed or finished: don't show again
            DispatchQueue.main.async { withExtendedLifetime(w) {} } // free it after AppKit and SwiftUI finish the close
        }
    }

    static func show<V: View>(_ id: String, title: String, transparent: Bool = false, _ view: V) {
        _ = closing
        let w = open[id] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = title
            w.isReleasedWhenClosed = false
            if transparent {
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                w.titlebarSeparatorStyle = .none
            }
            w.center()
            open[id] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) { open[id]?.close() }
    static func isOpen(_ id: String) -> Bool { open[id]?.isVisible == true }
    static func settings() {
        show("settings", title: "Spotlit Settings", SettingsView())
        Review.askIfDue(in: open["settings"]?.contentViewController)
    }
    static func paywall() {
        Task { await Store.shared.refresh(); await Store.shared.load() }
        show("pro", title: "Spotlit PRO", transparent: true, PaywallView())
    }
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0xFFB020
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .orange
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
