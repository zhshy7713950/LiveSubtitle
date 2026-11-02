import SwiftUI

@main
struct LiveSubtitleApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && !targetEnvironment(simulator)
            // TASK-02 temporary G0 entry; remove during TASK-13.
            G0ProbeView()
            #else
            ScaffoldView()
            #endif
        }
    }
}
