import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var store: RecallStore

    @MainActor
    init() {
        _store = StateObject(wrappedValue: RecallStore(automaticIndexInterval: .seconds(600)))
    }

    var body: some Scene {
        MenuBarExtra("Recall", systemImage: "clock.arrow.circlepath") {
            SearchView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
