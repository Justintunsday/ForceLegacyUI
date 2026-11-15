import SwiftUI
import UIKit

@main
struct CompatibilityProbeApp: App {
    init() { NSLog("ForceLegacyUI launch facts: %@", FLProbeFacts() as NSDictionary) }
    var body: some Scene { WindowGroup { ProbeView() } }
}

private struct ProbeView: View {
    @State private var facts: [String: String] = [:]
    @State private var enabled = true
    @State private var value = 0.5
    @State private var choice = 0
    @State private var text = ""
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    Section("SwiftUI controls") {
                        Text("Compare this screen before and after an SDK metadata experiment. Keep the binary and its signed Info.plist unchanged.")
                        Toggle("Sample switch", isOn: $enabled)
                        Picker("Sample segment", selection: $choice) { Text("First").tag(0); Text("Second").tag(1) }.pickerStyle(.segmented)
                        Slider(value: $value)
                        TextField("Sample text field", text: $text)
                        Button("Sample action") { enabled.toggle() }
                    }
                    Section("Observed launch inputs") {
                        ForEach(facts.keys.sorted(), id: \.self) { key in LabeledContent(key, value: facts[key] ?? "") }
                        Button("Refresh and Save Facts") { saveFacts() }
                        if let exportURL { ShareLink("Share Launch Facts", item: exportURL) }
                        if let exportError { Text(exportError).foregroundStyle(.red) }
                    }
                    Section {
                        Text("The plist opt-out in the Legacy control belongs only to that probe. Neither probe changes another app's bundle or appearance settings.").font(.footnote)
                    }
                }.navigationTitle("Compatibility Probe")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Action") { enabled.toggle() } } }
            }.tabItem { Label("SwiftUI", systemImage: "swift") }
            UIKitControls().tabItem { Label("UIKit", systemImage: "rectangle.3.group") }
        }.task { saveFacts() }
    }
    private func saveFacts() {
        let raw = FLProbeFacts()
        facts = raw.mapValues { String(describing: $0) }
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("launch-facts.json")
            try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            exportURL = url; exportError = nil
        } catch { exportError = error.localizedDescription }
    }
}

private struct UIKitControls: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = UIViewController()
        controller.title = "UIKit controls"
        controller.view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 28; stack.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel(); label.text = "Default UIKit navigation and toolbar"; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline); label.adjustsFontForContentSizeCategory = true
        let segment = UISegmentedControl(items: ["First", "Second"]); segment.selectedSegmentIndex = 0
        let slider = UISlider(); slider.value = 0.5
        let toggle = UISwitch(); toggle.isOn = true
        let field = UITextField(); field.placeholder = "Sample text field"; field.borderStyle = .roundedRect
        let button = UIButton(type: .system); button.setTitle("Sample action", for: .normal)
        [label, segment, slider, toggle, field, button].forEach { stack.addArrangedSubview($0) }
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
        controller.toolbarItems = [UIBarButtonItem(title: "First", style: .plain, target: nil, action: nil),
                                   UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "Second", style: .plain, target: nil, action: nil)]
        let navigation = UINavigationController(rootViewController: controller); navigation.isToolbarHidden = false
        return navigation
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) { }
}
