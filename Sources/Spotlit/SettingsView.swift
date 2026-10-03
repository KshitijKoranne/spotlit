import SwiftUI
import ServiceManagement

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", halo = "Halo", clicks = "Clicks", dim = "Spotlight Dim", keys = "Keystrokes"
        case magnifier = "Magnifier", presets = "Presets", apps = "Apps", shortcuts = "Shortcuts", pro = "Spotlit PRO", about = "About"
        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .halo: "circle.dashed"
            case .clicks: "cursorarrow.click"
            case .dim: "circle.lefthalf.filled"
            case .keys: "keyboard"
            case .magnifier: "plus.magnifyingglass"
            case .presets: "square.stack"
            case .apps: "app.badge"
            case .shortcuts: "command"
            case .pro: "sparkles"
            case .about: "info.circle"
            }
        }
        var isPro: Bool { [.dim, .keys, .magnifier, .presets, .apps].contains(self) }
    }

    @State private var tab: Tab? = .general
    @ObservedObject private var store = Store.shared

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                HStack {
                    Label(t.rawValue, systemImage: t.icon)
                    if t.isPro && !store.isPro { Spacer(); ProBadge() }
                }
                .tag(t)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch tab ?? .general {
                case .general: GeneralPane()
                case .halo: HaloPane()
                case .clicks: ClicksPane()
                case .dim: DimPane()
                case .keys: KeysPane()
                case .magnifier: MagnifierPane()
                case .presets: PresetsPane()
                case .apps: AppsPane()
                case .shortcuts: ShortcutsPane()
                case .pro: ProPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((tab ?? .general).rawValue)
        }
        .frame(width: 760, height: 540)
    }
}

/// Banner on PRO panes when PRO is not owned.
struct ProBanner: View {
    let text: String
    @ObservedObject private var store = Store.shared
    var body: some View {
        if !store.isPro {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(Color(hex: "#F5A000"))
                    Text(text).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Unlock · \(store.price)") { Windows.paywall() }
                        .buttonStyle(.borderedProminent).tint(Color(hex: "#F5A000"))
                }
            }
        }
    }
}

struct GeneralPane: View {
    @AppStorage("shake") private var shake = true
    @AppStorage("inRecordings") private var inRecordings = true
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var onboarding = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    loginOn = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Shake the pointer to find it", isOn: $shake)
                Toggle("Show effects in screenshots and recordings", isOn: $inRecordings)
            } footer: {
                Text("Turn off the last option to keep the halo out of screenshots, recordings and screen sharing.")
            }
            Section {
                Button("Show Welcome Tour…") { Onboarding.show() }
            }
        }
    }
}

struct HaloPane: View {
    @AppStorage("haloMode") private var mode = "always"
    @AppStorage("idleDelay") private var idleDelay = 2.0
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("opacity") private var opacity = 0.35
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    HaloView(shape: shape, size: min(size, 110), style: style, color: color, opacity: opacity)
                        .overlay(Image(systemName: "cursorarrow").font(.system(size: 22)).offset(x: 6, y: 8))
                        .frame(height: 120)
                    Spacer()
                }
            }
            Section {
                Picker("Show the halo", selection: $mode) {
                    Text("Always").tag("always")
                    Text("While moving").tag("moving")
                    Text("On click").tag("click")
                    Text("When idle").tag("idle")
                    Text("Never").tag("never")
                }
                if mode == "idle" {
                    Slider(value: $idleDelay, in: 1...10, step: 1) { Text("Idle after \(Int(idleDelay)) s") }
                }
                Picker("Shape", selection: $shape) {
                    Text("Circle").tag("circle")
                    Text("Squircle").tag("squircle")
                    Text("Rhombus").tag("rhombus")
                }.pickerStyle(.segmented)
                Picker("Style", selection: $style) {
                    Text("Fill").tag("fill")
                    Text("Ring").tag("ring")
                }.pickerStyle(.segmented)
                Slider(value: $size, in: 20...160) { Text("Size") }
                Slider(value: $opacity, in: 0.1...0.9) { Text("Opacity") }
            }
            Section("Color") {
                Swatches(key: "haloColor", hex: color)
                ColorPicker("Custom color", selection: Binding(get: { Paint.base(color) }, set: { color = $0.hex }), supportsOpacity: false)
            }
        }
    }
}

struct ClicksPane: View {
    @AppStorage("clicksOn") private var clicksOn = true
    @AppStorage("clickAnim") private var clickAnim = "ripple"
    @AppStorage("leftColor") private var left = "#FFB020"
    @AppStorage("rightColor") private var right = "#0A84FF"

