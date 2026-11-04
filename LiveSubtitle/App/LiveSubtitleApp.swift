import SwiftUI

@main
struct LiveSubtitleApp: App {
    @StateObject private var composition = AppComposition()

    var body: some Scene {
        WindowGroup { AppRootView(composition: composition) }
    }
}
