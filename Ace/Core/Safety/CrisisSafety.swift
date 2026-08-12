//
//  CrisisSafety.swift
//  Ace
//
//  The crisis safety net (§10). This is the highest-stakes code in the app, so
//  it is deliberately the simplest: plain string matching over a normalised
//  version of what the student said, with one structural rule that does most of
//  the work (see `FirstPersonRule` below).
//
//  Design priorities, in order:
//    1. Recall. Missing a real disclosure is unacceptable. A false positive
//       costs a student one gentle, kind message they can dismiss in a tap.
//    2. Comprehensibility. Anyone reading this file should be able to see
//       exactly why a phrase did or did not trigger. No ML, no opaque scores.
//    3. Precision *only where it's free*. We do not want "Macbeth kills Duncan"
//       or "the mitochondria die off" to trigger a crisis screen — but the fix
//       for those is a structural rule, not a blocklist of exceptions.
//
//  This service is called on EVERY free-text and transcribed-voice surface in
//  the app, in every mode, in every part. It never talks to the network.
//

import Foundation

// MARK: - Result types

/// How concerned we are about what the student just said.
enum CrisisSeverity: Int, Codable, Sendable, Comparable {
    /// Nothing detected. Carry on normally.
    case none = 0
    /// Distress, hopelessness or worthlessness without an explicit statement of
    /// self-harm. Ace responds warmly, offers resources softly, and eases back
    /// toward the work only if the student wants to.
    case concern = 1
    /// An explicit first-person statement about suicide or self-harm. Ace drops
    /// gamification entirely and runs the full support protocol.
    case crisis = 2

    static func < (lhs: CrisisSeverity, rhs: CrisisSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What kind of signal we saw. Used for logging and for choosing wording — not
/// for diagnosing anybody.
enum CrisisCategory: String, Codable, Sendable {
    case suicidalIntent      // "I'm going to kill myself"
    case suicidalIdeation    // "I wish I was dead", "I don't want to be here"
    case selfHarm            // "I've been cutting"
    case hopelessness        // "what's the point", "nothing will ever get better"
    case worthlessness       // "I hate myself", "everyone would be better off"
    case hyperbole           // "this homework is killing me"
    case none
}

/// The outcome of evaluating a piece of text.
struct CrisisSignal: Sendable, Equatable {
    var severity: CrisisSeverity
    var category: CrisisCategory
    /// The exact normalised substrings that matched. Shown in debug builds only;
    /// never surfaced to the student.
    var matches: [String]

    static let clear = CrisisSignal(severity: .none, category: .none, matches: [])

    var isCrisis: Bool { severity == .crisis }
    /// True whenever Ace must suppress XP, streaks, quizzes and hype.
    var suppressesGamification: Bool { severity >= .concern }
}

// MARK: - Region + resources

/// Where the student is, so we can give them a number that actually works.
/// Configurable in Settings; defaults to the device region with a US fallback.
enum SupportRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case unitedStates = "US"
    case canada = "CA"
    case unitedKingdom = "GB"
    case ireland = "IE"
    case australia = "AU"
    case newZealand = "NZ"
    case india = "IN"
    case international = "INT"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unitedStates: "United States"
        case .canada: "Canada"
        case .unitedKingdom: "United Kingdom"
        case .ireland: "Ireland"
        case .australia: "Australia"
        case .newZealand: "New Zealand"
        case .india: "India"
        case .international: "Elsewhere / international"
        }
    }

    /// Best guess from the device's region setting. Anything we don't have
    /// verified numbers for falls through to the international directory rather
    /// than to a wrong number.
    static func fromDeviceRegion(_ code: String?) -> SupportRegion {
        guard let code = code?.uppercased() else { return .unitedStates }
        return SupportRegion(rawValue: code) ?? .international
    }
}

/// One way to reach a human. `action` is what the button does.
struct SupportResource: Identifiable, Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case call(String)              // tel:
        case text(body: String, to: String)  // sms:
        case web(String)
        case info                      // no tap target, informational only
    }

    let id: String
    let title: String
    let detail: String
    let action: Action
    /// Shown first and styled most prominently.
    let isPrimary: Bool
}

