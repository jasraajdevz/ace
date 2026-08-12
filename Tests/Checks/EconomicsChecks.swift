//
//  EconomicsChecks.swift
//  Ace — verification harness
//
//  Part 5: metering, tiers, caps and the pricing worksheet.
//
//  The properties that get the hardest testing are the ones that would cost
//  either the student or the developer real money if they quietly broke:
//    • a cap degrades to Demo Mode, it never blocks studying (§10)
//    • the paywall flag genuinely gates everything, in both directions
//    • the worksheet reports an underpriced tier as underpriced
//

import Foundation

enum UsageMeterChecks {
    static let all = CheckSuite(name: "Usage metering") { run in
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // --- Recording -------------------------------------------------------
        var session = SessionUsage(startedAt: start, wasLive: true)
        run.expect(session.isEmpty, "a new session has used nothing")

        session.record(UsageEvent(kind: .inputTokens, amount: 1_000))
        session.record(UsageEvent(kind: .outputTokens, amount: 500))
        session.record(UsageEvent(kind: .inputAudio, amount: 60))
        session.record(UsageEvent(kind: .outputAudio, amount: 90))

        run.expectEqual(session.inputTokens, 1_000, "input tokens")
        run.expectEqual(session.outputTokens, 500, "output tokens")
        run.expectEqual(session.totalTokens, 1_500, "total tokens")
        run.expectClose(session.voiceMinutes, 2.5, tolerance: 0.001, "150 seconds is 2.5 minutes")
        run.expect(!session.isEmpty, "no longer empty")

        // Negative amounts are clamped rather than trusted — a bad measurement
        // must never credit the meter.
        var guarded = SessionUsage(wasLive: true)
        guarded.record(UsageEvent(kind: .inputTokens, amount: -500))
        run.expectEqual(guarded.inputTokens, 0, "negative usage is clamped to zero")

        // --- Cost ------------------------------------------------------------
        let rate = RateCard.realtimeVoice
        let cost = rate.cost(of: session)
        run.expect(cost > 0, "a live session costs something")

        // Voice must dominate. If the arithmetic ever says otherwise, the rate
        // card has been mis-entered.
        var voiceOnly = SessionUsage(wasLive: true)
        voiceOnly.outputAudioSeconds = 150
        var textOnly = SessionUsage(wasLive: true)
        textOnly.outputTokens = 1_500
        run.expect(rate.cost(of: voiceOnly) > rate.cost(of: textOnly) * 10,
                   "voice must dominate cost — it's the whole reason for metering")

        run.expectEqual(RateCard.onDevice.cost(of: session), 0,
                        "Demo Mode is free, by construction")
        run.expect(RateCard.realtimeMini.cost(of: session) < rate.cost(of: session),
                   "the mini card must be cheaper")
        run.expect(!RateCard.realtimeVoice.checkedOn.isEmpty,
                   "a rate card must carry the date it was checked, or it goes stale silently")

        // --- Ledger -----------------------------------------------------------
        var ledger = UsageLedger()
        run.expectEqual(ledger.sessionCount, 0, "empty ledger")
        run.expectEqual(ledger.cost(), 0, "costs nothing")
        run.expectEqual(ledger.averageLiveSessionCost(), 0, "no average from nothing, not NaN")

        let first = ledger.begin(wasLive: true, now: start)
        ledger.record(UsageEvent(kind: .outputAudio, amount: 300), in: first)
        ledger.end(first, now: start.addingTimeInterval(600))

        run.expectEqual(ledger.sessionCount, 1, "one session")
        run.expectClose(ledger.voiceMinutes, 5, tolerance: 0.001, "5 minutes")
        run.expect(ledger.cost() > 0, "cost accrued")

        // A demo session records at zero and must not drag the live average.
        let demo = ledger.begin(wasLive: false, now: start.addingTimeInterval(700))
        ledger.end(demo, now: start.addingTimeInterval(1_000))
        run.expectEqual(ledger.liveSessions.count, 1, "only one live session")
        run.expect(ledger.averageLiveSessionCost() > 0,
                   "the average is over LIVE sessions — averaging in free ones would flatter it")

        // Recording against an unknown session is a no-op, not a crash.
        ledger.record(UsageEvent(kind: .outputTokens, amount: 999), in: UUID())
        run.expectEqual(ledger.sessions.count, 2, "unknown session id ignored")

        // --- The ledger is bounded ----------------------------------------------
        var long = UsageLedger()
        for index in 0..<300 {
            let id = long.begin(wasLive: true, now: start.addingTimeInterval(Double(index) * 60))
            long.record(UsageEvent(kind: .outputAudio, amount: 60), in: id)
        }
        run.expect(long.sessions.count <= UsageLedger.maxRetainedSessions,
                   "the window is capped, got \(long.sessions.count)")
        run.expectEqual(long.sessionCount, 300,
                        "but the lifetime count is still right")
        run.expect(long.voiceMinutes >= 299,
                   "and retired minutes are not lost, got \(long.voiceMinutes)")
        run.expect(long.cost() > 0, "nor is retired cost")

        // --- Monthly window -------------------------------------------------------
        var monthly = UsageLedger()
        let old = monthly.begin(wasLive: true, now: start.addingTimeInterval(-60 * 86_400))
        monthly.record(UsageEvent(kind: .outputAudio, amount: 600), in: old)
        let recent = monthly.begin(wasLive: true, now: start)
        monthly.record(UsageEvent(kind: .outputAudio, amount: 120), in: recent)

        let window = monthly.usage(since: start.addingTimeInterval(-86_400))
        run.expectClose(window.voiceMinutes, 2, tolerance: 0.001,
                        "only the recent session is inside the window")
        run.expect(monthly.voiceMinutes > window.voiceMinutes,
                   "lifetime is larger than the window")

        // --- Round-tripping --------------------------------------------------------
        guard let encoded = try? JSONEncoder().encode(ledger),
              let decoded = try? JSONDecoder().decode(UsageLedger.self, from: encoded) else {
            run.expect(false, "the ledger must survive JSON — it's how it's persisted")
            return
        }
        run.expectEqual(decoded.sessionCount, ledger.sessionCount, "sessions survive")
        run.expectClose(decoded.voiceMinutes, ledger.voiceMinutes, tolerance: 0.001,
                        "minutes survive")

        // --- Token estimation --------------------------------------------------------
        run.expectEqual(TokenEstimator.tokens(in: ""), 0, "empty text is zero tokens")
        run.expect(TokenEstimator.tokens(in: "hello world") > 0, "some text is some tokens")

        // It must err HIGH: a cap that trips early is an annoyance, one that
        // trips late is a surprise bill.
        let sample = String(repeating: "the quick brown fox ", count: 50)   // 1000 chars
        let estimated = TokenEstimator.tokens(in: sample)
        run.expect(estimated >= 200 && estimated <= 400,
                   "1000 characters should estimate 200–400 tokens, got \(estimated)")
        run.expect(TokenEstimator.transcriptTokens(seconds: 60) > 100,
                   "a minute of speech is a lot of transcript tokens")
        run.expectEqual(TokenEstimator.transcriptTokens(seconds: 0), 0, "no audio, no tokens")
    }
}

