import Foundation

/// Observed from read-only Info.plist and executable load commands, never from an LS SDK column.
public struct BundleSDKObservation: Codable, Equatable, Sendable {
    public let bundleID: String
    public let bundlePath: String
    public let sdk: SDKVersion
    public let infoSHA256: String
    public let loadCommandsSHA256: String

    public init(bundleID: String, bundlePath: String, sdk: SDKVersion, infoSHA256: String, loadCommandsSHA256: String) {
        self.bundleID = bundleID; self.bundlePath = bundlePath; self.sdk = sdk
        self.infoSHA256 = infoSHA256; self.loadCommandsSHA256 = loadCommandsSHA256
    }
}

public enum LiveStorePolicy {
    public static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains(".") else { return nil }
        var value = "/" + parts.filter { !$0.isEmpty }.joined(separator: "/")
        if value.hasPrefix("/var/") { value = "/private" + value }
        return value
    }

    public static func bundlePath(_ path: String) -> Bool {
        guard let value = canonical(path) else { return false }
        let url = URL(fileURLWithPath: value)
        let parent = url.deletingLastPathComponent()
        return url.lastPathComponent.hasSuffix(".app") && url.lastPathComponent.count > 4
            && UUID(uuidString: parent.lastPathComponent) != nil
            && parent.deletingLastPathComponent().path == "/private/var/containers/Bundle/Application"
    }

    /// LS registration spelling can be folded; native reads still resolve one real .app and check its Info.plist ID.
    /// This comparison is only for bundle observations. Store write paths remain exact and case-sensitive.
    public static func sameBundleRegistration(_ first: String, _ second: String) -> Bool {
        guard bundlePath(first), bundlePath(second), let a = canonical(first), let b = canonical(second) else { return false }
        let left = URL(fileURLWithPath: a), right = URL(fileURLWithPath: b)
        return UUID(uuidString: left.deletingLastPathComponent().lastPathComponent) == UUID(uuidString: right.deletingLastPathComponent().lastPathComponent)
            && left.lastPathComponent.lowercased() == right.lastPathComponent.lowercased()
    }

    public static func storePath(_ path: String) -> Bool {
        guard let value = canonical(path) else { return false }
        let url = URL(fileURLWithPath: value), directory = url.deletingLastPathComponent()
        let container = directory.deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["/private/var/mobile/Containers/Data/InternalDaemon", "/private/var/mobile/Containers/Data/System",
                     "/private/var/containers/Data/System"]
        return url.lastPathComponent.hasPrefix("com.apple.LaunchServices-")
            && url.lastPathComponent.hasSuffix("-v2.csstore")
            && directory.lastPathComponent == "Caches" && directory.deletingLastPathComponent().lastPathComponent == "Library"
            && UUID(uuidString: container.lastPathComponent) != nil
            && roots.contains(container.deletingLastPathComponent().path)
    }
}

/// A checked snapshot is separate from appearance evidence. Construction performs all checks.
public struct SDKSnapshotEvidence {
    let originalSHA256: String
    let device: DeviceIdentity
    let profileDigest: String
    let observations: [BundleSDKObservation]
    let verifiedIDs: Set<String>

    private init(originalSHA256: String, device: DeviceIdentity, profileDigest: String,
                 observations: [BundleSDKObservation], verifiedIDs: Set<String>) {
        self.originalSHA256 = originalSHA256; self.device = device; self.profileDigest = profileDigest
        self.observations = observations; self.verifiedIDs = verifiedIDs
    }

    public static func validate(data: Data, profile: LayoutProfile, device: DeviceIdentity,
                                observations: [BundleSDKObservation], validator: StoreValidator) throws -> SDKSnapshotEvidence {
        try profile.validate(for: device)
        guard device.upstreamAccessCandidate, (3...32).contains(observations.count) else {
            throw LegacyError.unsupported("Single-app experiments need three to thirty-two independent bundle SDK observations on a supported device.")
        }
        try validator.validate(data)
        let store = try CSStore(data: data)
        let records = Dictionary(uniqueKeysWithValues: try store.applications(profile: profile, device: device).map { ($0.bundleID, $0) })
        var seen = Set<String>(), versions = Set<SDKVersion>()
        func hash(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        for fact in observations {
            guard seen.insert(fact.bundleID).inserted, LiveStorePolicy.bundlePath(fact.bundlePath), fact.sdk.isPlausible,
                  hash(fact.infoSHA256), hash(fact.loadCommandsSHA256), let record = records[fact.bundleID],
                  LiveStorePolicy.sameBundleRegistration(record.bundlePath, fact.bundlePath),
                  record.sdk == fact.sdk, let unit = store.tables["Bundle"]?[record.recordKey] else {
                throw LegacyError.conflict("Bundle identity, path or executable SDK disagrees with the layout, or the evidence is incomplete.")
            }
            // Repeated identical triples cannot establish which field is the SDK.
            let matches = stride(from: 0, through: unit.size - 24, by: 4).filter {
                data.subdata(in: (unit.body + $0)..<(unit.body + $0 + 24)) == fact.sdk.bytes
            }
            guard matches == [profile.sdk] else {
                throw LegacyError.unsupported("The SDK triple is absent or ambiguous in \(fact.bundleID); no live authorization was created.")
            }
            versions.insert(fact.sdk)
        }
        guard versions.count >= 2 else { throw LegacyError.unsupported("Layout evidence needs at least two distinct executable SDK versions.") }
        return .init(originalSHA256: sha256(data), device: device, profileDigest: profile.digest,
                     observations: observations, verifiedIDs: seen)
    }
}
