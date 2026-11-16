import Foundation
import CryptoKit

public enum LegacyError: LocalizedError, Equatable {
    case invalid(String), unsupported(String), conflict(String), io(String), recovery(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(s), let .unsupported(s), let .conflict(s), let .io(s), let .recovery(s): return s
        }
    }
}

public func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public struct SDKVersion: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    public init(_ major: UInt64, _ minor: UInt64 = 0, _ patch: UInt64 = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { UInt64($0) }
        guard values.count == parts.count else { return nil }
        self.init(values[0], values.count > 1 ? values[1] : 0, values.count > 2 ? values[2] : 0)
        guard isPlausible else { return nil }
    }

    public var isPlausible: Bool { major > 0 && major <= 99 && minor <= 99 && patch <= 99 }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static let legacy = SDKVersion(18)
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    public var bytes: Data {
        var data = Data()
        for var value in [major.littleEndian, minor.littleEndian, patch.littleEndian] {
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public let osVersion: String
    public let osBuild: String
    public let architecture: String
    public let model: String

    public init(osVersion: String, osBuild: String, architecture: String, model: String) {
        self.osVersion = osVersion; self.osBuild = osBuild
        self.architecture = architecture; self.model = model
    }

    public var upstreamAccessCandidate: Bool {
        guard let version = SDKVersion(string: osVersion) else { return false }
        return version >= SDKVersion(26) && version <= SDKVersion(26, 7, 2)
            && ["arm64", "arm64e"].contains(architecture)
    }
}

public struct InstalledApplication: Codable, Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let bundlePath: String
    public let reportedSDK: SDKVersion?
    public let applicationType: String

    public init(bundleID: String, name: String, bundlePath: String,
                reportedSDK: SDKVersion?, applicationType: String = "User") {
        self.bundleID = bundleID; self.name = name; self.bundlePath = bundlePath
        self.reportedSDK = reportedSDK; self.applicationType = applicationType
    }
}

public enum OverrideStatus: String, Codable, Sendable {
    case verified = "Verified", experimental = "Experimental", unsupported = "Unsupported"
}

/// A profile describes a reviewed record layout, not an offset discovered by scanning for a number.
/// Import alone is not write authorization. A single-app experiment additionally requires independent
/// bundle SDK observations, an exact snapshot-bound proof and an explicitly enabled experiment.
public struct LayoutProfile: Codable, Equatable, Sendable {
    public let id: String
    public let osVersion: String
    public let osBuild: String
    public let architectures: [String]
    public let recordSize: Int
    public let identifier: Int
    public let duplicateIdentifier: Int
    public let kind: Int
    public let sdk: Int
    public let name: Int
    public let fallbackName: Int
    public let bundleName: Int
    public let placeholder: Int
    public let signer: Int
    public let evidence: [String]

    public init(id: String, osVersion: String, osBuild: String, architectures: [String],
                recordSize: Int, identifier: Int, duplicateIdentifier: Int, kind: Int, sdk: Int,
                name: Int, fallbackName: Int, bundleName: Int, placeholder: Int, signer: Int,
                evidence: [String]) {
        self.id = id; self.osVersion = osVersion; self.osBuild = osBuild; self.architectures = architectures
        self.recordSize = recordSize; self.identifier = identifier; self.duplicateIdentifier = duplicateIdentifier
        self.kind = kind; self.sdk = sdk; self.name = name; self.fallbackName = fallbackName
        self.bundleName = bundleName; self.placeholder = placeholder; self.signer = signer; self.evidence = evidence
    }

    public func validate(for device: DeviceIdentity) throws {
        guard !id.isEmpty, osVersion == device.osVersion, !osBuild.isEmpty, osBuild == device.osBuild,
              architectures.contains(device.architecture), (64...4096).contains(recordSize), !evidence.isEmpty else {
            throw LegacyError.unsupported("The layout does not match this exact OS version, build and architecture.")
        }
        let fields = [identifier, duplicateIdentifier, kind, name, fallbackName, bundleName, placeholder, signer]
        guard Set(fields).count == fields.count, fields.allSatisfy({ $0 >= 0 && $0 <= recordSize - 4 && $0 % 4 == 0 }),
              sdk >= 0, sdk <= recordSize - 24, sdk % 4 == 0,
              fields.allSatisfy({ !($0..<($0 + 4)).overlaps(sdk..<(sdk + 24)) }) else {
            throw LegacyError.invalid("The profile contains overlapping or out-of-bounds fields.")
        }
    }

    public var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // This value has no optional/non-finite values; JSONEncoder cannot fail for this model.
        return sha256((try? encoder.encode(self)) ?? Data())
    }
}

public enum ReviewedLayouts {
    /// Intentionally empty: the references provide no verified iOS 26.6.2 layout.
    /// A real device capture, independent cross-checks and review are required before adding one.
    public static let profiles: [LayoutProfile] = []
    public static let liveWriteDigests: Set<String> = []
    public static func profile(for device: DeviceIdentity) -> LayoutProfile? {
        profiles.first { (try? $0.validate(for: device)) != nil }
    }
}
