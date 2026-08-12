//
//  SettingsView.swift
//  Ace
//
//  Settings, kept short on purpose. Everything here is something a student
//  would actually want to change; nothing here is a preference we added because
//  we couldn't decide.
//
//  Part 3 adds the OpenAI key field, the Demo→Live toggle and the connection
//  self-test to the "How Ace runs" section — the row is already here showing
//  Demo Mode, so the shape won't change.
//

import SwiftUI
import SwiftData

@MainActor
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var profile: Profile

    @State private var previewingPersonaID: String?
    @State private var soundsEnabled = SoundCuePlayer.shared.isEnabled
    @State private var hapticsEnabled = HapticSettings.shared.isEnabled
    @State private var isConfirmingReset = false

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xxl) {
                        modeSection
                        voiceSection
                        aboutYouSection
                        feedbackSection
                        supportSection
                        dangerSection
                    }
                    .aceScreenPadding()
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.xxxl)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        Feedback.tap()
                        dismiss()
                    }
                    .foregroundStyle(Ink.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            Task { await appState.stopSpeaking() }
            appState.apply(profile.settings)
            try? modelContext.save()
        }
    }

    // MARK: - How Ace runs

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "How Ace runs")

            AceCard {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        Image(systemName: appState.providerMode == .demo ? "iphone" : "bolt.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appState.providerMode == .demo ? Ink.success : Ink.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.providerMode.displayName)
                                .font(Typeface.bodyEmphasis)
                                .foregroundStyle(Ink.textPrimary)
                            Text(appState.providerMode.detail)
                                .font(Typeface.caption)
                                .foregroundStyle(Ink.textSecondary)
                        }
                        Spacer(minLength: 0)
                        AceBadge(text: "Active", tint: Ink.success)
                    }

                    Divider().overlay(Ink.stroke)

                    Text("Everything works without an account or a key. Connecting an OpenAI key later makes the voice faster and more conversational — that arrives in a future update.")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "Voice",
                             subtitle: "Tap to hear any of them")

            VStack(spacing: Space.m) {
                ForEach(VoiceRoster.all) { persona in
                    VoicePersonaRow(
                        persona: persona,
                        isSelected: profile.voicePersonaID == persona.id,
                        isPlaying: previewingPersonaID == persona.id
                    ) {
                        select(persona)
                    }
                }
            }

            if !SpeechService.hasHighQualityVoice {
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                    Text("Ace sounds noticeably better with a downloaded voice. Settings › Accessibility › Spoken Content › Voices — grab an English (US) voice marked Enhanced or Premium.")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.l)
                .background(Ink.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
    }

    // MARK: - About you

    private var aboutYouSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "About you")

            AceCard {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Name")
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textTertiary)
                        TextField("", text: $profile.name,
                                  prompt: Text("Optional").foregroundStyle(Ink.textTertiary))
                            .font(Typeface.body)
                            .foregroundStyle(Ink.textPrimary)
                            .accessibilityLabel(Text("Your name"))
                    }

                    Divider().overlay(Ink.stroke)

                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Year")
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textTertiary)
                        Picker("Year", selection: Binding(
                            get: { profile.gradeLevel },
                            set: { profile.gradeLevel = $0 }
                        )) {
                            ForEach(GradeLevel.allCases) { grade in
                                Text(grade.displayName).tag(grade)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Ink.accent)
                        .labelsHidden()
                    }

                    Divider().overlay(Ink.stroke)

                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Subjects")
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textTertiary)
                        FlowLayout(spacing: Space.s) {
                            ForEach(Subject.presets) { subject in
                                AceChip(title: subject.displayName,
                                        systemImage: subject.symbolName,
                                        isSelected: profile.subjectKeys.contains(subject.storageKey)) {
                                    toggle(subject)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "Sound and feel")

            AceCard {
                VStack(spacing: Space.l) {
                    Toggle(isOn: $soundsEnabled) {
                        settingLabel("Sound cues", detail: "Quiet confirmations, never chatter",
                                     symbol: "speaker.wave.2.fill")
                    }
                    .tint(Ink.accent)
                    .onChange(of: soundsEnabled) { _, newValue in
                        SoundCuePlayer.shared.isEnabled = newValue
                        if newValue { SoundCuePlayer.shared.play(.tap) }
                    }

                    Divider().overlay(Ink.stroke)

                    Toggle(isOn: $hapticsEnabled) {
                        settingLabel("Haptics", detail: "Taps you can feel",
                                     symbol: "hand.tap.fill")
                    }
                    .tint(Ink.accent)
                    .onChange(of: hapticsEnabled) { _, newValue in
                        HapticSettings.shared.isEnabled = newValue
                        if newValue { Haptic.tap.play() }
                    }
                }
            }
        }
    }

    // MARK: - Support region

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "Getting help",
                             subtitle: "So Ace shows numbers that work where you are")

            AceCard {
                VStack(alignment: .leading, spacing: Space.m) {
                    Picker("Region", selection: Binding(
                        get: { profile.supportRegion },
                        set: {
                            profile.supportRegion = $0
                            appState.safety.region = $0
                        }
                    )) {
                        ForEach(SupportRegion.allCases) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Ink.accent)
                    .accessibilityLabel(Text("Support region"))

                    Divider().overlay(Ink.stroke)

                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("If things get heavy, Ace will show these:")
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textTertiary)
                        ForEach(SupportDirectory.resources(for: profile.supportRegion).filter(\.isPrimary)) { resource in
                            HStack(spacing: Space.s) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Ink.careAccent)
                                Text(resource.title)
                                    .font(Typeface.footnote)
                                    .foregroundStyle(Ink.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reset

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "Start over")

            AceButton(title: "Reset everything", systemImage: "trash", kind: .destructive) {
                isConfirmingReset = true
            }

            Text("Ace v\(Bundle.appVersion) · everything stays on this device")
                .font(Typeface.caption)
                .foregroundStyle(Ink.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, Space.l)
        }
        .confirmationDialog("Delete everything?", isPresented: $isConfirmingReset,
                            titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every source, deck and bit of progress. This can't be undone.")
        }
    }

    // MARK: - Helpers

    private func settingLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textPrimary)
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
            }
        }
    }

    private func select(_ persona: VoicePersona) {
        profile.voicePersonaID = persona.id
        appState.persona = persona
        previewingPersonaID = persona.id
        Task {
            await appState.preview(persona)
            if previewingPersonaID == persona.id { previewingPersonaID = nil }
        }
    }

    private func toggle(_ subject: Subject) {
        if let index = profile.subjectKeys.firstIndex(of: subject.storageKey) {
            profile.subjectKeys.remove(at: index)
        } else {
            profile.subjectKeys.append(subject.storageKey)
        }
    }

    private func resetAll() {
        // Listed explicitly rather than looped over `AceSchema.models`:
        // `delete(model:)` is generic over a concrete `PersistentModel`, so an
        // array of `any PersistentModel.Type` can't satisfy it.
        try? modelContext.delete(model: StoredFlashcard.self)
        try? modelContext.delete(model: StoredQuiz.self)
        try? modelContext.delete(model: StudySession.self)
        try? modelContext.delete(model: StudySource.self)
        try? modelContext.delete(model: ProgressRecord.self)
        try? modelContext.delete(model: Profile.self)

        UserDefaults.standard.removeObject(forKey: "ace.demoContentInstalled")
        try? modelContext.save()
        // Otherwise the home screen keeps showing a streak for an app with
        // nothing in it.
        WidgetBridge.clear()
        Feedback.warning()
        dismiss()
    }
}

// MARK: - Version

extension Bundle {
    static var appVersion: String {
        main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