enum SupportDirectory {

    /// Verified national lines. Kept small on purpose — a short list of numbers
    /// that definitely work beats a long list that might not.
    static func resources(for region: SupportRegion) -> [SupportResource] {
        switch region {
        case .unitedStates:
            return [
                SupportResource(id: "us-988-call", title: "Call or text 988",
                                detail: "Suicide & Crisis Lifeline — free, 24/7",
                                action: .call("988"), isPrimary: true),
                SupportResource(id: "us-741741", title: "Text HOME to 741741",
                                detail: "Crisis Text Line — free, 24/7",
                                action: .text(body: "HOME", to: "741741"), isPrimary: true),
                SupportResource(id: "us-911", title: "Call 911",
                                detail: "If you're in immediate danger",
                                action: .call("911"), isPrimary: false)
            ]
        case .canada:
            return [
                SupportResource(id: "ca-988", title: "Call or text 988",
                                detail: "Suicide Crisis Helpline — free, 24/7",
                                action: .call("988"), isPrimary: true),
                SupportResource(id: "ca-911", title: "Call 911",
                                detail: "If you're in immediate danger",
                                action: .call("911"), isPrimary: false)
            ]
        case .unitedKingdom:
            return [
                SupportResource(id: "uk-116123", title: "Call 116 123",
                                detail: "Samaritans — free, 24/7",
                                action: .call("116123"), isPrimary: true),
                SupportResource(id: "uk-shout", title: "Text SHOUT to 85258",
                                detail: "Shout Crisis Text Line — free, 24/7",
                                action: .text(body: "SHOUT", to: "85258"), isPrimary: true),
                SupportResource(id: "uk-999", title: "Call 999",
                                detail: "If you're in immediate danger",
                                action: .call("999"), isPrimary: false)
            ]
        case .ireland:
            return [
                SupportResource(id: "ie-116123", title: "Call 116 123",
                                detail: "Samaritans Ireland — free, 24/7",
                                action: .call("116123"), isPrimary: true),
                SupportResource(id: "ie-hello", title: "Text HELLO to 50808",
                                detail: "Text About It — free, 24/7",
                                action: .text(body: "HELLO", to: "50808"), isPrimary: true),
                SupportResource(id: "ie-112", title: "Call 112",
                                detail: "If you're in immediate danger",
                                action: .call("112"), isPrimary: false)
            ]
        case .australia:
            return [
                SupportResource(id: "au-lifeline", title: "Call 13 11 14",
                                detail: "Lifeline Australia — free, 24/7",
                                action: .call("131114"), isPrimary: true),
                SupportResource(id: "au-kids", title: "Call 1800 55 1800",
                                detail: "Kids Helpline — for ages 5–25, 24/7",
                                action: .call("1800551800"), isPrimary: true),
                SupportResource(id: "au-000", title: "Call 000",
                                detail: "If you're in immediate danger",
                                action: .call("000"), isPrimary: false)
            ]
        case .newZealand:
            return [
                SupportResource(id: "nz-1737", title: "Call or text 1737",
                                detail: "Need to Talk? — free, 24/7",
                                action: .call("1737"), isPrimary: true),
                SupportResource(id: "nz-111", title: "Call 111",
                                detail: "If you're in immediate danger",
                                action: .call("111"), isPrimary: false)
            ]
        case .india:
            return [
                SupportResource(id: "in-tele", title: "Call 14416",
                                detail: "Tele-MANAS — free, 24/7",
                                action: .call("14416"), isPrimary: true),
                SupportResource(id: "in-kiran", title: "Call 1800-599-0019",
                                detail: "KIRAN Mental Health Helpline — free, 24/7",
                                action: .call("18005990019"), isPrimary: true),
                SupportResource(id: "in-112", title: "Call 112",
                                detail: "If you're in immediate danger",
                                action: .call("112"), isPrimary: false)
            ]
        case .international:
            return [
                SupportResource(id: "int-find", title: "Find a helpline near you",
                                detail: "findahelpline.com — free lines by country",
                                action: .web("https://findahelpline.com"), isPrimary: true),
                SupportResource(id: "int-emergency", title: "Call your local emergency number",
                                detail: "If you're in immediate danger",
                                action: .info, isPrimary: false)
            ]
        }
    }
}

