//
//  StringUtilities.swift
//  Ace
//
//  Small, shared string helpers. Kept in `Core/` so every layer can use them
//  and so they are covered by the command-line verification build.
//

import Foundation

extension String {
    /// Whitespace- and newline-trimmed. Used everywhere a student types
    /// something, so it is worth having exactly one spelling of it.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the string is empty once trimmed — the check that actually
    /// matters for "did they type anything?".
    var isBlank: Bool { trimmed.isEmpty }
}
