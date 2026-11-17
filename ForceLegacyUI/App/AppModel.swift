import Foundation
import Combine
import UIKit
import LegacyCore

@MainActor
final class AppModel: ObservableObject {
    @Published var inspection: Inspection?
    @Published var selection = Set<String>()
    @Published var demo = ProcessInfo.processInfo.arguments.contains("--demo")
    @Published var dryRun = true
    @Published var busy = false
    @Published var message = ""
    @Published var failed = false
    @Published var backups: [BackupEntry] = []
    @Published var exportURL: URL?
    @Published private(set) var singleAppExperiment = false
    private let engine = ResearchEngine()

    var apps: [InstalledApplication] { inspection?.applications ?? [] }
    var liveWriteAvailable: Bool {
        guard let inspection else { return false }
        if inspection.isDemo { return true }
        return singleAppExperiment && inspection.singleAppWriteReady && selection.count == 1
    }
    var writeReadiness: String {
        if singleAppExperiment && selection.count > 1 { return "Select exactly one app for a live SDK experiment. Batch writes are disabled." }
        if !singleAppExperiment { return "Enable Single-app SDK experiment in Diagnostics after validating the layout." }
        return inspection?.writeReadinessReason ?? "Run inspection first."
    }
    func setSingleAppExperiment(_ value: Bool) async {
        guard !busy else { return }
        busy = true; await engine.setSingleAppExperiment(value); singleAppExperiment = value; busy = false
    }
    var catalogIssue: String {
        guard let inspection else { return "Run read-only inspection to check app visibility and App Group access." }
        if inspection.appGroup?.state == .missing {
            return "App Group unavailable. The signer may have renamed or removed this app's group. Diagnostics shows the configured and reported group identifiers."
        }
        if inspection.appGroup?.state == .ambiguous {
            return "Several matching App Groups are accessible. Configure one dedicated group before cache inspection."
        }
        if let error = inspection.storeError {
            let reason = error.components(separatedBy: .newlines).first ?? "Cache discovery failed."
            return reason + " Open Diagnostics for discovery results, or run Extended Store Discovery."
        }
        return "iOS exposed no application records. Open Diagnostics to review each enumeration method and cache access."
    }
    func copyDiagnostics() {
        UIPasteboard.general.string = inspection?.log ?? "Inspection has not completed."
    }
    func selectable(_ app: InstalledApplication) -> Bool {
        inspection?.layoutValidated == true && app.bundlePath.hasPrefix("/private/var/containers/Bundle/Application/") && app.reportedSDK != nil
    }
    func selectAll() { selection = Set(apps.filter(selectable).map(\.id)) }

    func start() async {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            do { try await engine.simulatorSelfTest() }
            catch { failed = true; message = "Simulator self-test failed: \(error.localizedDescription)" }
        }
        if ProcessInfo.processInfo.arguments.contains("--catalog-self-test") {
            do { try await engine.simulatorCatalogSelfTest() }
            catch { failed = true; message = "Simulator catalog self-test failed: \(error.localizedDescription)" }
        }
        #endif
        await scan()
    }

    func scan(extended: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        inspection = await engine.inspect(demo: demo, extended: extended)
        selection.formIntersection(Set(apps.filter(selectable).map(\.id)))
        do { backups = try await engine.backups() }
        catch { failed = true; message = error.localizedDescription }
    }
    func restartInodeDiscovery() async {
        guard !busy else { return }
        busy = true; await engine.restartInodeDiscovery(); busy = false
        await scan(extended: true)
    }
    func apply() async {
        guard !busy else { return }; busy = true
        do { message = try await engine.apply(selected: selection, dryRun: dryRun); failed = false }
        catch { message = error.localizedDescription; failed = true }
        busy = false
        await scan()
    }
    func restore(_ backup: BackupEntry) async {
        guard !busy else { return }; busy = true
        do { message = try await engine.restore(backup); failed = false }
        catch { message = error.localizedDescription; failed = true }
        busy = false; await scan()
    }
    func importProfile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 64 * 1024 else { throw LegacyError.invalid("Profile exceeds 64 KiB.") }
            try await engine.importLayout(Data(contentsOf: url))
            message = "Profile loaded. Inspection will check its SDK fields against independent executable metadata before any single-app experiment."; failed = false
            await scan()
        } catch { message = error.localizedDescription; failed = true }
    }
    func export(includeSnapshot: Bool) async {
        do {
            exportURL = try await engine.exportReport(includeSnapshot: includeSnapshot)
            message = includeSnapshot ? "Report, snapshot and SHA-256 were packaged in one ZIP. Share Report now shares that archive. Raw stores can contain private metadata." : "Report saved locally. Review it before sharing."
            failed = false
        } catch { message = error.localizedDescription; failed = true }
    }
}