// MARK: - Text normalisation

/// Folds the many ways a sentence can be written down into one canonical form
/// before matching. This is what lets the phrase list stay short and readable.
enum SafetyTextNormalizer {

    /// Obfuscated spellings, repaired *before* punctuation is stripped —
    /// otherwise "k!ll" becomes "k ll" and slips through. These substitutions
    /// exist specifically because the spellings exist to dodge filters.
    private static let obfuscations: [(String, String)] = [
        ("k!ll", "kill"), ("k1ll", "kill"), ("ki11", "kill"), ("k*ll", "kill"),
        ("su1c1de", "suicide"), ("suicid3", "suicide"), ("su!c!de", "suicide"),
        ("s3lf", "self"), ("d!e", "die"), ("d1e", "die")
    ]

    /// Intensifiers and filler that students drop between the subject and the
    /// verb. Removing them is what lets the phrase list stay short: without
    /// this, "I just want to die" and "I really want to die" would each need
    /// their own entry, forever.
    private static let fillers: [String] = [
        "just", "really", "so", "such", "very", "honestly", "literally",
        "actually", "kinda", "sorta", "legit", "lowkey", "seriously", "totally",
        "basically", "genuinely", "truly", "definitely", "absolutely", "simply",
        "kind of", "sort of", "like"
    ]

    /// Contractions and shorthand students actually type. Expanded so the
    /// phrase list can be written in plain English.
    private static let substitutions: [(String, String)] = [
        // Contractions
        ("i'm", "i am"), ("im", "i am"), ("i’m", "i am"),
        ("i've", "i have"), ("i’ve", "i have"), ("ive", "i have"),
        ("i'd", "i would"), ("i’d", "i would"),
        ("i'll", "i will"), ("i’ll", "i will"),
        ("don't", "do not"), ("don’t", "do not"), ("dont", "do not"),
        ("can't", "cannot"), ("can’t", "cannot"), ("cant", "cannot"),
        ("won't", "will not"), ("won’t", "will not"), ("wont", "will not"),
        ("doesn't", "does not"), ("doesn’t", "does not"),
        ("isn't", "is not"), ("isn’t", "is not"),
        ("there's", "there is"), ("there’s", "there is"),
        ("what's", "what is"), ("what’s", "what is"),
        ("nobody's", "nobody is"), ("nobody’s", "nobody is"),
        ("everyone's", "everyone is"), ("everyone’s", "everyone is"),
        // "suicidal" → "suicide" so one phrase entry covers both forms.
        ("suicidal", "suicide"),
        ("self harm", "selfharm"),

        // Compounds a speech recogniser may split. Transcribed speech is not
        // typed text: "anymore" comes back as "any more", "myself" as "my self".
        // Each of these is a hole in the net if left unhandled.
        ("any more", "anymore"),
        ("my self", "myself"),
        ("no body", "nobody"),
        ("some one", "someone"),
        ("no one", "nobody"),
        ("every one", "everyone"),
        ("no where", "nowhere"),
        ("wanna", "want to"), ("gonna", "going to"), ("gotta", "got to"),
        ("wanto", "want to"),
        ("myslef", "myself"), ("mysef", "myself")
    ]

    /// Lowercase, repair obfuscation, strip punctuation and emoji, expand
    /// shorthand, drop filler words, collapse whitespace.
    ///
    /// The result is padded with spaces at both ends so callers can match whole
    /// words with `" phrase "` and never hit a substring inside another word —
    /// that's what stops "kms" firing inside "skims" and "im" rewriting the
    /// middle of "important".
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()

