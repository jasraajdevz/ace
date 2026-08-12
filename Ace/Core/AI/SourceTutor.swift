//
//  SourceTutor.swift
//  Ace
//
//  Ace's teaching brain for open conversation about a piece of material.
//
//  `SocraticEngine` handles the structured case — a specific quiz question with
//  a known answer and a prepared hint ladder. This handles the unstructured one:
//  the student is looking at their chapter and says "I don't get the light
//  reactions". There is no prepared answer, only the page.
//
//  The rule that makes this feel like a tutor rather than a chatbot:
//
//      Ace never says anything that isn't on the student's page.
//
//  Every reply is anchored to a real sentence from the source. That's what stops
//  it inventing plausible nonsense — a keyless app has no model to fall back on,
//  and even in Live Mode (Part 3) grounding is what stops confident wrongness.
//  If Ace can't find a relevant sentence, it says so and asks the student to
//  point at the bit they mean, which is what a real tutor does.
//
//  The second rule, from §10: questions and hints before answers. The student
//  gets asked what *they* think first, every time, unless they explicitly ask to
//  be told.
//

import Foundation

/// What the student's message is trying to do. Ace responds very differently to
/// "what is chlorophyll" and "is it because the leaf is green?".
enum StudentIntent: String, Sendable, Equatable {
    /// "What is X?", "How does Y work?"
    case question
    /// An attempt at an answer — the thing we most want to encourage.
    case attempt
    /// "I don't know", "no idea", "I'm stuck"
    case stuck
    /// "Just tell me"
    case wantsAnswer
    /// "got it", "makes sense"
    case acknowledgement
    /// Anything else.
    case chat
}

enum SourceTutor {

    // MARK: - Reading the student

    private static let stuckPhrases = [
        "i don't know", "i dont know", "idk", "no idea", "i'm stuck", "im stuck",
        "i have no clue", "not a clue", "i'm lost", "im lost", "no clue", "dunno"
    ]

    private static let acknowledgementPhrases = [
        "got it", "makes sense", "i see", "ah ok", "ohh", "that helps", "thanks",
        "thank you", "cool", "gotcha", "right ok", "oh right"
    ]

    private static let questionOpeners = [
        "what", "why", "how", "when", "where", "which", "who", "can you", "could you",
        "explain", "tell me about", "help me with", "i don't understand",
        "i dont understand", "i don't get", "i dont get"
    ]

    /// Question-word + auxiliary pairs. Unlike the openers these are matched
    /// anywhere in the message, which is what catches "got it, but why does the
    /// water matter". A bare "what" can't be used this way — it appears in
    /// plenty of statements ("chlorophyll is what captures the light") — but the
    /// pair is unambiguous.
    private static let questionBigrams = [
        "what is", "what are", "what does", "what do", "what happens",
        "why is", "why are", "why does", "why do", "why did",
        "how is", "how are", "how does", "how do", "how did", "how come",
        "when does", "when did", "where does", "where is", "which one",
        "can you", "could you", "do i", "does it", "is it because"
    ]

    /// Words that express *asking* rather than naming a topic. Used to tell
    /// "just tell me" (no topic — reveal the main point) apart from "just tell
    /// me about the Treaty of Versailles" (a topic that isn't on the page, so
    /// Ace must decline rather than invent).
    private static let requestWords: Set<String> = [
        "tell", "answer", "know", "show", "give", "explain", "help", "understand",
        "clue", "idea", "stuck", "lost", "please", "honestly", "really", "actually",
        "anything", "something", "sorry", "okay", "just", "about", "with", "this",
        "that", "there"
    ]

    /// Classify what the student just said.
    static func intent(of message: String) -> StudentIntent {
        let text = message.lowercased().trimmed
        guard !text.isEmpty else { return .chat }

        // Explicit requests for the answer win — honouring them is a feature.
        if SocraticEngine.isAskingForAnswer(text) { return .wantsAnswer }

        if stuckPhrases.contains(where: { text.contains($0) }) { return .stuck }

        // A short message that's *only* an acknowledgement. Checked against
        // length so "got it, but why does the water matter?" stays a question.
        if text.split(separator: " ").count <= 4,
           acknowledgementPhrases.contains(where: { text.contains($0) }) {
            return .acknowledgement
        }

        if text.hasSuffix("?") { return .question }
        if questionOpeners.contains(where: { text.hasPrefix($0) }) { return .question }
        if questionBigrams.contains(where: { text.contains($0) }) { return .question }

        // Anything else of substance is treated as an attempt. Erring this way
        // matters: mistaking an attempt for chat means Ace ignores a student who
        // tried, which is the worst thing a tutor can do.
        return text.split(separator: " ").count >= 2 ? .attempt : .chat
    }

