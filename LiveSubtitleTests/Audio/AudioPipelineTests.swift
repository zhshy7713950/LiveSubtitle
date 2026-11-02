import AVFoundation
import Foundation
import Synchronization
#if !TASK04_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private final class Task04Flag: Sendable {
    private let storage = Mutex(false)
    func set() { storage.withLock { $0 = true } }
    func value() -> Bool { storage.withLock { $0 } }
}

private func task04Format(
    sampleRate: Double = 16_000,
    channels: Int = 1,
    commonFormat: AVAudioCommonFormat = .pcmFormatInt16
) -> AudioFormat {
    let sample: PCMSampleFormat
    let bytesPerSample: Int
    switch commonFormat {
    case .pcmFormatInt16: sample = .signedInt16; bytesPerSample = 2
    case .pcmFormatInt32: sample = .signedInt32; bytesPerSample = 4
    case .pcmFormatFloat32: sample = .float32; bytesPerSample = 4
    case .pcmFormatFloat64: sample = .float64; bytesPerSample = 8
    default: fatalError("unsupported test format")
    }
    return AudioFormat(sampleRate: sampleRate, channels: channels,
                       pcm: PCMFormat(sampleFormat: sample, isInterleaved: true,
                                      isBigEndian: false, bytesPerFrame: bytesPerSample * channels))
}

private func task04Chunk(
    sequence: UInt64,
    captureFrame: Int64,
    frameCount: Int,
    sampleRate: Double = 16_000,
    channels: Int = 1,
    commonFormat: AVAudioCommonFormat = .pcmFormatInt16,
    discontinuity: Bool = false,
    audible: Bool = false,
    malformed: Bool = false
) -> AudioChunk {
    let format = task04Format(sampleRate: sampleRate, channels: channels, commonFormat: commonFormat)
    var data = Data(count: frameCount * format.pcm.bytesPerFrame)
    if audible && !data.isEmpty { data[0] = 1 }
    return AudioChunk(sequence: sequence,
                      capturePTS: AudioTimestamp(value: captureFrame, timescale: Int32(sampleRate)),
                      frameCount: frameCount, sampleRate: sampleRate, channels: channels,
                      format: format.pcm, ownedPCM: [malformed ? Data(count: 1) : data],
                      discontinuity: discontinuity)
}

private func task04Next(_ stream: AsyncStream<AudioSourceEvent>) async -> AudioSourceEvent? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}

private func task04Yield(
    _ continuation: AsyncStream<AudioSourceEvent>.Continuation,
    _ chunk: AudioChunk
) {
    continuation.yield(.chunk(chunk))
}

private func task04Chunk(from event: AudioSourceEvent?) throws -> AudioChunk {
    guard case .chunk(let chunk) = event else {
        throw Task04CheckFailure(message: "expected an audio chunk")
    }
    return chunk
}

func checkPCMOwnershipSurvivesCallbackReturn() throws {
    let formats: [AVAudioCommonFormat] = [.pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat32, .pcmFormatFloat64]
    for commonFormat in formats {
        for interleaved in [false, true] {
            guard let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000,
                                             channels: 2, interleaved: interleaved),
                  let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
                throw Task04CheckFailure(message: "test PCM format could not be created")
            }
            source.frameLength = 4
            var expected: [Data] = []
            for (planeIndex, plane) in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList).enumerated() {
                guard let bytes = plane.mData else {
                    throw Task04CheckFailure(message: "test PCM plane is missing")
                }
                let data = Data((0..<Int(plane.mDataByteSize)).map { UInt8(($0 + planeIndex * 31 + 1) & 0xff) })
                data.withUnsafeBytes { raw in
                    bytes.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                }
                expected.append(data)
            }
            let chunk = try AudioPCMBufferCopy.chunk(
                from: source,
                sequence: 7,
                capturePTS: AudioTimestamp(value: 11, timescale: 48_000),
                discontinuity: false
            )
            for plane in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                plane.mData?.initializeMemory(as: UInt8.self, repeating: 0xff, count: Int(plane.mDataByteSize))
            }
            source.frameLength = 0
            try task04Require(chunk.ownedPCM == expected,
                              "owned PCM changed after the callback source was reused")
            try task04Require(chunk.sequence == 7 && chunk.frameCount == 4 && chunk.channels == 2,
                              "PCM copy must retain chunk metadata")
        }
    }
}

