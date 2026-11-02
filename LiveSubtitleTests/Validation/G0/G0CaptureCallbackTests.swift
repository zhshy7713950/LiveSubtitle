#if DEBUG && !targetEnvironment(simulator)
import Testing
import Foundation
@testable import LiveSubtitle

struct G0CaptureCallbackTests {
    @MainActor @Test
    func pickerFailureCanArriveOffMainActor() async {
        let identity = SessionIdentity(sessionID: UUID(), languageEpoch: 0, engineEpoch: 0, cloudConfigRevision: 0)
        let inbox = G0AudioInbox()
        inbox.activate(identity)
        await withCheckedContinuation { continuation in
            Task.detached {
                // Construct and invoke the actual SDK observer off MainActor.
                // Only its value event crosses back to the UI executor.
                let observer = G0CaptureCore(inbox: inbox, identity: identity)
                observer.setHandler { event in
                    Task { @MainActor in
                        if case .failed = event { continuation.resume() }
                        else { Issue.record("Unexpected capture event"); continuation.resume() }
                    }
                }
                observer.contentSharingPickerStartDidFailWithError(FailureCode.captureFailed)
            }
        }
    }
}
#endif
