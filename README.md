# ForceLegacyUI

A native SwiftUI research app for investigating legacy appearance on iOS 26, with
a read-only LaunchServices inspector, worse_query integration, two control probes
and a guarded SDK-metadata experiment engine.

[繁體中文安裝與「找不到 App」排查教程](docs/GUIDE.zh-Hant.md)

[Download 0.1.9 IPA (re-signing required)](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.9/ForceLegacyUI-unsigned.ipa)

[單 App 寫入、預覽與還原教程](docs/SINGLE-APP.zh-Hant.md)

Version **0.1.9 (build 11)** is distributed only as the regular App Group app
and its two control probes. MHA distribution ended at the user's request.
Partial native enumeration is reconciled with unambiguous cache registrations,
so one visible native app no longer suppresses other observed cache entries.
Cache-sourced paths retain their provenance, conflicting identities are excluded,
and cached SDKs are not promoted into independent evidence. A separate no-write
O_RDWR/stable-read probe reports cache access even when SDK layout proof is
incomplete. It does not enable Apply. See [the reported catalog gap](docs/feedback-0.1.8.md).

Version **0.1.8 (build 10)** includes a [572-byte candidate](docs/LAYOUT-572.md)
restricted to iOS 26.6.2 / 23G90 / arm64, reviewed against a matching private
snapshot and one independently read self-SDK. One fresh matching native witness
can explain read-only cache SDK values, clearly marked as candidates; selection
and live authorization still require three apps and two SDK versions. The reader
excludes null-placeholder system records from its UUID application scope. Bundle
traversal now retries the upstream alternate flag set after a denied/tokenless
query. Improved phone access and legacy appearance remain unverified.

Version 0.1.7 (build 9) adds traversal fallbacks to bundle SDK reading after the
regular and alternate worse_query attempts. It first tries the requested UUID,
then the fixed Bundle/Application root used by the reference metadata reader.
The consumer still opens only the requested UUID/name and its Info.plist/executable
read-only, and releases each token after that attempt. Both traversal scopes
require a preflight existing-directory check. This is an unverified device access
attempt, not a newly supported 572-byte layout.

Version 0.1.6 addresses bundle SDK read failures reported with 0.1.5.
It resolves registration spelling against bounded entries in the same UUID
container, checks Info.plist identity and retries scoped grants through the actual
metadata read. Individual LS URLs are spelling hints only for the same container
and name. Logs now include requested/resolved paths, access stages and absent
candidate sizes. An independently read executable SDK is displayed separately
while the cache SDK field remains unverified.

The supplied ZIP established a bounded **572-byte candidate**, not a verified
write layout. The captured log still had only one native SDK witness and returned
no sandbox tokens for the other bundle traversal attempts. The reviewed-live
allowlist stays empty, and the original private capture is not published.

The opt-in single-app SDK write experiment requires fresh
Info.plist/executable observations to corroborate the exact snapshot's layout,
identities, paths and SDKs across at least three apps and two SDK versions. Known
field-position signatures are candidates until those checks pass. A writable-open
probe, fresh dry run, snapshot/path/hash-bound authorization, durable backup and
post-write verification are required. Receipts retain the layout and metadata
evidence for restoration after relaunch. Raw diagnostic export now shares one ZIP.

The historical MHA experiment is archived after 0.1.8. Current CI and releases
produce the regular App Group app and two probes. A prefixed `SystemDataOnly`
cache remains diagnostic only. App-list completeness, live SDK experiments and
legacy appearance still need device verification.

The regular build resolves matching signing-tool App Group renames, records
per-stage discovery failures and reports process architecture separately from
phone model. A permission grant does not establish an appearance override.

**No legacy appearance override is currently verified on iOS 26.6.2.** The compiled
reviewed-live allowlist is empty; the new single-app capability requires its own
independent checks and explicit experiment setting. The app does not modify signed app bundles, install
tweaks, reinstall target applications or require a jailbreak. A successful metadata
write is never described as a successful appearance change.

## What you can test

* List visible installed apps with local icons, identifiers and reported SDKs.
* Inspect a bounded LS store snapshot, record sizes and checksums without modifying it.
* Select proposed per-app changes, use Select All / Deselect All and run a dry run.
* Correlate reference-signature candidates or import an exact-build profile, then
  preview app-owned copies and perform a validated **one-app SDK experiment**.
* Exercise apply, durable backup, original-value tracking, rollback and restoration
  in the clearly marked synthetic demo laboratory.
* Export technical diagnostics and compare UIKit / SwiftUI controls in Modern and
  Legacy probe apps, including plist, Mach-O, dyld and LS launch inputs.

Record size or an OS label alone never selects offsets. Reference field positions
require current-device independent corroboration; unknown layouts stay unsupported.
No successful physical-device write or appearance test is fabricated.

## Build

Open `ForceLegacyUI.xcodeproj` with Xcode 26.x on macOS. The repository includes
the project, shared schemes, a local Swift package and GitHub Actions workflow.
CI packages unsigned device IPAs; an optional manual signing job can produce a
device-installable main-app IPA when matching credentials and provisioning are
configured. Unsigned IPAs require signing before installation.

[Find the latest build artifacts](https://github.com/Justintunsday/ForceLegacyUI/actions/workflows/build.yml).
Use the 0.1.9 build 11 release for sideloading; the old 0.1.0 package omitted App
Group signing metadata. See the [validation record](docs/VALIDATION.md) for test scope.
The [0.1.9 build](https://github.com/Justintunsday/ForceLegacyUI/actions/runs/44091064076)
passed 51 core tests, 60 native cases and 5 offline analysis tests. Its iOS 26.2
simulator completed the synthetic transaction/ZIP flow, launched both probes and
returned 148 native registrations. Build details and scope are recorded in
[validation evidence](docs/VALIDATION.md).
Synthetic authorization, rollback and recovery tests do not establish phone access
or a legacy appearance effect.

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
