import SwiftUI

@main
struct RecallApp: App {
    var body: some Scene {
        MenuBarExtra("Recall", systemImage: "clock.arrow.circlepath") {
            SearchView()
        }
        .menuBarExtraStyle(.window)
    }
}
