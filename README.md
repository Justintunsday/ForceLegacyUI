# ForceLegacyUI

A native SwiftUI research app for investigating legacy appearance on iOS 26, with
a read-only LaunchServices inspector, worse_query integration, two control probes
and a guarded SDK-metadata experiment engine.

[繁體中文安裝與「找不到 App」排查教程](docs/GUIDE.zh-Hant.md)

[Download 0.1.1 IPA (re-signing required)](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.1/ForceLegacyUI-unsigned.ipa)

Version 0.1.1 fixes missing App Group request metadata in the old sideloading
artifact, detects matching signing-tool group renames, adds fallback enumeration,
and shows the app-list failure reason directly. Updating permissions does not
enable unverified live overrides.

**No legacy appearance override is currently verified on iOS 26.6.2.** The shipped
live-write allowlist is empty. The app does not modify signed app bundles, install
tweaks, reinstall target applications or require a jailbreak. A successful metadata
write is never described as a successful appearance change.

## What you can test

* List visible installed apps with local icons, identifiers and reported SDKs.
* Inspect a bounded LS store snapshot, record sizes and checksums without modifying it.
* Select proposed per-app changes, use Select All / Deselect All and run a dry run.
* Import an exact-build profile for **app-owned copy experiments** only.
* Exercise apply, durable backup, original-value tracking, rollback and restoration
  in the clearly marked synthetic demo laboratory.
* Export technical diagnostics and compare UIKit / SwiftUI controls in Modern and
  Legacy probe apps, including plist, Mach-O, dyld and LS launch inputs.

No arbitrary byte editor or iOS 27 offsets are used on iOS 26. Unknown layouts
remain unsupported. No successful physical-device test is fabricated.

## Build

Open `ForceLegacyUI.xcodeproj` with Xcode 26.x on macOS. The repository includes
the project, shared schemes, a local Swift package and GitHub Actions workflow.
CI packages unsigned device IPAs; an optional manual signing job can produce a
device-installable main-app IPA when matching credentials and provisioning are
configured. Unsigned IPAs require signing before installation.

[Find the latest build artifacts](https://github.com/Justintunsday/ForceLegacyUI/actions/workflows/build.yml).
Use a successful 0.1.1 build for sideloading; the old 0.1.0 package omitted App
Group signing metadata. See the [validation record](docs/VALIDATION.md) for test scope.
The [0.1.1 build](https://github.com/Justintunsday/ForceLegacyUI/actions/runs/43775929275)
passed 28 safety tests, requested-entitlement packaging checks, device/simulator
builds, synthetic transaction testing and native simulator app enumeration.

```sh
swift test --package-path Packages/LegacyCore --parallel
python3 scripts/generate_project.py --check
```

For a simulator, turn on **Diagnostics → Demo laboratory**. For a physical device,
sign ForceLegacyUI with a dedicated, provisioned App Group. Simply sideloading
with an unprovisioned App Group string does not grant the needed capability.

## Documentation

* [Investigation and confirmed findings](docs/INVESTIGATION.md)
* [Building, signing and IPA artifacts](docs/BUILDING.md)
* [iOS 26.6.2 test protocol and research tools](docs/TESTING.md)
* [Safety boundaries and recovery](docs/SAFETY.md)
* [Actual build and simulator results](docs/VALIDATION.md)

The upstream references are pinned in [upstreams.json](docs/upstreams.json).

License: GPL-3.0-or-later. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
