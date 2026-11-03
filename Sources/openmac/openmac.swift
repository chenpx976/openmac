#if os(macOS)
import SwiftUI

@main
struct OpenMacApp: App {
    @StateObject private var model = OpenMacAppModel()

    var body: some Scene {
        WindowGroup {
            OpenMacView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("OpenMac", systemImage: "antenna.radiowaves.left.and.right") {
            Button("显示设置") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Toggle("本地服务", isOn: Binding(get: { model.isEnabled }, set: { model.toggleServer($0) }))
            Divider()
            Button("退出 OpenMac") { NSApp.terminate(nil) }
        }
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
