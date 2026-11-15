# Validation evidence

The first complete Xcode build and simulator run passed at commit
[`acbea902`](https://github.com/Justintunsday/ForceLegacyUI/commit/acbea90234795c8178e95be3841d9cf819abafe3).
Its [GitHub Actions run](https://github.com/Justintunsday/ForceLegacyUI/actions/runs/43769668198)
contains device/simulator logs, unsigned IPAs, screenshots and machine-readable
probe/self-test evidence.

| Check | Observed result |
| --- | --- |
| Local Python tooling | Project generator consistency and Python syntax checks passed in WSL |
| Core safety tests | 15 XCTest cases executed and passed on macOS in the first complete build |
| Xcode device build | Main app plus Modern and Legacy probes built with Xcode 26.2 / iPhoneOS 26.2 SDK |
| IPA packaging | Three explicitly unsigned IPA files and SHA-256 sidecars produced |
| Simulator build | All three apps built for the iOS simulator |
| Simulator environment | iOS 26.2, iPhone SE (3rd generation) simulator, arm64 runner |
| Launch smoke check | Each app launched, remained listed as a process, and yielded a screenshot |
| Main app integration | Synthetic dry run preserved the source; apply changed it; backup and restore returned exactly to baseline |
| Probe input controls | Both exported Mach-O and dyld SDK 26.2.0 and LS SDK 26.2; their own plist values were respectively false and true |
| Visual inspection | Screenshots showed the marked demo UI and visibly distinct modern/legacy control styling in the two probes |
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
The first probe export's `kern.osversion` is the simulator host's kernel build,
not an iOS device build. Subsequent source labels that value explicitly as
`simulator-host-kernel:...` and exports an environment discriminator.

Two interrupted-write recovery tests were added after this first complete run;
their results and the final build will be recorded after the next run completes.
No simulator evidence is promoted to a physical-device compatibility claim.
