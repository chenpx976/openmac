import Foundation
import AppKit

func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "LiveChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

actor Requests {
    var bodies = [Data]()
    func record(_ request: URLRequest) { bodies.append(request.httpBody ?? Data()) }
    var count: Int { bodies.count }
}

@main
struct LiveChecks {
    static func main() async throws {
        var transcript = SpeechTranscript()
        transcript.accept("第一")
        transcript.accept("第一句话")
        transcript.accept("第一句话", start: 0.7, end: 3.2)
        transcript.accept("")
        try check(try transcript.finish() == "第一句话", "空最终回调不能清空已识别句子")
        transcript.accept("第二")
        transcript.accept("第二句话", start: 5.1, end: 8.6)
        try check(try transcript.finish() == "第一句话\n第二句话", "停顿后的句子不应覆盖前文")
        transcript.accept("第一句修订", start: 0.7, end: 3.3)
        try check(try transcript.finish() == "第一句修订\n第二句话", "同一句修订必须覆盖，不能重复拼接")
        transcript.accept("第一句修订第二句话", start: 0.7, end: 8.6)
        try check(try transcript.finish() == "第一句修订第二句话", "累积回调不能重复前文")
        var emptyTranscript = SpeechTranscript()
        emptyTranscript.accept(" \n")
        do { _ = try emptyTranscript.finish(); throw NSError(domain: "empty speech accepted", code: 1) }
        catch is APIRequestError { }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = LiveConfiguration()
        config.barkURL = "https://example.invalid/test-key"
        let requests = Requests()
        let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            await requests.record(request)
            return (Data("{\"code\":200}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let pipeline = LivePipeline(directory: directory, configuration: config, send: transport)
        let message = LiveMessage(comment_id: "message-1", content_type: 0, user_type: 1,
            org_msg_content: "测试新增消息", more_info: .string("\"\""), created_timestamp: 1700000000,
            wx_nickname: "主播", comment_name: nil)
        let batch = LiveBatch(appId: "app-test", aliveId: "live-test", roomId: "room-test", title: "测试直播", messages: [message, message])
        try check(try await pipeline.ingest(batch) == 1, "批次内去重失败")
        try check(try await pipeline.ingest(batch) == 0, "重复提交未去重")
        let recovered = LivePipeline(directory: directory, configuration: config, send: transport)
        try check(try await recovered.ingest(batch) == 0, "重启后去重状态丢失")
        await recovered.processOnce()
        try check(await requests.count == 1, "应该只推送一次")
        await recovered.processOnce()
        try check(await requests.count == 1, "队列重复推送")
        let stateFile = directory.appendingPathComponent("queue.json")
        let state = try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: stateFile))
        try check(state.jobs[0].result?.contains("测试新增消息") == true && state.outbox[0].sent, "消息处理或推送确认未持久化")

        let failing = LivePipeline(directory: directory.appendingPathComponent("failed"), configuration: config, send: { request in
            (Data("{\"code\":500}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await failing.ingest(batch)
        await failing.processOnce()
        try check(await failing.statusText().contains("待推送 1"), "推送失败不应丢消息")
        let failedState = try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: directory.appendingPathComponent("failed/queue.json")))
        try check(!failedState.outbox[0].sent && failedState.outbox[0].retryAt > Date(), "推送失败应安排重试")

        let rawImages = "[{\"DownUrl\":\"http://wxresource.xiaoeknow.com/a.png?thumbnail=2000\"},{\"DownUrl\":\"http://wxresource.xiaoeknow.com/a.png\"},{\"DownUrl\":\"http://wxresource.xiaoeknow.com/a.png\"}]"
        let images = try LivePipeline.imageURLs(rawImages)
        try check(images.count == 1 && images[0].query == nil && images[0].scheme == "https", "原图/缩略图去重失败")
        do { _ = try LivePipeline.mediaURL("http://127.0.0.1/secrets"); throw NSError(domain: "allowed unsafe URL", code: 1) }
        catch is APIRequestError { }
        let longText = String(repeating: "中文🙂", count: 1000)
        let parts = LivePipeline.chunks(longText)
        try check(parts.joined() == longText && parts.allSatisfy { $0.utf8.count <= 1800 }, "通知分段损坏文本或超过字节限制")
        let badRequest = Data("POST /api/live/messages HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        do { _ = try HTTPRequestParser.parse(buffer: badRequest); throw NSError(domain: "negative length accepted", code: 1) }
        catch is APIRequestError { }

        let binary = Data([0, 255, 128, 13, 10, 42]) + Data("\r\n--test-boundary-not-a-delimiter".utf8)
        var multipart = Data("--test-boundary\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n{}\r\n--test-boundary\r\nContent-Disposition: form-data; name=\"media0\"; filename=\"audio.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n".utf8)
        multipart.append(binary)
        multipart.append(Data("\r\n--test-boundary--\r\n".utf8))
        let fields = try LiveMultipart(body: multipart, contentType: "multipart/form-data; boundary=test-boundary").fields
        try check(fields["media0"] == binary && fields["metadata"] == Data("{}".utf8), "multipart 二进制被损坏")

        // 空转写必须进入失败重试，旧版空白/截断缓存必须重识别，且不重发通知。
        let voiceDirectory = directory.appendingPathComponent("speech-test")
        let voice = LiveMessage(comment_id: "voice-test", content_type: 3, user_type: 1, org_msg_content: "",
            more_info: .object(["url": .string("https://media.myqcloud.com/test.mp3")]),
            created_timestamp: 1700000000, wx_nickname: "发送者", comment_name: nil)
        var voiceBatch = LiveBatch(appId: "app", aliveId: "source", roomId: "room", title: "语音记录", messages: [voice])
        voiceBatch.notify = false
        voiceBatch.media = [LiveMediaReference(url: "https://media.myqcloud.com/test.mp3", field: "audio")]
        let emptySpeech = LivePipeline(directory: voiceDirectory, configuration: config, send: transport, transcribe: { _ in " \n" })
        _ = try await emptySpeech.ingest(voiceBatch, files: ["audio": Data([1, 2, 3])])
        await emptySpeech.processOnce()
        let voiceFile = voiceDirectory.appendingPathComponent("queue.json")
        var legacy = try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: voiceFile))
        try check(legacy.jobs[0].result == nil && legacy.jobs[0].error != nil && legacy.cache.isEmpty,
            "空转写不能标记为成功或写入缓存")
        legacy.jobs[0].result = "[时间] 发送者\n【语音转写】\n"
        legacy.jobs[0].recognitionVersion = 2
        legacy.jobs[0].error = nil
        legacy.jobs[0].notify = true
        legacy.jobs[0].notified = true
        try JSONEncoder().encode(legacy).write(to: voiceFile)
        let fixedSpeech = LivePipeline(directory: voiceDirectory, configuration: config, send: transport, transcribe: { _ in "完整前句\n后句" })
        let voiceRequest = MarkdownExportRequest(appId: "app", aliveId: "source", roomId: "room", title: "语音记录", commentIds: ["voice-test"])
        let notificationsBeforeRepair = await requests.count
        try check(try await fixedSpeech.markdownExport(voiceRequest).completed == 0, "旧语音缓存应失效")
        await fixedSpeech.processOnce()
        let repaired = try await fixedSpeech.markdownExport(voiceRequest)
        try check(repaired.failed == 0 && repaired.markdown?.contains("完整前句\n后句") == true, "重识别结果未进入导出")
        try check(await requests.count == notificationsBeforeRepair, "修复旧缓存不能重发通知")
        try check(try await fixedSpeech.markdownExport(voiceRequest).completed == 1, "新版本缓存不应反复失效")

        // 原生 Vision 冒烟测试，无网络、无需隐私授权。
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 120, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 120).fill()
        ("中韩半导体 HELLO 123" as NSString).draw(at: NSPoint(x: 20, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let ocr = try OCRService().recognizeText(in: png).text
        try check(ocr.contains("中韩半导体") && ocr.contains("123"), "原生 OCR 冒烟测试失败：\(ocr)")
        let privateImage = LiveMessage(comment_id: "private-image", content_type: 2, user_type: 1,
            org_msg_content: "[{\"DownUrl\":\"https://wxresource.xiaoeknow.com/private.png\"}]", more_info: nil,
            created_timestamp: 1700000001, wx_nickname: "主播", comment_name: nil)
        var mediaBatch = LiveBatch(appId: "app-test", aliveId: "live-test", roomId: "room-test", title: "上传图片", messages: [privateImage])
        mediaBatch.media = [LiveMediaReference(url: "https://wxresource.xiaoeknow.com/private.png", field: "media0")]
        let mediaStore = LivePipeline(directory: directory.appendingPathComponent("media-test"), configuration: config, send: transport)
        _ = try await mediaStore.ingest(mediaBatch, files: ["media0": png])
        let storedMedia = try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: directory.appendingPathComponent("media-test/queue.json")))
        let savedName = storedMedia.jobs[0].mediaFiles!["https://wxresource.xiaoeknow.com/private.png"]!
        try check(try Data(contentsOf: directory.appendingPathComponent("media-test/media/" + savedName)) == png, "上传媒体未原样落盘")
        await mediaStore.processOnce()
        let recognized = try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: directory.appendingPathComponent("media-test/queue.json")))
        try check(recognized.jobs[0].result?.contains("中韩半导体") == true, "上传图片应该直接识别本地文件，不再访问私有 URL")
        do {
            _ = try await mediaStore.ingest(mediaBatch, files: [:])
            throw NSError(domain: "missing upload accepted", code: 1)
        } catch is APIRequestError { }
        let exports = LivePipeline(directory: directory.appendingPathComponent("exports"), configuration: config, send: transport)
        var silent = LiveBatch(appId: "app-test", aliveId: "live-test", roomId: "export-room", title: "文字记录", messages: [privateImage, message])
        silent.media = mediaBatch.media
        silent.notify = false
        let exportRequest = MarkdownExportRequest(appId: silent.appId, aliveId: silent.aliveId,
            roomId: silent.roomId, title: silent.title, commentIds: [privateImage.comment_id, message.comment_id, message.comment_id])
        let missing = try await exports.markdownExport(exportRequest)
        try check(missing.missing.count == 2 && missing.markdown == nil, "导出应报告缺失消息并去重")
        let pushCount = await requests.count
        _ = try await exports.ingest(silent, files: ["media0": png])
        let waiting = try await exports.markdownExport(exportRequest)
        try check(waiting.completed == 0 && waiting.missing.isEmpty && waiting.markdown == nil, "识别未完成不能生成完整文档")
        await exports.processOnce()
        await exports.processOnce()
        let document = try await exports.markdownExport(exportRequest)
        try check(document.completed == 2 && document.failed == 0, "导出处理进度错误")
        try check(document.markdown?.contains("中韩半导体") == true && document.markdown?.contains("测试新增消息") == true, "Markdown 应包含原文与 OCR")
        let markdown = document.markdown!
        try check(markdown.range(of: "测试新增消息")!.lowerBound < markdown.range(of: "中韩半导体")!.lowerBound, "Markdown 应按时间排序")
        let afterExport = await requests.count
        try check(!markdown.contains("<audio") && afterExport == pushCount, "导出不能附带音频或推送 Bark")
        let exportRestart = LivePipeline(directory: directory.appendingPathComponent("exports"), configuration: config, send: transport)
        try check(try await exportRestart.markdownExport(exportRequest).markdown == markdown, "重启后应复用导出结果")
        silent.notify = true
        _ = try await exports.ingest(silent, files: ["media0": png])
        await exports.processOnce()
        try check(await requests.count == pushCount + 1, "仅导出的消息随后进入监听时应正常推送一次")
        print("通过：持久化恢复、批次去重、推送确认、失败重试、图片去重、通知分段、HTTP 校验、multipart 二进制、上传落盘、中文 OCR、Markdown 导出与推送隔离")
    }
}