        // 1. Repair obfuscated spellings BEFORE punctuation is stripped, or
        //    "k!ll" would become "k ll" and never match anything.
        for (from, to) in obfuscations {
            s = s.replacingOccurrences(of: from, with: to)
        }

        // 2. Replace anything that isn't a letter, digit, apostrophe or space
        //    with a space. Kills punctuation and emoji in one pass and prevents
        //    "kill.myself" from sliding past a space-delimited match.
        s = String(s.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" { return ch }
            return " "
        })

        s = collapse(s)

        // 3. Expand contractions and shorthand on word boundaries.
        for (from, to) in substitutions {
            s = s.replacingOccurrences(of: " \(from) ", with: " \(to) ")
        }
        s = collapse(s)

        // 4. Drop filler and intensifiers so "I just really want to die"
        //    reduces to "i want to die". Two passes handles adjacent fillers.
        for _ in 0..<2 {
            for filler in fillers {
                s = s.replacingOccurrences(of: " \(filler) ", with: " ")
            }
            s = collapse(s)
        }

        return s
    }

    /// Collapse whitespace runs and re-pad with a single leading/trailing space.
    private static func collapse(_ s: String) -> String {
        " " + s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") + " "
    }
}

// MARK: - The service

/// Evaluates text for crisis signals. Stateless and cheap — safe to call on
/// every keystroke-committed field and every voice transcript.
struct CrisisSafetyService: Sendable {

    // MARK: Phrase lists
    //
    // Each entry is matched against the normalised, space-padded text. Because
    // every phrase below is written in the first person, ordinary study
    // material ("Macbeth kills Duncan", "cell death", "the suicide of Romeo")
    // does not match. That single structural choice replaces a long and
    // permanently incomplete list of academic exceptions.

    /// Explicit first-person statements of intent or ideation. → `.crisis`
    private static let crisisPhrases: [(String, CrisisCategory)] = [
        // Intent
        ("i want to kill myself", .suicidalIntent),
        ("i want to die", .suicidalIntent),
        ("i am going to kill myself", .suicidalIntent),
        ("i am going to end it", .suicidalIntent),
        ("i am going to end my life", .suicidalIntent),
        ("i will kill myself", .suicidalIntent),
        ("i am killing myself", .suicidalIntent),
        ("i am ending my life", .suicidalIntent),
        ("i want to end my life", .suicidalIntent),
        ("i want to end it all", .suicidalIntent),
        ("i want to end things", .suicidalIntent),
        ("i want to commit suicide", .suicidalIntent),
        ("i am thinking about suicide", .suicidalIntent),
        ("i have been thinking about suicide", .suicidalIntent),
        ("i am suicide", .suicidalIntent),           // from "i'm suicidal"
        ("i feel suicide", .suicidalIntent),         // from "i feel suicidal"
        ("i have a plan to kill myself", .suicidalIntent),
        ("i am about to kill myself", .suicidalIntent),
        ("i do not want to wake up", .suicidalIdeation),
        ("i hope i do not wake up", .suicidalIdeation),

        // Ideation
        ("i wish i was dead", .suicidalIdeation),
        ("i wish i were dead", .suicidalIdeation),
        ("i wish i was never born", .suicidalIdeation),
        ("i wish i could die", .suicidalIdeation),
        ("i wish i would die", .suicidalIdeation),
        ("i do not want to be here anymore", .suicidalIdeation),
        ("i do not want to be alive", .suicidalIdeation),
        ("i do not want to live", .suicidalIdeation),
        ("i cannot do this anymore", .suicidalIdeation),
        ("i cannot go on", .suicidalIdeation),
        ("i cannot keep going", .suicidalIdeation),
        ("i am better off dead", .suicidalIdeation),
        ("i want to disappear forever", .suicidalIdeation),
        ("i am done with life", .suicidalIdeation),
        ("i am tired of living", .suicidalIdeation),
        ("i am tired of being alive", .suicidalIdeation),
        ("everyone would be better off without me", .suicidalIdeation),
        ("they would be better off without me", .suicidalIdeation),
        ("my family would be better off without me", .suicidalIdeation),
        ("nobody would miss me", .suicidalIdeation),
        ("no one would miss me", .suicidalIdeation),

        // Self-harm
        ("i want to hurt myself", .selfHarm),
        ("i am going to hurt myself", .selfHarm),
        ("i hurt myself", .selfHarm),
        ("i have been hurting myself", .selfHarm),
        ("i want to cut myself", .selfHarm),
        ("i cut myself", .selfHarm),
        ("i have been cutting myself", .selfHarm),
        ("i have been cutting", .selfHarm),
        ("i selfharm", .selfHarm),
        ("i have been selfharming", .selfHarm),
        ("i want to selfharm", .selfHarm),
        ("i am going to overdose", .selfHarm),
        ("i took a bunch of pills", .selfHarm)
    ]

