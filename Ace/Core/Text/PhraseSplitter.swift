//
//  PhraseSplitter.swift
//  Ace
//
//  Splits text into speakable phrases.
//
//  This is the single most effective trick for making system text-to-speech not
//  sound like a screen reader. `AVSpeechSynthesizer` reads a whole paragraph in
//  one flat breath; feeding it one phrase per utterance, with small pauses
//  between them, produces something that sounds like a person thinking.
//
//  It does double duty: the same splitter drives the streaming tutor reply, so
//  text arrives in the UI at the same rhythm the voice speaks it.
//

import Foundation

enum PhraseSplitter {

    /// Below this many words, a comma is not worth pausing on — otherwise we
    /// machine-gun through lists like "red, green, blue".
    private static let minimumWordsBeforeClauseBreak = 6
    /// A phrase longer than this is a wall of sound even if it has no
    /// punctuation, so it's broken at a word boundary.
    private static let maximumWordsPerPhrase = 26
    private static let wordsPerForcedChunk = 20

    /// Break text at sentence and clause boundaries.
    static func phrases(in text: String) -> [String] {
        var out: [String] = []
        var current = ""

        for character in text {
            current.append(character)

            let isSentenceEnd = character == "." || character == "!" || character == "?"
            let isClauseEnd = (character == "," || character == ";" || character == ":")
                && current.split(separator: " ").count >= minimumWordsBeforeClauseBreak

            if isSentenceEnd || isClauseEnd {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }

        return out.flatMap(chunkIfTooLong)
    }

    private static func chunkIfTooLong(_ phrase: String) -> [String] {
        let words = phrase.split(separator: " ")
        guard words.count > maximumWordsPerPhrase else { return [phrase] }
        return stride(from: 0, to: words.count, by: wordsPerForcedChunk).map { start in
            words[start..<min(start + wordsPerForcedChunk, words.count)].joined(separator: " ")
        }
    }
}
