import Foundation
import Combine
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
    private let engine = ResearchEngine()

    var apps: [InstalledApplication] { inspection?.applications ?? [] }
    func selectable(_ app: InstalledApplication) -> Bool {
        app.bundlePath.hasPrefix("/private/var/containers/Bundle/Application/") && app.reportedSDK != nil
    }
    func selectAll() { selection = Set(apps.filter(selectable).map(\.id)) }

    func scan(extended: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        inspection = await engine.inspect(demo: demo, extended: extended)
        selection.formIntersection(Set(apps.filter(selectable).map(\.id)))
        do { backups = try await engine.backups() }
        catch { failed = true; message = error.localizedDescription }
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
            message = "Profile loaded for copy experiments. Live-write authorization is unchanged."; failed = false
            await scan()
        } catch { message = error.localizedDescription; failed = true }
    }
    func export(includeSnapshot: Bool) async {
        do {
            exportURL = try await engine.exportReport(includeSnapshot: includeSnapshot)
            message = includeSnapshot ? "Report and raw snapshot saved in Documents/Diagnostics. Raw stores can contain private metadata." : "Report saved locally. Review it before sharing."
            failed = false
        } catch { message = error.localizedDescription; failed = true }
    }
}
