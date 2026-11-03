import Foundation
#if !TASK08_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private struct SSETestFailure: Error {
    let message: String
}

private func checkEveryUTF8SplitAndSSEBoundary() throws {
    let expected = [
        "{\"text\":\"你\"}",
        "first\nsecond",
        "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}",
        "{\"choices\":[]}",
        "{\"usage\":{\"total_tokens\":2}}"
    ]
    for newline in ["\n", "\r\n", "\r"] {
        let fixtures = [
            ": comment" + newline,
            "data: {\"text\":\"你\"}" + newline + newline,
            "data: first" + newline,
            "data: second" + newline + newline,
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}" + newline + newline,
            "data: {\"choices\":[]}" + newline + newline,
            "data: {\"usage\":{\"total_tokens\":2}}" + newline + newline
        ]
        let data = Data(fixtures.joined().utf8)
        for split in 0...data.count {
            var decoder = SSEDecoder()
            var events = try decoder.append(data[..<split])
            events.append(contentsOf: try decoder.append(data[split...]))
            events.append(contentsOf: try decoder.finish())
            guard events.map({ String(decoding: $0, as: UTF8.self) }) == expected else {
                throw SSETestFailure(message: "SSE split \(split) with \(newline.debugDescription) changed events")
            }
        }
        var byteDecoder = SSEDecoder()
        var byteEvents: [Data] = []
        for byte in data {
            byteEvents.append(contentsOf: try byteDecoder.append(Data([byte])))
        }
        byteEvents.append(contentsOf: try byteDecoder.finish())
        guard byteEvents.map({ String(decoding: $0, as: UTF8.self) }) == expected else {
            throw SSETestFailure(message: "byte-split SSE with \(newline.debugDescription) changed events")
        }
    }
}

private func checkEventByteLimit() throws {
    let prefix = "data: "
    let delimiter = "\n\n"
    let exactPayload = String(
        repeating: "x",
        count: RuntimePolicy.sseEventByteLimit - prefix.utf8.count - delimiter.utf8.count
    )
    var exactDecoder = SSEDecoder()
    let exactEvents = try exactDecoder.append(Data((prefix + exactPayload + delimiter).utf8))
    guard exactEvents.count == 1, exactEvents[0].count == exactPayload.utf8.count else {
        throw SSETestFailure(message: "exact 64 KiB event was rejected")
    }

    var oversizedDecoder = SSEDecoder()
    do {
        _ = try oversizedDecoder.append(Data((prefix + exactPayload + "x" + delimiter).utf8))
        throw SSETestFailure(message: "oversized event was accepted")
    } catch let error as SSEDecoderError {
        guard error == .eventTooLarge else { throw error }
    }
}

#if TASK08_HOST_CHECK
@main
private struct SSEDecoderHostChecks {
    static func main() throws {
        try checkEveryUTF8SplitAndSSEBoundary()
        try checkEventByteLimit()
        print("2 SSE host checks passed")
    }
}
#else
struct SSEDecoderTests {
    @Test func testEveryUTF8SplitAndSSEBoundary() throws {
        try checkEveryUTF8SplitAndSSEBoundary()
    }

    @Test func testEventByteLimit() throws {
        try checkEventByteLimit()
    }
}
#endif
