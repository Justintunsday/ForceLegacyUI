import Foundation
import LegacyCore

struct Inspection: Codable {
    var device: DeviceIdentity
    var applications: [InstalledApplication]
    var storePath: String?
    var storeSummary: StoreSummary?
    var layoutID: String?
    var layoutValidated: Bool
    var isDemo: Bool
    var log: String
    var status: OverrideStatus
}

actor ResearchEngine {
    private let files = FileManager.default
    private let documents: URL
    private var importedProfile: LayoutProfile?
    private var lastInspection: Inspection?
    private var lastPreview: String?
    private var demo = false

    init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var demoRoot: URL { documents.appendingPathComponent("DemoLaboratory", isDirectory: true) }
    private var demoStore: URL { demoRoot.appendingPathComponent("synthetic.csstore") }
    private var backupRoot: URL { demo ? demoRoot.appendingPathComponent("Backups", isDirectory: true) : documents.appendingPathComponent("Backups", isDirectory: true) }
    private var validator: StoreValidator { demo ? SyntheticStoreValidator() : AppleStoreValidator() }
    private var identity: DeviceIdentity {
        if demo { return DemoFixture.device }
        let d = FLDeviceInfo()
        return DeviceIdentity(osVersion: d["osVersion"] ?? "unknown", osBuild: d["osBuild"] ?? "unknown",
            architecture: d["architecture"] ?? "unknown", model: d["model"] ?? "unknown")
    }
    private var profile: LayoutProfile? { demo ? DemoFixture.profile : (importedProfile ?? ReviewedLayouts.profile(for: identity)) }

    private func withStore<T>(extended: Bool = false, _ body: (URL, String) throws -> T) throws -> T {
        if demo {
            try files.createDirectory(at: demoRoot, withIntermediateDirectories: true)
            if !files.fileExists(atPath: demoStore.path) { try BackupRepository.durableWrite(DemoFixture.make().data, to: demoStore) }
            return try body(demoStore, "Synthetic app-owned store. No installed application is changed.")
        }
        let group = Bundle.main.object(forInfoDictionaryKey: "FLAppGroupIdentifier") as? String ?? ""
        let cached = UserDefaults.standard.string(forKey: "LastLSCacheDirectory")
        var failure: NSError?
        guard let session = FLOpenStore(group, cached, extended, &failure) else {
            throw LegacyError.unsupported(failure?.localizedDescription ?? "Store access was refused.")
        }
        defer { session.endAccess() }
        let url = URL(fileURLWithPath: session.path)
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "LastLSCacheDirectory")
        return try body(url, session.diagnostics)
    }

    func inspect(demo requestedDemo: Bool, extended: Bool = false) -> Inspection {
        if requestedDemo != demo { lastPreview = nil }
        demo = requestedDemo
        var message: NSString?
        let raw = demo ? [] : FLInstalledApps(&message)
        var apps: [InstalledApplication] = raw.compactMap { value in
            guard let id = value["bundleID"] as? String, let name = value["name"] as? String,
                  let path = value["bundlePath"] as? String else { return nil }
            return InstalledApplication(bundleID: id, name: name, bundlePath: path,
                reportedSDK: (value["sdk"] as? String).flatMap(SDKVersion.init(string:)),
                applicationType: value["applicationType"] as? String ?? "Unknown")
        }
        var output = Inspection(device: identity, applications: apps, layoutValidated: false,
                                isDemo: demo, log: message as String? ?? "", status: .unsupported)
        do {
            try withStore(extended: extended) { url, accessLog in
                let data = try TransactionEngine.readSnapshot(url)
                output.storePath = url.path
                let store = try CSStore(data: data)
                output.storeSummary = store.summary
                output.log += "\n\(accessLog)\nBounded v2 catalog parsed. SHA-256: \(sha256(data))\n"
                do {
                    try validator.validate(data)
                    output.log += "Store copy passed \(demo ? "synthetic" : "system CoreServicesStore") validation.\n"
                } catch {
                    output.log += "Store validator refused: \(error.localizedDescription)\n"
                    throw error
                }
                if let profile {
                    let records = try store.applications(profile: profile, device: identity)
                    if demo {
                        apps = records.map { InstalledApplication(bundleID: $0.bundleID, name: $0.name, bundlePath: $0.bundlePath, reportedSDK: $0.sdk) }
                        output.applications = apps
                    } else {
                        let count = try store.crossValidate(records, catalog: apps)
                        output.log += "Cross-checked \(count) app identities, paths and SDK values against LaunchServices proxies.\n"
                    }
                    output.layoutID = profile.id; output.layoutValidated = true; output.status = .experimental
                    output.log += "Profile \(profile.id). Appearance remains unverified.\n"
                } else {
                    output.log += "No reviewed layout for this OS build. Record sizes are diagnostic only; no offsets were guessed. Live writes are disabled.\n"
                }
                if store.summary.containsCompatibilityKeyString {
                    output.log += "The compatibility key string occurs in this snapshot. This does not establish a writable per-app field or an effective override.\n"
                } else {
                    output.log += "The compatibility key string was not found. This does not prove that a derived flag or encoded metadata is absent.\n"
                }
            }
        } catch { output.log += "\n\(error.localizedDescription)\n" }
        output.applications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastInspection = output
        return output
    }

    func importLayout(_ data: Data) throws {
        guard !demo, data.count <= 64 * 1024 else { throw LegacyError.invalid("Import a profile under 64 KiB in device mode.") }
        let value = try JSONDecoder().decode(LayoutProfile.self, from: data)
        try value.validate(for: identity)
        importedProfile = value; lastPreview = nil
        // Imported fields are deliberately session-scoped and cannot change the live-write allowlist.
    }

    func apply(selected: Set<String>, dryRun: Bool) throws -> String {
        guard let profile else {
            throw LegacyError.unsupported("No verified record layout exists for this OS build. Export read-only diagnostics first; a SDK downgrade cannot safely be planned from record size alone.")
        }
        return try withStore { url, _ in
            let data = try TransactionEngine.readSnapshot(url)
            let store = try CSStore(data: data)
            let records = try store.applications(profile: profile, device: identity)
            guard let inspection = lastInspection, inspection.layoutValidated else {
                throw LegacyError.unsupported("Run read-only inspection and validate this profile before planning changes.")
            }
            if !demo { _ = try store.crossValidate(records, catalog: inspection.applications) }
            let targets = Dictionary(uniqueKeysWithValues: selected.map { ($0, SDKVersion.legacy) })
            let plan = try SDKPlanner.prepare(data: data, profile: profile, device: identity, targets: targets, validator: validator)
            let fingerprint = sha256(data) + profile.digest + selected.sorted().joined(separator: ",")
            if dryRun {
                let lab = documents.appendingPathComponent("CopyExperiments/\(UUID().uuidString)", isDirectory: true)
                try files.createDirectory(at: lab, withIntermediateDirectories: true)
                try BackupRepository.durableWrite(data, to: lab.appendingPathComponent("original.csstore"))
                try BackupRepository.durableWrite(plan.candidate, to: lab.appendingPathComponent("candidate.csstore"))
                let description = "DRY RUN: only app-owned copies were saved.\n\(plan.summary)\nOriginal SHA-256: \(sha256(data))\nCandidate SHA-256: \(sha256(plan.candidate))\nAppearance has not been tested.\nCopies: \(lab.lastPathComponent)"
                try BackupRepository.durableWrite(Data(description.utf8), to: lab.appendingPathComponent("plan.txt"))
                lastPreview = fingerprint
                return description
            }
            guard lastPreview == fingerprint else { throw LegacyError.conflict("Run a fresh dry run with the same selection before applying.") }
            guard demo || selected.count == 1 else { throw LegacyError.unsupported("Live batch operations require reviewed single-app appearance evidence and are not enabled in this release.") }
            let authorization = try demo ? WriteAuthorization.appOwned(directory: demoRoot) : WriteAuthorization.reviewedLive(profile: profile, device: identity)
            let entry = try TransactionEngine.apply(plan, to: url, backups: backupRoot, authorization: authorization, validator: validator)
            lastPreview = nil
            return "\(demo ? "Demo copy" : "SDK metadata") written and verified.\n\(plan.summary)\nBackup: \(entry.id)\nThis does not verify legacy appearance."
        }
    }

    func backups() throws -> [BackupEntry] { try BackupRepository.list(backupRoot) }

    #if targetEnvironment(simulator)
    func simulatorSelfTest() throws {
        let inspection = inspect(demo: true)
        guard inspection.layoutValidated else { throw LegacyError.invalid("Demo inspection failed.") }
        let before = try TransactionEngine.readSnapshot(demoStore)
        let selected: Set<String> = ["org.forcelegacyui.sample.0"]
        let preview = try apply(selected: selected, dryRun: true)
        guard try TransactionEngine.readSnapshot(demoStore) == before else { throw LegacyError.invalid("Dry run mutated its source.") }
        let result = try apply(selected: selected, dryRun: false)
        let applied = try TransactionEngine.readSnapshot(demoStore)
        guard applied != before, let entry = try backups().first(where: { $0.status == .applied }) else {
            throw LegacyError.invalid("Apply or automatic backup failed.")
        }
        let restored = try restore(entry)
        guard try TransactionEngine.readSnapshot(demoStore) == before else { throw LegacyError.invalid("Restoration did not reproduce the baseline.") }
        let evidence: [String: Any] = ["passed": true, "physicalDeviceTest": false, "syntheticData": true,
            "beforeSHA256": sha256(before), "appliedSHA256": sha256(applied), "restoredSHA256": sha256(before),
            "preview": preview, "apply": result, "restore": restored]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try BackupRepository.durableWrite(data, to: documents.appendingPathComponent("simulator-self-test.json"))
    }
    #endif

    func restore(_ entry: BackupEntry) throws -> String {
        guard let profile else { throw LegacyError.unsupported("Restoration needs the original reviewed layout; no raw whole-store overwrite is allowed.") }
        return try withStore { url, _ in
            guard entry.receipt.sourceName == url.lastPathComponent else { throw LegacyError.conflict("This backup belongs to a different store file.") }
            let current = try TransactionEngine.readSnapshot(url)
            let authorization = try demo ? WriteAuthorization.appOwned(directory: demoRoot) : WriteAuthorization.reviewedLive(profile: profile, device: identity)
            let plan: PreparedPlan
            do {
                plan = try TransactionEngine.restorationPlan(backup: entry, current: current, profile: profile, device: identity, validator: validator)
            } catch {
                guard [.prepared, .needsRecovery].contains(entry.status) else { throw error }
                try TransactionEngine.recoverInterrupted(backup: entry, at: url, profile: profile, device: identity,
                    authorization: authorization, validator: validator)
                lastPreview = nil
                return "Interrupted transaction recovered. Original bytes and checksum were verified."
            }
            let undo = try TransactionEngine.apply(plan, to: url, backups: backupRoot, authorization: authorization, validator: validator)
            try BackupRepository.setStatus(.restored, directory: entry.directory)
            try BackupRepository.setStatus(.restored, directory: undo.directory)
            lastPreview = nil
            return "Original SDK values restored and verified. Unrelated current records were preserved."
        }
    }

    func exportReport(includeSnapshot: Bool = false) throws -> URL {
        guard let inspection = lastInspection else { throw LegacyError.invalid("Run an inspection first.") }
        let folder = documents.appendingPathComponent("Diagnostics/\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = folder.appendingPathComponent("report.json")
        try BackupRepository.durableWrite(encoder.encode(inspection), to: report)
        if includeSnapshot {
            try withStore { url, _ in
                let data = try TransactionEngine.readSnapshot(url)
                try BackupRepository.durableWrite(data, to: folder.appendingPathComponent("snapshot.csstore"))
                try BackupRepository.durableWrite(Data(sha256(data).utf8), to: folder.appendingPathComponent("snapshot.sha256"))
            }
        }
        return report
    }
}
