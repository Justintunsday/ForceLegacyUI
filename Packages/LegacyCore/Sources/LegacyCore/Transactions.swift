import Foundation
import CStoreIO

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64, inode: UInt64, size: UInt64
    public let modifiedSeconds: Int64, modifiedNanoseconds: Int64
    init(_ c: FLFileIdentity) {
        device = c.device; inode = c.inode; size = c.size
        modifiedSeconds = c.modified_seconds; modifiedNanoseconds = c.modified_nanoseconds
    }
}

private final class StableFile {
    let directory: Int32
    let fd: Int32
    let name: String

    init(url: URL, writable: Bool) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw LegacyError.invalid("Expected an absolute file URL.")
        }
        name = url.lastPathComponent
        let dir = fl_open_directory(url.deletingLastPathComponent().path)
        guard dir >= 0 else { throw LegacyError.io("Cannot open store directory (errno \(fl_errno())).") }
        let file = fl_open_file(dir, name, writable ? 1 : 0)
        guard file >= 0 else { fl_close(dir); throw LegacyError.io("Cannot open store (errno \(fl_errno())).") }
        guard fl_lock_file(file, writable ? 1 : 0) == 0 else {
            fl_close(file); fl_close(dir); throw LegacyError.conflict("Store is locked. Refresh and try again.")
        }
        directory = dir; fd = file
    }
    deinit { fl_close(fd); fl_close(directory) }

    func snapshot() throws -> (Data, FileIdentity) {
        var before = FLFileIdentity()
        guard fl_identity(fd, &before) == 0, before.size > 0, before.size <= UInt64(CSStore.maximumSize),
              fl_path_matches(directory, name, &before) != 0 else {
            throw LegacyError.conflict("Store was replaced, has hard links, or exceeds the size limit.")
        }
        var data = Data(count: Int(before.size))
        let result = data.withUnsafeMutableBytes { fl_read_file(fd, $0.baseAddress, $0.count) }
        var after = FLFileIdentity()
        guard result == 0, fl_identity(fd, &after) == 0, FileIdentity(before) == FileIdentity(after),
              fl_path_matches(directory, name, &after) != 0 else {
            throw LegacyError.conflict("Store changed while being read. Refresh before continuing.")
        }
        return (data, FileIdentity(after))
    }
    func write(_ patches: [BytePatch], restore: Bool) throws {
        // SDK fields precede the checksum. In-place writes preserve mmap inode identity.
        for patch in patches {
            let data = restore ? patch.original : patch.replacement
            let result = data.withUnsafeBytes { fl_write_bytes(fd, $0.baseAddress, $0.count, UInt64(patch.offset)) }
            guard result == 0 else { throw LegacyError.io("Short or failed store write (errno \(fl_errno())).") }
        }
        guard fl_sync(fd) == 0 else { throw LegacyError.io("Store fsync failed (errno \(fl_errno())).") }
    }
}

public enum TransactionStatus: String, Codable, Sendable { case prepared, applied, restored, rolledBack, needsRecovery }

public struct BackupReceipt: Codable, Identifiable, Sendable {
    public let schema: Int
    public let id: UUID
    public let created: Date
    public let sourceName: String
    public let identity: FileIdentity
    public let device: DeviceIdentity
    public let profileDigest: String
    public let originalSHA256: String
    public let candidateSHA256: String
    public let changes: [SDKChange]
}

public struct BackupEntry: Identifiable, Sendable {
    public var id: UUID { receipt.id }
    public let directory: URL
    public let receipt: BackupReceipt
    public let status: TransactionStatus
}

