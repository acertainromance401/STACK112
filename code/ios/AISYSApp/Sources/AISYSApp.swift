import SwiftUI
import SwiftData

@main
struct AISYSApp: App {
    @StateObject private var store = ReviewStore()
    @StateObject private var runtime = AppRuntimeState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(runtime)
                .task {
                    await LLMService.shared.loadModelIfNeeded()
                }
        }
        .modelContainer(for: ScannedCase.self)
    }
}
