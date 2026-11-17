import SwiftUI

@main
struct GitSyncApp: App {
    @StateObject private var engine = SyncEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(engine)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: engine.paused ? "pause.circle" : "arrow.triangle.2.circlepath")
                let attention = engine.staleResults.count + engine.failedResults.filter { !$0.isStale(days: SyncEngine.staleDays) }.count
                if attention > 0 { Text("\(attention)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