func checkOverflowDropsOldestAndMarksDiscontinuity() async throws {
    let buffer = BoundedAudioEventBuffer()
    buffer.push(task04Chunk(sequence: 1, captureFrame: 0, frameCount: 16_000))
    buffer.push(task04Chunk(sequence: 2, captureFrame: 16_000, frameCount: 16_000))
    buffer.push(task04Chunk(sequence: 3, captureFrame: 32_000, frameCount: 16_000))
    let snapshot = buffer.snapshot()
    try task04Require(abs(snapshot.bufferedDuration - 2) < 0.000_001 && snapshot.droppedChunkCount == 1,
                      "queue must charge two seconds and drop exactly the oldest chunk")
    let first = try task04Chunk(from: await buffer.next())
    let second = try task04Chunk(from: await buffer.next())
    try task04Require(first.sequence == 2 && first.discontinuity,
                      "first retained chunk must expose the overflow discontinuity")
    try task04Require(second.sequence == 3 && !second.discontinuity,
                      "only the new timeline start is marked discontinuous")
    try task04Require(buffer.snapshot().bufferedDuration <= 2,
                      "in-flight PCM remains inside the two-second budget")
    buffer.close()
    let end = await buffer.next()
    try task04Require(end == nil, "closed audio queue must finish")
}

func checkControlEventsSurviveOverflow() async throws {
    let buffer = BoundedAudioEventBuffer()
    for index in 0..<4 {
        buffer.push(task04Chunk(sequence: UInt64(index + 1), captureFrame: Int64(index * 16_000), frameCount: 16_000))
    }
    buffer.finish(.failed(.captureFailed))
    guard case .failed(let code) = await buffer.next() else {
        throw Task04CheckFailure(message: "terminal failure was lost behind audio overflow")
    }
    let afterFailure = await buffer.next()
    try task04Require(code == .captureFailed && afterFailure == nil,
                      "failure must be delivered once and then finish the stream")
}

func checkConsumerCancellationClosesUnderlyingStream() async throws {
    let terminated = Task04Flag()
    let inputBuffer = BoundedAudioEventBuffer()
    let input = AsyncStream<AudioSourceEvent>(unfolding: {
        await inputBuffer.next()
    }, onCancel: {
        inputBuffer.close()
        terminated.set()
    })
    let pipeline = AudioPipeline()
    let output = await pipeline.process(input, target: task04Format())
    inputBuffer.push(task04Chunk(sequence: 1, captureFrame: 0, frameCount: 160))
    let consumer = Task {
        var iterator = output.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
    }
    for _ in 0..<200 {
        if inputBuffer.hasWaiter { break }
        await Task.yield()
    }
    consumer.cancel()
    for _ in 0..<200 {
        if terminated.value() { break }
        await Task.yield()
    }
    try task04Require(terminated.value(), "cancelling the output consumer must cancel the input stream; inputBufferClosed=\(inputBuffer.isClosed)")
    await pipeline.stop()
    inputBuffer.close()
}

func checkSilenceAndNoSamplesDiffer() async throws {
    let pipeline = AudioPipeline()
    let initialActivity = await pipeline.activity
    try task04Require(initialActivity == .noSamples, "no input buffers must remain noSamples")
    let (input, continuation) = AsyncStream<AudioSourceEvent>.makeStream(bufferingPolicy: .bufferingOldest(2))
    let output = await pipeline.process(input, target: task04Format())
    task04Yield(continuation, task04Chunk(sequence: 1, captureFrame: 0, frameCount: 160))
    _ = try task04Chunk(from: await task04Next(output))
    let silentActivity = await pipeline.activity
    try task04Require(silentActivity == .silence,
                      "an owned all-zero PCM buffer is silence, not missing input or a DRM diagnosis")
    await pipeline.stop()
    continuation.finish()
}

