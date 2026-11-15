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
    private enum Scope { case appOwned(URL), reviewedLive(String) }
    private let scope: Scope

    public static func appOwned(directory: URL) -> WriteAuthorization { .init(scope: .appOwned(directory)) }

    public static func reviewedLive(profile: LayoutProfile, device: DeviceIdentity) throws -> WriteAuthorization {
        try profile.validate(for: device)
        guard device.upstreamAccessCandidate, ReviewedLayouts.liveWriteDigests.contains(profile.digest) else {
            throw LegacyError.unsupported("No source-reviewed layout authorizes live writes on this OS build. Imported profiles only permit copy experiments.")
        }
        return .init(scope: .reviewedLive(profile.digest))
    }

    func validate(url: URL, plan: PreparedPlan) throws {
        switch scope {
        case let .appOwned(root):
            let directory = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let target = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard directory != "/", target.hasPrefix(directory) else {
                throw LegacyError.unsupported("Copy experiments must stay inside their app-owned directory.")
            }
        case let .reviewedLive(digest):
            let path = url.standardizedFileURL.path
            let roots = ["/private/var/mobile/Containers/Data/InternalDaemon/", "/private/var/containers/Data/System/"]
            guard digest == plan.profile.digest, ReviewedLayouts.liveWriteDigests.contains(digest),
                  roots.contains(where: path.hasPrefix), path.contains("/Library/Caches/"),
                  url.lastPathComponent.hasPrefix("com.apple.LaunchServices-"), url.pathExtension == "csstore" else {
                throw LegacyError.unsupported("The live target is not an approved LaunchServices store.")
            }
        }
    }
}
