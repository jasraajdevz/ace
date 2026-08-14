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


---

## Part 3 — The Voice

### D24 · WebSocket transport, not WebRTC

**The brief specifies WebRTC. Ace ships a WebSocket.** This is the largest
deviation in the project, so here is the full reasoning.

**Why not WebRTC.** There is no WebRTC stack on Apple platforms. Using it means
adding Google's `libwebrtc` as a ~100MB binary XCFramework from a third-party SPM
repository. That collides with the brief's own "third-party dependencies near
zero", and — decisively — it is a dependency I *cannot verify*: with no Xcode on
this machine, I can't confirm the package resolves, links, or compiles. Shipping
an unverifiable 100MB binary into a project that must open and build first time
risks bricking the whole thing. That is a worse failure than the one being
avoided.

**Why WebSocket is the right call anyway.** OpenAI's own guidance is WebRTC for
*browsers*, WebSocket for server-side and native clients. `URLSessionWebSocketTask`
is first-party, has no dependencies, and carries exactly the same Realtime
protocol. Every §7 target is met on it.

**What is built regardless.** `RealtimeSessionMinter` implements the ephemeral-
token half of the WebRTC handshake (`POST /v1/realtime/sessions`) because it is
better practice on any transport: a token scoped to one session that expires in a
minute is safer on a wire than a long-lived key. And `RealtimeTransport` is a
two-method protocol, so if a WebRTC media engine is ever added it is one new
conformance and no changes anywhere else.

### D25 · Latency is engineered, measured and shown

The §7 budget is 400ms to first audio, p95 ≤ 700ms, barge-in under 150ms. Five
things get us there, in order of contribution:

1. **Prewarming.** `prewarmForSession` opens the socket, TLS and `session.update`
   when the tutor screen appears — not when the student first speaks. This is
   worth several hundred milliseconds on its own.
2. **Server-side VAD**, so no client silence timer is stacked on top.
3. **Playback starts on the first audio delta**, not on response completion.
4. **Barge-in is local first**: audio stops, *then* the cancel is sent. Waiting
   for a server round-trip would blow the 150ms budget by itself.
5. **No fade-out on stop.** A 100ms fade would eat two-thirds of the budget.

`LatencyTracker` and `BargeInTracker` are pure arithmetic in `Core/`, so all of
this is asserted rather than asserted-to-be-true, and the numbers are visible in
Settings ▸ Latency detail.

### D26 · The mock realtime server is part of the product's verification

`MockRealtimeTransport` implements `RealtimeTransport`, so
`OpenAIRealtimeProvider` cannot tell it from OpenAI. It can be scripted to reject
the key, take 900ms, drop mid-response, rate-limit, or emit events this client
has never heard of.

That is what makes "Live Mode integration-tested against a mocked realtime
server" a thing that actually runs — with no key, no network, no audio hardware
and no Xcode. It caught three real bugs: reconnection had no config to reconnect
*with*, a duplicate reconnect chain could start when a socket reported both an
error and a stream end, and my own async test harness deadlocked on main-actor
hops (it blocked the main thread, so main-queue work never ran).

### D27 · The voice baseline adapts over 30 seconds, not one

Voice matching compares the student against *their own* normal. The first
implementation smoothed that baseline with a fixed per-frame factor of 0.02 —
which, at 50 audio frames a second, is a one-second time constant. Any sustained
change was normalised away within about two seconds, so matching would have
silently stopped working almost immediately.

The baseline now uses a 30-second time constant derived from each frame's real
duration, so it is independent of the audio engine's buffer size. Caught by a
test asserting that a genuine jump in loudness registers.

### D28 · Behaviour beats voice; the gentler read beats both

`MoodFusion` merges the acoustic read with the behavioural one. Three rules:
agreement raises confidence (capped below certainty); a weak voice read never
overrides hard behavioural evidence like three wrong answers in a row; and when
they genuinely disagree about how the student is doing, the *gentler* read wins.

Acting gently on a student who was fine costs nothing. The reverse costs a lot.

### D29 · The key is never displayed, only fingerprinted

Once saved, the key becomes `sk-proj-…a91f` — the family and the last four. There
is no reveal button. It is entered through a `SecureField` so it isn't visible
while being pasted either, and it is stored with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which means it never syncs to
iCloud and a stolen backup is not a stolen key.

