#!/usr/bin/env python3
"""
harness_data.py — type-check AND run the SwiftData-bound app without Xcode.

The problem this solves: `@Model` is a compiler-plugin macro that ships inside
Xcode. On a machine with only the Swift command-line tools, every file using it
can be parsed but never type-checked — which left the persistence layer as the
one place with real logic and no compile behind it (DECISIONS.md D1).

The approach: copy the affected files to a scratch directory, mechanically strip
the macro attributes, and compile the copies against `swiftdata_shim.swift`
alongside the real `Core/`, `DesignSystem/` and `Services/` sources.

That yields a genuine type-check of every property access, method signature and
generic constraint in those files.

With `--run` it goes further: the shim is a working in-memory store, so the
persistence *logic* is executed rather than merely compiled — see
`Tests/Persistence/PersistenceChecks.swift`.

Honest about what it does NOT prove:
  • that the real `@Model` macro expands the way the shim models it
  • that the SwiftData schema is valid at runtime
  • that the SwiftUI screens LAY OUT correctly, or that iOS-only modifiers
    behave as intended — only that every call in them resolves and type-checks

Run:  python3 Tools/gen/harness_data.py          # type-check only
      python3 Tools/gen/harness_data.py --run    # type-check, then execute
"""

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Everything that is SwiftData-bound and therefore uncheckable as it stands —
# which, with the SwiftUI half of the shim in place, is the entire remaining app.
TARGET_FILES = [
    "Ace/Data/Models.swift",
    "Ace/Data/Stores.swift",
    "Ace/Data/SessionRecorder.swift",
    "Ace/Services/ShareImporter.swift",
    "Ace/AceApp.swift",
]

TARGET_DIRS = [
    "Ace/Features/Home",
    "Ace/Features/Capture",
    "Ace/Features/Settings",
    "Ace/Features/Study",
    "Ace/Features/Presence",
    "Ace/Features/Onboarding",
]

# Real sources compiled alongside, so the check sees the actual types the
# persistence layer talks to rather than more stand-ins.
REAL_SOURCE_DIRS = [
    "Ace/Core",
    "Ace/DesignSystem",
    "Ace/Services",
    "Ace/Features/Safety",   # ConcernBanner, CrisisSupportView, .safetyNet()
    "Shared",
]

# Services that are themselves SwiftData-bound must not be included twice.
EXCLUDE_FROM_REAL = {"ShareImporter.swift"}


def strip_macros(source: str, drop_main: bool = False) -> str:
    """Remove the macro attributes the plugin would otherwise expand.

    Deliberately conservative: it only removes attributes, never rewrites logic,
    so a type error in the surrounding code survives the transform intact.

    `drop_main` removes `@main` from `AceApp`. In run mode the harness supplies
    its own entry point, and `@main` cannot coexist with top-level code — but
    the struct still compiles and is still worth type-checking.
    """
    if drop_main:
        source = re.sub(r"^@main\s*$", "// @main (harness supplies the entry point)",
                        source, flags=re.MULTILINE)

    # `@Model` → `@Observable`. The shim's PersistentModel requires Observable,
    # and this keeps `@Bindable` usage honest.
    source = re.sub(r"^@Model\b", "@Observable", source, flags=re.MULTILINE)

    # `@Attribute(.unique)` / `@Attribute(.externalStorage)` — property options
    # with no bearing on types.
    source = re.sub(r"@Attribute\([^)]*\)\s*", "", source)

    # `@Relationship(deleteRule: .cascade, inverse: \Foo.bar)` — the inverse key
    # path references a property the shim doesn't model.
    source = re.sub(r"@Relationship\((?:[^()]|\([^()]*\))*\)\s*", "", source)

    # Swap the framework import for the shim's types, which live in the same
    # module here.
    source = re.sub(r"^import SwiftData\s*$", "// import SwiftData (shimmed)",
                    source, flags=re.MULTILINE)

    # The `@Observable` macro IS available (it's in the toolchain), so make sure
    # Observation is imported wherever a model now needs it.
    if "@Observable" in source and "import Observation" not in source:
        source = source.replace("import Foundation", "import Foundation\nimport Observation", 1)

    # Conformance to PersistentModel is what the real macro adds; add it so the
    # generic constraints on ModelContext actually bind.
    source = re.sub(
        r"^(@Observable\nfinal class )([A-Za-z0-9_]+)( \{)",
        r"\1\2: PersistentModel\3",
        source,
        flags=re.MULTILINE,
    )
    return source


