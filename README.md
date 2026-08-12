# Ace

**A voice-first AI study companion for iOS.** Point it at a worksheet, a textbook
page or a screenshot — it reads the page, then teaches you through it out loud
like a tutor would: with questions and hints, not answers.

This README is written for someone who has never opened Xcode. Follow it top to
bottom.

---

## What's here right now (Parts 1–2 of 5)

- **Onboarding** — name, year, subjects, and a voice you pick by listening to it
- **Capture** — scan a document, take a photo, pick from your library, or paste
  text → on-device OCR → cleaned, editable study material
- **Talk it through** — a Socratic tutor grounded in *your* page. It asks before
  it answers, hints one rung at a time, and refuses to make things up
- **Quiz me** — multiple choice with plausible distractors, a hint ladder, and a
  results screen whose main button redoes only the ones you missed
- **Flashcards** — spaced repetition, a card that flips, and forgotten cards that
  come back before the session ends
- **Progression** — XP for effort (not just for being right), levels, a streak
  with a free repair, and a level-up worth screen-recording
- **Home-screen widget** — small and medium: level, streak, and one warm nudge
- **The crisis safety net** — always on, everywhere, with 249 dedicated checks
- **Two bundled demo decks** so the app has something real in it on first launch

Everything runs with **no account, no API key, and no network**.

Coming in Parts 3–5: live realtime voice over WebRTC, the study-companion and
guardian features, and Anywhere Mode.

---

## 1 · Install Xcode

**You need Xcode to run this.** It's free, it's about 15 GB, and it takes a
while.

1. Open the **App Store** on your Mac.
2. Search for **Xcode** and install it.
3. When it finishes, **open Xcode once** and accept the license prompt. It will
   install some extra components — let it.
4. Then run this in Terminal so the command-line tools point at Xcode rather
   than the standalone tools:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

You only ever do this once.

## 2 · Open the project

```bash
open ~/Downloads/ace/Ace.xcodeproj
```

## 3 · Run it

1. At the top of the Xcode window there's a device dropdown. Pick any
   **iPhone 16** simulator.
2. Press **⌘R** (or the ▶ button).
3. First build takes a minute or two. After that it's seconds.

That's it — no key, no sign-in. The app is fully usable.

> **Camera and document scanning don't work in the Simulator** — there's no
> camera. Use **Paste text** or **From your photos** to try the capture flow
> there, or run on a real iPhone (step 5) to use the scanner.

## 4 · Try this first

1. Go through onboarding — **tap each voice** to hear it.
2. On the home screen you'll already find two demo decks. Open **How Plants Make
   Food** and tap **Quiz me** to see the whole loop in about a minute.
3. Then add your own: **Add something to study ▸ Paste text**, and paste a few
   paragraphs from anything you're actually working on.
4. On that material, try **Talk it through** and type "I don't know" — watch Ace
   point you at a real line from your page instead of lecturing.
5. Ask it something that *isn't* on the page. It will tell you so rather than
   inventing an answer. That refusal is the whole design.

### Adding the widget

Long-press your home screen ▸ **+** ▸ search **Ace** ▸ add the small or medium
one. It updates the moment your XP or streak changes.

> On a **free** Apple ID, App Groups aren't provisioned, so a build to a physical
> device may fail signing on the widget. Two options: run in the Simulator
> (everything works), or in Xcode select the **AceWidgetExtension** target ▸
> **Signing & Capabilities** ▸ remove **App Groups**. The app itself is
> unaffected — the widget just shows its empty state.

## 5 · Run on your own iPhone (optional)

You need a free Apple ID. No paid developer account.

1. In Xcode: **Xcode ▸ Settings ▸ Accounts ▸ +** and sign in with your Apple ID.
2. Click the blue **Ace** at the top of the left sidebar → **Signing &
   Capabilities** tab.
3. Tick **Automatically manage signing**, then pick your name under **Team**.
4. Change the **Bundle Identifier** to something unique to you, e.g.
   `com.yourname.Ace`.
5. Plug in your iPhone, pick it in the device dropdown, press **⌘R**.
6. On the phone: **Settings ▸ General ▸ VPN & Device Management** → trust your
   developer certificate.

---

## Where the OpenAI key goes (Part 3)