The self-test is deliberately end-to-end — connect, ask for one short reply, time
the first audio — because a test that only opened a socket would pass for a key
that has no Realtime access, which is the exact failure people hit.

### D30 · Talking out loud works in Demo Mode too

The microphone isn't gated behind a key. Without one, audio is transcribed
on-device by `SFSpeechRecognizer` and handed to the same Socratic tutor as text.
Live Mode makes the conversation faster and more natural; it is not the
difference between having a voice feature and not.

The audio session switches to `.playAndRecord` / `.voiceChat` while listening,
which turns on the system echo canceller — without it the microphone hears Ace
through the speaker and the server's VAD interrupts Ace with its own voice.


---

## Part 4 — The Presence

### D31 · Three check-ins per session, and most ticks say nothing

`BodyDoubleSession.tick()` runs every fifteen seconds and almost always returns
nil. Milestones fire at a quarter, half and three quarters — three sentences in a
twenty-five minute session — and each one is *silent* (shown, not spoken).

Body doubling works because someone is present, not because something is
happening. A companion that comments every two minutes is an interruption
wearing company's clothes. The break suggestion fires once, ever, and is never
repeated.

### D32 · The Guardian is late, escalating, and gives up

Thresholds were chosen by asking "would a good tutor say something here, or keep
quiet?" — so three wrong answers earns an offer, not one; sixty seconds of
silence is being stuck, twenty-five is thinking; and a frustrated *mood* on its
own never interrupts, because that already changes how Ace speaks.

On top: a 75-second cooldown, an escalation ladder so the same offer is never
repeated, declined offers are remembered, and after four ignored nudges Ace stops
offering entirely. Being ignored three times is an answer.

The welcome-back line is the one thing that bypasses the cooldown — greeting
someone's return late is worse than not at all — and it never mentions where they
went or how long they were away. "You were gone 12 minutes" is surveillance, not
company. There's a test asserting that.

### D33 · Do Not Disturb is provably non-blocking

`DoNotDisturbState.capabilities` is a dictionary where every value is `true`, and
a test iterates every DND configuration asserting that none of them is ever
`false`. It exists purely so §10's "it never blocks the app or the studying" is
a checkable property rather than a promise in a comment.

The one thing DND can never quiet is the crisis net: `allows(.safety)` returns
true unconditionally, in every configuration.

### D34 · Comfort comes first, and the bridge is always an offer

`ComfortResponder` runs strictly *after* the crisis service, on messages that
came back `.none`. Every response is comfort, then a bridge — never the reverse,
and the bridge is phrased as "want to…" rather than "you should…".

Tiredness gets explicit permission to stop. Anxiety is the only feeling that
doesn't mute the game layer, because a small win genuinely helps there.

And loneliness points **outward**: it names the possibility of messaging a real
person, and there is a test forbidding "you have me", "I'm all you need" and
similar. A companion that positions itself as someone's only company is doing
harm however warm it sounds — §10 is explicit about this.

### D35 · Focus music is synthesised, not licensed

There is no audio file in the app. `AmbientScore` generates note events; the
player renders and schedules them eight seconds at a time. Three consequences:
no licensing question (there is no recording to license), no megabytes in the
bundle, and **no loop seam** — looped study music becomes grating precisely
because you start hearing the loop.

Notes come from a pentatonic minor scale, where no combination is dissonant, so
the generator cannot produce a wrong note. A test asserts every generated pitch
is in the scale and that density stays below four notes a second, because
background music that gets busy stops being background.

Ducking is asymmetric: fast down (120ms), slow up (550ms). The reverse sounds
like a broken radio. And it ducks to 22% rather than to silence — music that
vanishes and returns is more distracting than music that dips.

### D36 · Speaking drills name ONE thing to fix

`SpeakingDrillScorer` scores clarity, structure and confidence, then picks the
weakest axis and turns it into a concrete instruction — naming the terms they
never said, or telling them to add "because" and "which means", or to drop the
hedging. A list of six weaknesses is a list nobody acts on.

Feedback always opens with a real strength, named specifically. Feedback that
opens with a criticism gets heard as "that was bad", and nothing after it lands.

Improvement is measured as recent-half versus earlier-half, not last-versus-first,
so one good day doesn't read as progress — and a dip is explained kindly rather
than reported as a decline.

