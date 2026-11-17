# Device and simulator test protocol

## Discovery regression checks on macOS

The CI step **Discovery fallback regression tests** compiles the production
Foundation discovery coordinator and Mach-O architecture reader against injected
denied/empty/mapped/cache responses. It checks the fixed-path fallback, extension
search limits, unrelated-path rejection, ambiguous-store refusal and arm64/arm64e
subtype reporting. Its JSON report explicitly records that no physical-device
sandbox access was tested. These checks supplement the Swift package's transaction
tests and the native simulator catalog smoke test; they do not validate worse_query
on a physical device.

The native executable also injects a transport into the production MHA lease
implementation (test entry points are compiled only into this test executable).
It covers missing manual APIs with working object activation, paired manual
fallback, refusal to consume unreleasable tokens, actual-readability requirements,
existing readable access, path rejection, denied queries and lifetime cleanup.
Prefixed-cache cases verify diagnostic classification, continued primary search
and refusal to hide ambiguity. These are synthetic responses, not device grants.
Metadata tests separately cover class/flags, deduplication, invalid-ID rejection,
record limits, absent iterator symbols, query cleanup and unavailable SDK/path
fields. They assert that metadata enumeration performs no activation or file probe.

The 0.1.5 core tests check single-plan/path/device/hash binding, one-target limits,
stale proofs, duplicate SDK triples, native-fingerprint mismatches, receipt-backed
active SDK display, restoration/recovery and no-write writable probes. Alternate
592/604 fixtures are synthetic: they verify candidate rejection/corroboration code,
not the layout on a real phone. A shifted field and unsupported OS must fail.
Placeholder `/var` aliases must still agree with canonical bundle paths. ZIP output
is extracted using the system unzip implementation; offline Python tests verify
snapshot/report agreement, independent evidence provenance and numeric-key collisions.

The 0.1.6 cases also check unique folded-name resolution, bounded/ambiguous names,
same-UUID path correlation, receipt matching with resolved spelling, subfile grant
retry, ineffective positive-token release, alternate flags, unavailable release
callbacks and rejection of identity conflicts/symlinks. Temporary file fixtures
simulate access changes; they do not exercise an actual sandbox grant. Missing
candidate sizes must be reported without inferring a replacement layout. Offline
analysis retains candidate field references when bundle filename/UUID spelling differs.

The 0.1.7 native cases exercise the complete denied-standard/denied-alternate/
scoped-traversal/fixed-root sequence, independent fallback when worse_query is
unavailable, metadata-read enforcement and release. Injected transport checks
bind class 13, the fixed system group, part, flags and exact domain; unsafe targets,
unverifiable directories, absent paired APIs, rejected queries and missing tokens
must stop. The root capability changes no read target. These tests do not establish
kernel approval of a Bundle/Application extension on a phone.

The symbol-lookup test exercises the production resolver using the exported
operation-part/part-domain names. New scan tests inject inode paths and time to
check descending anchors above forty million, overflow fallback, primary filename
priority, continued scanning after diagnostic observations, timeout/resume and
stale/malformed checkpoint rejection. Grant tests require a successful read probe,
release ineffective positive tokens and retry alternate flags; EPERM and EACCES
both remain failures. These tests do not measure device filesystem performance.

## First run on iOS 26.6.2

The 0.1.8 core cases use synthetic 572-byte payloads to check exact build/architecture
binding, one-witness read-only decoding without a write proof, wrong/ambiguous SDK
rejection, null-placeholder scope, malformed non-null path refusal and one-field
planning with full evidence. Native cases retry the alternate traversal flags only
after denied/tokenless results, preserve the UUID/fixed-root domain, dispose every
query and leave one paired token owner. The private phone capture is not sent to CI.

1. Sign and install ForceLegacyUI with a dedicated, provisioned App Group as
   described in [BUILDING.md](BUILDING.md). No root tool, jailbreak framework or
   modification of an installed target bundle is used.
2. Record the exact iOS version **and build**, hardware model and process
   architecture shown in Diagnostics. This release has no reviewed 26.6.2 layout,
   so **Unsupported** for the live override is expected.
3. Run **Read-Only Inspection**. Save the diagnostic report locally. If normal
   discovery fails, **Extended Store Discovery** performs a bounded path scan.
   A failed grant or an incomplete installed-app list is a result to record,
   not a reason to guess a container path or offsets.
4. Optionally save the raw snapshot. Retrieve it and its SHA-256 file through
   Files / Finder file sharing. Raw caches and reports may contain private app
   metadata; do not post them publicly without inspection and redaction.
5. Keep **Dry run** enabled. The live planner refuses an unknown layout.

Read-only mode reads the system cache but uses the app's own temporary App Group
symlink while acquiring access. It does not write the system cache. All sandbox
extension handles are released after each operation.

## Test working components immediately

In **Diagnostics**, enable **Demo laboratory**. This is prominently labeled and
uses synthetic data in the app's Documents directory.

1. Select one sample app, keep Dry run on, and tap **Preview Changes**.
2. Verify the preview's original and candidate hashes differ while the displayed
   reported SDK remains unchanged.
