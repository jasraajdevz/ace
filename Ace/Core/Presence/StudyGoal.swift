//
//  StudyGoal.swift
//  Ace
//
//  "Let's go till chapter 4."
//
//  The goal a student sets with Ace at the start of a body-double session. Three
//  shapes, because those are the three ways people actually think about a study
//  session: for a while, through a number of things, or until a place in the
//  material.
//
//  Parsing is deliberately forgiving. A student typing their goal is not filling
//  in a form, and anything we can't parse becomes an open-ended goal with their
//  own words kept verbatim — never an error and never a rejected input.
//

import Foundation

/// What "done" means for this session.
enum GoalTarget: Sendable, Equatable {
    /// "25 minutes", "half an hour"
    case duration(minutes: Int)
    /// "10 questions", "20 cards"
    case count(Int, unit: CountUnit)
    /// "chapter 4", "the end of the essay" — Ace can't measure it, so the
    /// student says when it's done.
    case landmark(String)

    enum CountUnit: String, Sendable, Codable {
        case questions, cards, pages

        func label(_ count: Int) -> String {
            let singular = String(rawValue.dropLast())
            return "\(count) \(count == 1 ? singular : rawValue)"
        }
    }
}

/// A goal, plus the words the student used for it.
struct StudyGoal: Sendable, Equatable {
    var target: GoalTarget
    /// Exactly what they typed or said. Used in Ace's replies so the goal is
    /// theirs, not a paraphrase.
    var rawText: String

    /// How Ace refers to the goal.
    var displayText: String {
        switch target {
        case .duration(let minutes):
            return minutes >= 60 && minutes % 60 == 0
                ? "\(minutes / 60) hour\(minutes == 60 ? "" : "s")"
                : "\(minutes) minutes"
        case .count(let count, let unit):
            return unit.label(count)
        case .landmark(let name):
            return name
        }
    }

    /// Whether Ace can measure progress itself.
    var isMeasurable: Bool {
        if case .landmark = target { return false }
        return true
    }

    static let defaultGoal = StudyGoal(target: .duration(minutes: 25),
                                       rawText: "25 minutes")
}

// MARK: - Parsing

enum GoalParser {

    /// Number words students actually type.
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90,
        "a": 1, "an": 1, "half": 30, "couple": 2, "few": 3
    ]

    private static let countUnitWords: [(String, GoalTarget.CountUnit)] = [
        ("questions", .questions), ("question", .questions),
        ("qs", .questions), ("problems", .questions), ("problem", .questions),
        ("cards", .cards), ("card", .cards), ("flashcards", .cards),
        ("pages", .pages), ("page", .pages)
    ]

    /// Turn what the student said into a goal.
    ///
    /// Never fails. Anything unrecognised becomes a landmark carrying their own
    /// words — "let's go till I understand mitosis" is a perfectly good goal
    /// even though nothing about it is countable.
    static func parse(_ raw: String) -> StudyGoal {
        let text = raw.trimmed
        guard !text.isEmpty else { return .defaultGoal }

        let lower = text.lowercased()

        // "half an hour" / "an hour" — special-cased because the number and the
        // unit are the same word.
        if lower.contains("half an hour") || lower.contains("half hour") {
            return StudyGoal(target: .duration(minutes: 30), rawText: text)
        }
        if lower.contains("hour") {
            let count = leadingNumber(in: lower, before: "hour") ?? 1
            return StudyGoal(target: .duration(minutes: count * 60), rawText: text)
        }

        // Minutes.
        for word in ["minutes", "minute", "mins", "min"] where lower.contains(word) {
            if let count = leadingNumber(in: lower, before: word) {
                return StudyGoal(target: .duration(minutes: max(1, count)), rawText: text)
            }
        }

        // Countable things.
        for (word, unit) in countUnitWords where lower.contains(word) {
            if let count = leadingNumber(in: lower, before: word) {
                return StudyGoal(target: .count(max(1, count), unit: unit), rawText: text)
            }
        }

        // Everything else is a landmark. Strip the lead-in so the goal reads as
        // a place rather than a sentence: "let's go till chapter 4" → "chapter 4".
        return StudyGoal(target: .landmark(landmarkName(from: text)), rawText: text)
    }

    /// The number immediately before `word`, digits or words.
    private static func leadingNumber(in text: String, before word: String) -> Int? {
        guard let range = text.range(of: word) else { return nil }
        let prefix = String(text[text.startIndex..<range.lowerBound])
        let tokens = prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        // Walk backwards: the nearest number is the one that means something.
        for token in tokens.reversed() {
            if let digits = Int(token) { return digits }
            if let spelled = numberWords[token] { return spelled }
            // Stop at the first content word that isn't a number, so
            // "10 questions then 5 cards" doesn't attribute 10 to cards.
            if token.count > 2 && numberWords[token] == nil && Int(token) == nil {
                continue
            }
        }
        return nil
    }

    /// Trim the conversational lead-in off a landmark.
    private static func landmarkName(from text: String) -> String {
        var result = text
        let leadIns = [
            "let's go till ", "lets go till ", "let's go until ", "lets go until ",
            "let's go to ", "lets go to ", "go till ", "go until ", "until ",
            "till ", "i want to get to ", "get to ", "finish ", "i want to finish ",
            "work through ", "get through ", "do "
        ]
        for leadIn in leadIns {
            if result.lowercased().hasPrefix(leadIn) {
                result = String(result.dropFirst(leadIn.count))
                break
            }
        }
        return result.trimmed.isEmpty ? text : result.trimmed
    }
}

// MARK: - Progress

/// How far through the goal we are.
struct GoalProgress: Sendable, Equatable {
    var completed: Double
    var total: Double

    /// 0...1. A landmark goal has no measurable total, so it reports 0 and the
    /// UI shows elapsed time instead of a bar.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(completed / total, 0), 1)
    }

    var isComplete: Bool { total > 0 && completed >= total }

    static let none = GoalProgress(completed: 0, total: 0)
}

/// The points where Ace says something.
///
/// Three, at a quarter, half and three-quarters. Deliberately few: this is
/// co-working, not a fitness app. Somebody who is concentrating does not want to
/// be congratulated every ninety seconds.
enum Milestone: Int, Sendable, CaseIterable, Comparable {
    case quarter = 25
    case half = 50
    case threeQuarters = 75

    static func < (lhs: Milestone, rhs: Milestone) -> Bool { lhs.rawValue < rhs.rawValue }

    var fraction: Double { Double(rawValue) / 100 }

    /// The most recent milestone passed at this progress, if any.
    static func reached(at fraction: Double) -> Milestone? {
        allCases.reversed().first { fraction >= $0.fraction }
    }
}
