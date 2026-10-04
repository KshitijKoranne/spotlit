import SwiftUI
import Carbon.HIToolbox

/// Global shortcuts via Carbon hot keys. They need no permission.
/// Stored as "keyCode,carbonModifiers,label", e.g. "1,6144,⌃⌥S".
@MainActor
enum HotKeys {
    static let names = ["toggle", "next", "dim", "keys", "mag"]
    static let titles = ["Turn Spotlit on or off", "Next preset", "Focus Dim", "Keystrokes", "Magnifier"]
    private static let sig: OSType = 0x5350_4C54 // "SPLT"
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    /// Stored values macOS refused to register, e.g. taken by another app since they were set.
    private static var failed: Set<String> = []

    static func reload() {
        pause()
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated { // Carbon calls on the main thread
                    guard id.signature == HotKeys.sig, HotKeys.names.indices.contains(Int(id.id)) else { return OSStatus(eventNotHandledErr) }
                    HotKeys.fire(Int(id.id))
                    return noErr
                }
            }, 1, &spec, nil, nil) == noErr
        }
        failed = []
        for (i, name) in names.enumerated() {
            guard let k = parse(name) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(k.code, k.mods, EventHotKeyID(signature: sig, id: UInt32(i)), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.insert(UserDefaults.standard.string(forKey: "hk.\(name)") ?? "") }
        }
    }

    /// Unregisters all, so a recorder gets the keys instead of the actions firing.
    static func pause() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    /// Same parse as `reload`, so "None" shows exactly when nothing is registered, "Unavailable" when macOS refused it.
    static func label(_ name: String) -> String { label(value: UserDefaults.standard.string(forKey: "hk.\(name)") ?? "") }
    /// For views that keep the stored value in @AppStorage, so they redraw when the shortcut changes.
    static func label(value: String) -> String { failed.contains(value) ? "Unavailable" : parse(value: value)?.label ?? "None" }

    private static func parse(_ name: String) -> (code: UInt32, mods: UInt32, label: String)? {
        parse(value: UserDefaults.standard.string(forKey: "hk.\(name)") ?? "")
    }

    private static func parse(value: String) -> (code: UInt32, mods: UInt32, label: String)? {
        let p = value.split(separator: ",", maxSplits: 2)
        guard p.count == 3, let code = UInt32(p[0]), let mods = UInt32(p[1]) else { return nil }
        return (code, mods, String(p[2]))
    }

    /// Why a combination can't be used for `name`, or nil if it can. Call while paused.
    static func conflict(_ code: UInt32, _ mods: UInt32, for name: String) -> String? {
        // ponytail: menu shortcuts inside other apps can't be seen; the ⌃/⌥ rule keeps clear of most.
        for (n, t) in zip(names, titles) where n != name {
            if let k = parse(n), k.code == code, k.mods == mods { return "Used by “\(t)”" }
        }
        var sys: Unmanaged<CFArray>?
        let mask = cmdKey | shiftKey | optionKey | controlKey
        if CopySymbolicHotKeys(&sys) == noErr, let list = sys?.takeRetainedValue() as? [[String: Any]],
           list.contains(where: { ($0["kHISymbolicHotKeyEnabled"] as? Bool) == true && ($0["kHISymbolicHotKeyCode"] as? Int) == Int(code)
                                  && (($0["kHISymbolicHotKeyModifiers"] as? Int) ?? 0) & mask == Int(mods) }) {
            return "Used by macOS"
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, mods, EventHotKeyID(signature: sig, id: 99), GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr ? nil : "Used by another app"
    }

    /// Keys with no printable character, named as macOS menus show them.
    static let glyphs: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 57: "⇪", 71: "⌧", 76: "⌤", 114: "help", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑", 102: "英数", 104: "かな",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// A key's name as macOS menus show it ("F5", "Space", "←", "S"), or nil if it has none.
    /// `typed` names what ⇧ types ("!" for ⇧1); otherwise the plain key, as in "⌃⌥⇧1".
    static func keyName(_ e: NSEvent, typed: Bool = false) -> String? {
        if let g = glyphs[e.keyCode] { return g }
        let c = (typed ? nil : e.characters(byApplyingModifiers: [])) ?? e.charactersIgnoringModifiers ?? ""
        guard !c.isEmpty, !c.unicodeScalars.contains(where: { [.control, .privateUse].contains($0.properties.generalCategory) }) else { return nil }
        let u = c.uppercased()
        return u.count == c.count ? u : c // "ß" stays "ß", not "SS"
    }

    private static func fire(_ i: Int) {
        let d = UserDefaults.standard
        func flip(_ key: String) { d.set(!d.bool(forKey: key), forKey: key) }
        if names[i] == "toggle" { return flip("enabled") }
        // PRO keys only beep without PRO: a paywall must not take focus while someone presents.
        guard Store.shared.isPro else { return NSSound.beep() }
        switch names[i] {
        case "next": Presets.next()
        case "dim": flip("dimOn")
        case "keys": flip("keysOn")
        default: flip("magOn")
        }
    }
}

