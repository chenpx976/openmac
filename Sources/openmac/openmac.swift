#if os(macOS)
import SwiftUI

@main
struct OpenMacApp: App {
    @StateObject private var model = OpenMacAppModel()

    var body: some Scene {
        WindowGroup("OpenMac", id: "settings") {
            OpenMacView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("OpenMac", systemImage: "antenna.radiowaves.left.and.right") {
            OpenMacMenu().environmentObject(model)
        }
    }
}

private struct OpenMacMenu: View {
    @EnvironmentObject private var model: OpenMacAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("显示设置") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("本地服务", isOn: Binding(get: { model.isEnabled }, set: { model.toggleServer($0) }))
        Divider()
        Button("退出 OpenMac") { NSApp.terminate(nil) }
    }
}
#else
@main
struct openmac {
    static func main() {
        print("openmac requires macOS to run the SwiftUI app.")
    }
}
#endif
