//
//  ShareImportOutcome.swift
//  Ace
//
//  What happened when shared items were imported, and the line the student sees.
//
//  Lifted out of `ShareImporter` because that file is SwiftData-bound and so
//  cannot be executed by the checks — and the wording here has a branch that was
//  wrong. It reported failures only when *nothing* succeeded:
//
//      if imported.count > 1 { return "\(imported.count) shared items are ready." }
//      if failed > 0        { return "I couldn't read what you shared." }
//
//  Share five things, two of which are a format Ace can't read, and it said
//  "3 shared items are ready" — while `ShareInbox.drain()` had already cleared
//  the manifest, so the other two were gone. The student is told everything
//  worked and quietly loses two things.
//

import Foundation

/// The tally from one import pass.
struct ShareImportOutcome: Sendable, Equatable {
    var imported: [UUID] = []
    var failed: Int = 0
    var skippedForSafety: Int = 0

    var didImportAnything: Bool { !imported.isEmpty }

    /// The line shown when the app comes to the front.
    ///
    /// Partial failure gets its own branch. Anything the importer could not read
    /// is already out of the inbox by the time this is read, so a message that
    /// mentions only the successes is the last chance the student had to know
    /// something went missing.
    ///
    /// Items the safety net held back are deliberately *not* counted here. That
    /// surface has already said what it needs to; totting them up in a toast
    /// afterwards would be crass.
    var message: String? {
        let succeeded = imported.count

        if succeeded > 0 && failed > 0 {
            let missed = failed == 1 ? "one" : "\(failed)"
            return succeeded == 1
                ? "One is ready — I couldn't read \(missed) of the others."
                : "\(succeeded) are ready — I couldn't read \(missed)."
        }
        if succeeded == 1 { return "Something you shared is ready." }
        if succeeded > 1 { return "\(succeeded) shared items are ready." }
        if failed > 0 { return "I couldn't read what you shared. Try the text instead." }
        return nil
    }
}