# The headless persistence suite, compiled in only for `--run`.
HARNESS_DIR = "Tests/Persistence"
# The assertion helper the suites use, shared with the SPM verification target.
HARNESS_SUPPORT = ["Tests/Checks/CheckHarness.swift"]


def main() -> int:
    should_run = "--run" in sys.argv
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="ace-harness-"))
    try:
        sources: list[pathlib.Path] = []

        # 1. The shim.
        shim = scratch / "SwiftDataShim.swift"
        shutil.copy(ROOT / "Tools" / "gen" / "swiftdata_shim.swift", shim)
        sources.append(shim)

        # 2. The stripped targets.
        targets = [ROOT / rel for rel in TARGET_FILES]
        for directory in TARGET_DIRS:
            targets += sorted((ROOT / directory).glob("*.swift"))

        stripped_count = 0
        for path in targets:
            if not path.exists():
                print(f"    ! target missing: {path}")
                continue
            out = scratch / path.name
            out.write_text(strip_macros(path.read_text(),
                                        drop_main=should_run and path.name == "AceApp.swift"))
            sources.append(out)
            stripped_count += 1

        # 3. The real sources they depend on. `Features/Safety` is already
        #    compiled by the SPM harness, so it comes in as a real source here.
        real_count = 0
        for directory in REAL_SOURCE_DIRS:
            for path in sorted((ROOT / directory).rglob("*.swift")):
                if path.name in EXCLUDE_FROM_REAL:
                    continue
                sources.append(path)
                real_count += 1

        # 4. For `--run`, add the persistence suite and its assertion helper.
        #    `CheckHarness.swift` declares `AllChecks`, which references suites
        #    that aren't compiled here, so only the `CheckRun`/`CheckSuite` half
        #    is taken.
        if should_run:
            support = (ROOT / HARNESS_SUPPORT[0]).read_text()
            support = support.split("/// Everything the verifier executes.")[0]
            (scratch / "CheckHarness.swift").write_text(support)
            sources.append(scratch / "CheckHarness.swift")
            for path in sorted((ROOT / HARNESS_DIR).glob("*.swift")):
                sources.append(path)

        # 5. Type-check the lot. `-typecheck` skips codegen, which is all we need
        #    and roughly twice as fast.
        binary = scratch / "ace-persistence"
        mode = ["-o", str(binary)] if should_run else ["-typecheck"]

        result = subprocess.run(
            ["swiftc", "-swift-version", "5"] + mode + [
             # The screens use iOS-only SwiftUI (`fullScreenCover`,
             # `.topBarLeading`, `navigationBarTitleDisplayMode`). Disabling the
             # availability checker keeps the REAL SwiftUI declarations — and
             # therefore real signature checking — while dropping the
             # "unavailable in macOS" complaints, which are true here and
             # irrelevant to the iOS build.
             #
             # This is strictly safer than shimming those modifiers ourselves: a
             # hand-written stand-in with a subtly wrong signature would let a
             # broken call site pass here and fail in Xcode.
             "-Xfrontend", "-disable-availability-checking"] + [str(p) for p in sources],
            capture_output=True, text=True, cwd=scratch,
        )

        errors = [
            line for line in result.stderr.splitlines()
            if ": error:" in line and "SwiftDataShim.swift" not in line
        ]

        if errors:
            print(f"    ✗ {len(errors)} type error(s):")
            for line in errors[:15]:
                # Report against the real path, not the scratch copy.
                cleaned = re.sub(r"^.*/([A-Za-z0-9_]+\.swift)", r"\1", line)
                print(f"      {cleaned}")
            return 1

        print(f"    {stripped_count} SwiftData-bound files type-checked "
              f"against {real_count} real sources")

        if not should_run:
            return 0

        # 6. Execute the persistence suite against the in-memory store.
        run = subprocess.run([str(binary)], capture_output=True, text=True, cwd=scratch)
        print(run.stdout.rstrip())
        if run.returncode != 0:
            if run.stderr.strip():
                print(run.stderr.rstrip())
            return 1
        return 0

    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