### D37 · A separate suite for the crisis net on spoken transcripts

Speech recognisers produce run-on sentences with no punctuation, dropped
apostrophes, filler left in, and compounds split into two words. A safety net
tuned on typed input can quietly fail on spoken input, and nobody would notice
until it mattered.

`VoiceSafetyChecks` runs the net over realistic transcripts of both disclosures
and coursework. It immediately found a real hole: "anymore" comes back as "any
more", so "i do not want to be here any more" matched nothing. The normaliser now
rejoins the compounds a recogniser is likely to split.


---

## Part 5 — Everywhere, the business, and the final polish

### D38 · The worksheet said the tiers lose money, so the tiers changed

This is what the pricing worksheet was for, and it earned its place immediately.

Run against realistic metered usage, `PricingWorksheet` reported that **Pro at
$9.99 with 300 voice minutes would cost $45.59 to serve a subscriber who used
their allowance — a $38.59 loss, every month, per subscriber.** Unlimited was
worse: a $168 monthly loss. The suggested break-even prices were $131 and $521.

Two things changed rather than shipping that:

1. **Subscription tiers run on the mini realtime model.** The full model costs
   about six times as much per minute of audio, and at that rate no flat-rate
   price under roughly $60 survives a heavy subscriber. Mini is more than good
   enough for Socratic tutoring, where replies are two or three sentences.
   Bring-your-own-key gets the full model, because they're paying for it.
2. **Caps came down hard.** Free 20 → 15 minutes, Pro 300 → 150, Unlimited
   1,200 → 400.

Result: every tier is now positive at full use (Pro +$3.20, Unlimited +$3.88).
There's a **regression guard** in `TierChecks` that fails the build if any priced
tier ever goes underwater again.

The report also has to be internally consistent: costing the worst case against
the mini card while costing "expected use" against the full card would make the
worksheet contradict itself, which is exactly how a spreadsheet becomes
dangerous. `expectedMargin` uses the tier's own rate card.

### D39 · The paywall ships OFF, but the meter runs from day one

`PaywallFlag.isEnabled` is false by default. With it off there are no caps, no
purchase prompts, and no StoreKit calls at all — `entitlement` simply returns
Unlimited.

But `UsageLedger` records from the first Live Mode session regardless. That
ordering is the point: by the time the flag is flipped there is real usage data
behind the prices, rather than a guess. The usage panel is visible in Settings
either way, so a student on their own key can see exactly what Ace is spending.

### D40 · The share extension writes bytes and exits

A share extension is a separate process with a hard memory ceiling that is killed
the moment its UI dismisses. Running OCR, PDF rendering and deck generation
inside one is a good way to be terminated halfway through.

So `AceShare` does the minimum: writes the payload into the App Group container
and finishes. `ShareImporter` drains the inbox the next time the app is
frontmost, where there's a SwiftData stack and no ceiling. Sharing therefore
works while the app is closed, and the payload is written *before* the manifest
entry — so a kill between the two loses the item rather than leaving an entry
pointing at a file that isn't there.

It's UIKit rather than SwiftUI because the extension's whole job is a 400ms
confirmation, and UIKit gets on screen faster with no hosting controller.

### D41 · Free is not a trial, and the paywall says so

The free column on the paywall is longer than the paid one, because it's true:
everything on-device is unlimited forever. Capture, OCR, quizzes, flashcards, the
Socratic tutor, the system voice, body doubling, speaking drills, the widget —
none of it has a marginal cost, so none of it is gated.

The only thing money buys is realtime voice. Bring-your-own-key is offered
plainly rather than buried, because for a heavy user it's genuinely the better
deal, and pretending otherwise is the kind of thing this app shouldn't do.

Hitting a cap **degrades to Demo Mode** with one sentence. There's a test
forbidding "upgrade to continue", "blocked", "locked" and "unlock" from the cap
message.

### D42 · The QA sweep is a script, not a checklist

`Tools/qa.sh` checks the things that rot quietly: unlabelled controls, missing
designed states, `print` left in, force-trys, TODO markers, unreferenced types,
and whether the safety net is still wired into every free-text surface. It runs
as step 5 of `verify.sh`, so "everything passes" means all of it.

