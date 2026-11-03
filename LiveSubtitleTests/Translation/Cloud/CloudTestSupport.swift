import Foundation
import Synchronization
#if !TASK08_HOST_CHECK
@testable import LiveSubtitle
#endif

struct CloudRecordedRequest: Sendable {
    let url: URL
    let method: String?
    let headers: [String: String]
    let body: Data?
}

struct CloudStubResponse: Sendable {
    var status = 200
    var headers = ["Content-Type": "text/event-stream"]
    var chunks: [Data] = []
    var redirectTo: URL?
    var gate: DispatchSemaphore?

    static func sse(_ text: String, splitBytes: Bool = false) -> CloudStubResponse {
        let data = Data(text.utf8)
        return CloudStubResponse(chunks: splitBytes ? data.map { Data([$0]) } : [data])
    }

    static func json(_ text: String, status: Int = 200) -> CloudStubResponse {
        CloudStubResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            chunks: [Data(text.utf8)]
        )
    }
}

final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (CloudRecordedRequest) -> CloudStubResponse

    private struct StaticState {
        var handler: Handler?
        var requests: [CloudRecordedRequest] = []
    }

    private struct WorkState {
        var cancelled = false
        var gate: DispatchSemaphore?
    }

    private static let staticState = Mutex(StaticState())
    private let workState = Mutex(WorkState())

    static func reset() {
        staticState.withLock { $0 = StaticState() }
    }

    static func setHandler(_ handler: @escaping Handler) {
        staticState.withLock { $0.handler = handler }
    }

    static var requests: [CloudRecordedRequest] {
        staticState.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestBody = request.httpBody ?? Self.readBody(request.httpBodyStream) else {
            Self.recordAndRespond(
                CloudRecordedRequest(
                    url: request.url!, method: request.httpMethod,
                    headers: request.allHTTPHeaderFields ?? [:], body: nil
                ),
                for: self
            )
            return
        }
        Self.recordAndRespond(
            CloudRecordedRequest(
                url: request.url!, method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:], body: requestBody
            ),
            for: self
        )
    }

    override func stopLoading() {
        workState.withLock { state in
            state.cancelled = true
            state.gate?.signal()
        }
    }

    private static func recordAndRespond(_ recorded: CloudRecordedRequest, for instance: CloudURLProtocol) {
        let script = staticState.withLock { state -> CloudStubResponse in
            state.requests.append(recorded)
            return state.handler?(recorded) ?? CloudStubResponse(status: 500, chunks: [])
        }
        if let gate = script.gate {
            instance.workState.withLock { $0.gate = gate }
            gate.wait()
        }
        guard !instance.workState.withLock({ $0.cancelled }) else { return }
        if let redirectURL = script.redirectTo {
            var redirectRequest = URLRequest(url: redirectURL)
            redirectRequest.httpMethod = recorded.method
            redirectRequest.allHTTPHeaderFields = recorded.headers
            redirectRequest.httpBody = recorded.body
            let response = HTTPURLResponse(
                url: recorded.url, statusCode: script.status,
                httpVersion: "HTTP/1.1", headerFields: script.headers
            )!
            instance.client?.urlProtocol(instance, wasRedirectedTo: redirectRequest, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(
            url: recorded.url, statusCode: script.status,
            httpVersion: "HTTP/1.1", headerFields: script.headers
        )!
        instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in script.chunks {
            guard !instance.workState.withLock({ $0.cancelled }) else { return }
            instance.client?.urlProtocol(instance, didLoad: chunk)
        }
        instance.client?.urlProtocolDidFinishLoading(instance)
    }

    private static func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }
}

actor CloudCredentialStoreStub: CredentialStoring {
    private var keys: [UUID: String]
    private let blocksRead: Bool
    private var readContinuation: CheckedContinuation<Void, Never>?
    private(set) var readProfileIDs: [UUID] = []

    init(keys: [UUID: String], blocksRead: Bool = false) {
        self.keys = keys
        self.blocksRead = blocksRead
    }

    func readKey(profileID: UUID) async throws -> String? {
        readProfileIDs.append(profileID)
        if blocksRead {
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return keys[profileID]
    }

    func releaseRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func replaceKey(_ key: String, profileID: UUID) async throws {
        keys[profileID] = key
    }

    func deleteKey(profileID: UUID) async throws {
        keys.removeValue(forKey: profileID)
    }

    func clearAppNamespace() async throws {
        keys.removeAll()
    }
}

final class CloudClockStub: MonotonicClock {
    private struct State {
        var times: [UInt64]
        var index = 0
    }

    private let state: Mutex<State>

    init(times: [UInt64] = [0]) {
        state = Mutex(State(times: times.isEmpty ? [0] : times))
    }

    func now() -> MonotonicInstant {
        let value = state.withLock { state -> UInt64 in
            let value = state.times[min(state.index, state.times.count - 1)]
            state.index += 1
            return value
        }
        return MonotonicInstant(uptimeNanoseconds: value)
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        throw CancellationError()
    }
}

func cloudTestEventually(
    _ condition: () async -> Bool,
    attempts: Int = 1_000
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
