//
//  LiveModeSettings.swift
//  Ace
//
//  The "How Ace runs" section: the key, the Demo ↔ Live switch, the connection
//  self-test, and the debug latency HUD.
//
//  Two things this screen is careful about:
//
//  • **The key is never shown.** Once saved it becomes a masked fingerprint
//    (`sk-proj-…a91f`), which is enough to tell *which* key is installed without
//    it being readable over someone's shoulder. There is no "reveal" button.
//  • **Demo Mode is never framed as the lesser option.** It's free, private and
//    works offline, and the copy says so. A student who never adds a key should
//    not feel like they're using a crippled app — because they aren't.
//
//  This file touches no SwiftData, so it is compiled and type-checked by the
//  command-line build (DECISIONS.md D1).
//

import SwiftUI

struct LiveModeSection: View {
    @Bindable var controller: ProviderController

    @State private var draftKey = ""
    @State private var keyError: String?
    @State private var isEditingKey = false
    @State private var isShowingHUD = false
    @State private var isConfirmingRemoval = false
    @FocusState private var isKeyFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "How Ace runs")

            modeCard

            if controller.hasKey {
                keyCard
                testCard
            } else {
                addKeyCard
            }

            if let notice = controller.fallbackNotice {
                fallbackBanner(notice)
            }
        }
        .aceAnimation(Motion.smooth, value: controller.hasKey)
        .aceAnimation(Motion.smooth, value: isEditingKey)
        .confirmationDialog("Remove your key?", isPresented: $isConfirmingRemoval,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await controller.removeKey() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Ace goes back to on-device mode. Everything still works.")
        }
    }

    // MARK: - Mode

    private var modeCard: some View {
        AceCard {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(spacing: Space.m) {
                    Image(systemName: isLive ? "bolt.fill" : "iphone")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isLive ? Ink.accent : Ink.success)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isLive ? "Live Mode" : "Demo Mode")
                            .font(Typeface.bodyEmphasis)
                            .foregroundStyle(Ink.textPrimary)
                        Text(isLive
                             ? "OpenAI Realtime. Fastest, most natural voice."
                             : "On-device. Free, private, works offline.")
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                    AceBadge(text: "Active", tint: isLive ? Ink.accent : Ink.success)
                }

                if controller.hasKey {
                    Divider().overlay(Ink.stroke)

                    Picker("Mode", selection: Binding(
                        get: { controller.preference },
                        set: { controller.preference = $0 }
                    )) {
                        ForEach(ProviderPreference.allCases, id: \.self) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("How Ace runs"))

                    Text(controller.preference.detail)
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var isLive: Bool {
        controller.preference == .preferLive && controller.hasKey
    }

    // MARK: - Adding a key

    private var addKeyCard: some View {
        AceCard {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("Ace works fully without a key. Adding one makes the voice faster and lets you actually talk with it rather than typing.")
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isEditingKey {
                    keyField
                } else {
                    AceButton(title: "Add an OpenAI key", systemImage: "key.fill",
                              kind: .secondary) {
                        isEditingKey = true
                        isKeyFieldFocused = true
                    }
                }

                Text("Your key is stored in the iOS Keychain on this device. It never syncs, never leaves the phone except to talk to OpenAI, and Ace never displays it back to you.")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // `SecureField` rather than `TextField`: the key must not be visible
            // while it's being pasted either.
            SecureField("", text: $draftKey,
                        prompt: Text("sk-…").foregroundStyle(Ink.textTertiary))
                .font(Typeface.body)
                .foregroundStyle(Ink.textPrimary)
                .textContentType(.password)
                .autocorrectionDisabled()
                .focused($isKeyFieldFocused)
                .padding(Space.l)
                .background(Ink.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(keyError == nil ? Ink.stroke : Ink.danger, lineWidth: 1)
                )
                .accessibilityLabel(Text("OpenAI API key"))

            if let keyError {
                Text(keyError)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.m) {
                AceButton(title: "Save", isEnabled: !draftKey.isBlank) { save() }
                AceButton(title: "Cancel", kind: .ghost, fillsWidth: false) {
                    draftKey = ""
                    keyError = nil
                    isEditingKey = false
                }
            }
        }
    }

    private func save() {
        Task {
            keyError = await controller.saveKey(draftKey)
            if keyError == nil {
                draftKey = ""
                isEditingKey = false
                Feedback.complete()
                // Prove it works straight away rather than leaving the student
                // to wonder.
                await controller.runConnectionTest()
            } else {
                Feedback.warning()
            }
        }
    }

    // MARK: - An installed key

    private var keyCard: some View {
        AceCard {
            HStack(spacing: Space.m) {
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.success)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.keyFingerprint ?? "sk-…")
                        .font(Typeface.numeric(.callout, weight: .medium))
                        .foregroundStyle(Ink.textPrimary)
                    Text("Stored in the Keychain on this device")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                }

                Spacer(minLength: 0)

                Button("Remove") { isConfirmingRemoval = true }
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.danger)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Key \(controller.keyFingerprint ?? "") is saved"))
    }

    // MARK: - Self-test

    private var testCard: some View {
        AceCard {
            VStack(alignment: .leading, spacing: Space.l) {
                if let result = controller.lastTestResult {
                    HStack(alignment: .top, spacing: Space.m) {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(result.passed ? Ink.success : Ink.warning)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.headline)
                                .font(Typeface.bodyEmphasis)
                                .foregroundStyle(Ink.textPrimary)
                            Text(result.detail)
                                .font(Typeface.caption)
                                .foregroundStyle(Ink.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }

                AceButton(title: controller.lastTestResult == nil ? "Test the connection" : "Test again",
                          systemImage: "waveform.path.ecg",
                          kind: .secondary,
                          isLoading: controller.isTesting) {
                    Task { await controller.runConnectionTest() }
                }

                Divider().overlay(Ink.stroke)

                Button {
                    Feedback.tap()
                    isShowingHUD.toggle()
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: isShowingHUD ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("Latency detail")
                            .font(Typeface.footnote)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Ink.textTertiary)
                }
                .buttonStyle(.plain)

                if isShowingHUD {
                    LatencyHUD(latency: controller.live?.latency ?? LatencyTracker(),
                               bargeIn: controller.live?.bargeIn ?? BargeInTracker(),
                               quality: controller.live?.connectionQuality ?? .offline,
                               model: controller.model)
                        .transition(.opacity)
                }
            }
        }
        .aceAnimation(Motion.smooth, value: isShowingHUD)
    }

    private func fallbackBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.success)
            Text(notice)
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("OK") { controller.clearFallbackNotice() }
                .font(Typeface.caption)
                .foregroundStyle(Ink.accent)
        }
        .padding(Space.l)
        .background(Ink.successSoft)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Debug HUD

