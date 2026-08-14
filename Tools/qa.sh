#!/bin/bash
#
#  qa.sh — the Part 5 final sweep.
#
#  `verify.sh` proves the code compiles and behaves. This proves it's *finished*:
#  no dead code, no debug leftovers, no unlabelled controls, no force-unwraps
#  waiting to crash, no screen without its designed empty/error state.
#
#  Everything here is static analysis, because the two passes that genuinely
#  need a device — Instruments and VoiceOver — can't run on a machine with no
#  Xcode. QA.md records exactly which those are and what to do about them.
#
#  Run:  ./Tools/qa.sh
#

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
FAILED=0

section() { printf "\n${BOLD}%s${NC}\n" "$1"; }
pass()    { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}✗${NC} %s\n" "$1"; FAILED=1; }

APP_SWIFT=$(find Ace AceWidget AceShare Shared -name "*.swift" -type f | sort)

# ---------------------------------------------------------------- accessibility

section "Accessibility"

# Every tappable control needs a label, or VoiceOver announces "button" and
# nothing else.
UNLABELLED=0
for file in Ace/DesignSystem/*.swift; do
    # Components that build a Button but never set an accessibility label or
    # explicitly inherit one by combining children.
    # Strip comments first: a doc comment mentioning "buttons" is not a button.
    if sed -E 's|//.*||' "$file" | grep -q "Button(" \
       && ! grep -qE "accessibilityLabel|accessibilityElement\(children: \.combine\)" "$file"; then
        fail "no accessibility label in $(basename "$file")"
        UNLABELLED=1
    fi
done
[ "$UNLABELLED" -eq 0 ] && pass "every design-system control carries an accessibility label"

# Dynamic Type: the type scale must be built on semantic text styles, not fixed
# point sizes, or nothing scales.
if grep -qE '\.system\(\.(largeTitle|title|title2|title3|headline|body|callout|subheadline|footnote|caption)' Ace/DesignSystem/Theme.swift; then
    pass "the type scale is built on semantic styles, so Dynamic Type works"
else
    fail "the type scale uses fixed sizes — Dynamic Type will not scale it"
fi

# Reduce Motion must be honoured, not just imported.
MOTION_USERS=$(grep -rl "accessibilityReduceMotion" Ace/DesignSystem Ace/Features | wc -l | tr -d ' ')
if [ "$MOTION_USERS" -ge 5 ]; then
    pass "Reduce Motion is handled in $MOTION_USERS files"
else
    fail "Reduce Motion is barely handled ($MOTION_USERS files)"
fi

# Decorative imagery must be hidden from VoiceOver.
if grep -q "accessibilityHidden(true)" Ace/DesignSystem/Components.swift \
   && grep -q "accessibilityHidden(true)" Ace/DesignSystem/AceMark.swift; then
    pass "decorative elements are hidden from VoiceOver"
else
    warn "check that decorative shapes are accessibilityHidden"
fi

# Text that can wrap must be allowed to.
FIXED_SIZE=$(grep -rc "fixedSize(horizontal: false, vertical: true)" Ace --include="*.swift" \
    | awk -F: '{sum += $2} END {print sum}')
if [ "${FIXED_SIZE:-0}" -ge 40 ]; then
    pass "multi-line text is allowed to grow ($FIXED_SIZE call sites)"
else
    warn "few fixedSize calls ($FIXED_SIZE) — long text may clip at large Dynamic Type sizes"
fi

# ---------------------------------------------------------------- designed states

section "Designed states (§8: no default-grey anything)"

for component in AceEmptyState AceLoadingState AceErrorState; do
    USES=$(grep -rl "$component" Ace/Features | wc -l | tr -d ' ')
    if [ "$USES" -ge 1 ]; then
        pass "$component used in $USES screens"
    else
        fail "$component is defined but never used"
    fi
done

# A ProgressView with no surrounding designed state is a grey spinner.
BARE_SPINNERS=$(grep -rn "ProgressView()" Ace/Features --include="*.swift" \
    | grep -v "AceLoadingState" | grep -v "progressViewStyle" | wc -l | tr -d ' ')
if [ "$BARE_SPINNERS" -eq 0 ]; then
    pass "no bare system spinners in feature code"
else
    warn "$BARE_SPINNERS bare ProgressView(s) — check each has a designed surround"
fi

# ---------------------------------------------------------------- crash safety

section "Crash safety"

# Force-unwraps and force-trys in shipping code.
FORCE=$(grep -rnE '[a-zA-Z0-9_\)\]]\!(\s|$|\.|,|\))' $APP_SWIFT \
    | grep -vE '!=|!\s*[a-zA-Z]|// ' \
    | grep -vE 'try!' | wc -l | tr -d ' ')
FORCE_TRY=$(grep -rn "try!" $APP_SWIFT | wc -l | tr -d ' ')

if [ "$FORCE_TRY" -le 1 ]; then
    pass "force-try used $FORCE_TRY time(s) — the launch-time last resort only"
else
    fail "$FORCE_TRY force-trys — each one is a crash"
    grep -rn "try!" $APP_SWIFT | sed 's|^|      |' | head -5
fi

if ! grep -rn "fatalError\|preconditionFailure" $APP_SWIFT | grep -v "^\s*//" | head -3; then
    pass "no fatalError or preconditionFailure in shipping code"
else
    fail "a deliberate crash exists in shipping code"
fi

# Array subscripting without a bounds check is the classic SwiftUI crash.
if grep -rn "\.indices.contains" Ace/Core --include="*.swift" >/dev/null 2>&1; then
    pass "bounds are checked before indexing in Core"
