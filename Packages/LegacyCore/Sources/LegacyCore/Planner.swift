import Foundation

public protocol StoreValidator {
    func validate(_ data: Data) throws
    /// Must return the same bytes except for the v2 checksum at 6..<8.
    func repairingChecksum(_ data: Data) throws -> Data
}

public struct SDKChange: Codable, Equatable, Sendable {
    public let bundleID: String
    public let bundlePath: String
    public let original: SDKVersion
    public let target: SDKVersion
}

public struct BytePatch: Equatable, Sendable {
    public let offset: Int
    public let original: Data
    public let replacement: Data
    public var range: Range<Int> { offset..<(offset + original.count) }
}

public struct PreparedPlan {
    public let original: Data
    public let candidate: Data
    public let changes: [SDKChange]
    public let patches: [BytePatch]
    public let profile: LayoutProfile
    public let device: DeviceIdentity
    public var summary: String {
        changes.map { "\($0.bundleID): \($0.original) → \($0.target)" }.joined(separator: "\n")
    }
}

public enum SDKPlanner {
    public static func prepare(data: Data, profile: LayoutProfile, device: DeviceIdentity,
                               targets: [String: SDKVersion], validator: StoreValidator) throws -> PreparedPlan {
        guard !targets.isEmpty else { throw LegacyError.invalid("Select at least one application.") }
        try validator.validate(data)
        let store = try CSStore(data: data)
        let records = try store.applications(profile: profile, device: device)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.bundleID, $0) })
        guard targets.keys.allSatisfy({ byID[$0] != nil }), targets.values.allSatisfy(\.isPlausible) else {
            throw LegacyError.invalid("A selected application or requested SDK is not valid in this snapshot.")
        }
        var candidate = data
        var changes: [SDKChange] = []
        var patches: [BytePatch] = []
        for id in targets.keys.sorted() {
            guard let record = byID[id], let target = targets[id], record.sdk != target else { continue }
            let range = record.sdkOffset..<(record.sdkOffset + 24)
            candidate.replaceSubrange(range, with: target.bytes)
            patches.append(BytePatch(offset: record.sdkOffset, original: record.sdk.bytes, replacement: target.bytes))
            changes.append(SDKChange(bundleID: id, bundlePath: record.bundlePath, original: record.sdk, target: target))
        }
        guard !changes.isEmpty else { throw LegacyError.invalid("The selected applications already report the requested SDK.") }
        let sdkCandidate = candidate
        candidate = try validator.repairingChecksum(candidate)
        guard candidate.count == data.count else { throw LegacyError.invalid("The checksum operation changed the file length.") }
        for index in candidate.indices where !(6..<8).contains(index) && candidate[index] != sdkCandidate[index] {
            throw LegacyError.invalid("Checksum repair changed bytes outside its field.")
        }
        let checksum = BytePatch(offset: 6, original: data.subdata(in: 6..<8), replacement: candidate.subdata(in: 6..<8))
        if checksum.original != checksum.replacement { patches.append(checksum) }
        for (index, patch) in patches.enumerated() {
            guard patch.original.count == patch.replacement.count,
                  !patches.prefix(index).contains(where: { $0.range.overlaps(patch.range) }) else {
                throw LegacyError.invalid("Overlapping mutation ranges.")
            }
        }
        // Patching all permitted fields must reproduce the candidate exactly.
        var replay = data
        for patch in patches { replay.replaceSubrange(patch.range, with: patch.replacement) }
        guard replay == candidate else { throw LegacyError.invalid("The candidate changed unapproved bytes.") }
        try validator.validate(candidate)
        let updated = try CSStore(data: candidate).applications(profile: profile, device: device)
        guard updated.count == records.count else { throw LegacyError.invalid("Candidate record count changed.") }
        for (before, after) in zip(records, updated) {
            guard before.bundleID == after.bundleID, before.name == after.name,
                  before.bundlePath == after.bundlePath, before.sdkOffset == after.sdkOffset,
                  before.recordKey == after.recordKey, after.sdk == (targets[before.bundleID] ?? before.sdk) else {
                throw LegacyError.invalid("The candidate did not round-trip to the requested records.")
            }
        }
        return PreparedPlan(original: data, candidate: candidate, changes: changes, patches: patches, profile: profile, device: device)
    }
}

