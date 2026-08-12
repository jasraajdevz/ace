# Decisions

Judgement calls made while building Ace, and the reasoning behind each. Newest
part at the bottom.

---

## Part 1 — Foundation & Capture

### D1 · No Xcode on this machine — how the build is verified anyway

**Situation.** The build machine has the Swift command-line toolchain but not
Xcode: no iOS SDK, no Simulator, no `xcodebuild`, and — because they ship inside
Xcode — no XCTest, no Swift Testing, and no SwiftData macro plugin.

**Decision.** Rather than write code and hope, the project is structured so the
maximum possible amount is genuinely compiled and tested here:

| Layer | Verification |
|---|---|
| `Core/`, `DesignSystem/`, `Services/` | **Compiled against the macOS SDK** and covered by 1,227 assertions. SwiftUI, Vision, AVFoundation and Speech all resolve on macOS. |
| `Data/`, `Features/`, `AceApp.swift` | **`swiftc -parse` syntax gate** on every file, plus manual audit. These need SwiftData macros and UIKit. |
| Project, plists, assets, decks | Structural validation in `Tools/verify.sh`. |

`Package.swift` is a **developer harness, not a second copy of the app** — it
points `sources:` at the same files the Xcode target compiles, so the two cannot
drift.

**Consequence.** Type errors in `Features/` are the one class of defect this
machine can't catch. They're a one-keystroke fix on first build in Xcode.
Everything else — logic, safety behaviour, the design system, the services — is
verified for real.

**This is the only thing Part 1 needs from you: install Xcode.** See README §1.

### D2 · Dark-only, not dark-first

The brief says dark-first. Ace goes further and locks to dark
(`UIUserInterfaceStyle = Dark`).

A light palette isn't a toggle, it's a second design: every shadow, every
elevation, every gradient and the entire contrast strategy has to be re-tuned,
and a half-tuned light mode is exactly the "looks like the indie app" failure the
brief warns about. One palette, tuned properly, on a near-black ground.

Accessibility is not traded away for it: Dynamic Type works throughout (the type
scale is built on semantic text styles), VoiceOver labels are on every component,
and Reduce Motion is handled by `aceAnimation`.

Revisit if a student actually asks for light mode.

### D3 · Quiz and flashcard generation built in Part 1, not Part 2

The brief puts the Drill Engine in Part 2. The *generation* logic was built now
anyway, because it's pure Foundation code — meaning it's the kind of thing this
machine can genuinely test, whereas the Part 2 UI around it can't be.

Part 2 gets the grading, XP, spaced-repetition scheduling and the screens. The
generator is already verified and already producing the two bundled demo decks.

### D4 · Hyperbole is `.concern`, not silence and not `.crisis`

"This homework is killing me" and "kill me now" are how teenagers talk about a
hard worksheet. They are also, sometimes, how a real disclosure starts.

Three-way severity resolves it: `.crisis` runs the full protocol, `.concern` is
one warm sentence and a soft offer, `.none` is silence. Hyperbole lands on
`.concern` — Ace acknowledges it kindly and offers to slow down, without a
helpline screen.

Related: "I want to die 😭" stays `.crisis` even with an emoji or "lol". Emoji do
not downgrade severity. A student who gets one unnecessary kind message loses
nothing; the opposite error is unacceptable.

### D5 · First-person matching, not a blocklist

The hardest problem in the crisis net is telling "I want to kill myself" from
"Macbeth kills Duncan". A list of academic exceptions would be endless and
permanently incomplete.

Instead, **every crisis phrase is written in the first person** and matched on
word boundaries against a normalised string. Third-person prose about death,
killing, war and suicide in literature simply never matches. There's a suite of
30 real coursework sentences proving it.

Three things sit on top:
- **Obfuscation repair** runs *before* punctuation stripping, so `k!ll` doesn't
  become `k ll` and slip through.
- **Filler stripping** reduces "I just really honestly want to die" to
  "i want to die", so the phrase list doesn't need a row per adverb.
- **Coded terms** (`kms`, `sewerslide`, `unalive myself`) bypass the first-person
  rule, since they have essentially no other usage — but `kms` is ignored when
  preceded by a number, because physics worksheets measure kilometres.

