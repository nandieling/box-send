import SwiftUI
import BoxSendKit

@main
struct BoxSendAppMain: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("BoxSend \(BoxSendVersion.version)") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
