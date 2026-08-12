#!/usr/bin/env python3
"""
check_pbxproj.py — structural validation of Ace.xcodeproj.

`plutil -lint` proves the project file *parses*. It says nothing about whether
the object graph makes sense — and a project that parses but references a
missing object is a project that opens in Xcode and immediately fails to build,
which is exactly the failure mode this machine can't otherwise catch
(DECISIONS.md D1).

So this converts the pbxproj to JSON and checks the graph the way Xcode would:

  • every referenced object id resolves to a real object
  • every target has the build phases its product type requires
  • every file reference points at a file that exists on disk
  • the app embeds the widget, and depends on it (or the widget builds after
    the app and gets embedded stale)
  • entitlements, Info.plists and bundle ids are consistent
  • the shared file is compiled into both targets

Run:  python3 Tools/gen/check_pbxproj.py
"""

import json
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PBXPROJ = ROOT / "Ace.xcodeproj" / "project.pbxproj"

errors: list[str] = []
notes: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


def load() -> dict:
    """pbxproj is an OpenStep plist; plutil converts it to something parseable."""
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(PBXPROJ)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"✗ project.pbxproj is not a valid property list:\n{result.stderr}")
        sys.exit(1)
    return json.loads(result.stdout)


def main() -> int:
    plist = load()
    objects = plist.get("objects", {})
    if not objects:
        fail("no objects in the project")
        return report()

    root_id = plist.get("rootObject")
    if root_id not in objects:
        fail("rootObject does not resolve")
        return report()

    # ---- every id-shaped reference must resolve -------------------------------
    #
    # Walk the whole tree and check any 24-hex-char string that looks like an
    # object id. A dangling reference is the single most common way a
    # hand-written pbxproj breaks.
    def is_object_id(value) -> bool:
        return (isinstance(value, str) and len(value) == 24
                and all(c in "0123456789ABCDEFabcdef" for c in value))

    def walk(node, path: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{path}[{index}]")
        elif is_object_id(node) and node not in objects:
            fail(f"dangling reference {node} at {path}")

    for oid, obj in objects.items():
        walk(obj, oid)

    # ---- objects by type --------------------------------------------------------
    def of_type(isa: str) -> dict:
        return {k: v for k, v in objects.items() if v.get("isa") == isa}

    targets = of_type("PBXNativeTarget")
    file_refs = of_type("PBXFileReference")
    build_files = of_type("PBXBuildFile")

    names = {t["name"] for t in targets.values()}
    for expected in ("Ace", "AceWidgetExtension"):
        if expected not in names:
            fail(f"missing target “{expected}”")

    app = next((t for t in targets.values() if t["name"] == "Ace"), None)
    widget = next((t for t in targets.values() if t["name"] == "AceWidgetExtension"), None)
    if not app or not widget:
        return report()

    app_id = next(k for k, v in targets.items() if v["name"] == "Ace")
    widget_id = next(k for k, v in targets.items() if v["name"] == "AceWidgetExtension")

    # ---- product types ------------------------------------------------------------
    if app["productType"] != "com.apple.product-type.application":
        fail(f"app has the wrong product type: {app['productType']}")
    if widget["productType"] != "com.apple.product-type.app-extension":
        fail(f"widget has the wrong product type: {widget['productType']}")

    # ---- required build phases -------------------------------------------------------
    def phases(target) -> dict:
        return {objects[p]["isa"]: objects[p] for p in target["buildPhases"]}

    app_phases = phases(app)
    widget_phases = phases(widget)

    for isa in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"):
        if isa not in app_phases:
            fail(f"app is missing a {isa}")
        if isa not in widget_phases:
            fail(f"widget is missing a {isa}")

    # ---- the app must embed the widget ------------------------------------------------
    embed = app_phases.get("PBXCopyFilesBuildPhase")
    if not embed:
        fail("app has no copy-files phase — the widget would never be embedded")
    else:
        if str(embed.get("dstSubfolderSpec")) != "13":
            fail(f"embed phase targets the wrong folder ({embed.get('dstSubfolderSpec')}, want 13 = PlugIns)")
        embedded = {objects[bf]["fileRef"] for bf in embed.get("files", [])}
        if widget["productReference"] not in embedded:
            fail("the widget product is not in the app's embed phase")

    # ---- and depend on it, so build order is right -------------------------------------
    deps = [objects[d] for d in app.get("dependencies", [])]
    if not any(d.get("target") == widget_id for d in deps):
        fail("app does not depend on the widget target — it could embed a stale build")
    for dep in deps:
        proxy_id = dep.get("targetProxy")
        proxy = objects.get(proxy_id, {})
        if proxy.get("remoteGlobalIDString") != dep.get("target"):
            fail("target dependency proxy points at the wrong target")

    # ---- the shared file must be in BOTH targets ----------------------------------------
    def sources_refs(target_phases) -> set:
        phase = target_phases.get("PBXSourcesBuildPhase", {})
        return {objects[bf]["fileRef"] for bf in phase.get("files", [])}

    shared_ref = next(
        (k for k, v in file_refs.items() if v.get("path") == "WidgetSnapshot.swift"), None
    )
    if not shared_ref:
        fail("WidgetSnapshot.swift has no file reference")
    else:
        if shared_ref not in sources_refs(app_phases):
            fail("WidgetSnapshot.swift is not compiled into the app")
        if shared_ref not in sources_refs(widget_phases):
            fail("WidgetSnapshot.swift is not compiled into the widget")

    # Every widget source must actually be in the widget's Sources phase.
    widget_sources = sources_refs(widget_phases)
    for name in ("AceWidget.swift", "AceWidgetBundle.swift", "AceWidgetViews.swift"):
        ref = next((k for k, v in file_refs.items() if v.get("path") == name), None)
        if not ref:
            fail(f"{name} has no file reference")
        elif ref not in widget_sources:
            fail(f"{name} is not compiled into the widget")

    # ---- no duplicate compilation ----------------------------------------------------------
    for target_name, target_phases in (("app", app_phases), ("widget", widget_phases)):
        phase = target_phases.get("PBXSourcesBuildPhase", {})
        refs = [objects[bf]["fileRef"] for bf in phase.get("files", [])]
        if len(refs) != len(set(refs)):
            fail(f"{target_name} compiles the same file twice")

    # ---- every file reference must exist on disk ---------------------------------------------
    #
    # Resolves the group hierarchy to build each reference's real path.
    groups = of_type("PBXGroup")
    parent_path: dict[str, str] = {}

    def resolve(group_id: str, prefix: str) -> None:
        group = groups.get(group_id)
        if not group:
            return
        here = prefix
        if group.get("path"):
            here = str(pathlib.PurePosixPath(prefix) / group["path"]) if prefix else group["path"]
        for child in group.get("children", []):
            if child in groups:
                resolve(child, here)
            else:
                parent_path[child] = here

    root = objects[root_id]
    resolve(root["mainGroup"], "")

    for ref_id, ref in file_refs.items():
        if ref.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            continue                                   # produced by the build
        prefix = parent_path.get(ref_id, "")
        path = pathlib.PurePosixPath(prefix) / ref["path"] if prefix else pathlib.PurePosixPath(ref["path"])
        if not (ROOT / path).exists():
            fail(f"file reference points at something that isn't there: {path}")

    # ---- synchronised folder groups -------------------------------------------------------------
    synced = of_type("PBXFileSystemSynchronizedRootGroup")
    if not synced:
        fail("no synchronised folder group — new files under Ace/ would not be compiled")
    for group in synced.values():
        if not (ROOT / group["path"]).is_dir():
            fail(f"synchronised group points at a missing folder: {group['path']}")
    if app.get("fileSystemSynchronizedGroups") is None:
        fail("the app target does not use the synchronised group")

    # ---- build settings that must be right ------------------------------------------------------
    def settings_for(target) -> list[dict]:
        config_list = objects[target["buildConfigurationList"]]
        return [objects[c]["buildSettings"] for c in config_list["buildConfigurations"]]

    app_settings = settings_for(app)
    widget_settings = settings_for(widget)

    if len(app_settings) != 2 or len(widget_settings) != 2:
        fail("expected exactly Debug and Release configurations on each target")

    for label, settings_list, want_id in (
        ("app", app_settings, "com.acestudy.Ace"),
        ("widget", widget_settings, "com.acestudy.Ace.AceWidget"),
    ):
        for settings in settings_list:
            if settings.get("PRODUCT_BUNDLE_IDENTIFIER") != want_id:
                fail(f"{label} bundle id is {settings.get('PRODUCT_BUNDLE_IDENTIFIER')}, want {want_id}")

            plist_path = settings.get("INFOPLIST_FILE", "").strip('"')
            if not plist_path or not (ROOT / plist_path).exists():
                fail(f"{label} Info.plist missing: {plist_path}")

            ents = settings.get("CODE_SIGN_ENTITLEMENTS", "").strip('"')
            if not ents or not (ROOT / ents).exists():
                fail(f"{label} entitlements missing: {ents}")

    # A widget extension that isn't SKIP_INSTALL breaks archiving.
    for settings in widget_settings:
        if settings.get("SKIP_INSTALL") != "YES":
            fail("widget must set SKIP_INSTALL = YES or archiving fails validation")

    # ---- App Group must match on both sides ----------------------------------------------------------
    def app_groups(path: str) -> list:
        with open(ROOT / path, "rb") as handle:
            return plistlib.load(handle).get("com.apple.security.application-groups", [])

    try:
        app_g = app_groups("Config/Ace.entitlements")
        widget_g = app_groups("Config/AceWidget.entitlements")
        if not app_g:
            fail("app entitlements declare no App Group")
        elif app_g != widget_g:
            fail(f"App Groups differ: app {app_g} vs widget {widget_g}")
        else:
            # And the code must use the same identifier.
            source = (ROOT / "Shared" / "WidgetSnapshot.swift").read_text()
            if f'"{app_g[0]}"' not in source:
                fail(f"WidgetSnapshot.swift does not use the entitled group {app_g[0]}")
            notes.append(f"App Group {app_g[0]} consistent across entitlements and code")
    except Exception as exc:                                    # noqa: BLE001
        fail(f"could not read entitlements: {exc}")

    # The widget's extension point must be declared.
    try:
        with open(ROOT / "Config" / "AceWidget-Info.plist", "rb") as handle:
            widget_plist = plistlib.load(handle)
        point = widget_plist.get("NSExtension", {}).get("NSExtensionPointIdentifier")
        if point != "com.apple.widgetkit-extension":
            fail(f"widget extension point is {point!r}, want com.apple.widgetkit-extension")
    except Exception as exc:                                    # noqa: BLE001
        fail(f"could not read the widget Info.plist: {exc}")

    # ---- build file hygiene --------------------------------------------------------------------------
    for bf_id, bf in build_files.items():
        if bf.get("fileRef") not in objects:
            fail(f"build file {bf_id} references a missing file")

    notes.append(f"{len(targets)} targets, {len(file_refs)} file references, "
                 f"{len(build_files)} build files, {len(objects)} objects")
    return report()


def report() -> int:
    if errors:
        print("✗ project structure is broken:")
        for error in errors:
            print(f"    • {error}")
        return 1
    for note in notes:
        print(f"    {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
