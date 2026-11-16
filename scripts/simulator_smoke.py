#!/usr/bin/env python3
"""Boot an available iOS 26 simulator and verify process launch and probe fact export."""
from pathlib import Path
import json
import plistlib
import shlex
import subprocess
import time

root = Path(__file__).resolve().parents[1]
def run(*args, timeout=120, **kwargs):
    print("Running: " + shlex.join(args), flush=True)
    try:
        return subprocess.run(args, check=True, text=True, capture_output=True, timeout=timeout, **kwargs).stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        for stream in (error.stdout, error.stderr):
            if stream:
                print(stream.decode(errors="replace") if isinstance(stream, bytes) else stream, flush=True)
        raise

devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
candidates = [(runtime, d) for runtime, items in devices.items() if "iOS-26-" in runtime for d in items if "iPhone" in d["name"]]
if not candidates: raise SystemExit("No iOS 26 iPhone simulator runtime available; smoke test cannot be claimed")
sdk_version = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
sdk_pair = tuple(int(part) for part in sdk_version.split(".")[:2])
def simulator_priority(value):
    runtime, device = value
    version = tuple(int(part) for part in runtime.rsplit("iOS-", 1)[1].split("-"))
    return (version[:2] == sdk_pair, version, device["state"] == "Booted", device["name"] == "iPhone 17 Pro", device["name"])
runtime, device = max(candidates, key=simulator_priority)
print(f"Selected {runtime} / {device['name']} for toolchain simulator SDK {sdk_version}", flush=True)
udid = device["udid"]
if device["state"] != "Booted": run("xcrun", "simctl", "boot", udid)
run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
output = root / "dist"; output.mkdir(exist_ok=True)
products = root / "build/simulator/Build/Products/Debug-iphonesimulator"
evidence = {"runtime": runtime, "toolchainSDK":sdk_version, "device": device["name"], "udid": udid, "deviceTest": False, "launches": []}
for name in ["ForceLegacyUI", "CompatibilityProbeModern", "CompatibilityProbeLegacy"]:
    app = products / f"{name}.app"
    info = plistlib.loads((app / "Info.plist").read_bytes()); identifier = info["CFBundleIdentifier"]
    run("xcrun", "simctl", "install", udid, str(app), timeout=300)
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
        fixture_path = container / "Documents/DemoLaboratory/synthetic.csstore"
        (output / "synthetic-demo.csstore").write_bytes(fixture_path.read_bytes())
        run("python3", str(root / "scripts/analyze_snapshot.py"), str(output / "synthetic-demo.csstore"),
            "--output", str(output / "synthetic-analysis.json"))
    if name != "ForceLegacyUI":
        container = Path(run("xcrun", "simctl", "get_app_container", udid, identifier, "data"))
        facts_path = container / "Documents/launch-facts.json"
        if not facts_path.exists(): raise SystemExit(f"Probe failed to export facts: {identifier}")
        facts = json.loads(facts_path.read_text())
        if facts["plistCompatibilityValue"] != name.endswith("Legacy"): raise SystemExit("Probe plist control mismatch")
        (output / f"{name}-launch-facts.json").write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n")
    evidence["launches"].append({"bundleID": identifier, "launchResult": launch, "factsExported": facts is not None})
    run("xcrun", "simctl", "terminate", udid, identifier)
# Test the real LaunchServices enumeration path too; the synthetic demo cannot cover app visibility.
main_info = plistlib.loads((products / "ForceLegacyUI.app/Info.plist").read_bytes())
main_id = main_info["CFBundleIdentifier"]
run("xcrun", "simctl", "launch", udid, main_id, "--catalog-self-test")
container = Path(run("xcrun", "simctl", "get_app_container", udid, main_id, "data"))
catalog_file = container / "Documents/simulator-catalog-test.json"
for _ in range(20):
    if catalog_file.exists(): break
    time.sleep(1)
if not catalog_file.exists(): raise SystemExit("Native application catalog self-test did not produce evidence")
catalog = json.loads(catalog_file.read_text())
if catalog["isDemo"] or not any(app["bundleID"] == main_id for app in catalog["applications"]):
    raise SystemExit("Native catalog was empty or used synthetic data")
(output / "simulator-catalog-test.json").write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n")
run("xcrun", "simctl", "io", udid, "screenshot", str(output / "ForceLegacyUI-native-catalog-simulator.png"))
run("xcrun", "simctl", "terminate", udid, main_id)
(output / "simulator-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
print("Simulator launch smoke checks passed. No physical-device compatibility claim is made.")
