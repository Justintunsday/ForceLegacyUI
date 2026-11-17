import Foundation

/// Reviewed field-position observations are candidates, not OS support claims.
/// Every use requires exact current-device metadata and fresh independent executable observations.
public enum RuntimeLayoutCandidates {
    public static func candidates(for device: DeviceIdentity) -> [LayoutProfile] {
        guard device.upstreamAccessCandidate else { return [] }
        let evidence = ["Candidate field positions investigated in ForceDuoApp 1.2 (5b652000); not a pre-verified iOS 26 profile.",
                        "Requires snapshot-bound independent bundle SDK/identity/path correlation before single-app use."]
        var result: [LayoutProfile] = []
        if device.osVersion == "26.6.2", device.osBuild == "23G90", device.architecture == "arm64" {
            result.append(LayoutProfile(id: "candidate-572-23G90-arm64", osVersion: device.osVersion, osBuild: device.osBuild,
                architectures: ["arm64"], recordSize: 572, identifier: 12, duplicateIdentifier: 20,
                kind: 24, sdk: 64, name: 112, fallbackName: 8, bundleName: 320, placeholder: 564, signer: 128,
                evidence: ["Read-only field review of a user-supplied 23G90 arm64 snapshot with 437 572-byte records.",
                           "One independently read executable SDK matched uniquely at byte 64; insufficient for live authorization.",
                           "Fresh three-app/two-SDK correlation remains required; appearance is unverified."]))
        }
        result += [
            LayoutProfile(id: "correlated-592-\(device.osBuild)", osVersion: device.osVersion, osBuild: device.osBuild,
                architectures: [device.architecture], recordSize: 592, identifier: 12, duplicateIdentifier: 20,
                kind: 24, sdk: 68, name: 116, fallbackName: 8, bundleName: 320, placeholder: 572, signer: 132, evidence: evidence),
            LayoutProfile(id: "correlated-604-\(device.osBuild)", osVersion: device.osVersion, osBuild: device.osBuild,
                architectures: [device.architecture], recordSize: 604, identifier: 12, duplicateIdentifier: 24,
                kind: 28, sdk: 72, name: 120, fallbackName: 8, bundleName: 324, placeholder: 580, signer: 136, evidence: evidence)
        ]
        return result
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

    /// May explain candidate cache values with one witness. This does not create a write proof.
    public static func inspectReadOnly(data: Data, device: DeviceIdentity, observations: [BundleSDKObservation],
                                       validator: StoreValidator, log: inout String) throws -> ReadOnlyLayoutEvidence? {
        guard !observations.isEmpty else { return nil }
        let sizes = try CSStore(data: data).summary.bundleRecordSizes
        var matched: [ReadOnlyLayoutEvidence] = []
        for candidate in candidates(for: device) where sizes[candidate.recordSize] != nil {
            do {
                let evidence = try ReadOnlyLayoutEvidence.validate(data: data, profile: candidate, device: device,
                    observations: observations, validator: validator)
                matched.append(evidence)
                log += "Read-only candidate \(candidate.id): \(evidence.records.count) UUID registrations; \(observations.count) independent SDK observations. Candidate values do not authorize writes.\n"
            } catch { log += "Read-only candidate \(candidate.id) refused: \(error.localizedDescription)\n" }
        }
        guard matched.count <= 1 else { throw LegacyError.unsupported("More than one read-only candidate matched; no candidate values were selected.") }
        return matched.first
    }
}
