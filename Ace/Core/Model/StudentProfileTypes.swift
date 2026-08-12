//
//  StudentProfileTypes.swift
//  Ace
//
//  Plain value types that describe *who* the student is.
//
//  Everything in `Core/` is deliberately Foundation-only: no SwiftUI, no UIKit,
//  no SwiftData. That keeps this layer portable and — importantly for this
//  project — compilable and unit-testable straight from the command line
//  without Xcode. See `Tools/VerifyMain/main.swift`.
//

import Foundation

// MARK: - Grade level

/// How far along the student is. Drives vocabulary, question difficulty and the
/// register Ace speaks in (a 5th grader and a college sophomore should not get
/// the same sentence).
enum GradeLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case grade5, grade6, grade7, grade8
    case grade9, grade10, grade11, grade12
    case college

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grade5: "5th grade"
        case .grade6: "6th grade"
        case .grade7: "7th grade"
        case .grade8: "8th grade"
        case .grade9: "9th grade"
        case .grade10: "10th grade"
        case .grade11: "11th grade"
        case .grade12: "12th grade"
        case .college: "College"
        }
    }

    /// Short label for tight spaces (chips, the widget).
    var shortName: String {
        switch self {
        case .college: "College"
        default: displayName.replacingOccurrences(of: " grade", with: "")
        }
    }

    /// Broad bands. We tune tone and reading level per band rather than per
    /// grade — nine separate voices would be false precision.
    enum Band: String, Codable, Sendable {
        case elementary   // 5th
        case middle       // 6–8
        case high         // 9–12
        case college
    }

    var band: Band {
        switch self {
        case .grade5: .elementary
        case .grade6, .grade7, .grade8: .middle
        case .grade9, .grade10, .grade11, .grade12: .high
        case .college: .college
        }
    }

    /// Target sentence length for generated explanations, in words. Used by the
    /// mock tutor to keep answers age-appropriate.
    var targetSentenceWords: Int {
        switch band {
        case .elementary: 12
        case .middle: 15
        case .high: 19
        case .college: 24
        }
    }

    /// How many multiple-choice options feel fair at this level.
    var quizChoiceCount: Int {
        switch band {
        case .elementary: 3
        case .middle, .high, .college: 4
        }
    }
}

// MARK: - Subject

/// Subjects the student picks during onboarding. `.other` carries a free-text
/// label so nobody is boxed out of their own coursework.
enum Subject: Codable, Hashable, Sendable, Identifiable {
    case math
    case science
    case history
    case english
    case language
    case computerScience
    case other(String)

    var id: String {
        switch self {
        case .other(let name): "other:\(name.lowercased())"
        default: storageKey
        }
    }

    /// Stable string used for persistence.
    var storageKey: String {
        switch self {
        case .math: "math"
        case .science: "science"
        case .history: "history"
        case .english: "english"
        case .language: "language"
        case .computerScience: "cs"
        case .other(let name): "other:\(name)"
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("other:") {
            let name = String(storageKey.dropFirst("other:".count))
            guard !name.isEmpty else { return nil }
            self = .other(name)
            return
        }
        switch storageKey {
        case "math": self = .math
        case "science": self = .science
        case "history": self = .history
        case "english": self = .english
        case "language": self = .language
        case "cs": self = .computerScience
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .math: "Math"
        case .science: "Science"
        case .history: "History"
        case .english: "English"
        case .language: "Languages"
        case .computerScience: "Computer Science"
        case .other(let name): name
        }
    }

    /// SF Symbol used on chips and cards.
    var symbolName: String {
        switch self {
        case .math: "function"
        case .science: "atom"
        case .history: "building.columns"
        case .english: "book"
        case .language: "globe"
        case .computerScience: "chevron.left.forwardslash.chevron.right"
        case .other: "sparkles"
        }
    }

    /// The set offered as one-tap chips in onboarding.
    static var presets: [Subject] {
        [.math, .science, .history, .english, .language, .computerScience]
    }
}

// MARK: - Settings snapshot

/// A plain snapshot of the student's preferences.
///
/// The persistence layer owns a SwiftData `Profile`; everything else takes one
/// of these. That's what lets `AppState`, the tutor and the voice layer be
/// tested without a database anywhere near them.
struct StudentSettings: Sendable, Equatable {
    var name: String
    var gradeLevel: GradeLevel
    var subjects: [Subject]
    var voicePersonaID: String
    var supportRegion: SupportRegion

    init(name: String = "",
         gradeLevel: GradeLevel = .grade9,
         subjects: [Subject] = [],
         voicePersonaID: String = VoiceRoster.default.id,
         supportRegion: SupportRegion = .unitedStates) {
        self.name = name
        self.gradeLevel = gradeLevel
        self.subjects = subjects
        self.voicePersonaID = voicePersonaID
        self.supportRegion = supportRegion
    }

    /// First name only, for greetings.
    var firstName: String {
        String(name.split(separator: " ").first ?? "")
    }

    var greetingName: String {
        firstName.isEmpty ? "there" : firstName
    }
}

// MARK: - Mood

/// Ace's read on how the student is doing *right now*.
///
/// In Demo Mode this comes from heuristics (answer streaks, response latency,
/// typing cadence). In Live Mode the realtime model contributes too. Either way
/// the rest of the app only ever sees this enum, so the UI never has to care
/// which provider produced it.
enum Mood: String, Codable, CaseIterable, Sendable {
    case neutral
    case energized     // rolling, on a streak — match with hype
    case focused       // in the zone — stay out of the way
    case confused      // needs a slower, smaller step
    case frustrated    // needs patience and an easier win
    case low           // needs warmth first, work second
    case distracted    // needs a gentle pull back

    var displayName: String {
        switch self {
        case .neutral: "Steady"
        case .energized: "On fire"
        case .focused: "Locked in"
        case .confused: "A bit lost"
        case .frustrated: "Frustrated"
        case .low: "Low"
        case .distracted: "Drifting"
        }
    }

    /// Moods where hype, streak-pressure and gamification are the wrong move.
    var wantsGentleness: Bool {
        switch self {
        case .low, .frustrated, .confused: true
        case .neutral, .energized, .focused, .distracted: false
        }
    }
}

/// A mood plus how strongly we believe it, 0...1. Confidence matters: a weak
/// read should not make Ace change personality mid-sentence.
struct MoodReading: Codable, Sendable, Equatable {
    var mood: Mood
    var confidence: Double
    /// Human-readable reason, surfaced in the debug HUD. Never shown to students.
    var rationale: String

    init(mood: Mood, confidence: Double = 0.5, rationale: String = "") {
        self.mood = mood
        self.confidence = min(max(confidence, 0), 1)
        self.rationale = rationale
    }

    static let unknown = MoodReading(mood: .neutral, confidence: 0, rationale: "no signal yet")

    /// Only act on a reading we're reasonably sure about.
    var isActionable: Bool { confidence >= 0.45 }
}
