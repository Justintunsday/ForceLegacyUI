# 0.1.8 phone feedback: 23G90 arm64

A second user-provided evidence ZIP was reviewed locally on 2026-11-17. ZIP CRC,
snapshot sidecar SHA-256 and report/snapshot digest agreed. The report identifies
ForceLegacyUI **0.1.8, build 10**, iOS **26.6.2 / 23G90**, iPhone17,3 / arm64,
using the **regular App Group backend**. The original archive and extracted
application metadata remain private and are not committed or sent to CI.

The primary-name store was readable and the phone's system validator accepted
the copy. It contains 437 Bundle units of 572 bytes. The compiled candidate
successfully decoded 156 UUID registrations and matched candidate SDK values
to all 134 entries in the existing generic inventory. `storeError` is absent.
This is reported phone evidence for read-only candidate decoding, not installation
proof, a live write, or an appearance change.

The independent native SDK observation count remains **one**, from the running
app, with SDK **26.2.0** uniquely matching payload offset **64**. No additional
native bundle was read:

* Eleven standard and eleven alternate worse_query requests returned **-6**.
* For eleven UUID and eleven fixed-root traversal stages, standard flags returned
  **-104**, followed by the added alternate-flag retry.
* All 44 traversal query attempts returned no sandbox token. Both final stage
  results remained **-104** for each of the eleven other bundle targets.

`layoutValidated` and `singleAppWriteReady` are false. `writableOpen` is absent:
the SDK experiment has not passed its evidence gate and therefore has not reached
the no-write O_RDWR probe. This log does not establish that the LS cache itself
cannot be opened for writing. The SDK planner still requires three independent
apps across two SDK versions; decoded cache values cannot supply those witnesses.

The new evidence does not justify another flag permutation or a smaller SDK
proof requirement. The available next access comparison is the already-built
[0.1.8 MHA variant](ENTERPRISE-MHA.zh-Hant.md) signed using the user's successful
3105 enterprise process with the unchanged MobileHouseArrest identity. That
identity/backend was not used in this ZIP. Its access must be tested; the user's
earlier success with app-data folders does not prove signed-bundle readability.
Installing that variant can replace 3105 because it shares the bundle identifier.

No program changes or new binary release are justified by this feedback alone.
The 0.1.8 candidate fix is functioning; the alternate traversal flags did not
improve other-bundle access in the reported regular-build session.
