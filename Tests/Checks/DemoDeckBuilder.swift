//
//  DemoDeckBuilder.swift
//  Ace — developer tooling
//
//  Builds the two decks that ship with the app.
//
//  Run:  swift run AceVerify --make-demo-decks
//
//  The decks are produced by the *real* `StudyMaterialGenerator`, not written by
//  hand. Two reasons:
//    • What a new user sees on first launch is exactly what they'll get from
//      their own photographed page. No bait and switch.
//    • It's a standing end-to-end test of the generator on realistic material —
//      if the generator regresses, the demo decks visibly rot.
//

import Foundation

enum DemoDeckBuilder {

    // MARK: - Source material

    /// A 5th-grade science passage, in the register a worksheet actually uses.
    static let photosynthesisText = """
    Photosynthesis is the process that plants use to make their own food. \
    Plants do not eat like animals do. Instead, they build their own sugar \
    using light, water, and air.

    Chlorophyll is the green pigment inside a leaf that captures energy from \
    sunlight. It is the reason most leaves look green. The chloroplast is the \
    tiny part of a plant cell where photosynthesis happens. A single leaf cell \
    can hold dozens of chloroplasts.

    Plants pull water up from the soil through their roots. They take in carbon \
    dioxide from the air through small holes on the underside of the leaf. \
    These holes are called stomata. When sunlight hits the chlorophyll, the \
    plant uses that energy to combine the water and the carbon dioxide.

    Glucose is the sugar that the plant makes and stores as food. Oxygen is \
    released back into the air as a leftover product. This is why forests and \
    ocean plants matter so much to the air we breathe.

    Respiration is the opposite process. It is how a cell breaks glucose back \
    down to release the energy stored inside it. Plants and animals both do \
    respiration, but only plants do photosynthesis.
    """

    /// A college-level CS passage — deliberately denser, with the kind of
    /// defined terms an undergraduate lecture handout is full of.
    static let neuralNetworkText = """
    A perceptron is the simplest form of an artificial neuron. It computes a \
    weighted sum of its inputs, adds a bias term, and passes the result through \
    an activation function to produce an output.

    The activation function is the nonlinearity that lets a network represent \
    relationships a straight line cannot. Without it, stacking layers would be \
    pointless: a composition of linear maps is itself a linear map. ReLU is the \
    activation function that returns the input when it is positive and zero \
    otherwise, and it is the default choice in most modern architectures.

    The loss function is the scalar measure of how wrong a prediction is. \
    Training means searching for the weights that minimise it. Gradient descent \
    is the optimisation procedure that repeatedly steps each weight in the \
    direction that most reduces the loss.

    Backpropagation is the algorithm that computes those gradients efficiently \
    by applying the chain rule backwards through the network. It reuses the \
    intermediate values from the forward pass, which is why training a deep \
    network costs roughly twice a forward pass rather than growing with depth \
    squared.

    The learning rate is the hyperparameter that scales each update step. Set it \
    too high and the optimiser overshoots and diverges. Set it too low and \
    training crawls. Overfitting is the failure mode where a model memorises the \
    training set and generalises poorly to data it has not seen.
    """

    // MARK: - Build

    static func build() -> [DemoDeck] {
        let elementary = StudyMaterialGenerator(gradeLevel: .grade5)
        let college = StudyMaterialGenerator(gradeLevel: .college)

        return [
            DemoDeck(
                id: "demo_photosynthesis",
                title: "How Plants Make Food",
                subtitle: "5th grade science · try me first",
                gradeLevel: .grade5,
                subject: Subject.science.storageKey,
                sourceText: photosynthesisText,
                flashcards: elementary.flashcards(from: photosynthesisText,
                                                  title: "How Plants Make Food",
                                                  limit: 10),
                quiz: elementary.quiz(from: photosynthesisText,
                                      title: "How Plants Make Food",
                                      questionCount: 6)
            ),
            DemoDeck(
                id: "demo_neural_networks",
                title: "Neural Networks: The Basics",
                subtitle: "College · intro machine learning",
                gradeLevel: .college,
                subject: Subject.computerScience.storageKey,
                sourceText: neuralNetworkText,
                flashcards: college.flashcards(from: neuralNetworkText,
                                               title: "Neural Networks: The Basics",
                                               limit: 12),
                quiz: college.quiz(from: neuralNetworkText,
                                   title: "Neural Networks: The Basics",
                                   questionCount: 8)
            )
        ]
    }