It found one real thing on its first run: `RealtimeSessionMinter` had been built
in Part 3 and never called. D24 claimed an ephemeral token is safer on the wire
than the raw key — so rather than deleting the code, it's now wired into
`WebSocketRealtimeTransport`, which mints a short-lived token and falls back to
the key only if minting fails. The claim is now true instead of merely stated.

### D43 · Rate cards carry the date they were checked

Model prices move faster than app releases, and a hard-coded number that silently
goes stale produces a pricing worksheet that is confidently wrong — which is
worse than no worksheet. Every `RateCard` has a `checkedOn` field, the report
prints it, and there's a test asserting it isn't empty.


---

## After Part 5 — closing the type-check gap

### D44 · The SwiftData layer is type-checked by stripping the macro

Xcode is not going to be available on this machine, so the standing "type errors
in the screens are the one class of defect we can't catch" caveat had to stop
being permanent.

`Tools/gen/typecheck_data.py` copies every SwiftData-bound file to a scratch
directory, mechanically strips the attributes the compiler plugin would expand
(`@Model` → `@Observable` + `PersistentModel`, `@Attribute(…)` and
`@Relationship(…)` removed), and compiles the copies against
`swiftdata_shim.swift` alongside the *real* `Core/`, `DesignSystem/`,
`Services/`, `Features/Safety/` and `Shared/` sources.

Two decisions inside that made it work:

**The shim mirrors the real signatures exactly**, including `throws` and generic
constraints. A shim that accepted more than SwiftData does would hide errors,
which is worse than having no shim — the `delete(model:)` generic is the reason
`SettingsView.resetAll` can't loop over `[any PersistentModel.Type]`, and the
shim has to preserve that.

**iOS-only SwiftUI is handled with `-Xfrontend -disable-availability-checking`,
not with more shims.** `fullScreenCover`, `.topBarLeading` and
`navigationBarTitleDisplayMode` don't exist on macOS. Writing stand-ins would
mean a hand-written signature could be subtly wrong, letting a broken call site
pass here and fail in Xcode. Disabling the availability checker keeps the *real*
SwiftUI declarations and therefore real signature checking, and simply drops the
"unavailable on this platform" complaints — which are true on macOS and
irrelevant to the iOS build.

**It found three real bugs on its first complete run**: `TextField` called as
`(_:text:axis:prompt:)` in `SourceDetailView`, `TutorView` and `BodyDoubleView`,
where SwiftUI's initialiser is `(_:text:prompt:axis:)`. All three would have
failed the first Xcode build.

The harness was then verified adversarially, because a check that only ever
passes is worthless: four deliberate errors injected into a screen file — a
wrong argument order, a typo'd method, a nonexistent property and a type
mismatch — were caught 4/4, while `swiftc -parse` caught 0/4.

What it still does not prove: that the real macro expands the way the shim
models it, that the schema is valid at runtime, or anything about layout.


### D45 · The shim became a real store, so persistence is executed not just compiled

Type-checking the SwiftData layer proved it *compiles*. It said nothing about
whether `fetchOrCreate` creates once or twice, whether XP actually lands on the
record, or whether the crisis net genuinely suppresses gamification.

So `swiftdata_shim.swift` grew a working in-memory `ModelContext` — `insert`
inserts, `fetch` returns and sorts, `delete` removes — and
`Tests/Persistence/` runs 149 checks against it via
`harness_data.py --run`.

**It found a crash.** `SessionRecorder` held `celebrations` and `safety` as
`unowned`. ARC releases at last *use*, not at scope end, so a caller that
doesn't independently retain those objects for the recorder's whole lifetime hits
a destroyed reference. In the app it happens to work because both are `@State` on
the same view — luck of ownership, not design. Neither type refers back to
`SessionRecorder`, so strong references cannot form a cycle; they are strong now.

Verified adversarially, as with the type-check: three behavioural regressions
were injected — removing the safety-suppression guard, removing the
already-finished guard, and making `fetchOrCreate` create every time. The
type-check noticed **none** of them (they all compile). The running harness
caught **all three**, including "NO XP is awarded during a safety event: expected
0, got 50" — which is the §10 guarantee, now protected by an executing test
rather than by careful reading.

The boundary is drawn deliberately: the checks never assert on cascade deletes,
relationship inverse maintenance or `@Attribute(.unique)`. Those are real
SwiftData behaviours the shim doesn't emulate, and asserting on them would be
testing the shim rather than the app.
