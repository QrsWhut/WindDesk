import SwiftUI

@main
struct WindDeskApp: App {
    @State private var store = MarketStore()

    var body: some Scene {
        MenuBarExtra("Wind 行情", systemImage: "chart.line.uptrend.xyaxis") {
            PanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