    var body: some View {
        Form {
            Section {
                Toggle("Show clicks", isOn: $clicksOn)
                LabeledContent("Effect") { ClickEffectPicker(value: clickAnim) }
            } footer: {
                Text("Pulse, Shrink and Glitter are part of PRO.")
            }
            Section("Left click") {
                Swatches(key: "leftColor", hex: left)
                ColorPicker("Custom color", selection: Binding(get: { Paint.base(left) }, set: { left = $0.hex }), supportsOpacity: false)
            }
            Section("Right click") {
                Swatches(key: "rightColor", hex: right)
                ColorPicker("Custom color", selection: Binding(get: { Paint.base(right) }, set: { right = $0.hex }), supportsOpacity: false)
            }
        }
    }
}

struct DimPane: View {
    @AppStorage("dimOn") private var dimOn = false
    @AppStorage("dimAmount") private var amount = 0.55
    @AppStorage("dimSize") private var size = 170.0

    var body: some View {
        Form {
            ProBanner(text: "Dim the screen and keep a bright circle around the pointer.")
            Section {
                Toggle("Spotlight Dim", isOn: proBinding("dimOn", "Spotlight Dim"))
                Slider(value: $amount, in: 0.2...0.85) { Text("Dim amount") }
                Slider(value: $size, in: 80...400) { Text("Spotlight size") }
            } footer: {
                Text("Shortcut: \(HotKeys.label("dim"))")
            }
        }
    }
}

struct KeysPane: View {
    @AppStorage("keysOn") private var keysOn = false
    @AppStorage("keysMode") private var mode = "all"
    @AppStorage("keysPos") private var pos = "bottom"
    @AppStorage("keysSize") private var size = 24.0
    @ObservedObject private var keyTap = KeyTap.shared

    var body: some View {
        Form {
            ProBanner(text: "Show the keys you press as clear keycaps. Good for tutorials and recordings.")
            Section {
                Toggle("Show keystrokes", isOn: proBinding("keysOn", "Keystrokes"))
                Picker("Show", selection: $mode) {
                    Text("All keys").tag("all")
                    Text("Shortcuts only").tag("shortcuts")
                }.pickerStyle(.segmented)
                Picker("Position", selection: $pos) {
                    Text("Bottom").tag("bottom")
                    Text("Center").tag("center")
                    Text("Top").tag("top")
                }.pickerStyle(.segmented)
                Slider(value: $size, in: 16...40) { Text("Key size") }
            }
            Section {
                LabeledContent("Input Monitoring") {
                    if keyTap.allowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { keyTap.request() }
                    }
                }
            } footer: {
                Text("macOS asks for Input Monitoring so Spotlit can see the keys you press. Spotlit never saves or sends them. Keys typed in password fields are hidden by macOS. If keys do not show after you allow it, quit and reopen Spotlit.")
            }
        }
        .onAppear { keyTap.check() }
    }
}

struct MagnifierPane: View {
    @AppStorage("magOn") private var magOn = false
    @AppStorage("magZoom") private var zoom = 2.0
    @AppStorage("magSize") private var size = 200.0
    @AppStorage("magShape") private var shape = "circle"
    @State private var allowed = Overlay.shared.magnifier.allowed

    var body: some View {
        Form {
            ProBanner(text: "Zoom in on the area under the pointer, anywhere on screen.")
            Section {
                Toggle("Magnifier", isOn: proBinding("magOn", "Magnifier"))
                if magOn && !allowed {
                    LabeledContent("Screen Recording") { Button("Allow…") { Overlay.shared.magnifier.request() } }
                }
                Slider(value: $zoom, in: 1.5...6, step: 0.5) { Text(String(format: "Zoom %.1f×", zoom)) }
                Slider(value: $size, in: 120...360) { Text("Lens size") }
                Picker("Lens", selection: $shape) {
                    Text("Circle").tag("circle")
                    Text("Rounded").tag("rounded")
                }.pickerStyle(.segmented)
            } footer: {
                Text("The magnifier needs Screen Recording permission. macOS asks the first time you turn it on. After you allow it, quit and reopen Spotlit. Shortcut: \(HotKeys.label("mag"))")
            }
        }
        .onReceive(Overlay.shared.magnifier.$allowed) { allowed = $0 }
    }
}

struct PresetsPane: View {
    @AppStorage("preset") private var preset = "Default"
    @State private var names = Presets.names
    @State private var newName = ""
    @ObservedObject private var store = Store.shared

