import AVFAudio

@MainActor
protocol PlaybackAudioSessionManaging: AnyObject {
    func activate() throws
    func deactivate()
}

/// Configures PiP playback while leaving Chrome audio at its normal volume.
/// No player, microphone input, or silent audio is created.
@MainActor
final class PlaybackAudioSession: PlaybackAudioSessionManaging {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            throw FailureCode.unavailable
        }
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