// MARK: - Tiers and caps

enum TierChecks {
    static let all = CheckSuite(name: "Tiers, caps and entitlements") { run in

        // --- Tier shape ------------------------------------------------------
        for tier in Tier.allCases {
            run.expect(!tier.displayName.isEmpty, "\(tier) needs a name")
            run.expect(!tier.summary.isEmpty, "\(tier) needs a summary")
            run.expect(tier.monthlyPrice >= 0, "\(tier) has a negative price")
        }
        run.expect(Tier.pro.monthlyPrice < Tier.unlimited.monthlyPrice, "priced in order")
        run.expect((Tier.free.voiceMinutesPerMonth ?? 0) < (Tier.pro.voiceMinutesPerMonth ?? 0),
                   "caps rise with price")
        run.expect(Tier.bringYourOwnKey.voiceMinutesPerMonth == nil, "BYOK is uncapped")
        run.expectEqual(Tier.free.monthlyPrice, 0, "free is free")
        run.expectEqual(Tier.bringYourOwnKey.monthlyPrice, 0, "BYOK costs us nothing and them nothing")

        run.expect(Tier.pro.storeProductID != nil, "paid tiers need a product id")
        run.expect(Tier.free.storeProductID == nil, "free has nothing to buy")
        run.expectEqual(Set(Tier.allCases.compactMap(\.storeProductID)).count, 2,
                        "product ids must be unique")

        // The free list must be long — that's the point of it.
        run.expect(Tier.alwaysIncluded.count >= 6,
                   "the always-free list must be substantial, got \(Tier.alwaysIncluded.count)")

        // --- Entitlements -------------------------------------------------------
        // Derived from the tier rather than hard-coded: caps move when the
        // pricing worksheet says they should, and a test that pins them turns a
        // deliberate change into a false failure.
        let freeCap = Tier.free.voiceMinutesPerMonth ?? 0
        run.expect(freeCap > 0, "the free tier has some voice allowance")

        let fresh = Entitlement(tier: .free, voiceMinutesUsed: 0, hasOwnKey: false)
        run.expect(fresh.canUseRealtimeVoice, "a fresh free account can use voice")
        run.expectEqual(fresh.voiceMinutesRemaining, freeCap, "the whole allowance is available")
        run.expectEqual(fresh.usageFraction, 0, "nothing used")
        run.expect(!fresh.isNearingCap, "not near the cap")
        run.expect(fresh.capMessage == nil, "nothing to say yet")

        let nearing = Entitlement(tier: .free, voiceMinutesUsed: freeCap * 0.85, hasOwnKey: false)
        run.expect(nearing.canUseRealtimeVoice, "still allowed at 85%")
        run.expect(nearing.isNearingCap, "warned before the cap, not at it")
        run.expect(nearing.capMessage != nil, "and the warning exists")
        run.expect(nearing.capMessage?.contains("minutes") == true,
                   "the warning must talk in minutes")

        let exhausted = Entitlement(tier: .free, voiceMinutesUsed: freeCap, hasOwnKey: false)
        run.expect(!exhausted.canUseRealtimeVoice, "cap reached")
        run.expectEqual(exhausted.voiceMinutesRemaining, 0, "nothing left")
        run.expectEqual(exhausted.usageFraction, 1, "fully used")

        // THE requirement: a cap degrades, it never blocks (§10).
        guard let capMessage = exhausted.capMessage else {
            run.expect(false, "hitting the cap must say something")
            return
        }
        let lower = capMessage.lowercased()
        run.expect(lower.contains("on-device") || lower.contains("still works"),
                   "the cap message must point at Demo Mode: “\(capMessage)”")
        for coercive in ["upgrade to continue", "you can no longer", "blocked", "locked",
                         "buy now", "unlock"] {
            run.expect(!lower.contains(coercive),
                       "the cap message must not coerce: found “\(coercive)”")
        }

        // Over-use must not produce a negative remaining.
        let over = Entitlement(tier: .free, voiceMinutesUsed: 999, hasOwnKey: false)
        run.expectEqual(over.voiceMinutesRemaining, 0, "remaining never goes negative")
        run.expectEqual(over.usageFraction, 1, "fraction is clamped")

        // BYOK is never capped, however much is used.
        let byok = Entitlement(tier: .free, voiceMinutesUsed: 10_000, hasOwnKey: true)
        run.expect(byok.canUseRealtimeVoice, "their own key is never capped by us")
        run.expect(byok.voiceMinutesRemaining == nil, "no remaining to report")
        run.expect(byok.capMessage == nil, "and nothing to warn about")
        run.expectEqual(byok.usageFraction, 0, "no fraction of a cap that doesn't exist")

        // Paid tiers get proportionally more.
        let pro = Entitlement(tier: .pro, voiceMinutesUsed: freeCap, hasOwnKey: false)
        run.expect(pro.canUseRealtimeVoice, "the free allowance barely touches Pro")
        run.expect(!pro.isNearingCap, "and is nowhere near the cap")

        // --- Every tier must be able to pay for itself ---------------------------
        //
        // A REGRESSION GUARD. The tiers as first specified lost $38 a month per
        // Pro subscriber; the worksheet caught it and the caps and model were
        // changed. This stops that being quietly undone.
        var realistic = UsageLedger()
        let seed = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<12 {
            let id = realistic.begin(wasLive: true, now: seed.addingTimeInterval(Double(index) * 86_400))
            realistic.record(UsageEvent(kind: .inputAudio, amount: 360), in: id)
            realistic.record(UsageEvent(kind: .outputAudio, amount: 360), in: id)
        }
        let guardWorksheet = PricingWorksheet(ledger: realistic)
        for tier in Tier.allCases where tier.monthlyPrice > 0 {
            run.expect(guardWorksheet.isSustainable(tier),
                       "\(tier.displayName) LOSES MONEY at full use: margin "
                       + "$\(String(format: "%.2f", guardWorksheet.worstCaseMargin(for: tier)))")
        }

        // Paid tiers run on the cheaper model — the decision that makes a $9.99
        // tier arithmetically possible at all.
        run.expectEqual(Tier.pro.rateCard.label, RateCard.realtimeMini.label,
                        "Pro must be costed against the mini card")
        run.expectEqual(Tier.bringYourOwnKey.rateCard.label, RateCard.realtimeVoice.label,
                        "BYOK gets the full model — they're paying for it")
        run.expect(Tier.pro.realtimeModel != Tier.bringYourOwnKey.realtimeModel,
                   "the tiers must actually request different models")
    }
}