    // MARK: - Finding the ground

    /// The sentence in the source most relevant to a message, with a score.
    ///
    /// Plain content-word overlap. It's crude, and it's the right amount of
    /// machinery: on a single page of material it reliably lands on the right
    /// sentence, and it can never hallucinate because it only ever returns text
    /// the student already has.
    static func anchor(for message: String, in source: String) -> (sentence: String, score: Int)? {
        let sentences = TextAnalysis.sentences(in: source)
        guard !sentences.isEmpty else { return nil }

        let queryWords = Set(TextAnalysis.words(in: message)
            .filter { !TextAnalysis.stopwords.contains($0) && $0.count > 3 })
        guard !queryWords.isEmpty else { return nil }

        var best: (sentence: String, score: Int)?
        for sentence in sentences {
            let words = Set(TextAnalysis.words(in: sentence))
            let overlap = queryWords.intersection(words).count
            if overlap > (best?.score ?? 0) {
                best = (sentence, overlap)
            }
        }
        // One shared word is noise, not relevance.
        guard let best, best.score >= 1 else { return nil }
        return best
    }

    /// How well an attempted answer lines up with the source sentence, 0...1.
    ///
    /// This is an F1 (harmonic mean of precision and recall), not plain overlap,
    /// and the difference matters. With plain overlap, "chlorophyll is sugar"
    /// scores 0.5 against the chlorophyll sentence — half its words are in
    /// there — so Ace would congratulate a student on a flatly wrong answer.
    /// Requiring the attempt to *cover* the sentence's content as well as draw
    /// from it drops that to 0.2, while a real paraphrase still scores ~0.86.
    static func agreement(between attempt: String, and sentence: String) -> Double {
        func content(_ text: String) -> Set<String> {
            Set(TextAnalysis.words(in: text)
                .filter { !TextAnalysis.stopwords.contains($0) && $0.count > 3 })
        }
        let attemptWords = content(attempt)
        let sentenceWords = content(sentence)
        guard !attemptWords.isEmpty, !sentenceWords.isEmpty else { return 0 }

        let shared = Double(attemptWords.intersection(sentenceWords).count)
        guard shared > 0 else { return 0 }

        let precision = shared / Double(attemptWords.count)   // did they say only relevant things?
        let recall = shared / Double(sentenceWords.count)     // did they cover the idea?
        return 2 * precision * recall / (precision + recall)
    }

    /// Content words that name a *topic*, with request/filler words removed.
    /// Empty means the student asked for help without saying about what.
    static func topicWords(in message: String) -> Set<String> {
        Set(TextAnalysis.words(in: message)
            .filter { !TextAnalysis.stopwords.contains($0) }
            .filter { $0.count > 3 }
            .filter { !requestWords.contains($0) })
    }

    /// The single most important sentence in the material — the one carrying the
    /// most-weighted key term.
    ///
    /// Used when a student asks for help without naming a topic ("just tell me",
    /// "I don't know"). Falling back to the main point is grounded and useful;
    /// falling back to nothing would leave Ace mute at exactly the moment it's
    /// most needed.
    static func primaryAnchor(in source: String) -> String? {
        if let top = TextAnalysis.keyTerms(in: source, limit: 1).first {
            return top.sentence
        }
        return TextAnalysis.sentences(in: source).first
    }

    // MARK: - Opening

    /// Ace's first line of a session. Uses the student's own note about what
    /// they're doing, because that's the difference between a tutor who read the
    /// brief and one who didn't.
    static func opening(source: String, note: String, gradeLevel: GradeLevel) -> String {
        let terms = TextAnalysis.keyTerms(in: source, limit: 3).map(\.term)
        let topic = terms.first

        if !note.trimmed.isEmpty {
            if let topic {
                return "Right — \(note.trimmed). I've read it. Before I explain anything: what do you already know about \(topic)?"
            }
            return "Right — \(note.trimmed). I've read the page. Where do you want to start?"
        }

        if let topic {
            let others = terms.dropFirst().joined(separator: " and ")
            let mention = others.isEmpty ? "" : " There's \(others) in here too."
            return "Okay, I've read it. This is mostly about \(topic).\(mention) What's the bit that isn't clicking?"
        }

        return "I've read it. What are we working on — the whole thing, or one bit that's bugging you?"
    }

