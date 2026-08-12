#!/usr/bin/env python3
"""
build_pbxproj.py — generates Ace.xcodeproj/project.pbxproj.

The project file is generated rather than hand-edited because this machine has
no Xcode (DECISIONS.md D1), so there is no way to open the project, make a
change in the UI and let Xcode write it back. Generating it from a script means
the object graph is built once, correctly, and every future change is a small
edit here rather than surgery on 300 lines of OpenStep plist.

Three targets:
  • Ace                    — the app. Uses a synchronised folder group, so new
                             files under Ace/ are picked up with no edit here.
  • AceWidgetExtension     — the widget and the Live Activity.
  • AceShare               — the share-sheet extension (Anywhere Mode).

Everything in `Shared/` is compiled into more than one target, which is why the
app target has explicit Sources entries alongside its synchronised group.

Run:  python3 Tools/gen/build_pbxproj.py
Then: ./Tools/verify.sh   (which structurally validates the result)
"""

import pathlib

# ---------------------------------------------------------------- identifiers
#
# Xcode object identifiers are 24 uppercase hex characters. These are assigned
# by hand so the file diffs cleanly when regenerated.

def oid(n: int) -> str:
    """ACE1 + 17 zeros + a 3-digit number = 24 characters."""
    return f"ACE1{'0' * 17}{n:03d}"

APP_PRODUCT      = oid(1)
APP_INFO_PLIST   = oid(2)
APP_GROUP_SYNC   = oid(10)
APP_FRAMEWORKS   = oid(20)
MAIN_GROUP       = oid(30)
CONFIG_GROUP     = oid(31)
PRODUCTS_GROUP   = oid(32)
APP_TARGET       = oid(40)
APP_SOURCES      = oid(41)
APP_RESOURCES    = oid(42)
APP_CONFIG_LIST  = oid(50)
APP_DEBUG        = oid(51)
APP_RELEASE      = oid(52)
PROJECT          = oid(60)
PROJ_CONFIG_LIST = oid(70)
PROJ_DEBUG       = oid(71)
PROJ_RELEASE     = oid(72)

# Part 2 additions — the widget.
WIDGET_PRODUCT     = oid(100)
WIDGET_GROUP       = oid(101)
SHARED_GROUP       = oid(102)
WIDGET_TARGET      = oid(103)
WIDGET_SOURCES     = oid(104)
WIDGET_FRAMEWORKS  = oid(105)
WIDGET_RESOURCES   = oid(106)
WIDGET_CONFIG_LIST = oid(107)
WIDGET_DEBUG       = oid(108)
WIDGET_RELEASE     = oid(109)
EMBED_PHASE        = oid(110)
EMBED_BUILD_FILE   = oid(111)
TARGET_PROXY       = oid(112)
TARGET_DEPENDENCY  = oid(113)

# File references
REF_SHARED_SNAPSHOT = oid(120)
REF_WIDGET_MAIN     = oid(121)
REF_WIDGET_BUNDLE   = oid(122)
REF_WIDGET_VIEWS    = oid(123)
REF_WIDGET_PLIST    = oid(124)
REF_APP_ENTS        = oid(125)
REF_WIDGET_ENTS     = oid(126)
REF_PRIVACY         = oid(127)

# Part 5 — the share extension.
SHARE_PRODUCT      = oid(140)
SHARE_GROUP        = oid(141)
SHARE_TARGET       = oid(142)
SHARE_SOURCES      = oid(143)
SHARE_FRAMEWORKS   = oid(144)
SHARE_RESOURCES    = oid(145)
SHARE_CONFIG_LIST  = oid(146)
SHARE_DEBUG        = oid(147)
SHARE_RELEASE      = oid(148)
SHARE_PROXY        = oid(149)
SHARE_DEPENDENCY   = oid(150)
REF_SHARE_MAIN     = oid(151)
REF_SHARE_PLIST    = oid(152)
REF_SHARE_ENTS     = oid(153)
REF_SHARE_INBOX    = oid(154)
REF_ACTIVITY_ATTRS = oid(155)
REF_WIDGET_ACTIVITY = oid(156)
REF_WIDGET_INTENT  = oid(157)

BF_SHARE_MAIN        = oid(160)
BF_INBOX_IN_APP      = oid(161)
BF_INBOX_IN_SHARE    = oid(162)
BF_ATTRS_IN_APP      = oid(163)
BF_ATTRS_IN_WIDGET   = oid(164)
BF_WIDGET_ACTIVITY   = oid(165)
BF_WIDGET_INTENT     = oid(166)
BF_SHARE_EMBED       = oid(167)
BF_SNAPSHOT_IN_SHARE = oid(168)
BF_PRIVACY_IN_APP    = oid(169)

