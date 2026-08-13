import SwiftUI

@main
struct BeijingClockApp: App {

    init() {
        CrashLogger.shared.setup()
        CrashLogger.shared.log("App 启动，崩溃捕获器已安装")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
