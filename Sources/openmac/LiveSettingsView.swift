#if os(macOS)
import SwiftUI
import AppKit

struct LiveSettingsView: View {
    @State private var config = LiveConfiguration()
    @State private var status = "正在读取配置…"
    @State private var notice = ""
    @State private var loaded = false
    @State private var speechPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接收消息 → 语音转写 / 图片 OCR → 转发 Bark")
                .font(.subheadline.weight(.semibold))
            Text("将文字、图片和音频发送到 OpenMac，处理后的消息可转发到 Bark。关闭窗口后服务继续运行。")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Bark 完整地址：https://api.day.app/设备Key", text: $config.barkURL)
                .textFieldStyle(.roundedBorder)
            TextField("识别术语（可选，用顿号分隔名称和专业词）", text: $speechPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text("也会参考同房间的原始文字辅助识别名称，不直接替换正文。修改术语后重新导出会重新识别语音。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存设置") {
                    Task {
                        do {
                            config.barkURL = config.barkURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            config.speechPrompt = speechPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            try await LivePipeline.shared.saveConfiguration(config)
                            notice = "设置已保存"
                        } catch { notice = error.localizedDescription }
                    }
                }.disabled(!loaded)
                Button("授权语音识别") {
                    Task {
                        notice = await SpeechTranscriber.authorize()
                            ? "已授权；语音仅在本机识别" : "未授权，请检查系统设置 → 隐私与安全性 → 语音识别"
                    }
                }
                Button("刷新状态") { Task { status = await LivePipeline.shared.statusText() } }
            }
            Button("重新识别失败消息") {
                Task {
                    do { try await LivePipeline.shared.retryFailures(); notice = "失败消息已重新入队" }
                    catch { notice = error.localizedDescription }
                }
            }
            Text(status).font(.caption).textSelection(.enabled)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text("识别失败自动重试三次，之后推送原始消息和失败说明。Bark 未送达会持续重试。")
                .font(.caption).foregroundStyle(.secondary)
            Button("打开本地消息目录") { NSWorkspace.shared.open(LiveConfiguration.directory) }
            Spacer()
        }
        .task {
            do {
                config = try LiveConfiguration.load()
                speechPrompt = config.speechPrompt ?? ""
                loaded = true
            }
            catch { notice = error.localizedDescription }
            status = await LivePipeline.shared.statusText()
        }
    }
}
#endif
