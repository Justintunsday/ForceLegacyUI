#!/usr/bin/env python3
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import zipfile
from macho_entitlements import read_entitlements

parser = argparse.ArgumentParser()
parser.add_argument("products", type=Path); parser.add_argument("output", type=Path)
parser.add_argument("--unsigned", action="store_true")
parser.add_argument("--house-arrest", action="store_true"); args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
apps = sorted(args.products.glob("*.app"))
if not apps: raise SystemExit("No built application bundles found")
for app in apps:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if args.house_arrest and (len(apps) != 1 or info.get("CFBundleIdentifier") != "com.apple.mobile.MobileHouseArrest" or
                             info.get("FLAccessMode") != "house-arrest" or info.get("FLAppGroupIdentifier")):
        raise SystemExit("HouseArrest packaging requires the dedicated enterprise-identity build without App Group metadata")
    executable = app / info["CFBundleExecutable"]
    if not executable.is_file(): raise SystemExit(f"Missing executable for {app.name}")
    group = info.get("FLAppGroupIdentifier")
    if group and group not in read_entitlements(executable.read_bytes()).get("com.apple.security.application-groups", []):
        raise SystemExit("App Group signing metadata is missing. Run scripts/prepare_sideload_metadata.py before packaging, or use a correctly provisioned signed build.")
    suffix = "unsigned" if args.unsigned else "signed"
    name = "ForceLegacyUIHouseArrest" if args.house_arrest else app.stem
    output = args.output / f"{name}-{suffix}.ipa"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(app.rglob("*")):
            if file.is_file(): archive.write(file, "Payload/" + str(file.relative_to(app.parent)))
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".ipa.sha256").write_text(digest + "  " + output.name + "\n")
    print(f"Packaged {output.name}; signing required: {args.unsigned}")
(args.output / "PACKAGING.txt").write_text(
    "Unsigned IPAs require signing with your own provisioning profile before installation.\n"
    "An ad-hoc signature carries requested entitlements for sideloading tools; it does not grant device permissions.\n"
    "The standard ForceLegacyUI build needs a dedicated, correctly provisioned App Group.\n" +
    ("The archived HouseArrest variant shares 3105's identity and replaces that app.\n" if args.house_arrest else "") +
    "Signing ForceLegacyUI/probes does not modify or re-sign the target applications.\n"
    "No appearance override is verified; see the investigation and testing documentation.\n")
