import AVFoundation
import Foundation
import whisper

final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline = Date().addingTimeInterval(600)
    func cancel() { lock.withLock { cancelled = true } }
    var shouldAbort: Bool { lock.withLock { cancelled || Date() >= deadline } }
}

/// 进程内运行官方 whisper.cpp；actor 串行复用模型，避免重复加载和并发访问 C context。
public actor WhisperEngine {
    public static let shared = WhisperEngine()
    private var context: OpaquePointer?
    private var modelPath = ""

    deinit { if let context { whisper_free(context) } }

    public func releaseModel() {
        if let context { whisper_free(context); self.context = nil }
        modelPath = ""
    }

    public nonisolated func transcribe(file: URL, model: URL, prompt: String, vadModel: URL? = nil) async throws -> WhisperTranscript {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await run(file: file, model: model, prompt: prompt, vadModel: vadModel, cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }

    private func run(file: URL, model: URL, prompt: String, vadModel: URL?, cancellation: CancellationState) throws -> WhisperTranscript {
        if cancellation.shouldAbort { throw CancellationError() }
        if context == nil || modelPath != model.path {
            if let context { whisper_free(context); self.context = nil }
            var options = whisper_context_default_params()
            options.use_gpu = true
            options.flash_attn = true
            context = model.path.withCString { whisper_init_from_file_with_params($0, options) }
            guard context != nil else { throw failure("无法加载本地 Whisper 模型") }
            modelPath = model.path
        }
        guard let context else { throw failure("Whisper 未初始化") }
        let samples = try pcmSamples(file: file, cancellation: cancellation)
        guard !samples.isEmpty else { throw failure("音频没有有效采样") }
        var options = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        options.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        options.beam_search.beam_size = 5
        options.translate = false
        options.no_context = true
        options.carry_initial_prompt = true
        options.print_progress = false
        options.print_realtime = false
        options.print_timestamps = false
        options.print_special = false
        options.vad = vadModel != nil
        options.vad_params.threshold = 0.4
        options.vad_params.min_speech_duration_ms = 150
        options.vad_params.min_silence_duration_ms = 700
        options.vad_params.speech_pad_ms = 250
        options.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        options.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<CancellationState>.fromOpaque(pointer).takeUnretainedValue().shouldAbort
        }
        // C 参数中的字符串指针在整个推理期间保持有效，不使用临时 NSString 指针。
        let status = "zh".withCString { language in
            prompt.withCString { initialPrompt in
                options.language = language
                options.initial_prompt = initialPrompt
                return (vadModel?.path ?? "").withCString { vadPath in
                    options.vad_model_path = vadModel == nil ? nil : vadPath
                    return samples.withUnsafeBufferPointer { buffer in
                        whisper_full(context, options, buffer.baseAddress, Int32(buffer.count))
                    }
                }
            }
        }
        try Task.checkCancellation()
        if cancellation.shouldAbort { throw failure("Whisper 识别超时") }
        guard status == 0 else { throw failure("Whisper 识别失败（\(status)）") }
        var segments = [TranscribedSegment]()
        for index in 0..<whisper_full_n_segments(context) {
            guard let pointer = whisper_full_get_segment_text(context, index) else { continue }
            let text = String(cString: pointer)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let logProbabilities = (0..<whisper_full_n_tokens(context, index)).compactMap { tokenIndex -> Double? in
                let token = whisper_full_get_token_data(context, index, tokenIndex)
                guard token.id < whisper_token_eot(context), token.p.isFinite else { return nil }
                return log(max(Double(token.p), 1e-9))
            }
            segments.append(TranscribedSegment(
                start: Double(whisper_full_get_segment_t0(context, index)) / 100,
                end: Double(whisper_full_get_segment_t1(context, index)) / 100,
                text: text,
                meanLogProbability: logProbabilities.isEmpty ? -10 : logProbabilities.reduce(0, +) / Double(logProbabilities.count),
                noSpeechProbability: Double(whisper_full_get_segment_no_speech_prob(context, index))))
        }
        guard !segments.isEmpty else { throw failure("Whisper 未识别到有效文字") }
        return WhisperTranscript(segments: segments)
    }

    func pcmSamples(file url: URL, cancellation: CancellationState) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw failure("无法转换音频为 16kHz 单声道")
        }
        var samples = [Float]()
        var ended = false
        while !ended {
            if cancellation.shouldAbort { throw CancellationError() }
            output.frameLength = 0
            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                do {
                    let remaining = file.length - file.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    let count = min(requested, input.frameCapacity, AVAudioFrameCount(min(remaining, Int64(UInt32.max))))
                    try file.read(into: input, frameCount: count)
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            guard samples.count <= 16000 * 1800 else { throw failure("音频超过 30 分钟") }
            switch status {
            case .endOfStream: ended = true
            case .error: throw failure("音频解码失败")
            case .inputRanDry, .haveData: break
            @unknown default: throw failure("未知音频转换状态")
            }
        }
        return samples
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "OpenMac.Whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
