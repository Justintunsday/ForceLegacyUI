# Mutation boundaries

The app ships with an empty live-write profile allowlist. A JSON profile, plausible
SDK byte pattern, matching record size or successful sandbox grant cannot change it.

Read-only discovery may probe the exact legacy cache directory `/private/var/db/lsd`
and UUID/lsd `Library/Caches` directories under two system-container roots. Extended
search only lists root names and matching cache-file metadata; it does not inspect
unrelated application data. It has directory/entry/time budgets and releases each
extension before advancing. It refuses multiple discovered stores rather than
selecting the newest. The legacy path is not added to live-write authorization.
Time budgets are checked between synchronous system calls and cannot interrupt a
blocked private API. A failed or bounded search does not establish that no store exists.

| Stage | Required condition | Failure behavior |
| --- | --- | --- |
| Discovery | One unambiguous LS store in an allowed cache directory | Refuse; do not choose an arbitrary newest file |
| Snapshot | Regular file, one link, bounded size, stable inode/path and read metadata | Refuse and request fresh inspection |
| Parsing | v2 header, bounded tables/units, unique keys, exact-build reviewed layout | Generic diagnostics only for unknown layouts |
| Planning | Selected identities, paths and SDKs validated; original checksum accepted | No candidate write to the live store |
| Dry run | Reparse candidate; diff only SDK and checksum; checksum accepted | Only app-owned experiment files can be saved |
| Authorization | Fresh preview, source-reviewed digest, one live target | Imported profiles remain copy-only |
| Backup | Immutable original, SHA-256, original values and receipt written, fsynced and read back | Abort before system mutation |
| Commit | Exclusive advisory lock; inode/path/content rechecked after backup | Abort on stale preview or concurrent change |
| Verification | Exact candidate bytes, unchanged inode, fsync, system checksum acceptance | Attempt bounded rollback |
| Rollback | No unrelated byte changed; modified bytes are explained by original/candidate | Keep needsRecovery state if proof fails |
| Restore | Current records re-resolved by identity and expected value | Refuse stale whole-store replacement |

App-owned copies and journals use atomic file replacement plus synchronization.
The mapped system store would require **in-place writes**, which are not a
multi-field atomic transaction. `flock` is advisory and may not be honored by lsd.
The implementation checks for races and preserves recovery data but cannot promise
isolation from a noncooperating daemon. This limitation is one reason live writes
are disabled without a reviewed layout and device protocol.

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

The only writable paths inside an installed app bundle belong to this project's
own **unsigned build output during packaging/signing**. Runtime code never writes
another installed app's signed bundle. No root helper, jailbreak dependency,
daemon-killing operation or system-wide injection is included.
