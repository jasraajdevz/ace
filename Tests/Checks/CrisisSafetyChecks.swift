//
//  CrisisSafetyChecks.swift
//  Ace — verification harness
//
//  The most important tests in the project. Two jobs:
//
//    1. Recall — every realistic way a student might disclose must be caught,
//       including shorthand and filter-dodging spellings.
//    2. Precision where it matters — ordinary study material about death,
//       killing, war and tragedy must NOT trigger the crisis screen. A history
//       student reading about the Somme should never get a helpline popup.
//

import Foundation

enum CrisisSafetyChecks {

    // MARK: - Recall: these MUST be caught

    static let detection = CheckSuite(name: "Crisis safety — detection") { run in
        let service = CrisisSafetyService()

        /// Phrases that must reach `.crisis` (full protocol, gamification off).
        let mustBeCrisis = [
            // The exact example from the spec.
            "I want to kill myself",
            "i want to kill myself",
            "I WANT TO KILL MYSELF",
            "i wanna kill myself",
            "I want to kill myself.",
            "honestly i want to kill myself",
            "idk i just want to die",
            "I want to die",
            "i wish i was dead",
            "i wish i were dead honestly",
            "I don't want to be here anymore",
            "i dont want to be here anymore",
            "I'm going to kill myself tonight",
            "im gonna kill myself",
            "i'm suicidal",
            "im suicidal",
            "i feel suicidal",
            "i've been thinking about suicide",
            "ive been thinking about suicide",
            "i want to end my life",
            "i want to end it all",
            "i cant go on",
            "I can't do this anymore",
            "everyone would be better off without me",
            "my family would be better off without me",
            "nobody would miss me",
            "i want to hurt myself",
            "i've been cutting",
            "ive been cutting myself",
            "i want to cut myself",
            "i am better off dead",
            "i'm tired of living",
            "i hope i don't wake up",
            "i wish i could die",
            "i'm done with life",
            // Filter-dodging spellings students actually use.
            "kms",
            "i want to unalive myself",
            "thinking about sewerslide",
            "i want to k!ll myself",
            // Punctuation and emoji must not hide it.
            "i want to kill myself :(",
            "i...want...to...die",
            "i want to die 😭",
        ]

        for phrase in mustBeCrisis {
            let signal = service.evaluate(phrase)
            run.expect(signal.severity == .crisis,
                       "MISSED CRISIS: “\(phrase)” → \(signal.severity) / \(signal.category)")
        }

        // Distress that should register as concern (warm response, no hype),
        // but not the full crisis interrupt.
        let mustBeConcern = [
            "i hate myself",
            "i'm worthless",
            "im so stupid",
            "i'm such a failure",
            "nobody cares about me",
            "what's the point",
            "nothing matters anymore",
            "i feel so alone",
            "i feel hopeless",
            "i'm so depressed",
            "i can't stop crying",
            "i'm a burden to everyone",
            // Hyperbole — real students say this constantly about homework.
            "this homework is killing me",
            "ugh this test is killing me",
            "kill me now lol",
            "i'm dying",
        ]

        for phrase in mustBeConcern {
            let signal = service.evaluate(phrase)
            run.expect(signal.severity == .concern,
                       "WRONG SEVERITY: “\(phrase)” → \(signal.severity) (wanted .concern)")
        }

        // De-escalators must not escalate.
        let mustNotBeCrisis = [
            "i don't want to die",
            "i'm not suicidal",
            "i would never kill myself",
        ]
        for phrase in mustNotBeCrisis {
            let signal = service.evaluate(phrase)
            run.expect(signal.severity != .crisis,
                       "OVER-ESCALATED: “\(phrase)” → \(signal.severity)")
        }

        // Gamification must be suppressed for anything at or above concern.
        run.expect(service.evaluate("i want to kill myself").suppressesGamification,
                   "crisis must suppress gamification")
        run.expect(service.evaluate("i hate myself").suppressesGamification,
                   "concern must suppress gamification")
        run.expect(!service.evaluate("what is photosynthesis").suppressesGamification,
                   "normal text must not suppress gamification")

        // Category is used for wording — check the obvious ones.
        run.expectEqual(service.evaluate("i'm going to kill myself").category, .suicidalIntent,
                        "intent category")
        run.expectEqual(service.evaluate("i've been cutting myself").category, .selfHarm,
                        "self-harm category")
        run.expectEqual(service.evaluate("this homework is killing me").category, .hyperbole,
                        "hyperbole category")
    }