    /// Distress without an explicit self-harm statement. → `.concern`
    /// These are also what Part 4's comfort mode listens for.
    private static let concernPhrases: [(String, CrisisCategory)] = [
        // NOTE: these are written filler-free ("i am alone", not "i am so
        // alone") because the normaliser strips intensifiers before matching.
        ("i hate myself", .worthlessness),
        ("i am worthless", .worthlessness),
        ("i am a failure", .worthlessness),
        ("i am stupid", .worthlessness),
        ("i am useless", .worthlessness),
        ("i cannot do anything right", .worthlessness),
        ("i ruin everything", .worthlessness),
        ("i am a burden", .worthlessness),
        ("nobody cares about me", .worthlessness),
        ("no one cares about me", .worthlessness),
        ("nobody likes me", .worthlessness),
        ("i have no friends", .worthlessness),
        ("i am all alone", .worthlessness),
        ("i am alone", .worthlessness),
        ("i feel alone", .worthlessness),
        ("i feel lonely", .worthlessness),

        ("what is the point", .hopelessness),
        ("what is the point of anything", .hopelessness),
        ("there is no point", .hopelessness),
        ("nothing matters", .hopelessness),
        ("nothing will ever get better", .hopelessness),
        ("it is never going to get better", .hopelessness),
        ("i give up on everything", .hopelessness),
        ("i feel empty", .hopelessness),
        ("i feel hopeless", .hopelessness),
        ("i am depressed", .hopelessness),
        ("i cannot stop crying", .hopelessness),
        ("i have been crying all day", .hopelessness)
    ]

    /// Everyday exaggeration. These *are* how teenagers talk about a hard
    /// worksheet — but they are also, sometimes, how a real one starts. We land
    /// on `.concern`: one warm sentence and a soft offer, never the full
    /// interrupt. See DECISIONS.md.
    private static let hyperbolePhrases: [String] = [
        "this homework is killing me",
        "this test is killing me",
        "this class is killing me",
        "this is killing me",
        "kill me now",
        "just kill me",
        "i am dying",
        "i am dead",
        "i want to throw myself out a window",
        "shoot me now"
    ]

    /// Coded terms that exist almost solely to talk about one's own suicidality
    /// while dodging content filters. They carry no realistic academic meaning,
    /// so unlike everything above they don't need a first-person frame — the
    /// word itself is the disclosure.
    ///
    /// `guardedByNumber` marks terms with a legitimate homograph: "kms" is also
    /// how a physics worksheet writes kilometres, so we ignore it when the
    /// preceding token is a number.
    private static let codedDisclosures: [(term: String, category: CrisisCategory, guardedByNumber: Bool)] = [
        ("kms", .suicidalIntent, true),
        ("sewerslide", .suicidalIdeation, false),
        ("unalive myself", .suicidalIntent, false),
        ("unalive my self", .suicidalIntent, false)
    ]

