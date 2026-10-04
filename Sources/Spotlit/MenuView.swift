import SwiftUI

struct MenuView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var keyTap = KeyTap.shared
    @State private var magAllowed = Overlay.shared.magnifier.allowed // not observed: the magnifier publishes every frame
    @AppStorage("enabled") private var enabled = true
    @AppStorage("hk.toggle") private var hkToggle = ""
    @AppStorage("preset") private var preset = "Default"
    @AppStorage("haloMode") private var mode = "always"
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"
    @AppStorage("clicksOn") private var clicksOn = true
    @AppStorage("clickAnim") private var clickAnim = "ripple"
    @AppStorage("dimOn") private var dimOn = false
    @AppStorage("dimAmount") private var dimAmount = 0.55
    @AppStorage("dimSize") private var dimSize = 170.0
    @AppStorage("keysOn") private var keysOn = false
    @AppStorage("keysMode") private var keysMode = "all"
    @AppStorage("magOn") private var magOn = false
    @AppStorage("magZoom") private var magZoom = 2.0
    @AppStorage("magSize") private var magSize = 200.0

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) { haloCard; clicksCard }
                VStack(spacing: 12) { dimCard; keysCard; magCard }
            }
            footer
        }
        .padding(14)
        .frame(width: 580)
        .task { await store.refresh(); await store.load() } // trial end, and the real price if launch had no network
        .onReceive(Overlay.shared.magnifier.$allowed) { magAllowed = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Spotlit").font(.system(size: 14, weight: .semibold))
                Text(enabled ? (hkToggle.isEmpty ? "On" : "On · \(HotKeys.label(value: hkToggle))") : "Off")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Preset", selection: Binding(get: { preset }, set: { Presets.choose($0) })) {
                ForEach(Presets.names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .help("Preset")
            Button { Windows.settings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Toggle("Spotlit", isOn: $enabled).toggleStyle(.switch).labelsHidden()
        }
    }

    private var haloCard: some View {
        Card(title: "Halo", icon: "circle.dashed") {
            Row(title: "Show") {
                Picker("Show", selection: $mode) {
                    Text("Always").tag("always")
                    Text("While moving").tag("moving")
                    Text("On click").tag("click")
                    Text("When idle").tag("idle")
                    Text("Never").tag("never")
                }.labelsHidden()
            }
            Picker("Shape", selection: $shape) {
                Text("Circle").tag("circle")
                Text("Squircle").tag("squircle")
                Text("Rhombus").tag("rhombus")
            }.pickerStyle(.segmented).labelsHidden()
            Row(title: "Size") {
                Slider(value: $size, in: 20...160)
                Text("\(Int(size))").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            }
            Row(title: "Style") {
                Picker("Style", selection: $style) {
                    Text("Fill").tag("fill")
                    Text("Ring").tag("ring")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Swatches(key: "haloColor", hex: color)
        }
    }

    private var clicksCard: some View {
        Card(title: "Clicks", icon: "cursorarrow.click", isOn: $clicksOn) {
            Row(title: "Effect") { ClickEffectPicker(value: clickAnim) }
        }
    }

    private var dimCard: some View {
        Card(title: "Focus Dim", icon: "circle.lefthalf.filled", isOn: proBinding("dimOn"), pro: true) {
            Row(title: "Amount") { Slider(value: $dimAmount, in: 0.2...0.85) }
            Row(title: "Size") { Slider(value: $dimSize, in: 80...400) }
        }
    }

    private var keysCard: some View {
        Card(title: "Keystrokes", icon: "keyboard", isOn: proBinding("keysOn"), pro: true) {
            Picker("Keys", selection: $keysMode) {
                Text("All keys").tag("all")
                Text("Shortcuts only").tag("shortcuts")
            }.pickerStyle(.segmented).labelsHidden()
            if store.on("keysOn") && !keyTap.allowed {
                Button("Allow Input Monitoring…") { keyTap.request() }
                    .controlSize(.small)
            }
        }
    }

    private var magCard: some View {
        Card(title: "Magnifier", icon: "plus.magnifyingglass", isOn: proBinding("magOn"), pro: true) {
            Row(title: "Zoom") {
                Slider(value: $magZoom, in: 1.5...6, step: 0.5)
                Text(String(format: "%.1f×", magZoom)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            Row(title: "Lens") { Slider(value: $magSize, in: 120...360) }
            if store.on("magOn") && !magAllowed {
                Button("Allow Screen Recording…") { Overlay.shared.magnifier.request() }
                    .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !store.purchased {
                Button { Windows.paywall() } label: {
                    Label("Unlock PRO\(store.price.map { " · \($0)" } ?? "")", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#F5A000"))
                .controlSize(.small)
            }
            Spacer()
            Button("Settings…") { Windows.settings() }.controlSize(.small).keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small).keyboardShortcut("q")
        }
    }
}

/// Small app mark used in the menu and windows.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "cursorarrow.rays")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(hex: "#FFC94A"), Color(hex: "#FF9500")], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var isOn: Binding<Bool>? = nil
    var pro = false
    @ViewBuilder let content: Content
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(.system(size: 12, weight: .semibold))
                if pro && !store.isPro { ProBadge() }
                Spacer()
                if let isOn {
                    Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            .frame(height: 20)
            VStack(alignment: .leading, spacing: 8) { content }
                .disabled(!(isOn?.wrappedValue ?? true))
                .opacity(isOn?.wrappedValue ?? true ? 1 : 0.45)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Row<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content
        }
        .font(.system(size: 12))
    }
}

/// Free colors, then PRO gradients. Choosing a gradient without PRO opens the paywall.
// ponytail: no NSColorPanel in the menu; the menu window closes when the panel takes focus.
struct Swatches: View {
    let key: String
    let hex: String
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Paint.free + Paint.pro, id: \.self) { c in
                let on = Paint.effective(hex, key) == c
                Button {
                    if !c.hasPrefix("g:") || store.allow() { UserDefaults.standard.set(c, forKey: key) }
                } label: {
                    Circle()
                        .fill(Paint.style(c))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.85 : 0.15), lineWidth: on ? 2 : 1))
                        .overlay(alignment: .topTrailing) {
                            if c.hasPrefix("g:") && !store.isPro {
                                Image(systemName: "lock.fill").font(.system(size: 6)).foregroundStyle(.white)
                                    .padding(1.5).background(Color.black.opacity(0.55), in: Circle()).offset(x: 3, y: -3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(c.hasPrefix("g:") ? "PRO color" : c)
            }
        }
    }
}

struct ClickEffectPicker: View {
    let value: String
    @ObservedObject private var store = Store.shared
    var body: some View {
        Picker("Effect", selection: Binding(get: { store.isPro ? value : "ripple" }, set: { v in
            if v == "ripple" || store.allow() { UserDefaults.standard.set(v, forKey: "clickAnim") }
        })) {
            Text("Ripple").tag("ripple")
            Text("Pulse ✦").tag("pulse")
            Text("Shrink ✦").tag("shrink")
            Text("Glitter ✦").tag("glitter")
        }
        .labelsHidden()
    }
}