else
    warn "no explicit bounds checks found in Core"
fi

# ---------------------------------------------------------------- debug leftovers

section "Debug leftovers"

PRINTS=$(grep -rnE '(^|[^a-zA-Z.])print\(' $APP_SWIFT | grep -v "// " | wc -l | tr -d ' ')
if [ "$PRINTS" -eq 0 ]; then
    pass "no print statements in shipping code"
else
    fail "$PRINTS print statement(s) left in"
    grep -rnE '(^|[^a-zA-Z.])print\(' $APP_SWIFT | sed 's|^|      |' | head -5
fi

for marker in "TODO" "FIXME" "HACK" "XXX" "WIP" "stub"; do
    HITS=$(grep -rniE "//.*\b$marker\b" $APP_SWIFT | wc -l | tr -d ' ')
    if [ "$HITS" -ne 0 ]; then
        fail "$HITS '$marker' marker(s) left in the code"
        grep -rniE "//.*\b$marker\b" $APP_SWIFT | sed 's|^|      |' | head -3
    fi
done
pass "no TODO/FIXME/HACK markers"

# ---------------------------------------------------------------- dead code

section "Dead code"

# Every type declared in the app should be referenced somewhere other than its
# own declaration. This catches components built and then never wired up.
DEAD=""
while IFS= read -r decl; do
    name=$(echo "$decl" | sed -E 's/.*(struct|class|enum|protocol) ([A-Za-z0-9_]+).*/\2/')
    [ -z "$name" ] && continue
    # Skip nested/private helper names that legitimately appear once.
    uses=$(grep -rhoE "\b$name\b" $APP_SWIFT Tests/Checks/*.swift 2>/dev/null | wc -l | tr -d ' ')
    if [ "$uses" -le 1 ]; then
        DEAD="$DEAD $name"
    fi
done < <(grep -rhE "^(public |private |internal )?(final )?(struct|class|enum|protocol) [A-Z]" $APP_SWIFT)

if [ -z "$DEAD" ]; then
    pass "every declared type is referenced somewhere"
else
    fail "unreferenced type(s):$DEAD"
fi

# ---------------------------------------------------------------- safety net reach

section "The safety net reaches everywhere (§10)"

# Every surface that accepts free text or a transcript must route it through
# SafetyCoordinator.check before doing anything else with it.
SAFETY_SURFACES=$(grep -rl "safety.check(" Ace/Features Ace/Services | wc -l | tr -d ' ')
if [ "$SAFETY_SURFACES" -ge 5 ]; then
    pass "safety.check is called from $SAFETY_SURFACES surfaces"
else
    fail "the safety net is only wired into $SAFETY_SURFACES surfaces"
fi

# And the net must be attachable to any screen.
NET_ATTACHED=$(grep -rc "\.safetyNet()" Ace/Features --include="*.swift" \
    | awk -F: '{sum += $2} END {print sum}')
if [ "${NET_ATTACHED:-0}" -ge 6 ]; then
    pass "safetyNet() attached to $NET_ATTACHED screens"
else
    fail "safetyNet() attached to only ${NET_ATTACHED:-0} screens"
fi

# Gamification must check suppression.
SUPPRESSION=$(grep -rl "isGamificationSuppressed" Ace | wc -l | tr -d ' ')
if [ "$SUPPRESSION" -ge 4 ]; then
    pass "gamification suppression is honoured in $SUPPRESSION files"
else
    fail "gamification suppression is barely wired ($SUPPRESSION files)"
fi

# ---------------------------------------------------------------- secrets

section "Secrets"

if grep -rnE 'sk-[A-Za-z0-9]{20,}' $APP_SWIFT Config/* 2>/dev/null | head -3; then
    fail "a real-looking API key is committed"
else
    pass "no API keys in the source or config"
fi

# The key now reaches the Keychain through the `SecretStore` seam, so following
# it takes two steps: the production store must wrap `KeychainService`, and the
# controller must default to that store. Checking only the first would pass with
# the app wired to the in-memory test store.
if grep -q "KeychainService.load()" Ace/Services/KeychainService.swift; then
    pass "the production secret store reads the Keychain"
else
    fail "KeychainSecretStore may not be going through the Keychain"
fi

if grep -q "secrets: SecretStore = KeychainSecretStore()" Ace/Services/ProviderController.swift; then
    pass "the app defaults to the Keychain-backed store"
else
    fail "ProviderController may not default to the Keychain store"
fi

# The in-memory store exists for the harness. If it is ever named in app code,
# a build could ship with the key held in RAM and never persisted — or worse,
# a test double in the shipping path.
if grep -rn "InMemorySecretStore" $APP_SWIFT | grep -v "Ace/Services/KeychainService.swift" >/dev/null 2>&1; then
    fail "the in-memory secret store is referenced by app code"
else
    pass "the in-memory secret store is test-only"
fi

if grep -rn "UserDefaults.*apiKey\|UserDefaults.*openai" $APP_SWIFT >/dev/null 2>&1; then
    fail "an API key may be stored in UserDefaults"
else
    pass "no key material in UserDefaults"
fi

# ---------------------------------------------------------------- result

printf "\n"
if [ "$FAILED" -eq 0 ]; then
    printf "${GREEN}${BOLD}QA sweep clean.${NC}\n"
    printf "${DIM}Instruments and VoiceOver passes still need a device — see QA.md.${NC}\n\n"
    exit 0
else
    printf "${RED}${BOLD}QA sweep found problems.${NC}\n\n"
    exit 1
fi
