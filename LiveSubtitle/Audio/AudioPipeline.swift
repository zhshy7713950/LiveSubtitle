import AVFoundation
import Foundation
import Synchronization

enum AudioActivity: Sendable, Equatable {
    case noSamples
    case silence
    case audible
}

struct AudioBufferSnapshot: Sendable {
    let bufferedDuration: Double
    let droppedChunkCount: Int
}

/// A synchronous producer handoff with a duration budget and a separate terminal slot.
final class BoundedAudioEventBuffer: Sendable {
    private typealias Waiter = CheckedContinuation<AudioSourceEvent?, Never>

    private enum Poll {
        case event(AudioSourceEvent?)
        case empty
    }

    private struct State {
        var chunks: [AudioChunk] = []
        var bufferedDuration = 0.0
        var inFlightDuration = 0.0
        var droppedChunkCount = 0
        var pendingDiscontinuity = false
        var terminal: AudioSourceEvent?
        var closed = false
        var waiter: Waiter?
    }

    private let state = Mutex(State())
    private let limit = Double(RuntimePolicy.audioBufferDuration.components.seconds)
        + Double(RuntimePolicy.audioBufferDuration.components.attoseconds) / 1e18

    func push(_ chunk: AudioChunk) {
        var delivery: (Waiter, AudioSourceEvent?)?
        state.withLock { value in
            guard !value.closed else { return }
            let duration = Double(chunk.frameCount) / chunk.sampleRate
            guard duration.isFinite, duration > 0, duration <= limit else {
                value.terminal = .failed(.captureFailed)
                value.closed = true
                value.chunks.removeAll()
                value.bufferedDuration = 0
                value.inFlightDuration = 0
                if let waiter = value.waiter, let terminal = value.terminal {
                    value.waiter = nil
                    value.terminal = nil
                    delivery = (waiter, terminal)
                }
                return
            }

            var dropped = false
            while value.bufferedDuration + duration > limit, !value.chunks.isEmpty {
                let removed = value.chunks.removeFirst()
                value.bufferedDuration -= Self.duration(of: removed)
                value.droppedChunkCount += 1
                dropped = true
            }
            guard value.bufferedDuration + duration <= limit else {
                // The only older audio is already with the consumer and cannot be reclaimed.
                value.droppedChunkCount += 1
                value.pendingDiscontinuity = true
                return
            }

            var incoming = chunk
            if dropped || value.pendingDiscontinuity {
                if value.chunks.isEmpty {
                    incoming = incoming.markingDiscontinuity()
                } else {
                    value.chunks[0] = value.chunks[0].markingDiscontinuity()
                }
                value.pendingDiscontinuity = false
            }
            value.chunks.append(incoming)
            value.bufferedDuration += duration
            if let waiter = value.waiter, case .event(let event) = Self.poll(&value) {
                value.waiter = nil
                delivery = (waiter, event)
            }
        }
        if let (waiter, event) = delivery { waiter.resume(returning: event) }
    }

    func finish(_ event: AudioSourceEvent) {
        var delivery: (Waiter, AudioSourceEvent?)?
        state.withLock { value in
            guard !value.closed else { return }
            value.closed = true
            value.terminal = event
            if case .failed = event {
                value.chunks.removeAll()
                value.bufferedDuration = 0
                value.inFlightDuration = 0
            }
            if let waiter = value.waiter, case .event(let event) = Self.poll(&value) {
                value.waiter = nil
                delivery = (waiter, event)
            }
        }
        if let (waiter, event) = delivery { waiter.resume(returning: event) }
    }

    func close() {
        var waiter: Waiter?
        state.withLock { value in
            guard !value.closed || value.terminal != nil else { return }
            value.closed = true
            value.terminal = nil
            value.chunks.removeAll()
            value.bufferedDuration = 0
            value.inFlightDuration = 0
            waiter = value.waiter
            value.waiter = nil
        }
        waiter?.resume(returning: nil)
    }

