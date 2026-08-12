//
//  MockAIProvider.swift
//  Ace
//
//  The default provider (§5). Everything on-device, no key, no network, no cost.
//
//  "Mock" undersells it: this is a working tutor. Vision reads real worksheets,
//  AVSpeechSynthesizer speaks with real personality, the study generator makes
//  real quizzes from the student's own page, and the Socratic engine teaches
//  with real hints. Live Mode is faster and more conversational — it is not the
//  difference between a demo and a product.
//

import Foundation
import AVFoundation
import Speech

/// On-device implementation of `AIProvider`.
final class MockAIProvider: AIProvider, @unchecked Sendable {

    let mode: AIProviderMode = .demo
    var isReady: Bool { true }

    private let ocr = OCRService()
    /// `SpeechService` is main-actor isolated; the provider hops on demand.
    @MainActor private static let speech = SpeechService()

    init() {}

    // MARK: - Voice

    func speak(_ text: String, persona: VoicePersona, prosody: Prosody) async throws {
        await MainActor.run { _ = Self.speech }   // ensure the synthesiser exists
        await Self.speech.speak(text, persona: persona, prosody: prosody)
    }

    func stopSpeaking() async {
        await Self.speech.stop()
    }

    /// Transcribe recorded audio using on-device speech recognition.
    ///
    /// `requiresOnDeviceRecognition` is set so audio never leaves the phone —
    /// which is both a privacy property and the reason this works offline.
    func transcribe(audio: Data) async throws -> String {
        guard await Self.requestSpeechAuthorization() else {
            throw AIProviderError.audioUnavailable
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw AIProviderError.audioUnavailable
        }

        // `SFSpeechURLRecognitionRequest` needs a file, so the buffer is written
        // to a temporary one and cleaned up afterwards.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            // A recognition task can call its handler more than once; this box
            // guarantees the continuation is resumed exactly once.
            let hasResumed = ResumeGuard()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if hasResumed.claim() {
                        continuation.resume(throwing: AIProviderError.transport(error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if hasResumed.claim() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: - Tutoring

    /// Stream a Socratic reply.
    ///
    /// The text is produced locally and instantly, then emitted phrase by phrase
    /// with small delays. That is not theatre: the UI and the voice layer both
    /// consume this as a stream, so behaving like one here means Part 3 can swap
    /// in the real streaming provider with no changes above this line.
    func tutorReply(context: TutorContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // The crisis net runs before anything else, in every mode.
                let safety = CrisisSafetyService().evaluate(context.studentMessage)
                if safety.severity == .crisis {
                    // The provider does not attempt to counsel. It hands control
                    // to the safety surface, which owns this moment entirely.
                    continuation.yield("")
                    continuation.finish()
                    return
                }

                let reply = Self.composeReply(for: context)
                for phrase in PhraseSplitter.phrases(in: reply) {
                    if Task.isCancelled { break }
                    continuation.yield(phrase + " ")
                    // ~28ms per word approximates a natural reading pace.
                    let words = phrase.split(separator: " ").count
                    try? await Task.sleep(for: .milliseconds(min(28 * words, 260)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build the tutor's next line from the context.
    private static func composeReply(for context: TutorContext) -> String {
        let askedForAnswer = context.studentAskedForAnswer
            || SocraticEngine.isAskingForAnswer(context.studentMessage)

        // Ground every reply in the student's own material: find the sentence
        // most relevant to what they just said.
        let relevant = mostRelevantSentence(to: context.studentMessage, in: context.sourceText)
        let rung = SocraticEngine.rung(attemptCount: context.attemptCount,
                                       askedForAnswer: askedForAnswer,
                                       mood: context.mood.mood)

        if rung.revealsAnswer, let relevant {
            return "Here's the part that matters: “\(relevant)” Read it back to me in your own words — "
                + "that's the bit that makes it stick."
        }

        if let relevant {
            return "Look at this line: “\(relevant)” What do you think it's telling you?"
        }

        // No source match — ask them to locate it themselves rather than
        // inventing content that isn't in their material.
        return "Point me at the bit you're stuck on — read me the sentence and we'll take it apart together."
    }

    /// Cheap relevance: the sentence sharing the most content words with the
    /// student's message. Good enough to feel grounded, and it never invents
    /// anything that isn't on their page.
    private static func mostRelevantSentence(to message: String, in source: String) -> String? {
        let sentences = TextAnalysis.sentences(in: source)
        guard !sentences.isEmpty else { return nil }

        let queryWords = Set(TextAnalysis.words(in: message)
            .filter { !TextAnalysis.stopwords.contains($0) && $0.count > 3 })
        guard !queryWords.isEmpty else { return sentences.first }

        var best: (sentence: String, score: Int)?
        for sentence in sentences {
            let words = Set(TextAnalysis.words(in: sentence))
            let score = queryWords.intersection(words).count
            if score > (best?.score ?? 0) {
                best = (sentence, score)
            }
        }
        return best?.sentence ?? sentences.first
    }

    // MARK: - Reading the world

    func readText(from imageData: Data) async throws -> RecognizedText {
        try await ocr.recognizeText(in: imageData)
    }

    // MARK: - Study material

    func makeQuiz(from source: StudyMaterialSource,
                  gradeLevel: GradeLevel,
                  title: String,
                  questionCount: Int) async throws -> Quiz {
        guard case .text(let text) = source else { throw AIProviderError.noTextFound }
        let generator = StudyMaterialGenerator(gradeLevel: gradeLevel)
        let quiz = generator.quiz(from: text, title: title, questionCount: questionCount)
        guard !quiz.isEmpty else { throw AIProviderError.noTextFound }
        return quiz
    }

    func makeFlashcards(from source: StudyMaterialSource,
                        gradeLevel: GradeLevel,
                        title: String,
                        limit: Int) async throws -> [Flashcard] {
        guard case .text(let text) = source else { throw AIProviderError.noTextFound }
        let generator = StudyMaterialGenerator(gradeLevel: gradeLevel)
        let cards = generator.flashcards(from: text, title: title, limit: limit)
        guard !cards.isEmpty else { throw AIProviderError.noTextFound }
        return cards
    }

    // MARK: - Reading the student

    func readEmotion(audio: Data?, text: String?, signals: BehaviourSignals) async -> MoodReading {
        // Demo Mode has no audio-emotion model, so behaviour and wording carry
        // the read. See `MoodHeuristics` for what that's based on.
        MoodHeuristics.read(signals: signals, text: text)
    }
}

/// One-shot latch, so a callback that fires twice can't resume a continuation
/// twice (which traps).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// Returns true exactly once.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}
