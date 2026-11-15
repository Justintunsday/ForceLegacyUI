import Foundation
import LegacyCore

/// All private validation calls operate on a unique app-owned copy, never the active database.
struct AppleStoreValidator: StoreValidator {
    private func check(_ data: Data) throws -> (Bool, NSNumber?, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CSStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("validation.csstore")
        try data.write(to: url, options: .atomic)
        var sum: NSNumber?, error: NSError?
        let valid = FLCSStoreValidate(url.path, &sum, &error)
        return (valid, sum, error?.localizedDescription ?? "CoreServicesStore rejected the copy.")
    }
    func validate(_ data: Data) throws {
        let (valid, _, message) = try check(data)
        guard valid else { throw LegacyError.invalid(message) }
    }
    func repairingChecksum(_ data: Data) throws -> Data {
        let (valid, sum, message) = try check(data)
        if valid { return data }
        guard data.count >= 100, let sum, sum.int64Value >= 0, sum.uint64Value <= UInt16.max else {
            throw LegacyError.unsupported("No usable checksum was returned. \(message)")
        }
        var candidate = data
        candidate[6] = UInt8(sum.uint16Value & 0xff)
        candidate[7] = UInt8(sum.uint16Value >> 8)
        try validate(candidate)
        return candidate
    }
}