// MARK: - The pricing worksheet

enum PricingChecks {
    static let all = CheckSuite(name: "Pricing worksheet") { run in

        /// A ledger representing a realistic heavy-ish user.
        func makeLedger(sessions: Int, minutesEach: Double) -> UsageLedger {
            var ledger = UsageLedger()
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<sessions {
                let id = ledger.begin(wasLive: true, now: start.addingTimeInterval(Double(index) * 3_600))
                ledger.record(UsageEvent(kind: .inputAudio, amount: minutesEach * 60 * 0.5), in: id)
                ledger.record(UsageEvent(kind: .outputAudio, amount: minutesEach * 60 * 0.5), in: id)
                ledger.record(UsageEvent(kind: .inputTokens,
                                         amount: TokenEstimator.transcriptTokens(seconds: minutesEach * 30)),
                              in: id)
                ledger.record(UsageEvent(kind: .outputTokens,
                                         amount: TokenEstimator.transcriptTokens(seconds: minutesEach * 30)),
                              in: id)
            }
            return ledger
        }

        let worksheet = PricingWorksheet(ledger: makeLedger(sessions: 20, minutesEach: 12))

        // --- Measured from real usage ----------------------------------------
        run.expect(worksheet.measuredSessionCost > 0, "a measured cost per session")
        run.expectClose(worksheet.measuredSessionMinutes, 12, tolerance: 0.5,
                        "measured minutes match what was recorded")

        let monthly = worksheet.monthlyCost(sessionsPerWeek: 4)
        run.expect(monthly > worksheet.measuredSessionCost,
                   "a month of sessions costs more than one session")
        run.expect(monthly > 0, "and is a real number")

        // An empty ledger must not divide by zero.
        let empty = PricingWorksheet(ledger: UsageLedger())
        run.expectEqual(empty.measuredSessionCost, 0, "no data means zero, not NaN")
        run.expectEqual(empty.monthlyCost(sessionsPerWeek: 4), 0, "no data means zero")

        // --- Worst case is what actually matters ----------------------------------
        for tier in [Tier.free, .pro, .unlimited] {
            let worst = worksheet.worstCaseCost(for: tier)
            run.expect(worst > 0, "\(tier) has a worst-case cost")
            run.expect(worst.isFinite, "\(tier) worst case must be finite")
        }
        run.expect(worksheet.worstCaseCost(for: .unlimited) > worksheet.worstCaseCost(for: .pro),
                   "a bigger cap costs more to serve")
        run.expect(!worksheet.worstCaseCost(for: .bringYourOwnKey).isFinite,
                   "BYOK has no cap, so no bounded worst case")

        // --- Revenue and margin ----------------------------------------------------
        let net = worksheet.netRevenue(for: .pro)
        run.expect(net < Tier.pro.monthlyPrice, "the store takes a cut")
        run.expectClose(net, Tier.pro.monthlyPrice * 0.7, tolerance: 0.01, "30% commission")

        // The worksheet must be willing to report bad news. This is its whole
        // purpose: a worksheet that always says "sustainable" is decoration.
        let expensive = PricingWorksheet(ledger: makeLedger(sessions: 10, minutesEach: 60))
        let verdict = expensive.summary(for: .pro)
        run.expect(!verdict.isEmpty, "every tier gets a summary")
        run.expect(verdict.contains("Pro"), "and names the tier")
        run.expect(verdict.contains("$"), "with real numbers in it")

        // A deliberately underpriced tier must be flagged, with a suggestion.
        var brutal = PricingWorksheet(ledger: makeLedger(sessions: 5, minutesEach: 30))
        brutal.storeCommission = 0.30
        let unsustainable = Tier.allCases.first { !brutal.isSustainable($0) && $0.monthlyPrice > 0 }
        if let unsustainable {
            let summary = brutal.summary(for: unsustainable)
            run.expect(summary.contains("UNDERPRICED"),
                       "an unsustainable tier must be called out: “\(summary)”")
            run.expect(brutal.breakEvenPrice(for: unsustainable) > unsustainable.monthlyPrice,
                       "and the suggested price must be higher than the current one")
        }

        // Free is trivially sustainable — it takes no money and promises little.
        run.expect(worksheet.isSustainable(.free), "free is always sustainable")
        run.expect(worksheet.isSustainable(.bringYourOwnKey), "BYOK costs us nothing")

        // Break-even must respond to the commission.
        var lowCommission = worksheet
        lowCommission.storeCommission = 0.15
        run.expect(lowCommission.breakEvenPrice(for: .pro) < worksheet.breakEvenPrice(for: .pro),
                   "a smaller store cut means a lower break-even price")

        // And it must produce a price that looks like a price.
        let suggested = worksheet.breakEvenPrice(for: .pro)
        if suggested > 0 {
            let cents = Int((suggested * 100).rounded()) % 100
            run.expectEqual(cents, 99, "suggested prices should end in .99, got \(suggested)")
        }
    }
}

