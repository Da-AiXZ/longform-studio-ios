import SwiftUI

@main
struct LongformStudioApp: App {
    @StateObject private var appStore = AppStore.live()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(appStore)
                .environmentObject(appStore.settings)
                .task { await appStore.loadProjects() }
        }
    }
}
