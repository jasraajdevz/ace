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


---

## Part 2 — The Loop

### D15 · Only the first attempt scores, but retries are unlimited

`QuizRunner` lets a student keep trying a question forever, and marks it correct
when they get there — but the *score* only counts questions answered right first
time, unaided.

Cutting someone off after one guess teaches nothing. Counting the third guess the
same as the first turns the score into a measure of persistence. Splitting the
two gives an honest score and a forgiving interaction. Taking a hint has the same
effect: still correct, no longer an unaided win, and it doesn't extend the
streak.

### D16 · The results screen's primary button redoes only what you missed

A results screen that says "60%" and offers "Done" wastes the most teachable
moment in the loop. `QuizRunner.missedQuestionsQuiz()` builds a follow-up from
exactly the questions that got you, and that's the emphasised action.

### D17 · Forgotten flashcards come back in the same session — once

A card graded *Forgot* is re-queued behind the remaining cards rather than
deferred to tomorrow; fixing it now is the point of sitting down. It can only
come back once, so a card you keep blanking on can't trap you in a loop.

Session progress is measured against the *original* deck size, so re-queues never
make the bar go backwards.

### D18 · The tutor is grounded, and says so when it can't be

`SourceTutor` anchors every reply to a real sentence from the student's own
material. When nothing in the source matches what they asked, it says so and asks
them to point at the right bit — even when they've explicitly demanded an answer.

A keyless app has no model to fall back on, so the alternative to grounding isn't
a worse answer, it's a fabricated one. The behaviour is also the right default
for Part 3: in Live Mode, grounding is what stops confident wrongness.

The one exception is a request for help that names *no* topic ("just tell me",
"I don't know"). There, Ace falls back to the material's main point rather than
going silent — silence is the worst possible response to a student asking for
help. "Just tell me about the Treaty of Versailles" does name a topic, so if it
isn't on the page, Ace declines.

### D19 · Agreement is measured with an F1, not overlap

Judging an attempted answer by plain word overlap gave "chlorophyll is sugar" a
0.5 against the chlorophyll sentence — half its words are in there — so Ace
congratulated a student on a flatly wrong answer.

Requiring the attempt to *cover* the sentence as well as draw from it (harmonic
mean of precision and recall) drops that to 0.2 while a real paraphrase still
scores ~0.86. Caught by a test asserting that a frustrated student and a neutral
one don't get identical wording — the two had collided in the "you're right!"
branch.

### D20 · The widget reads a flat snapshot, not the database

`WidgetSnapshot` is a handful of numbers and a string in a shared `UserDefaults`
container. Spinning up a `ModelContainer` inside a widget timeline — a separate
process, on the system's schedule, under a hard memory ceiling — is slow, fragile
and a well-known way to get a widget killed.

All the widget's copy is written by the *app* (`WidgetBridge.nudge`), so the tone
rules from §10 live in one place. Every branch of that copy is an invitation;
none is a countdown or a warning about what you stand to lose.

If the App Group isn't provisioned (it needs a paid Apple Developer account),
`WidgetStore` silently falls back to the app's own defaults: the app is
completely unaffected and the widget shows its empty state.

### D21 · The project file is generated by a script

`Tools/gen/build_pbxproj.py` writes `project.pbxproj`. With no Xcode on this
machine there's no way to add a target through the UI and let Xcode write the
file back, and hand-editing a 400-line OpenStep plist to add a second target,
an embed phase, a container proxy and a target dependency is exactly how a
project ends up opening but not building.

`Tools/gen/check_pbxproj.py` then validates the *graph* rather than the syntax:
every reference resolves, every target has the phases its product type needs,
every file reference exists on disk, the app embeds and depends on the widget,
the shared file is compiled into both targets, and the App Group matches across
both entitlements files and the source. It runs in `verify.sh`.

### D22 · Shared components live in the design system, not beside their screens

`ChoiceRow`, `AceReplyBubble`, `FlipCard`, `GradeButton`, `StudyActionCard`,
`QuickReply`, `TurnBubble` and `VoicePersonaRow` all moved into
`Ace/DesignSystem/`. Partly because the quiz, flashcard and tutor surfaces must
look like one product — and partly because everything in `DesignSystem/` is
compiled by the command-line build, while the screens that use them are bound to
SwiftData and can only be parsed.

The same reasoning put the two results screens in their own files: `Package.swift`
takes individual file paths as well as directories, so the persistence-free parts
of a mixed folder can still be type-checked.

### D23 · A compile-time probe covers the screens that can't be type-checked

`Tests/Checks/ComponentUsageProbe.swift` constructs every shared component using
the exact argument shapes the real screens use. It runs nothing — it exists so
that a signature change breaks the command-line build instead of surfacing in
Xcode.

It has already earned its place twice: it caught `AceBadge` being called with its
arguments in the wrong order (Swift's memberwise initialiser requires declaration
order), and it forced three components out of feature files and into the design
system where they belonged.
