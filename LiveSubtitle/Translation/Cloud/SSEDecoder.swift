import Foundation

enum SSEDecoderError: Error, Equatable {
    case eventTooLarge
}

struct SSEDecoder {
    private var line = Data()
    private var dataLines: [Data] = []
    private var eventByteCount = 0

    mutating func append(_ chunk: Data) throws -> [Data] {
        var events: [Data] = []
        for byte in chunk {
            eventByteCount += 1
            guard eventByteCount <= RuntimePolicy.sseEventByteLimit else {
                throw SSEDecoderError.eventTooLarge
            }
            if byte == 0x0A {
                try processLine(&events)
            } else {
                line.append(byte)
            }
        }
        return events
    }

    mutating func finish() throws -> [Data] {
        line.removeAll(keepingCapacity: false)
        dataLines.removeAll(keepingCapacity: false)
        eventByteCount = 0
        return []
    }

    private mutating func processLine(_ events: inout [Data]) throws {
        if line.last == 0x0D { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            eventByteCount = 0
            guard !dataLines.isEmpty else { return }
            var event = Data()
            for (index, dataLine) in dataLines.enumerated() {
                if index > 0 { event.append(0x0A) }
                event.append(dataLine)
            }
            dataLines.removeAll(keepingCapacity: true)
            events.append(event)
            return
        }
        guard line.first != 0x3A else { return }
        let field: Data
        var value = Data()
        if let colon = line.firstIndex(of: 0x3A) {
            field = line[..<colon]
            let valueStart = line.index(after: colon)
            if valueStart < line.endIndex {
                value = line[valueStart...]
                if value.first == 0x20 { value.removeFirst() }
            }
        } else {
            field = line
        }
        if String(decoding: field, as: UTF8.self) == "data" {
            dataLines.append(value)
        }
    }
}
