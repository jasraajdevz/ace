//
//  CaptureView.swift
//  Ace
//
//  The capture pipeline: pick a way in → recognise the text → review and save.
//
//  This is the front door of the whole product. A student points their phone at
//  a worksheet and, a couple of seconds later, has study material. Everything
//  else in Ace hangs off a `StudySource` created here.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let profile: Profile
    /// Called with the saved source so the caller can navigate to it.
    var onSaved: (StudySource) -> Void = { _ in }

    @State private var stage: Stage = .choosing
    @State private var activeSheet: CaptureSheet?
    @State private var recognized: RecognizedText = .empty
    @State private var pendingKind: SourceKind = .pastedText
    @State private var thumbnail: Data?

    private enum Stage: Equatable {
        case choosing
        case pasting
        case reading          // OCR in flight
        case reviewing
        case failed(String)
    }

    private enum CaptureSheet: Identifiable {
        case camera, library, scanner
        var id: Int { hashValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuraBackground(isStill: stage == .reading)

                switch stage {
                case .choosing:
                    chooserContent
                case .pasting:
                    PasteTextView { text in
                        beginPaste(text)
                    }
                case .reading:
                    AceLoadingState(message: "Reading your page…", rows: 5)
                        .padding(.top, Space.xxl)
                        .overlay(alignment: .top) {
                            readingBanner
                        }
                case .reviewing:
                    SourceReviewView(
                        recognized: recognized,
                        kind: pendingKind,
                        profile: profile,
                        thumbnail: thumbnail,
                        onSave: save,
                        onRetake: { stage = .choosing }
                    )
                case .failed(let message):
                    AceErrorState(
                        title: "I couldn't read that",
                        message: message,
                        retryTitle: "Try another way",
                        onRetry: { stage = .choosing },
                        secondaryTitle: "Paste the text instead",
                        onSecondary: { stage = .pasting }
                    )
                    .padding(.top, Space.xxl)
                }
            }
            .navigationTitle(stage == .choosing ? "Add material" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        Feedback.tap()
                        dismiss()
                    }
                    .foregroundStyle(Ink.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .safetyNet()
        #if canImport(UIKit)
        .fullScreenCover(item: $activeSheet) { sheet in
            switch sheet {
            case .camera:
                CameraPicker(
                    onCapture: { data in
                        activeSheet = nil
                        process([data], kind: .cameraPhoto)
                    },
                    onCancel: { activeSheet = nil }
                )
                .ignoresSafeArea()
            case .library:
                LibraryPicker(
                    onPick: { images in
                        activeSheet = nil
                        process(images, kind: .photoLibrary)
                    },
                    onCancel: { activeSheet = nil }
                )
                .ignoresSafeArea()
            case .scanner:
                DocumentScanner(
                    onScan: { pages in
                        activeSheet = nil
                        process(pages, kind: .documentScan)
                    },
                    onCancel: { activeSheet = nil }
                )
                .ignoresSafeArea()
            }
        }
        #endif
    }

    // MARK: - Chooser

    private var chooserContent: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                Text("However it's easiest — I'll read it and we'll work from there.")
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.s)

                #if canImport(UIKit)
                if ScannerAvailability.isSupported {
                    CaptureOptionCard(
                        symbol: "doc.viewfinder",
                        title: "Scan a page",
                        detail: "Best results — straightens the page and handles several at once.",
                        isRecommended: true
                    ) { activeSheet = .scanner }
                }

                if ScannerAvailability.hasCamera {
                    CaptureOptionCard(
                        symbol: "camera.fill",
                        title: "Take a photo",
                        detail: "Quick snap of a worksheet or a whiteboard."
                    ) { activeSheet = .camera }
                }

                CaptureOptionCard(
                    symbol: "photo.on.rectangle.angled",
                    title: "From your photos",
                    detail: "Screenshots and saved pages."
                ) { activeSheet = .library }
                #endif

                CaptureOptionCard(
                    symbol: "text.alignleft",
                    title: "Paste text",
                    detail: "Notes, an article, anything you can copy."
                ) { stage = .pasting }
            }
            .aceScreenPadding()
            .padding(.top, Space.l)
            .padding(.bottom, Space.xxl)
        }
    }

    private var readingBanner: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.accent)
            Text("This all happens on your phone — nothing gets uploaded.")
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textSecondary)
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.l)
        .background(Ink.surface, in: Capsule())
        .padding(.top, Space.l)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Pipeline

    private func beginPaste(_ text: String) {
        // Free text goes through the safety net before anything else touches it.
        guard !appState.safety.check(text) else { return }

        let cleaned = text.trimmed
        guard !cleaned.isEmpty else {
            stage = .failed("There wasn't any text in that.")
            return
        }
        pendingKind = .pastedText
        thumbnail = nil
        recognized = RecognizedText(lines: cleaned.components(separatedBy: .newlines), confidence: 1)
        stage = .reviewing
    }

    private func process(_ images: [Data], kind: SourceKind) {
        pendingKind = kind
        thumbnail = images.first
        stage = .reading

        Task {
            do {
                var lines: [String] = []
                var confidences: [Double] = []

                for data in images {
                    let result = try await appState.provider.readText(from: data)
                    lines.append(contentsOf: result.lines)
                    if !result.lines.isEmpty { confidences.append(result.confidence) }
                }

                let confidence = confidences.isEmpty
                    ? 0 : confidences.reduce(0, +) / Double(confidences.count)
                let result = RecognizedText(lines: lines, confidence: confidence)

                guard result.isUsable else {
                    stage = .failed(AIProviderError.noTextFound.studentFacingSuggestion)
                    return
                }

                // The recognised text is student-authored content too, so it
                // gets checked like anything else — a photographed diary page
                // must not slip past the net.
                if appState.safety.check(result.lines.joined(separator: " ")) { return }

                recognized = result
                Feedback.complete()
                stage = .reviewing
            } catch let error as AIProviderError {
                stage = .failed(error.studentFacingSuggestion)
            } catch {
                stage = .failed("Something went wrong reading that. Try again, or paste the text.")
            }
        }
    }

    private func save(title: String, note: String, subject: Subject?, cleanedText: String) {
        // Both free-text fields go through the net.
        guard !appState.safety.check(note) else { return }

        let source = StudySource(
            title: title.isEmpty ? defaultTitle : title,
            kind: pendingKind,
            rawText: recognized.lines.joined(separator: "\n"),
            cleanedText: cleanedText,
            studentNote: note,
            subject: subject,
            confidence: recognized.confidence
        )
        source.thumbnailData = thumbnail

        modelContext.insert(source)

        // Capturing material is real progress and pays XP — unless the safety
        // net is engaged, in which case nothing gamified happens at all.
        if !appState.safety.isGamificationSuppressed {
            let progress = ProgressStore.fetchOrCreate(in: modelContext)
            progress.award(.capturedSource)
            progress.sourcesCaptured += 1
            progress.recordStudyDay()
        }

        try? modelContext.save()
        Feedback.complete()
        onSaved(source)
        dismiss()
    }

    private var defaultTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "\(pendingKind.displayName) · \(formatter.string(from: Date()))"
    }
}

