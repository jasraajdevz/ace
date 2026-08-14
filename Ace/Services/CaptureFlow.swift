//
//  CaptureFlow.swift
//  Ace
//
//  The capture screen's state machine, lifted out of the view.
//
//  Why it exists: `CaptureView` held this as `@State`, which meant the whole
//  path — photograph, recognise, check, review, save — could be type-checked and
//  never executed. On a machine with no simulator that is the same as untested,
//  and it was: the safety branch below returned while the stage was still
//  `.reading`, so a student whose photographed page tripped the crisis net came
//  back from that screen to a spinner that never stopped.
//
//  Nothing here knows about SwiftUI. Everything it needs — a provider, a safety
//  coordinator — arrives as a parameter, so the checks can drive the same code
//  the screen runs, with a mock provider and real text.
//

import Foundation
import Observation

@MainActor
@Observable
final class CaptureFlow {

    enum Stage: Equatable {
        case choosing
        case pasting
        /// Recognition in flight.
        case reading
        case reviewing
        case failed(String)
    }

    private(set) var stage: Stage = .choosing
    private(set) var recognized: RecognizedText = .empty
    private(set) var thumbnail: Data?
    private(set) var pendingKind: SourceKind = .pastedText

    init() {}

    // MARK: - Navigation

    func beginPasting() { stage = .pasting }
    func fail(_ message: String) { stage = .failed(message) }

    /// Back to the neutral state, holding on to nothing.
    ///
    /// Used after the safety net fires as well as for an ordinary retake, and
    /// the clearing matters in that case: the recognised text is the content
    /// that triggered it, and leaving it loaded so it reappears the moment the
    /// student dismisses the support screen would be careless.
    func reset() {
        recognized = .empty
        thumbnail = nil
        stage = .choosing
    }

    // MARK: - Pasted text

    /// Returns false when the safety net took over.
    @discardableResult
    func paste(_ text: String, safety: SafetyCoordinator) -> Bool {
        // Free text goes through the safety net before anything else touches it.
        guard !safety.check(text) else {
            reset()
            return false
        }

        let cleaned = text.trimmed
        guard !cleaned.isEmpty else {
            stage = .failed("There wasn't any text in that.")
            return false
        }

        pendingKind = .pastedText
        thumbnail = nil
        recognized = RecognizedText(lines: cleaned.components(separatedBy: .newlines),
                                    confidence: 1)
        stage = .reviewing
        return true
    }

    // MARK: - Images

    /// Recognise text in one or more images and decide where the screen lands.
    ///
    /// Every exit assigns a stage. That is the whole discipline here — this
    /// function is the only thing that can move the screen off `.reading`, so a
    /// path that returns without setting one strands the student on a spinner.
    func process(images: [Data],
                 kind: SourceKind,
                 provider: AIProvider,
                 safety: SafetyCoordinator) async {
        pendingKind = kind
        thumbnail = images.first
        stage = .reading

        do {
            var lines: [String] = []
            var confidences: [Double] = []

            for data in images {
                let result = try await provider.readText(from: data)
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

            // The recognised text is student-authored content too, so it gets
            // checked like anything else — a photographed diary page must not
            // slip past the net.
            guard !safety.check(result.lines.joined(separator: " ")) else {
                reset()
                return
            }

            recognized = result
            Feedback.complete()
            stage = .reviewing
        } catch let error as AIProviderError {
            stage = .failed(error.studentFacingSuggestion)
        } catch {
            stage = .failed("Something went wrong reading that. Try again, or paste the text.")
        }
    }

    // MARK: - What the review screen saves

    var rawText: String { recognized.lines.joined(separator: "\n") }
}
