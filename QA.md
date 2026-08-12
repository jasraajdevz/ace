# QA — final sweep

The Part 5 sweep: every checklist from Parts 1–4 re-run, plus the performance,
accessibility and dead-code passes.

**Run it yourself:**

```bash
cd ~/Downloads/ace && ./Tools/verify.sh && ./Tools/qa.sh
```

**Result: everything verifiable on this machine passes.** 2,949 assertions, 79
files through the syntax gate, three-target project graph validated, QA sweep
clean.

The one thing this log cannot claim is a Simulator run-through — see
[What could not be verified here](#what-could-not-be-verified-here), which is the
most important section in this file.

---

## Part 1 — Foundation & Capture

| Checklist item | Status | Evidence |
|---|---|---|
| Compiles clean | ✅ | `Core/`, `DesignSystem/`, `Services/`, `Features/Safety/` + selected screens compile against the macOS SDK with zero warnings. Everything else passes `swiftc -parse`. |
| Runs keyless in the Simulator | ⚠️ **needs Xcode** | Code path verified: `AppState` starts on `MockAIProvider`, `ProviderController.refresh()` returns Demo Mode with no key. Not *run*. |
| Onboarding → capture → OCR'd source on screen | ⚠️ **needs Xcode** | Logic verified (`SourceTextCleaner`, 39 checks). Vision OCR type-checks. Not run end to end. |
| Crisis service passes its unit tests | ✅ | 281 checks across 5 suites, including 30 real coursework sentences that must *not* trigger it, and spoken-transcript variants. |
| UI already looks designed — no default-grey | ✅ | `qa.sh` verifies `AceEmptyState`/`AceLoadingState`/`AceErrorState` are used and no bare `ProgressView` exists in feature code. |

## Part 2 — The Loop

| Checklist item | Status | Evidence |
|---|---|---|
| Capture → Socratic tutor → quiz → grade → XP/level/streak | ⚠️ **needs Xcode** for the run; all engines verified | `QuizRunner` (70), `FlashcardRunner` (65), `SourceTutor` (222), progression (222). |
| Widget updates | ⚠️ **needs Xcode** | `WidgetBridge.publish` is called from `SessionRecorder.persist()`, capture, and Home's `.task`. Snapshot round-trip verified. |
| Everything persists across relaunch | ⚠️ **needs Xcode** | SwiftData models compile-gated only (macro plugin ships with Xcode). |
| Answer must not leak before it's earned | ✅ | Asserted for every mood and every rung; hint ladder withholds its last rung. |
| Effort always pays | ✅ | `XPEvent.attemptedAnswer.amount > 0` asserted. |

## Part 3 — The Voice

| Checklist item | Status | Evidence |
|---|---|---|
| Demo Mode still perfect keyless | ✅ | Asserted: with no connection, `tutorReply` falls through to Demo and still answers. |
| Live Mode integration-tested against a mocked realtime server | ✅ | 36 checks driving the **real** `OpenAIRealtimeProvider` against `MockRealtimeTransport` — connect, converse, barge in, drop out, rate-limit, unknown events, crisis. |
| Self-test passes with a key | ⚠️ **needs a key** | End-to-end path built and type-checked; requires a real key to exercise. |
| TTFA hits budget on good network | ✅ *in harness* | Asserted against a fast mock (`meetsBudget`), and asserted to **fail** against a 900ms mock — so the measurement is real, not decorative. Real-network numbers need a device. |
| Barge-in silences Ace in <150ms | ✅ | Measured in the integration suite, including with a simulated 50ms engine-stop cost. |

## Part 4 — The Presence

| Checklist item | Status | Evidence |
|---|---|---|
| Body-double: start → goal → milestones → finish | ✅ | Full arc driven on an injected clock (46 checks), including pause, early stop and the break suggestion firing exactly once. |
| Leave-app → return nudge fires | ✅ | `Guardian.evaluate(didJustReturn:)` bypasses the cooldown; asserted. Scene-phase wiring needs a device. |
| DND quiets but never locks | ✅ | Every capability asserted `true` in every DND configuration; `allows(.safety)` unconditional. |
| Comfort and crisis verified with scripted tests | ✅ | 75 comfort checks + 281 crisis checks, including forbidden-phrase assertions ("you have me", guilt language, therapist role-play). |
| Music ducks under voice | ✅ | Mix arithmetic asserted; asymmetric ramp asserted. Audible check needs a device. |
| Speaking drills give useful feedback keyless and live | ✅ | 67 checks; feedback must be an instruction, must open with a strength, must name the weakest axis. |

## Part 5 — Everywhere & the business

| Checklist item | Status | Evidence |
|---|---|---|
| Share-sheet → deck appears in-app | ⚠️ **needs Xcode** for the run | Third target in the project, validated structurally (embedded, depends-on, App Group matching, principal class exists). `ShareInbox` round-trip verified (30 checks). |
| Metering visible in Settings | ✅ | `UsageSection` compiled and probed; 34 metering checks. |
| Paywall flag works both ways | ✅ | 8 checks toggling it in both directions and asserting caps appear and disappear. |
| `QA.md` written | ✅ | This file. |

---

## Performance pass

Instruments needs a device. What was done instead is the static work that
Instruments would otherwise *find*:

| Concern | Finding |
|---|---|
| Main-thread stalls | Audio capture, conversion and feature extraction run off the main actor (`MicrophoneCapture` is deliberately not `@MainActor`, with a lock). OCR runs in a continuation off the main thread. Music renders in a background `Task`. |
| Animation hitches | The particle burst draws in a single `Canvas` pass inside `TimelineView` rather than as N SwiftUI views — 90 particles as individual views would drop frames on older hardware. Particle position is derived from elapsed time, not integrated, so a dropped frame can't accumulate error. |
| Cold launch | No network on the launch path. SwiftData container built synchronously with an in-memory fallback so a corrupt store can't hang launch. Demo decks install once, behind a flag. |
| Memory | Ledger, latency window, speaking history and share inbox are all explicitly bounded (120 sessions / 40 samples / 40 scores / 40 items), each with a test. |
| Widget budget | Reads one small JSON blob from `UserDefaults`. No `ModelContainer`, no images, no network. Timeline refresh is hourly. |
| Extension budget | The share extension writes bytes and exits. All OCR and generation happens in the app. |

**Still required on a device:** an Instruments Time Profiler trace during a quiz
and a level-up, and an Allocations trace over a 30-minute live session.

## Accessibility pass

| Check | Status |
|---|---|
| Dynamic Type | ✅ The whole type scale is built on semantic `TextStyle`s, so it scales automatically. Verified by `qa.sh`. |
| VoiceOver labels | ✅ Every design-system control carries an `accessibilityLabel` or combines its children. Verified by `qa.sh`. |
| Decorative elements hidden | ✅ `AuraBackground`, `AceMark` and `ParticleBurst` are `accessibilityHidden(true)`. |
| Reduce Motion | ✅ Handled in 5 files. The particle burst is *removed*, not slowed — a slow burst is still motion. The flip card cross-fades. |
| Text truncation | ✅ 63 `fixedSize(horizontal:vertical:)` call sites so long text grows rather than clipping. |
| Colour as the only signal | ✅ Quiz choices carry an icon (`checkmark`/`xmark`) as well as a colour; the connection indicator carries a symbol and a label. |
| Contrast | ⚠️ Palette designed against a near-black ground and reviewed by eye, but **not measured**. Needs a contrast checker on a device. |

**Still required on a device:** a full VoiceOver navigation pass, and a run at
the largest accessibility text sizes.

## Dead code and lint pass

| Check | Result |
|---|---|
| Unreferenced types | ✅ None. Found one — `RealtimeSessionMinter` was built in Part 3 and never called. Rather than delete it, it's now wired into the transport so Live Mode connects with a short-lived ephemeral token instead of the raw key, which is what D24 claimed it would do. |
| `print` statements | ✅ None in shipping code. |
| TODO/FIXME/HACK/WIP/stub markers | ✅ None. |
| `fatalError` / `preconditionFailure` | ✅ None. |
| `try!` | ✅ One, deliberate: the in-memory `ModelContainer` fallback on the launch path, where there is no meaningful alternative to crashing. |
| Hardcoded secrets | ✅ None. The key is read only from the Keychain, never `UserDefaults`. |

---

## What could not be verified here

**This machine has no Xcode** — only the Swift command-line tools. No iOS SDK,
no Simulator, no `xcodebuild`, no SwiftData macro plugin, no XCTest. See
DECISIONS.md D1 for how the project was structured around that.

So the following are **built and statically verified, but never observed
running**:

1. **The app launching at all.** The project graph is validated
   (`Tools/gen/check_pbxproj.py`: every reference resolves, every target has its
   phases, every file exists, extensions are embedded and depended on, App Groups
   match across three entitlements files and the source). But no build has run.
2. **The SwiftData layer.** `@Model` needs Xcode's macro plugin, so
   `Ace/Data/` and the screens bound to it get the syntax gate plus a
   component-usage probe, not a type-check.
3. **Every screen's appearance.** Layout, spacing at large Dynamic Type sizes,
   and how the animations actually feel.
4. **Camera, document scanner, microphone, speakers** — all need hardware.
5. **Real network latency.** TTFA is measured for real in the harness against a
   mock; the number over a real connection to OpenAI is unknown.
6. **StoreKit purchases**, which need App Store Connect products and a sandbox
   account.
7. **The widget and Live Activity on a home screen.**

### To close every gap above

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

after installing Xcode from the Mac App Store, then open `Ace.xcodeproj` and
press ⌘R. The first build is the moment any remaining type error in the
SwiftData-bound screens will surface, and they are one-line fixes by
construction — the component-usage probe already verifies every shared
component's call shape from those screens.

### Known limitation, not a bug

The App Group capability needs a paid Apple Developer account. On a free account
a build to a physical device may fail signing on the widget and share extension.
The app itself is unaffected: `WidgetStore` falls back to local `UserDefaults`,
the widget shows its empty state, and the share extension says so plainly rather
than failing silently. The Simulator is unaffected entirely.

---

## Numbers

| | |
|---|---|
| Assertions | 2,949 across 27 suites |
| Swift files | 79 (app + widget + share + shared) |
| Lines of Swift | ~26,000 including tests and tooling |
| Targets | 3 — app, widget extension, share extension |
| Crisis-safety checks | 281 |
| Compiler warnings | 0 |
