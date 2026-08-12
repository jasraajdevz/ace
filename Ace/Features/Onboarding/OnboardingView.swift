//
//  OnboardingView.swift
//  Ace
//
//  First run. Five short steps, each one screen, each answerable in a tap or
//  two. Nothing here is a form — a student should be through it in under a
//  minute and hear Ace's voice before the end.
//

import SwiftUI
import SwiftData

@MainActor
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    /// The profile row created at launch; onboarding fills it in.
    let profile: Profile

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var gradeLevel: GradeLevel = .grade9
    @State private var selectedSubjects: Set<String> = []
    @State private var customSubject = ""
    @State private var personaID = VoiceRoster.default.id
    @State private var previewingPersonaID: String?

    enum Step: Int, CaseIterable {
        case welcome, name, grade, subjects, voice

        var progress: Double {
            Double(rawValue) / Double(Step.allCases.count - 1)
        }
    }

    var body: some View {
        ZStack {
            AuraBackground()

            VStack(spacing: 0) {
                header

                // Each step is its own view so transitions stay crisp and the
                // body of this file stays readable.
                Group {
                    switch step {
                    case .welcome: WelcomeStep()
                    case .name: NameStep(name: $name)
                    case .grade: GradeStep(gradeLevel: $gradeLevel)
                    case .subjects: SubjectsStep(selected: $selectedSubjects, custom: $customSubject)
                    case .voice: VoiceStep(personaID: $personaID, previewingID: $previewingPersonaID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                footer
            }
        }
        .aceAnimation(Motion.smooth, value: step)
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: Space.l) {
            HStack {
                if step != .welcome {
                    Button {
                        Feedback.tap()
                        goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Ink.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(Ink.surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                }
                Spacer()
            }

            AceProgressBar(progress: step.progress, height: 6, showsGlow: false)
                .accessibilityLabel(Text("Setup progress"))
        }
        .aceScreenPadding()
        .padding(.top, Space.s)
    }

    private var footer: some View {
        VStack(spacing: Space.m) {
            AceButton(title: primaryTitle,
                      systemImage: step == .voice ? "checkmark" : nil,
                      isEnabled: canAdvance) {
                advance()
            }

            if step == .name {
                Button("Skip for now") {
                    Feedback.tap()
                    name = ""
                    advance()
                }
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textTertiary)
            }
        }
        .aceScreenPadding()
        .padding(.bottom, Space.xl)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Let's go"
        case .voice: "Start studying"
        default: "Next"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .subjects: !selectedSubjects.isEmpty || !customSubject.trimmed.isEmpty
        default: true
        }
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        // Stop any voice preview before moving on — nothing worse than Ace
        // talking over the next screen.
        Task { await appState.stopSpeaking() }
        step = next
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        Task { await appState.stopSpeaking() }
        step = previous
    }

    /// Write everything into the profile and hand over to the app.
    private func finish() {
        Task { await appState.stopSpeaking() }

        profile.name = name.trimmed
        profile.gradeLevel = gradeLevel
        profile.voicePersonaID = personaID
        profile.supportRegion = SupportRegion.fromDeviceRegion(Locale.current.region?.identifier)

        var subjects = Subject.presets.filter { selectedSubjects.contains($0.storageKey) }
        let custom = customSubject.trimmed
        if !custom.isEmpty { subjects.append(.other(custom)) }
        profile.subjects = subjects

        profile.hasCompletedOnboarding = true

        try? modelContext.save()
        appState.apply(profile.settings)
        Feedback.complete()
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            AceMark(size: 108)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: Space.m) {
                Text("Ace")
                    .font(.system(size: 52, design: .rounded).weight(.heavy))
                    .foregroundStyle(Ink.brandGradient)

                Text("A study partner that talks back.\nPoint it at your work and it'll teach you through it — out loud.")
                    .font(Typeface.body)
                    .foregroundStyle(Ink.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)

            Spacer()

            AceBadge(text: "Works with no account and no key", systemImage: "lock.shield.fill",
                     tint: Ink.success)
                .opacity(appeared ? 1 : 0)
        }
        .aceScreenPadding()
        .onAppear {
            withAnimation(Motion.bouncy.delay(0.1)) { appeared = true }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NameStep: View {
    @Binding var name: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            AceScreenTitle(title: "What should I call you?",
                           subtitle: "Totally optional — it just makes this feel less like a form.")

            TextField("", text: $name, prompt: Text("Your name").foregroundStyle(Ink.textTertiary))
                .font(Typeface.title2)
                .foregroundStyle(Ink.textPrimary)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .focused($isFocused)
                .padding(Space.l)
                .background(Ink.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(isFocused ? Ink.accent : Ink.stroke, lineWidth: 1)
                )
                .aceAnimation(Motion.snappy, value: isFocused)
                .accessibilityLabel(Text("Your name"))

            Spacer()
        }
        .aceScreenPadding()
        .padding(.top, Space.xxl)
        .onAppear {
            // A small delay so the keyboard doesn't fight the step transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isFocused = true }
        }
    }
}

private struct GradeStep: View {
    @Binding var gradeLevel: GradeLevel

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Space.m)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                AceScreenTitle(title: "What year are you in?",
                               subtitle: "This sets how I explain things — and how hard the questions get.")

                LazyVGrid(columns: columns, spacing: Space.m) {
                    ForEach(GradeLevel.allCases) { grade in
                        AceChip(title: grade.shortName,
                                isSelected: gradeLevel == grade) {
                            gradeLevel = grade
                        }
                    }
                }

                AceCard {
                    HStack(spacing: Space.m) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                        Text(sampleLine)
                            .font(Typeface.footnote)
                            .foregroundStyle(Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .aceAnimation(Motion.gentle, value: gradeLevel)

                Spacer(minLength: Space.xxl)
            }
            .aceScreenPadding()
            .padding(.top, Space.xxl)
        }
    }

    /// Shows the student what their choice actually changes.
    private var sampleLine: String {
        switch gradeLevel.band {
        case .elementary:
            "“Plants make their own food using sunlight. What do you think they need besides light?”"
        case .middle:
            "“Photosynthesis turns light into sugar. What has to go in for that to happen?”"
        case .high:
            "“Light reactions produce ATP and NADPH. Where does the carbon in glucose actually come from?”"
        case .college:
            "“Given that RuBisCO also fixes O₂, what limits net carbon assimilation at high temperature?”"
        }
    }
}

