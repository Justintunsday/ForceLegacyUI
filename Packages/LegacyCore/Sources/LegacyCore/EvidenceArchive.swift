import Foundation

/// A bounded ZIP32 archive with stored entries; no shell, external dependency or arbitrary paths.
public enum EvidenceArchive {
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    public static func make(files: [String: Data]) throws -> Data {
        guard (1...8).contains(files.count), files.values.allSatisfy({ $0.count <= CSStore.maximumSize }),
              files.values.reduce(0, { $0 + $1.count }) <= 70 * 1024 * 1024 else {
            throw LegacyError.invalid("Evidence archive exceeds its entry or size budget.")
        }
        var archive = Data(), central = Data()
        func u16(_ number: UInt16, _ output: inout Data) {
            var value = number.littleEndian; withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        func u32(_ number: UInt32, _ output: inout Data) {
            var value = number.littleEndian; withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        for name in files.keys.sorted() {
            let text = Data(name.utf8)
            guard !text.isEmpty, text.count <= 128, text.allSatisfy({ (32...126).contains($0) }),
                  !name.contains("/"), !name.contains("\\"), name != ".", name != "..", let data = files[name] else {
                throw LegacyError.invalid("Evidence ZIP entries must have plain ASCII filenames.")
            }
            var crc = UInt32.max
            for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
            crc ^= UInt32.max
            let offset = UInt32(archive.count), size = UInt32(data.count)
            u32(0x04034b50, &archive); u16(20, &archive); u16(0x0800, &archive); u16(0, &archive)
            u16(0, &archive); u16(33, &archive); u32(crc, &archive); u32(size, &archive); u32(size, &archive)
            u16(UInt16(text.count), &archive); u16(0, &archive); archive.append(text); archive.append(data)
            u32(0x02014b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(33, &central); u32(crc, &central); u32(size, &central); u32(size, &central)
            u16(UInt16(text.count), &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u32(0, &central); u32(offset, &central); central.append(text)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        u32(0x06054b50, &archive); u16(0, &archive); u16(0, &archive)
        u16(UInt16(files.count), &archive); u16(UInt16(files.count), &archive)
        u32(UInt32(central.count), &archive); u32(centralOffset, &archive); u16(0, &archive)
        return archive
    }
}