public struct WriteAuthorization {
    private struct SingleAppScope {
        let digest: String, before: String, after: String, bundleID: String, sourcePath: String
        let device: DeviceIdentity
        let observations: [BundleSDKObservation]
    }
    private enum Scope {
        case appOwned(URL), reviewedLive(String)
        case singleApp(SingleAppScope)
    }
    private let scope: Scope

    public static func appOwned(directory: URL) -> WriteAuthorization { .init(scope: .appOwned(directory)) }

    public static func reviewedLive(profile: LayoutProfile, device: DeviceIdentity) throws -> WriteAuthorization {
        try profile.validate(for: device)
        guard device.upstreamAccessCandidate, ReviewedLayouts.liveWriteDigests.contains(profile.digest) else {
            throw LegacyError.unsupported("No compiled reviewed-live permission exists for this build. The separate single-app flow requires fresh independent SDK evidence.")
        }
        return .init(scope: .reviewedLive(profile.digest))
    }

    /// Experimental authorization is bound to one checked plan, never a general write-enable switch.
    public static func validatedSingleApp(plan: PreparedPlan, evidence: SDKSnapshotEvidence, source: URL) throws -> WriteAuthorization {
        guard plan.changes.count == 1, let change = plan.changes.first,
              evidence.verifiedIDs.contains(change.bundleID), plan.device == evidence.device,
              plan.profile.digest == evidence.profileDigest, sha256(plan.original) == evidence.originalSHA256 else {
            throw LegacyError.unsupported("Single-app authorization requires fresh, matching evidence for the selected app and snapshot.")
        }
        return try boundSingleApp(plan: plan, source: source, observations: evidence.observations)
    }

    var bundleEvidence: [BundleSDKObservation]? {
        if case let .singleApp(proof) = scope { return proof.observations }; return nil
    }

    private static func boundSingleApp(plan: PreparedPlan, source: URL, observations: [BundleSDKObservation]) throws -> WriteAuthorization {
        guard source.isFileURL, LiveStorePolicy.storePath(source.path), plan.changes.count == 1,
              let id = plan.changes.first?.bundleID, let path = LiveStorePolicy.canonical(source.path) else {
            throw LegacyError.unsupported("A single-app experiment requires an exact primary-name LS store target.")
        }
        return .init(scope: .singleApp(.init(digest: plan.profile.digest, before: sha256(plan.original), after: sha256(plan.candidate),
                                           bundleID: id, sourcePath: path, device: plan.device, observations: observations)))
    }

    private static func checkedBackup(_ backup: BackupEntry, profile: LayoutProfile, device: DeviceIdentity,
                                      observations: [BundleSDKObservation], source: URL, validator: StoreValidator) throws -> (BackupEntry, Data, SDKSnapshotEvidence) {
        let checked = try BackupRepository.load(backup.directory), receipt = checked.receipt
        guard [.applied, .prepared, .needsRecovery].contains(checked.status), receipt.changes.count == 1,
              receipt.sourceName == source.lastPathComponent, receipt.profileDigest == profile.digest,
              receipt.layout == profile, receipt.device == device, let old = receipt.bundleEvidence,
              let target = receipt.changes.first?.bundleID,
              let baseline = old.first(where: { $0.bundleID == target }),
              observations.first(where: { $0.bundleID == target }) == baseline else {
            throw LegacyError.conflict("The backup, source, device or selected bundle metadata changed; refusing experimental restoration.")
        }
        let original = try Data(contentsOf: checked.directory.appendingPathComponent("original.csstore"))
        let evidence = try SDKSnapshotEvidence.validate(data: original, profile: profile, device: device,
                                                       observations: observations, validator: validator)
        return (checked, original, evidence)
    }

