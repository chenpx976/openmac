import XCTest
@testable import WhisperRuntime

final class AudioConversionTests: XCTestCase {
    func testMP3EndOfFileAndResampling() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "mp3"))
        let samples = try await WhisperEngine.shared.pcmSamples(file: file, cancellation: CancellationState())
        XCTAssertEqual(samples.count, 3200, accuracy: 32)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertTrue(samples.contains { abs($0) > 0.01 })
    }

    func testCancellationBeforeConversion() async throws {
        let state = CancellationState()
        state.cancel()
        let file = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "mp3"))
        do {
            _ = try await WhisperEngine.shared.pcmSamples(file: file, cancellation: state)
            XCTFail("已取消的任务不能继续转换")
        } catch is CancellationError { }
    }
}