3. Turn Dry run off and tap **Apply Changes**. The selected synthetic record should
   report 18.0.0. A backup should appear under Restore.
4. Use **Restore Original Configuration**. Confirm the original SDK returns and
   the receipt is marked restored.
5. Repeat a dry run with Select All / Deselect All. These are synthetic batch
   checks, not authorization to batch-write a device's LS store.

This tests parser/planner/UI/backup/restore integration. It does not exercise the
container escape, an actual LS record layout, or another application's appearance.

## Establishing a real layout

```sh
python3 scripts/analyze_snapshot.py snapshot.csstore --catalog report.json --output analysis.json
```

The tool reports sizes and candidate columns without writing the snapshot.
Repeated identity references and SDK byte matches are observations only. Verify
record identity, kind, name, bundle name, placeholder/container path, SDK triple,
checksum behavior and nonselected records independently. Do not select an offset
merely because it contains `26` or because its record size resembles iOS 27.

The invalid `Profiles/profile.template.json` documents the expected schema. Once
every field is established, create a profile containing the exact captured OS
build and evidence references. Import it in Diagnostics. The app requires:

* Exact OS version, build and architecture matching.
* Distinct, bounded fields; no overlap with the SDK triple.
* Unique bundle identity and a valid application container path.
* At least three independent bundle/executable SDK observations spanning two SDK versions.
* System CoreServicesStore acceptance of the original and repaired candidate.
* A candidate diff confined to selected SDK triples and checksum bytes.

Import alone creates no live authorization. Version 0.1.5 checks an imported
profile or one of the read-only reference-signature candidates against fresh native
bundle observations and unique SDK columns. A successful O_RDWR open writes zero
bytes. Only a fresh preview plus an explicitly enabled, one-app, snapshot/path/hash
bound capability can reach Apply. Examine the saved copies under CopyExperiments.
Record-layout proof and appearance proof remain separate decisions.

## Tracing UIKit and SwiftUI inputs

Build the Modern and Legacy probes with Xcode 26.x, keeping the build SDK and all
sources equal except each probe's own plist opt-out and identity. They are separate
control apps; the tested target is not reinstalled or re-signed during an experiment.

Export `launch-facts.json` from both probes and capture the SwiftUI and UIKit tabs
under the same orientation, text size, appearance, accessibility settings and
device OS. Record the signed binary and Info.plist hashes before any metadata test.

For a debuggable probe under Xcode, stop at the executable entry **before UIKit
initialization**, then run:

```lldb
command script import /absolute/path/to/scripts/trace_compatibility.py
fl-trace-start /absolute/path/to/output/trace.jsonl
continue
```

`fl-trace-stop` removes only this script's breakpoints. Trace callbacks observe
key/API entries and callers; they do not swizzle methods, change return values or
inject into other apps. A late attach may miss cached decisions. A missing key
trace may mean an alternate or bulk dictionary read; it is not negative proof.
Follow captured UIKitCore/SwiftUI callers in a disassembler/debugger to establish
the final condition and its consumed value on the **matching OS build**.

`scripts/inspect_binary.py` can inventory a locally supplied authorized framework
image. This repository does not distribute Apple binaries or require extracting
them from a jailbroken device.

## One-app appearance experiment, after source review

No iOS 26.6.2 profile is claimed as pre-verified. Candidate signatures must pass
the current device's independent structure/SDK checks; byte count or OS-label
substitution is insufficient. Unknown fields still need capture and review.
The compiled allowlist stays empty; the single-app experiment has its own narrow
capability. See [the user workflow](SINGLE-APP.zh-Hant.md).

After the exact-device checks pass:

1. Back up the device normally. Choose only the Modern Probe initially.
2. Run read-only inspection and export the baseline. Enable the single-app experiment, then run a fresh one-app dry run.
3. Apply once with the same selection. Retain the verified receipt and original snapshot.
4. Cold-launch the unchanged Modern Probe. Collect the new facts, trace and both
   control-screen screenshots. Log any LS reload, app termination or device restart;
   the app does not kill system services or claim a cache refresh occurred.
5. Compare LS reported SDK, Mach-O SDK, dyld SDK, actual key reads and UI rendering
   separately. Ask whether the probe moved toward the Legacy control, not merely
   whether the cache now contains 18.0.0.
6. Restore using the receipt. Cold-launch again and capture the reversal.

Batch live operations remain disabled in this release, even after importing a
profile or recording a subjective observation. A successful single-app reversible
A/B result must be independently reviewed before a future implementation enables
batch writes or a Verified appearance status.

## Recovery

For an ordinary applied receipt, restoration reparses the current database and
restores only recorded app fields if the bundle path and expected value still
match. Other current records are preserved. A removed/reinstalled app or unexpected
current SDK causes a refusal.

A pending/interrupted receipt can also recover a torn checksum write, but only
on the same inode, device and size, with all unrelated bytes identical to the
saved original and every changed byte explainable by that transaction's candidate.
It saves the interrupted state before restoring. If that proof fails, retain all
backups and export diagnostics. Never replace a current system database with an
old whole-file snapshot.
