import Foundation

enum SSEDecoderError: Error, Equatable {
    case eventTooLarge
}

struct SSEDecoder {
    private var line = Data()
    private var dataLines: [Data] = []
    private var eventByteCount = 0
    private var afterCR = false
    private var resetAfterCR = false

    mutating func append(_ chunk: Data) throws -> [Data] {
        var events: [Data] = []
        for byte in chunk {
            if afterCR {
                afterCR = false
                if byte == 0x0A {
                    eventByteCount += 1
                    guard eventByteCount <= RuntimePolicy.sseEventByteLimit else {
                        throw SSEDecoderError.eventTooLarge
                    }
                    if resetAfterCR { eventByteCount = 0 }
                    resetAfterCR = false
                    continue
                }
                if resetAfterCR { eventByteCount = 0 }
                resetAfterCR = false
            }
            eventByteCount += 1
            guard eventByteCount <= RuntimePolicy.sseEventByteLimit else {
                throw SSEDecoderError.eventTooLarge
            }
            switch byte {
            case 0x0D:
                resetAfterCR = try processLine(&events)
                afterCR = true
            case 0x0A:
                if try processLine(&events) { eventByteCount = 0 }
            default:
                line.append(byte)
            }
        }
        return events
    }

    mutating func finish() throws -> [Data] {
        line.removeAll(keepingCapacity: false)
        dataLines.removeAll(keepingCapacity: false)
        eventByteCount = 0
        afterCR = false
        resetAfterCR = false
        return []
    }

    private mutating func processLine(_ events: inout [Data]) throws -> Bool {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !dataLines.isEmpty else { return true }
            var event = Data()
            for (index, dataLine) in dataLines.enumerated() {
                if index > 0 { event.append(0x0A) }
                event.append(dataLine)
            }
            dataLines.removeAll(keepingCapacity: true)
            events.append(event)
            return true
        }
        guard line.first != 0x3A else { return false }
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
        return false
    }
}
