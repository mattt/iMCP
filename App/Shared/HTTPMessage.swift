import Foundation

/// An HTTP/1.1 request read from a connection.
struct HTTPRequestMessage: Equatable, Sendable {
    var method: String
    /// The path without its query.
    var path: String
    /// Header fields, with repeated fields joined by commas.
    var headers: [String: String]
    var body: Data
    /// Whether the client expects the connection to stay open after the response.
    var keepAlive: Bool

    func header(_ name: String) -> String? {
        let name = name.lowercased()
        return headers.first { $0.key.lowercased() == name }?.value
    }
}

/// Reads HTTP/1.1 requests from the bytes received on a connection.
///
/// The MCP endpoint only needs small JSON bodies,
/// so the parser requires `Content-Length` and doesn't accept chunked request bodies.
enum HTTPRequestParser {
    static let maximumHeaderLength = 16 * 1024
    static let maximumBodyLength = 8 * 1024 * 1024

    enum Result: Equatable {
        /// The buffer doesn't hold a whole request yet.
        /// `expectsContinue` is true when the client waits for `100 Continue` before it sends the body.
        case incomplete(expectsContinue: Bool)
        /// A request, and the number of bytes it took from the start of the buffer.
        case request(HTTPRequestMessage, length: Int)
        /// The request can't be read; respond with this status and close the connection.
        case failure(status: Int, reason: String)
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> Result {
        guard let terminator = buffer.range(of: headerTerminator) else {
            if buffer.count > maximumHeaderLength {
                return .failure(status: 431, reason: "Request header fields are too large.")
            }
            return .incomplete(expectsContinue: false)
        }
        let headerLength = terminator.upperBound - buffer.startIndex
        guard headerLength <= maximumHeaderLength else {
            return .failure(status: 431, reason: "Request header fields are too large.")
        }
        guard let head = String(data: buffer[buffer.startIndex ..< terminator.lowerBound], encoding: .utf8) else {
            return .failure(status: 400, reason: "The request header isn't valid UTF-8.")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") else {
            return .failure(status: 400, reason: "The request line isn't valid.")
        }
        let version = String(requestLine[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(status: 505, reason: "Only HTTP/1.1 is supported.")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(status: 400, reason: "A header field isn't valid.")
            }
            let name = line[..<colon]
            guard !name.isEmpty, name.allSatisfy(isTokenCharacter) else {
                return .failure(status: 400, reason: "A header field name isn't valid.")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Header names are case-insensitive, so keep the first spelling and join repeated fields.
            let key = headers.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? String(name)
            headers[key] = headers[key].map { "\($0), \(value)" } ?? value
        }

        let message = HTTPRequestMessage(
            method: String(requestLine[0]),
            path: String(requestLine[1].split(separator: "?", maxSplits: 1)[0]),
            headers: headers,
            body: Data(),
            keepAlive: false
        )

        if message.header("Transfer-Encoding") != nil {
            return .failure(status: 411, reason: "Send the request body with a Content-Length header.")
        }
        let contentLength: Int
        if let field = message.header("Content-Length") {
            guard let length = Int(field), length >= 0 else {
                return .failure(status: 400, reason: "The Content-Length header isn't valid.")
            }
            contentLength = length
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyLength else {
            return .failure(status: 413, reason: "The request body is too large.")
        }

        let bodyStart = terminator.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else {
            let expectsContinue = message.header("Expect")?.lowercased() == "100-continue"
            return .incomplete(expectsContinue: expectsContinue)
        }

        var request = message
        request.body = Data(buffer[bodyStart ..< bodyStart + contentLength])
        let connection = request.header("Connection")?.lowercased() ?? ""
        request.keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
        return .request(request, length: headerLength + contentLength)
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let value = character.asciiValue, value > 0x20, value < 0x7F else {
            return false
        }
        return !"\"(),/:;<=>?@[\\]{}".contains(character)
    }
}

/// Writes HTTP/1.1 responses.
enum HTTPResponseEncoder {
    /// The status line and header fields of a response.
    ///
    /// Pass `contentLength` for a response with a known body,
    /// or `nil` to send the body in chunks.
    static func head(
        status: Int,
        headers: [String: String],
        contentLength: Int?,
        keepAlive: Bool
    ) -> Data {
        // Framing headers come from the connection, not from the response.
        let framing: Set<String> = ["connection", "content-length", "transfer-encoding"]
        var lines = ["HTTP/1.1 \(status) \(reasonPhrase(for: status))"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key })
        where !framing.contains(name.lowercased()) && isSafe(name) && isSafe(value) {
            lines.append("\(name): \(value)")
        }
        if let contentLength {
            lines.append("Content-Length: \(contentLength)")
        } else {
            lines.append("Transfer-Encoding: chunked")
        }
        lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func chunk(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var chunk = Data((String(data.count, radix: 16) + "\r\n").utf8)
        chunk.append(data)
        chunk.append(contentsOf: Array("\r\n".utf8))
        return chunk
    }

    static let lastChunk = Data("0\r\n\r\n".utf8)

    static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Status \(status)"
        }
    }

    /// Whether a field has no line breaks.
    /// Check the bytes, because Swift treats CR LF as one character.
    private static func isSafe(_ field: String) -> Bool {
        !field.utf8.contains { $0 == 0x0D || $0 == 0x0A }
    }
}
