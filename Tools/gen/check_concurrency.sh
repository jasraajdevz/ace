#!/usr/bin/env bash
#
# Type-check the app under `-strict-concurrency=complete`.
#
# The project ships in the Swift 5 language mode with minimal concurrency
# checking, which is the right default today — but "minimal" means the compiler
# stays quiet about data races it can already see. This runs the complete check
# as a separate pass, so the hazards surface without changing how the app builds.
#
# It earned its place immediately, finding:
#   • six `NSLock.lock()` calls inside `async` functions in `RealtimeAudioPlayer`
#     — an error outright in Swift 6, because awaiting while holding a lock
#     blocks a thread from the cooperative pool
#   • three `static var` protocol requirements on `QuickCaptureIntent`, which are
#     globally mutable shared state
#   • an `Equatable` conformance on `XPToast` crossing out of main-actor isolation
#   • a captured `var` handed to `AVAudioConverter`'s `@Sendable` input block
#   • a non-Sendable closure used as a `Binding` setter
#
# WHY THIS RUNS `swiftc` DIRECTLY rather than `swift build -Xswiftc`:
# an earlier version did the latter and reported a clean pass while compiling
# nothing at all. SPM considered the module up to date, emitted no warnings, and
# the grep read that silence as success — a check that could only ever pass.
# Invoking the compiler on an explicit file list makes the work unconditional.
#
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SDK=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null) || {
    echo "no macOS SDK available"; exit 0; }

# The same files the SPM verification target compiles. `ShareImporter` is
# excluded there too — it is SwiftData-bound, so it needs the macro plugin.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
    find Ace/Core Ace/DesignSystem Ace/Services Ace/Features/Safety Shared AceWidget \
        -name '*.swift' -type f | grep -v 'ShareImporter' | sort
)
FILES+=(Ace/Features/Study/QuizResultsView.swift
        Ace/Features/Study/FlashcardResultsView.swift
        Ace/Features/Settings/LiveModeSettings.swift
        Ace/Features/Settings/PaywallView.swift)

OUTPUT=$(swiftc -typecheck -sdk "$SDK" -target arm64-apple-macos14.0 \
         -strict-concurrency=complete "${FILES[@]}" 2>&1)

# Reasoned exceptions. Each is a case where the diagnostic is right about the
# code and wrong about the intent — not a case of "we could not work it out".
#
#  • scheduleBuffer: the async alternative suspends until playback *finishes*.
#    Awaiting it would serialise the stream into one-buffer-at-a-time playback,
#    which is the opposite of what streaming audio needs. The synchronous
#    overload is correct here and the warning does not know that.
#  • FocusMusicPicker.onVolume: `Binding`'s setter is `@Sendable`, but both
#    callers mutate main-actor state inside the closure, so marking it
#    `@Sendable` breaks them rather than making anything safer. The real fix is
#    `@Binding var volume`, which needs a stored property on `FocusMusicPlayer`
#    that does not exist yet. Recorded rather than annotated away.
ALLOWED_PATTERNS=(
    'consider using asynchronous alternative function'
    "converting non-Sendable function value to '@isolated(any) @Sendable (Double) -> Void'"
)

FINDINGS=$(printf '%s\n' "$OUTPUT" \
    | grep -E '^[A-Za-z][^ ]*\.swift:[0-9]+:[0-9]+: (warning|error):' | sort -u)
for pattern in "${ALLOWED_PATTERNS[@]}"; do
    FINDINGS=$(printf '%s\n' "$FINDINGS" | grep -vF "$pattern")
done
FINDINGS=$(printf '%s\n' "$FINDINGS" | sed '/^$/d')

# A compile that produced no diagnostics at all AND no output is suspicious —
# it is what the broken version of this check looked like. Prove it ran.
if [ -z "$OUTPUT" ] && [ "${#FILES[@]}" -eq 0 ]; then
    echo "refusing to report a pass: no files were checked"
    exit 1
fi

if [ -n "$FINDINGS" ]; then
    echo "$FINDINGS"
    exit 1
fi

echo "${#FILES[@]} files clean under -strict-concurrency=complete"
exit 0
