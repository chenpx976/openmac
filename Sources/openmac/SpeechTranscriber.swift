#if os(macOS)
import Foundation
import AVFoundation
import Speech

/// 一次识别对应一个对象，保证结果、错误与超时只恢复一次 continuation。
@MainActor
private final class SpeechOperation {
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?

    func run(file: URL) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw APIRequestError.badRequest("请先在直播消息设置中授权语音识别")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw APIRequestError.internalError("当前 Mac 不支持中文本地语音识别，请检查系统语言与语音模型")
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task = recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        if let result, result.isFinal {
                            self.finish(.success(result.bestTranscription.formattedString))
                        } else if let error {
                            self.finish(.failure(error))
                        }
                    }
                }
                timeout = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                    self.finish(.failure(APIRequestError.internalError("语音识别超时")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        task?.cancel()
        task = nil
        recognizer = nil
        continuation.resume(with: result)
    }
}

enum SpeechTranscriber {
    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// 分成最多 50 秒的小段，兼容直播中超过一分钟的语音。
    static func transcribe(file: URL) async throws -> String {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 1800 else {
            throw APIRequestError.badRequest("语音时长必须在 0 至 1800 秒之间")
        }
        var texts = [String]()
        for start in stride(from: 0.0, to: duration, by: 50.0) {
            try Task.checkCancellation()
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw APIRequestError.internalError("无法解码语音")
            }
            let chunk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: chunk) }
            export.outputURL = chunk
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: min(50, duration - start), preferredTimescale: 600))
            await withCheckedContinuation { continuation in
                export.exportAsynchronously { continuation.resume() }
            }
            guard export.status == .completed else {
                throw export.error ?? APIRequestError.internalError("语音分段失败")
            }
            let text = try await SpeechOperation().run(file: chunk)
            texts.append(text)
        }
        return texts.joined(separator: "\n")
    }
}
#endif