    var body: some View {
        Form {
            ProBanner(text: "Save your setups and switch between them in one click.")
            Section {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Image(systemName: preset == name ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(preset == name ? Color.accentColor : .secondary)
                        Text(name)
                        Spacer()
                        if !Presets.builtInNames.contains(name) {
                            Button("Delete", role: .destructive) { Presets.delete(name); names = Presets.names }.buttonStyle(.borderless)
                        }
                        Button("Use") { Presets.choose(name) }.disabled(preset == name)
                    }
                }
            } footer: {
                Text("Next preset: \(HotKeys.label("next"))")
            }
            Section("Save current settings") {
                HStack {
                    TextField("Name", text: $newName).onSubmit(save)
                    Button(names.contains(target ?? "") ? "Replace" : "Save", action: save).disabled(target == nil)
                }
            }
        }
    }

    private var target: String? { Presets.saveName(newName) }

    private func save() {
        guard let n = target else { return }
        guard store.isPro else { return Windows.paywall() }
        Presets.save(n)
        newName = ""
        names = Presets.names
    }
}

struct AppsPane: View {
    @ObservedObject private var auto = AutoOn.shared
    @ObservedObject private var store = Store.shared

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in !auto.rules.contains { $0.bundle == app.bundleIdentifier } }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            ProBanner(text: "Turn Spotlit on by itself when an app like Zoom or Keynote comes to the front.")
            Section {
                if auto.rules.isEmpty {
                    Text("No apps yet.").foregroundStyle(.secondary)
                }
                ForEach($auto.rules) { $rule in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundle) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        }
                        Text(rule.name)
                        Spacer()
                        Picker("Preset", selection: $rule.preset) {
                            ForEach(Presets.names, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 110)
                        Toggle("In recordings", isOn: $rule.showInRecordings).toggleStyle(.checkbox)
                        Button { auto.rules.removeAll { $0.bundle == rule.bundle } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("When you leave the app, your earlier settings come back.")
            }
            Section {
                Menu("Add App") {
                    ForEach(running, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "App") {
                            guard store.isPro else { return Windows.paywall() }
                            auto.rules.append(AppRule(bundle: app.bundleIdentifier!, name: app.localizedName ?? "App",
                                                      preset: "Demo", showInRecordings: true))
                        }
                    }
                }
                .fixedSize()
            } footer: {
                Text("Lists apps that are open now. Open the app first if you do not see it.")
            }
        }
    }
}

struct ShortcutsPane: View {
    @AppStorage("holdMode") private var holdMode = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Turn Spotlit on or off") { ShortcutRecorder("toggle") }
                LabeledContent("Next preset") { ShortcutRecorder("next") }
                LabeledContent("Spotlight Dim") { ShortcutRecorder("dim") }
                LabeledContent("Keystrokes") { ShortcutRecorder("keys") }
                LabeledContent("Magnifier") { ShortcutRecorder("mag") }
            } footer: {
                Text("Changing shortcuts is part of PRO. Click a shortcut, then press the new keys. Press Delete to clear it.")
            }
            Section {
                Toggle(isOn: proBinding("holdMode", "Hold-key mode")) {
                    HStack { Text("Show effects only while holding ⌥ Option"); if !Store.shared.isPro { ProBadge() } }
                }
            } footer: {
                Text("The halo, dim and magnifier show only while you hold the Option key.")
            }
        }
    }
}

struct ProPane: View {
    @ObservedObject private var store = Store.shared
    var body: some View {
        Form {
            Section {
                if store.isPro {
                    Label("PRO is unlocked. Thank you for your support.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    ProFeatureList()
                    Button("Unlock PRO · \(store.price)") { Task { await store.buy() } }
                        .buttonStyle(.borderedProminent).tint(Color(hex: "#F5A000")).disabled(store.busy)
                }
            }
            Section {
                Button("Restore Purchase") { Task { await store.restore() } }.disabled(store.busy)
                if let m = store.message { Text(m).foregroundStyle(.secondary) }
            }
        }
    }
}

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spotlit").font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Privacy", value: "No data collected. Everything stays on this Mac.")
                LabeledContent("Made by", value: "Kshitij Koranne")
            }
        }
    }
}

struct ProFeatureList: View {
    static let items: [(String, String, String)] = [
        ("circle.lefthalf.filled", "Spotlight Dim", "Dim the screen around the pointer"),
        ("keyboard", "Keystrokes", "Show the keys you press"),
        ("plus.magnifyingglass", "Magnifier", "Zoom in where you point"),
        ("sparkle", "Glitter and more clicks", "Glitter, Pulse and Shrink"),
        ("paintpalette", "Exclusive colors", "Sunset, Aurora, Ocean, Candy, Prism"),
        ("square.stack", "Presets", "Switch setups in one click"),
        ("app.badge", "Auto-on per app", "Turns on with Zoom, Keynote and more"),
        ("command", "Hold-key mode and shortcuts", "Your keys, your way"),
    ]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 12) {
            ForEach(Self.items, id: \.1) { icon, title, sub in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#F5A000"))
                        .frame(width: 26, height: 26)
                        .background(Color(hex: "#FFB020").opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
