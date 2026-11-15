#!/usr/bin/env python3
"""Boot an available iOS 26 simulator and verify process launch and probe fact export."""
from pathlib import Path
import json
import plistlib
import subprocess
import time

root = Path(__file__).resolve().parents[1]
def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs).stdout.strip()

devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
candidates = [(runtime, d) for runtime, items in devices.items() if "iOS-26-" in runtime for d in items if "iPhone" in d["name"]]
if not candidates: raise SystemExit("No iOS 26 iPhone simulator runtime available; smoke test cannot be claimed")
runtime, device = sorted(candidates, key=lambda value: (value[0], value[1]["name"]))[-1]
udid = device["udid"]
if device["state"] != "Booted": run("xcrun", "simctl", "boot", udid)
run("xcrun", "simctl", "bootstatus", udid, "-b")
output = root / "dist"; output.mkdir(exist_ok=True)
products = root / "build/simulator/Build/Products/Debug-iphonesimulator"
evidence = {"runtime": runtime, "device": device["name"], "udid": udid, "deviceTest": False, "launches": []}
for name in ["ForceLegacyUI", "CompatibilityProbeModern", "CompatibilityProbeLegacy"]:
    app = products / f"{name}.app"
    info = plistlib.loads((app / "Info.plist").read_bytes()); identifier = info["CFBundleIdentifier"]
    run("xcrun", "simctl", "install", udid, str(app))
    arguments = ["--demo", "--self-test"] if name == "ForceLegacyUI" else []
    launch = run("xcrun", "simctl", "launch", udid, identifier, *arguments)
    time.sleep(3)
    # launchctl presence checks that the app did not simply crash after spawning.
    processes = run("xcrun", "simctl", "spawn", udid, "launchctl", "list")
    if identifier not in processes: raise SystemExit(f"Process did not remain running: {identifier}")
    run("xcrun", "simctl", "io", udid, "screenshot", str(output / f"{name}-simulator.png"))
    facts = None
    if name == "ForceLegacyUI":
        container = Path(run("xcrun", "simctl", "get_app_container", udid, identifier, "data"))
        self_test_path = container / "Documents/simulator-self-test.json"
        for _ in range(15):
            if self_test_path.exists(): break
            time.sleep(1)
        if not self_test_path.exists(): raise SystemExit("App engine self-test did not produce evidence")
        self_test = json.loads(self_test_path.read_text())
        if not self_test.get("passed"): raise SystemExit("App engine self-test failed")
        (output / "simulator-self-test.json").write_text(json.dumps(self_test, indent=2, sort_keys=True) + "\n")
    if name != "ForceLegacyUI":
        container = Path(run("xcrun", "simctl", "get_app_container", udid, identifier, "data"))
        facts_path = container / "Documents/launch-facts.json"
        if not facts_path.exists(): raise SystemExit(f"Probe failed to export facts: {identifier}")
        facts = json.loads(facts_path.read_text())
        if facts["plistCompatibilityValue"] != name.endswith("Legacy"): raise SystemExit("Probe plist control mismatch")
        (output / f"{name}-launch-facts.json").write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n")
    evidence["launches"].append({"bundleID": identifier, "launchResult": launch, "factsExported": facts is not None})
    run("xcrun", "simctl", "terminate", udid, identifier)
(output / "simulator-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
print("Simulator launch smoke checks passed. No physical-device compatibility claim is made.")