    /// Phrases that must *not* escalate even though they contain crisis words.
    /// Kept deliberately tiny — the first-person rule does the heavy lifting,
    /// and every entry here is a small hole in the net.
    private static let deEscalators: [String] = [
        "i do not want to die",
        "i do not want to kill myself",
        "i am not suicide",           // from "i'm not suicidal"
        "i do not want to hurt myself",
        "i would never kill myself",
        "i used to want to die but"
    ]

    init() {}

    /// The single entry point. Everything that accepts free text or a voice
    /// transcript calls this before doing anything else with the content.
    func evaluate(_ raw: String) -> CrisisSignal {
        let text = SafetyTextNormalizer.normalize(raw)
        guard text.count > 2 else { return .clear }

        // 1. De-escalators win outright. "I don't want to die" contains
        //    "i want to die" as a substring, so this check must come first.
        for phrase in Self.deEscalators where text.contains(" \(phrase) ") || text.contains(" \(phrase)") {
            return CrisisSignal(severity: .concern, category: .hopelessness, matches: [phrase])
        }

        // 2. Coded terms — checked before the phrase list because they don't
        //    follow its first-person shape.
        for coded in Self.codedDisclosures where text.contains(" \(coded.term) ") {
            if coded.guardedByNumber, isPrecededByNumber(coded.term, in: text) { continue }
            return CrisisSignal(severity: .crisis, category: coded.category, matches: [coded.term])
        }

        // 3. Explicit crisis language.
        var crisisMatches: [String] = []
        var crisisCategory: CrisisCategory = .none
        for (phrase, category) in Self.crisisPhrases where text.contains(" \(phrase) ") {
            crisisMatches.append(phrase)
            // Keep the most specific category we saw: intent outranks ideation.
            if crisisCategory == .none || category == .suicidalIntent {
                crisisCategory = category
            }
        }
        if !crisisMatches.isEmpty {
            return CrisisSignal(severity: .crisis, category: crisisCategory, matches: crisisMatches)
        }

        // 4. Hyperbole — checked before generic distress so "this is killing
        //    me" is categorised as what it usually is.
        for phrase in Self.hyperbolePhrases where text.contains(" \(phrase) ") {
            return CrisisSignal(severity: .concern, category: .hyperbole, matches: [phrase])
        }

        // 5. Distress.
        var concernMatches: [String] = []
        var concernCategory: CrisisCategory = .none
        for (phrase, category) in Self.concernPhrases where text.contains(" \(phrase) ") {
            concernMatches.append(phrase)
            if concernCategory == .none { concernCategory = category }
        }
        if !concernMatches.isEmpty {
            return CrisisSignal(severity: .concern, category: concernCategory, matches: concernMatches)
        }

        return .clear
    }

    /// True when every occurrence of `term` in `text` follows a number —
    /// "50 kms" is a distance, not a disclosure. If even one occurrence is
    /// unguarded we treat the whole message as a disclosure, because recall
    /// matters more than tidiness here.
    private func isPrecededByNumber(_ term: String, in text: String) -> Bool {
        let tokens = text.split(separator: " ").map(String.init)
        var sawUnguarded = false
        for (index, token) in tokens.enumerated() where token == term {
            let previous = index > 0 ? tokens[index - 1] : ""
            let previousIsNumber = !previous.isEmpty && previous.allSatisfy(\.isNumber)
            if !previousIsNumber { sawUnguarded = true }
        }
        return !sawUnguarded
    }
}

// MARK: - What Ace says

/// The words Ace uses when the net catches something.
///
/// Rules baked into this copy, from §10:
///   • warmth, zero judgement, no minimising
///   • no therapist role-play and no diagnosis
///   • no promises of confidentiality
///   • encourage a trusted person and real services
///   • no steering back to studying until the student says they're okay
struct CrisisResponse: Sendable, Equatable {
    var headline: String
    var body: String
    var resources: [SupportResource]
    /// Copy for the button that returns to the app. Deliberately low-key.
    var dismissTitle: String
    /// True when the UI must suppress XP, streaks, quizzes and celebration.
    var suppressGamification: Bool
    /// True when the UI must take over the screen rather than show an inline note.
    var requiresFullScreen: Bool

