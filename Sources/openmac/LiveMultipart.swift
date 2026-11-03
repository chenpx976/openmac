import Foundation

/// 解析浏览器 FormData；文件始终作为 Data 处理，不经 UTF-8 或 Base64 转换。
struct LiveMultipart {
    let fields: [String: Data]

    init(body: Data, contentType: String) throws {
        guard contentType.lowercased().hasPrefix("multipart/form-data"),
              let parameter = contentType.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.lowercased().hasPrefix("boundary=") }) else {
            throw APIRequestError.badRequest("缺少 multipart boundary")
        }
        let boundary = String(parameter.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !boundary.isEmpty, boundary.utf8.count <= 200, !boundary.contains("\r"), !boundary.contains("\n") else {
            throw APIRequestError.badRequest("无效 multipart boundary")
        }
        let delimiter = Data(("--" + boundary).utf8)
        let nextDelimiter = Data(("\r\n--" + boundary).utf8)
        let newline = Data("\r\n".utf8)
        let separator = Data("\r\n\r\n".utf8)
        guard body.starts(with: delimiter) else { throw APIRequestError.badRequest("multipart 起始标记无效") }
        var cursor = delimiter.count
        var fields = [String: Data]()
        while cursor < body.count {
            if body[cursor...].starts(with: Data("--".utf8)) {
                self.fields = fields
                return
            }
            guard body[cursor...].starts(with: newline) else { throw APIRequestError.badRequest("multipart 分隔符无效") }
            cursor += newline.count
            guard let headerEnd = body.range(of: separator, in: cursor..<body.count),
                  headerEnd.lowerBound - cursor < 8192,
                  let header = String(data: body[cursor..<headerEnd.lowerBound], encoding: .utf8),
                  let disposition = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-disposition:") }),
                  let namePart = disposition.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
                    .first(where: { $0.hasPrefix("name=\"") && $0.hasSuffix("\"") }) else {
                throw APIRequestError.badRequest("multipart 字段头无效")
            }
            let name = String(namePart.dropFirst(6).dropLast())
            guard name == "metadata" || name.hasPrefix("media"), fields[name] == nil, fields.count < 32 else {
                throw APIRequestError.badRequest("multipart 字段重复或过多")
            }
            let start = headerEnd.upperBound
            var search = start
            var end: Range<Data.Index>?
            while let found = body.range(of: nextDelimiter, in: search..<body.count) {
                let suffix = body[found.upperBound...]
                if suffix.starts(with: newline) || suffix.starts(with: Data("--".utf8)) { end = found; break }
                search = found.upperBound
            }
            guard let end else { throw APIRequestError.badRequest("multipart 缺少结束标记") }
            fields[name] = Data(body[start..<end.lowerBound])
            cursor = end.upperBound
        }
        throw APIRequestError.badRequest("multipart 请求未结束")
    }
}
