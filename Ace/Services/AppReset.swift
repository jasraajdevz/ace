//
//  AppReset.swift
//  Ace
//
//  Everything "Start over" has to clear that isn't a SwiftData row.
//
//  It exists because the reset only deleted the six model types and stopped.
//  Three things survived it:
//
//    • the usage ledger — so a student at their free cap could reset the app,
//      lose all their work, and still be capped
//    • the share inbox, manifest and payload files — so items shared before the
//      reset were imported into the "fresh" app afterwards
//    • every `ace.speaking.history.<uuid>` key, whose source had just been
//      deleted, leaving entries keyed to an id that no longer exists anywhere.
//      Unreadable, unreclaimable, and one more added per source, forever.
//
//  The last of those leaked on the ordinary path too: deleting a single source
//  never cleared its speaking history either.
//
//  Kept out of the view so it can actually be run. `SettingsView.resetAll` had
//  no test covering it and no way to get one.
//

import Foundation

enum AppReset {

    /// Where per-source speaking scores are keyed.
    ///
    /// Shared with `SpeakingHistoryStore` rather than written out twice — the
    /// sweep below has to match the writer exactly or it silently cleans
    /// nothing, which is the failure it was written to fix.
    static let speakingHistoryPrefix = "ace.speaking.history."

    /// Keys holding study data or state derived from it.
    private static let studyStateKeys = [
        "ace.demoContentInstalled",
        "ace.usage.ledger",
        "ace.quickCapture.requestedAt",
    ]

    /// Kept deliberately on a reset:
    ///
    ///  • `ace.tier` — they paid for that. Wiping local study data must not
    ///    revoke a subscription; StoreKit is the source of truth and would
    ///    restore it anyway, but taking it away even briefly is wrong.
    ///  • `ace.sounds.enabled`, `ace.haptics.enabled`, `ace.music.*` — comfort
    ///    and accessibility choices about how the device behaves, not study
    ///    data. Someone who turned haptics off did so for a reason that a reset
    ///    does not undo.
    ///  • `ace.provider.*` — the key stays in the Keychain and is removed by its
    ///    own control in Settings, so silently orphaning the preference that
    ///    points at it would be confusing.

    /// Clear everything a reset should clear outside the model store.
    static func clearStoredState(defaults: UserDefaults = .standard) {
        for key in studyStateKeys {
            defaults.removeObject(forKey: key)
        }
        clearAllSpeakingHistory(defaults: defaults)
        ShareInbox.clearAll()
    }

    /// Forget one source's leftovers, for an ordinary delete.
    static func forget(sourceID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: speakingHistoryPrefix + sourceID.uuidString)
    }

    /// Sweep every speaking-history entry, whatever source it belonged to.
    static func clearAllSpeakingHistory(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(speakingHistoryPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// How many orphaned entries are sitting there. Used by the checks, and a
    /// useful thing to be able to ask.
    static func speakingHistoryKeyCount(defaults: UserDefaults = .standard) -> Int {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(speakingHistoryPrefix) }
            .count
    }
}
