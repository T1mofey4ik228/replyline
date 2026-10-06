import SwiftUI

@main
struct ClientReplyCompanionApp: App {
    @StateObject private var capture = CaptureManager()
    @StateObject private var promptProfiles = PromptProfileStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(capture)
                .environmentObject(promptProfiles)
                .frame(minWidth: 760, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