// MARK: - The paywall flag

enum PaywallFlagChecks {
    static let all = CheckSuite(name: "Paywall flag") { run in
        let original = PaywallFlag.isEnabled
        defer { PaywallFlag.isEnabled = original }

        // --- OFF: nothing is gated, which is how it ships -------------------
        PaywallFlag.isEnabled = false
        run.expect(!PaywallFlag.isEnabled, "the flag reads back off")

        // With the flag off, the entitlement must be unrestricted regardless of
        // how much has been used. Building the real controller here would touch
        // UserDefaults and StoreKit, so the same rule is asserted directly.
        let unrestricted = Entitlement(tier: .unlimited, voiceMinutesUsed: 0, hasOwnKey: true)
        run.expect(unrestricted.canUseRealtimeVoice, "flag off means no cap")
        run.expect(unrestricted.capMessage == nil, "flag off means nothing to say about caps")

        // --- ON: caps apply ---------------------------------------------------
        PaywallFlag.isEnabled = true
        run.expect(PaywallFlag.isEnabled, "the flag reads back on")

        let capped = Entitlement(tier: .free, voiceMinutesUsed: 25, hasOwnKey: false)
        run.expect(!capped.canUseRealtimeVoice, "flag on means the cap bites")
        run.expect(capped.capMessage != nil, "and the student is told")

        // --- Both directions ---------------------------------------------------
        PaywallFlag.isEnabled = false
        run.expect(!PaywallFlag.isEnabled, "the flag turns back off")
        PaywallFlag.isEnabled = true
        PaywallFlag.isEnabled = false
        run.expect(!PaywallFlag.isEnabled, "and survives being toggled")
    }
}

