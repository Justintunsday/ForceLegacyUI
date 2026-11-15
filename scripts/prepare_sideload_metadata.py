#!/usr/bin/env python3
"""Ad-hoc seal our build output so signing tools can discover requested App Groups.

This does NOT create an Apple-provisioned, device-installable signature.
"""
from pathlib import Path
import argparse
import json
import plistlib
import subprocess
import sys
import tempfile
from macho_entitlements import read_entitlements

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("products", type=Path)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
if sys.platform != "darwin": raise SystemExit("Preparing ad-hoc signing metadata requires macOS codesign")
apps = sorted(args.products.glob("*.app"))
if not apps: raise SystemExit("No built apps found")
evidence = []
for app in apps:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    group = info.get("FLAppGroupIdentifier")
    entitlements = {"com.apple.security.application-groups": [group]} if group else {}
    with tempfile.TemporaryDirectory(prefix="forcelegacyui-entitlements-") as temporary:
        path = Path(temporary) / "entitlements.plist"
        path.write_bytes(plistlib.dumps(entitlements))
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(path), "--generate-entitlement-der", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    embedded = read_entitlements((app / info["CFBundleExecutable"]).read_bytes())
    if group and embedded.get("com.apple.security.application-groups") != [group]:
        raise SystemExit("Requested App Group was not embedded in the re-signing metadata")
    evidence.append({"bundleID": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
                     "requestedEntitlements": embedded, "signatureKind": "ad-hoc metadata only",
                     "requiresAppleProvisionedResigning": True})
args.evidence.parent.mkdir(parents=True, exist_ok=True)
args.evidence.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
print("Requested App Group metadata embedded and verified. Apple-provisioned re-signing is still required.")
