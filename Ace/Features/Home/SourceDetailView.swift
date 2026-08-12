//
//  SourceDetailView.swift
//  Ace
//
//  One piece of study material.
//
//  In Part 1 this is where the capture pipeline lands: the cleaned text, what
//  Ace pulled out of it, and the ability to fix anything that came out wrong.
//  Part 2 adds the tutor, quiz and flashcard entry points to the action row.
//

import SwiftUI
import SwiftData

@MainActor
struct SourceDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Bindable var source: StudySource

    @State private var isEditingNote = false
    @State private var draftNote = ""
    @State private var isConfirmingDelete = false
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        ZStack {
            AuraBackground(tint: Ink.accentAlt)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    noteSection
                    keyTermsSection
                    textSection
                }
                .aceScreenPadding()
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxxl)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftNote = source.studentNote
                        isEditingNote = true
                    } label: {
                        Label("Edit what you're working on", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.textSecondary)
                }
                .accessibilityLabel(Text("More options"))
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .confirmationDialog("Delete this material?",
                            isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                modelContext.delete(source)
                try? modelContext.save()
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This removes the text and anything generated from it. It can't be undone.")
        }
        .sheet(isPresented: $isEditingNote) {
            noteEditor
        }
        .onAppear {
            source.lastOpenedAt = Date()
            try? modelContext.save()
        }
        .safetyNet()
    }

    // MARK: - Sections

    private var header: some View {
        AceCard {
            HStack(spacing: Space.xl) {
                AceStat(value: "\(source.wordCount)", label: "words", systemImage: "text.alignleft")
                AceStat(value: source.kind.displayName, label: "source",
                        systemImage: source.kind.symbolName, tint: Ink.accentAlt)
                if let subject = source.subject {
                    AceStat(value: subject.displayName, label: "subject",
                            systemImage: subject.symbolName, tint: Ink.success)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var noteSection: some View {
        if source.studentNote.isEmpty {
            AceTappableCard(
                action: {
                    draftNote = ""
                    isEditingNote = true
                },
                accessibilityLabel: "Add what you're working on"
            ) {
                HStack(spacing: Space.m) {
                    Image(systemName: "target")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                    Text("Tell me what you're working on")
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Ink.textTertiary)
                }
            }
        } else {
            AceCard(fill: Ink.accentSoft) {
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "target")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                    Text(source.studentNote)
                        .font(Typeface.callout)
                        .foregroundStyle(Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Working on: \(source.studentNote)"))
        }
    }

    /// What Ace found in the page. This is a small window onto the machinery —
    /// it makes the app feel like it actually *read* the material rather than
    /// just storing it.
    @ViewBuilder private var keyTermsSection: some View {
        let terms = TextAnalysis.keyTerms(in: source.cleanedText, limit: 8)
        if !terms.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                AceSectionHeader(title: "What I picked out",
                                 subtitle: "The ideas this page keeps coming back to")
                FlowLayout(spacing: Space.s) {
                    ForEach(terms, id: \.term) { term in
                        Text(term.term)
                            .font(Typeface.footnote)
                            .foregroundStyle(Ink.textPrimary)
                            .padding(.vertical, Space.s)
                            .padding(.horizontal, Space.m)
                            .background(Ink.surfaceRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceSectionHeader(title: "The material")

            if source.isLowConfidence {
                HStack(spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.warning)
                    Text("This scan was rough — some of it may be wrong.")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textSecondary)
                }
                .padding(.vertical, Space.s)
                .padding(.horizontal, Space.m)
                .background(Ink.warningSoft, in: Capsule())
            }

            AceCard {
                Text(source.cleanedText)
                    .font(Typeface.reading)
                    .foregroundStyle(Ink.textSecondary)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Note editor

    private var noteEditor: some View {
        NavigationStack {
            ZStack {
                Ink.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: Space.l) {
                    Text("One line about what you're doing with this. It's how I know what to focus on.")
                        .font(Typeface.callout)
                        .foregroundStyle(Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("", text: $draftNote, axis: .vertical,
                              prompt: Text("studying photosynthesis, test Friday")
                                .foregroundStyle(Ink.textTertiary))
                        .font(Typeface.body)
                        .foregroundStyle(Ink.textPrimary)
                        .lineLimit(1...4)
                        .focused($isNoteFocused)
                        .padding(Space.l)
                        .background(Ink.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(isNoteFocused ? Ink.accent : Ink.stroke, lineWidth: 1)
                        )
                        .accessibilityLabel(Text("What you're working on"))

                    AceButton(title: "Save") { saveNote() }

                    Spacer()
                }
                .aceScreenPadding()
                .padding(.top, Space.l)
            }
            .navigationTitle("What are you working on?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isEditingNote = false }
                        .foregroundStyle(Ink.textSecondary)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isNoteFocused = true }
        }
    }

    private func saveNote() {
        // Free text — through the safety net before it's stored or acted on.
        guard !appState.safety.check(draftNote) else {
            isEditingNote = false
            return
        }
        source.studentNote = draftNote.trimmed
        try? modelContext.save()
        Feedback.tap()
        isEditingNote = false
    }
}