    public static func validatedRestoration(plan: PreparedPlan, backup: BackupEntry, observations: [BundleSDKObservation],
                                            source: URL, validator: StoreValidator) throws -> WriteAuthorization {
        let (checked, _, _) = try checkedBackup(backup, profile: plan.profile, device: plan.device,
                                               observations: observations, source: source, validator: validator)
        let reproduced = try TransactionEngine.restorationPlan(backup: checked, current: plan.original, profile: plan.profile,
                                                               device: plan.device, validator: validator)
        guard reproduced.candidate == plan.candidate, reproduced.changes == plan.changes else {
            throw LegacyError.invalid("The restore plan does not reproduce the checked receipt.")
        }
        return try boundSingleApp(plan: plan, source: source, observations: observations)
    }

    /// Recognizes our own still-active SDK change without mistaking its expected SDK mismatch for a new layout.
    public static func activeChangeLayout(backup: BackupEntry, current: Data, device: DeviceIdentity,
                                          observations: [BundleSDKObservation], source: URL, validator: StoreValidator) throws -> LayoutProfile {
        guard backup.status == .applied, let profile = backup.receipt.layout, LiveStorePolicy.storePath(source.path) else {
            throw LegacyError.unsupported("No applied single-app receipt describes this source.")
        }
        let (checked, _, _) = try checkedBackup(backup, profile: profile, device: device,
                                               observations: observations, source: source, validator: validator)
        try validator.validate(current)
        let records = try CSStore(data: current).applications(profile: profile, device: device)
        guard let change = checked.receipt.changes.first, let target = records.first(where: { $0.bundleID == change.bundleID }),
              target.sdk == change.target, target.bundlePath == change.bundlePath else {
            throw LegacyError.conflict("The current SDK no longer matches the active receipt.")
        }
        for fact in observations {
            guard let record = records.first(where: { $0.bundleID == fact.bundleID }), LiveStorePolicy.sameBundleRegistration(record.bundlePath, fact.bundlePath),
                  record.sdk == (fact.bundleID == change.bundleID ? change.target : fact.sdk) else {
                throw LegacyError.conflict("Current records contain an unexplained SDK/path change.")
            }
        }
        return profile
    }

    public static func validatedRecovery(backup: BackupEntry, profile: LayoutProfile, device: DeviceIdentity,
                                         observations: [BundleSDKObservation], source: URL, validator: StoreValidator) throws -> WriteAuthorization {
        let (checked, original, evidence) = try checkedBackup(backup, profile: profile, device: device,
                                                             observations: observations, source: source, validator: validator)
        let targets = Dictionary(uniqueKeysWithValues: checked.receipt.changes.map { ($0.bundleID, $0.target) })
        let plan = try SDKPlanner.prepare(data: original, profile: profile, device: device, targets: targets, validator: validator)
        guard plan.changes == checked.receipt.changes, sha256(plan.candidate) == checked.receipt.candidateSHA256 else {
            throw LegacyError.invalid("Recovery cannot reproduce the saved candidate.")
        }
        return try validatedSingleApp(plan: plan, evidence: evidence, source: source)
    }

    func validate(url: URL, plan: PreparedPlan) throws {
        guard url.isFileURL else { throw LegacyError.invalid("Write authorization requires a local file URL.") }
        switch scope {
        case let .appOwned(root):
            let directory = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let target = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard directory != "/", target.hasPrefix(directory) else {
                throw LegacyError.unsupported("Copy experiments must stay inside their app-owned directory.")
            }
        case let .reviewedLive(digest):
            guard digest == plan.profile.digest, ReviewedLayouts.liveWriteDigests.contains(digest),
                  plan.changes.count == 1, LiveStorePolicy.storePath(url.path) else {
                throw LegacyError.unsupported("The live target is not an approved LaunchServices store.")
            }
        case let .singleApp(proof):
            guard LiveStorePolicy.storePath(url.path), LiveStorePolicy.canonical(url.path) == proof.sourcePath,
                  proof.digest == plan.profile.digest, proof.device == plan.device,
                  plan.changes.count == 1, plan.changes.first?.bundleID == proof.bundleID,
                  sha256(plan.original) == proof.before, sha256(plan.candidate) == proof.after else {
                throw LegacyError.unsupported("The single-app proof does not authorize this target, snapshot or candidate.")
            }
        }
    }
}
