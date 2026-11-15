#!/usr/bin/env python3
"""Build our app using an explicit provisioning profile. Never touches installed target apps."""
from pathlib import Path
import base64
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
import plistlib

root = Path(__file__).resolve().parents[1]
required = ["FL_CERTIFICATE_BASE64", "FL_CERTIFICATE_PASSWORD", "FL_PROFILE_BASE64"]
missing = [name for name in required if not os.environ.get(name)]
if missing: raise SystemExit("Signing not configured: " + ", ".join(missing))
secrets = [os.environ[name] for name in required]

def run(*args):
    result = subprocess.run(args, cwd=root, text=True, capture_output=True)
    if result.returncode:
        message = (result.stderr + result.stdout)[-6000:]
        for secret in secrets: message = message.replace(secret, "[redacted]")
        raise RuntimeError(f"{Path(args[0]).name} failed: {message}")
    return result.stdout.strip()

def decode(name):
    return base64.b64decode("".join(os.environ[name].split()), validate=True)

profile_copy = None
old_profile = None
old_keychains = shlex.split(run("security", "list-keychains", "-d", "user"))
with tempfile.TemporaryDirectory(prefix="forcelegacyui-signing-") as temporary:
    temporary = Path(temporary)
    keychain = temporary / "signing.keychain-db"
    password = uuid.uuid4().hex + uuid.uuid4().hex
    secrets.append(password)
    try:
        certificate = temporary / "certificate.p12"; certificate.write_bytes(decode("FL_CERTIFICATE_BASE64")); certificate.chmod(0o600)
        profile_file = temporary / "profile.mobileprovision"; profile_file.write_bytes(decode("FL_PROFILE_BASE64")); profile_file.chmod(0o600)
        profile = plistlib.loads(run("security", "cms", "-D", "-i", str(profile_file)).encode())
        if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise RuntimeError("The provisioning profile has expired")
        entitlement = profile["Entitlements"]
        team = profile["TeamIdentifier"][0]
        bundle_id = os.environ.get("FL_BUNDLE_ID") or "org.forcelegacyui.app"
        group = os.environ.get("FL_APP_GROUP") or "group.org.forcelegacyui.app"
        if entitlement.get("application-identifier") != team + "." + bundle_id:
            raise RuntimeError("Profile application-identifier must exactly match FL_BUNDLE_ID (wildcards are not supported)")
        if group not in entitlement.get("com.apple.security.application-groups", []):
            raise RuntimeError("Profile must provision the dedicated FL_APP_GROUP")
        if not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"):
            raise RuntimeError("Use a development or ad hoc device-installable profile, not an App Store profile")
        run("security", "create-keychain", "-p", password, str(keychain))
        run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
        run("security", "unlock-keychain", "-p", password, str(keychain))
        run("security", "import", str(certificate), "-P", os.environ["FL_CERTIFICATE_PASSWORD"], "-A", "-t", "cert", "-f", "pkcs12", "-k", str(keychain))
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-k", password, str(keychain))
        run("security", "list-keychains", "-d", "user", "-s", str(keychain), *old_keychains)
        identities = re.findall(r"\b[0-9A-F]{40}\b", run("security", "find-identity", "-v", "-p", "codesigning", str(keychain)))
        allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
        matching = [identity for identity in identities if identity in allowed]
        if not matching: raise RuntimeError("Imported signing identity does not match a certificate in the profile")
        profiles = Path.home() / "Library/MobileDevice/Provisioning Profiles"; profiles.mkdir(parents=True, exist_ok=True)
        profile_copy = profiles / (profile["UUID"] + ".mobileprovision")
        if profile_copy.exists(): old_profile = profile_copy.read_bytes()
        shutil.copyfile(profile_file, profile_copy)
        output = run("xcodebuild", "-project", "ForceLegacyUI.xcodeproj", "-scheme", "ForceLegacyUIDevice", "-configuration", "Release",
            "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-derivedDataPath", "build/signed",
            "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=" + team, "CODE_SIGN_IDENTITY=" + matching[0],
            "PROVISIONING_PROFILE_SPECIFIER=" + profile["UUID"], "FL_BUNDLE_ID=" + bundle_id, "APP_GROUP_IDENTIFIER=" + group, "build")
        (root / "build/signed.log").write_text(output + "\n")
        products = root / "build/signed/Build/Products/Release-iphoneos"
        run("codesign", "--verify", "--deep", "--strict", str(products / "ForceLegacyUI.app"))
        run(sys.executable, "scripts/package_ipa.py", str(products), str(root / "dist"))
        (root / "dist/signing-evidence.json").write_text(json.dumps({"bundleID": bundle_id, "appGroup": group,
            "profileUUID": profile["UUID"], "profileExpiration": profile["ExpirationDate"].isoformat(),
            "signatureVerified": True, "appearanceVerified": False}, indent=2) + "\n")
        print("Built and verified a provisioned IPA. Installation is restricted to devices allowed by that profile.")
    finally:
        run("security", "list-keychains", "-d", "user", "-s", *old_keychains)
        subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True)
        if profile_copy:
            if old_profile is None: profile_copy.unlink(missing_ok=True)
            else: profile_copy.write_bytes(old_profile)
