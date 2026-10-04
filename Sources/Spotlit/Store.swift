import StoreKit
import SwiftUI

/// PRO is one non-consumable unlock, or a free 3-day trial sold as a second, free non-consumable (guideline 3.1.1).
/// PRO settings are never changed when PRO ends: they take effect only while `isPro`, so they come back with PRO.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let proID = "in.kjrlabs.spotlit.pro"
    static let trialID = "in.kjrlabs.spotlit.trial"
    static let trialLength: TimeInterval = 3 * 24 * 3600

    /// Starts from the last known state, so PRO settings don't blink off before StoreKit answers.
    @Published private(set) var isPro = UserDefaults.standard.bool(forKey: "proCache")
    @Published private(set) var purchased = false
    @Published private(set) var trialUsed = false
    @Published private(set) var trialEndsAt: Date?
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published var message: String?

    private var trialProduct: Product?
    private var updates: Task<Void, Never>?
    private var trialEnd: Task<Void, Never>?

    /// The App Store's local price. Nil until it loads: a guessed price would be wrong outside the US.
    var price: String? { product?.displayPrice }

    func start() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { [weak self] in
            await self?.refresh()
            await self?.load()
        }
    }

    /// Fetches the products if missing, e.g. when Spotlit opened at login before the network was up.
    func load() async {
        guard product == nil || trialProduct == nil,
              let ps = try? await Product.products(for: [Self.proID, Self.trialID]) else { return }
        product = ps.first { $0.id == Self.proID } ?? product
        trialProduct = ps.first { $0.id == Self.trialID } ?? trialProduct
    }

    func refresh() async {
        // latest(for:) sees a purchase at once; currentEntitlements can lag a moment behind it.
        func live(_ id: String) async -> StoreKit.Transaction? {
            guard case .verified(let t)? = await Transaction.latest(for: id), t.revocationDate == nil else { return nil }
            return t
        }
        let owned = await live(Self.proID) != nil, trialStart = await live(Self.trialID)?.purchaseDate
        let end = trialStart.map { $0 + Self.trialLength }
        let pro = owned || end.map { $0 > Date() } ?? false
        purchased = owned
        trialUsed = trialStart != nil
        trialEndsAt = end
        if isPro != pro { isPro = pro }
        if pro { message = nil }
        UserDefaults.standard.set(pro, forKey: "proCache")
        // One timer for the trial's end. The continuous clock keeps counting while the Mac sleeps.
        trialEnd?.cancel()
        if !owned, let end, end > Date() {
            trialEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow + 1), clock: .continuous)
                if !Task.isCancelled { await self?.refresh() }
            }
        }
    }

    func buy() async { await purchase(Self.proID) }
    func startTrial() async { await purchase(Self.trialID) }

    private func purchase(_ id: String) async {
        busy = true
        message = nil
        defer { busy = false }
        await load()
        guard let p = id == Self.proID ? product : trialProduct else {
            message = "The App Store is not available. Try again later."
            return
        }
        do {
            switch try await p.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                await refresh()
            case .success(.unverified):
                message = "The App Store could not verify the purchase. Try again later."
            case .pending:
                message = "Your purchase is waiting for approval. PRO unlocks once it is approved."
            default:
                break // Cancelled: nothing to say.
            }
        } catch StoreKitError.userCancelled {
            // The user closed the Apple Account sign-in.
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return // The user closed the Apple Account sign-in.
        } catch {
            message = error.localizedDescription
            return
        }
        await refresh()
        if !isPro { message = "No purchase found for this Apple Account." }
    }

    /// For a direct user action on a PRO feature: true with PRO, otherwise opens the paywall.
    func allow() -> Bool {
        if !isPro { Windows.paywall() }
        return isPro
    }

    /// A PRO switch as it takes effect: stored on, and PRO active.
    func on(_ key: String) -> Bool { isPro && UserDefaults.standard.bool(forKey: key) }

    /// Turning a PRO switch on needs PRO; turning it off never does.
    func set(_ key: String, _ on: Bool) {
        if !on || allow() { UserDefaults.standard.set(on, forKey: key) }
    }
}

/// Binding for a PRO switch. Shows the effective value; turning it on without PRO opens the paywall.
@MainActor
func proBinding(_ key: String) -> Binding<Bool> {
    Binding(get: { Store.shared.on(key) }, set: { Store.shared.set(key, $0) })
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
