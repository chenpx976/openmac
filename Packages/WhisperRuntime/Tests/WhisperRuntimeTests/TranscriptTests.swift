import XCTest
import AVFoundation
@testable import WhisperRuntime

final class TranscriptTests: XCTestCase {
    func testTimingBreaksPreserveRepeatedWords() {
        let first = String(repeating: "原话继续保留", count: 6)
        let transcript = WhisperTranscript(segments: [
            .init(start: 0, end: 8, text: first, meanLogProbability: -0.1, noSpeechProbability: 0.01),
            .init(start: 9, end: 12, text: "涨了涨了涨了", meanLogProbability: -0.1, noSpeechProbability: 0.01)
        ])
        XCTAssertEqual(transcript.text, first + "\n\n涨了涨了涨了")
    }

    func testUncertainTextIsFlaggedInsteadOfDeleted() {
        let transcript = WhisperTranscript(segments: [
            .init(start: 61, end: 65, text: "谢谢观看", meanLogProbability: -1.5, noSpeechProbability: 0.7)
        ])
        XCTAssertTrue(transcript.text.contains("01:01–01:05 识别存疑"))
        XCTAssertTrue(transcript.text.hasSuffix("谢谢观看"))
    }

    func testNativeSilenceDoesNotProduceText() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISPER_TEST_MODEL"] else {
            throw XCTSkip("设置 WHISPER_TEST_MODEL 后执行本地模型集成测试")
        }
        let model = URL(fileURLWithPath: path)
        let vad = model.deletingLastPathComponent().appendingPathComponent("ggml-silero-v6.2.0.bin")
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000))
        buffer.frameLength = 32000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: 0, count: 32000)
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        do {
            _ = try await WhisperEngine.shared.transcribe(file: audio, model: model, prompt: "简体中文。", vadModel: vad)
            XCTFail("静音不能输出成功转写")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未识别到有效文字"), error.localizedDescription)
        }
        await WhisperEngine.shared.releaseModel()
    }
}
