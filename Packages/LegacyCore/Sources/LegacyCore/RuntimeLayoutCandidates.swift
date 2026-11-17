import Foundation

/// Public field-position observations from ForceDuoApp 1.2 are candidates, not OS support claims.
/// Every use requires exact current-device metadata and fresh independent executable observations.
public enum RuntimeLayoutCandidates {
    public static func candidates(for device: DeviceIdentity) -> [LayoutProfile] {
        guard device.upstreamAccessCandidate else { return [] }
        let evidence = ["Candidate field positions investigated in ForceDuoApp 1.2 (5b652000); not a pre-verified iOS 26 profile.",
                        "Requires snapshot-bound independent bundle SDK/identity/path correlation before single-app use."]
        return [
            LayoutProfile(id: "correlated-592-\(device.osBuild)", osVersion: device.osVersion, osBuild: device.osBuild,
                architectures: [device.architecture], recordSize: 592, identifier: 12, duplicateIdentifier: 20,
                kind: 24, sdk: 68, name: 116, fallbackName: 8, bundleName: 320, placeholder: 572, signer: 132, evidence: evidence),
            LayoutProfile(id: "correlated-604-\(device.osBuild)", osVersion: device.osVersion, osBuild: device.osBuild,
                architectures: [device.architecture], recordSize: 604, identifier: 12, duplicateIdentifier: 24,
                kind: 28, sdk: 72, name: 120, fallbackName: 8, bundleName: 324, placeholder: 580, signer: 136, evidence: evidence)
        ]
    }

    public static func correlate(data: Data, device: DeviceIdentity, observations: [BundleSDKObservation],
                                  validator: StoreValidator, log: inout String) throws -> LayoutProfile? {
        let store = try CSStore(data: data)
        var matched: [LayoutProfile] = []
        let sizes = store.summary.bundleRecordSizes.keys.sorted().map(String.init).joined(separator: ", ")
        log += "Layout correlation: Bundle record sizes [\(sizes)]; \(observations.count) independent SDK observations.\n"
        for candidate in candidates(for: device) {
            guard store.summary.bundleRecordSizes[candidate.recordSize] != nil else {
                log += "Candidate \(candidate.id) skipped: required record size \(candidate.recordSize) is absent.\n"
                continue
            }
            do {
                _ = try SDKSnapshotEvidence.validate(data: data, profile: candidate, device: device,
                                                     observations: observations, validator: validator)
                matched.append(candidate)
                log += "Candidate \(candidate.id): independent SDK, identity and bundle-path checks passed.\n"
            } catch { log += "Candidate \(candidate.id) refused: \(error.localizedDescription)\n" }
        }
        guard matched.count <= 1 else { throw LegacyError.unsupported("More than one record signature matched; the layout is ambiguous.") }
        if matched.isEmpty { log += "No independently corroborated layout was found. Export a matching snapshot/report for field review.\n" }
        return matched.first
    }
}