    // MARK: - Precision: study material MUST NOT trigger

    static let falsePositives = CheckSuite(name: "Crisis safety — no false alarms on schoolwork") { run in
        let service = CrisisSafetyService()

        /// Real sentences from real coursework. Every one contains crisis
        /// vocabulary; none is a disclosure. If any of these fire, a student
        /// gets a helpline screen in the middle of a history essay.
        let schoolwork = [
            // Literature
            "Macbeth kills Duncan in Act 2.",
            "Romeo and Juliet both die at the end of the play.",
            "Ophelia's death is often read as a suicide.",
            "The theme of suicide runs through Hamlet's soliloquy.",
            "To be or not to be, that is the question.",
            "Why does Juliet want to die rather than marry Paris?",
            "Analyse how Shakespeare presents death in Act 5.",
            "The narrator says he wishes he were dead — is this reliable?",
            // History
            "Over 19,000 British soldiers died on the first day of the Somme.",
            "The Black Death killed a third of Europe.",
            "Kamikaze pilots were expected to die in the attack.",
            "Explain the causes of the mass killing during the Rwandan genocide.",
            // Science
            "Apoptosis is programmed cell death.",
            "The cells die off during metamorphosis.",
            "White blood cells kill invading bacteria.",
            "What kills the bacteria in pasteurisation?",
            "The reaction kills the enzyme by denaturing it.",
            // Maths / general
            "Solve for the half-life of the isotope.",
            "The population dies out when r is less than one.",
            "I need to finish chapter 4 before the test on Friday.",
            "Studying photosynthesis, test Friday",
            "Can you quiz me on the periodic table?",
            "What is the mitochondria?",
            "I don't understand question 7.",
            "This chapter is really hard.",
            "I got that one wrong again.",
            "I'm so tired.",
            "I'm bored.",
            "I hate this subject.",           // hating a subject ≠ hating oneself
            "I hate maths so much",
            "my teacher is killing me with homework",  // hyperbole-ish, fine either way
        ]

        for sentence in schoolwork {
            let signal = service.evaluate(sentence)
            run.expect(signal.severity != .crisis,
                       "FALSE ALARM on schoolwork: “\(sentence)” → \(signal.severity) (\(signal.matches))")
        }

        // A tighter subset that must be completely clear — not even `.concern`,
        // because a warm interruption mid-quiz is still an interruption.
        let mustBeSilent = [
            "Macbeth kills Duncan in Act 2.",
            "Apoptosis is programmed cell death.",
            "Over 19,000 British soldiers died on the first day of the Somme.",
            "What is photosynthesis?",
            "I don't understand question 7.",
            "I need to finish chapter 4 before the test on Friday.",
            "Can you quiz me on the periodic table?",
            "I hate this subject.",
        ]
        for sentence in mustBeSilent {
            let signal = service.evaluate(sentence)
            run.expectEqual(signal.severity, .none, "should be silent: “\(sentence)”")
        }

        // Empty and junk input must not crash or fire.
        run.expectEqual(service.evaluate("").severity, .none, "empty string")
        run.expectEqual(service.evaluate("   ").severity, .none, "whitespace only")
        run.expectEqual(service.evaluate("😀😀😀").severity, .none, "emoji only")
        run.expectEqual(service.evaluate("a").severity, .none, "single char")

        // --- Adversarial cases against the normaliser itself ---
        // Filler-stripping is powerful, so it gets its own hostile tests.

        // Stacked filler must still reduce to a match.
        for phrase in ["i just really want to die",
                       "i honestly literally want to kill myself",
                       "i kinda just want to disappear forever",
                       "i seriously do not want to be here anymore"] {
            run.expectEqual(service.evaluate(phrase).severity, .crisis,
                            "stacked filler defeated detection: “\(phrase)”")
        }

        // Filler-stripping must not manufacture a match out of a negation.
        for phrase in ["i am not alone in thinking that",
                       "i do not feel alone anymore",
                       "i never want to die"] {
            run.expect(service.evaluate(phrase).severity != .crisis,
                       "negation was stripped into a false positive: “\(phrase)”")
        }

        // "kms" as kilometres in a physics problem must stay silent.
        for phrase in ["the car travelled 50 kms in an hour",
                       "convert 12 kms to metres",
                       "Skims the surface of the topic"] {
            run.expectEqual(service.evaluate(phrase).severity, .none,
                            "kilometre false positive: “\(phrase)”")
        }
        // ...but an unguarded use is still a disclosure, even alongside a number.
        run.expectEqual(service.evaluate("i got 50 on the test kms").severity, .crisis,
                        "unguarded kms must still fire")

        // Obfuscation repair must survive punctuation stripping.
        for phrase in ["i want to k1ll myself", "i want to ki11 myself", "i am su1c1de"] {
            run.expectEqual(service.evaluate(phrase).severity, .crisis,
                            "obfuscated spelling missed: “\(phrase)”")
        }

        // Case and spacing chaos.
        run.expectEqual(service.evaluate("I   WANT    to KILL   myself").severity, .crisis,
                        "whitespace and case chaos")
        run.expectEqual(service.evaluate("i wanna kill myself!!!!!").severity, .crisis,
                        "trailing punctuation")

        // Word-boundary safety: shorthand expansion must not corrupt real words.
        run.expectEqual(service.evaluate("This is important information.").severity, .none,
                        "'im' inside 'important' must not expand")
        run.expectEqual(service.evaluate("The kilns fire at 1200 degrees.").severity, .none,
                        "'kil' inside 'kilns'")
        run.expectEqual(service.evaluate("Skims the surface of the topic").severity, .none,
                        "'kms' inside 'skims'")
    }