private struct SubjectsStep: View {
    @Binding var selected: Set<String>
    @Binding var custom: String
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                AceScreenTitle(title: "What are you working on?",
                               subtitle: "Pick as many as you like. You can change this later.")

                FlowLayout(spacing: Space.m) {
                    ForEach(Subject.presets) { subject in
                        AceChip(title: subject.displayName,
                                systemImage: subject.symbolName,
                                isSelected: selected.contains(subject.storageKey)) {
                            toggle(subject)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Something else?")
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textTertiary)

                    TextField("", text: $custom,
                              prompt: Text("e.g. Music Theory").foregroundStyle(Ink.textTertiary))
                        .font(Typeface.body)
                        .foregroundStyle(Ink.textPrimary)
                        .focused($isFocused)
                        .padding(Space.l)
                        .background(Ink.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(isFocused ? Ink.accent : Ink.stroke, lineWidth: 1)
                        )
                        .aceAnimation(Motion.snappy, value: isFocused)
                        .accessibilityLabel(Text("Another subject"))
                }

                Spacer(minLength: Space.xxl)
            }
            .aceScreenPadding()
            .padding(.top, Space.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func toggle(_ subject: Subject) {
        if selected.contains(subject.storageKey) {
            selected.remove(subject.storageKey)
        } else {
            selected.insert(subject.storageKey)
        }
    }
}

@MainActor
private struct VoiceStep: View {
    @Binding var personaID: String
    @Binding var previewingID: String?
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                AceScreenTitle(title: "Pick a voice",
                               subtitle: "Tap any of them to hear it. This is who you'll be studying with.")

                VStack(spacing: Space.m) {
                    ForEach(VoiceRoster.all) { persona in
                        VoicePersonaRow(
                            persona: persona,
                            isSelected: personaID == persona.id,
                            isPlaying: previewingID == persona.id
                        ) {
                            select(persona)
                        }
                    }
                }

                Spacer(minLength: Space.xxl)
            }
            .aceScreenPadding()
            .padding(.top, Space.xxl)
        }
    }

    private func select(_ persona: VoicePersona) {
        personaID = persona.id
        previewingID = persona.id
        Task {
            await appState.preview(persona)
            // Only clear the indicator if this preview is still the current one.
            if previewingID == persona.id { previewingID = nil }
        }
    }
}
