# Mutation boundaries

The compiled reviewed-live allowlist is empty. Version 0.1.5 has a separate,
opt-in single-app experiment with snapshot-bound authorization. Importing JSON,
matching a byte count or obtaining a token cannot authorize that experiment alone.

Candidate field-position signatures are never OS support claims. They must parse
the current snapshot and match three independent Info.plist/executable observations
across at least two SDK versions; each SDK triple must be unique in its record.
The exact OS/build/architecture, profile digest, selected ID, source path, original
hash and candidate hash are bound into the authorization. More than one SDK change
is refused. The UI additionally requires an O_RDWR/no-write probe and a fresh preview.

Bundle evidence opens only validated UUID application-bundle paths, Info.plist and
the named executable with read-only/no-follow descriptors. It reads bounded Mach-O
headers/load commands, checks CFBundleIdentifier and stable file identities, and
releases any temporary token. It never opens signed bundles for writing. Queries
use only our resolved dedicated App Group; MHA without group access may have fewer
readable bundles and cannot bypass the three-observation requirement.

Version 0.1.6 can enumerate at most 64 names in the requested bundle's UUID parent
to resolve folded registration spelling. It opens only one matching `.app` name;
ambiguous names, symlinks, changed directory identities and Info.plist ID conflicts
are refused. UUID/name case equivalence is limited to bundle observation comparison;
live store write paths stay exact. Individual LS URLs can supply spelling only for
the same UUID/name and never replace the native metadata read. Scoped parent grants
are paired and tested through Info.plist/executable reads, including when opening
the directory alone succeeded. No request targets the overall Bundle/Application
root, application data or unrelated UUIDs. The current app uses its own bundle path
as an independent observation when its registration is present.

Read-only discovery may probe exact legacy LS cache directories and UUID/lsd
`Library/Caches` directories under the three listed system-container roots. Extended
search only lists root names and matching cache-file metadata; it does not inspect
unrelated application data. It has directory/entry/time budgets and releases each
temporary extension before advancing. MHA lsd leases remain owned by the current
read-only session and are released at its end. It refuses multiple discovered
stores rather than selecting the newest. Single-app writes require an exact UUID
container/Library/Caches primary-name path in one of the three declared roots.
Legacy and prefixed diagnostic sources remain excluded. Traversal requests reject unrelated paths before
calling private APIs; MHA queries require explicit mode, the exact host identity,
class 10/12 and the fixed lsd identifier.
Time budgets are checked between synchronous system calls and cannot interrupt a
blocked private API. A failed or bounded search does not establish that no store exists.
The recent-inode anchor is a heuristic from a temporary file in our own sandbox;
that file is unlinked after fstat/volume checks. It is not a write to any LS store.
The older cursor is scoped to volume/build/boot, and old ascending cursors are not
reused. Token verification requires a successful read-only directory probe; an
ineffective positive token is released before retrying another flag set.

MHA object activation does not depend on optional manual token symbols. Each lease
owns its transport functions, query and activation object until the session ends.
The manual route consumes a token only when its release function is available.
An activation result still requires a real read-only directory-open check.

`SystemDataOnly-` prefixed stores have an unverified catalog role. A single readable
prefixed source can be inspected as a diagnostic fallback; it does not suppress
primary-name discovery. SDK planning, writing and restore reject this source class.

The MHA catalog fallback enumerates class-2 data-registration metadata without
activation/token requests or app-data file reads. Only validated unique identifier
strings are retained. Bundle/SDK fields are filled from matching individual LS
responses, never inferred from a data-container path. Registration presence does
not establish installation or grant SDK-write authority.

| Stage | Required condition | Failure behavior |
| --- | --- | --- |
| Discovery | One unambiguous LS store in an allowed cache directory | Refuse; do not choose an arbitrary newest file |
| Snapshot | Regular file, one link, bounded size, stable inode/path and read metadata | Refuse and request fresh inspection |
| Parsing | v2 header, bounded tables/units, unique keys, exact-build validated layout | Generic diagnostics only for unknown layouts |
| Planning | Selected identities, paths and SDKs validated; original checksum accepted | No candidate write to the live store |
| Dry run | Reparse candidate; diff only SDK and checksum; checksum accepted | Only app-owned experiment files can be saved |
| Authorization | Explicit experiment, exact snapshot/candidate/path proof, independent SDKs, one target | Refuse stale, ambiguous or incomplete evidence |
| Backup | Immutable original, SHA-256, original values and receipt written, fsynced and read back | Abort before system mutation |
| Commit | Exclusive advisory lock; inode/path/content rechecked after backup | Abort on stale preview or concurrent change |
| Verification | Exact candidate bytes, unchanged inode, fsync, system checksum acceptance | Attempt bounded rollback |
| Rollback | No unrelated byte changed; modified bytes are explained by original/candidate | Keep needsRecovery state if proof fails |
| Restore | Current records re-resolved by identity and expected value | Refuse stale whole-store replacement |

App-owned copies and journals use atomic file replacement plus synchronization.
The mapped system store uses **in-place writes**, which are not a
multi-field atomic transaction. `flock` is advisory and may not be honored by lsd.
The implementation checks for races and preserves recovery data but cannot promise
isolation from a noncooperating daemon. The preview, CAS, backup, fsync, verification
and bounded rollback checks remain necessary even after writable-open succeeds.

The private CoreServicesStore helper is queried using unique app-owned files. A
candidate checksum is accepted only after the helper successfully reopens a new
copy. The two-byte store checksum is not confused with backup integrity: backups
also carry a SHA-256 digest. These hashes detect corruption, not the authenticity
of a maliciously rewritten backup or an externally supplied profile.

Backups are never automatically deleted. A prepared receipt survives process death
and is listed for recovery. Ordinary restoration preserves new/unrelated records;
strict interrupted-write recovery has tighter whole-file and inode requirements.
Partial writes handle EINTR/short pwrite operations. A failed backup, checksum
oracle, fsync or post-write comparison is surfaced to the user.
New receipts also retain the layout and independent metadata observations. Restore
revalidates against the immutable original and fresh target fingerprints, so it
does not require a still-loaded imported profile. A receipt-explained active change
remains visible as changed SDK metadata; it is not treated as appearance proof.

The only writable paths inside an installed app bundle belong to this project's
own **unsigned build output during packaging/signing**. Runtime code never writes
another installed app's signed bundle. No root helper, jailbreak dependency,
daemon-killing operation or system-wide injection is included.
