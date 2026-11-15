#!/usr/bin/env python3
"""Inventory SDK load commands and relevant symbols from a locally supplied, authorized Mach-O image."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if not shutil.which("xcrun"): raise SystemExit("Run this optional symbol inventory on macOS with Xcode tools")
pattern = re.compile(r"UIDesignRequiresCompatibility|Compatibility|Legacy|LiquidGlass|SDKAtLeast|sdk_at_least|LinkedOnOrAfter", re.I)

def capture(*command):
    result = subprocess.run(command, text=True, capture_output=True)
    return {"exitCode": result.returncode, "lines": [line for line in result.stdout.splitlines() if pattern.search(line)][:2000],
            "error": result.stderr[:2000]}

digest = hashlib.sha256()
with args.binary.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""): digest.update(chunk)
load = subprocess.run(["xcrun", "otool", "-l", str(args.binary)], text=True, capture_output=True)
report = {"input": str(args.binary.resolve()), "sha256": digest.hexdigest(),
          "symbols": capture("xcrun", "nm", "-a", str(args.binary)),
          "strings": capture("strings", "-a", str(args.binary)),
          "loadCommands": load.stdout, "loadCommandError": load.stderr,
          "warning": "An inventory supplies names and locations, not verified call-graph or override semantics. Shared-cache-only images must first be obtained/extracted with authorized development tools."}
args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