# Build files
BF_SHARED_IN_APP    = oid(130)
BF_SHARED_IN_WIDGET = oid(131)
BF_WIDGET_MAIN      = oid(132)
BF_WIDGET_BUNDLE    = oid(133)
BF_WIDGET_VIEWS     = oid(134)

BUNDLE_ID = "com.acestudy.Ace"

# ---------------------------------------------------------------- shared settings

COMMON = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = minimal;
\t\t\t\tSWIFT_VERSION = 5.0;"""

DEBUG_ONLY = """\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";"""

RELEASE_ONLY = """\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tVALIDATE_PRODUCT = YES;"""


def app_target_settings() -> str:
    return f"""\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = Config/Ace.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Config/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""


def share_target_settings() -> str:
    return f"""\t\t\t\tCODE_SIGN_ENTITLEMENTS = Config/AceShare.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = "Config/AceShare-Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}.AceShare;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""


def widget_target_settings() -> str:
    return f"""\t\t\t\tCODE_SIGN_ENTITLEMENTS = Config/AceWidget.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = "Config/AceWidget-Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}.AceWidget;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""


# ---------------------------------------------------------------- the file

def build() -> str:
    return f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
\t\t{BF_SHARED_IN_APP} /* WidgetSnapshot.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_SHARED_SNAPSHOT} /* WidgetSnapshot.swift */; }};
\t\t{BF_SHARED_IN_WIDGET} /* WidgetSnapshot.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_SHARED_SNAPSHOT} /* WidgetSnapshot.swift */; }};
\t\t{BF_WIDGET_MAIN} /* AceWidget.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_WIDGET_MAIN} /* AceWidget.swift */; }};
\t\t{BF_WIDGET_BUNDLE} /* AceWidgetBundle.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_WIDGET_BUNDLE} /* AceWidgetBundle.swift */; }};
\t\t{BF_WIDGET_VIEWS} /* AceWidgetViews.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_WIDGET_VIEWS} /* AceWidgetViews.swift */; }};
\t\t{EMBED_BUILD_FILE} /* AceWidgetExtension.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {WIDGET_PRODUCT} /* AceWidgetExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
\t\t{BF_SHARE_EMBED} /* AceShare.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {SHARE_PRODUCT} /* AceShare.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
\t\t{BF_SHARE_MAIN} /* ShareViewController.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_SHARE_MAIN} /* ShareViewController.swift */; }};
\t\t{BF_INBOX_IN_APP} /* ShareInbox.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_SHARE_INBOX} /* ShareInbox.swift */; }};
\t\t{BF_INBOX_IN_SHARE} /* ShareInbox.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_SHARE_INBOX} /* ShareInbox.swift */; }};
\t\t{BF_SNAPSHOT_IN_SHARE} /* WidgetSnapshot.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_SHARED_SNAPSHOT} /* WidgetSnapshot.swift */; }};
\t\t{BF_ATTRS_IN_APP} /* StudyActivityAttributes.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_ACTIVITY_ATTRS} /* StudyActivityAttributes.swift */; }};
\t\t{BF_ATTRS_IN_WIDGET} /* StudyActivityAttributes.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_ACTIVITY_ATTRS} /* StudyActivityAttributes.swift */; }};
\t\t{BF_WIDGET_ACTIVITY} /* StudyLiveActivity.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_WIDGET_ACTIVITY} /* StudyLiveActivity.swift */; }};
\t\t{BF_WIDGET_INTENT} /* QuickCaptureIntent.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {REF_WIDGET_INTENT} /* QuickCaptureIntent.swift */; }};
\t\t{BF_PRIVACY_IN_APP} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {REF_PRIVACY} /* PrivacyInfo.xcprivacy */; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t{TARGET_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {PROJECT} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {WIDGET_TARGET};
\t\t\tremoteInfo = AceWidgetExtension;
\t\t}};
\t\t{SHARE_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {PROJECT} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {SHARE_TARGET};
\t\t\tremoteInfo = AceShare;
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
\t\t{EMBED_PHASE} /* Embed Foundation Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{EMBED_BUILD_FILE} /* AceWidgetExtension.appex in Embed Foundation Extensions */,
\t\t\t\t{BF_SHARE_EMBED} /* AceShare.appex in Embed Foundation Extensions */,
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
\t\t{APP_PRODUCT} /* Ace.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Ace.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{APP_INFO_PLIST} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{WIDGET_PRODUCT} /* AceWidgetExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = AceWidgetExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{REF_SHARED_SNAPSHOT} /* WidgetSnapshot.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WidgetSnapshot.swift; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_MAIN} /* AceWidget.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AceWidget.swift; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_BUNDLE} /* AceWidgetBundle.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AceWidgetBundle.swift; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_VIEWS} /* AceWidgetViews.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AceWidgetViews.swift; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_PLIST} /* AceWidget-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "AceWidget-Info.plist"; sourceTree = "<group>"; }};
\t\t{REF_APP_ENTS} /* Ace.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Ace.entitlements; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_ENTS} /* AceWidget.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = AceWidget.entitlements; sourceTree = "<group>"; }};
\t\t{REF_PRIVACY} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; }};
\t\t{SHARE_PRODUCT} /* AceShare.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = AceShare.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{REF_SHARE_MAIN} /* ShareViewController.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareViewController.swift; sourceTree = "<group>"; }};
\t\t{REF_SHARE_PLIST} /* AceShare-Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "AceShare-Info.plist"; sourceTree = "<group>"; }};
\t\t{REF_SHARE_ENTS} /* AceShare.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = AceShare.entitlements; sourceTree = "<group>"; }};
\t\t{REF_SHARE_INBOX} /* ShareInbox.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareInbox.swift; sourceTree = "<group>"; }};
\t\t{REF_ACTIVITY_ATTRS} /* StudyActivityAttributes.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StudyActivityAttributes.swift; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_ACTIVITY} /* StudyLiveActivity.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StudyLiveActivity.swift; sourceTree = "<group>"; }};
\t\t{REF_WIDGET_INTENT} /* QuickCaptureIntent.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickCaptureIntent.swift; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
\t\t{APP_GROUP_SYNC} /* Ace */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = Ace;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{APP_FRAMEWORKS} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{WIDGET_FRAMEWORKS} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{SHARE_FRAMEWORKS} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{MAIN_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_GROUP_SYNC} /* Ace */,
\t\t\t\t{WIDGET_GROUP} /* AceWidget */,
\t\t\t\t{SHARE_GROUP} /* AceShare */,
\t\t\t\t{SHARED_GROUP} /* Shared */,
\t\t\t\t{CONFIG_GROUP} /* Config */,
\t\t\t\t{PRODUCTS_GROUP} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{WIDGET_GROUP} /* AceWidget */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{REF_WIDGET_BUNDLE} /* AceWidgetBundle.swift */,
\t\t\t\t{REF_WIDGET_MAIN} /* AceWidget.swift */,
\t\t\t\t{REF_WIDGET_VIEWS} /* AceWidgetViews.swift */,
\t\t\t\t{REF_WIDGET_ACTIVITY} /* StudyLiveActivity.swift */,
\t\t\t\t{REF_WIDGET_INTENT} /* QuickCaptureIntent.swift */,
\t\t\t);
\t\t\tpath = AceWidget;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{SHARE_GROUP} /* AceShare */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{REF_SHARE_MAIN} /* ShareViewController.swift */,
\t\t\t);
\t\t\tpath = AceShare;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{SHARED_GROUP} /* Shared */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{REF_SHARED_SNAPSHOT} /* WidgetSnapshot.swift */,
\t\t\t\t{REF_SHARE_INBOX} /* ShareInbox.swift */,
\t\t\t\t{REF_ACTIVITY_ATTRS} /* StudyActivityAttributes.swift */,
\t\t\t);
\t\t\tpath = Shared;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{CONFIG_GROUP} /* Config */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_INFO_PLIST} /* Info.plist */,
\t\t\t\t{REF_WIDGET_PLIST} /* AceWidget-Info.plist */,
\t\t\t\t{REF_SHARE_PLIST} /* AceShare-Info.plist */,
\t\t\t\t{REF_APP_ENTS} /* Ace.entitlements */,
\t\t\t\t{REF_WIDGET_ENTS} /* AceWidget.entitlements */,
\t\t\t\t{REF_SHARE_ENTS} /* AceShare.entitlements */,
\t\t\t\t{REF_PRIVACY} /* PrivacyInfo.xcprivacy */,
\t\t\t);
\t\t\tpath = Config;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{PRODUCTS_GROUP} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_PRODUCT} /* Ace.app */,
\t\t\t\t{WIDGET_PRODUCT} /* AceWidgetExtension.appex */,
\t\t\t\t{SHARE_PRODUCT} /* AceShare.appex */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{APP_TARGET} /* Ace */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {APP_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Ace" */;
\t\t\tbuildPhases = (
\t\t\t\t{APP_SOURCES} /* Sources */,
\t\t\t\t{APP_FRAMEWORKS} /* Frameworks */,
\t\t\t\t{APP_RESOURCES} /* Resources */,
\t\t\t\t{EMBED_PHASE} /* Embed Foundation Extensions */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{TARGET_DEPENDENCY} /* PBXTargetDependency */,
\t\t\t\t{SHARE_DEPENDENCY} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{APP_GROUP_SYNC} /* Ace */,
\t\t\t);
\t\t\tname = Ace;
\t\t\tproductName = Ace;
\t\t\tproductReference = {APP_PRODUCT} /* Ace.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t{WIDGET_TARGET} /* AceWidgetExtension */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {WIDGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "AceWidgetExtension" */;
\t\t\tbuildPhases = (
\t\t\t\t{WIDGET_SOURCES} /* Sources */,
\t\t\t\t{WIDGET_FRAMEWORKS} /* Frameworks */,
\t\t\t\t{WIDGET_RESOURCES} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = AceWidgetExtension;
\t\t\tproductName = AceWidgetExtension;
\t\t\tproductReference = {WIDGET_PRODUCT} /* AceWidgetExtension.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};
\t\t{SHARE_TARGET} /* AceShare */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {SHARE_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "AceShare" */;
\t\t\tbuildPhases = (
\t\t\t\t{SHARE_SOURCES} /* Sources */,
\t\t\t\t{SHARE_FRAMEWORKS} /* Frameworks */,
\t\t\t\t{SHARE_RESOURCES} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = AceShare;
\t\t\tproductName = AceShare;
\t\t\tproductReference = {SHARE_PRODUCT} /* AceShare.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{PROJECT} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2600;
\t\t\t\tLastUpgradeCheck = 2600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{APP_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t}};
\t\t\t\t\t{WIDGET_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t}};
\t\t\t\t\t{SHARE_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {PROJ_CONFIG_LIST} /* Build configuration list for PBXProject "Ace" */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN_GROUP};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{APP_TARGET} /* Ace */,
\t\t\t\t{WIDGET_TARGET} /* AceWidgetExtension */,
\t\t\t\t{SHARE_TARGET} /* AceShare */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{APP_RESOURCES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{BF_PRIVACY_IN_APP} /* PrivacyInfo.xcprivacy in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{WIDGET_RESOURCES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{SHARE_RESOURCES} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{APP_SOURCES} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{BF_SHARED_IN_APP} /* WidgetSnapshot.swift in Sources */,
\t\t\t\t{BF_INBOX_IN_APP} /* ShareInbox.swift in Sources */,
\t\t\t\t{BF_ATTRS_IN_APP} /* StudyActivityAttributes.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{WIDGET_SOURCES} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{BF_WIDGET_BUNDLE} /* AceWidgetBundle.swift in Sources */,
\t\t\t\t{BF_WIDGET_MAIN} /* AceWidget.swift in Sources */,
\t\t\t\t{BF_WIDGET_VIEWS} /* AceWidgetViews.swift in Sources */,
\t\t\t\t{BF_SHARED_IN_WIDGET} /* WidgetSnapshot.swift in Sources */,
\t\t\t\t{BF_ATTRS_IN_WIDGET} /* StudyActivityAttributes.swift in Sources */,
\t\t\t\t{BF_WIDGET_ACTIVITY} /* StudyLiveActivity.swift in Sources */,
\t\t\t\t{BF_WIDGET_INTENT} /* QuickCaptureIntent.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{SHARE_SOURCES} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{BF_SHARE_MAIN} /* ShareViewController.swift in Sources */,
\t\t\t\t{BF_INBOX_IN_SHARE} /* ShareInbox.swift in Sources */,
\t\t\t\t{BF_SNAPSHOT_IN_SHARE} /* WidgetSnapshot.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{TARGET_DEPENDENCY} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {WIDGET_TARGET} /* AceWidgetExtension */;
\t\t\ttargetProxy = {TARGET_PROXY} /* PBXContainerItemProxy */;
\t\t}};
\t\t{SHARE_DEPENDENCY} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {SHARE_TARGET} /* AceShare */;
\t\t\ttargetProxy = {SHARE_PROXY} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
\t\t{PROJ_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{COMMON}
{DEBUG_ONLY}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{PROJ_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{COMMON}
{RELEASE_ONLY}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{APP_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{app_target_settings()}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{APP_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{app_target_settings()}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{WIDGET_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{widget_target_settings()}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{WIDGET_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{widget_target_settings()}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{SHARE_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{share_target_settings()}
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{SHARE_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{share_target_settings()}
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{PROJ_CONFIG_LIST} /* Build configuration list for PBXProject "Ace" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{PROJ_DEBUG} /* Debug */,
\t\t\t\t{PROJ_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{APP_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "Ace" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{APP_DEBUG} /* Debug */,
\t\t\t\t{APP_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{WIDGET_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "AceWidgetExtension" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{WIDGET_DEBUG} /* Debug */,
\t\t\t\t{WIDGET_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{SHARE_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "AceShare" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{SHARE_DEBUG} /* Debug */,
\t\t\t\t{SHARE_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {PROJECT} /* Project object */;
}}
"""


if __name__ == "__main__":
    out = pathlib.Path(__file__).resolve().parents[2] / "Ace.xcodeproj" / "project.pbxproj"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build())
    print(f"wrote {out}")
