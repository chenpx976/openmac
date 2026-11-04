#if os(macOS)
import SwiftUI

@main
struct OpenMacApp: App {
    @NSApplicationDelegateAdaptor(OpenMacLifecycle.self) private var lifecycle
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

/// 等待识别任务取消并释放 GPU 模型，避免进程退出时 Metal 静态析构顺序导致崩溃。
@MainActor
private final class OpenMacLifecycle: NSObject, NSApplicationDelegate {
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating {
            terminating = true
            Task {
                await LivePipeline.shared.shutdown()
                await SpeechTranscriber.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
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
