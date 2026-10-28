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

        // 教程单独一扇窗：与主窗并排摆着边看边设，不像工作表那样把主窗挡死
        Window("使用教程", id: "tutorial") {
            TutorialView()
                .environmentObject(model)
        }
        .defaultSize(width: 640, height: 700)
    }
}