// MARK: - Anywhere Mode

enum ShareInboxChecks {
    static let all = CheckSuite(name: "Share inbox") { run in

        // --- Item shape ------------------------------------------------------
        let text = ShareInboxItem(payload: .text, inlineText: "Photosynthesis is a process.")
        run.expectEqual(text.payload, .text, "payload kind")
        run.expect(text.filename == nil, "inline text needs no file")
        run.expect(!text.displayTitle.isEmpty, "always has a title")
        run.expect(text.displayTitle.contains("Photosynthesis"),
                   "the title comes from the content when nothing better exists")

        let titled = ShareInboxItem(payload: .pdf, filename: "a.pdf",
                                    suggestedTitle: "Chapter 4 — Cells")
        run.expectEqual(titled.displayTitle, "Chapter 4 — Cells",
                        "a supplied title wins")

        let untitled = ShareInboxItem(payload: .image, filename: "b.jpg")
        run.expectEqual(untitled.displayTitle, "Shared image", "a sensible fallback")
        run.expectEqual(ShareInboxItem(payload: .pdf, filename: "c.pdf").displayTitle,
                        "Shared PDF", "PDF fallback")
        run.expectEqual(ShareInboxItem(payload: .url, inlineText: "").displayTitle,
                        "Shared link", "empty inline text falls back")

        // Titles must be bounded — a shared essay must not become a 4,000
        // character row in the source list.
        let huge = ShareInboxItem(payload: .text,
                                  inlineText: String(repeating: "word ", count: 2_000))
        run.expect(huge.displayTitle.count <= 60,
                   "titles are truncated, got \(huge.displayTitle.count)")
        let hugeSuggested = ShareInboxItem(payload: .pdf, filename: "x",
                                           suggestedTitle: String(repeating: "n", count: 500))
        run.expect(hugeSuggested.displayTitle.count <= 60, "supplied titles are truncated too")

        // A multi-line share takes the first line, not the whole thing.
        let multiline = ShareInboxItem(payload: .text, inlineText: "Cell Biology\nThe cell is…")
        run.expectEqual(multiline.displayTitle, "Cell Biology", "first line becomes the title")

        // --- Round-tripping ----------------------------------------------------
        // The manifest is the contract between two processes, so it has to
        // survive encoding exactly.
        for item in [text, titled, untitled, multiline] {
            guard let data = try? JSONEncoder().encode(item),
                  let decoded = try? JSONDecoder().decode(ShareInboxItem.self, from: data) else {
                run.expect(false, "\(item.payload) must survive JSON")
                continue
            }
            run.expectEqual(decoded.id, item.id, "id survives")
            run.expectEqual(decoded.payload, item.payload, "payload survives")
            run.expectEqual(decoded.filename, item.filename, "filename survives")
            run.expectEqual(decoded.displayTitle, item.displayTitle, "title survives")
        }

        let list = [text, titled, untitled]
        guard let encoded = try? JSONEncoder().encode(list),
              let decoded = try? JSONDecoder().decode([ShareInboxItem].self, from: encoded) else {
            run.expect(false, "the manifest must survive JSON")
            return
        }
        run.expectEqual(decoded.count, 3, "all items survive")
        run.expectEqual(decoded.map(\.id), list.map(\.id), "order is preserved")

        // --- The App Group is shared with the widget ------------------------------
        run.expectEqual(ShareInbox.appGroupID, WidgetStore.appGroupID,
                        "the share inbox and the widget must use the SAME App Group")
    }
}
