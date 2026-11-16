# Third-party notices

## worse_query

Copyright (C) 2026 Taj C (forcequit). GPL-3.0-or-later.

`ForceLegacyUI/Vendor/worse_query/worse_query.h` and `.m` originate from
[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query) at commit
`d1540e20cd82b974d891e0551ced6d6aeb570ac2`. Original copyright and license headers
are retained. Cleanup, failure-path and paired token-symbol lookup changes are identified in the implementation
and [upstreams.json](docs/upstreams.json). The complete license is in [LICENSE](LICENSE).

## ForceDuoApp research credit

[34306/ForceDuoApp](https://github.com/34306/ForceDuoApp) at commit
`5b65200015f7ed0a0fdf34708bd857e4a34e1f80` (release 1.2) was inspected for LS discovery,
CoreServicesStore organization, SDK metadata and system checksum techniques,
including recent-inode-first scanning and verifying/retrying consumed grants.
No explicit redistribution license was found. Its source and artwork are not
vendored. ForceLegacyUI has its own parser, transaction engine, UI, probes and icon.

## 3105 / MHA-C2 and bad_query research credit

[YangJiiii/3105](https://github.com/YangJiiii/3105) revision
`a72617ed4c764a65d8aac1e91aca95231e72a2cb` was inspected for MHA identity/signing
requirements, retained container access, LS cache locations and inode discovery.
Its original material is GPL-3.0; its third-party notices identify separate upstream
terms, including research without an exposed redistribution license.
[forcequitOS/bad_query](https://github.com/forcequitOS/bad_query) revision
`73ef6da1adabef0982fd00e36cb85f21b8f8194a` was inspected for class-13 partDomain
query semantics; no repository license was found. Neither project's source files
or artwork are redistributed here. `FLContainerAccess` and the bounded discovery
policy are independent implementations restricted to LS cache discovery. MHA-C2
research is credited through 3105 to 0xjohnnydev / FilzaSlop and its contributors.

## Apple sources

Apple developer documentation and the open dyld implementation were consulted as
research evidence; links are in [INVESTIGATION.md](docs/INVESTIGATION.md). Apple
framework binaries and source fragments are not redistributed here. The project
uses system frameworks supplied by the installed OS/Xcode.

Original ForceLegacyUI code is distributed under GPL-3.0-or-later. GitHub Actions
and developer tools keep their respective licenses.
