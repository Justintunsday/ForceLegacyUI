# Building and installing

## Xcode

Use macOS and Xcode 26.x. CI selects Xcode 26.2 explicitly. The app's minimum OS
is 18.0 so unsupported OS versions can display diagnostics; the extension attempt
is restricted to the upstream-reported iOS 26.0–26.7.2 range. The normal arm64
device build can run on arm64e-capable devices; this is not evidence of testing
either hardware class or a separately distributed arm64e ABI slice.

Open `ForceLegacyUI.xcodeproj`. It and its four shared schemes are checked in;
XcodeGen, CocoaPods and network Swift packages are not required. The only Swift
package is the local `Packages/LegacyCore` package.

```sh
swift test --package-path Packages/LegacyCore --parallel
python3 scripts/generate_project.py --check
xcodebuild -project ForceLegacyUI.xcodeproj -scheme ForceLegacyUI \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build
python3 scripts/prepare_sideload_metadata.py build/device/Build/Products/Release-iphoneos --evidence dist/sideload-metadata.json
python3 scripts/package_ipa.py build/device/Build/Products/Release-iphoneos dist --unsigned
```

`ForceLegacyUI` builds the app and both probes. `ForceLegacyUIDevice` builds only
the main app, useful for a provisioning profile that covers only its bundle ID.
The two probe schemes build independently.

For simulator testing, choose an iOS 26 simulator. The extension intentionally
returns unsupported in the simulator; turn on **Diagnostics → Demo laboratory**.
Launch arguments `--demo --self-test` additionally execute the app engine's
synthetic preview/apply/backup/restore protocol and export a JSON result.

## Signing your own app

Sideloading ForceLegacyUI itself requires signing. The constraint against re-signing
applies to the installed apps being investigated; none of those is reinstalled or
re-signed by ForceLegacyUI.

1. Choose a unique bundle ID and register a **dedicated App Group** with your
   Apple developer account. Its provisioning profile must carry the matching
   `com.apple.security.application-groups` entitlement.
2. Copy the following to the ignored `Config/Signing.local.xcconfig`, supplying your values:

   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   FL_BUNDLE_ID = your.unique.bundle.identifier
   APP_GROUP_IDENTIFIER = group.your.unique.group
   ```

3. Select the main target's signing team and App Groups capability in Xcode.
   Confirm the built Info.plist's `FLAppGroupIdentifier` matches the expanded
   entitlement. Install to a registered device with Developer Mode enabled.
4. For probes, use their separate bundle identifiers and appropriate provisioning.
   They need no App Group for their control screens and fact export.

A sideloading service that strips or cannot provision App Groups will not enable
worse_query. A group string added to an unsigned entitlements file is not a valid
provision. The app explains this in Diagnostics and still offers the demo.

As of 0.1.1, re-signing inputs carry an ad-hoc signature containing the requested
App Group entitlement, so sideloading tools can discover it. This is still not an
Apple-provisioned installable signature. The package script rejects a missing
App Group request instead of silently shipping an input without it.

The runtime checks its own signature (or uses an embedded profile as candidate
metadata) and tests matching group-container access. It accepts a uniquely
recognizable signing-tool rename, refuses unrelated/ambiguous groups, and reports
the configured, reported and selected names in Diagnostics. It does not create
entitlements that Apple has not authorized. See the [Traditional Chinese guide](GUIDE.zh-Hant.md).

## GitHub Actions artifacts

The build workflow runs safety tests, builds all three device apps, packages
unsigned IPAs, builds simulator apps, checks launches, exports probe facts and
captures screenshots. Artifacts also include logs, SHA-256 files and an explicit
packaging notice. **An unsigned IPA is not directly installable.**

To request an installable main-app IPA, configure repository secrets:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded Apple signing certificate and private key in a `.p12` |
| `P12_PASSWORD` | That `.p12` password |
| `BUILD_PROVISION_PROFILE_BASE64` | Base64-encoded development or ad hoc provisioning profile covering the exact app ID, App Group and intended device |

Set repository variables `FL_BUNDLE_ID` and `FL_APP_GROUP` if they differ from the
defaults. Dispatch **Build and package iOS app** with `signed` enabled. Signing
credentials are only consumed on explicit manual dispatch, not pull requests.
The script checks profile expiration, exact application ID, group membership,
device-installable profile type and certificate match. It uses a temporary
keychain, restores the runner's keychain list, removes temporary credentials and
checks the final code signature before packaging.

No signing credentials were supplied for the initial development run, so the
delivered build artifacts are labeled unsigned. Do not upload signing secrets as
source files or issue attachments.

## Archived MHA experiment

MHA distribution ended after 0.1.8 at the user's request. Current CI builds the
regular App Group app and two control probes; no enterprise-identity IPA is
produced or included in new releases. Earlier evidence remains in the versioned
validation records for reproducibility.

## Reproducibility

Run `python3 scripts/generate_project.py` after adding native source files and
commit the resulting project. CI rejects stale project files. The icon is generated
by `scripts/generate_icon.py` without external image dependencies. Original
reference clones stay local under the ignored `research/` directory.