    func next() async -> AudioSourceEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediate: AudioSourceEvent??
                state.withLock { value in
                    value.bufferedDuration = max(0, value.bufferedDuration - value.inFlightDuration)
                    value.inFlightDuration = 0
                    switch Self.poll(&value) {
                    case .event(let event):
                        immediate = event
                    case .empty:
                        if value.waiter == nil {
                            value.waiter = continuation
                        } else {
                            immediate = .some(nil)
                        }
                    }
                }
                if let event = immediate { continuation.resume(returning: event) }
            }
        } onCancel: {
            close()
        }
    }

    func snapshot() -> AudioBufferSnapshot {
        state.withLock {
            AudioBufferSnapshot(bufferedDuration: $0.bufferedDuration, droppedChunkCount: $0.droppedChunkCount)
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }
    var hasWaiter: Bool { state.withLock { $0.waiter != nil } }

    private static func poll(_ value: inout State) -> Poll {
        if !value.chunks.isEmpty {
            let chunk = value.chunks.removeFirst()
            value.inFlightDuration = duration(of: chunk)
            return .event(.chunk(chunk))
        }
        if let terminal = value.terminal {
            value.terminal = nil
            value.bufferedDuration = 0
            value.inFlightDuration = 0
            return .event(terminal)
        }
        if value.closed { return .event(nil) }
        return .empty
    }

    private static func duration(of chunk: AudioChunk) -> Double {
        Double(chunk.frameCount) / chunk.sampleRate
    }
}

private extension AudioChunk {
    func markingDiscontinuity() -> AudioChunk {
        guard !discontinuity else { return self }
        return AudioChunk(sequence: sequence, capturePTS: capturePTS, frameCount: frameCount,
                          sampleRate: sampleRate, channels: channels, format: format,
                          ownedPCM: ownedPCM, discontinuity: true)
    }
}

