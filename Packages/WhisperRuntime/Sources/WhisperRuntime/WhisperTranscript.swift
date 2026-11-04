import Foundation

public struct TranscribedSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let meanLogProbability: Double
    public let noSpeechProbability: Double

    var needsReview: Bool { meanLogProbability < -1 || noSpeechProbability > 0.6 }
}

public struct WhisperTranscript: Codable, Sendable {
    public let segments: [TranscribedSegment]

    /// 保留全部识别文字和口语重复；时间边界辅助分段，低置信片段只标注、不删除。
    public var text: String {
        var output = ""
        var paragraphLength = 0
        var previousEnd = 0.0
        for segment in segments {
            if segment.needsReview {
                output += "\n\n【\(timestamp(segment.start))–\(timestamp(segment.end)) 识别存疑，请核对原音频】\n"
                paragraphLength = 0
            } else if paragraphLength >= 90 || (paragraphLength >= 30 && segment.start - previousEnd >= 0.7) {
                output += "\n\n"
                paragraphLength = 0
            }
            output += segment.text
            paragraphLength += segment.text.count
            if segment.needsReview { output += "\n\n"; paragraphLength = 0 }
            previousEnd = segment.end
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