/// The latency numbers from §7, in the open.
///
/// It lives in Settings rather than floating over the tutor because a HUD on the
/// study surface is exactly the kind of thing §8 calls out: motion and
/// information that competes with focus. It's here when you want it.
struct LatencyHUD: View {
    let latency: LatencyTracker
    let bargeIn: BargeInTracker
    let quality: ConnectionQuality
    let model: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            row("Connection", quality.displayName,
                tint: quality >= .fair ? Ink.success : Ink.warning)
            row("Model", model, tint: Ink.textSecondary)

            Divider().overlay(Ink.stroke).padding(.vertical, 2)

            row("Time to first audio", ms(latency.last), tint: verdictTint)
            row("p50", ms(latency.p50), tint: Ink.textSecondary)
            row("p95", ms(latency.p95),
                tint: latency.meetsBudget ? Ink.success : Ink.warning)
            row("Samples", "\(latency.count)", tint: Ink.textTertiary)

            Divider().overlay(Ink.stroke).padding(.vertical, 2)

            row("Barge-in", ms(bargeIn.last),
                tint: bargeIn.meetsBudget ? Ink.success : Ink.danger)
            row("Barge-in worst", ms(bargeIn.worst),
                tint: bargeIn.meetsBudget ? Ink.success : Ink.danger)

            Divider().overlay(Ink.stroke).padding(.vertical, 2)

            Text("Targets: first audio under \(Int(LatencyBudget.ttfaTarget * 1000))ms (p95 \(Int(LatencyBudget.ttfaP95Ceiling * 1000))ms), barge-in under \(Int(LatencyBudget.bargeInCeiling * 1000))ms.")
                .font(Typeface.caption)
                .foregroundStyle(Ink.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .background(Ink.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var verdictTint: Color {
        switch latency.verdict {
        case .good: Ink.success
        case .acceptable: Ink.warning
        case .poor: Ink.danger
        }
    }

    private func ms(_ value: TimeInterval?) -> String {
        value.map { "\(Int(($0 * 1000).rounded()))ms" } ?? "—"
    }

    private func row(_ label: String, _ value: String, tint: Color) -> some View {
        HStack {
            Text(label)
                .font(Typeface.caption)
                .foregroundStyle(Ink.textTertiary)
            Spacer(minLength: Space.m)
            Text(value)
                .font(Typeface.numeric(.caption, weight: .semibold))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(value)"))
    }
}

// MARK: - Connection indicator

/// The small pill shown during a live conversation.
///
/// Only appears when there's something worth saying — a good connection stays
/// silent, because an always-on status badge is just noise.
struct ConnectionIndicator: View {
    let quality: ConnectionQuality
    var isLive: Bool

    var body: some View {
        if isLive && quality < .good {
            HStack(spacing: Space.xs) {
                Image(systemName: quality.symbolName)
                    .font(.system(size: 10, weight: .bold))
                Text(quality.displayName)
                    .font(Typeface.caption)
            }
            .foregroundStyle(quality == .offline ? Ink.textTertiary : Ink.warning)
            .padding(.vertical, 4)
            .padding(.horizontal, Space.m)
            .background(
                (quality == .offline ? Ink.surfaceRaised : Ink.warningSoft),
                in: Capsule()
            )
            .accessibilityLabel(Text(quality.displayName))
        }
    }
}
