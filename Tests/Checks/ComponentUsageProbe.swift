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
            }
        }
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
