# ForceLegacyUI

A native iOS research app for investigating legacy appearance on iOS 26, with a
read-only LaunchServices inspector and a guarded SDK-metadata experiment engine.

**No legacy appearance override is currently verified on iOS 26.6.2.** The shipped
live-write allowlist is empty. The app does not modify signed app bundles, install
tweaks, reinstall target applications or require a jailbreak. A successful metadata
write is never described as a successful appearance change.

The implementation and evidence are being built and checked in this repository.
See `docs/INVESTIGATION.md`, `docs/TESTING.md` and `docs/BUILDING.md` for the final
research findings, device protocol and build instructions.

License: GPL-3.0-or-later. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
