import Foundation
import WhisperRuntime

@main struct WhisperBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count >= 4 else {
            print("用法：whisper-benchmark MODEL PROMPT AUDIO [AUDIO...]")
            return
        }
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        let prompt = CommandLine.arguments[2]
        let vad = model.deletingLastPathComponent().appendingPathComponent("ggml-silero-v6.2.0.bin")
        do {
            for path in CommandLine.arguments.dropFirst(3) {
                let started = Date()
                let transcript = try await WhisperEngine.shared.transcribe(file: URL(fileURLWithPath: path), model: model, prompt: prompt,
                    vadModel: FileManager.default.fileExists(atPath: vad.path) ? vad : nil)
                let segments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript.segments))
                let output: [String: Any] = ["file": path, "seconds": Date().timeIntervalSince(started), "text": transcript.text, "segments": segments]
                print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
            }
        } catch {
            await WhisperEngine.shared.releaseModel()
            throw error
        }
        // 正常结束前释放 Metal 缓冲，不能依赖进程静态析构顺序。
        await WhisperEngine.shared.releaseModel()
    }
}
