//
//  StudyMaterialGenerator.swift
//  Ace
//
//  Builds quizzes and flashcards from the student's own material, on-device,
//  with no network and no API key. This is what makes Demo Mode a real product
//  rather than a placeholder.
//
//  The approach is classic information-extraction, not machine learning:
//    1. Split the source into sentences.
//    2. Find the sentences that *define* something ("X is Y", "X refers to Y").
//       Textbooks and worksheets are full of these and they make the best
//       questions.
//    3. Find the important terms (capitalised phrases, repeated content words,
//       anything that got defined).
//    4. Blank a term out of its sentence to make a cloze question, and pull
//       distractors from the other terms in the same document — which is why
//       they feel plausible instead of random.
//
//  Everything here is deterministic given a seed, so tests can assert on exact
//  output and the same source always produces the same deck.
//

import Foundation

// MARK: - Deterministic randomness

/// A tiny seeded PRNG. We want shuffling (so the right answer isn't always
/// choice A) *and* reproducibility (so tests aren't flaky and a student who
/// re-opens a deck sees the same thing).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the all-zero state, which would make splitmix64 degenerate.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// splitmix64 — short, fast, and good enough for shuffling four strings.
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension String {
    /// Stable hash for seeding. Swift's `hashValue` is randomised per process,
    /// so it cannot be used for anything reproducible.
    var stableSeed: UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325   // FNV-1a offset basis
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        return hash
    }
}

// MARK: - Extraction primitives

/// A term worth learning, with the sentence it came from.
struct KeyTerm: Sendable, Equatable {
    var term: String
    /// The sentence the term was found in, used for cloze questions and context.
    var sentence: String
    /// The definition, when the sentence was a definition ("X is Y" → Y).
    var definition: String?
    /// Higher = more central to the document.
    var weight: Int
}

enum TextAnalysis {

