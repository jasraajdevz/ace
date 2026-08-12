//
//  ComponentUsageProbe.swift
//  Ace — developer verification harness
//
//  A COMPILE-TIME probe. Nothing in here runs, and none of it ships.
//
//  Why it exists: `Features/` is bound to SwiftData, which needs Xcode's macro
//  plugin, so it can't be type-checked on this machine — only parsed. Parsing
//  catches syntax errors but not *type* errors, and the most likely type error
//  in SwiftUI code is a mis-ordered or mis-labelled initialiser argument (Swift
//  requires memberwise arguments in declaration order, so reordering a property
//  silently breaks every call site).
//
//  So every design-system component is constructed here using the exact same
//  argument shapes the real screens use. If a component's signature changes in a
//  way that would break a screen, this file stops compiling and `verify.sh`
//  fails — on a machine with no Xcode.
//
//  Keep it in sync when a screen adds a new call shape:
//      grep -rhoE '\b(AceButton|AceCard|…)\(' Ace/Features
//

import SwiftUI

/// Mirrors every design-system call site in `Ace/Features/`.
struct ComponentUsageProbe: View {

    @State private var chipSelected = false
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack {
                buttons
                cards
                chips
                progress
                headers
                states
                smallPieces
                backgrounds
                safetySurfaces
                studyLoop
                celebrationSurfaces
                voiceSurfaces
                presenceSurfaces
            }
        }
    }

    // MARK: QuizView, FlashcardView, TutorView, SourceDetailView
    //
    // These screens are bound to SwiftData so they can't be type-checked
    // directly. Their component call sites are mirrored here instead.

    @ViewBuilder private var studyLoop: some View {
        // QuizView
        ChoiceRow(text: "Chlorophyll", state: .neutral, isEnabled: true) {}
        ChoiceRow(text: "Glucose", state: .correct, isEnabled: false) {}
        ChoiceRow(text: "Stomata", state: .incorrect, isEnabled: false) {}
        AceReplyBubble(text: "What do you think it's telling you?")
        AceReplyBubble(text: "It's Chlorophyll.", isHint: false)
        AceProgressBar(progress: 0.4, height: 6)
        AceProgressBar(
            progress: 0.4,
            height: 6,
            tint: LinearGradient(colors: [Ink.success, Ink.accentAlt],
                                 startPoint: .leading, endPoint: .trailing)
        )

        // FlashcardView
        FlipCard(front: "What is glucose?", back: "The sugar plants store as food.",
                 context: "From the source.", isRevealed: false, flip: 0)
        FlipCard(front: "F", back: "B", context: nil, isRevealed: true, flip: 180)
        GradeButton(grade: .forgot, tint: Ink.danger) {}
        GradeButton(grade: .hard, tint: Ink.warning) {}
        GradeButton(grade: .easy, tint: Ink.success) {}

        // TutorView
        TurnBubble(turn: TutorTurn(speaker: .ace, text: "What do you already know?"))
        TurnBubble(turn: TutorTurn(speaker: .student, text: "Not much honestly"))
        TurnBubble(turn: TutorTurn(speaker: .ace, text: "Try this line.", isHint: true))
        ThinkingIndicator()
        QuickReply(title: "I don't know", systemImage: "questionmark") {}
        QuickReply(title: "Just tell me", systemImage: "arrow.right.to.line") {}

        // SourceDetailView
        StudyActionCard(symbol: "bubble.left.and.text.bubble.right.fill",
                        title: "Talk it through",
                        detail: "Ace asks the questions.",
                        tint: Ink.accent,
                        isPreparing: false,
                        isPrimary: true) {}
        StudyActionCard(symbol: "checklist", title: "Quiz me", detail: "Fresh questions",
                        tint: Ink.accentAlt, isPreparing: true, isCompact: true) {}

        // Results screens (these two ARE compiled, so this is a call-shape check)
        QuizResultsView(
            result: QuizResult(quizID: UUID(), correctCount: 4, totalCount: 6,
                               missedQuestionIDs: [UUID()], elapsed: 92),
            followUp: Quiz(title: "Follow up", questions: []),
            sessionXP: 120,
            onRedoMissed: {},
            onDone: {}
        )
        FlashcardResultsView(
            summary: FlashcardSummary(deckSize: 8, reviewed: 8, easy: 5, hard: 2, forgotten: 1),
            sessionXP: 60,
            onDone: {}
        )
    }

    // MARK: BodyDoubleView, SpeakingDrillView

    @ViewBuilder private var presenceSurfaces: some View {
        SessionTimer(elapsed: 754, progress: 0.42, goalText: "25 minutes", isMeasurable: true)
        SessionTimer(elapsed: 60, progress: 0, goalText: "chapter 4", isMeasurable: false)

        PresenceBanner(message: PresenceMessage(kind: .milestone,
                                                text: "Halfway — 12 minutes down.",
                                                isSpoken: false)) {}
        PresenceBanner(message: PresenceMessage(kind: .closing,
                                                text: "That's it.", isSpoken: true)) {}

        if let nudge = Guardian.nudge(for: .suggestBreak, mood: .frustrated) {
            GuardianNudgeCard(nudge: nudge, onAccept: {}, onDismiss: {})
        }
        if let welcome = Guardian.nudge(for: .welcomeBack, mood: .neutral,
                                        goalText: "chapter 4", awaySeconds: 120) {
            GuardianNudgeCard(nudge: welcome, onAccept: {}, onDismiss: {})
        }

        ComfortCard(message: ComfortResponder.respond(to: .tired, studentName: "Sam")) {}

        DoNotDisturbToggle(state: .off) {}
        DoNotDisturbToggle(state: .on) {}

        FocusMusicPicker(current: .drift, volume: 0.35, onSelect: { _ in }, onVolume: { _ in })
        FocusMusicPicker(current: .off, volume: 0, onSelect: { _ in }, onVolume: { _ in })

        AceProgressBar(progress: 0.6, height: 6,
                       tint: LinearGradient(colors: [Ink.accent, Ink.accent.opacity(0.55)],
                                            startPoint: .leading, endPoint: .trailing),
                       showsGlow: false)
        AceChip(title: "Drift", systemImage: "wind", isSelected: true, tint: Ink.calm) {}
    }

    // MARK: Live Mode — Settings, the HUD, the listening bar

    @ViewBuilder private var voiceSurfaces: some View {
        LiveModeSection(controller: ProviderController())
        LatencyHUD(latency: LatencyTracker(), bargeIn: BargeInTracker(),
                   quality: .good, model: RealtimeModel.default)
        ConnectionIndicator(quality: .poor, isLive: true)
        ConnectionIndicator(quality: .good, isLive: false)
        VoiceListeningBar(level: 0.4, isStudentSpeaking: true) {}
        VoiceListeningBar(level: 0, isStudentSpeaking: false) {}
    }

    // MARK: The reward moments

    @ViewBuilder private var celebrationSurfaces: some View {
        XPToast(amount: 12, caption: "Correct")
        ParticleBurst()
        ParticleBurst(count: 40, duration: 1.2, gravity: 500, seed: 7)
        LevelUpView(level: 5, title: "Warmed up", progress: 0.2) {}
        Color.clear.celebrations(CelebrationCenter())
    }

    // MARK: OnboardingView, CaptureView, SourceReviewView, SettingsView

    private var buttons: some View {
        VStack {
            AceButton(title: "Save") {}
            AceButton(title: "Save", systemImage: "checkmark", isEnabled: true) {}
            AceButton(title: "Next", systemImage: nil, isEnabled: true) {}
            AceButton(title: "Skip for now", kind: .ghost, action: {})
            AceButton(title: "Try a different page", kind: .ghost, action: {})
            AceButton(title: "Use this", isEnabled: !text.trimmed.isEmpty) {}
            AceButton(title: "Paste from clipboard", systemImage: "doc.on.clipboard",
                      kind: .secondary) {}
            AceButton(title: "Reset everything", systemImage: "trash", kind: .destructive) {}
            AceButton(title: "Add your first page", kind: .secondary, fillsWidth: false, action: {})
            AceButton(title: "Retry", systemImage: "arrow.clockwise", action: {})
        }
    }

    // MARK: HomeView, SourceDetailView, SettingsView

    private var cards: some View {
        VStack {
            AceCard { Text("plain") }
            AceCard(fill: Ink.accentSoft) { Text("tinted") }
            AceTappableCard(action: {}, accessibilityLabel: "label") { Text("tappable") }
            AceTappableCard(
                action: {},
                accessibilityLabel: "Add material. Photograph, scan or paste something to study."
            ) {
                Text("multi-line call shape")
            }
        }
    }

    // MARK: Onboarding, SourceReviewView, SettingsView

    private var chips: some View {
        VStack {
            AceChip(title: GradeLevel.grade9.shortName, isSelected: chipSelected) {}
            AceChip(title: Subject.science.displayName,
                    systemImage: Subject.science.symbolName,
                    isSelected: chipSelected) {}
            AceChip(title: "photosynthesis", isSelected: false) {}
        }
    }

    // MARK: OnboardingView, HomeView

    private var progress: some View {
        VStack {
            AceProgressBar(progress: 0.5, height: 6, showsGlow: false)
            AceProgressBar(progress: 0.5)
            AceProgressRing(progress: 0.5, lineWidth: 7)
        }
    }

    // MARK: Every screen

    private var headers: some View {
        VStack {
            AceSectionHeader(title: "The material")
            AceSectionHeader(title: "Your material", subtitle: "3 items")
            AceSectionHeader(
                title: "What I read",
                subtitle: "120 words · 92% confident",
                actionTitle: "Fix it",
                action: {}
            )
            AceScreenTitle(title: "Pick a voice",
                           subtitle: "Tap any of them to hear it.")
        }
    }

    // MARK: Designed empty / loading / error states

    private var states: some View {
        VStack {
            AceEmptyState(systemImage: "questionmark.folder",
                          title: "That's gone",
                          message: "This material was deleted.")
            AceEmptyState(
                systemImage: "doc.text.viewfinder",
                title: "Nothing here yet",
                message: "Point Ace at a worksheet…",
                actionTitle: "Add your first page",
                action: {}
            )
            AceLoadingState(message: "Reading your page…", rows: 5)
            AceErrorState(
                title: "I couldn't read that",
                message: "Try again with more light.",
                retryTitle: "Try another way",
                onRetry: {},
                secondaryTitle: "Paste the text instead",
                onSecondary: {}
            )
        }
    }

    // MARK: Stats, badges, the mark, flow layout

    private var smallPieces: some View {
        VStack {
            AceStat(value: "120", label: "words", systemImage: "text.alignleft")
            AceStat(value: SourceKind.cameraPhoto.displayName, label: "source",
                    systemImage: SourceKind.cameraPhoto.symbolName, tint: Ink.accentAlt)

            // Argument ORDER matters for the memberwise initialiser — this is
            // the exact shape that broke once.
            AceBadge(text: "Active", tint: Ink.success)
            AceBadge(text: "Best", tint: Ink.success)
            AceBadge(text: "Works with no account and no key",
                     systemImage: "lock.shield.fill",
                     tint: Ink.success)

            AceMark(size: 26)
            AceMark(size: 96)
            AceMark(size: 108)

            FlowLayout(spacing: Space.s) {
                ForEach(Subject.presets) { subject in
                    Text(subject.displayName)
                }
            }
            FlowLayout(spacing: Space.m) { Text("one") }

            VoicePersonaRow(persona: VoiceRoster.default,
                            isSelected: true,
                            isPlaying: false) {}
        }
    }

    private var backgrounds: some View {
        ZStack {
            AuraBackground()
            AuraBackground(isStill: true)
            AuraBackground(tint: Ink.accentAlt)
        }
        .aceScreenPadding()
        .aceBackground()
    }

    // MARK: The safety surfaces

    @ViewBuilder private var safetySurfaces: some View {
        let signal = CrisisSafetyService().evaluate("i want to kill myself")
        if let response = CrisisResponder.response(for: signal,
                                                   region: .unitedStates,
                                                   studentName: "Sam") {
            CrisisSupportView(response: response) {}
            ConcernBanner(response: response, onDismiss: {})
            ConcernBanner(response: response, onDismiss: {}, onOpenResource: { _ in })
        }
    }
}

// MARK: - Modifier probes

/// The view modifiers the screens apply, exercised so a signature change breaks
/// the build here rather than in Xcode.
private struct ModifierProbe: View {
    var body: some View {
        Text("x")
            .aceAnimation(Motion.snappy, value: true)
            .aceAnimation(Motion.smooth, value: Optional<Bool>.none)
            .aceAnimation(Motion.gentle, value: GradeLevel.grade9, decorative: true)
            .elevation(.low)
            .elevation(.none)
            .aceScreenPadding()
            .aceBackground(tint: Ink.accent, isStill: false)
    }
}

/// `ReduceMotionReader` is used by celebration code in Part 2 — probed now so
/// its signature is locked in.
private struct ReduceMotionProbe: View {
    var body: some View {
        ReduceMotionReader { reduced in
            Text(reduced ? "still" : "moving")
        }
    }
}