    // MARK: - Response content

    static let responses = CheckSuite(name: "Crisis safety — response content") { run in
        let service = CrisisSafetyService()
        let signal = service.evaluate("i want to kill myself")

        guard let response = CrisisResponder.response(for: signal, region: .unitedStates,
                                                      studentName: "Jordan Lee") else {
            run.expect(false, "crisis signal produced no response")
            return
        }

        run.expect(response.suppressGamification, "crisis response must suppress gamification")
        run.expect(response.requiresFullScreen, "crisis response must take over the screen")
        run.expect(response.headline.contains("Jordan"), "should use the student's first name")
        run.expect(!response.headline.contains("Lee"), "should use first name only")

        let body = response.body.lowercased()

        // Required behaviours from §10.
        run.expect(body.contains("trust") || body.contains("parent") || body.contains("teacher"),
                   "must encourage a trusted person")
        run.expect(body.contains("emergency"), "must mention emergency services")
        run.expect(body.contains("wait"), "must explicitly deprioritise studying")

        // Forbidden behaviours from §10.
        let forbidden: [(String, String)] = [
            ("as your therapist", "no therapist role-play"),
            ("i'm your therapist", "no therapist role-play"),
            ("this stays between us", "no confidentiality promises"),
            ("i won't tell", "no confidentiality promises"),
            ("secret", "no confidentiality promises"),
            ("it's not that bad", "no minimising"),
            ("cheer up", "no minimising"),
            ("others have it worse", "no minimising"),
            ("you're overreacting", "no minimising"),
            ("streak", "no gamification in a crisis response"),
            ("xp", "no gamification in a crisis response"),
        ]
        for (phrase, why) in forbidden {
            run.expect(!body.contains(phrase), "\(why): found “\(phrase)”")
        }

        // The US resources required by the spec must be present and tappable.
        let ids = response.resources.map(\.id)
        run.expect(ids.contains("us-988-call"), "must offer 988")
        run.expect(ids.contains("us-741741"), "must offer Crisis Text Line 741741")

        let call988 = response.resources.first { $0.id == "us-988-call" }
        run.expectEqual(call988?.action, .call("988"), "988 must be a tel: action")
        run.expect(call988?.title.contains("988") == true, "988 must appear in the title")

        let text741 = response.resources.first { $0.id == "us-741741" }
        run.expectEqual(text741?.action, .text(body: "HOME", to: "741741"),
                        "Crisis Text Line must send HOME to 741741")
        run.expect(text741?.title.uppercased().contains("HOME") == true,
                   "must tell the student to text HOME")

        // No name supplied → no dangling punctuation or empty greeting.
        let anonymous = CrisisResponder.response(for: signal, region: .unitedStates, studentName: nil)
        run.expect(anonymous?.headline.hasPrefix(",") == false, "no leading comma without a name")
        run.expect(anonymous?.headline.isEmpty == false, "headline must never be empty")
        let blankName = CrisisResponder.response(for: signal, region: .unitedStates, studentName: "   ")
        run.expect(blankName?.headline.contains("  ") == false, "whitespace name must not leave a gap")

        // Concern responses stay inline and gentle.
        let concern = service.evaluate("i hate myself")
        guard let concernResponse = CrisisResponder.response(for: concern, region: .unitedStates) else {
            run.expect(false, "concern signal produced no response")
            return
        }
        run.expect(!concernResponse.requiresFullScreen, "concern must not hijack the screen")
        run.expect(concernResponse.suppressGamification, "concern must still mute hype")
        run.expect(!concernResponse.resources.isEmpty, "concern should still offer a line")

        // Hyperbole gets a light touch and no helpline list.
        let hyperbole = service.evaluate("this homework is killing me")
        let hyperboleResponse = CrisisResponder.response(for: hyperbole, region: .unitedStates)
        run.expect(hyperboleResponse?.resources.isEmpty == true,
                   "hyperbole must not show a helpline list")
        run.expect(hyperboleResponse?.requiresFullScreen == false,
                   "hyperbole must not hijack the screen")

        // Clear text produces no response at all.
        run.expect(CrisisResponder.response(for: .clear, region: .unitedStates) == nil,
                   "clear signal must produce no response")
    }