    /// Words too common to ever be a quiz answer.
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "than", "that", "this",
        "these", "those", "is", "are", "was", "were", "be", "been", "being", "am",
        "of", "to", "in", "on", "at", "by", "for", "with", "from", "as", "into",
        "it", "its", "he", "she", "they", "them", "we", "you", "i", "his", "her",
        "their", "our", "your", "my", "which", "who", "whom", "whose", "what",
        "when", "where", "why", "how", "all", "any", "both", "each", "few", "more",
        "most", "other", "some", "such", "no", "not", "only", "own", "same", "so",
        "can", "will", "just", "should", "now", "also", "there", "here", "one",
        "two", "very", "may", "might", "must", "would", "could", "has", "have",
        "had", "do", "does", "did", "up", "down", "out", "over", "under", "about",
        "because", "while", "during", "between", "after", "before", "above",
        "below", "through", "called", "known", "used", "using", "make", "makes",
        "made", "get", "gets", "like", "many", "much", "example", "examples"
    ]

    /// Split prose into sentences. Handles the abbreviations that would
    /// otherwise chop "e.g." into its own sentence.
    static func sentences(in text: String) -> [String] {
        let protectedText = protectAbbreviations(text)
        var out: [String] = []
        var current = ""

        for ch in protectedText {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 1 {
                    out.append(restoreAbbreviations(trimmed))
                }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.count > 1 { out.append(restoreAbbreviations(tail)) }

        return out
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(separator: " ").count >= 4 }   // fragments make bad questions
    }

    private static let abbreviations = ["e.g.", "i.e.", "etc.", "vs.", "Dr.", "Mr.", "Mrs.", "Ms.", "St.", "Fig.", "Eq.", "approx."]
    private static let sentinel = "\u{FFFC}"   // object-replacement char, never in real text

    private static func protectAbbreviations(_ text: String) -> String {
        var s = text
        for (i, abbrev) in abbreviations.enumerated() {
            s = s.replacingOccurrences(of: abbrev, with: abbrev.replacingOccurrences(of: ".", with: "\(sentinel)\(i)\(sentinel)"))
        }
        return s
    }

    private static func restoreAbbreviations(_ text: String) -> String {
        var s = text
        for i in abbreviations.indices {
            s = s.replacingOccurrences(of: "\(sentinel)\(i)\(sentinel)", with: ".")
        }
        return s
    }

    /// Words in a sentence, stripped of punctuation, lowercased.
    static func words(in sentence: String) -> [String] {
        sentence
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Sentences shaped like a definition, returned as (subject, definition).
    ///
    /// These are the gold in any textbook page: "Photosynthesis is the process
    /// by which plants convert light into chemical energy."
    static func definitions(in sentence: String) -> (term: String, definition: String)? {
        // The connectives worth trusting, longest first so "is defined as"
        // wins over a bare "is".
        let connectives = [
            " is defined as ", " are defined as ", " is known as ", " are known as ",
            " is called ", " are called ", " refers to ", " refer to ",
            " means ", " is the ", " are the ", " is a ", " is an ", " are a "
        ]
        for connective in connectives {
            guard let range = sentence.range(of: connective, options: [.caseInsensitive]) else { continue }
            var lhs = String(sentence[sentence.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop a leading article so the term is "chloroplast", not "The
            // chloroplast" — otherwise every flashcard reads "What is The …?".
            for article in ["The ", "the ", "A ", "a ", "An ", "an "] where lhs.hasPrefix(article) {
                lhs = String(lhs.dropFirst(article.count))
                break
            }
            var rhs = String(sentence[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = rhs.last, last == "." || last == "," { rhs.removeLast() }

            // A definition subject is short. "One of the reasons the war ended
            // early is the collapse of supply lines" is not a definition.
            let subjectWords = lhs.split(separator: " ")
            guard (1...5).contains(subjectWords.count), lhs.count >= 3 else { continue }

            // The definition itself has to actually say something. Four words is
            // the line that rejects "Respiration is the opposite process" —
            // technically a definition, useless as a flashcard — while keeping
            // "Glucose is the sugar that plants store as food".
            guard rhs.split(separator: " ").count >= 4 else { continue }

            // Skip subjects that are only stopwords ("This is a...").
            let content = subjectWords.map { String($0).lowercased() }.filter { !stopwords.contains($0) }
            guard !content.isEmpty else { continue }

            return (lhs, rhs)
        }
        return nil
    }

    /// Pull out the terms worth learning, best first.
    static func keyTerms(in text: String, limit: Int = 40) -> [KeyTerm] {
        let allSentences = sentences(in: text)
        guard !allSentences.isEmpty else { return [] }

        var byKey: [String: KeyTerm] = [:]

        func record(_ term: String, sentence: String, definition: String?, weight: Int) {
            let cleaned = term.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:()[]\"'"))
            guard cleaned.count >= 3, cleaned.count <= 48 else { return }
            let lower = cleaned.lowercased()
            guard !stopwords.contains(lower) else { return }
            guard cleaned.contains(where: \.isLetter) else { return }

            if var existing = byKey[lower] {
                existing.weight += weight
                if existing.definition == nil, let definition { existing.definition = definition }
                byKey[lower] = existing
            } else {
                byKey[lower] = KeyTerm(term: cleaned, sentence: sentence,
                                       definition: definition, weight: weight)
            }
        }

        // 1. Defined terms — the strongest signal by far.
        for sentence in allSentences {
            if let (term, definition) = definitions(in: sentence) {
                record(term, sentence: sentence, definition: definition, weight: 10)
            }
        }

        // 2. Capitalised phrases mid-sentence (proper nouns, named concepts).
        for sentence in allSentences {
            for phrase in capitalisedPhrases(in: sentence) {
                record(phrase, sentence: sentence, definition: nil, weight: 4)
            }
        }

        // 3. Frequent content words. Repetition is how a page signals what it's
        //    about.
        var frequency: [String: Int] = [:]
        var firstSentence: [String: String] = [:]
        for sentence in allSentences {
            for word in words(in: sentence) where !stopwords.contains(word) && word.count >= 5 {
                frequency[word, default: 0] += 1
                if firstSentence[word] == nil { firstSentence[word] = sentence }
            }
        }
        for (word, count) in frequency where count >= 2 {
            record(word, sentence: firstSentence[word] ?? allSentences[0],
                   definition: nil, weight: min(count, 6))
        }

        return byKey.values
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.term.lowercased() < $1.term.lowercased()   // stable tiebreak
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Runs of capitalised words that aren't at the start of the sentence.
    /// Sentence-initial capitals tell us nothing.
    static func capitalisedPhrases(in sentence: String) -> [String] {
        let tokens = sentence.split(separator: " ").map(String.init)
        guard tokens.count > 1 else { return [] }

        var out: [String] = []
        var run: [String] = []

        for token in tokens.dropFirst() {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]\"'"))
            let isCapitalised = bare.first?.isUppercase == true && bare.count > 1
                && !bare.allSatisfy { $0.isUppercase || !$0.isLetter }   // skip ACRONYMS-only here
            if isCapitalised {
                run.append(bare)
            } else {
                if !run.isEmpty { out.append(run.joined(separator: " ")); run = [] }
                // Acronyms on their own are still worth keeping.
                if bare.count >= 2, bare.count <= 6, bare.allSatisfy({ $0.isUppercase || $0.isNumber }),
                   bare.contains(where: \.isLetter) {
                    out.append(bare)
                }
            }
        }
        if !run.isEmpty { out.append(run.joined(separator: " ")) }
        return out
    }
}

// MARK: - Generator

