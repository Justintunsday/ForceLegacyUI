# Compatibility investigation

Investigation date: 2026-11-16, Asia/Hong_Kong. Primary requested device: iOS
26.6.2, arm64 / arm64e, without a jailbreak. **No physical-device appearance
result is claimed.** Build and simulator evidence are recorded separately in
[VALIDATION.md](VALIDATION.md).

## Findings and their limits

| Question | Evidence | Conclusion |
| --- | --- | --- |
| Is `UIDesignRequiresCompatibility` a real setting? | [Apple's key documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility) | Yes, it is a Boolean bundle information key. Apple describes earlier SDK appearance when it is enabled. |
| Does minimum deployment version select the design? | [Apple framework engineer's clarification](https://developer.apple.com/forums/thread/838637) | Build SDK and deployment target are different. Setting the deployment target to 18 does not establish legacy appearance. |
| Can the opt-out be assumed to work with any build SDK? | Same Apple documentation and clarification | No. Apple says builds made with the 27 SDK ignore the key, including on supported earlier OS releases. This project's CI selects Xcode 26.2. |
| Does dyld take its program SDK from the LS cache? | [Apple dyld implementation](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldAPIs.cpp), `APIs::dyld_get_program_sdk_version`, `getSdkVersion` | The inspected implementation obtains the program SDK from main-executable image metadata. Changing an LS SDK triple does not itself change this input. |
| Where does the exact iOS 26.6.2 UIKit decision read its flag? | No matching UIKitCore binary, launch trace or device capture was supplied | Unresolved. Apple's bundle-key contract does not establish the private implementation or exclude a derived LS flag. |
| Does SwiftUI consume the LS SDK triple for its design selection? | No matching SwiftUI call graph or device A/B result | Unresolved. The two probes exercise SwiftUI and UIKit separately. |
| Is an injectable per-app compatibility Boolean established in `.csstore`? | The reference engines edit SDK triples; neither identifies such a Boolean | No established writable field. String presence or absence alone cannot answer this. |
| Are the reference record offsets suitable for 26.6.2? | Pinned ForceDuoApp engine documents layouts for 27.1 and 27.3 | No. Those offsets are not shipped as iOS 26 profiles. |

The distinction is between three separate observations: a store field was
changed, a process received different launch inputs, and that process rendered
different controls. None implies the next without a measurement.

## Reference projects actually inspected

The local `research/` clones are excluded from this repository; exact revisions
are recorded in [upstreams.json](upstreams.json).

### ForceDuoApp

Inspected [revision 65e8b686](https://github.com/34306/ForceDuoApp/tree/65e8b6866e637ba695f594d4d718108c13a51635), including
`FDEngine.m`, entitlements and project settings. Its mechanism is:

1. Obtain the `com.apple.lsd` container path through containermanager metadata;
   also inspect the process's mapped store paths, with inode discovery as a fallback.
2. Use worse_query with a dedicated, entitled App Group to acquire directory access.
3. Read v2 CoreServicesStore catalog, Bundle and string tables.
4. Interpret a matching Bundle layout and edit the three 64-bit SDK components.
5. Ask CoreServicesStore to calculate/validate the changed store checksum.
6. Write SDK fields and checksum in place, preserving the mapped file's inode.

The reference lists 592-byte and 604-byte payload layouts, described as iOS 27.1
and 27.3. Their SDK offsets are respectively `0x44` and `0x48` relative to the
record payload. **A byte count is not an OS-version signature.** Its project
targets iOS 27.0, and its phone-layout demonstration is not evidence of a legacy
appearance toggle on 26.6.2.

No explicit license was found in that clone. ForceLegacyUI does not redistribute
its engine or UI code. The bounded reader and transaction engine here are separate
implementations informed by the investigated data organization and techniques.

### worse_query

Vendored from [revision d1540e20](https://github.com/forcequitOS/worse_query/tree/d1540e20cd82b974d891e0551ced6d6aeb570ac2), under GPL-3.0-or-later.
The primitive redirects the app's own App Group `Library/Caches` via a symlink,
issues a class-7 containermanager query for part 3, obtains a sandbox token and
consumes it. Two upstream query-flag variants are retained. The symlink is removed
and the extension is explicitly released after use.

The pinned README reports iOS 26.0–26.7.2 / 27.2 access, including application and
InternalDaemon data containers. Its System container claims are specifically
qualified for iOS 27. These are **upstream reports**, not our test results. The
app restricts attempts to the reported iOS 26 range and dedicated LS cache paths.
Denied queries or missing symbols remain normal unsupported results.

The integration changes cleanup to unlink only a symlink or remove an empty
directory, refuses nonempty App Group caches, frees a failed query, recovers an
interrupted symlink setup, and runs requests serially. It does not enumerate or
modify arbitrary application data containers. Read-only inspection may change
our dedicated App Group's temporary symlink; it does not write the LS store.

Version 0.1.2 corrects an earlier omission when both mapped-store inspection and
container metadata queries return no paths: it also tries the reference's fixed
lsd cache locations. Explicit extended discovery can list candidate UUID/lsd cache
directories under the two allowed system-container roots before a bounded inode
scan. Only matching LS cache-file metadata is read during discovery. Every grant,
directory-open failure and search limit is reported. Upstream's iOS 27 qualification
for System containers still applies; adding a discovery attempt is not evidence of
access on iOS 26.6.2. The legacy `/private/var/db/lsd` location is read-only and is
not added to live-write authorization.

Physical-device process architecture now comes from the running Mach-O header.
The previous `uname.machine` value identifies a phone model such as `iPhone17,3`,
not its arm64/arm64e process architecture. Hardware model remains a separate field.

## Approach A: LaunchServices Boolean override

No field with established ownership, representation, checksum consequences and
UIKit/SwiftUI consumption was identified for the requested OS. A cache may contain
derived state without storing the literal key, so absence of its UTF-8 string is
not treated as proof. A matching string likewise does not authorize insertion or
bit flipping.

There is deliberately no code to inject a plist key into an unknown record. To
enable this approach requires a 26.6.2 capture plus a differential/trace result
identifying the actual decision field and a reviewed serializer for that field.

## Approach B: reported SDK downgrade to 18.0.0

This is implemented as an **SDK metadata experiment**, not a verified appearance
override. The planner accepts exact-build profiles, validates every selected app's
identity and bundle container, cross-checks at least three apps across two SDK
versions against independent LS proxy observations, changes only the 24-byte SDK
triple and the checksum, and reparses the result.

Imported profiles permit experiments on app-owned copies. They cannot authorize
live writes. `ReviewedLayouts.liveWriteDigests` is empty because there is no
reviewed 26.6.2 layout or device appearance evidence. This is an explicit safety
boundary, not a hidden successful implementation.

The falsifiable next experiment is to downgrade **one Modern Probe registration**
on a reviewed layout, cold-launch the same unchanged probe executable, and compare
its exported LS SDK, Mach-O SDK, dyld SDK and both UI control screens. The Legacy
Probe, whose own signed plist opts out at build time, is the positive control.
If the LS field changes but the UI does not, the SDK metadata hypothesis has failed
for that app/build. Do not reinterpret successful byte verification as success.

## Approach C: other sources

worse_query is a file-access primitive, not execution inside another application's
process. Its reported data-container scope does not provide an established path
to rewrite another signed app's bundle information. Code in this project never
opens target bundles for writing. Changing an arbitrary preferences plist or a
same-named key in a data directory has no demonstrated consumer in UIKit.

No per-app preference domain, environment override or registration API that meets
the non-jailbreak/no-target-resigning constraints was established. Accessibility
appearance settings are not equivalent to the SDK compatibility contract and are
not used as a claimed replacement. No tweak or system injection implementation is
included.

## Reverse-engineering tools delivered

* `scripts/analyze_snapshot.py`: bounded, read-only offline catalog and candidate
  column inventory; accepts the app's diagnostic report as corroborating input.
* `scripts/trace_compatibility.py`: LLDB entry tracing for our own debuggable probe's
  bundle-key reads and dyld SDK queries, preserving return values.
* `scripts/inspect_binary.py`: hash, load-command and relevant-symbol inventory
  for a researcher-supplied UIKitCore/SwiftUI image on macOS.
* Modern and Legacy probes: default UIKit and SwiftUI controls, signed-plist
  controls, main-executable SDK inspection and launch-fact export.

These enable further investigation but do not replace a matching-device call graph.
See [TESTING.md](TESTING.md) for the evidence required before changing the allowlist.