    // MARK: - Replying

    /// Ace's next line.
    ///
    /// - Parameters:
    ///   - exchanges: how many turns the student has had on the current point.
    ///     Drives how far up the hint ladder Ace is.
    static func reply(to message: String,
                      source: String,
                      note: String,
                      exchanges: Int,
                      mood: Mood,
                      gradeLevel: GradeLevel) -> SocraticReply {

        let intent = self.intent(of: message)
        let rung = SocraticEngine.rung(attemptCount: exchanges,
                                       askedForAnswer: intent == .wantsAnswer,
                                       mood: mood)

        var found = anchor(for: message, in: source)

        // "Just tell me" and "I don't know" name no topic, so there's nothing to
        // match on — but the student is asking for help, and going silent is the
        // worst possible response. Fall back to the material's main point.
        //
        // Crucially this only applies when they named *no* topic. "Just tell me
        // about the Treaty of Versailles" does name one, and if it isn't on the
        // page Ace must say so rather than answer a different question.
        if found == nil,
           intent == .wantsAnswer || intent == .stuck,
           topicWords(in: message).isEmpty,
           let primary = primaryAnchor(in: source) {
            found = (primary, 0)
        }

        // Nothing on the page matches. Say so honestly rather than inventing —
        // this is the single most important branch in the file.
        guard let found else {
            return SocraticReply(text: offPage(intent: intent, message: message), rung: .orient)
        }
        let sentence = found.sentence

        switch intent {
        case .wantsAnswer:
            return SocraticReply(
                text: "Here it is, straight: “\(sentence)” "
                    + followUp(for: gradeLevel),
                rung: .reveal
            )

        case .stuck:
            // Being stuck earns a bigger step down the ladder, not a lecture.
            return SocraticReply(
                text: "\(softener(for: mood)) Look at this line: “\(sentence)” "
                    + "Read it once — which word in it would you want defined?",
                rung: .narrow
            )

        case .attempt:
            return attemptReply(message: message, sentence: sentence,
                                mood: mood, gradeLevel: gradeLevel, rung: rung)

        case .acknowledgement:
            return SocraticReply(text: checkUnderstanding(sentence: sentence), rung: .shape)

        case .question, .chat:
            return questionReply(sentence: sentence, rung: rung, mood: mood,
                                 gradeLevel: gradeLevel)
        }
    }

    // MARK: - Branches

    /// The student had a go. Respond to the *content* of what they said.
    private static func attemptReply(message: String,
                                     sentence: String,
                                     mood: Mood,
                                     gradeLevel: GradeLevel,
                                     rung: SocraticRung) -> SocraticReply {
        let agreement = self.agreement(between: message, and: sentence)

        if agreement >= 0.5 {
            // They've essentially got it. Confirm, then push one level deeper —
            // that's where understanding actually forms.
            return SocraticReply(
                text: "\(affirmation(for: mood)) The page puts it as: “\(sentence)” "
                    + deeperProbe(for: gradeLevel),
                rung: .reveal
            )
        }

        if agreement >= 0.3 {
            // Partially right. Name the part that's right before the part that
            // isn't — a student who hears only the correction stops trying.
            //
            // The threshold sits at 0.3 rather than 0.2 deliberately: at 0.2,
            // "chlorophyll is sugar" counts as partly right purely for naming
            // the topic, and telling a student that a wrong answer is "on the
            // right track" is worse than telling them nothing.
            return SocraticReply(
                text: "\(partialCredit(for: mood)) Compare what you said with this: “\(sentence)” "
                    + "What would you change about your version?",
                rung: .narrow
            )
        }

        // Off target. Never say "wrong" — redirect.
        if rung >= .nearly {
            return SocraticReply(
                text: "Not quite that one. Here's the line that matters: “\(sentence)” "
                    + "Put that into your own words and we're done.",
                rung: .reveal
            )
        }
        return SocraticReply(
            text: "\(softener(for: mood)) Different bit of the page — try this line: “\(sentence)” "
                + "What's it actually saying?",
            rung: .shape
        )
    }

