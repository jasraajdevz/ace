//
//  HomeView.swift
//  Ace
//
//  The screen the student lands on. Three jobs, in order:
//    1. Say hello like a person, not a dashboard.
//    2. Make "add something to study" the single most obvious action.
//    3. Show progress in a way that encourages without nagging (§10).
//
//  Parts 2–4 hang the study loop, the body-double mode and the guardian off
//  this screen; the structure here is built to take them.
//

import SwiftUI
import SwiftData

@MainActor
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let profile: Profile

    @Query(sort: \StudySource.createdAt, order: .reverse)
    private var sources: [StudySource]

    @State private var isCapturing = false
    @State private var isShowingSettings = false
    @State private var isStudyingTogether = false
    @State private var navigationPath = NavigationPath()

    private var progress: ProgressRecord {
        ProgressStore.fetchOrCreate(in: modelContext)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                AuraBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xxl) {
                        greeting
                        progressCard

                        if let concern = appState.safety.concernResponse {
                            ConcernBanner(response: concern) {
                                appState.safety.dismissConcern()
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        captureCallToAction
                        studyTogetherCard
                        materialSection
                    }
                    .aceScreenPadding()
                    .padding(.top, Space.s)
                    .padding(.bottom, Space.xxxl)
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: Space.s) {
                        AceMark(size: 26)
                        Text("Ace")
                            .font(Typeface.headline)
                            .foregroundStyle(Ink.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Feedback.tap()
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.textSecondary)
                    }
                    .accessibilityLabel(Text("Settings"))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { sourceID in
                if let source = sources.first(where: { $0.id == sourceID }) {
                    SourceDetailView(source: source)
                } else {
                    AceEmptyState(systemImage: "questionmark.folder",
                                  title: "That's gone",
                                  message: "This material was deleted.")
                }
            }
        }
        .sheet(isPresented: $isCapturing) {
            CaptureView(profile: profile) { source in
                // Drop straight into what they just captured — the payoff
                // should be immediate.
                navigationPath.append(source.id)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(profile: profile)
        }
        .fullScreenCover(isPresented: $isStudyingTogether) {
            NavigationStack {
                BodyDoubleView(source: nil)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { isStudyingTogether = false }
                                .foregroundStyle(Ink.textSecondary)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .aceAnimation(Motion.smooth, value: appState.safety.concernResponse?.headline)
        .preferredColorScheme(.dark)
        .safetyNet()
        .task {
            // Republish on every appearance so the widget can't drift — the day
            // may have rolled over while the app was closed, turning a "safe"
            // streak into an "at risk" one.
            WidgetBridge.refresh(from: modelContext)
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(timeGreeting)
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textTertiary)
            Text(headline)
                .font(Typeface.display)
                .foregroundStyle(Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late one"
        }
    }

    private var headline: String {
        let name = profile.greetingName
        if sources.isEmpty {
            return "Let's get you set up, \(name)."
        }
        // While the safety net is engaged, nothing on this screen is allowed to
        // be peppy.
        if appState.safety.isGamificationSuppressed {
            return "No pressure today, \(name)."
        }
        return "Ready when you are, \(name)."
    }

    @ViewBuilder private var progressCard: some View {
        // Gamification is suppressed entirely after a safety event (§10) — not
        // dimmed, not softened. Gone.
        if !appState.safety.isGamificationSuppressed {
            let record = progress
            AceCard {
                HStack(spacing: Space.xl) {
                    ZStack {
                        AceProgressRing(progress: record.levelProgress, lineWidth: 7)
                            .frame(width: 66, height: 66)
                        VStack(spacing: 0) {
                            Text("\(record.level)")
                                .font(Typeface.numeric(.title3))
                                .foregroundStyle(Ink.textPrimary)
                            Text("level")
                                .font(.system(size: 9, design: .rounded).weight(.semibold))
                                .foregroundStyle(Ink.textTertiary)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text("Level \(record.level), \(Int(record.levelProgress * 100)) percent to the next"))

                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(record.levelTitle)
                            .font(Typeface.bodyEmphasis)
                            .foregroundStyle(Ink.textPrimary)
                        Text(streakStatus.nudge)
                            .font(Typeface.footnote)
                            .foregroundStyle(Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if record.streak.current > 0 {
                        VStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Ink.flame)
                            Text("\(record.streak.current)")
                                .font(Typeface.numeric(.headline))
                                .foregroundStyle(Ink.textPrimary)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(Text("\(record.streak.current) day streak"))
                    }
                }
            }
        }
    }

    private var captureCallToAction: some View {
        AceTappableCard(
            action: {
                isCapturing = true
            },
            accessibilityLabel: "Add material. Photograph, scan or paste something to study."
        ) {
            HStack(spacing: Space.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Ink.brandGradient)
                        .frame(width: 54, height: 54)
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Ink.textOnAccent)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Add something to study")
                        .font(Typeface.bodyEmphasis)
                        .foregroundStyle(Ink.textPrimary)
                    Text("Photo, scan, screenshot or pasted text")
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// Body doubling doesn't need material — sometimes you just want somebody
    /// in the room while you work on something Ace has never seen.
    private var studyTogetherCard: some View {
        AceTappableCard(
            action: { isStudyingTogether = true },
            accessibilityLabel: "Study with me. Set a goal and Ace sits with you while you work."
        ) {
            HStack(spacing: Space.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Ink.calm.opacity(0.18))
                        .frame(width: 46, height: 46)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Ink.calm)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Study with me")
                        .font(Typeface.bodyEmphasis)
                        .foregroundStyle(Ink.textPrimary)
                    Text("Set a goal. I'll sit with you and stay out of the way.")
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.textTertiary)
            }
        }
    }

    @ViewBuilder private var materialSection: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if !sources.isEmpty {
                AceSectionHeader(title: "Your material",
                                 subtitle: "\(sources.count) \(sources.count == 1 ? "item" : "items")")
            }

            if sources.isEmpty {
                AceEmptyState(
                    systemImage: "doc.text.viewfinder",
                    title: "Nothing here yet",
                    message: "Point Ace at a worksheet, a textbook page or a screenshot and it'll read it — then we can start working through it together.",
                    actionTitle: "Add your first page",
                    action: { isCapturing = true }
                )
                .padding(.top, Space.l)
            } else {
                VStack(spacing: Space.m) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        SourceRow(source: source) {
                            navigationPath.append(source.id)
                        }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .animation(Motion.smooth.delay(Motion.stagger(index)), value: sources.count)
                    }
                }
            }
        }
    }

    private var streakStatus: StreakStatus {
        StreakEngine.status(progress.streak)
    }
}

// MARK: - Source row

struct SourceRow: View {
    let source: StudySource
    let action: () -> Void

    var body: some View {
        AceTappableCard(action: action,
                        accessibilityLabel: "\(source.title). \(source.wordCount) words.") {
            HStack(spacing: Space.l) {
                thumbnail

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(source.title)
                        .font(Typeface.bodyEmphasis)
                        .foregroundStyle(Ink.textPrimary)
                        .lineLimit(1)

                    if !source.studentNote.isEmpty {
                        Text(source.studentNote)
                            .font(Typeface.footnote)
                            .foregroundStyle(Ink.accent)
                            .lineLimit(1)
                    }

                    Text(source.preview)
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.textTertiary)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Ink.surfaceRaised)
                .frame(width: 46, height: 46)

            #if canImport(UIKit)
            if let data = source.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            } else {
                Image(systemName: source.kind.symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Ink.textSecondary)
            }
            #else
            Image(systemName: source.kind.symbolName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Ink.textSecondary)
            #endif
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
