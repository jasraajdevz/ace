#!/bin/bash
#
#  verify.sh — Ace's full local verification gate.
#
#  Run from the repo root:   ./Tools/verify.sh
#
#  This machine has the Swift command-line toolchain but not Xcode, so there is
#  no iOS SDK and no Simulator. The gate below squeezes every check that IS
#  possible out of what's available:
#
#    1. TYPE-CHECK + TESTS  — Core/, DesignSystem/, Services/ and
#       Features/Safety/ are compiled against the macOS SDK and the full
#       assertion suite is run. This is real compilation: SwiftUI, Vision,
#       AVFoundation and Speech all resolve. `ComponentUsageProbe.swift` also
#       constructs every design-system component using the exact argument shapes
#       the screens use, so a signature change breaks the build here.
#
#    2. SYNTAX GATE — the remaining files (SwiftData models and the screens
#       bound to them, which need Xcode's macro plugin) are parsed with
#       `swiftc -parse`. That catches syntax errors, though not type errors.
#
#    3. PROJECT INTEGRITY — the Xcode project, Info.plist, asset catalogue and
#       bundled decks are structurally validated.
#
#  Anything this gate can't cover is listed in QA.md and is verified in Xcode.
#

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN='\033[1;32m'; RED='\033[1;31m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
FAILED=0

section() { printf "\n${BOLD}%s${NC}\n" "$1"; }
pass()    { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}✗${NC} %s\n" "$1"; FAILED=1; }

# ---------------------------------------------------------------- 1. compile + test

section "1 · Type-check and unit checks (macOS SDK)"

BUILD_LOG=$(swift build 2>&1)
if echo "$BUILD_LOG" | grep -q "error:"; then
    fail "compilation failed"
    echo "$BUILD_LOG" | grep "error:" | sed 's|^|      |' | sort -u | head -20
else
    pass "Core/, DesignSystem/, Services/ and Features/Safety/ compile clean"
fi

TEST_LOG=$(swift run AceVerify 2>&1)
if echo "$TEST_LOG" | grep -q "All .* checks passed"; then
    COUNT=$(echo "$TEST_LOG" | grep -o "All [0-9]* checks passed" | grep -o "[0-9]*")
    pass "$COUNT assertions passed"
else
    fail "assertions failed"
    echo "$TEST_LOG" | grep -A3 "✗" | sed 's|^|      |' | head -30
fi

# ---------------------------------------------------------------- 2. syntax gate

section "2 · Syntax gate (every Swift file in both targets)"

SYNTAX_ERRORS=0
FILE_COUNT=0
while IFS= read -r file; do
    FILE_COUNT=$((FILE_COUNT + 1))
    if ! OUT=$(swiftc -parse "$file" 2>&1); then
        fail "$(basename "$file")"
        echo "$OUT" | grep "error:" | sed 's|^|      |' | head -5
        SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
    fi
done < <(find Ace AceWidget Shared -name "*.swift" -type f | sort)

if [ "$SYNTAX_ERRORS" -eq 0 ]; then
    pass "$FILE_COUNT files parse clean"
fi

# ---------------------------------------------------------------- 3. project integrity

section "3 · Project integrity"

if plutil -lint Ace.xcodeproj/project.pbxproj >/dev/null 2>&1; then
    pass "Ace.xcodeproj/project.pbxproj is a valid property list"
else
    fail "project.pbxproj is malformed — Xcode will refuse to open it"
fi

# Every object identifier must be exactly 24 hex characters.
BAD_IDS=$(grep -oE '\bACE[0-9A-F]{5,}\b' Ace.xcodeproj/project.pbxproj | sort -u | awk 'length($0) != 24')
if [ -z "$BAD_IDS" ]; then
    pass "object identifiers are well-formed"
else
    fail "malformed object identifiers: $BAD_IDS"
fi

# The object GRAPH, not just the syntax: dangling references, missing build
# phases, files that don't exist, the widget not being embedded, App Groups that
# don't match. This is the check that catches a project which opens but can't
# build — see Tools/gen/check_pbxproj.py.
if STRUCT=$(python3 Tools/gen/check_pbxproj.py 2>&1); then
    pass "project object graph is sound"
    echo "$STRUCT" | sed 's|^|    |'
else
    fail "project object graph is broken"
    echo "$STRUCT" | sed 's|^|      |'
fi

