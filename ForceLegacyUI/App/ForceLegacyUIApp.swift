import SwiftUI

@main
struct ForceLegacyUIApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}