actor AudioPipeline: AudioProcessing {
    private var generation: UInt64 = 0
    private var consumerTask: Task<Void, Never>?
    private var outputBuffer: BoundedAudioEventBuffer?
    private var target: AudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AudioFormatKey?
    private var mapper = AudioTimeMapper()
    private var previousSequence: UInt64?
    private var previousSourceFormat: AudioFormatKey?
    private var lastSourceFrameCount = 0
    private(set) var activity: AudioActivity = .noSamples

    func process(_ input: AsyncStream<AudioSourceEvent>, target: AudioFormat) async -> AsyncStream<AudioSourceEvent> {
        stop()
        generation &+= 1
        let token = generation
        let buffer = BoundedAudioEventBuffer()
        outputBuffer = buffer
        do {
            _ = try AudioPCMConversion.audioFormat(for: target)
            self.target = target
        } catch {
            buffer.finish(.failed(.speechFailed))
        }

        let output = AsyncStream<AudioSourceEvent>(unfolding: {
            await buffer.next()
        }, onCancel: {
            buffer.close()
            Task { await self.stopIfCurrent(token, buffer: buffer) }
        })
        guard self.target != nil else { return output }

        consumerTask = Task {
            for await event in input {
                if Task.isCancelled { return }
                let keepGoing = self.ingest(event, into: buffer, generation: token)
                if !keepGoing { return }
            }
            if !Task.isCancelled {
                self.inputFinished(into: buffer, generation: token)
            }
        }
        return output
    }

    func stop() {
        generation &+= 1
        consumerTask?.cancel()
        consumerTask = nil
        outputBuffer?.close()
        outputBuffer = nil
        target = nil
        converter = nil
        converterSource = nil
        mapper = AudioTimeMapper()
        previousSequence = nil
        previousSourceFormat = nil
        lastSourceFrameCount = 0
        activity = .noSamples
    }

    private func stopIfCurrent(_ token: UInt64, buffer: BoundedAudioEventBuffer) {
        guard token == generation, outputBuffer === buffer else { return }
        stop()
    }

    private func inputFinished(into buffer: BoundedAudioEventBuffer, generation token: UInt64) {
        guard token == generation, !buffer.isClosed else { return }
        do {
            try drainConverter(into: buffer)
            buffer.finish(.ended)
        } catch let error as FailureCode {
            buffer.finish(.failed(error))
        } catch {
            buffer.finish(.failed(.captureFailed))
        }
        converter = nil
        converterSource = nil
    }

    private func ingest(_ event: AudioSourceEvent, into buffer: BoundedAudioEventBuffer, generation token: UInt64) -> Bool {
        guard token == generation else { return false }
        switch event {
        case .ended:
            inputFinished(into: buffer, generation: token)
            return false
        case .failed:
            buffer.finish(event)
            converter = nil
            converterSource = nil
            return false
        case .chunk(let chunk):
            do {
                guard let converted = try convert(chunk), target != nil else { return true }
                activity = converted.ownedPCM.allSatisfy({ data in data.allSatisfy { $0 == 0 } })
                    ? .silence : .audible
                buffer.push(converted)
                return !buffer.isClosed
            } catch let error as FailureCode {
                buffer.finish(.failed(error))
                return false
            } catch {
                buffer.finish(.failed(.captureFailed))
                return false
            }
        }
    }

    private func drainConverter(into buffer: BoundedAudioEventBuffer) throws {
        guard let converter, let target else { return }
        let capacity = ceil(Double(lastSourceFrameCount) * target.sampleRate / converter.inputFormat.sampleRate) + 64
        guard capacity > 0, capacity <= Double(UInt32.max) else { throw FailureCode.captureFailed }
        while !buffer.isClosed {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(capacity)
            ) else { throw FailureCode.captureFailed }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            guard status != .error, conversionError == nil else { throw FailureCode.captureFailed }
            if output.frameLength == 0 { break }
            let timestamp = try mapper.mapDrainedOutput(
                frameCount: Int(output.frameLength),
                sampleRate: target.sampleRate
            )
            let baseSequence = previousSequence ?? 0
            let (sequence, overflow) = baseSequence.addingReportingOverflow(1)
            guard !overflow else { throw FailureCode.captureFailed }
            let chunk = try AudioPCMBufferCopy.chunk(
                from: output,
                sequence: sequence,
                capturePTS: timestamp,
                discontinuity: false
            )
            previousSequence = sequence
            activity = chunk.ownedPCM.allSatisfy({ data in data.allSatisfy { $0 == 0 } })
                ? .silence : .audible
            buffer.push(chunk)
        }
    }

    private func convert(_ chunk: AudioChunk) throws -> AudioChunk? {
        guard let target else { return nil }
        try AudioPCMConversion.validate(chunk)
        let sourceKey = AudioFormatKey(chunk)
        let targetKey = AudioFormatKey(target)
        let formatChanged = previousSourceFormat.map { $0 != sourceKey } ?? false
        let sequenceChanged = previousSequence.map { chunk.sequence != $0 &+ 1 } ?? false
        let timeChanged = try mapper.requiresDiscontinuity(
            capturePTS: chunk.capturePTS,
            sourceFrameCount: chunk.frameCount,
            sourceSampleRate: chunk.sampleRate
        )
        let reset = chunk.discontinuity || formatChanged || sequenceChanged || timeChanged
        if reset || converterSource != sourceKey { converter = nil }

        let inputBuffer = try AudioPCMConversion.pcmBuffer(from: chunk)
        let outputBuffer: AVAudioPCMBuffer
        if sourceKey == targetKey {
            outputBuffer = inputBuffer
        } else {
            if converter == nil {
                let inputFormat = try AudioPCMConversion.audioFormat(for: chunk)
                let outputFormat = try AudioPCMConversion.audioFormat(for: target)
                guard let created = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                    throw FailureCode.captureFailed
                }
                converter = created
                converterSource = sourceKey
            }
            guard let converter else { throw FailureCode.captureFailed }
            let capacity = ceil(Double(chunk.frameCount) * target.sampleRate / chunk.sampleRate) + 64
            guard capacity > 0, capacity <= Double(UInt32.max) else { throw FailureCode.captureFailed }
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(capacity)
            ) else { throw FailureCode.captureFailed }
            var provided = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return inputBuffer
            }
            guard status != .error, conversionError == nil else { throw FailureCode.captureFailed }
            outputBuffer = converted
        }

        let timestamp = try mapper.map(
            capturePTS: chunk.capturePTS,
            sourceFrameCount: chunk.frameCount,
            sourceSampleRate: chunk.sampleRate,
            outputFrameCount: Int(outputBuffer.frameLength),
            outputSampleRate: target.sampleRate,
            reset: reset
        )
        previousSequence = chunk.sequence
        previousSourceFormat = sourceKey
        lastSourceFrameCount = chunk.frameCount
        guard outputBuffer.frameLength > 0 else { return nil }
        return try AudioPCMBufferCopy.chunk(from: outputBuffer, sequence: chunk.sequence,
                                            capturePTS: timestamp, discontinuity: reset)
    }
}

private enum AudioSampleKind: Equatable {
    case float32, float64, signedInt16, signedInt32
}

private struct AudioFormatKey: Equatable {
    let sampleRate: Double
    let channels: Int
    let sample: AudioSampleKind
    let isInterleaved: Bool
    let isBigEndian: Bool
    let bytesPerFrame: Int

    init(_ format: AudioFormat) {
        sampleRate = format.sampleRate
        channels = format.channels
        isInterleaved = format.pcm.isInterleaved
        isBigEndian = format.pcm.isBigEndian
        bytesPerFrame = format.pcm.bytesPerFrame
        switch format.pcm.sampleFormat {
        case .float32: sample = .float32
        case .float64: sample = .float64
        case .signedInt16: sample = .signedInt16
        case .signedInt32: sample = .signedInt32
        }
    }

