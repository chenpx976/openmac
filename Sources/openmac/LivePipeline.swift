#if os(macOS)
import Foundation
import CryptoKit

struct LiveConfiguration: Codable {
    var barkURL = ""

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenMacLive", isDirectory: true)
    static let file = directory.appendingPathComponent("config.json")

    static func load() throws -> Self {
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }
        let config = Self()
        try config.save()
        return config
    }

    func save() throws {
        if !barkURL.isEmpty {
            guard let url = URL(string: barkURL), ["https", "http"].contains(url.scheme), url.host != nil else {
                throw APIRequestError.badRequest("Bark 地址应为包含设备 Key 的完整 HTTP(S) 地址")
            }
        }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

/// 保留不同消息类型的原始附加信息，包括平台返回的字符串和对象。
enum LiveJSON: Codable {
    case string(String), number(Double), bool(Bool), object([String: LiveJSON]), array([LiveJSON]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: LiveJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([LiveJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    subscript(key: String) -> LiveJSON? {
        if case .object(let values) = self { return values[key] }
        return nil
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
}

struct LiveMessage: Codable {
    let comment_id: String
    let content_type: Int
    let user_type: Int
    let org_msg_content: String
    let more_info: LiveJSON?
    let created_timestamp: Double
    let wx_nickname: String?
    let comment_name: String?
}

struct LiveMediaReference: Codable {
    let url: String
    let field: String
}

struct LiveBatch: Codable {
    let appId: String
    let aliveId: String
    let roomId: String
    let title: String
    let messages: [LiveMessage]
    var media: [LiveMediaReference]? = nil
    var roomKey: String { "\(appId):\(aliveId):\(roomId)" }
    func validate() throws {
        guard [appId, aliveId, roomId, title].allSatisfy({ !$0.isEmpty && $0.count <= 1000 }),
              messages.count <= 10000,
              messages.allSatisfy({ !$0.comment_id.isEmpty && $0.comment_id.count < 256 && $0.user_type == 1
                  && $0.created_timestamp.isFinite }) else {
            throw APIRequestError.badRequest("消息批次参数无效，请检查发送端的数据格式")
        }
    }
}

struct LiveJob: Codable {
    let key: String
    let room: String
    let title: String
    let message: LiveMessage
    var result: String?
    var attempts = 0
    var retryAt = Date.distantPast
    var error: String?
    var notified = false
    var mediaFiles: [String: String]? = nil
}

struct LiveNotification: Codable {
    var id = UUID().uuidString
    let title: String
    let body: String
    var sent = false
    var retryAt = Date.distantPast
}

struct LiveState: Codable {
    var jobs = [LiveJob]()
    var outbox = [LiveNotification]()
    var cache = [String: String]()
}

/// actor 串行保护状态。网络请求期间允许接收新消息，写盘成功后才返回确认。
actor LivePipeline {
    static let shared = LivePipeline()
    private var config: LiveConfiguration?
    private var state = LiveState()
    private var startupError: String?
    private var processing = false
    private var worker: Task<Void, Never>?
    private var lastError = ""
    private let file: URL
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(directory: URL = LiveConfiguration.directory, configuration: LiveConfiguration? = nil,
         send: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.send = send
        file = directory.appendingPathComponent("queue.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            config = try configuration ?? LiveConfiguration.load()
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: file))
            }
        } catch {
            startupError = "无法读取本地配置或队列：\(error.localizedDescription)"
        }
    }

    private func transaction(_ update: (inout LiveState) throws -> Void) throws {
        if let startupError { throw APIRequestError.internalError(startupError) }
        var next = state
        try update(&next)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
    }

    func saveConfiguration(_ value: LiveConfiguration) throws {
        try value.save()
        config = value
    }

    func ingest(_ batch: LiveBatch, files: [String: Data] = [:]) throws -> Int {
        try batch.validate()
        var mediaFiles = [String: String]()
        let mediaDirectory = file.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
        var total = 0
        for reference in batch.media ?? [] {
            let url = try Self.mediaURL(reference.url)
            guard let data = files[reference.field], !data.isEmpty else {
                throw APIRequestError.badRequest("上传媒体缺少字段 \(reference.field)")
            }
            total += data.count
            guard total <= 30 * 1024 * 1024 else { throw APIRequestError.badRequest("媒体总大小超过 30MB") }
            let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".bin"
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let destination = mediaDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            mediaFiles[url.absoluteString] = name
        }
        if batch.media != nil {
            for message in batch.messages {
                var required = [URL]()
                if message.content_type == 2 { required = try Self.imageURLs(message.org_msg_content) }
                if message.content_type == 3 {
                    guard let audio = message.more_info?["url"]?.string else {
                        throw APIRequestError.badRequest("语音消息缺少音频地址")
                    }
                    required.append(try Self.mediaURL(audio))
                    if let ppt = message.more_info?["target_ppt"]?["pic_url"]?.string {
                        required.append(try Self.mediaURL(ppt))
                    }
                }
                guard required.allSatisfy({ mediaFiles[$0.absoluteString] != nil }) else {
                    throw APIRequestError.badRequest("图片、音频或关联课件未完整上传")
                }
            }
        }
        var known = Set(state.jobs.map(\.key))
        var added = 0
        try transaction { next in
            for message in batch.messages {
                let key = batch.roomKey + ":" + message.comment_id
                if known.insert(key).inserted {
                    var job = LiveJob(key: key, room: batch.roomKey, title: batch.title, message: message)
                    job.mediaFiles = mediaFiles
                    next.jobs.append(job)
                    added += 1
                }
            }
        }
        return added
    }

    func retryFailures() throws {
        try transaction { next in
            for index in next.jobs.indices where next.jobs[index].error != nil {
                next.jobs[index].result = nil
                next.jobs[index].error = nil
                next.jobs[index].attempts = 0
                next.jobs[index].retryAt = .distantPast
                next.jobs[index].notified = false
            }
        }
        lastError = ""
    }

    func statusText() -> String {
        if let startupError { return startupError }
        let waiting = state.jobs.filter { $0.result == nil }.count
        let sending = state.outbox.filter { !$0.sent }.count
        return "待识别 \(waiting) 条，待推送 \(sending) 条通知" +
            (config?.barkURL.isEmpty != false ? "；尚未配置 Bark" : "") +
            (lastError.isEmpty ? "" : "；\(lastError)")
    }

    func start() {
        guard worker == nil else { return }
        worker = Task {
            while !Task.isCancelled {
                await processOnce()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
    }

    func stop() { worker?.cancel(); worker = nil }

    func processOnce() async {
        guard !processing, startupError == nil else { return }
        processing = true
        defer { processing = false }
        do {
            let jobs = state.jobs.filter { $0.result == nil && $0.retryAt <= Date() }.prefix(50)
            for job in jobs {
                try Task.checkCancellation()
                do {
                    let text = try await render(job.message, mediaFiles: job.mediaFiles ?? [:])
                    try transaction { next in
                        guard let index = next.jobs.firstIndex(where: { $0.key == job.key }) else { return }
                        next.jobs[index].result = text
                        next.jobs[index].error = nil
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let detail = error.localizedDescription
                    lastError = detail
                    try transaction { next in
                        guard let index = next.jobs.firstIndex(where: { $0.key == job.key }) else { return }
                        next.jobs[index].attempts += 1
                        next.jobs[index].error = detail
                        next.jobs[index].retryAt = Date().addingTimeInterval(Double(next.jobs[index].attempts * 30))
                        if next.jobs[index].attempts >= 3 {
                            let raw = String(data: try JSONEncoder().encode(job.message), encoding: .utf8) ?? ""
                            next.jobs[index].result = "【识别失败，保留原始消息】\n\(detail)\n\(raw)"
                        }
                    }
                }
            }
            try enqueueNotifications()
            try await sendNotifications()
        } catch is CancellationError { }
        catch { lastError = error.localizedDescription }
    }

    private func render(_ message: LiveMessage, mediaFiles: [String: String]) async throws -> String {
        var parts = [String]()
        switch message.content_type {
        case 0: parts.append(message.org_msg_content)
        case 2:
            for url in try Self.imageURLs(message.org_msg_content) {
                let text = try await recognize(url: url, speech: false, mediaFiles: mediaFiles)
                parts.append("【图片 OCR】\n\(text.isEmpty ? "未识别到文字" : text)\n\(url.absoluteString)")
            }
        case 3:
            guard let audio = message.more_info?["url"]?.string else {
                throw APIRequestError.badRequest("语音消息缺少 URL")
            }
            parts.append("【语音转写】\n" + (try await recognize(url: Self.mediaURL(audio), speech: true, mediaFiles: mediaFiles)))
            if let picture = message.more_info?["target_ppt"]?["pic_url"]?.string {
                parts.append("【关联课件 OCR】\n" + (try await recognize(url: Self.mediaURL(picture), speech: false, mediaFiles: mediaFiles)))
            }
        default: parts.append("【消息类型 \(message.content_type)】\n\(message.org_msg_content)")
        }
        let format = DateFormatter()
        format.dateFormat = "MM-dd HH:mm:ss"
        let name = message.comment_name ?? message.wx_nickname ?? "发送者"
        return "[\(format.string(from: Date(timeIntervalSince1970: message.created_timestamp)))] \(name)\n" + parts.joined(separator: "\n\n")
    }

    private func recognize(url: URL, speech: Bool, mediaFiles: [String: String]) async throws -> String {
        let stored = mediaFiles[url.absoluteString]
        let key = "\(speech ? "speech" : "ocr-zh-v2"):\(stored ?? url.absoluteString)"
        if let cached = state.cache[key] { return cached }
        let data: Data
        if let stored {
            let localFile = file.deletingLastPathComponent().appendingPathComponent("media").appendingPathComponent(stored)
            data = try Data(contentsOf: localFile)
        } else {
            data = try await Self.download(url)
        }
        let text: String
        if speech {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            text = try await SpeechTranscriber.transcribe(file: file)
        } else {
            text = try OCRService().recognizeText(in: data).text
        }
        try transaction { $0.cache[key] = text }
        return text
    }

    static func mediaURL(_ string: String) throws -> URL {
        guard var parts = URLComponents(string: string), let host = parts.host,
              ["http", "https"].contains(parts.scheme), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 80 || parts.port == 443,
              ["myqcloud.com", "xiaoeknow.com"].contains(where: { host.hasSuffix("." + $0) }) else {
            throw APIRequestError.badRequest("当前媒体地址不受支持，请使用文件上传")
        }
        parts.scheme = "https"
        parts.port = nil
        guard let url = parts.url else { throw APIRequestError.badRequest("媒体 URL 无效") }
        return url
    }

    static func imageURLs(_ raw: String) throws -> [URL] {
        struct Image: Decodable { let DownUrl: String }
        let images = try JSONDecoder().decode([Image].self, from: Data(raw.utf8))
        var urls = [String: URL]()
        var order = [String]()
        for image in images {
            let url = try mediaURL(image.DownUrl)
            let key = (url.host ?? "") + url.path
            if urls[key] == nil { order.append(key) }
            if urls[key] == nil || url.query == nil { urls[key] = url }
        }
        return order.compactMap { urls[$0] }
    }

    static func download(_ url: URL) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: LiveMediaRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw APIRequestError.internalError("媒体下载失败")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 30 * 1024 * 1024 else { throw APIRequestError.badRequest("媒体文件超过 30MB") }
        return try Data(contentsOf: file)
    }

    static func chunks(_ text: String, limit: Int = 1800) -> [String] {
        var result = [String](), chunk = "", size = 0
        for scalar in text.unicodeScalars {
            let part = String(scalar)
            if size + part.utf8.count > limit && !chunk.isEmpty {
                result.append(chunk); chunk = ""; size = 0
            }
            chunk += part; size += part.utf8.count
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }

    private func enqueueNotifications() throws {
        let ready = state.jobs.filter { $0.result != nil && !$0.notified }
        guard !ready.isEmpty else { return }
        try transaction { next in
            for room in Set(ready.map(\.room)).sorted() {
                // 有失败重试中的较早消息时先等它，保持房间内的发送顺序。
                let roomJobs = next.jobs.filter { $0.room == room && !$0.notified }
                    .sorted { $0.message.created_timestamp < $1.message.created_timestamp }
                let messages = Array(roomJobs.prefix(while: { $0.result != nil }))
                guard !messages.isEmpty else { continue }
                let body = messages.compactMap(\.result).joined(separator: "\n\n——\n\n")
                let parts = Self.chunks(body)
                for (index, part) in parts.enumerated() {
                    let title = String(messages[0].title.prefix(60)) + (parts.count > 1 ? " (\(index + 1)/\(parts.count))" : "")
                    next.outbox.append(LiveNotification(title: title, body: part))
                }
                let ids = Set(messages.map(\.key))
                for index in next.jobs.indices where ids.contains(next.jobs[index].key) { next.jobs[index].notified = true }
            }
        }
    }

    private func sendNotifications() async throws {
        guard let config, !config.barkURL.isEmpty, let url = URL(string: config.barkURL) else { return }
        for notification in state.outbox.filter({ !$0.sent }).prefix(50) {
            if notification.retryAt > Date() { break }
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "title": notification.title, "body": notification.body, "group": "OpenMac 消息", "isArchive": 1
                ])
                let (data, response) = try await send(request)
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (response as? HTTPURLResponse)?.statusCode == 200, payload?["code"] as? Int == 200 else {
                    throw APIRequestError.internalError("Bark 未确认成功")
                }
                try transaction { next in
                    if let index = next.outbox.firstIndex(where: { $0.id == notification.id }) { next.outbox[index].sent = true }
                }
            } catch {
                lastError = "Bark 推送失败，将在 30 秒后重试"
                try transaction { next in
                    if let index = next.outbox.firstIndex(where: { $0.id == notification.id }) {
                        next.outbox[index].retryAt = Date().addingTimeInterval(30)
                    }
                }
                break
            }
        }
    }
}

private final class LiveMediaRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let safe = try? LivePipeline.mediaURL(url.absoluteString) else {
            completionHandler(nil); return
        }
        var request = request
        request.url = safe
        completionHandler(request)
    }
}
#endif
