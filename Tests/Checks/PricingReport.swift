//
//  PricingReport.swift
//  Ace — developer tooling
//
//  Prints the pricing worksheet.
//
//  Run:  swift run AceVerify --pricing
//
//  The numbers come from `PricingWorksheet`, which is the same code the app uses
//  on a real ledger. Here it's fed a synthetic ledger at three intensities so
//  the tiers can be sanity-checked before a single user exists — and re-run
//  later against a real one.
//

import Foundation

enum PricingReport {

    /// A ledger for a student who studies `sessionsPerWeek` times, talking for
    /// `minutes` each time.
    static func ledger(sessions: Int, minutes: Double) -> UsageLedger {
        var ledger = UsageLedger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<sessions {
            let id = ledger.begin(wasLive: true,
                                  now: start.addingTimeInterval(Double(index) * 86_400))
            // Voice splits roughly evenly between the student and Ace.
            ledger.record(UsageEvent(kind: .inputAudio, amount: minutes * 30), in: id)
            ledger.record(UsageEvent(kind: .outputAudio, amount: minutes * 30), in: id)
            ledger.record(UsageEvent(kind: .inputTokens,
                                     amount: TokenEstimator.transcriptTokens(seconds: minutes * 30)),
                          in: id)
            ledger.record(UsageEvent(kind: .outputTokens,
                                     amount: TokenEstimator.transcriptTokens(seconds: minutes * 30)),
                          in: id)
            ledger.end(id)
        }
        return ledger
    }

    static func print() {
        let bold = "\u{001B}[1m", dim = "\u{001B}[2m", reset = "\u{001B}[0m"

        Swift.print("""

        \(bold)Ace — pricing worksheet\(reset)
        \(dim)Computed by PricingWorksheet from measured usage.
        Rates: \(RateCard.realtimeVoice.label), last checked \(RateCard.realtimeVoice.checkedOn).
        Check current OpenAI pricing before relying on these.\(reset)
        """)

        // --- What a session costs -----------------------------------------
        Swift.print("\n\(bold)Cost per session\(reset)")
        for minutes in [5.0, 12.0, 30.0] {
            let worksheet = PricingWorksheet(ledger: ledger(sessions: 10, minutes: minutes))
            Swift.print(String(format: "  %5.0f min   full model $%.3f/session   mini $%.3f/session",
                               minutes, worksheet.measuredSessionCost,
                               worksheet.ledger.averageLiveSessionCost(rate: .realtimeMini)))
        }

        // --- Tier economics -------------------------------------------------
        let worksheet = PricingWorksheet(ledger: ledger(sessions: 20, minutes: 12))
        Swift.print("\n\(bold)Tiers — worst case, i.e. a subscriber using their whole allowance\(reset)")
        Swift.print(String(format: "  %-11@ %6@ %7@ %8@ %8@ %8@  %@",
                           "TIER" as NSString, "CAP" as NSString, "PRICE" as NSString,
                           "NET" as NSString, "COST" as NSString, "MARGIN" as NSString,
                           "MODEL" as NSString))
        for tier in [Tier.free, .pro, .unlimited] {
            let cost = worksheet.worstCaseCost(for: tier)
            let net = worksheet.netRevenue(for: tier)
            let margin = worksheet.worstCaseMargin(for: tier)
            let flag = worksheet.isSustainable(tier) ? "" : "  ← UNDERPRICED"
            let cap = tier.voiceMinutesPerMonth.map { String(format: "%.0fm", $0) } ?? "—"
            Swift.print(String(format: "  %-11@ %6@ %7.2f %8.2f %8.2f %8.2f  %@%@",
                               tier.displayName as NSString, cap as NSString,
                               tier.monthlyPrice, net, cost, margin,
                               tier.realtimeModel as NSString, flag as NSString))
        }

        // --- Suggested prices ------------------------------------------------
        Swift.print("\n\(bold)Suggested prices (50% margin on a fully-used allowance)\(reset)")
        for tier in [Tier.pro, .unlimited] {
            let suggested = worksheet.breakEvenPrice(for: tier)
            let verdict = suggested <= tier.monthlyPrice
                ? "current price has room"
                : "raise to at least this"
            Swift.print(String(format: "  %-11@ $%.2f   (%@)",
                               tier.displayName as NSString, suggested, verdict as NSString))
        }

        // --- The realistic picture ---------------------------------------------
        Swift.print("\n\(bold)Expected margin at realistic use (4 sessions a week, 12 min each)\(reset)")
        for tier in [Tier.pro, .unlimited] {
            let margin = worksheet.expectedMargin(for: tier, sessionsPerWeek: 4)
            let cost = worksheet.monthlyCost(sessionsPerWeek: 4, rate: tier.rateCard)
            Swift.print(String(format: "  %-11@ costs $%.2f, margin $%.2f per subscriber per month",
                               tier.displayName as NSString, cost, margin))
        }

        Swift.print("""

        \(dim)Read the worst-case table, not the expected one. A flat-rate tier is
        priced by its heaviest subscriber, not its average one — which is why the
        BYOK path exists: it is strictly better for anyone above the cap, and
        offering it keeps them off a tier that would lose money.\(reset)
        """)
    }
}
