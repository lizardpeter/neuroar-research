#!/usr/bin/env python3
"""Verify release metadata locally before asking Apple to validate an upload."""
import plistlib
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("Usage: validate-ios-bundle.py PATH_TO_APP EXPECTED_BUNDLE_ID")
app = Path(sys.argv[1])
expected = sys.argv[2]
with (app / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)

errors = []
if info.get("CFBundleIdentifier") != expected:
    errors.append("bundle ID does not match " + expected)
primary = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
icon_name = info.get("CFBundleIconName") or primary.get("CFBundleIconName")
if not icon_name:
    errors.append("compiled Info.plist is missing CFBundleIconName")
if not (info.get("UILaunchScreen") is not None or info.get("UILaunchStoryboardName")):
    errors.append("compiled Info.plist is missing UILaunchScreen or UILaunchStoryboardName")
orientations = info.get("UISupportedInterfaceOrientations", [])
ipad = info.get("UISupportedInterfaceOrientations~ipad", orientations)
needed = {"UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
          "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
if not isinstance(orientations, list) or not orientations:
    errors.append("compiled Info.plist is missing UISupportedInterfaceOrientations array")
if not isinstance(ipad, list) or not needed.issubset(ipad):
    errors.append("iPad orientation configuration must include all four orientations")
if not info.get("NSCameraUsageDescription"):
    errors.append("camera usage description is absent")
# Apple's TestFlight export-compliance declaration must be a Boolean false,
# not an absent key or the string "NO". Keep this check in Release archives.
if info.get("ITSAppUsesNonExemptEncryption") is not False:
    errors.append("ITSAppUsesNonExemptEncryption must be Boolean NO for this exempt-encryption build")
if errors:
    for issue in errors:
        print("::error::" + issue, file=sys.stderr)
    sys.exit(1)
print("Verified compiled iOS metadata: bundle ID, AppIcon, launch screen, iPhone/iPad orientations, camera permission and export-compliance declaration.")
