import SwiftUI
import Carbon.HIToolbox

/// Global shortcuts via Carbon hot keys. They need no permission.
/// Stored as "keyCode,carbonModifiers,label", e.g. "1,6144,⌃⌥S".
enum HotKeys {
    static let names = ["toggle", "next", "dim", "keys", "mag"]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func reload() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                HotKeys.fire(Int(id.id))
                return noErr
            }, 1, &spec, nil, nil)
        }
        for (i, name) in names.enumerated() {
            let parts = (UserDefaults.standard.string(forKey: "hk.\(name)") ?? "").split(separator: ",")
            guard parts.count >= 2, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { continue }
            var ref: EventHotKeyRef?
            RegisterEventHotKey(code, mods, EventHotKeyID(signature: 0x5350_4C54, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    static func label(_ name: String) -> String {
        let parts = (UserDefaults.standard.string(forKey: "hk.\(name)") ?? "").split(separator: ",", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]) : "None"
    }

    private static func fire(_ i: Int) {
        let d = UserDefaults.standard
        func flip(_ key: String, _ label: String) { Store.shared.set(key, !d.bool(forKey: key), label: label) }
        switch names[i] {
        case "toggle": d.set(!d.bool(forKey: "enabled"), forKey: "enabled")
        case "next": Presets.next()
        case "dim": flip("dimOn", "Spotlight Dim")
        case "keys": flip("keysOn", "Keystrokes")
        default: flip("magOn", "Magnifier")
        }
    }
}

/// Click, then press the new shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let name: String
    @AppStorage private var value: String
    @State private var recording = false
    @State private var monitor: Any?

    init(_ name: String) {
        self.name = name
        _value = AppStorage(wrappedValue: "", "hk.\(name)")
    }

    var body: some View {
        Button {
            guard Store.shared.isPro else { return Windows.paywall() }
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : (value.isEmpty ? "None" : HotKeys.label(name)))
                .frame(minWidth: 90)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if e.keyCode == UInt16(kVK_Delete) { value = ""; finish(); return nil }
            guard f.contains(.command) || f.contains(.control) || f.contains(.option) else { NSSound.beep(); return nil }
            var mods = 0, text = ""
            if f.contains(.control) { mods |= controlKey; text += "⌃" }
            if f.contains(.option) { mods |= optionKey; text += "⌥" }
            if f.contains(.shift) { mods |= shiftKey; text += "⇧" }
            if f.contains(.command) { mods |= cmdKey; text += "⌘" }
            text += (e.charactersIgnoringModifiers ?? "?").uppercased()
            value = "\(e.keyCode),\(mods),\(text)"
            finish()
            return nil
        }
    }

    private func finish() { stop(); HotKeys.reload() }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Keystrokes via a listen-only event tap. Needs Input Monitoring, which sandboxed App Store apps may use.
final class KeyTap: ObservableObject {
    static let shared = KeyTap()
    @Published private(set) var allowed = CGPreflightListenEventAccess()
    var onKey: ((NSEvent) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var poll: Timer?
    private var wanted = false, asking = false

    /// macOS shows its prompt only once. After that, open System Settings.
    func request() {
        let d = UserDefaults.standard
        if d.bool(forKey: "askedKeys") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        } else {
            d.set(true, forKey: "askedKeys")
            CGRequestListenEventAccess()
        }
        asking = true
        check()
    }

    func start() {
        wanted = true
        guard tap == nil, poll == nil else { return }
        if !UserDefaults.standard.bool(forKey: "askedKeys"), !CGPreflightListenEventAccess() { request() } else { check() }
    }

    func stop() {
        wanted = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if !asking { poll?.invalidate(); poll = nil }
    }

    /// Starts the tap once access is granted. macOS sends no notice, so this polls until then.
    func check() {
        let ok = CGPreflightListenEventAccess()
        if ok, wanted, tap == nil {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                    callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = KeyTap.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else if let e = NSEvent(cgEvent: event) {
                    KeyTap.shared.onKey?(e)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
            if let tap {
                source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        // A tap that fails even with access (macOS may want a relaunch) counts as not allowed; retry on the slow poll.
        let now = ok && (tap != nil || !wanted)
        if allowed != now { allowed = now }
        if now || !(wanted || asking) {
            poll?.invalidate()
            poll = nil
            asking = false
        } else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
        }
    }
}
