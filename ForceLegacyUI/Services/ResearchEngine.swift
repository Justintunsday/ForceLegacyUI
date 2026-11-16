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
    var appGroup: AppGroupResolution?
    var appGroupSource: String?
    var catalogSource: String = "LaunchServices"
    var storeError: String?
    var accessBackend: String = "App Group / worse_query"
    var storeRole: String?
    var bundleFacts: [BundleSDKObservation] = []
    var singleAppWriteReady = false
    var writeReadinessReason = "Import an exact-build layout and validate independent SDK observations first."
    var writableOpen: Bool?
}

actor ResearchEngine {
    private let files = FileManager.default
    private let documents: URL
    private var importedProfile: LayoutProfile?
    private var lastInspection: Inspection?
    private var lastPreview: String?
    private var previewFacts: [BundleSDKObservation]?
    private var demo = false
    private var singleAppExperiment = false

    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documents = FLAccessMode() == "house-arrest" ? root.appendingPathComponent("ForceLegacyUI", isDirectory: true) : root
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

    private func resolveAppGroup() -> (AppGroupResolution, String) {
        let context = FLAppGroupContext()
        let configured = context["configured"] as? String ?? ""
        let bundleID = context["bundleID"] as? String ?? ""
        let reported = context["groups"] as? [String] ?? []
        let candidates = AppGroupResolution.candidates(configured: configured, bundleID: bundleID, reportedGroups: reported)
        let accessible = Set(candidates.filter { files.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil })
        return (AppGroupResolution.resolve(configured: configured, bundleID: bundleID, reportedGroups: reported,
            accessibleGroups: accessible), context["source"] as? String ?? "unknown")
    }

    private func withStore<T>(extended: Bool = false, _ body: (URL, String) throws -> T) throws -> T {
        if demo {
            try files.createDirectory(at: demoRoot, withIntermediateDirectories: true)
            if !files.fileExists(atPath: demoStore.path) { try BackupRepository.durableWrite(DemoFixture.make().data, to: demoStore) }
            return try body(demoStore, "Synthetic app-owned store. No installed application is changed.")
        }
        let (resolution, _) = resolveAppGroup()
        let group = FLAccessMode() == "house-arrest" ? "" : resolution.selected
        guard let group else {
            throw LegacyError.unsupported(resolution.state == .ambiguous
                ? "More than one rewritten ForceLegacyUI App Group is usable. Configure the dedicated group explicitly; no group was selected."
                : "App Group unavailable. The configured group does not match a usable group in this app's signature. Re-sign ForceLegacyUI with its dedicated App Group; changing an Info.plist string alone does not grant access.")
        }
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

    func restartInodeDiscovery() { FLResetStoreDiscoveryProgress() }
    func setSingleAppExperiment(_ value: Bool) { singleAppExperiment = value; lastPreview = nil }

    private var evidenceGroup: String { FLAccessMode() == "house-arrest" ? "" : (resolveAppGroup().0.selected ?? "") }
    private func observations(_ apps: [InstalledApplication], required: Set<String> = [], log: inout String) -> [BundleSDKObservation] {
        #if targetEnvironment(simulator)
        log += "Independent physical bundle observations are unavailable in the simulator.\n"
        return []
        #else
        return BundleObservationCollector.collect(apps, group: evidenceGroup, required: required, log: &log)
        #endif
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
        if let source = raw.first?["catalogSource"] as? String { output.catalogSource = source }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        output.log = "ForceLegacyUI \(version) (build \(build))\niOS \(output.device.osVersion) (\(output.device.osBuild)); \(output.device.model); \(output.device.architecture)\nInspection: \(demo ? "demo" : (extended ? "extended" : "standard"))\n\n" + output.log
        output.accessBackend = demo ? "Synthetic demo" : (FLAccessMode() == "house-arrest" ? "MobileHouseArrest" : "App Group / worse_query + traversal fallback")
        output.log += "\nAccess backend: \(output.accessBackend)\n"
        if !demo && FLAccessMode() == "house-arrest" {
            output.log += "Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")\nMHA mode requires an unchanged com.apple.mobile.MobileHouseArrest identity. App Group is not required for this mode.\n"
        } else if !demo {
            let (group, source) = resolveAppGroup()
            output.appGroup = group; output.appGroupSource = source
            output.log += "\nBundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")\nConfigured App Group: \(group.configured)\nGroup metadata: \(source)\nReported groups: \(group.reportedGroups.joined(separator: ", "))\nGroup state: \(group.state.rawValue); selected: \(group.selected ?? "none")\n"
        } else { output.catalogSource = "Synthetic demo" }
        do {
            try withStore(extended: extended) { url, accessLog in
                output.log += "\n\(accessLog)\n"
                let diagnosticOnly = FLStoreIsDiagnosticOnly(url.path)
                output.storeRole = diagnosticOnly ? "Prefixed cache; role unverified; diagnostic only" : "Primary-name cache"
                if diagnosticOnly { output.log += "Prefixed cache role is unverified. Profile planning and writes are disabled for this source.\n" }
                let data = try TransactionEngine.readSnapshot(url)
                output.storePath = url.path
                let store = try CSStore(data: data)
                output.storeSummary = store.summary
                output.log += "Bounded v2 catalog parsed. SHA-256: \(sha256(data))\n"
                do {
                    try validator.validate(data)
                    output.log += "Store copy passed \(demo ? "synthetic" : "system CoreServicesStore") validation.\n"
                } catch {
                    output.log += "Store validator refused: \(error.localizedDescription)\n"
                    throw error
                }
                if !demo && apps.isEmpty {
                    let registrations = try store.discoverRegistrations()
                    output.applications = registrations
                    output.catalogSource = diagnosticOnly ? "Prefixed cache registrations (read-only)" : "Read-only cache registrations"
                    output.log += "Read-only cache fallback: \(registrations.count) unambiguous registrations. SDK offsets were not inferred; installation state and layout remain unverified.\n"
                }
                if !demo && !diagnosticOnly {
                    output.bundleFacts = observations(output.applications, log: &output.log)
                }
                if diagnosticOnly {
                    output.log += "Diagnostic source only; continuing extended scans can search for a primary-name catalog.\n"
                } else if let profile {
                    let records = try store.applications(profile: profile, device: identity)
                    if demo {
                        apps = records.map { InstalledApplication(bundleID: $0.bundleID, name: $0.name, bundlePath: $0.bundlePath, reportedSDK: $0.sdk) }
                        output.applications = apps
                    } else {
                        do {
                            for record in records {
                                if let observed = apps.first(where: { $0.bundleID == record.bundleID }), let sdk = observed.reportedSDK {
                                    guard sdk == record.sdk, LiveStorePolicy.canonical(observed.bundlePath) == LiveStorePolicy.canonical(record.bundlePath) else {
                                        throw LegacyError.conflict("LaunchServices metadata disagrees with the loaded layout for \(record.bundleID).")
                                    }
                                }
                            }
                            _ = try SDKSnapshotEvidence.validate(data: data, profile: profile, device: identity,
                                                                 observations: output.bundleFacts, validator: validator)
                            output.applications = records.map { InstalledApplication(bundleID: $0.bundleID, name: $0.name,
                                bundlePath: $0.bundlePath, reportedSDK: $0.sdk, applicationType: "Validated cache registration") }
                            output.catalogSource = "Validated cache registrations with executable SDK corroboration"
                            do {
                                try TransactionEngine.probeWritable(url, expected: data)
                                output.writableOpen = true; output.singleAppWriteReady = true
                                output.writeReadinessReason = "Layout and independent SDKs agree; enable the single-app experiment and preview one app."
                                output.log += "O_RDWR open and stable read succeeded; zero bytes were written.\n"
                            } catch {
                                output.writableOpen = false; output.writeReadinessReason = error.localizedDescription
                                output.log += "Writable-open probe failed: \(error.localizedDescription)\n"
                            }
                        } catch {
                            output.writeReadinessReason = error.localizedDescription
                            output.log += "Single-app evidence refused: \(error.localizedDescription)\n"
                            return
                        }
                    }
                    output.layoutID = profile.id; output.layoutValidated = true; output.status = .experimental
                    output.log += "Profile \(profile.id). Appearance remains unverified.\n"
                } else {
                    output.log += "No exact-build layout is loaded. Record sizes and independent build SDKs are diagnostic evidence; no SDK offsets were guessed. Import and validate a layout before a single-app experiment.\n"
                }
                if store.summary.containsCompatibilityKeyString {
                    output.log += "The compatibility key string occurs in this snapshot. This does not establish a writable per-app field or an effective override.\n"
                } else {
                    output.log += "The compatibility key string was not found. This does not prove that a derived flag or encoded metadata is absent.\n"
                }
            }
        } catch { output.storeError = error.localizedDescription; output.log += "\n\(error.localizedDescription)\n" }
        output.applications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastInspection = output
        return output
    }

    func importLayout(_ data: Data) throws {
        guard !demo, data.count <= 64 * 1024 else { throw LegacyError.invalid("Import a profile under 64 KiB in device mode.") }
        let value = try JSONDecoder().decode(LayoutProfile.self, from: data)
        try value.validate(for: identity)
        importedProfile = value; lastPreview = nil
        // Import is session-scoped. Live authorization additionally validates fresh native bundle evidence.
    }

    func apply(selected: Set<String>, dryRun: Bool) throws -> String {
        guard let profile else {
            throw LegacyError.unsupported("No verified record layout exists for this OS build. Export read-only diagnostics first; a SDK downgrade cannot safely be planned from record size alone.")
        }
        return try withStore { url, _ in
            guard !FLStoreIsDiagnosticOnly(url.path) else { throw LegacyError.unsupported("The prefixed cache is diagnostic only. SDK planning and writes are disabled for this source.") }
            let data = try TransactionEngine.readSnapshot(url)
            let store = try CSStore(data: data)
            let records = try store.applications(profile: profile, device: identity)
            guard let inspection = lastInspection, inspection.layoutValidated else {
                throw LegacyError.unsupported("Run read-only inspection and validate this profile before planning changes.")
            }
            var evidence: SDKSnapshotEvidence?
            var freshFacts: [BundleSDKObservation] = []
            if !demo {
                var log = ""
                let catalog = records.map { InstalledApplication(bundleID: $0.bundleID, name: $0.name,
                    bundlePath: $0.bundlePath, reportedSDK: nil) }
                let witnessIDs = Set((previewFacts ?? []).map(\.bundleID))
                let witnesses = !dryRun && lastPreview != nil ? catalog.filter { witnessIDs.contains($0.bundleID) } : catalog
                freshFacts = observations(witnesses, required: selected.count == 1 ? selected : [], log: &log)
                evidence = try SDKSnapshotEvidence.validate(data: data, profile: profile, device: identity,
                                                            observations: freshFacts, validator: validator)
                if selected.count == 1, !freshFacts.contains(where: { selected.contains($0.bundleID) }) {
                    throw LegacyError.unsupported("The selected app's executable SDK could not be independently observed.")
                }
            }
            let targets = Dictionary(uniqueKeysWithValues: selected.map { ($0, SDKVersion.legacy) })
            let plan = try SDKPlanner.prepare(data: data, profile: profile, device: identity, targets: targets, validator: validator)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fingerprint = sha256(data) + sha256(plan.candidate) + profile.digest + selected.sorted().joined(separator: ",") + sha256(try encoder.encode(freshFacts))
            if dryRun {
                let lab = documents.appendingPathComponent("CopyExperiments/\(UUID().uuidString)", isDirectory: true)
                try files.createDirectory(at: lab, withIntermediateDirectories: true)
                try BackupRepository.durableWrite(data, to: lab.appendingPathComponent("original.csstore"))
                try BackupRepository.durableWrite(plan.candidate, to: lab.appendingPathComponent("candidate.csstore"))
                let description = "DRY RUN: only app-owned copies were saved.\n\(plan.summary)\nOriginal SHA-256: \(sha256(data))\nCandidate SHA-256: \(sha256(plan.candidate))\nAppearance has not been tested.\nCopies: \(lab.lastPathComponent)"
                try BackupRepository.durableWrite(Data(description.utf8), to: lab.appendingPathComponent("plan.txt"))
                lastPreview = fingerprint
                previewFacts = freshFacts
                return description
            }
            guard lastPreview == fingerprint else { throw LegacyError.conflict("Run a fresh dry run with the same selection before applying.") }
            guard demo || selected.count == 1 else { throw LegacyError.unsupported("Live batch operations require reviewed single-app appearance evidence and are not enabled in this release.") }
            let authorization: WriteAuthorization
            if demo { authorization = .appOwned(directory: demoRoot) }
            else {
                guard singleAppExperiment, let evidence else { throw LegacyError.unsupported("Enable the single-app SDK experiment in Diagnostics after validation, then run a new dry run.") }
                authorization = try .validatedSingleApp(plan: plan, evidence: evidence, source: url)
            }
            let entry = try TransactionEngine.apply(plan, to: url, backups: backupRoot, authorization: authorization, validator: validator)
            lastPreview = nil
            return "\(demo ? "Demo copy" : "SDK metadata") written and verified.\n\(plan.summary)\nBackup: \(entry.id)\nThis does not verify legacy appearance."
        }
    }

    func backups() throws -> [BackupEntry] { try BackupRepository.list(backupRoot) }

    #if targetEnvironment(simulator)
    func simulatorCatalogSelfTest() throws {
        let result = inspect(demo: false)
        guard result.applications.contains(where: { $0.bundleID == Bundle.main.bundleIdentifier }) else {
            throw LegacyError.invalid("The native LS catalog could not identify this installed simulator app.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try BackupRepository.durableWrite(encoder.encode(result), to: documents.appendingPathComponent("simulator-catalog-test.json"))
    }

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
        let archive = try exportReport(includeSnapshot: true)
        guard archive.pathExtension == "zip", files.fileExists(atPath: archive.path) else {
            throw LegacyError.invalid("Evidence ZIP export failed.")
        }
        let evidence: [String: Any] = ["passed": true, "physicalDeviceTest": false, "syntheticData": true, "evidenceZIPExported":true,
            "beforeSHA256": sha256(before), "appliedSHA256": sha256(applied), "restoredSHA256": sha256(before),
            "preview": preview, "apply": result, "restore": restored]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try BackupRepository.durableWrite(data, to: documents.appendingPathComponent("simulator-self-test.json"))
    }
    #endif

    func restore(_ entry: BackupEntry) throws -> String {
        guard let profile = demo ? DemoFixture.profile : (entry.receipt.layout ?? self.profile) else {
            throw LegacyError.unsupported("Restoration needs the original layout stored in its receipt or loaded profile.")
        }
        return try withStore { url, _ in
            guard !FLStoreIsDiagnosticOnly(url.path) else { throw LegacyError.unsupported("A prefixed diagnostic cache cannot be used as a restoration destination.") }
            guard entry.receipt.sourceName == url.lastPathComponent else { throw LegacyError.conflict("This backup belongs to a different store file.") }
            let current = try TransactionEngine.readSnapshot(url)
            var facts: [BundleSDKObservation] = []
            if !demo, let saved = entry.receipt.bundleEvidence {
                var log = ""
                let apps = saved.map { InstalledApplication(bundleID: $0.bundleID, name: $0.bundleID, bundlePath: $0.bundlePath, reportedSDK: nil) }
                facts = observations(apps, required: Set(entry.receipt.changes.map(\.bundleID)), log: &log)
            }
            let plan: PreparedPlan
            do {
                plan = try TransactionEngine.restorationPlan(backup: entry, current: current, profile: profile, device: identity, validator: validator)
            } catch {
                guard [.prepared, .needsRecovery].contains(entry.status) else { throw error }
                let authorization: WriteAuthorization
                if demo { authorization = .appOwned(directory: demoRoot) }
                else if entry.receipt.bundleEvidence != nil {
                    authorization = try .validatedRecovery(backup: entry, profile: profile, device: identity,
                        observations: facts, source: url, validator: validator)
                } else { authorization = try .reviewedLive(profile: profile, device: identity) }
                try TransactionEngine.recoverInterrupted(backup: entry, at: url, profile: profile, device: identity,
                    authorization: authorization, validator: validator)
                lastPreview = nil
                return "Interrupted transaction recovered. Original bytes and checksum were verified."
            }
            let authorization: WriteAuthorization
            if demo { authorization = .appOwned(directory: demoRoot) }
            else if entry.receipt.bundleEvidence != nil {
                authorization = try .validatedRestoration(plan: plan, backup: entry, observations: facts, source: url, validator: validator)
            } else { authorization = try .reviewedLive(profile: profile, device: identity) }
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
                guard sha256(data) == inspection.storeSummary?.sha256 else {
                    throw LegacyError.conflict("The cache changed since inspection. Run a fresh inspection before exporting its evidence.")
                }
                try BackupRepository.durableWrite(data, to: folder.appendingPathComponent("snapshot.csstore"))
                try BackupRepository.durableWrite(Data(sha256(data).utf8), to: folder.appendingPathComponent("snapshot.sha256"))
                let archive = try EvidenceArchive.make(files: ["report.json":encoder.encode(inspection),
                    "snapshot.csstore":data, "snapshot.sha256":Data(sha256(data).utf8)])
                try BackupRepository.durableWrite(archive, to: folder.appendingPathComponent("ForceLegacyUI-evidence.zip"))
            }
            return folder.appendingPathComponent("ForceLegacyUI-evidence.zip")
        }
        return report
    }
}
