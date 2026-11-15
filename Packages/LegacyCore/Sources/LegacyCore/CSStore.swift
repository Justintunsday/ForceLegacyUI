import Foundation

struct BoundedBytes {
    let data: Data
    func range(_ offset: Int, _ length: Int) throws -> Range<Int> {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
            throw LegacyError.invalid("CoreServicesStore contains an out-of-bounds reference.")
        }
        return offset..<(offset + length)
    }
    func u32(_ offset: Int) throws -> UInt32 {
        let r = try range(offset, 4)
        return r.enumerated().reduce(UInt32(0)) { $0 | UInt32(data[$1.element]) << (8 * $1.offset) }
    }
    func u64(_ offset: Int) throws -> UInt64 {
        let r = try range(offset, 8)
        return r.enumerated().reduce(UInt64(0)) { $0 | UInt64(data[$1.element]) << (8 * $1.offset) }
    }
}

public struct StoreUnit: Codable, Equatable, Sendable {
    public let key: UInt32
    public let offset: Int
    public let size: Int
    public var body: Int { offset + 8 }
}

public struct StoreSummary: Codable, Sendable {
    public let bytes: Int
    public let sha256: String
    public let tableCounts: [String: Int]
    public let bundleRecordSizes: [Int: Int]
    public let containsCompatibilityKeyString: Bool
}

public struct StoreApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let bundlePath: String
    public let sdk: SDKVersion
    public let sdkOffset: Int
    public let recordKey: UInt32
}

/// Independently implemented bounded reader for the table/unit organization investigated in ForceDuoApp.
/// Parsing the container does not assert that an OS-specific Bundle record layout is understood.
public struct CSStore {
    public static let maximumSize = 64 * 1024 * 1024
    public let data: Data
    public let tables: [String: [UInt32: StoreUnit]]

    public init(data: Data) throws {
        guard data.startIndex == 0, data.count >= 100, data.count <= Self.maximumSize,
              data.prefix(5) == Data([0x62, 0x64, 0x73, 0x6c, 0x02]) else {
            throw LegacyError.unsupported("Not a bounded v2 CoreServicesStore. No fields were interpreted.")
        }
        let bytes = BoundedBytes(data: data)
        guard try bytes.u32(20) & 0x40000000 != 0 else {
            throw LegacyError.invalid("The CoreServicesStore catalog marker is missing.")
        }
        let catalog = try Self.readTable(bytes, at: 20)
        var result: [String: [UInt32: StoreUnit]] = [:]
        for entry in catalog.values {
            let name = try Self.unitString(bytes, unit: entry, maximum: 48)
            guard !name.isEmpty, result[name] == nil else {
                throw LegacyError.invalid("The store catalog contains empty or duplicate table names.")
            }
            result[name] = try Self.readTable(bytes, at: entry.offset)
        }
        guard result["Bundle"] != nil, result["<string>"] != nil else {
            throw LegacyError.unsupported("The store does not contain Bundle and <string> tables.")
        }
        self.data = data; self.tables = result
    }

    private static func readTable(_ bytes: BoundedBytes, at unit: Int) throws -> [UInt32: StoreUnit] {
        _ = try bytes.range(unit, 0x50)
        let payload = Int(try bytes.u32(unit + 4))
        guard payload >= 0x48 else { throw LegacyError.invalid("Truncated table unit.") }
        _ = try bytes.range(unit + 8, payload)
        let hash = Int(try bytes.u32(unit + 0x4c))
        guard hash >= 100 else { throw LegacyError.invalid("Invalid table hash reference.") }
        let bucketCount = Int(try bytes.u32(hash))
        guard bucketCount <= 1_000_000 else { throw LegacyError.invalid("Excessive bucket count.") }
        _ = try bytes.range(hash + 4, bucketCount * 8)
        var result: [UInt32: StoreUnit] = [:]
        var visited = 0
        for bucket in 0..<bucketCount {
            let header = hash + 4 + bucket * 8
            let count = Int(try bytes.u32(header))
            if count == 0 { continue }
            guard count <= 1_000_000 - visited else { throw LegacyError.invalid("Excessive table entry count.") }
            visited += count
            let start = Int(try bytes.u32(header + 4))
            guard start >= 100 else { throw LegacyError.invalid("Invalid bucket reference.") }
            _ = try bytes.range(start, count * 8)
            for index in 0..<count {
                let key = try bytes.u32(start + index * 8)
                let raw = try bytes.u32(start + index * 8 + 4)
                if raw == UInt32.max { continue }
                let offset = Int(raw)
                guard offset >= 100 else { throw LegacyError.invalid("Unit overlaps the store header.") }
                _ = try bytes.range(offset, 8)
                let size = Int(try bytes.u32(offset + 4))
                _ = try bytes.range(offset + 8, size)
                guard result[key] == nil else { throw LegacyError.invalid("Duplicate unit key in a table.") }
                result[key] = StoreUnit(key: key, offset: offset, size: size)
            }
        }
        return result
    }