public enum BackupRepository {
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        return try e.encode(value)
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        guard fl_sync_path(url.path, 0) == 0, try Data(contentsOf: url) == data,
              fl_sync_path(url.deletingLastPathComponent().path, 1) == 0 else {
            throw LegacyError.io("Backup could not be synchronized and verified. Nothing may be written to the live store.")
        }
    }

    static func create(plan: PreparedPlan, source: URL, identity: FileIdentity, root: URL) throws -> BackupEntry {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipt = BackupReceipt(schema: 1, id: UUID(), created: Date(), sourceName: source.lastPathComponent,
            identity: identity, device: plan.device, profileDigest: plan.profile.digest,
            originalSHA256: sha256(plan.original), candidateSHA256: sha256(plan.candidate), changes: plan.changes)
        let directory = root.appendingPathComponent(receipt.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try durableWrite(plan.original, to: directory.appendingPathComponent("original.csstore"))
        try durableWrite(encode(receipt), to: directory.appendingPathComponent("receipt.json"))
        try setStatus(.prepared, directory: directory)
        guard fl_sync_path(root.path, 1) == 0 else { throw LegacyError.io("Cannot synchronize the backup directory.") }
        let loaded = try load(directory)
        guard loaded.receipt.originalSHA256 == sha256(plan.original) else { throw LegacyError.invalid("Backup receipt mismatch.") }
        return loaded
    }

    public static func setStatus(_ status: TransactionStatus, directory: URL) throws {
        try durableWrite(encode(status), to: directory.appendingPathComponent("status.json"))
    }

    public static func load(_ directory: URL) throws -> BackupEntry {
        let receipt = try decoder().decode(BackupReceipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json")))
        let status = try decoder().decode(TransactionStatus.self, from: Data(contentsOf: directory.appendingPathComponent("status.json")))
        let originalURL = directory.appendingPathComponent("original.csstore")
        let attrs = try FileManager.default.attributesOfItem(atPath: originalURL.path)
        guard receipt.schema == 1, directory.lastPathComponent == receipt.id.uuidString,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= CSStore.maximumSize,
              sha256(try Data(contentsOf: originalURL)) == receipt.originalSHA256 else {
            throw LegacyError.invalid("Backup is corrupt or its original snapshot checksum does not match.")
        }
        return BackupEntry(directory: directory, receipt: receipt, status: status)
    }

    public static func list(_ root: URL) throws -> [BackupEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // A broken backup is an error, not something to silently hide from recovery.
        return try urls.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map(load).sorted { $0.receipt.created > $1.receipt.created }
    }
}

public enum TransactionEngine {
    public static func readSnapshot(_ url: URL) throws -> Data { try StableFile(url: url, writable: false).snapshot().0 }

    @discardableResult
    public static func apply(_ plan: PreparedPlan, to url: URL, backups: URL,
                             authorization: WriteAuthorization, validator: StoreValidator) throws -> BackupEntry {
        try authorization.validate(url: url, plan: plan)
        let file = try StableFile(url: url, writable: true)
        let (original, identity) = try file.snapshot()
        guard original == plan.original else { throw LegacyError.conflict("Store changed after preview. Run a fresh dry run.") }
        try validator.validate(original)
        let backup = try BackupRepository.create(plan: plan, source: url, identity: identity, root: backups)
        // Recheck after durable backup creation; lsd may not honor our advisory lock.
        guard try file.snapshot().0 == original else {
            try BackupRepository.setStatus(.rolledBack, directory: backup.directory)
            throw LegacyError.conflict("Store changed during backup creation. Nothing was written.")
        }
        do {
            try file.write(plan.patches, restore: false)
            let after = try file.snapshot().0
            guard after == plan.candidate else { throw LegacyError.conflict("Post-write bytes differ from the candidate.") }
            try validator.validate(after)
        } catch {
            do {
                let current = try file.snapshot().0
                guard safeToRollback(current: current, plan: plan) else {
                    throw LegacyError.recovery("Another writer changed the store; automatic rollback would overwrite unrelated data.")
                }
                try file.write(plan.patches, restore: true)
                guard try file.snapshot().0 == original else { throw LegacyError.recovery("Rollback bytes did not verify.") }
                try validator.validate(original)
                try BackupRepository.setStatus(.rolledBack, directory: backup.directory)
            } catch let recoveryError {
                try? BackupRepository.setStatus(.needsRecovery, directory: backup.directory)
                throw LegacyError.recovery("Recovery required. Keep backup \(backup.id). \(recoveryError.localizedDescription)")
            }
            throw LegacyError.io("The write failed verification and the original bytes were restored: \(error.localizedDescription)")
        }
        do { try BackupRepository.setStatus(.applied, directory: backup.directory) }
        catch { throw LegacyError.recovery("Bytes were verified but the completion receipt could not be saved. Keep backup \(backup.id) and inspect recovery status.") }
        return try BackupRepository.load(backup.directory)
    }

    private static func safeToRollback(current: Data, plan: PreparedPlan) -> Bool {
        guard current.count == plan.original.count else { return false }
        var remaining = current
        for patch in plan.patches {
            for index in patch.range {
                guard current[index] == plan.original[index] || current[index] == plan.candidate[index] else { return false }
            }
            remaining.replaceSubrange(patch.range, with: patch.original)
        }
        return remaining == plan.original
    }

    public static func restorationPlan(backup: BackupEntry, current: Data, profile: LayoutProfile,
                                       device: DeviceIdentity, validator: StoreValidator) throws -> PreparedPlan {
        let checked = try BackupRepository.load(backup.directory)
        let receipt = checked.receipt
        guard [.applied, .prepared, .needsRecovery].contains(checked.status), receipt.profileDigest == profile.digest,
              receipt.device.osVersion == device.osVersion, receipt.device.osBuild == device.osBuild,
              receipt.device.architecture == device.architecture else {
            throw LegacyError.unsupported("Backup is not active or does not match this OS build and layout.")
        }
        let old = try Data(contentsOf: checked.directory.appendingPathComponent("original.csstore"))
        let originals = try CSStore(data: old).applications(profile: profile, device: device)
        let records = try CSStore(data: current).applications(profile: profile, device: device)
        var targets: [String: SDKVersion] = [:]
        for change in receipt.changes {
            guard let original = originals.first(where: { $0.bundleID == change.bundleID }),
                  original.sdk == change.original, original.bundlePath == change.bundlePath,
                  let record = records.first(where: { $0.bundleID == change.bundleID }), record.bundlePath == change.bundlePath,
                  record.sdk == change.target || record.sdk == change.original,
                  targets[change.bundleID] == nil else {
                throw LegacyError.conflict("An app was removed, reinstalled, or changed since backup. Refusing stale restoration.")
            }
            targets[change.bundleID] = change.original
        }
        // Re-resolves fields in today's store, preserving unrelated registrations and records.
        return try SDKPlanner.prepare(data: current, profile: profile, device: device, targets: targets, validator: validator)
    }
}