    /// The student asked something. Answer with a question first.
    private static func questionReply(sentence: String,
                                      rung: SocraticRung,
                                      mood: Mood,
                                      gradeLevel: GradeLevel) -> SocraticReply {
        switch rung {
        case .orient:
            return SocraticReply(
                text: "Good question. Before I answer it — the page covers this. "
                    + "What's your best guess, even a rough one?",
                rung: .orient
            )
        case .narrow:
            return SocraticReply(
                text: "It's in here: “\(sentence)” What do you make of that?",
                rung: .narrow
            )
        case .shape:
            return SocraticReply(
                text: "Look at this line again: “\(sentence)” "
                    + "The answer's the part that says what it *does*. Which bit is that?",
                rung: .shape
            )
        case .nearly, .reveal:
            return SocraticReply(
                text: "Here it is: “\(sentence)” " + followUp(for: gradeLevel),
                rung: .reveal
            )
        }
    }

    /// Nothing in the source matches what they said.
    private static func offPage(intent: StudentIntent, message: String) -> String {
        switch intent {
        case .wantsAnswer:
            return "I'd tell you, but that isn't on the page you gave me — and I'm not going to "
                + "make something up. Read me the sentence you're stuck on and we'll take it apart."
        case .stuck:
            return "Okay. Point me at it — read me the line you're looking at, or the question number, "
                + "and we'll start there."
        case .acknowledgement:
            return "Good. What's next — another bit of this page, or shall I quiz you on it?"
        default:
            return "That doesn't look like it's in what you gave me. Are we still on this page, "
                + "or is this from something else? Either's fine — just tell me which."
        }
    }

    // MARK: - Voice

    /// Mood-matched opener for a correction (§9). A student who is already
    /// frustrated needs a different first three words.
    private static func softener(for mood: Mood) -> String {
        switch mood {
        case .frustrated: "Okay, forget that for a second."
        case .low: "No rush at all."
        case .confused: "Let's slow down."
        case .energized: "Close —"
        case .distracted: "Back with me?"
        case .focused, .neutral: "Not quite."
        }
    }

    /// Mood-matched praise. Even being right should sound different depending on
    /// how the student got there — an emphatic "Yes!" at someone who has been
    /// grinding for ten minutes reads as sarcasm.
    private static func affirmation(for mood: Mood) -> String {
        switch mood {
        case .energized: "Yes — that's it."
        case .focused, .neutral: "That's it."
        case .confused: "That's right — and you got there by working it out."
        case .frustrated: "There it is. That was the hard one."
        case .low: "That's exactly right."
        case .distracted: "Right — that's it."
        }
    }

    /// Mood-matched opener for a half-right answer.
    private static func partialCredit(for mood: Mood) -> String {
        switch mood {
        case .energized: "Close — you've got part of it."
        case .frustrated: "You're nearer than it feels."
        case .low: "That's a good chunk of it, honestly."
        case .confused: "Part of that is right, which is the hard part."
        case .distracted, .focused, .neutral: "You're on the right track."
        }
    }

    /// Register-appropriate line after a reveal.
    private static func followUp(for gradeLevel: GradeLevel) -> String {
        switch gradeLevel.band {
        case .elementary, .middle:
            return "Now say it back to me in your own words — that's the bit that makes it stick."
        case .high, .college:
            return "Now restate it without looking. If you can't, you've read it rather than learned it."
        }
    }

    /// The follow-up question after a correct attempt.
    private static func deeperProbe(for gradeLevel: GradeLevel) -> String {
        switch gradeLevel.band {
        case .elementary:
            return "So why does that matter — what would happen without it?"
        case .middle:
            return "Now the harder half: why does it work that way?"
        case .high:
            return "So what would break if that step didn't happen?"
        case .college:
            return "Good. Now argue the other side — where does that explanation stop holding?"
        }
    }

    /// After "got it" — never just accept it.
    private static func checkUnderstanding(sentence: String) -> String {
        "Prove it to me — say it back without looking at “\(sentence.prefix(28))…”. "
            + "If it comes out easily, we move on."
    }
}
