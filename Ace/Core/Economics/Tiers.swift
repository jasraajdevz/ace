//
//  Tiers.swift
//  Ace
//
//  What each tier gets, what it costs, and how the caps are enforced (§Part 5).
//
//  Three rules shape all of it:
//
//  1. **Free is not a trial.** Everything on-device is unlimited on every tier,
//     forever, with no key. Capture, OCR, quizzes, flashcards, the Socratic
//     tutor, the system voice, body doubling, speaking drills, the widget — none
//     of it costs anything to run, so none of it is gated. What the paid tiers
//     buy is the *realtime voice*, which is the only thing with a marginal cost.
//
//  2. **Caps degrade, never lock.** Hitting a cap switches you to Demo Mode
//     with one sentence. It never blocks studying (§10), and Demo Mode is a
//     real product, not a punishment.
//
//  3. **BYOK exists so heavy users can't bleed margin.** A student who wants
//     four hours of voice a day should be spending their own OpenAI credit, and
//     Ace should say so plainly rather than either eating the cost or hiding
//     behind a fair-use clause.
//

import Foundation

// MARK: - Tiers

enum Tier: String, Sendable, Codable, CaseIterable, Identifiable {
    case free
    case pro
    case unlimited
    /// Using their own OpenAI key. No cap, no charge, no margin.
    case bringYourOwnKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .free: "Free"
        case .pro: "Pro"
        case .unlimited: "Unlimited"
        case .bringYourOwnKey: "Your own key"
        }
    }

    /// Realtime voice minutes a month. Nil means uncapped.
    ///
    /// These numbers are not guesses — they come from `PricingWorksheet` run
    /// against real metered usage, and they were revised downward hard once it
    /// reported the truth. See DECISIONS.md D38.
    var voiceMinutesPerMonth: Double? {
        switch self {
        case .free: 15
        case .pro: 150              // 2.5 hours
        case .unlimited: 400        // ~6.5 hours; a soft ceiling, not infinity
        case .bringYourOwnKey: nil
        }
    }

    /// Which realtime model this tier runs on.
    ///
    /// Subscription tiers use the mini model. This is the single decision that
    /// makes a $9.99 tier possible at all: the full realtime model costs about
    /// six times as much per minute of audio, and at that rate no flat-rate
    /// price under about $60 survives a subscriber who actually uses their
    /// allowance. Mini is more than good enough for Socratic tutoring, where
    /// replies are two or three sentences.
    ///
    /// Bring-your-own-key gets the full model, because they're paying for it.
    var realtimeModel: String {
        switch self {
        case .free, .pro, .unlimited: "gpt-realtime-mini"
        case .bringYourOwnKey: RealtimeModel.default
        }
    }

    /// The rate card this tier is costed against.
    var rateCard: RateCard {
        switch self {
        case .free, .pro, .unlimited: .realtimeMini
        case .bringYourOwnKey: .realtimeVoice
        }
    }

    /// Monthly price in US dollars.
    var monthlyPrice: Double {
        switch self {
        case .free, .bringYourOwnKey: 0
        case .pro: 9.99
        case .unlimited: 19.99
        }
    }

    var storeProductID: String? {
        switch self {
        case .pro: "com.acestudy.Ace.pro.monthly"
        case .unlimited: "com.acestudy.Ace.unlimited.monthly"
        case .free, .bringYourOwnKey: nil
        }
    }

    /// The one-line pitch.
    var summary: String {
        switch self {
        case .free:
            "Everything on-device, forever. 15 minutes of realtime voice a month."
        case .pro:
            "2½ hours of realtime voice a month. Enough for most people."
        case .unlimited:
            "Over 6 hours a month. For people who talk through everything."
        case .bringYourOwnKey:
            "Use your own OpenAI key. No limits from us, and you pay OpenAI directly."
        }
    }

    /// What every tier includes, free ones too. Written out because the point
    /// of the list is that it's long.
    static let alwaysIncluded = [
        "Photo, scan and paste capture with on-device reading",
        "Unlimited quizzes and flashcards",
        "The Socratic tutor, on-device",
        "Spaced repetition and progress",
        "Study-with-me, the Guardian and quiet mode",
        "Focus music and speaking drills",
        "The home-screen widget",
        "Everything works offline"
    ]

    /// Whether this tier ever touches the network for AI.
    var usesMeteredVoice: Bool {
        switch self {
        case .free, .pro, .unlimited: true
        case .bringYourOwnKey: false      // metered, but not against our caps
        }
    }
}

// MARK: - Entitlement

/// What the student is allowed to do right now.
struct Entitlement: Sendable, Equatable {
    var tier: Tier
    /// Voice minutes used this calendar month.
    var voiceMinutesUsed: Double
    /// True when the student supplied their own key.
    var hasOwnKey: Bool

    /// Minutes left before the cap. Nil when uncapped.
    var voiceMinutesRemaining: Double? {
        guard !hasOwnKey, let cap = tier.voiceMinutesPerMonth else { return nil }
        return max(0, cap - voiceMinutesUsed)
    }

    /// Can realtime voice be used right now?
    var canUseRealtimeVoice: Bool {
        if hasOwnKey { return true }
        guard let remaining = voiceMinutesRemaining else { return true }
        return remaining > 0
    }

    /// Fraction of the monthly allowance used, 0...1.
    var usageFraction: Double {
        guard !hasOwnKey, let cap = tier.voiceMinutesPerMonth, cap > 0 else { return 0 }
        return min(voiceMinutesUsed / cap, 1)
    }

