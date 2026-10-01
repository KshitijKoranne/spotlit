import SwiftUI
import Carbon.HIToolbox

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
        UserDefaults.standard.register(defaults: [
            "enabled": true, "haloMode": "always", "shape": "circle", "size": 56.0,
            "haloStyle": "fill", "haloColor": "#FFB020", "opacity": 0.35,
            "clicksOn": true, "leftColor": "#FFB020", "rightColor": "#0A84FF",
            "dimOn": false, "dimAmount": 0.55, "dimSize": 170.0,
            "keysOn": false, "keysMode": "all", "shake": true, "inRecordings": true,
        ])
        NSApp.setActivationPolicy(.accessory)
        Overlay.shared.start()
        HotKey.register {
            let d = UserDefaults.standard
            d.set(!d.bool(forKey: "enabled"), forKey: "enabled")
        }
    }
}

// Global ⌃⌥S toggle. Carbon hot keys need no permission.
enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x5350_4C54, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0xFFB020
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}