    /// Write the decks to `Ace/Resources/DemoDecks/` and verify each one
    /// round-trips back through `JSONDecoder`.
    static func writeAll(to directory: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var allGood = true
        for deck in build() {
            let path = "\(directory)/\(deck.id).json"
            do {
                let data = try encoder.encode(deck)

                // Round-trip before writing: a deck that can't be decoded would
                // silently vanish from the app rather than fail loudly.
                let decoded = try JSONDecoder().decode(DemoDeck.self, from: data)
                guard decoded.flashcards.count == deck.flashcards.count,
                      decoded.quiz.questions.count == deck.quiz.questions.count else {
                    print("  ✗ \(deck.id): round-trip lost content")
                    allGood = false
                    continue
                }

                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true
                )
                try data.write(to: URL(fileURLWithPath: path))
                print("  ✓ \(deck.id): \(deck.flashcards.count) cards, \(deck.quiz.questions.count) questions → \(path)")
            } catch {
                print("  ✗ \(deck.id): \(error)")
                allGood = false
            }
        }
        return allGood
    }

    /// Print the generated decks so their quality can be eyeballed rather than
    /// assumed.
    static func dump() {
        for deck in build() {
            print("\n━━━ \(deck.title) (\(deck.gradeLevel.displayName)) ━━━")
            print("\nFLASHCARDS (\(deck.flashcards.count)):")
            for card in deck.flashcards.prefix(6) {
                print("  Q: \(card.front)")
                print("  A: \(card.back)\n")
            }
            print("QUIZ (\(deck.quiz.questions.count) questions):")
            for question in deck.quiz.questions.prefix(4) {
                print("  \(question.prompt)")
                for (index, choice) in question.choices.enumerated() {
                    print("    \(index == question.correctIndex ? "✓" : " ") \(choice)")
                }
                print("    → \(question.explanation)")
                print("    hints: \(question.hints.joined(separator: " | "))\n")
            }
        }
    }
}

// MARK: - Deck sanity checks

enum DemoDeckChecks {
    static let all = CheckSuite(name: "Bundled demo decks") { run in
        let decks = DemoDeckBuilder.build()
        run.expectEqual(decks.count, 2, "two decks ship with the app")

        // One at each end of the age range, as the brief asks for.
        run.expect(decks.contains { $0.gradeLevel.band == .elementary },
                   "need an elementary deck")
        run.expect(decks.contains { $0.gradeLevel.band == .college },
                   "need a college deck")

        for deck in decks {
            let label = deck.id

            run.expect(!deck.title.isEmpty, "\(label): no title")
            run.expect(!deck.subtitle.isEmpty, "\(label): no subtitle")
            run.expect(Subject(storageKey: deck.subject) != nil,
                       "\(label): subject key “\(deck.subject)” doesn't resolve")

            // A demo deck that looks thin is worse than no demo deck.
            run.expect(deck.flashcards.count >= 6,
                       "\(label): only \(deck.flashcards.count) flashcards — too thin to impress")
            run.expect(deck.quiz.questions.count >= 4,
                       "\(label): only \(deck.quiz.questions.count) questions")

            for card in deck.flashcards {
                run.expect(!card.front.isEmpty, "\(label): empty card front")
                run.expect(!card.back.isEmpty, "\(label): empty card back")
                run.expect(card.front.count < 300, "\(label): card front is a wall of text")
                // "What is the chloroplast?" is correct — the generator adds a
                // lowercase article so common nouns read grammatically. What
                // must never appear is a capitalised article dragged in from the
                // source sentence ("What is The chloroplast?"), or a doubled one.
                run.expect(!card.front.hasPrefix("What is The "),
                           "\(label): source article leaked into “\(card.front)”")
                run.expect(!card.front.hasPrefix("What is A "),
                           "\(label): source article leaked into “\(card.front)”")
                run.expect(!card.front.lowercased().contains("the the "),
                           "\(label): doubled article in “\(card.front)”")
                run.expect(!card.front.lowercased().contains("what is the the"),
                           "\(label): doubled article in “\(card.front)”")
            }

            for question in deck.quiz.questions {
                run.expectEqual(question.choices.count, deck.gradeLevel.quizChoiceCount,
                                "\(label): wrong choice count")
                run.expect(question.choices.indices.contains(question.correctIndex),
                           "\(label): correctIndex out of range")
                run.expectEqual(Set(question.choices).count, question.choices.count,
                                "\(label): duplicate choices \(question.choices)")
                run.expect(!question.explanation.isEmpty, "\(label): question with no explanation")
                run.expectEqual(question.hints.count, 3, "\(label): expected 3 hints")

                let answer = question.correctAnswer.lowercased()
                run.expect(!question.prompt.lowercased().contains(answer),
                           "\(label): prompt leaks the answer “\(answer)”")
                run.expect(!question.hints[0].lowercased().contains(answer),
                           "\(label): hint 1 leaks the answer")
            }

            // The whole deck must survive a JSON round trip, because that's how
            // it reaches the app.
            do {
                let data = try JSONEncoder().encode(deck)
                let decoded = try JSONDecoder().decode(DemoDeck.self, from: data)
                run.expectEqual(decoded.flashcards.count, deck.flashcards.count,
                                "\(label): flashcards lost in JSON round-trip")
                run.expectEqual(decoded.quiz.questions.count, deck.quiz.questions.count,
                                "\(label): questions lost in JSON round-trip")
                run.expectEqual(decoded.gradeLevel, deck.gradeLevel,
                                "\(label): grade level lost in JSON round-trip")
                run.expectEqual(decoded.quiz.questions.first?.choices,
                                deck.quiz.questions.first?.choices,
                                "\(label): choice order changed in JSON round-trip")
            } catch {
                run.expect(false, "\(label): JSON round-trip threw — \(error)")
            }
        }
    }
}