    /// Warn before the cap rather than at it, so a session doesn't end
    /// mid-sentence without warning.
    var isNearingCap: Bool {
        guard !hasOwnKey, voiceMinutesRemaining != nil else { return false }
        return usageFraction >= 0.8 && canUseRealtimeVoice
    }

    /// What the student is told when the cap is reached.
    ///
    /// Note what this does NOT say: it doesn't say "upgrade to continue", and it
    /// doesn't say studying has stopped — because it hasn't (§10).
    var capMessage: String? {
        guard !canUseRealtimeVoice else {
            guard isNearingCap else { return nil }
            let left = Int(voiceMinutesRemaining ?? 0)
            return "\(left) minutes of realtime voice left this month. On-device mode is unlimited."
        }
        return "You've used this month's realtime voice. I've switched to on-device mode — "
            + "everything still works, I'll just sound a bit different."
    }

    static let freeDefault = Entitlement(tier: .free, voiceMinutesUsed: 0, hasOwnKey: false)
}

// MARK: - The pricing worksheet

/// Works out what a user costs and what to charge, from Ace's own measurements
/// (§Part 5: "computes real per-user cost from the app's own measured usage and
/// derives suggested prices").
///
/// Every number below is derived, not asserted — feed it a real ledger and it
/// tells you the truth about your margins, including when the truth is that a
/// tier is underpriced.
struct PricingWorksheet: Sendable {

    let ledger: UsageLedger
    let rate: RateCard
    /// Share of revenue taken by the App Store. 30% falling to 15% after a
    /// year, so the first-year number is the one that matters for planning.
    var storeCommission: Double = 0.30

    init(ledger: UsageLedger, rate: RateCard = .realtimeVoice) {
        self.ledger = ledger
        self.rate = rate
    }

    // MARK: Measured

    var measuredSessionCost: Double { ledger.averageLiveSessionCost(rate: rate) }
    var measuredSessionMinutes: Double { ledger.averageLiveSessionMinutes() }

    /// Cost of a month at a given intensity, from this device's real per-session
    /// numbers, costed against a given rate card.
    func monthlyCost(sessionsPerWeek: Double, rate: RateCard? = nil) -> Double {
        let card = rate ?? self.rate
        let perSession = ledger.averageLiveSessionCost(rate: card)
        return perSession * sessionsPerWeek * 4.33
    }

    /// The cost of a tier's cap being used in full — the worst case that
    /// actually matters, because a flat-rate tier is priced by its heaviest
    /// user, not its average one.
    func worstCaseCost(for tier: Tier) -> Double {
        guard let cap = tier.voiceMinutesPerMonth else { return .infinity }
        // Costed against the tier's own rate card — a tier on the mini model is
        // a fundamentally different business than one on the full model.
        let rate = tier.rateCard
        // Voice minutes split roughly evenly between the student talking and
        // Ace answering.
        let usage = SessionUsage(wasLive: true)
        var full = usage
        full.inputAudioSeconds = cap * 60 * 0.5
        full.outputAudioSeconds = cap * 60 * 0.5
        full.inputTokens = TokenEstimator.transcriptTokens(seconds: cap * 60 * 0.5)
        full.outputTokens = TokenEstimator.transcriptTokens(seconds: cap * 60 * 0.5)
        return rate.cost(of: full)
    }

    /// Revenue kept after the store's cut.
    func netRevenue(for tier: Tier) -> Double {
        tier.monthlyPrice * (1 - storeCommission)
    }

    /// Margin if a subscriber uses their whole allowance.
    func worstCaseMargin(for tier: Tier) -> Double {
        netRevenue(for: tier) - worstCaseCost(for: tier)
    }

    /// Margin at a realistic intensity, costed against the tier's own card.
    ///
    /// Using the full-model card here while the worst-case table uses the mini
    /// card would make the report contradict itself — which is exactly the sort
    /// of quiet inconsistency that makes a spreadsheet dangerous.
    func expectedMargin(for tier: Tier, sessionsPerWeek: Double) -> Double {
        netRevenue(for: tier)
            - monthlyCost(sessionsPerWeek: sessionsPerWeek, rate: tier.rateCard)
    }

    /// The price that would break even on a fully-used allowance, with headroom.
    func breakEvenPrice(for tier: Tier, targetMargin: Double = 0.5) -> Double {
        let cost = worstCaseCost(for: tier)
        guard cost.isFinite, cost > 0 else { return 0 }
        // price × (1 − commission) × (1 − targetMargin) = cost
        let price = cost / ((1 - storeCommission) * (1 - targetMargin))
        // Round up to the nearest .99, which is what a price actually looks like.
        return (price).rounded(.up) - 0.01
    }

    /// Is this tier survivable if everyone maxes it out?
    func isSustainable(_ tier: Tier) -> Bool {
        guard tier.monthlyPrice > 0 else { return true }
        return worstCaseMargin(for: tier) > 0
    }

    /// The plain-English summary that goes in the README.
    func summary(for tier: Tier) -> String {
        guard tier.monthlyPrice > 0 else {
            return "\(tier.displayName): no revenue by design."
        }
        let worst = worstCaseCost(for: tier)
        let net = netRevenue(for: tier)
        let margin = worstCaseMargin(for: tier)
        let verdict = margin > 0
            ? "sustainable"
            : "UNDERPRICED — suggested at least $\(String(format: "%.2f", breakEvenPrice(for: tier)))"
        return String(
            format: "%@ at $%.2f: net $%.2f, worst-case cost $%.2f, margin $%.2f — %@",
            tier.displayName, tier.monthlyPrice, net, worst, margin, verdict
        )
    }
}
