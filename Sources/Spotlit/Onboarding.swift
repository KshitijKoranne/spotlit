import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: Mascot

/// The fluffy mascot. Plays Mascot.mp4 in a loop if bundled, else shows Mascot.png with a gentle bob.
struct Mascot: View {
    var size: CGFloat = 200
    @State private var bob = false

    var body: some View {
        Group {
            if Bundle.main.url(forResource: "Mascot", withExtension: "mp4") != nil {
                LoopingVideo(name: "Mascot")
            } else if let img = NSImage(named: "Mascot") {
                Image(nsImage: img).resizable().scaledToFit()
                    .offset(y: bob ? -6 : 4)
                    .scaleEffect(x: bob ? 0.98 : 1.02, y: bob ? 1.03 : 0.97, anchor: .bottom)
                    .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever()) { bob = true } }
            } else {
                AppMark(size: size * 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

struct LoopingVideo: NSViewRepresentable {
    let name: String
    final class Coordinator { var looper: AVPlayerLooper? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return view }
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        player.play()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Warm card behind the mascot. Matches the mascot art background.
struct MascotStage<Content: View>: View {
    var height: CGFloat = 230
    @ViewBuilder let content: Content
    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color(hex: "#FFF3DF"), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: Paywall

struct PaywallView: View {
    var inOnboarding = false
    var onDone: () -> Void = { Windows.close("pro") }
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 18) {
            MascotStage(height: inOnboarding ? 170 : 190) { Mascot(size: inOnboarding ? 160 : 180) }
            VStack(spacing: 6) {
                Text(store.isPro ? "You have PRO. Thank you!" : "Unlock Spotlit PRO")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("One payment of \(store.price). No subscription. Yours on every Mac with your Apple Account.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            ProFeatureList().padding(.horizontal, 6)
            VStack(spacing: 10) {
                Button {
                    store.isPro ? onDone() : Task { await store.buy() }
                } label: {
                    HStack(spacing: 8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.isPro ? "Continue" : "Unlock for \(store.price)").font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#F5A000"))
                .controlSize(.large)
                .disabled(store.busy)
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 18) {
                    Button("Restore Purchase") { Task { await store.restore() } }
                    if !store.isPro { Button(inOnboarding ? "Maybe Later" : "Not Now", action: onDone) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .disabled(store.busy)

                if let m = store.message {
                    Text(m).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(inOnboarding ? 0 : 28)
        .frame(width: inOnboarding ? nil : 520)
        .onChange(of: store.isPro) { pro in
            if pro { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: onDone) }
        }
    }
}

// MARK: Onboarding

enum Onboarding {
    static func show() { Windows.show("onboarding", title: "Welcome to Spotlit", transparent: true, OnboardingView()) }
    static func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: "onboarded") { show() }
    }
}

struct OnboardingView: View {
    @State private var step = 0
    @AppStorage("shape") private var shape = "circle"
    @AppStorage("size") private var size = 56.0
    @AppStorage("haloStyle") private var style = "fill"
    @AppStorage("haloColor") private var color = "#FFB020"
    @AppStorage("opacity") private var opacity = 0.35
    @AppStorage("clicksOn") private var clicksOn = true
    @AppStorage("shake") private var shake = true
    @State private var login = true

    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: pickHalo
                case 2: basics
                case 3: PaywallView(inOnboarding: true) { next() }
                default: done
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Color(hex: "#F5A000") : Color.primary.opacity(0.15))
                            .frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 && step < steps - 1 {
                    Button("Back") { go(step - 1) }.controlSize(.large)
                }
                if step != 3 {
                    Button(step == steps - 1 ? "Start Using Spotlit" : step == 0 ? "Get Started" : "Continue") { next() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#F5A000"))
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 600, height: 640)
        .clipped()
    }

    private func go(_ s: Int) { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step = s } }

    private func next() {
        if step == 2 {
            try? login ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
        if step == steps - 1 {
            UserDefaults.standard.set(true, forKey: "onboarded")
            Windows.close("onboarding")
        } else {
            go(step + 1)
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            MascotStage(height: 320) { Mascot(size: 300) }
            VStack(spacing: 8) {
                Text("Hi, I'm Spotlit!").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("I keep your pointer easy to see on calls, in demos and in every screen recording.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var pickHalo: some View {
        VStack(spacing: 18) {
            Title(text: "Pick your halo", sub: "Move your pointer. The halo already follows it.")
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#2B3A67"), Color(hex: "#151B33")], startPoint: .top, endPoint: .bottom))
                HaloView(shape: shape, size: max(size, 70), style: style, color: color, opacity: opacity)
                    .overlay(Image(systemName: "cursorarrow").font(.system(size: 26)).foregroundStyle(.white).shadow(radius: 2).offset(x: 6, y: 9))
            }
            .frame(height: 190)
            VStack(spacing: 12) {
                Picker("Shape", selection: $shape) {
                    Text("Circle").tag("circle")
                    Text("Squircle").tag("squircle")
                    Text("Rhombus").tag("rhombus")
                }.pickerStyle(.segmented).labelsHidden()
                Picker("Style", selection: $style) {
                    Text("Fill").tag("fill")
                    Text("Ring").tag("ring")
                }.pickerStyle(.segmented).labelsHidden()
                HStack { Text("Size").foregroundStyle(.secondary); Slider(value: $size, in: 20...160) }
                Swatches(key: "haloColor", hex: color).scaleEffect(1.25).padding(.top, 4)
            }
            .font(.system(size: 13))
        }
    }

    private var basics: some View {
        VStack(spacing: 18) {
            Title(text: "A few good basics", sub: "Change these any time from the menu bar.")
            VStack(spacing: 0) {
                OptionRow(icon: "cursorarrow.click", title: "Show my clicks", sub: "A ring appears on every click.", on: $clicksOn)
                Divider()
                OptionRow(icon: "hand.wave", title: "Shake to find the pointer", sub: "Shake the mouse and the halo grows.", on: $shake)
                Divider()
                OptionRow(icon: "power", title: "Open at login", sub: "Spotlit is ready when your Mac starts.", on: $login)
            }
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(Color(hex: "#F5A000"))
                Text("Press \(HotKeys.label("toggle")) to turn Spotlit on or off.").font(.system(size: 13))
                Spacer()
            }
            .padding(14)
            .background(Color(hex: "#FFB020").opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var done: some View {
        VStack(spacing: 22) {
            MascotStage(height: 300) { Mascot(size: 280) }
            VStack(spacing: 8) {
                Text("You're all set").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Find me in the menu bar at the top of your screen. Click the pointer icon to change anything.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

private struct Title: View {
    let text: String, sub: String
    var body: some View {
        VStack(spacing: 6) {
            Text(text).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(sub).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

private struct OptionRow: View {
    let icon: String, title: String, sub: String
    @Binding var on: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: "#F5A000")).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $on).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 12)
    }
}