    init(_ chunk: AudioChunk) {
        self.init(AudioFormat(sampleRate: chunk.sampleRate, channels: chunk.channels, pcm: chunk.format))
    }
}

private enum AudioPCMConversion {
    static func validate(_ chunk: AudioChunk) throws {
        let expectedBytesPerFrame = try expectedBytesPerFrame(for: chunk)
        let expectedPlanes = chunk.format.isInterleaved ? 1 : chunk.channels
        guard chunk.frameCount > 0,
              chunk.sampleRate.isFinite, chunk.sampleRate > 0,
              chunk.sampleRate <= Double(Int32.max), chunk.sampleRate.rounded() == chunk.sampleRate,
              chunk.ownedPCM.count == expectedPlanes,
              chunk.frameCount <= Int(UInt32.max) else {
            throw FailureCode.captureFailed
        }
        let planeBytes = chunk.frameCount.multipliedReportingOverflow(by: expectedBytesPerFrame)
        guard !planeBytes.overflow else { throw FailureCode.captureFailed }
        for plane in chunk.ownedPCM where plane.count != planeBytes.partialValue {
            throw FailureCode.captureFailed
        }
    }

    static func audioFormat(for chunk: AudioChunk) throws -> AVAudioFormat {
        try audioFormat(for: AudioFormat(sampleRate: chunk.sampleRate, channels: chunk.channels, pcm: chunk.format))
    }

    private static func expectedBytesPerFrame(for chunk: AudioChunk) throws -> Int {
        try expectedBytesPerFrame(for: AudioFormat(sampleRate: chunk.sampleRate, channels: chunk.channels, pcm: chunk.format))
    }

    private static func expectedBytesPerFrame(for format: AudioFormat) throws -> Int {
        let bytesPerSample: Int
        switch format.pcm.sampleFormat {
        case .float32, .signedInt32: bytesPerSample = 4
        case .float64: bytesPerSample = 8
        case .signedInt16: bytesPerSample = 2
        }
        let result = format.pcm.isInterleaved
            ? bytesPerSample.multipliedReportingOverflow(by: format.channels)
            : (partialValue: bytesPerSample, overflow: false)
        guard format.channels > 0, format.channels <= Int(UInt32.max), !result.overflow,
              result.partialValue > 0, result.partialValue <= Int(UInt32.max),
              format.pcm.bytesPerFrame == result.partialValue else {
            throw FailureCode.captureFailed
        }
        return result.partialValue
    }

    static func audioFormat(for format: AudioFormat) throws -> AVAudioFormat {
        let bytesPerFrame = try expectedBytesPerFrame(for: format)
        let bytesPerSample: Int
        var flags = kAudioFormatFlagIsPacked
        switch format.pcm.sampleFormat {
        case .float32:
            bytesPerSample = 4
            flags |= kAudioFormatFlagIsFloat
        case .float64:
            bytesPerSample = 8
            flags |= kAudioFormatFlagIsFloat
        case .signedInt16:
            bytesPerSample = 2
            flags |= kAudioFormatFlagIsSignedInteger
        case .signedInt32:
            bytesPerSample = 4
            flags |= kAudioFormatFlagIsSignedInteger
        }
        if format.pcm.isBigEndian { flags |= kAudioFormatFlagIsBigEndian }
        if !format.pcm.isInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.sampleRate <= Double(Int32.max), format.sampleRate.rounded() == format.sampleRate else {
            throw FailureCode.captureFailed
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(format.channels),
            mBitsPerChannel: UInt32(bytesPerSample * 8),
            mReserved: 0
        )
        guard let result = AVAudioFormat(streamDescription: &description) else {
            throw FailureCode.captureFailed
        }
        return result
    }

    static func pcmBuffer(from chunk: AudioChunk) throws -> AVAudioPCMBuffer {
        try validate(chunk)
        let format = try audioFormat(for: chunk)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk.frameCount)
        ) else { throw FailureCode.captureFailed }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        let planes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard planes.count == chunk.ownedPCM.count else { throw FailureCode.captureFailed }
        for (plane, data) in zip(planes, chunk.ownedPCM) {
            guard let destination = plane.mData, plane.mDataByteSize == data.count else {
                throw FailureCode.captureFailed
            }
            data.withUnsafeBytes { raw in
                destination.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
        return buffer
    }
}