### D6 · Gamification stays off for the rest of the session

After a `.crisis` or `.concern` signal, XP, streaks, quizzes, celebration
haptics and celebration sounds are suppressed — and dismissing the screen does
**not** turn them back on. Only a genuinely new session does.

Returning someone to "🔥 4 day streak!" moments after that conversation would be
grotesque. `SafetyCoordinator.isGamificationSuppressed` is checked at every
gamified call site.

### D7 · Streaks have a free repair

Missing one day spends a repair rather than resetting the streak, and repairs are
earned back after seven consecutive days (capped at two). Wrong answers still
earn XP for the attempt.

§10 requires healthy motivation over manipulation. A streak that dies on the
first bad day converts a bad day into a reason to quit. There's a check that
scans every piece of streak copy for guilt language ("don't lose", "last chance",
"failed").

### D8 · Storage stores primitives; `Core/` owns the types

SwiftData models hold strings, ints, dates and JSON blobs, and expose the rich
`Core/` types through computed properties. `AppState` takes a plain
`StudentSettings` value, never a `Profile`.

It keeps migrations simple, and it's the reason the entire logic layer can be
tested with no database anywhere near it.

`StoredQuiz` keeps its questions as encoded JSON rather than as a child model: a
quiz is always read and written whole, so a relationship would add a third level
of graph management and buy nothing.

### D9 · A custom check runner instead of a test framework

Neither XCTest nor Swift Testing exists without Xcode. Rather than ship a test
suite that can't run, `Tests/Checks/` uses a ~60-line harness (`CheckRun`) and
runs with `swift run AceVerify`.

The assertions are ordinary Swift, so once Xcode is installed they can be called
from a real test target without changing a line.

### D10 · Artwork is generated from code

`Tools/gen/make_icon.swift` renders the app icon and launch mark with
CoreGraphics. The glyph geometry lives in `AceGlyphGeometry`
(`Ace/DesignSystem/AceMark.swift`) and the renderer reads the same coordinates,
so the in-app mark and the home-screen icon are the same shape by construction.

The "A" is drawn subtractively — one triangle with the counter and the leg-notch
cut out of it, filled even-odd. Building it additively from two legs plus a
crossbar produces overlapping subpaths with opposite winding, which punches a
hole exactly where the crossbar should be. (It did, on the first render.)

### D11 · UI sounds are synthesised, not shipped as files

`SoundCues.swift` renders each cue as a short sine tone with an attack/decay
envelope at launch and caches the buffers. No audio assets, no licensing
question, and every cue is consistent with the others by construction.

Each is under 200ms and the master gain ducks to 35% while Ace is speaking.

### D12 · Swift 5 language mode, minimal concurrency checking

`SWIFT_VERSION = 5.0` and `SWIFT_STRICT_CONCURRENCY = minimal`, pinned
explicitly rather than left to the Xcode template default (which is now Swift 6).

Swift 6's strict checking would demand isolation annotations throughout the
SwiftUI layer, and this codebase is meant to be readable by a beginner. The
screen-level views are annotated `@MainActor` where they own helper methods that
touch main-actor state, which is the part that actually matters.

Worth revisiting in Part 3, when WebRTC introduces real concurrency.

### D13 · Portrait-only on iPhone

A study surface that rotates is a study surface that loses your place mid-
question. iPad gets all four orientations.

### D14 · Demo decks are generated by the real engine

The two bundled decks are produced by `StudyMaterialGenerator` from realistic
source passages, not hand-authored.

New users see exactly what they'll get from their own photographed page — no
bait and switch — and the decks act as a standing end-to-end test: if the
generator regresses, they visibly rot. `DemoDeckChecks` asserts on their quality
directly (no leaked answers, no duplicate choices, no thin decks).

Three real defects surfaced this way and were fixed: definitions shorter than
four words produced useless cards ("Respiration → opposite process"); always
taking the top-ranked distractors meant every question in a deck offered the same
two wrong answers; and inconsistent source capitalisation made the odd-one-out a
visual tell.
