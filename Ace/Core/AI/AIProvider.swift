//
//  AIProvider.swift
//  Ace
//
//  The seam that lets Ace be built today and paid for later (§5).
//
//  Every AI capability in the app goes through this one protocol. Two things
//  implement it:
//
//    • `MockAIProvider`  — the default. On-device only: AVSpeechSynthesizer for
//                          voice, Vision for reading images, local text analysis
//                          for quizzes and flashcards, heuristics for mood. No
//                          key, no network, no cost.
//    • `OpenAIRealtimeProvider` — the real one, added in Part 3. Realtime voice
//                          over WebRTC, vision, and function calling.
//
//  Nothing above this layer knows which one is running. That is the whole point:
//  the UI, the study loop, the guardian and the widget are all written once.
//

import Foundation

// MARK: - Supporting types

/// Which implementation is live. Surfaced in Settings and the debug HUD.
enum AIProviderMode: String, Codable, Sendable {
    case demo   // MockAIProvider — keyless
    case live   // OpenAIRealtimeProvider — needs a key

    var displayName: String {
        switch self {
        case .demo: "Demo Mode"
        case .live: "Live Mode"
        }
    }

    var detail: String {
        switch self {
        case .demo: "On-device. Free, private, works offline."
        case .live: "OpenAI Realtime. Fastest, most natural voice."
        }
    }
}

/// Everything the tutor needs to know to say the next thing.
///
/// Assembled fresh for each turn rather than held as state, so a reconnect or a
/// provider switch mid-session can't lose the thread.
struct TutorContext: Sendable {
    /// The cleaned source text the student is working from.
    var sourceText: String
    /// What the student said they're doing — "studying photosynthesis, test Friday".
    var studentNote: String
    var gradeLevel: GradeLevel
    var subject: Subject?
    /// Conversation so far, oldest first.
    var transcript: [TutorTurn]
    /// The student's latest message.
    var studentMessage: String
    /// Our current read on how they're doing.
    var mood: MoodReading
    /// Set when the student has explicitly asked for the answer ("just tell
    /// me"). Until then the tutor stays Socratic.
    var studentAskedForAnswer: Bool
    /// How many times the student has attempted the current question. Feeds the
    /// decision about when a hint becomes an answer.
    var attemptCount: Int

    init(sourceText: String = "",
         studentNote: String = "",
         gradeLevel: GradeLevel = .grade9,
         subject: Subject? = nil,
         transcript: [TutorTurn] = [],
         studentMessage: String = "",
         mood: MoodReading = .unknown,
         studentAskedForAnswer: Bool = false,
         attemptCount: Int = 0) {
        self.sourceText = sourceText
        self.studentNote = studentNote
        self.gradeLevel = gradeLevel
        self.subject = subject
        self.transcript = transcript
        self.studentMessage = studentMessage
        self.mood = mood
        self.studentAskedForAnswer = studentAskedForAnswer
        self.attemptCount = attemptCount
    }
}

/// One line of tutor conversation.
struct TutorTurn: Sendable, Codable, Identifiable, Equatable {
    enum Speaker: String, Codable, Sendable { case student, ace }

    var id: UUID = UUID()
    var speaker: Speaker
    var text: String
    var timestamp: Date = Date()
    /// True when this turn was a hint rather than a full answer — used by the
    /// UI to style it and by the tutor to know how far up the ladder it is.
    var isHint: Bool = false
}

/// What Ace reads from an image.
struct RecognizedText: Sendable, Equatable {
    /// Lines in reading order, straight from the recogniser.
    var lines: [String]
    /// 0...1 average confidence. Below ~0.4 we tell the student to retake it
    /// rather than quietly building a quiz out of mush.
    var confidence: Double

    var isUsable: Bool { !lines.isEmpty && confidence >= 0.3 }

    static let empty = RecognizedText(lines: [], confidence: 0)
}

/// Where generated study material comes from.
enum StudyMaterialSource: Sendable {
    case text(String)
}

