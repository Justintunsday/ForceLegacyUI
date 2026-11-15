# Validation evidence

The final source build and simulator run passed at commit
[`596e0552`](https://github.com/Justintunsday/ForceLegacyUI/commit/596e055291dcfc85cec478cd814d554bff614c4e).
Its [GitHub Actions run](https://github.com/Justintunsday/ForceLegacyUI/actions/runs/43770790014)
contains device/simulator logs, unsigned IPAs, screenshots and machine-readable
probe/self-test evidence. The subsequent documentation commit adds these results
and screenshots without changing application or build source.

The artifact is `ForceLegacyUI-596e055291dcfc85cec478cd814d554bff614c4e`, ID
`14184462461`, with ZIP digest
`e303b397b82cc175623f053834f9a82ba4a53e1f70f736b76608b4ead2147ffc`.
Selected evidence and IPA checksum sidecars are retained in [evidence/](evidence/).

| Check | Observed result |
| --- | --- |
| Local Python tooling | Project generator consistency and Python syntax checks passed in WSL |
| Core safety tests | 17 XCTest cases executed and passed on macOS, including interrupted-checksum recovery and refusal to overwrite unrelated changes |
| Xcode device build | Main app plus Modern and Legacy probes built with Xcode 26.2 / iPhoneOS 26.2 SDK |
| IPA packaging | Three explicitly unsigned IPA files and SHA-256 sidecars produced |
| Simulator build | All three apps built for the iOS simulator |
| Simulator environment | iOS 26.2, iPhone SE (3rd generation) simulator, arm64 runner |
| Launch smoke check | Each app launched, remained listed as a process, and yielded a screenshot |
| Main app integration | Synthetic dry run preserved the source; apply changed it; backup and restore returned exactly to baseline |
| Probe input controls | Both exported Mach-O and dyld SDK 26.2.0 and LS SDK 26.2; their own plist values were respectively false and true |
| Visual inspection | Screenshots showed the marked demo UI and visibly distinct modern/legacy SwiftUI control styling in the two probes; UIKit-tab screenshots were not captured by this smoke run |
| Offline analyzer | Read the exported synthetic store and reproduced its size, table counts and SHA-256 |
| Downloaded IPA checks | All three payloads, Info.plist executable references, Mach-O headers and SHA-256 sidecars verified locally |
| Provisioned signing | Not run: no signing certificate or profile was supplied |
| Physical iOS 26.6.2 | Not run |
| worse_query grant on a non-jailbroken device | Not verified |
| Real iOS 26.6.2 record layout | Not established; no live-write digest is allowed |
| Legacy appearance for another installed app | Not verified |

The main synthetic test recorded:

```text
before/restored SHA-256: 036b8a8fea6b258779071264cbde428629d4a588fd6800365fec8bbf7ea10e36
applied SHA-256:         55103ac3135bc35c4d8bd777c86d5d38f2e925b7cc230f170abaec4fbb2146cc
```

These are synthetic fixture hashes, not samples from an iOS device database.
The probe export's `kern.osversion` is the simulator host's kernel build,
not an iOS device build. It is explicitly labeled `simulator-host-kernel:...`
and an environment discriminator is exported.

The earlier [15-test build](https://github.com/Justintunsday/ForceLegacyUI/actions/runs/43769668198)
also passed. The final run includes both new recovery tests and the Python
analyzer check. Remaining Xcode warnings concern optional AppIntents metadata
extraction for apps with no AppIntents dependency; no source compilation warning
remains in the final build log.

No simulator evidence is promoted to a physical-device compatibility claim.

## Captured simulator screens

<img src="screenshots/ForceLegacyUI.png" width="280" alt="Marked synthetic demo laboratory" />
<img src="screenshots/ModernProbe.png" width="280" alt="Modern probe with opt-out false" />
<img src="screenshots/LegacyProbe.png" width="280" alt="Legacy probe with opt-out true" />