func checkFormatChangeRebuildsConverter() async throws {
    let pipeline = AudioPipeline()
    let target = task04Format(commonFormat: .pcmFormatFloat32)
    let (input, continuation) = AsyncStream<AudioSourceEvent>.makeStream(bufferingPolicy: .bufferingOldest(4))
    let output = await pipeline.process(input, target: target)

    task04Yield(continuation, task04Chunk(sequence: 1, captureFrame: 0, frameCount: 160,
                                   commonFormat: .pcmFormatFloat32))
    let first = try task04Chunk(from: await task04Next(output))
    try task04Require(!first.discontinuity && first.capturePTS.value == 0,
                      "first compatible chunk starts a continuous timeline")

    task04Yield(continuation, task04Chunk(sequence: 2, captureFrame: 0, frameCount: 480,
                                   sampleRate: 48_000, channels: 2, commonFormat: .pcmFormatFloat32))
    let changed = try task04Chunk(from: await task04Next(output))
    try task04Require(changed.sampleRate == 16_000 && changed.channels == 1 && changed.discontinuity,
                      "sample-rate/channel change must rebuild conversion and mark a discontinuity")
    try task04Require(changed.capturePTS == AudioTimestamp(value: 0, timescale: 16_000),
                      "new converter timeline starts at zero")

    task04Yield(continuation, task04Chunk(sequence: 3, captureFrame: 480, frameCount: 480,
                                   sampleRate: 48_000, channels: 2, commonFormat: .pcmFormatFloat32))
    let continued = try task04Chunk(from: await task04Next(output))
    try task04Require(!continued.discontinuity && continued.capturePTS.value == Int64(changed.frameCount),
                      "rebuilt converter must continue by actual output frame count")

    task04Yield(continuation, task04Chunk(sequence: 4, captureFrame: 960, frameCount: 480,
                                   sampleRate: 48_000, channels: 2, commonFormat: .pcmFormatFloat32,
                                   discontinuity: true))
    let routeChanged = try task04Chunk(from: await task04Next(output))
    try task04Require(routeChanged.discontinuity && routeChanged.capturePTS.value == 0,
                      "explicit route discontinuity resets conversion even when format is unchanged")

    task04Yield(continuation, task04Chunk(sequence: 5, captureFrame: 1_440, frameCount: 480,
                                   sampleRate: 48_000, channels: 2, commonFormat: .pcmFormatFloat32,
                                   malformed: true))
    guard case .failed(let code) = await task04Next(output) else {
        throw Task04CheckFailure(message: "malformed PCM must fail instead of reaching the converter")
    }
    try task04Require(code == .captureFailed, "invalid samples use the safe capture failure category")
    await pipeline.stop()
    continuation.finish()
}

func checkOversizedPCMMetadataIsRejected() async throws {
    let pipeline = AudioPipeline()
    let (input, continuation) = AsyncStream<AudioSourceEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let output = await pipeline.process(input, target: task04Format())
    let malformed = AudioChunk(
        sequence: 1,
        capturePTS: AudioTimestamp(value: 0, timescale: 16_000),
        frameCount: 1,
        sampleRate: 16_000,
        channels: Int.max,
        format: PCMFormat(sampleFormat: .signedInt16, isInterleaved: true,
                          isBigEndian: false, bytesPerFrame: 2),
        ownedPCM: [],
        discontinuity: false
    )
    task04Yield(continuation, malformed)
    guard case .failed(let code) = await task04Next(output) else {
        throw Task04CheckFailure(message: "oversized PCM metadata must be rejected")
    }
    try task04Require(code == .captureFailed, "oversized metadata returns a safe failure category")
    await pipeline.stop()
    continuation.finish()
}

@MainActor
private final class Task04CaptureDriver: ScreenCaptureDriving {
    var startError: Error?
    var stopCallCount = 0
    private var buffer: BoundedAudioEventBuffer?

    func start(buffer: BoundedAudioEventBuffer, identity: SessionIdentity) async throws {
        if let startError { throw startError }
        self.buffer = buffer
    }

    func stop() async {
        stopCallCount += 1
        buffer = nil
    }

