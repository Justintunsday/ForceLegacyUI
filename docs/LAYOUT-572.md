# 23G90 arm64: 572-byte candidate

A user supplied a matching 0.1.7 report, snapshot and SHA-256 sidecar. Local ZIP
CRC, sidecar and report/snapshot digest checks agreed. The snapshot was 13,942,784
bytes, with 437 Bundle payloads of 572 bytes. The phone report recorded successful
system CoreServicesStore validation. The raw snapshot, report, application
identifiers, signer names and UUIDs remain private and are not included in CI.

The independent observation was ForceLegacyUI's own read-only Info.plist/Mach-O
SDK **26.2.0**. Its unique 24-byte little-endian SDK triple occurred at payload
offset **64 / 0x40**. Both identifier references, the registration filename and the
UUID placeholder matched that observation. This is one witness and one SDK
version; it cannot meet the three-app/two-SDK requirement for live authorization.

| Payload field candidate | Decimal offset | Hex offset |
| --- | ---: | ---: |
| Fallback display name | 8 | 0x08 |
| Identifier / duplicate | 12 / 20 | 0x0c / 0x14 |
| Record kind | 24 | 0x18 |
| SDK: three UInt64 values | 64 | 0x40 |
| Preferred display name | 112 | 0x70 |
| Signer string, diagnostic only | 128 | 0x80 |
| Bundle filename | 320 | 0x140 |
| SerializedPlaceholder.ipa path | 564 | 0x234 |

These are payload offsets, excluding the unit's eight-byte header. Display and
signer strings are descriptive candidates, not fields modified by the planner.
The candidate is restricted to **iOS 26.6.2, build 23G90, arm64**. No arm64e
capture was reviewed. It is not extrapolated to another build or architecture.

The captured catalog also contained 228 same-size/kind records with a **null**
placeholder reference. These are outside the UUID application-container scope;
the reader now excludes them before interpreting application fields. Non-null
malformed placeholders, conflicting duplicate application identities, invalid
paths and implausible SDKs still fail. Dotless identifiers remain outside the
supported reverse-DNS target scope. Exclusion never establishes installation.

The [candidate JSON](../Layouts/candidate-572-23G90-arm64.json) and the compiled
candidate describe the same positions. One fresh native witness can explain
read-only candidate cache values in 0.1.8. Those values are not selectable targets
and are not independent witnesses. The compiled reviewed-live allowlist stays
empty. Three fresh native witnesses across two SDKs, a unique triple in each,
selected-app evidence, system validation, writable-open access and a fresh
single-app preview are still required by the separate experimental path.

The uploaded access log recorded 11 UUID traversal and 11 fixed-root traversal
queries returning **-104: no sandbox token**, leaving one native SDK observation.
0.1.8 adds a bounded retry with upstream alternate flags `0x800000000` after a
denied/tokenless bundle query using `0x8000000000`. Class, group, part, domain,
existing-directory checks, read target and paired token release remain the same.
This alternate flag combination is a device experiment, not demonstrated access.

Synthetic 572-byte fixtures test candidate decoding, exclusion, ambiguous/missing
evidence, exact device binding and one-field planning. They do not validate a
mutated phone snapshot or demonstrate a legacy appearance change. No direct
per-app Boolean field for UIDesignRequiresCompatibility has been established.