    private static func unitString(_ bytes: BoundedBytes, unit: StoreUnit, maximum: Int) throws -> String {
        let range = try bytes.range(unit.body, min(unit.size, maximum))
        let raw = bytes.data.subdata(in: range).prefix { $0 != 0 }
        guard let value = String(data: raw, encoding: .utf8) else {
            throw LegacyError.invalid("Invalid UTF-8 in a store string.")
        }
        return value
    }

    public var summary: StoreSummary {
        var sizes: [Int: Int] = [:]
        for unit in tables["Bundle", default: [:]].values { sizes[unit.size, default: 0] += 1 }
        return StoreSummary(bytes: data.count, sha256: LegacyCore.sha256(data),
                            tableCounts: tables.mapValues(\.count), bundleRecordSizes: sizes,
                            containsCompatibilityKeyString: data.range(of: Data("UIDesignRequiresCompatibility".utf8)) != nil)
    }

    public func text(at field: Int) throws -> String? {
        let bytes = BoundedBytes(data: data)
        let key = try bytes.u32(field)
        if key & 1 != 0 {
            let alphabet = Array("\0 abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
            var result: [UInt8] = []
            for shift in stride(from: 26, through: 2, by: -6) {
                let c = alphabet[Int((key >> shift) & 63)]
                if c != 0 { result.append(c) }
            }
            return String(bytes: result, encoding: .ascii)
        }
        guard let unit = tables["<string>"]?[key] else { return nil }
        guard unit.size <= 4096 else { throw LegacyError.invalid("Excessive record string length.") }
        return try Self.unitString(bytes, unit: unit, maximum: 4096)
    }

    public func applications(profile: LayoutProfile, device: DeviceIdentity) throws -> [StoreApplication] {
        try profile.validate(for: device)
        let bytes = BoundedBytes(data: data)
        var result: [StoreApplication] = []
        var seen = Set<String>()
        for unit in tables["Bundle", default: [:]].values {
            guard unit.size == profile.recordSize else { continue }
            let b = unit.body
            let identifier = try bytes.u32(b + profile.identifier)
            guard try bytes.u32(b + profile.duplicateIdentifier) == identifier,
                  try bytes.u32(b + profile.kind) == 2 else { continue }
            guard let id = try text(at: b + profile.identifier), id.contains("."),
                  !id.contains("/"), let bundleName = try text(at: b + profile.bundleName),
                  bundleName.hasSuffix(".app"), (bundleName as NSString).lastPathComponent == bundleName,
                  let placeholder = try text(at: b + profile.placeholder),
                  (placeholder as NSString).lastPathComponent == "SerializedPlaceholder.ipa" else {
                throw LegacyError.invalid("An application record failed identity/path validation.")
            }
            let parent = (placeholder as NSString).deletingLastPathComponent
            guard (parent as NSString).deletingLastPathComponent == "/private/var/containers/Bundle/Application",
                  UUID(uuidString: (parent as NSString).lastPathComponent) != nil,
                  seen.insert(id).inserted else {
                throw LegacyError.invalid("Ambiguous application identity or unexpected bundle container.")
            }
            let offset = b + profile.sdk
            let version = try SDKVersion(bytes.u64(offset), bytes.u64(offset + 8), bytes.u64(offset + 16))
            guard version.isPlausible else { throw LegacyError.invalid("Implausible SDK; record layout rejected.") }
            let preferredName = try text(at: b + profile.name)
            let fallback = try text(at: b + profile.fallbackName)
            result.append(StoreApplication(bundleID: id, name: preferredName ?? fallback ?? id,
                bundlePath: parent + "/" + bundleName, sdk: version, sdkOffset: offset, recordKey: unit.key))
        }
        guard !result.isEmpty else { throw LegacyError.unsupported("No application matched the exact profile.") }
        return result.sorted { $0.bundleID < $1.bundleID }
    }

    /// Independent LS proxy observations corroborate a proposed layout; this never authorizes live writes.
    public func crossValidate(_ records: [StoreApplication], catalog: [InstalledApplication]) throws -> Int {
        let groups = Dictionary(grouping: catalog, by: \.bundleID)
        guard groups.values.allSatisfy({ $0.count == 1 }) else { throw LegacyError.invalid("Duplicate catalog identifiers.") }
        var matched = 0
        var versions = Set<SDKVersion>()
        for record in records {
            guard let app = groups[record.bundleID]?.first, let sdk = app.reportedSDK else { continue }
            guard sdk == record.sdk, app.bundlePath == record.bundlePath else {
                throw LegacyError.conflict("LS metadata disagrees with the proposed layout for \(record.bundleID).")
            }
            matched += 1; versions.insert(sdk)
        }
        guard matched >= 3, versions.count >= 2 else {
            throw LegacyError.unsupported("Layout validation needs at least three matching apps and two distinct SDK versions.")
        }
        return matched
    }
}
