#!/usr/bin/env python3
"""
Find functions the app declares and never calls.

The sibling of `find_dead_writes.py`, and it exists for the same reason: the
worst bugs in this project have all been well-written code that nothing invokes.

What it found on its first run:

  • `StoreController.recordAudio` / `.recordText` — no callers anywhere, so every
    session metered zero usage. The ledger stayed empty, Settings always showed
    no usage, and the free-tier cap could never trigger. 119 checks covering
    tiers, caps and pricing passed throughout; they tested arithmetic on data
    the app never produced.
  • `SafetyCoordinator.beginFreshSession` — "Called when a *new* session starts"
    said the doc comment, and nothing called it, so one concern-level detection
    suppressed rewards for the rest of the app run.
  • `PresenceCoordinator.recordProgress` and `.evaluateGuardian` — unreachable,
    because the coordinator was `@State` inside a single screen and the study
    surfaces had no way to reach it.
  • `StoreController.startTransactionListener` — subscription changes made
    outside the app never registered.

A note on counting: a Swift function is often used without being *called* —
`onAppear(perform: animateIn)`, `onRedoMissed: startFollowUp`. Counting only
`name(` reported both of those as dead. So this counts every mention of the
identifier outside its own declaration, which is strict enough to be useful and
loose enough to be trustworthy.

Usage:  python3 Tools/gen/find_uncalled.py [--list]
Exits 1 if an unlisted uncalled function exists.
"""

import pathlib
import re
import sys

ROOTS = ["Ace", "Shared", "AceWidget"]

# Conformances the frameworks call for us. Not dead — just never named by us.
PROTOCOL_METHODS = {
    "body", "makeBody", "makeUIView", "updateUIView", "makeUIViewController",
    "updateUIViewController", "makeCoordinator", "sizeThatFits", "placeSubviews",
    "path", "animatableData", "main", "hash", "encode", "init",
    "placeholder", "getSnapshot", "getTimeline", "snapshot", "timeline",
    "recommendations", "entries", "callAsFunction",
    # UIKit / AVFoundation / Vision delegate callbacks.
    "imagePickerController", "imagePickerControllerDidCancel",
    "documentCameraViewController", "documentCameraViewControllerDidCancel",
    "speechSynthesizer", "speechRecognizer", "audioPlayerDidFinishPlaying",
}

# name -> why it is allowed to have no caller in app code.
ALLOWED = {
    # Teardown paths kept deliberately: the OS reclaims audio resources on
    # termination, but a future backgrounding policy needs a handle to pull.
    "shutdown": "explicit audio teardown; held for a backgrounding policy",

    # Reachable API on well-tested types, exercised by the checks and kept for
    # the screens that will use them. Each is a real capability, not a stub.
    "skipToUnanswered": "QuizRunner navigation, asserted in QuizRunnerChecks",
    "rewind": "FlashcardRunner navigation, asserted in FlashcardRunnerChecks",
    "ordered": "deterministic ordering helper, asserted in StudyGeneratorChecks",
    "matchedProsody": "voice-matching entry point, asserted in VoiceChecks",
    "personas": "roster accessor, asserted in VoiceChecks",
    "expectedMargin": "pricing worksheet, surfaced via --pricing",
    "isSustainable": "pricing worksheet, surfaced via --pricing",
    "aceBackground": "design-system modifier, asserted in DesignSystemChecks",
    "chunkIfTooLong": "PhraseSplitter internals, asserted in TextCleanerChecks",
    "measureRoundTrip": "transport instrumentation, asserted in LatencyChecks",
    "resetUsage": "used by the checks to start from a clean ledger",
    "clearAll": "share-inbox teardown, asserted in ShareInboxChecks",
    "speakingHistoryKeyCount": "how the reset checks count orphaned entries; the "
                               "sweep is what ships, this is how it is proved",
}

FUNC = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public |internal |private |fileprivate |static |class |final |mutating "
    r"|nonisolated |override |convenience )*func\s+([a-zA-Z_]\w*)\s*[(<]"
)


def main():
    files = [p for root in ROOTS for p in pathlib.Path(root).rglob("*.swift")]
    src = {p: p.read_text() for p in files}
    app = "\n".join(src.values())
    tests = "\n".join(p.read_text() for p in pathlib.Path("Tests").rglob("*.swift"))

    seen, dead = set(), []
    for p, s in src.items():
        for i, line in enumerate(s.splitlines()):
            m = FUNC.match(line)
            if not m:
                continue
            name = m.group(1)
            if name in PROTOCOL_METHODS or name.startswith("_") or name in seen:
                continue
            seen.add(name)

            # Every mention outside a `func <name>` declaration counts as a use —
            # Swift passes functions as values often enough that requiring a
            # literal call site produces more noise than signal.
            def uses(text):
                total = len(re.findall(r"(?<![\w.])" + re.escape(name) + r"\b", text)) \
                      + len(re.findall(r"\." + re.escape(name) + r"\b", text))
                decls = len(re.findall(r"func\s+" + re.escape(name) + r"\b", text))
                return total - decls

            if uses(app) <= 0:
                note = "unused in Tests too" if uses(tests) <= 0 else "used only by Tests"
                dead.append((name, note, f"{p}:{i + 1}"))

    listing = "--list" in sys.argv
    if listing:
        print(f"{len(seen)} functions scanned")
        for name, note, loc in dead:
            mark = "allowed" if name in ALLOWED else "DEAD"
            print(f"  {mark:8} {name:30} {note:20} {loc}")

    unlisted = [d for d in dead if d[0] not in ALLOWED]
    if unlisted:
        print(f"\n{len(unlisted)} function{'' if len(unlisted) == 1 else 's'} "
              "declared and never called from app code:")
        for name, note, loc in unlisted:
            print(f"    {name}  — {note}  ({loc})")
        print("\nEither call it, delete it, or add it to ALLOWED in "
              "Tools/gen/find_uncalled.py with a reason.")
        return 1

    if not listing:
        print(f"{len(seen)} functions scanned, {len(dead)} uncalled and accounted for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
