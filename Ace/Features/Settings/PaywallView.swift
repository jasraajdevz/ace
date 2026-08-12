//
//  PaywallView.swift
//  Ace
//
//  The paywall, and the usage panel that sits next to it.
//
//  It is OFF by default (`PaywallFlag.isEnabled`) and none of this is reachable
//  until the flag is turned on. When it is, the design follows one rule that
//  most paywalls break: **be honest about what's free.** The free column here is
//  longer than the paid one, because it is — everything on-device is unlimited
//  forever, and the only thing money buys is the realtime voice, which is the
//  only thing with a marginal cost.
//
//  A paywall that pretends the free tier is a crippled trial gets read as a
//  lie by anyone who has used the app for a week, and they're right.
//

import SwiftUI

// MARK: - Paywall

struct PaywallView: View {
    @Bindable var store: StoreController
    let onDismiss: () -> Void

    @State private var selected: Tier = .pro
    @State private var isPurchasing = false

    var body: some View {
        ZStack {
            AuraBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    freeForever
                    tierChoices
                    purchaseArea
                    smallPrint
                }
                .aceScreenPadding()
                .padding(.top, Space.l)
                .padding(.bottom, Space.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                Feedback.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Ink.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Ink.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Space.l)
            .accessibilityLabel(Text("Close"))
        }
        .task { await store.loadProducts() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceMark(size: 52)
            AceScreenTitle(
                title: "Ace, out loud",
                subtitle: "Realtime voice is the one thing that costs money to run. Everything else is yours already."
            )
        }
        .padding(.top, Space.xl)
    }

    /// The free list, first and in full.
    private var freeForever: some View {
        AceCard(fill: Ink.successSoft) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Image(systemName: "infinity")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Ink.success)
                    Text("Free forever, on every plan")
                        .font(Typeface.bodyEmphasis)
                        .foregroundStyle(Ink.textPrimary)
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Tier.alwaysIncluded, id: \.self) { item in
                        HStack(alignment: .top, spacing: Space.s) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Ink.success)
                                .padding(.top, 3)
                            Text(item)
                                .font(Typeface.footnote)
                                .foregroundStyle(Ink.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tierChoices: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "More voice time",
                             subtitle: "Cancel any time, from the App Store")

            ForEach([Tier.pro, .unlimited], id: \.self) { tier in
                TierRow(tier: tier,
                        priceText: priceText(for: tier),
                        isSelected: selected == tier) {
                    Feedback.selection()
                    selected = tier
                }
            }

            // BYOK is offered plainly rather than buried, because for a heavy
            // user it is genuinely the better deal — and pretending otherwise
            // would be the kind of thing this app shouldn't do.
            AceCard {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.accentAlt)
                        Text("Or use your own OpenAI key")
                            .font(Typeface.subheadline)
                            .foregroundStyle(Ink.textPrimary)
                    }
                    Text("No limits from us and nothing to pay us — you pay OpenAI directly for what you use. If you talk to Ace for hours a day, this is cheaper than any plan here.")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var purchaseArea: some View {
        VStack(spacing: Space.m) {
            AceButton(title: "Get \(selected.displayName)",
                      systemImage: "sparkles",
                      isLoading: isPurchasing) {
                buy()
            }

            if let error = store.purchaseError {
                Text(error)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.l) {
                Button("Restore purchases") {
                    Task { await store.restore() }
                }
                .font(Typeface.caption)
                .foregroundStyle(Ink.textTertiary)

                Button("Not now", action: onDismiss)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
            }
        }
    }

    private var smallPrint: some View {
        Text("Subscriptions renew monthly until cancelled. Manage or cancel in the App Store at any time. Ace never stops working when a subscription ends — it goes back to on-device mode.")
            .font(Typeface.caption)
            .foregroundStyle(Ink.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    /// Prefer the localised App Store price; fall back to the hard-coded one so
    /// the screen is never blank while products load.
    private func priceText(for tier: Tier) -> String {
        #if canImport(StoreKit)
        if let product = store.product(for: tier) {
            return product.displayPrice
        }
        #endif
        return String(format: "$%.2f", tier.monthlyPrice)
    }

    private func buy() {
        isPurchasing = true
        Task {
            let success = await store.purchase(selected)
            isPurchasing = false
            if success {
                Feedback.complete()
                onDismiss()
            } else if store.purchaseError != nil {
                Feedback.warning()
            }
        }
    }
}

// MARK: - Tier row

struct TierRow: View {
    let tier: Tier
    let priceText: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.l) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isSelected ? Ink.accent : Ink.stroke)

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(tier.displayName)
                            .font(Typeface.bodyEmphasis)
                            .foregroundStyle(Ink.textPrimary)
                        if let minutes = tier.voiceMinutesPerMonth {
                            AceBadge(text: "\(Int(minutes / 60))h voice", tint: Ink.accentAlt)
                        }
                    }
                    Text(tier.summary)
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(priceText)
                        .font(Typeface.numeric(.headline))
                        .foregroundStyle(Ink.textPrimary)
                    Text("/month")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Ink.accentSoft : Ink.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(isSelected ? Ink.accent.opacity(0.5) : Ink.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .aceAnimation(Motion.snappy, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(tier.displayName), \(priceText) a month. \(tier.summary)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Usage panel

/// What Live Mode has actually cost. Always visible, paywall or not.
///
/// Showing this unconditionally is the point: a student running their own key
/// should be able to see exactly what Ace is spending on their behalf, and a
/// student on the free tier should be able to see that on-device mode costs
/// nothing.
struct UsageSection: View {
    @Bindable var store: StoreController
    var onShowPaywall: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "Usage",
                             subtitle: "Measured on this device. Nothing is sent anywhere.")

            AceCard {
                VStack(alignment: .leading, spacing: Space.l) {
                    HStack {
                        AceStat(value: minutesText, label: "voice this month",
                                systemImage: "waveform", tint: Ink.accent)
                        Spacer(minLength: 0)
                        AceStat(value: costText, label: "OpenAI usage",
                                systemImage: "dollarsign.circle", tint: Ink.accentAlt)
                        Spacer(minLength: 0)
                        AceStat(value: "\(store.ledger.sessionCount)", label: "sessions",
                                systemImage: "clock", tint: Ink.success)
                    }

                    if PaywallFlag.isEnabled {
                        let entitlement = store.entitlement
                        if let remaining = entitlement.voiceMinutesRemaining {
                            VStack(alignment: .leading, spacing: Space.s) {
                                AceProgressBar(progress: entitlement.usageFraction, height: 6)
                                Text("\(Int(remaining)) of \(Int(entitlement.tier.voiceMinutesPerMonth ?? 0)) minutes left on \(entitlement.tier.displayName)")
                                    .font(Typeface.caption)
                                    .foregroundStyle(Ink.textTertiary)
                            }
                        }
                        if let message = entitlement.capMessage {
                            Text(message)
                                .font(Typeface.footnote)
                                .foregroundStyle(Ink.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if entitlement.tier == .free, let onShowPaywall {
                            AceButton(title: "See the plans", kind: .secondary, action: onShowPaywall)
                        }
                    } else {
                        Text(store.usageSummary)
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var minutesText: String {
        String(format: "%.0f", store.thisMonth.voiceMinutes)
    }

    private var costText: String {
        let cost = store.thisMonth.cost
        return cost < 0.01 ? "$0" : String(format: "$%.2f", cost)
    }
}
