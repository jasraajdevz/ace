#!/usr/bin/env python3
"""
Find stored properties that are written and never read.

This exists because of a specific bug. `AppState.celebrationsMuted` was set by
the comfort responder — "they said they're exhausted, quiet the game layer" —
and read by nothing at all. Fourteen call sites gated the game layer on the
crisis flag and not one checked the comfort one, so the app said something kind
and then handed the student an XP toast. It type-checked, it passed every test,
and it was completely inert.

That failure has no signature a compiler will ever catch, because writing to a
property is a legitimate thing to do. The only way to see it is to ask, across
the whole app, whether anybody ever reads the thing back.

Same shape, found the same way, in the same sweep:
  • `StudySession.goalMet` / `.goalText` / `.safetyEngaged` — three columns whose
    doc comments described behaviour that depended on them, never written
  • `StoreController.isRestoring` — tracked correctly, ignored by the button, so
    "Restore purchases" sat dead for the several seconds `AppStore.sync()` takes

The allowlist below is the point as much as the check is: every entry is a
deliberate decision with a reason, so an inert property has to be argued for
rather than merely forgotten.

Usage:  python3 Tools/gen/find_dead_writes.py [--list]
Exits 1 if an unlisted write-only property exists.
"""

import pathlib
import re
import sys

ROOTS = ["Ace", "Shared", "AceWidget"]

# name -> why it is allowed to be write-only.
ALLOWED = {
    # Written by SwiftData/StoreKit/Codable machinery rather than by our code,
    # or read only through a synthesised conformance.
    "quizID": "identity column; the relationship is the access path",
    "lastOpenedAt": "recorded for a future 'recently studied' sort; costs one Date",
    "lastAttemptedAt": "same — kept so the column exists before it is needed",

    # Diagnostics that exist to be read in a debugger or a crash report.
    "lastRoundTrip": "transport diagnostic, read when debugging a slow session",
    "isMeasuring": "barge-in tracker's internal latch",

    # Measured, deliberately not fed to the heuristics.
    "averageResponseLatency": "collected; MoodHeuristics uses lastResponseLatency "
                              "on purpose — a rolling average lags the mood it is "
                              "meant to detect",

    # Worksheet inputs, printed by --pricing rather than read in app code.
    "measuredSessionCost": "pricing worksheet input, surfaced via --pricing",
    "measuredSessionMinutes": "pricing worksheet input, surfaced via --pricing",

    # Part of a type's tested contract, not yet surfaced in the UI. This scan
    # covers app code only, so a property the checks assert on still lands here.
    "wasRequeued": "FlashcardRunner's result contract; asserted in LoopChecks, "
                   "not yet shown on the results screen",

    # Written at the end of a session and kept for a history view that does not
    # exist yet. Both are asserted in the persistence checks.
    "goalMet": "recorded by SessionRecorder.finish for session history",
    "safetyEngaged": "recorded by SessionRecorder.finish for session history",
}

DECL = re.compile(
    r"^ {4}(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:private\(set\) |fileprivate |public |internal )?var ([a-zA-Z_]\w*)\s*[:=]"
)


def is_stored(lines, i):
    """A `var` is stored unless it has a getter.

    Three shapes to tell apart, and getting the third wrong is what made an
    earlier version of this script report every one-line computed property in
    the app as dead:

        var a = 1                       stored
        var b: Int { c + 1 }            computed, all on one line
        var d: Int = 1 { didSet { } }   stored, with an observer
    """
    body = lines[i].split("//")[0]
    if "{" not in body:
        return True
    if body.rstrip().endswith("{"):
        # Body is on the following lines — an observer means it is stored.
        for j in range(i + 1, min(i + 3, len(lines))):
            nxt = lines[j].strip()
            if nxt:
                return nxt.startswith(("didSet", "willSet"))
        return False
    # Brace opened and closed on this line: computed, unless it is an observer.
    return "didSet" in body or "willSet" in body


def main():
    files = [p for root in ROOTS for p in pathlib.Path(root).rglob("*.swift")]
    src = {p: p.read_text() for p in files}
    whole = "\n".join(src.values())

    # Members of a Codable type are read by the synthesised coder, not by name.
    codable = set()
    for p, s in src.items():
        for m in re.finditer(
            r"(?:struct|final class|class|enum)\s+(\w+)[^{\n]*:[^{\n]*"
            r"\b(?:Codable|Encodable|Decodable)\b", s
        ):
            codable.add((p, m.group(1)))

    props, owner = [], None
    for p, s in src.items():
        lines = s.splitlines()
        for i, line in enumerate(lines):
            t = re.match(r"^(?:final |public |private )*(?:struct|class|enum|extension)\s+(\w+)",
                         line.strip())
            if t and not line.startswith(" "):
                owner = t.group(1)
            m = DECL.match(line)
            if m and is_stored(lines, i):
                props.append((m.group(1), p, owner, i + 1))

    dead = []
    for name, p, own, ln in props:
        if (p, own) in codable:
            continue
        reads = 0
        for m in re.finditer(r"(?<![\w])" + re.escape(name) + r"\b", whole):
            after = whole[m.end():m.end() + 4]
            before = whole[max(0, m.start() - 40):m.start()]
            if re.match(r"\s*=(?!=)", after):        # an assignment target
                continue
            if re.search(r"\b(var|let)\s+$", before):  # the declaration itself
                continue
            if re.search(r"\bfunc\s+\w*$", before):
                continue
            if re.search(r"[,(]\s*$", before) and re.match(r"\s*:", after):
                continue                              # an argument label
            reads += 1
        if reads == 0:
            dead.append((name, own, f"{p}:{ln}"))

    listing = "--list" in sys.argv
    if listing:
        print(f"{len(props)} stored properties scanned")
        for name, own, loc in dead:
            mark = "allowed" if name in ALLOWED else "DEAD"
            print(f"  {mark:8} {name:26} {own or '?':22} {loc}")

    unlisted = [d for d in dead if d[0] not in ALLOWED]
    if unlisted:
        print(f"\n{len(unlisted)} propert{'y is' if len(unlisted) == 1 else 'ies are'} "
              "written but never read:")
        for name, own, loc in unlisted:
            print(f"    {own or '?'}.{name}  ({loc})")
        print("\nEither read it, delete it, or add it to ALLOWED in "
              "Tools/gen/find_dead_writes.py with a reason.")
        return 1

    if not listing:
        print(f"{len(props)} stored properties scanned, "
              f"{len(dead)} inert and accounted for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