    // MARK: - Regions

    static let regions = CheckSuite(name: "Crisis safety — regional resources") { run in
        // Every region must offer at least one primary, reachable resource.
        for region in SupportRegion.allCases {
            let resources = SupportDirectory.resources(for: region)
            run.expect(!resources.isEmpty, "\(region.rawValue) has no resources")
            run.expect(resources.contains { $0.isPrimary },
                       "\(region.rawValue) has no primary resource")
            for resource in resources {
                run.expect(!resource.title.isEmpty, "\(region.rawValue): empty title")
                run.expect(!resource.detail.isEmpty, "\(region.rawValue) \(resource.id): empty detail")
                // Phone numbers must be dialable — digits only, no spaces.
                if case .call(let number) = resource.action {
                    run.expect(number.allSatisfy(\.isNumber),
                               "\(region.rawValue) \(resource.id): “\(number)” is not dialable")
                }
            }
            // IDs unique within a region.
            let ids = resources.map(\.id)
            run.expectEqual(Set(ids).count, ids.count, "\(region.rawValue): duplicate resource ids")
        }

        // Device-region mapping, including the fallback.
        run.expectEqual(SupportRegion.fromDeviceRegion("US"), .unitedStates, "US mapping")
        run.expectEqual(SupportRegion.fromDeviceRegion("gb"), .unitedKingdom, "lowercase mapping")
        run.expectEqual(SupportRegion.fromDeviceRegion("JP"), .international,
                        "unknown region falls back to international, never a wrong number")
        run.expectEqual(SupportRegion.fromDeviceRegion(nil), .unitedStates, "nil defaults to US")

        // The international fallback must point somewhere real.
        let intl = SupportDirectory.resources(for: .international)
        run.expect(intl.contains { if case .web(let url) = $0.action { return url.hasPrefix("https://") } else { return false } },
                   "international must offer an https directory link")
    }
}