/// Anything that can go wrong, in terms the UI can render a designed error
/// state for. No raw `NSError` ever reaches a student.
enum AIProviderError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case offline
    case rateLimited
    case audioUnavailable
    case noTextFound
    case cancelled
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Ace isn't connected to a key yet."
        case .offline: "No connection right now."
        case .rateLimited: "That was a lot of questions at once."
        case .audioUnavailable: "Ace can't reach the speaker or mic."
        case .noTextFound: "I couldn't read any text in that."
        case .cancelled: "Stopped."
        case .transport(let detail): detail
        }
    }

    /// The line Ace actually shows. Warm, specific, and always with a way out.
    var studentFacingSuggestion: String {
        switch self {
        case .notConfigured: "Demo Mode still works — everything here runs on your phone."
        case .offline: "Demo Mode works offline, so we can keep going."
        case .rateLimited: "Give it a few seconds and we'll pick right back up."
        case .audioUnavailable: "Check your volume and that nothing else is using the mic."
        case .noTextFound: "Try again with more light, or paste the text instead."
        case .cancelled: "No problem — say the word when you're ready."
        case .transport: "Let's try that once more."
        }
    }
}

// MARK: - The protocol

/// One protocol, every AI capability. See the file header.
///
/// All methods are `async` and every long-running one is cancellable, because a
/// student tapping "stop" must actually stop things — that's half of what makes
/// barge-in feel instant in Part 3.
protocol AIProvider: AnyObject, Sendable {

    /// Which implementation this is.
    var mode: AIProviderMode { get }

    /// True when the provider is ready to do work right now.
    var isReady: Bool { get }

    // MARK: Voice

    /// Speak a line in the given persona's voice, shaped by `prosody`.
    /// Returns when the audio has finished (or was interrupted).
    func speak(_ text: String, persona: VoicePersona, prosody: Prosody) async throws

    /// Stop speaking immediately. Must be safe to call when nothing is playing.
    /// The <150ms barge-in budget in §7 is measured from here.
    func stopSpeaking() async

    /// Convert recorded audio to text.
    func transcribe(audio: Data) async throws -> String

    // MARK: Tutoring

    /// The Socratic tutor. Streams the reply so the UI can start rendering — and
    /// the voice can start speaking — on the first chunk instead of waiting for
    /// the whole thing.
    func tutorReply(context: TutorContext) -> AsyncThrowingStream<String, Error>

    // MARK: Reading the world

    /// Extract text from image data (JPEG/PNG/HEIC).
    func readText(from imageData: Data) async throws -> RecognizedText

    // MARK: Study material

    func makeQuiz(from source: StudyMaterialSource,
                  gradeLevel: GradeLevel,
                  title: String,
                  questionCount: Int) async throws -> Quiz

    func makeFlashcards(from source: StudyMaterialSource,
                        gradeLevel: GradeLevel,
                        title: String,
                        limit: Int) async throws -> [Flashcard]

    // MARK: Reading the student

    /// How the student sounds. `audio` is optional — in text-only moments we
    /// read cadence and content instead.
    func readEmotion(audio: Data?, text: String?, signals: BehaviourSignals) async -> MoodReading
}

/// Non-verbal evidence about how a session is going. The mock provider runs
/// entirely on this; the live provider uses it alongside the audio.
///
/// Everything here is measured locally and never leaves the device.
struct BehaviourSignals: Sendable, Equatable {
    /// Consecutive correct answers.
    var correctStreak: Int = 0
    /// Consecutive wrong answers.
    var wrongStreak: Int = 0
    /// Seconds between the question appearing and the student answering.
    var lastResponseLatency: TimeInterval = 0
    /// Rolling average of the above.
    var averageResponseLatency: TimeInterval = 0
    /// Seconds since the student last did anything.
    var idleSeconds: TimeInterval = 0
    /// How many times they've left and come back this session.
    var appExits: Int = 0
    /// Hints taken on the current question.
    var hintsTaken: Int = 0

    static let none = BehaviourSignals()
}
