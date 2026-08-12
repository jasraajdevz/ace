//
//  StoreController.swift
//  Ace
//
//  Metering, entitlements, and the paywall — which is OFF by default (§Part 5).
//
//  `PaywallFlag.isEnabled` gates the whole thing. With it off (the default, and
//  the state it ships in) Ace behaves as if everyone is on Unlimited: no caps,
//  no purchase prompts, no StoreKit calls. Flipping it on turns the metering
//  that was already running into an enforced limit.
//
//  That ordering is deliberate. The meter runs from day one so that by the time
//  the flag is flipped there's real usage data behind the prices — see
//  `PricingWorksheet`.
//

import Foundation
import Observation
#if canImport(StoreKit)
import StoreKit
#endif

// MARK: - The flag

/// Whether the paywall exists at all.
enum PaywallFlag {
    private static let key = "ace.paywall.enabled"

    /// **Off by default.** Nothing is gated until this is deliberately turned on.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Controller

@MainActor
@Observable
final class StoreController {

    private static let ledgerKey = "ace.usage.ledger"
    private static let tierKey = "ace.tier"

    private(set) var ledger = UsageLedger()
    /// The tier StoreKit says they have — or `.unlimited` while the paywall is
    /// off.
    private(set) var purchasedTier: Tier = .free
    private(set) var isRestoring = false
    private(set) var purchaseError: String?

    /// True when the student supplied their own OpenAI key.
    var hasOwnKey = false

    private var activeSessionID: UUID?

    init() {
        load()
    }

    // MARK: - Entitlement

    /// What they're allowed to do right now.
    var entitlement: Entitlement {
        // Paywall off → no limits, and none of the UI appears.
        guard PaywallFlag.isEnabled else {
            return Entitlement(tier: .unlimited, voiceMinutesUsed: 0, hasOwnKey: true)
        }
        let monthStart = UsageLedger.monthStart()
        return Entitlement(
            tier: hasOwnKey ? .bringYourOwnKey : purchasedTier,
            voiceMinutesUsed: ledger.usage(since: monthStart).voiceMinutes,
            hasOwnKey: hasOwnKey
        )
    }

    /// Whether realtime voice may be used. The provider asks before connecting.
    var canUseRealtimeVoice: Bool { entitlement.canUseRealtimeVoice }

    // MARK: - Metering

    func beginSession(isLive: Bool) {
        activeSessionID = ledger.begin(wasLive: isLive)
        save()
    }

    func record(_ event: UsageEvent) {
        guard let activeSessionID else { return }
        ledger.record(event, in: activeSessionID)
    }

    /// Convenience for the realtime provider: seconds of audio each way.
    func recordAudio(inputSeconds: Double, outputSeconds: Double) {
        record(UsageEvent(kind: .inputAudio, amount: inputSeconds))
        record(UsageEvent(kind: .outputAudio, amount: outputSeconds))
        // The realtime API bills transcript tokens alongside the audio.
        record(UsageEvent(kind: .inputTokens,
                          amount: TokenEstimator.transcriptTokens(seconds: inputSeconds)))
        record(UsageEvent(kind: .outputTokens,
                          amount: TokenEstimator.transcriptTokens(seconds: outputSeconds)))
    }

    func recordText(sent: String, received: String) {
        record(UsageEvent(kind: .inputTokens, amount: TokenEstimator.tokens(in: sent)))
        record(UsageEvent(kind: .outputTokens, amount: TokenEstimator.tokens(in: received)))
    }

    func endSession() {
        guard let activeSessionID else { return }
        ledger.end(activeSessionID)
        self.activeSessionID = nil
        save()
    }

    // MARK: - What it cost

    var thisMonth: (voiceMinutes: Double, tokens: Double, cost: Double) {
        ledger.usage(since: UsageLedger.monthStart())
    }

    var worksheet: PricingWorksheet { PricingWorksheet(ledger: ledger) }

    /// The line shown in Settings. Concrete numbers, because "you've used some
    /// of your allowance" tells nobody anything.
    var usageSummary: String {
        let month = thisMonth
        guard month.voiceMinutes > 0 || month.tokens > 0 else {
            return "No realtime voice used this month. On-device mode is free and unlimited."
        }
        let minutes = String(format: "%.0f", month.voiceMinutes)
        let cost = String(format: "%.2f", month.cost)
        return "\(minutes) min of realtime voice this month · about $\(cost) of OpenAI usage"
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
           let decoded = try? JSONDecoder().decode(UsageLedger.self, from: data) {
            ledger = decoded
        }
        purchasedTier = UserDefaults.standard.string(forKey: Self.tierKey)
            .flatMap(Tier.init(rawValue:)) ?? .free
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: Self.ledgerKey)
    }

    func resetUsage() {
        ledger = UsageLedger()
        save()
    }

    // MARK: - StoreKit 2

    #if canImport(StoreKit)

    /// Products, loaded lazily. Empty when the paywall is off — there's no
    /// reason to talk to the App Store for a feature that doesn't exist yet.
    private(set) var products: [Product] = []

    func loadProducts() async {
        guard PaywallFlag.isEnabled else { return }
        let ids = Tier.allCases.compactMap(\.storeProductID)
        guard !ids.isEmpty else { return }
        products = (try? await Product.products(for: ids)) ?? []
    }

    func product(for tier: Tier) -> Product? {
        guard let id = tier.storeProductID else { return nil }
        return products.first { $0.id == id }
    }

    /// Buy a tier. Returns true on success.
    @discardableResult
    func purchase(_ tier: Tier) async -> Bool {
        guard PaywallFlag.isEnabled, let product = product(for: tier) else { return false }
        purchaseError = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseError = "That purchase couldn't be verified."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                return true

            case .userCancelled:
                return false

            case .pending:
                purchaseError = "That's waiting on approval. Ace will unlock when it goes through."
                return false

            @unknown default:
                return false
            }
        } catch {
            purchaseError = "Couldn't complete that purchase. Nothing was charged."
            return false
        }
    }

    /// Re-read what Apple says they own. Runs on launch and after a purchase.
    func refreshEntitlements() async {
        guard PaywallFlag.isEnabled else {
            purchasedTier = .unlimited
            return
        }

        var best: Tier = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }

            if let tier = Tier.allCases.first(where: { $0.storeProductID == transaction.productID }),
               tier.monthlyPrice > best.monthlyPrice {
                best = tier
            }
        }
        purchasedTier = best
        UserDefaults.standard.set(best.rawValue, forKey: Self.tierKey)
    }

    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Listens for renewals and revocations that happen outside the app.
    func startTransactionListener() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }

    #else

    func loadProducts() async {}
    @discardableResult func purchase(_ tier: Tier) async -> Bool { false }
    func refreshEntitlements() async { purchasedTier = .unlimited }
    func restore() async {}

    #endif
}