**You don't need one and nothing is blocked without one.** Ace ships in **Demo
Mode**: voice from the system speech synthesiser, reading from Apple's on-device
Vision framework, quizzes and flashcards from local text analysis. Free, private,
works on a plane.

In Part 3, **Settings ▸ How Ace runs** gains a key field and a Demo → Live
toggle. The key will be stored in the **iOS Keychain** — never in the code,
never in this repo, never in a file. There is nothing to paste anywhere today.

The seam that makes this possible is `AIProvider`
([Ace/Core/AI/AIProvider.swift](Ace/Core/AI/AIProvider.swift)) — one protocol
covering every AI capability, with two implementations behind it. No screen in
the app knows which one is running.

---

## Making Ace sound better (30 seconds, big difference)

Demo Mode uses Apple's built-in voices, and the ones preinstalled are the low-
quality "compact" versions. Downloading a good one transforms how Ace sounds:

**Settings ▸ Accessibility ▸ Spoken Content ▸ Voices ▸ English ▸ English (US)**
→ pick any voice marked **Enhanced** or **Premium** and tap the download icon.

Ace finds and uses the best installed voice automatically. It also tells you to
do this in its own Settings screen if it can't find one.

---

## Running the checks

There's a full verification suite that runs **without Xcode**:

```bash
cd ~/Downloads/ace && ./Tools/verify.sh
```

It compiles the logic layers against the macOS SDK, runs 1,584 assertions,
parses every Swift file in both targets, and validates the Xcode project's whole
object graph — dangling references, missing build phases, whether the app
actually embeds the widget, whether the App Group matches on both sides. It
takes a few seconds.

To run just the assertions:

```bash
cd ~/Downloads/ace && swift run AceVerify
```

To regenerate the app icon or the demo decks after changing them:

```bash
cd ~/Downloads/ace && swift Tools/gen/make_icon.swift && swift run AceVerify --make-demo-decks
```

The Xcode project file is generated too, so adding a target is an edit to a
script rather than surgery on a 400-line plist:

```bash
cd ~/Downloads/ace && python3 Tools/gen/build_pbxproj.py && python3 Tools/gen/check_pbxproj.py
```

---

## How the code is laid out

```
Ace/
├── Core/            Pure Swift. No SwiftUI, no UIKit, no database.
│   ├── Safety/      The crisis net (§10) — the most tested code here
│   ├── AI/          The AIProvider protocol, Socratic engine, mood heuristics
│   ├── Study/       Quiz + flashcard generation, XP, levels, streaks, SRS
│   ├── Text/        OCR cleanup and phrase splitting
│   └── Model/       Value types: grade levels, subjects, moods, voices
├── DesignSystem/    Every colour, font, spacing, curve, haptic and sound
├── Data/            SwiftData models — storage only, no logic
├── Services/        Vision OCR, speech, and the keyless MockAIProvider
├── Features/        The screens
└── Resources/       The two bundled demo decks

AceWidget/           The home-screen widget (its own target)
Shared/              WidgetSnapshot.swift — compiled into BOTH targets
Config/              Info.plists, entitlements, permission strings
Tests/Checks/        The assertion suite
Tools/               verify.sh, the icon generator, the project generator
```

**The rule that shapes all of it:** logic lives in `Core/` and is testable
without a simulator; `Features/` draws it. That's why 1,227 checks can run on a
machine with no Xcode installed at all.

---

## A note on the safety net

If a student types or says something suggesting self-harm, Ace stops being a
study app immediately: no XP, no streak, no quiz, no hype. It responds with
warmth and shows real, region-appropriate crisis lines (in the US: **call or
text 988**, and **text HOME to 741741**).

That behaviour is in [Ace/Core/Safety/CrisisSafety.swift](Ace/Core/Safety/CrisisSafety.swift),
it is deliberately simple enough to read end to end, and it has 249 dedicated
checks — including a suite that makes sure a history essay about the Somme or a
literature question about Macbeth never triggers it.

It reaches everywhere: once it fires, XP, streaks, quiz scores and the level-up
celebration are all suppressed for the rest of that session, and the results
screen shows no numbers at all. Dismissing it does not switch them back on.

---

## Companion documents

- [DECISIONS.md](DECISIONS.md) — every judgement call made along the way, and why
- `QA.md` — arrives with Part 5