/// Produces the actual decks. `seed` makes output reproducible.
struct StudyMaterialGenerator: Sendable {

    let gradeLevel: GradeLevel

    init(gradeLevel: GradeLevel = .grade9) {
        self.gradeLevel = gradeLevel
    }

    // MARK: Flashcards

    /// Definition cards first (the most useful), then cloze cards from key
    /// sentences to fill the deck out.
    func flashcards(from text: String, title: String, limit: Int = 20) -> [Flashcard] {
        let terms = TextAnalysis.keyTerms(in: text)
        guard !terms.isEmpty else { return [] }

        var cards: [Flashcard] = []
        var usedTerms = Set<String>()

        // 1. Real definitions → "What is X?" / "Y"
        for term in terms where term.definition != nil {
            guard cards.count < limit else { break }
            let key = term.term.lowercased()
            guard !usedTerms.contains(key) else { continue }
            usedTerms.insert(key)
            cards.append(Flashcard(
                front: "What is \(questionForm(term.term))?",
                back: sentenceCase(term.definition ?? ""),
                context: term.sentence
            ))
        }

        // 2. Cloze cards for the remaining strong terms.
        for term in terms where term.definition == nil {
            guard cards.count < limit else { break }
            let key = term.term.lowercased()
            guard !usedTerms.contains(key) else { continue }
            guard let blanked = blank(term.term, in: term.sentence) else { continue }
            usedTerms.insert(key)
            cards.append(Flashcard(
                front: blanked,
                back: term.term,
                context: term.sentence
            ))
        }

        return cards
    }

    // MARK: Quiz

    /// Build a multiple-choice quiz. Distractors come from other terms in the
    /// same document, which is what makes them plausible.
    func quiz(from text: String, title: String, questionCount: Int = 8) -> Quiz {
        let terms = TextAnalysis.keyTerms(in: text)
        guard terms.count >= 2 else {
            return Quiz(title: title, questions: [])
        }

        let choiceCount = gradeLevel.quizChoiceCount
        var generator = SeededGenerator(seed: (text + title).stableSeed)
        var questions: [QuizQuestion] = []
        var usedTerms = Set<String>()

        for term in terms {
            guard questions.count < questionCount else { break }
            let key = term.term.lowercased()
            guard !usedTerms.contains(key) else { continue }

            let rawDistractors = pickDistractors(for: term, from: terms,
                                                 count: choiceCount - 1,
                                                 using: &generator)
            guard rawDistractors.count == choiceCount - 1 else { continue }

            // Normalise the casing of every choice.
            //
            // Source material capitalises inconsistently — "Backpropagation" at
            // the start of a sentence, "loss function" mid-sentence. Left alone,
            // the odd one out becomes a visual tell and students answer by
            // spotting it rather than by knowing the material.
            let displayTerm = sentenceCase(term.term)
            let distractors = rawDistractors.map(sentenceCase)
            guard !distractors.contains(displayTerm) else { continue }

            // Prefer a definition question; fall back to cloze.
            let prompt: String
            let explanation: String
            if let definition = term.definition {
                prompt = "Which term does this describe?\n\n“\(sentenceCase(definition))”"
                explanation = "\(displayTerm) — \(sentenceCase(definition))."
            } else if let blanked = blank(term.term, in: term.sentence) {
                prompt = blanked
                explanation = "The full sentence reads: “\(term.sentence)”"
            } else {
                continue
            }

            usedTerms.insert(key)

            var choices = distractors + [displayTerm]
            choices.shuffle(using: &generator)
            guard let correctIndex = choices.firstIndex(of: displayTerm) else { continue }

            // Hints describe the answer, so they're built from the same cased
            // string the student is looking at.
            var casedTerm = term
            casedTerm.term = displayTerm

            questions.append(QuizQuestion(
                prompt: prompt,
                choices: choices,
                correctIndex: correctIndex,
                explanation: explanation,
                hints: hints(for: casedTerm)
            ))
        }

        return Quiz(title: title, questions: questions)
    }

    // MARK: Hints (the Socratic ladder)

    /// Three escalating nudges. Ace hands these out one at a time; the answer
    /// itself is never in hint 1 or 2.
    func hints(for term: KeyTerm) -> [String] {
        var out: [String] = []

        // 1. Point at where it lives, without naming it.
        let topicWords = TextAnalysis.words(in: term.sentence)
            .filter { !TextAnalysis.stopwords.contains($0) && $0.count > 4 && $0 != term.term.lowercased() }
        if let topic = topicWords.first {
            out.append("Think about the part that deals with \(topic).")
        } else {
            out.append("Read the sentence again and say it out loud — what's it actually claiming?")
        }

        // 2. Shape of the answer, still not the answer.
        let wordCount = term.term.split(separator: " ").count
        if wordCount > 1 {
            out.append("It's \(wordCount) words, and it starts with “\(String(term.term.prefix(1)))”.")
        } else {
            out.append("It starts with “\(String(term.term.prefix(1)))” and it's \(term.term.count) letters.")
        }

        // 3. Nearly there — the definition without the label.
        if let definition = term.definition {
            out.append("It's the one that means: \(sentenceCase(definition)).")
        } else {
            out.append("Ready? Say your best guess out loud first — then check it.")
        }

        return out
    }

