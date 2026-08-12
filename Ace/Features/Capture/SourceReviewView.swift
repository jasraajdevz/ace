//
//  SourceReviewView.swift
//  Ace
//
//  The screen between "Ace read your page" and "it's saved".
//
//  Two things happen here that matter a lot:
//    1. The student sees the cleaned text and can fix it. OCR is good, not
//       perfect, and a garbled line silently poisoning every quiz question is
//       the worst possible failure mode.
//    2. The student says what they're doing — "studying photosynthesis, test
//       Friday". That one sentence is what lets Ace behave like a tutor who
//       knows why you're here rather than a text summariser.
//

import SwiftUI

@MainActor
struct SourceReviewView: View {
    let recognized: RecognizedText
    let kind: SourceKind
    let profile: Profile
    let thumbnail: Data?
    let onSave: (_ title: String, _ note: String, _ subject: Subject?, _ cleanedText: String) -> Void
    let onRetake: () -> Void

    @Environment(AppState.self) private var appState

    @State private var title = ""
    @State private var note = ""
    @State private var subject: Subject?
    @State private var cleanedText = ""
    @State private var isEditingText = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, note, text }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {

                if recognized.confidence < 0.55 && kind != .pastedText {
                    lowConfidenceWarning
                }

                // What are you working on? — asked first, because it's the
                // thing that changes how Ace behaves.
                VStack(alignment: .leading, spacing: Space.m) {
                    AceSectionHeader(title: "What are you working on?",
                                     subtitle: "One line. It's how I know what to focus on.")

                    TextField("", text: $note, axis: .vertical)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.textPrimary)
                        .lineLimit(1...3)
                        .focused($focusedField, equals: .note)
                        .padding(Space.l)
                        .background(Ink.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(focusedField == .note ? Ink.accent : Ink.stroke, lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty {
                                Text("studying photosynthesis, test Friday")
                                    .font(Typeface.body)
                                    .foregroundStyle(Ink.textTertiary)
                                    .padding(Space.l)
                                    .allowsHitTesting(false)
                            }
                        }
                        .aceAnimation(Motion.snappy, value: focusedField)
                        .accessibilityLabel(Text("What you're working on"))

                    // Quick-fill suggestions built from the material itself.
                    if note.isEmpty, !suggestedTopics.isEmpty {
                        FlowLayout(spacing: Space.s) {
                            ForEach(suggestedTopics, id: \.self) { topic in
                                AceChip(title: topic, isSelected: false) {
                                    note = "studying \(topic)"
                                }
                            }
                        }
                    }
                }

                // Subject
                VStack(alignment: .leading, spacing: Space.m) {
                    AceSectionHeader(title: "Subject")
                    FlowLayout(spacing: Space.s) {
                        ForEach(subjectOptions) { option in
                            AceChip(title: option.displayName,
                                    systemImage: option.symbolName,
                                    isSelected: subject?.storageKey == option.storageKey) {
                                subject = subject?.storageKey == option.storageKey ? nil : option
                            }
                        }
                    }
                }

                // Title
                VStack(alignment: .leading, spacing: Space.m) {
                    AceSectionHeader(title: "Name it")
                    TextField("", text: $title,
                              prompt: Text(placeholderTitle).foregroundStyle(Ink.textTertiary))
                        .font(Typeface.body)
                        .foregroundStyle(Ink.textPrimary)
                        .focused($focusedField, equals: .title)
                        .padding(Space.l)
                        .background(Ink.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(focusedField == .title ? Ink.accent : Ink.stroke, lineWidth: 1)
                        )
                        .aceAnimation(Motion.snappy, value: focusedField)
                        .accessibilityLabel(Text("Title"))
                }

                // The text itself
                VStack(alignment: .leading, spacing: Space.m) {
                    AceSectionHeader(
                        title: "What I read",
                        subtitle: "\(wordCount) words\(kind == .pastedText ? "" : " · \(confidenceText)")",
                        actionTitle: isEditingText ? "Done" : "Fix it",
                        action: {
                            isEditingText.toggle()
                            focusedField = isEditingText ? .text : nil
                        }
                    )

                    if isEditingText {
                        TextEditor(text: $cleanedText)
                            .font(Typeface.reading)
                            .foregroundStyle(Ink.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                            .padding(Space.m)
                            .background(Ink.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .strokeBorder(Ink.accent, lineWidth: 1)
                            )
                            .focused($focusedField, equals: .text)
                            .accessibilityLabel(Text("Recognised text, editable"))
                    } else {
                        AceCard {
                            Text(cleanedText.isEmpty ? "Nothing readable yet." : cleanedText)
                                .font(Typeface.reading)
                                .foregroundStyle(cleanedText.isEmpty ? Ink.textTertiary : Ink.textSecondary)
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityLabel(Text("Recognised text"))
                    }
                }

                VStack(spacing: Space.m) {
                    AceButton(title: "Save", systemImage: "checkmark",
                              isEnabled: !cleanedText.trimmed.isEmpty) {
                        onSave(title.trimmed, note.trimmed, subject, cleanedText.trimmed)
                    }
                    AceButton(title: "Try a different page", kind: .ghost, action: onRetake)
                }
                .padding(.top, Space.s)
            }
            .aceScreenPadding()
            .padding(.top, Space.l)
            .padding(.bottom, Space.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: prepare)
    }

    // MARK: - Setup

    private func prepare() {
        // Clean once on arrival. `rawText` is kept on the model so a better
        // cleaner in a later version can re-run without the original photo.
        cleanedText = SourceTextCleaner.clean(lines: recognized.lines)
        if cleanedText.trimmed.isEmpty {
            cleanedText = recognized.lines.joined(separator: "\n")
        }
        subject = profile.subjects.first
    }

    // MARK: - Derived

    private var wordCount: Int {
        cleanedText.split(separator: " ").count
    }

    private var confidenceText: String {
        let percent = Int((recognized.confidence * 100).rounded())
        return "\(percent)% confident"
    }

    private var placeholderTitle: String {
        // The first heading in the material is almost always the right title.
        let blocks = SourceTextCleaner.blocks(from: recognized.lines)
        if let heading = blocks.first(where: { $0.kind == .heading })?.text {
            return heading
        }
        return "\(kind.displayName) · today"
    }

    /// The profile's subjects first, then any preset they haven't picked — so
    /// the common case is one tap and nothing is ever unavailable.
    private var subjectOptions: [Subject] {
        var options = profile.subjects
        for preset in Subject.presets where !options.contains(where: { $0.storageKey == preset.storageKey }) {
            options.append(preset)
        }
        return options
    }

    /// Topic chips pulled from the material's own key terms.
    private var suggestedTopics: [String] {
        TextAnalysis.keyTerms(in: cleanedText, limit: 4)
            .map(\.term)
            .filter { $0.count < 28 }
    }

    private var lowConfidenceWarning: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Ink.warning)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("That scan came out rough")
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textPrimary)
                Text("Worth a retake with more light — or fix the text below before saving.")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.warningSoft)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