/// Click, then press the new shortcut. Esc or a click elsewhere cancels, Delete clears.
struct ShortcutRecorder: View {
    let name: String
    @AppStorage private var value: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var note: String?
    @State private var hover = false
    private static var stopOther: (() -> Void)?

    init(_ name: String) {
        self.name = name
        _value = AppStorage(wrappedValue: "", "hk.\(name)")
    }

    var body: some View {
        Button {
            guard Store.shared.allow() else { return }
            recording ? stop() : start()
        } label: {
            Text(note ?? (recording ? "Type shortcut…" : (value.isEmpty ? "None" : HotKeys.label(name))))
                .frame(minWidth: 90)
        }
        .onHover { hover = $0 }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func start() {
        if let other = Self.stopOther { other() } // one recorder at a time
        Self.stopOther = stop
        recording = true
        HotKeys.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { e in
            guard e.type == .keyDown else { if !hover { stop() }; return e }
            if e.isARepeat { return nil } // a held key beeps once, not 30 times a second
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods = 0, text = ""
            if f.contains(.control) { mods |= controlKey; text += "⌃" }
            if f.contains(.option) { mods |= optionKey; text += "⌥" }
            if f.contains(.shift) { mods |= shiftKey; text += "⇧" }
            if f.contains(.command) { mods |= cmdKey; text += "⌘" }
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if e.keyCode == UInt16(kVK_Delete), mods == 0 { value = ""; stop(); return nil }
            // ⌥ alone would steal typing keys (⌥E types an accent); ⌘ alone steals app shortcuts (⌘C).
            guard mods & controlKey != 0 || mods & (optionKey | cmdKey) == optionKey | cmdKey else { return reject("Add ⌃, or ⌥ with ⌘") }
            guard let key = HotKeys.keyName(e) else { return reject(nil) }
            if let why = HotKeys.conflict(UInt32(e.keyCode), UInt32(mods), for: name) { return reject(why) }
            value = "\(e.keyCode),\(mods),\(text)\(key)"
            stop()
            return nil
        }
    }

    /// Beeps, keeps the old value and keeps recording.
    private func reject(_ why: String?) -> NSEvent? {
        NSSound.beep()
        note = why
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if note == why { note = nil } }
        return nil
    }

    private func stop() {
        guard recording else { return }
        Self.stopOther = nil
        recording = false
        note = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeys.reload()
    }
}

/// Keystrokes via a listen-only event tap. Needs Input Monitoring, which sandboxed App Store apps may use.
@MainActor
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
                MainActor.assumeIsolated { // the tap's source is on the main run loop
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let t = KeyTap.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    } else if let e = NSEvent(cgEvent: event) {
                        KeyTap.shared.onKey?(e)
                    }
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
            poll = repeating(1.5) { [weak self] in self?.check() }
        }
    }
}

/// A main-thread timer that also fires while a menu or slider is tracking, with tolerance so macOS can batch wake-ups.
@MainActor
func repeating(_ seconds: TimeInterval, _ f: @escaping @MainActor () -> Void) -> Timer {
    let t = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated(f) }
    t.tolerance = seconds / 5
    RunLoop.main.add(t, forMode: .common)
    return t
}
