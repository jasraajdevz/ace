//
//  SourceTextCleaner.swift
//  Ace
//
//  Turns raw OCR output into something a tutor can actually work with.
//
//  Vision gives us one string per recognised line, in reading order. That means
//  a paragraph arrives as a stack of hard-wrapped fragments, hyphenated words
//  are split across lines, and page furniture (page numbers, running headers,
//  "Chapter 4  •  87") is mixed in with the content. If we hand that straight to
//  a quiz generator we get questions about page numbers.
//

import Foundation

/// A single unit of cleaned source text.
struct TextBlock: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case heading
        case paragraph
        case listItem
    }
    var kind: Kind
    var text: String
}

enum SourceTextCleaner {

    /// Full pipeline: raw OCR lines in, clean prose out.
    static func clean(lines rawLines: [String]) -> String {
        blocks(from: rawLines).map(\.text).joined(separator: "\n\n")
    }

    /// Convenience for pasted text, which arrives as one blob.
    static func clean(text raw: String) -> String {
        clean(lines: raw.components(separatedBy: .newlines))
    }

    /// The structured version — used by the study engine, which cares about
    /// which fragments are headings (good quiz topics) versus prose.
    static func blocks(from rawLines: [String]) -> [TextBlock] {
        let trimmed = rawLines
            .map { normalizeWhitespace($0) }
            .filter { !$0.isEmpty }

        let content = trimmed.filter { !isPageFurniture($0) }
        guard !content.isEmpty else { return [] }

        var blocks: [TextBlock] = []
        var buffer: [String] = []

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let joined = joinWrappedLines(buffer)
            if !joined.isEmpty {
                blocks.append(TextBlock(kind: .paragraph, text: joined))
            }
            buffer.removeAll()
        }

        for line in content {
            if let item = listItemBody(line) {
                flushParagraph()
                blocks.append(TextBlock(kind: .listItem, text: item))
            } else if isHeading(line) {
                flushParagraph()
                blocks.append(TextBlock(kind: .heading, text: line))
            } else {
                buffer.append(line)
                // A line that ends a sentence and isn't obviously mid-paragraph
                // closes the block. Without this every page becomes one giant
                // paragraph.
                if endsSentence(line) && !looksMidParagraph(line) {
                    flushParagraph()
                }
            }
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Steps

    /// Collapse runs of whitespace, normalise the quotes and dashes OCR loves to
    /// mangle, and trim.
    static func normalizeWhitespace(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")  // non-breaking space
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"")
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"")
        s = s.replacingOccurrences(of: "\u{2013}", with: "-")  // en dash
        s = s.replacingOccurrences(of: "\u{2014}", with: " - ") // em dash
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Page numbers, running headers and OCR noise. Anything that survives here
    /// becomes quiz material, so it's worth being a little aggressive.
    static func isPageFurniture(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return true }

        // Bare page numbers: "87", "- 87 -", "Page 87", "87 | Chapter 4"
        let digitsOnly = s.allSatisfy { $0.isNumber || $0 == "-" || $0 == "|" || $0 == " " || $0 == "." }
        if digitsOnly && s.contains(where: \.isNumber) { return true }

        let lower = s.lowercased()
        if lower.hasPrefix("page ") && s.count < 16 { return true }

        // Very short fragments with no letters are almost always noise. We keep
        // short *lettered* lines because "Mitosis" is a valid heading.
        let letterCount = s.filter(\.isLetter).count
        if letterCount == 0 { return true }

        // A line that is mostly non-letters is OCR garbage from a diagram.
        if Double(letterCount) / Double(s.count) < 0.45 && s.count > 4 { return true }

        // Single stray characters.
        if s.count <= 2 { return true }

        return false
    }

    /// Headings: short, no terminal punctuation, often title-case or all-caps.
    static func isHeading(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.count <= 60, !s.isEmpty else { return false }
        if endsSentence(s) { return false }

        let words = s.split(separator: " ")
        guard words.count <= 8 else { return false }

        // ALL CAPS heading.
        let letters = s.filter(\.isLetter)
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) { return true }

        // "Chapter 4", "Section 2.1", "4.3 Photosynthesis"
        let lower = s.lowercased()
        for prefix in ["chapter ", "section ", "unit ", "lesson ", "part "] where lower.hasPrefix(prefix) {
            return true
        }

        // Title Case with at least two words and no sentence ending.
        if words.count >= 2 {
            let capitalised = words.filter { $0.first?.isUppercase == true }.count
            if Double(capitalised) / Double(words.count) >= 0.7 { return true }
        }
        return false
    }

    /// Returns the body of a bullet/numbered item, or nil if it isn't one.
    static func listItemBody(_ line: String) -> String? {
        let s = line.trimmingCharacters(in: .whitespaces)
        let bullets: [Character] = ["•", "-", "*", "‣", "◦", "·"]
        if let first = s.first, bullets.contains(first) {
            let body = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        // "1. thing" / "2) thing"
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            let head = parts[0]
            if head.count <= 3,
               head.dropLast().allSatisfy(\.isNumber),
               let last = head.last, last == "." || last == ")" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func endsSentence(_ line: String) -> Bool {
        guard let last = line.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "." || last == "!" || last == "?" || last == "\"" || last == ":"
    }

    /// Heuristic for "this line is clearly still mid-thought" — e.g. it ends in
    /// an abbreviation like "e.g." rather than a real full stop.
    static func looksMidParagraph(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        for abbrev in ["e.g.", "i.e.", "etc.", "vs.", "fig.", "eq.", "no.", "dr.", "mr.", "mrs.", "ms.", "st."] {
            if lower.hasSuffix(abbrev) { return true }
        }
        return false
    }

    /// Rejoin hard-wrapped lines, healing hyphenated words as we go.
    ///
    /// "photosyn-" + "thesis" → "photosynthesis"
    static func joinWrappedLines(_ lines: [String]) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            if index == 0 {
                out = line
                continue
            }
            if out.hasSuffix("-") {
                // Only heal when the next line starts lowercase — "well-" +
                // "Known" is more likely a real hyphenated compound at a break.
                if line.first?.isLowercase == true {
                    out.removeLast()
                    out += line
                } else {
                    out += line
                }
            } else {
                out += " " + line
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