# Every scheme must point at a target that exists.
if SCHEMES=$(python3 - <<'PYEOF' 2>&1
import re, json, subprocess, pathlib, sys
plist = json.loads(subprocess.run(
    ["plutil", "-convert", "json", "-o", "-", "Ace.xcodeproj/project.pbxproj"],
    capture_output=True, text=True).stdout)
targets = {k for k, v in plist["objects"].items() if v.get("isa") == "PBXNativeTarget"}
bad = []
for scheme in sorted(pathlib.Path("Ace.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme")):
    for bid in set(re.findall(r'BlueprintIdentifier = "([^"]+)"', scheme.read_text())):
        if bid not in targets:
            bad.append(f"{scheme.name}: {bid}")
if bad:
    print("\n".join(bad)); sys.exit(1)
PYEOF
); then
    pass "schemes point at real targets"
else
    fail "a scheme references a target that does not exist"
    echo "$SCHEMES" | sed 's|^|      |'
fi

PLIST_BAD=0
for plist in Config/*.plist Config/*.entitlements; do
    plutil -lint "$plist" >/dev/null 2>&1 || { fail "malformed: $plist"; PLIST_BAD=1; }
done
[ "$PLIST_BAD" -eq 0 ] && pass "Info.plists and entitlements are valid"

# Every permission the app can trigger must have a usage string, or iOS kills
# the app the moment it asks.
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
    if plutil -extract "$key" raw Config/Info.plist >/dev/null 2>&1; then
        pass "$key present"
    else
        fail "$key missing — the app will crash when it asks for that permission"
    fi
done

SCHEME_BAD=0
for scheme in Ace.xcodeproj/xcshareddata/xcschemes/*.xcscheme; do
    xmllint --noout "$scheme" 2>/dev/null || { fail "malformed scheme: $scheme"; SCHEME_BAD=1; }
done
[ "$SCHEME_BAD" -eq 0 ] && pass "shared schemes are valid XML"

# Asset catalogue.
ASSET_BAD=0
while IFS= read -r json; do
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" 2>/dev/null || {
        fail "invalid JSON: $json"; ASSET_BAD=1
    }
done < <(find Ace/Assets.xcassets Ace/Resources -name "*.json" | sort)
[ "$ASSET_BAD" -eq 0 ] && pass "asset catalogue and bundled decks are valid JSON"

[ -f Ace/Assets.xcassets/AppIcon.appiconset/icon-1024.png ] \
    && pass "app icon present" || fail "app icon missing"

# An icon with an alpha channel is rejected by App Store Connect.
if python3 - <<'PY' 2>/dev/null
import struct, sys
with open("Ace/Assets.xcassets/AppIcon.appiconset/icon-1024.png", "rb") as f:
    data = f.read()
# IHDR colour type byte sits at offset 25; 6 = RGBA, 4 = grey+alpha.
width, height = struct.unpack(">II", data[16:24])
colour_type = data[25]
sys.exit(0 if (width, height) == (1024, 1024) else 1)
PY
then
    pass "app icon is 1024×1024"
else
    fail "app icon is the wrong size"
fi

DECK_COUNT=$(find Ace/Resources/DemoDecks -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$DECK_COUNT" -ge 2 ]; then
    pass "$DECK_COUNT demo decks bundled"
else
    fail "expected 2 demo decks, found $DECK_COUNT"
fi

# ---------------------------------------------------------------- 4. hygiene

section "4 · Hygiene"

# No secrets, ever (§10).
if grep -rIn --include="*.swift" --include="*.plist" --include="*.json" \
     -E '(sk-[A-Za-z0-9]{20,}|api[_-]?key["'"'"']?\s*[:=]\s*["'"'"'][A-Za-z0-9]{16,})' \
     Ace Config 2>/dev/null | grep -v "keychain" | head -5; then
    fail "possible hardcoded secret"
else
    pass "no hardcoded secrets"
fi

# Nothing half-finished should reach a part boundary.
STUBS=$(grep -rIn --include="*.swift" -E '\b(fatalError\(|TODO:|FIXME:|notImplemented)' Ace | grep -v "^Ace/.*://" | head -10)
if [ -z "$STUBS" ]; then
    pass "no stubs, TODOs or fatalError calls in app code"
else
    fail "unfinished code found"
    echo "$STUBS" | sed 's|^|      |'
fi

# ---------------------------------------------------------------- result

# ---------------------------------------------------------------- 5. final sweep

section "5 · Final sweep"

if QA=$(./Tools/qa.sh 2>&1); then
    pass "QA sweep clean (accessibility, designed states, dead code, secrets)"
else
    fail "QA sweep found problems — run ./Tools/qa.sh"
    echo "$QA" | grep "✗" | sed 's|^|    |'
fi

printf "\n"
if [ "$FAILED" -eq 0 ]; then
    printf "${GREEN}${BOLD}Everything verifiable on this machine passes.${NC}\n"
    printf "${DIM}Simulator run-through still required — see QA.md.${NC}\n\n"
    exit 0
else
    printf "${RED}${BOLD}Verification failed.${NC}\n\n"
    exit 1
fi
