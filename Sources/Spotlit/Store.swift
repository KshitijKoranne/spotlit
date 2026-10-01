import StoreKit
import SwiftUI

/// One non-consumable unlock. PRO features get a 5-second live preview, then the paywall.
final class Store: ObservableObject {
    static let shared = Store()
    static let productID = "in.kjrlabs.spotlit.pro"

    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var previewing: String?

    private var updates: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var revert: [String: Any] = [:]
    private var revertKeys: [String] = []

    var price: String { product?.displayPrice ?? "$2.99" }

    func start() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { [weak self] in
            await self?.refresh()
            let p = try? await Product.products(for: [Self.productID]).first
            await MainActor.run { self?.product = p }
        }
    }

    func refresh() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { pro = true }
        }
        await MainActor.run {
            isPro = pro
            if pro { endPreview(revert: false) } else { lockProFeatures() }
        }
    }

    func buy() async {
        await MainActor.run { busy = true; message = nil }
        defer { Task { @MainActor in busy = false } }
        do {
            if product == nil {
                let p = try await Product.products(for: [Self.productID]).first
                await MainActor.run { product = p }
            }
            guard let product else {
                await MainActor.run { message = "The App Store is not available. Try again later." }
                return
            }
            if case .success(let v) = try await product.purchase(), case .verified(let t) = v {
                await t.finish()
                await refresh()
            }
        } catch {
            await MainActor.run { message = error.localizedDescription }
        }
    }

    func restore() async {
        await MainActor.run { busy = true; message = nil }
        try? await AppStore.sync()
        await refresh()
        await MainActor.run {
            busy = false
            if !isPro { message = "No purchase found for this Apple Account." }
        }
    }

    // MARK: Preview gate

    /// Applies `changes` now. Without PRO they last 5 seconds, then the paywall opens.
    func preview(_ label: String, _ changes: [String: Any]) {
        let d = UserDefaults.standard
        if isPro { return changes.forEach { d.set($1, forKey: $0) } }
        endPreview(revert: true)
        revertKeys = Array(changes.keys)
        for k in revertKeys { revert[k] = d.object(forKey: k) }
        changes.forEach { d.set($1, forKey: $0) }
        previewing = label
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.endPreview(revert: true)
                Windows.paywall()
            }
        }
    }

    /// Turns a PRO switch on (with preview) or off.
    func set(_ key: String, _ on: Bool, label: String) {
        if on { return preview(label, [key: true]) }
        if revertKeys.contains(key) { endPreview(revert: true) }
        UserDefaults.standard.set(false, forKey: key)
    }

    func endPreview(revert doRevert: Bool) {
        previewTask?.cancel()
        previewTask = nil
        if doRevert {
            for k in revertKeys {
                if let v = revert[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        revert = [:]
        revertKeys = []
        previewing = nil
    }

    /// Without PRO, PRO-only settings go back to free values.
    private func lockProFeatures() {
        guard previewing == nil else { return }
        let d = UserDefaults.standard
        for k in ["dimOn", "keysOn", "magOn", "holdMode"] { d.set(false, forKey: k) }
        if d.string(forKey: "clickAnim") != "ripple" { d.set("ripple", forKey: "clickAnim") }
        for (k, v) in ["haloColor": "#FFB020", "leftColor": "#FFB020", "rightColor": "#0A84FF"]
        where d.string(forKey: k)?.hasPrefix("g:") == true { d.set(v, forKey: k) }
    }
}

/// Binding for a PRO switch.
func proBinding(_ key: String, _ label: String) -> Binding<Bool> {
    Binding(get: { UserDefaults.standard.bool(forKey: key) },
            set: { Store.shared.set(key, $0, label: label) })
}

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color(hex: "#3B2600"))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(hex: "#FFB020"), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
