#if TASK14_PIP_DEVICE
import AVKit
import Testing
import UIKit
@testable import LiveSubtitle

/// Opt-in hardware probe with optional capture; no microphone, Speech, translation, or network.
@MainActor
struct PiPDeviceProbeTests {
    @Test func realPiPStartsOnDevice() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let view = UIViewController()
        window.rootViewController = view
        window.makeKeyAndVisible()
        let renderer = SubtitleRenderer()
        renderer.displayLayer.frame = CGRect(x: 20, y: 100, width: 320, height: 180)
        view.view.layer.addSublayer(renderer.displayLayer)
        let playback = PlaybackAudioSession()
        let pip = PiPCoordinator(renderer: renderer)
        let id = UUID()
        defer { playback.deactivate(); window.isHidden = true; previous?.makeKeyAndVisible() }
        try playback.activate()
        #if TASK14_CAPTURE_DEVICE
        let capture = ScreenCaptureAudioSource()
        let identity = SessionIdentity(sessionID: id, languageEpoch: 0, engineEpoch: 0, cloudConfigRevision: 0)
        let audio = try await capture.start(config: CaptureConfig(identity: identity, sourceLanguage: .init(rawValue: "en-US")))
        let drain = Task { for await _ in audio {} }
        print("TASK14_METRIC probe_capture_started=1 app_state=\(UIApplication.shared.applicationState.rawValue)")
        #endif
        #if TASK14_CAPTURE_DEVICE
        // The system sharing panel can remain on screen after capture starts.
        for _ in 0..<300 {
            if UIApplication.shared.applicationState == .active { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("TASK14_METRIC probe_before_pip_app_state=\(UIApplication.shared.applicationState.rawValue)")
        #endif
        let stream: AsyncStream<PiPEvent>
        do { stream = try await pip.start(sessionID: id) }
        catch {
            #if TASK14_CAPTURE_DEVICE
            await capture.stop()
            drain.cancel()
            await drain.value
            #endif
            await pip.stop(sessionID: id)
            throw error
        }
        var started = false
        var failed = false
        let consumer = Task { @MainActor in
            for await event in stream {
                switch event {
                case .started: started = true
                case .failed: failed = true
                default: break
                }
            }
        }
        // Real hardware observation window; deterministic readiness/deadline tests remain separate.
        for _ in 0..<50 {
            if started || failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await pip.stop(sessionID: id)
        #if TASK14_CAPTURE_DEVICE
        await capture.stop()
        drain.cancel()
        await drain.value
        #endif
        consumer.cancel()
        await consumer.value
        #expect(started)
        #expect(!failed)
    }
}
#endif
