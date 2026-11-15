#!/usr/bin/env python3
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("products", type=Path); parser.add_argument("output", type=Path)
parser.add_argument("--unsigned", action="store_true"); args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
apps = sorted(args.products.glob("*.app"))
if not apps: raise SystemExit("No built application bundles found")
for app in apps:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / info["CFBundleExecutable"]
    if not executable.is_file(): raise SystemExit(f"Missing executable for {app.name}")
    suffix = "unsigned" if args.unsigned else "signed"
    output = args.output / f"{app.stem}-{suffix}.ipa"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(app.rglob("*")):
            if file.is_file(): archive.write(file, "Payload/" + str(file.relative_to(app.parent)))
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".ipa.sha256").write_text(digest + "  " + output.name + "\n")
    print(f"Packaged {output.name}; signing required: {args.unsigned}")
(args.output / "PACKAGING.txt").write_text(
    "Unsigned IPAs require signing with your own provisioning profile before installation.\n"
    "ForceLegacyUI needs a dedicated, correctly provisioned App Group.\n"
    "Signing ForceLegacyUI/probes does not modify or re-sign the target applications.\n"
    "No appearance override is verified; see the investigation and testing documentation.\n")
