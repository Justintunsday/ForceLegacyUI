import SwiftUI
import UniformTypeIdentifiers
import LegacyCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        Label(model.demo ? "Demo laboratory" : "Appearance override unverified", systemImage: model.demo ? "testtube.2" : "shield.lefthalf.filled")
                            .font(.headline).foregroundStyle(model.demo ? .blue : .orange)
                        Text(model.demo ? "These sample apps live in a synthetic store inside ForceLegacyUI. Device apps are untouched." : "Inspect installed apps and plan an SDK metadata experiment. Legacy appearance has not been verified on this OS build.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section {
                        HStack {
                            Button("Select All") { model.selectAll() }
                            Spacer()
                            Button("Deselect All") { model.selection.removeAll() }
                        }.disabled(model.busy || model.apps.isEmpty)
                        ForEach(filteredApps) { app in ApplicationRow(application: app) }
                    } header: {
                        Text("Applications (\(model.apps.count))")
                    } footer: {
                        Text("Toggles select a proposed change. They do not indicate that legacy appearance is active. Live batch writes remain disabled.")
                    }
                    if model.apps.isEmpty {
                        ContentUnavailableView("No visible applications", systemImage: "app.dashed", description: Text("Run inspection. If iOS restricts the list, check Diagnostics or open the demo laboratory."))
                            .listRowBackground(Color.clear)
                    }
                }
                .navigationTitle("ForceLegacyUI")
                .searchable(text: $search, prompt: "Name or bundle identifier")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy).accessibilityLabel("Run read-only inspection") } }
                .safeAreaInset(edge: .bottom) { actionBar }
                .refreshable { await model.scan() }
            }.tabItem { Label("Applications", systemImage: "square.grid.2x2") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            BackupsView().tabItem { Label("Restore", systemImage: "clock.arrow.circlepath") }
        }
        .tint(Color(red: 0.08, green: 0.35, blue: 0.72))
        .task { await model.start() }
        .sheet(isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })) {
            NavigationStack {
                ScrollView { Text(model.message).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle(model.failed ? "Action blocked" : "Result")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.message = "" } } }
            }
        }
    }
    private var filteredApps: [InstalledApplication] {
        model.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }
    private var actionBar: some View {
        VStack(spacing: 10) {
            Toggle("Dry run", isOn: $model.dryRun).disabled(model.busy)
            Button { Task { await model.apply() } } label: {
                HStack {
                    if model.busy { ProgressView().tint(.white) }
                    Text(model.dryRun ? "Preview Changes (\(model.selection.count))" : "Apply Changes (\(model.selection.count))")
                        .fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.selection.isEmpty)
        }.padding().background(Color(uiColor: .systemBackground))
    }
}

private struct ApplicationRow: View {
    @EnvironmentObject private var model: AppModel
    let application: InstalledApplication
    @State private var icon: UIImage?
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let icon { Image(uiImage: icon).resizable() }
                else { ZStack { Color(uiColor: .secondarySystemBackground); Image(systemName: "app").font(.title2).foregroundStyle(.secondary) } }
            }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(application.name).font(.body.weight(.medium))
                Text(application.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text("Reported SDK \(application.reportedSDK?.description ?? "unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.demo ? "Experimental copy" : "Unsupported override").font(.caption2).foregroundStyle(model.demo ? .blue : .orange)
            }
            Spacer(minLength: 4)
            Toggle("Legacy appearance for \(application.name)", isOn: Binding(get: { model.selection.contains(application.id) }, set: { enabled in
                if enabled { model.selection.insert(application.id) } else { model.selection.remove(application.id) }
            }))
            .labelsHidden().disabled(model.busy || !model.selectable(application))
        }
        .padding(.vertical, 5)
        .task(id: application.id) { if !model.demo { icon = FLApplicationIcon(application.id) } }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    var body: some View {
        NavigationStack {
            List {
                Section("Environment") {
                    if let info = model.inspection {
                        LabeledContent("iOS", value: info.device.osVersion)
                        LabeledContent("Build", value: info.device.osBuild)
                        LabeledContent("Architecture", value: info.device.architecture)
                        LabeledContent("Override", value: info.status.rawValue)
                        LabeledContent("Layout", value: info.layoutID ?? "Unknown")
                        if let summary = info.storeSummary {
                            LabeledContent("Snapshot", value: "\(summary.bytes) bytes")
                            LabeledContent("Bundle record sizes", value: summary.bundleRecordSizes.keys.sorted().map(String.init).joined(separator: ", "))
                        }
                    }
                    Toggle("Demo laboratory", isOn: $model.demo).disabled(model.busy)
                        .onChange(of: model.demo) { _, _ in model.selection.removeAll(); Task { await model.scan() } }
                }
                Section {
                    Button("Run Read-Only Inspection") { Task { await model.scan() } }
                    Button("Extended Store Discovery") { Task { await model.scan(extended: true) } }
                    Button("Import Layout for Copy Experiment") { importing = true }.disabled(model.demo)
                } footer: { Text("Extended discovery scans inode paths for up to 8 seconds. Imported profiles never authorize live writes.") }
                .disabled(model.busy)
                Section("Export") {
                    Button("Save Diagnostic Report") { Task { await model.export(includeSnapshot: false) } }
                    Button("Save Report and Raw Snapshot") { Task { await model.export(includeSnapshot: true) } }
                    if let url = model.exportURL { ShareLink("Share Report", item: url) }
                    Text("Exports stay on this device until shared. Reports contain application identifiers; raw stores can contain more private metadata.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Technical log") {
                    Text(model.inspection?.log ?? "Run an inspection to begin.").font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("Research") {
                    Link("Compatibility investigation and source", destination: URL(string: "https://github.com/Justintunsday/ForceLegacyUI")!)
                    Text("Verified means observed appearance evidence, not merely a successful SDK write. This release contains no verified device overrides.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Diagnostics")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case let .success(url): Task { await model.importProfile(url) }
                case let .failure(error): model.failed = true; model.message = error.localizedDescription
                }
            }
        }
    }
}

private struct BackupsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Restore Original Configuration").font(.headline)
                    Text("Each write keeps an immutable snapshot and original SDK values. Restoration resolves current records by identity and preserves unrelated registrations.").font(.subheadline).foregroundStyle(.secondary)
                }
                if model.backups.isEmpty {
                    ContentUnavailableView("No backups yet", systemImage: "archivebox", description: Text("A verified backup is created automatically before any change. Try the demo laboratory to test restoration."))
                }
                ForEach(model.backups) { entry in
                    Section {
                        Text(entry.receipt.created, style: .date).font(.headline)
                        Text(entry.receipt.id.uuidString).font(.caption).foregroundStyle(.secondary)
                        LabeledContent("State", value: entry.status.rawValue)
                        ForEach(entry.receipt.changes, id: \.bundleID) { change in
                            Text("\(change.bundleID)\n\(change.original) → \(change.target)").font(.caption)
                        }
                        if [.applied, .prepared, .needsRecovery].contains(entry.status) {
                            Button("Restore Original Configuration") { Task { await model.restore(entry) } }.disabled(model.busy)
                        }
                    }
                }
            }.navigationTitle("Restore")
        }
    }
}