// MARK: - Option card

private struct CaptureOptionCard: View {
    let symbol: String
    let title: String
    let detail: String
    var isRecommended: Bool = false
    let action: () -> Void

    var body: some View {
        AceTappableCard(action: action,
                        accessibilityLabel: "\(title). \(detail)") {
            HStack(spacing: Space.l) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(isRecommended ? Ink.accentSoft : Ink.surfaceRaised)
                        .frame(width: 52, height: 52)
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isRecommended ? Ink.accent : Ink.textSecondary)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(title)
                            .font(Typeface.bodyEmphasis)
                            .foregroundStyle(Ink.textPrimary)
                        if isRecommended {
                            AceBadge(text: "Best", tint: Ink.success)
                        }
                    }
                    Text(detail)
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Ink.textTertiary)
            }
        }
    }
}

// MARK: - Paste

private struct PasteTextView: View {
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Paste anything — notes, an article, a chapter.")
                .font(Typeface.callout)
                .foregroundStyle(Ink.textSecondary)

            TextEditor(text: $text)
                .font(Typeface.reading)
                .foregroundStyle(Ink.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(Space.m)
                .frame(minHeight: 220)
                .background(Ink.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(isFocused ? Ink.accent : Ink.stroke, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste or type here…")
                            .font(Typeface.reading)
                            .foregroundStyle(Ink.textTertiary)
                            .padding(Space.l)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isFocused)
                .aceAnimation(Motion.snappy, value: isFocused)
                .accessibilityLabel(Text("Study material text"))

            #if canImport(UIKit)
            if UIPasteboard.general.hasStrings {
                AceButton(title: "Paste from clipboard", systemImage: "doc.on.clipboard",
                          kind: .secondary) {
                    text = UIPasteboard.general.string ?? text
                }
            }
            #endif

            AceButton(title: "Use this", isEnabled: !text.trimmed.isEmpty) {
                onSubmit(text)
            }

            Spacer(minLength: 0)
        }
        .aceScreenPadding()
        .padding(.top, Space.l)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isFocused = true }
        }
    }
}