    static func == (lhs: CrisisResponse, rhs: CrisisResponse) -> Bool {
        lhs.headline == rhs.headline && lhs.body == rhs.body
            && lhs.resources == rhs.resources
            && lhs.suppressGamification == rhs.suppressGamification
            && lhs.requiresFullScreen == rhs.requiresFullScreen
    }
}

enum CrisisResponder {

    static func response(for signal: CrisisSignal,
                         region: SupportRegion,
                         studentName: String? = nil) -> CrisisResponse? {
        switch signal.severity {
        case .none:
            return nil

        case .concern:
            return concernResponse(for: signal, region: region, name: studentName)

        case .crisis:
            let name = firstName(studentName)
            return CrisisResponse(
                headline: name.isEmpty ? "I'm really glad you told me." : "\(name), I'm really glad you told me.",
                body: """
                    I hear you, and I'm not going anywhere. What you're feeling sounds \
                    incredibly heavy, and you shouldn't have to carry it on your own.

                    I'm an app, so I'm not the right kind of help for this — but there are \
                    people who are, right now, and reaching them is free.

                    Please talk to someone tonight: one of the lines below, or a person \
                    you trust — a parent, a relative, a teacher, a counsellor, a friend's \
                    parent. Anyone. If you're in danger right now, call your local \
                    emergency number.

                    Studying can wait. You matter more than any of this.
                    """,
                resources: SupportDirectory.resources(for: region),
                dismissTitle: "I'm safe right now",
                suppressGamification: true,
                requiresFullScreen: true
            )
        }
    }

    private static func concernResponse(for signal: CrisisSignal,
                                        region: SupportRegion,
                                        name: String?) -> CrisisResponse {
        let first = firstName(name)
        switch signal.category {
        case .hyperbole:
            return CrisisResponse(
                headline: first.isEmpty ? "Okay, that sounds rough." : "Okay \(first), that sounds rough.",
                body: """
                    Hard sections do that. We can slow this right down and take one \
                    small piece at a time — or take five minutes and come back.

                    And if it's more than the homework, I'm here for that too.
                    """,
                resources: [],
                dismissTitle: "Keep going",
                suppressGamification: true,
                requiresFullScreen: false
            )

        case .worthlessness:
            return CrisisResponse(
                headline: "Hey — I want to stop on that.",
                body: """
                    That's a really painful thing to be carrying, and I don't think it's \
                    true about you. Being stuck on a page says nothing about who you are.

                    Is there someone you can talk to today — someone at home, a teacher, \
                    a friend? Talking to a real person helps in a way an app can't.

                    We can pick the work back up whenever you want. No rush, no streak to \
                    protect.
                    """,
                resources: SupportDirectory.resources(for: region).filter(\.isPrimary),
                dismissTitle: "I'm okay",
                suppressGamification: true,
                requiresFullScreen: false
            )

        case .hopelessness:
            return CrisisResponse(
                headline: "That sounds like a lot right now.",
                body: """
                    I'm glad you said it out loud. You don't have to have a reason or an \
                    explanation for feeling that way.

                    If it's been sitting on you for a while, please tell someone you \
                    trust — or one of the free lines below. They're good at exactly this, \
                    any time of day.

                    Nothing here is more important than you being alright.
                    """,
                resources: SupportDirectory.resources(for: region).filter(\.isPrimary),
                dismissTitle: "I'm okay",
                suppressGamification: true,
                requiresFullScreen: false
            )

        default:
            return CrisisResponse(
                headline: "I'm here.",
                body: """
                    However today's going, you don't have to push through it alone. If you \
                    want to talk to a real person, the lines below are free and open now.
                    """,
                resources: SupportDirectory.resources(for: region).filter(\.isPrimary),
                dismissTitle: "I'm okay",
                suppressGamification: true,
                requiresFullScreen: false
            )
        }
    }

    private static func firstName(_ name: String?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ""
        }
        return String(name.split(separator: " ").first ?? "")
    }
}
