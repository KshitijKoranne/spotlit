import SwiftUI
import ServiceManagement

struct MenuView: View {
    @AppStorage("enabled") private var enabled = true
    @AppStorage("haloMode") private var mode = "always"
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"
    @AppStorage("opacity") private var opacity = 0.35
    @AppStorage("clicksOn") private var clicksOn = true
    @AppStorage("leftColor") private var leftColor = "#FFB020"
    @AppStorage("rightColor") private var rightColor = "#0A84FF"
    @AppStorage("dimOn") private var dimOn = false
    @AppStorage("dimAmount") private var dimAmount = 0.55
    @AppStorage("dimSize") private var dimSize = 170.0
    @AppStorage("keysOn") private var keysOn = false
    @AppStorage("keysMode") private var keysMode = "all"
    @AppStorage("shake") private var shake = true
    @AppStorage("inRecordings") private var inRecordings = true
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) { haloCard; clicksCard }
                VStack(spacing: 12) { dimCard; keysCard; generalCard }
            }
            HStack {
                Text("⌃⌥S turns Spotlit on or off").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Spotlit") { NSApp.terminate(nil) }.keyboardShortcut("q").controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 560)
        .onAppear {
            trusted = AXIsProcessTrusted()
            Overlay.shared.tracker.updateKeyMonitor()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [Color(hex: "#FFC94A"), Color(hex: "#FF9500")], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Spotlit").font(.system(size: 14, weight: .semibold))
                Text(enabled ? "On" : "Off").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
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
            Row(title: "Opacity") { Slider(value: $opacity, in: 0.1...0.9) }
            Row(title: "Style") {
                Picker("Style", selection: $style) {
                    Text("Fill").tag("fill")
                    Text("Ring").tag("ring")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Row(title: "Color") { Swatches(hex: $color) }
        }
    }

    private var clicksCard: some View {
        Card(title: "Clicks", icon: "cursorarrow.click", isOn: $clicksOn) {
            Row(title: "Left") { Swatches(hex: $leftColor) }
            Row(title: "Right") { Swatches(hex: $rightColor) }
        }
    }

    private var dimCard: some View {
        Card(title: "Spotlight Dim", icon: "circle.lefthalf.filled", isOn: $dimOn) {
            Row(title: "Amount") { Slider(value: $dimAmount, in: 0.2...0.85) }
            Row(title: "Size") { Slider(value: $dimSize, in: 80...400) }
        }
    }

    private var keysCard: some View {
        Card(title: "Keystrokes", icon: "keyboard", isOn: Binding(get: { keysOn }, set: { on in
            keysOn = on
            if on && !AXIsProcessTrusted() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            Overlay.shared.tracker.updateKeyMonitor()
        })) {
            Picker("Keys", selection: $keysMode) {
                Text("All keys").tag("all")
                Text("Shortcuts only").tag("shortcuts")
            }.pickerStyle(.segmented).labelsHidden()
            if keysOn && !trusted {
                Text("Allow Spotlit in System Settings › Privacy & Security › Accessibility, then open this menu again.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generalCard: some View {
        Card(title: "General", icon: "gearshape") {
            Toggle("Shake to find pointer", isOn: $shake)
            Toggle("Show in screenshots and recordings", isOn: $inRecordings)
            Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                loginOn = SMAppService.mainApp.status == .enabled
            }))
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    var isOn: Binding<Bool>? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(.system(size: 12, weight: .semibold))
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

// ponytail: fixed swatches, no color panel. The menu window closes when NSColorPanel takes focus.
struct Swatches: View {
    @Binding var hex: String
    private let colors = ["#FFB020", "#FF453A", "#FF2D92", "#34C759", "#0A84FF", "#BF5AF2", "#FFFFFF"]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(colors, id: \.self) { c in
                Button { hex = c } label: {
                    Circle()
                        .fill(Color(hex: c))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(hex == c ? 0.85 : 0.15), lineWidth: hex == c ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c)
            }
        }
    }
}
