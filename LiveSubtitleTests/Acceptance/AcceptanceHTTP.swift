import Foundation
import Synchronization
@testable import LiveSubtitle

/// Test-only, host-isolated transport. Unregistered requests fail closed.
/// URLProtocol requires restating its inherited conformance; all shared state uses Mutex.
final class AcceptanceHTTP: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var contentType = "application/json"
        var chunks: [Data] = []
        var staysOpen = false
        var error: URLError.Code?

        static var json: Self {
            Self(chunks: [Data(#"{"choices":[{"message":{"content":"固定译文"},"finish_reason":"stop"}]}"#.utf8)])
        }

        static func sse(seed: UInt64, staysOpen: Bool = false, padding: Int = 0) -> Self {
            var text = ": keepalive\r\n\r\ndata: {\"choices\":[]}\r\n\r\n"
            for piece in ["你", "👩🏽‍💻", "好"] {
                text += "data: {\"choices\":[{\"delta\":{\"content\":\"\(piece)\"}}]}\r\n\r\n"
            }
            if !staysOpen { text += "data: [DONE]\r\n\r\n" }
            if padding > 0 { text += ":" + String(repeating: ".", count: padding) + "\r\n\r\n" }
            let bytes = Array(text.utf8)
            var random = seed
            var offset = 0
            var chunks: [Data] = []
            while offset < bytes.count {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let end = min(bytes.count, offset + Int(random % 17) + 1)
                chunks.append(Data(bytes[offset..<end]))
                offset = end
            }
            return Self(contentType: "text/event-stream", chunks: chunks, staysOpen: staysOpen)
        }
    }

    private struct Exchange {
        var response: Response
        var bodies: [Data] = []
        var delivered = 0
        var cancelled = 0
    }
    private static let exchanges = Mutex<[String: Exchange]>([:])

    static func install(_ response: Response, host: String) {
        exchanges.withLock { $0[host] = Exchange(response: response) }
    }
    static func replace(_ response: Response, host: String) {
        exchanges.withLock { $0[host]?.response = response }
    }
    static func bodies(host: String) -> [Data] { exchanges.withLock { $0[host]?.bodies ?? [] } }
    static func delivered(host: String) -> Int { exchanges.withLock { $0[host]?.delivered ?? 0 } }
    static func cancelled(host: String) -> Int { exchanges.withLock { $0[host]?.cancelled ?? 0 } }
    static func remove(host: String) { _ = exchanges.withLock { $0.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host else { return }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let script = Self.exchanges.withLock { state -> Response? in
            guard state[host] != nil else { return nil }
            state[host]?.bodies.append(body)
            return state[host]?.response
        }
        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = script.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: nil,
                headerFields: ["Content-Type": script.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in script.chunks { client?.urlProtocol(self, didLoad: chunk) }
            if !script.staysOpen { client?.urlProtocolDidFinishLoading(self) }
        }
        Self.exchanges.withLock { $0[host]?.delivered += 1 }
    }
    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.exchanges.withLock { $0[host]?.cancelled += 1 }
    }
    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
