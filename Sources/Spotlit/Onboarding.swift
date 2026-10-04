import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: Mascot

/// The fluffy mascot, Mascot.mp4 playing in a loop. The art has its own warm background, so it fills the card it sits in.
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
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        player.play()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { (nsView.layer as? AVPlayerLayer)?.player?.pause() }
}

/// Square card that holds the mascot art, so it never crops.
struct MascotStage: View {
    var height: CGFloat = 230
    var body: some View {
        Color(hex: "#F8E8BA")
            .overlay(LoopingVideo(name: "Mascot"))
            .frame(width: height, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height * 0.12, style: .continuous).strokeBorder(.black.opacity(0.06)))
            .shadow(color: Color(hex: "#B07A10").opacity(0.18), radius: 18, y: 8)
    }
}

// MARK: Paywall

struct PaywallView: View {
    var inOnboarding = false
    var onDone: () -> Void = { Windows.close("pro") }
    @ObservedObject private var store = Store.shared
    @State private var finished = false
    @State private var advance: Task<Void, Never>? = nil

    private var offerTrial: Bool { !store.trialUsed && !store.isPro }
    private var unlock: String { store.price.map { "Unlock for \($0)" } ?? "Unlock PRO" }
    private var oneTime: String { store.price.map { "a one-time purchase of \($0)" } ?? "a one-time purchase" }

    private var title: String {
        if store.purchased { return "You have PRO. Thank you!" }
        if store.isPro { return "Your free trial is on" }
        return store.trialUsed ? "Your trial has ended" : "Try Spotlit PRO free for 3 days"
    }

    private var subtitle: String {
        if store.purchased { return "Everything below is unlocked on every Mac with your Apple Account." }
        if store.isPro, let end = store.trialEndsAt {
            return "It ends \(end.formatted(date: .abbreviated, time: .shortened)). Then these features lock again. Keep them with \(oneTime). No subscription."
        }
        if store.trialUsed { return "These features are locked. Unlock them with \(oneTime). No subscription. Your settings are kept." }
        return "The trial lasts 3 days and costs nothing. When it ends, these features lock again. To keep them, unlock PRO with \(oneTime). No subscription."
    }

    var body: some View {
        VStack(spacing: inOnboarding ? 12 : 18) {
            MascotStage(height: inOnboarding ? 96 : 160)
            VStack(spacing: 6) {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProFeatureList().padding(.horizontal, 6)
            VStack(spacing: 8) {
                Button {
                    if store.purchased { finish() } else { Task { offerTrial ? await store.startTrial() : await store.buy() } }
                } label: {
                    HStack(spacing: 8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.purchased ? "Continue" : offerTrial ? "Start 3-Day Free Trial" : unlock).font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#F5A000"))
                .controlSize(.large)
                .disabled(store.busy)
                .keyboardShortcut(.defaultAction)

                if offerTrial {
                    Button { Task { await store.buy() } } label: {
                        Text(unlock).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(store.busy)
                }

                HStack(spacing: 18) {
                    Button("Restore Purchase") { Task { await store.restore() } }
                    if !store.purchased && store.price == nil { Button("Retry") { Task { await store.load() } } } // shows the price
                    if !store.purchased { Button(inOnboarding ? "Maybe Later" : "Not Now", action: finish) }
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
        .onChange(of: store.isPro) { _ in unlocked() }
        .onChange(of: store.purchased) { _ in unlocked() }
        .onDisappear { advance?.cancel() }
    }

    /// A started trial or a purchase moves on by itself.
    private func unlocked() {
        advance?.cancel()
        guard store.isPro else { return }
        advance = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { finish() }
        }
    }

    /// Button and auto-advance share this, so `onDone` runs once.
    private func finish() {
        advance?.cancel()
        guard !finished else { return }
        finished = true
        onDone()
    }
}

// MARK: Onboarding

@MainActor
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
    @AppStorage("hk.toggle") private var hkToggle = ""
    @State private var login = SMAppService.mainApp.status == .enabled // off until the user turns it on
    @ObservedObject private var store = Store.shared

    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: pickHalo
                case 2: basics
                case 3: PaywallView(inOnboarding: true) { if step == 3 { next() } }
                default: done
                }
            }
            .frame(maxHeight: .infinity)
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
                if step == 0 {
                    Button("Skip") { Windows.close("onboarding") }.controlSize(.large) // closing marks the tour as seen
                }
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
        .background(RadialGradient(colors: [Color(hex: "#FFB020").opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 420))
        .ignoresSafeArea()
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
            MascotStage(height: 300)
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
                HaloView(shape: shape, size: size, style: style, color: Paint.effective(color, "haloColor"), opacity: opacity)
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
                Text("Gradients are part of Spotlit PRO.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .opacity(store.isPro ? 0 : 1)
            }
            .font(.system(size: 13))
        }
    }

    private var basics: some View {
        VStack(spacing: 18) {
            MascotStage(height: 110)
            Title(text: "A few good basics", sub: "Change these any time from the menu bar.")
            VStack(spacing: 0) {
                OptionRow(icon: "cursorarrow.click", title: "Show my clicks", sub: "A ring appears on every click.", on: $clicksOn)
                Divider()
                OptionRow(icon: "hand.wave", title: "Shake to find the pointer", sub: "Shake the mouse and the halo grows.", on: $shake)
                Divider()
                OptionRow(icon: "power", title: "Open at Login", sub: "Spotlit is ready when your Mac starts.", on: $login)
            }
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(Color(hex: "#F5A000"))
                Text("Press \(HotKeys.label(value: hkToggle)) to turn Spotlit on or off.").font(.system(size: 13))
                Spacer()
            }
            .padding(14)
            .background(Color(hex: "#FFB020").opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var done: some View {
        VStack(spacing: 22) {
            MascotStage(height: 280)
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