    // MARK: Helpers

    /// Replace a term with a blank, preserving the rest of the sentence.
    /// Returns nil when the term can't be found (e.g. it was stemmed).
    func blank(_ term: String, in sentence: String) -> String? {
        guard let range = sentence.range(of: term, options: [.caseInsensitive]) else { return nil }
        var blanked = sentence.replacingCharacters(in: range, with: "________")
        blanked = blanked.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence that is mostly blank teaches nothing.
        guard blanked.split(separator: " ").count >= 5 else { return nil }
        return blanked
    }

    /// Choose wrong answers that look like they *could* be right: same rough
    /// length, same capitalisation style, drawn from the same document.
    func pickDistractors(for term: KeyTerm,
                         from pool: [KeyTerm],
                         count: Int,
                         using generator: inout SeededGenerator) -> [String] {
        let answerIsCapitalised = term.term.first?.isUppercase == true
        let answerWordCount = term.term.split(separator: " ").count

        // Numeric answers get numeric distractors — pulling a word out of the
        // pool next to "1789" gives the answer away instantly.
        if let number = Double(term.term) {
            return numericDistractors(around: number, count: count, using: &generator)
        }

        let candidates = pool
            .filter { $0.term.lowercased() != term.term.lowercased() }
            // Don't offer a distractor that is a substring of the answer (or
            // vice versa) — it reads as a trick rather than a question.
            .filter { !$0.term.lowercased().contains(term.term.lowercased()) }
            .filter { !term.term.lowercased().contains($0.term.lowercased()) }
            .sorted { lhs, rhs in
                score(lhs, capitalised: answerIsCapitalised, words: answerWordCount, target: term.term)
                    > score(rhs, capitalised: answerIsCapitalised, words: answerWordCount, target: term.term)
            }

        // Take a shortlist of the most plausible candidates, then shuffle within
        // it. Always taking the top-scoring few makes every question in a deck
        // offer the same two wrong answers, which teaches students to answer by
        // elimination instead of by understanding.
        var shortlist: [String] = []
        var seen = Set<String>()
        for candidate in candidates where shortlist.count < count * 2 {
            let key = candidate.term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            shortlist.append(candidate.term)
        }
        shortlist.shuffle(using: &generator)
        return Array(shortlist.prefix(count))
    }

    /// Similarity score for distractor ranking. Higher = more plausible.
    private func score(_ candidate: KeyTerm, capitalised: Bool, words: Int, target: String) -> Int {
        var s = 0
        if (candidate.term.first?.isUppercase == true) == capitalised { s += 3 }
        if candidate.term.split(separator: " ").count == words { s += 3 }
        let lengthDelta = abs(candidate.term.count - target.count)
        s += max(0, 4 - lengthDelta / 3)
        s += min(candidate.weight, 5)
        return s
    }

    private func numericDistractors(around value: Double,
                                    count: Int,
                                    using generator: inout SeededGenerator) -> [String] {
        let isInteger = value == value.rounded()
        var out: [String] = []
        // Offsets that look like real mistakes: transpositions and near misses.
        let offsets: [Double] = [1, -1, 2, -2, 10, -10, value * 0.5, value * 2]
        for offset in offsets where out.count < count {
            let candidate = value + (offset == value * 0.5 || offset == value * 2 ? offset - value : offset)
            guard candidate != value, candidate > 0 || value < 0 else { continue }
            let text = isInteger ? String(Int(candidate.rounded())) : String(format: "%.2f", candidate)
            if !out.contains(text) { out.append(text) }
        }
        return Array(out.prefix(count))
    }

    /// Make a term read naturally inside "What is ___?".
    ///
    /// Terms extracted from a definition have had their leading article stripped
    /// (so the answer is "chloroplast", not "The chloroplast"), which is right
    /// for a quiz choice but reads wrong in a question: "What is chloroplast?".
    /// A lowercase term is a common noun and gets its article back; a
    /// capitalised one is a proper name or a term the source capitalised, and is
    /// left alone.
    private func questionForm(_ term: String) -> String {
        guard let first = term.first, first.isLowercase else { return term }
        return "the \(term)"
    }

    /// Uppercase the first letter, leave everything else alone (so "DNA" and
    /// "pH" survive).
    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
