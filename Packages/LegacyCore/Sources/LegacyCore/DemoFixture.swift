import Foundation

/// Synthetic data for demonstrations and fault testing. Never a source of device layout evidence.
public struct DemoFixture {
    public let data: Data
    public let catalog: [InstalledApplication]
    public static let device = DeviceIdentity(osVersion: "26.6.2", osBuild: "DEMO-NOT-A-DEVICE", architecture: "arm64", model: "Synthetic fixture")
    public static let profile = LayoutProfile(id: "synthetic-v1-not-for-device-use", osVersion: "26.6.2",
        osBuild: "DEMO-NOT-A-DEVICE", architectures: ["arm64"], recordSize: 160,
        identifier: 12, duplicateIdentifier: 16, kind: 20, sdk: 32, name: 60, fallbackName: 64,
        bundleName: 68, placeholder: 72, signer: 76, evidence: ["Synthetic fixture, not a captured iOS layout"])

    public static func make(profile: LayoutProfile = DemoFixture.profile) -> DemoFixture {
        var data = Data(count: 100)
        func put32(_ value: UInt32, _ offset: Int) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        func unit(_ payload: Data) -> Int {
            while data.count % 4 != 0 { data.append(0) }
            let offset = data.count
            data.append(Data(count: 8)); put32(UInt32(payload.count), offset + 4)
            data.append(payload); return offset
        }
        func table(_ name: String) -> Int {
            var payload = Data(count: 72)
            payload.replaceSubrange(0..<name.utf8.count, with: name.utf8)
            return unit(payload)
        }
        let bundleTable = table("Bundle"), stringTable = table("<string>")
        var strings: [(UInt32, Int)] = [], bundles: [(UInt32, Int)] = []
        func text(_ value: String) -> UInt32 {
            let key = UInt32((strings.count + 1) * 2)
            let offset = unit(Data(value.utf8) + Data([0]))
            strings.append((key, offset)); return key
        }
        var catalog: [InstalledApplication] = []
        let names = ["Atlas Sample", "Notes Sample", "Orbit Sample"]
        let versions = [SDKVersion(26, 2), SDKVersion(26), SDKVersion(18, 5)]
        for index in 0..<3 {
            let id = "org.forcelegacyui.sample.\(index)"
            let parent = "/private/var/containers/Bundle/Application/00000000-0000-4000-8000-00000000000\(index)"
            let bundle = "Sample\(index).app"
            let identifier = text(id), name = text(names[index]), bundleKey = text(bundle)
            let placeholder = text(parent + "/SerializedPlaceholder.ipa"), signer = text("Synthetic signer")
            let record = unit(Data(count: profile.recordSize)), body = record + 8
            put32(identifier, body + profile.identifier); put32(identifier, body + profile.duplicateIdentifier); put32(2, body + profile.kind)
            data.replaceSubrange((body + profile.sdk)..<(body + profile.sdk + 24), with: versions[index].bytes)
            put32(name, body + profile.name); put32(name, body + profile.fallbackName); put32(bundleKey, body + profile.bundleName)
            put32(placeholder, body + profile.placeholder); put32(signer, body + profile.signer)
            bundles.append((UInt32(index + 1), record))
            catalog.append(InstalledApplication(bundleID: id, name: names[index], bundlePath: parent + "/" + bundle, reportedSDK: versions[index]))
        }
        func hashTable(_ descriptor: Int, _ entries: [(UInt32, Int)]) {
            while data.count % 4 != 0 { data.append(0) }
            let hash = data.count
            data.append(Data(count: 12 + entries.count * 8))
            put32(1, hash); put32(UInt32(entries.count), hash + 4); put32(UInt32(hash + 12), hash + 8)
            for (index, entry) in entries.enumerated() {
                put32(entry.0, hash + 12 + index * 8); put32(UInt32(entry.1), hash + 16 + index * 8)
            }
            put32(UInt32(hash), descriptor + 0x4c)
        }
        hashTable(bundleTable, bundles); hashTable(stringTable, strings)
        put32(0x40000000, 20); put32(72, 24)
        hashTable(20, [(1, bundleTable), (2, stringTable)])
        data.replaceSubrange(0..<5, with: [0x62, 0x64, 0x73, 0x6c, 2])
        data.replaceSubrange(8..<20, with: Data("FLUI-DEMO-v1".utf8))
        // The fixture checksum is deliberately synthetic and is not the Apple CSStore algorithm.
        data = SyntheticStoreValidator.repair(data)
        return DemoFixture(data: data, catalog: catalog)
    }
}

public struct SyntheticStoreValidator: StoreValidator {
    public init() {}
    public func validate(_ data: Data) throws {
        guard data.count >= 100, data.subdata(in: 8..<20) == Data("FLUI-DEMO-v1".utf8), Self.repair(data) == data else {
            throw LegacyError.invalid("Synthetic fixture checksum mismatch. This validator cannot open a device store.")
        }
    }
    public func repairingChecksum(_ data: Data) throws -> Data {
        guard data.count >= 100, data.subdata(in: 8..<20) == Data("FLUI-DEMO-v1".utf8) else {
            throw LegacyError.unsupported("Not a synthetic fixture.")
        }
        return Self.repair(data)
    }
    static func repair(_ input: Data) -> Data {
        var data = input
        let sum = data.enumerated().reduce(UInt32(0)) { (6..<8).contains($1.offset) ? $0 : ($0 + UInt32($1.element)) & 0xffff }
        data[6] = UInt8(sum & 0xff); data[7] = UInt8(sum >> 8); return data
    }
}