    func emit(_ event: AudioSourceEvent) {
        switch event {
        case .chunk(let chunk): buffer?.push(chunk)
        case .ended, .failed: buffer?.finish(event)
        }
    }
}

private func task04CaptureConfig() -> CaptureConfig {
    CaptureConfig(identity: SessionIdentity(sessionID: UUID(), languageEpoch: 1,
                                            engineEpoch: 1, cloudConfigRevision: 1),
                  sourceLanguage: LanguageIdentifier(rawValue: "en"))
}

func checkCapturePickerCancellationReturnsCancellationError() async throws {
    let driver = await MainActor.run { Task04CaptureDriver() }
    await MainActor.run { driver.startError = CancellationError() }
    let source = await MainActor.run { ScreenCaptureAudioSource(driver: driver) }
    do {
        _ = try await source.start(config: task04CaptureConfig())
        throw Task04CheckFailure(message: "picker cancellation returned a fake active stream")
    } catch is CancellationError {
        // Required user-cancellation semantics.
    }
    let stopCallCount = await MainActor.run { driver.stopCallCount }
    try task04Require(stopCallCount == 1, "cancelled picker start must release the capture driver")
}

func checkCaptureSourceDeliversAudioAndStopsDriver() async throws {
    let driver = await MainActor.run { Task04CaptureDriver() }
    let source = await MainActor.run { ScreenCaptureAudioSource(driver: driver) }
    let output = try await source.start(config: task04CaptureConfig())
    await MainActor.run { driver.emit(.chunk(task04Chunk(sequence: 1, captureFrame: 0, frameCount: 160))) }
    let chunk = try task04Chunk(from: await task04Next(output))
    try task04Require(chunk.sequence == 1, "capture source must emit owned audio after a successful start")
    await MainActor.run { driver.emit(.ended) }
    guard case .ended = await task04Next(output) else {
        throw Task04CheckFailure(message: "capture source lost its terminal event")
    }
    await source.stop()
    let stopCallCount = await MainActor.run { driver.stopCallCount }
    try task04Require(stopCallCount == 1, "source stop must stop the underlying driver")
}

func runAudioPipelineChecks() async throws {
    try checkPCMOwnershipSurvivesCallbackReturn()
    try await checkOverflowDropsOldestAndMarksDiscontinuity()
    try await checkControlEventsSurviveOverflow()
    try await checkConsumerCancellationClosesUnderlyingStream()
    try await checkSilenceAndNoSamplesDiffer()
    try await checkFormatChangeRebuildsConverter()
    try await checkOversizedPCMMetadataIsRejected()
    try await checkCapturePickerCancellationReturnsCancellationError()
    try await checkCaptureSourceDeliversAudioAndStopsDriver()
}

#if !TASK04_HOST_CHECK
struct AudioPipelineTests {
    @Test func testPCMOwnershipSurvivesCallbackReturn() throws {
        try checkPCMOwnershipSurvivesCallbackReturn()
    }
    @Test func testOverflowDropsOldestAndMarksDiscontinuity() async throws {
        try await checkOverflowDropsOldestAndMarksDiscontinuity()
    }
    @Test func testControlEventsSurviveOverflow() async throws {
        try await checkControlEventsSurviveOverflow()
    }
    @Test func testConsumerCancellationClosesUnderlyingStream() async throws {
        try await checkConsumerCancellationClosesUnderlyingStream()
    }
    @Test func testSilenceAndNoSamplesDiffer() async throws {
        try await checkSilenceAndNoSamplesDiffer()
    }
    @Test func testFormatChangeRebuildsConverter() async throws {
        try await checkFormatChangeRebuildsConverter()
    }
    @Test func testOversizedPCMMetadataIsRejected() async throws {
        try await checkOversizedPCMMetadataIsRejected()
    }
    @Test func testCapturePickerCancellationReturnsCancellationError() async throws {
        try await checkCapturePickerCancellationReturnsCancellationError()
    }
    @Test func testCaptureSourceDeliversAudioAndStopsDriver() async throws {
        try await checkCaptureSourceDeliversAudioAndStopsDriver()
    }
}
#endif
