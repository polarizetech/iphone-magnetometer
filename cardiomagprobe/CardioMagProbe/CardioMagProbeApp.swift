import SwiftUI

@main
struct CardioMagProbeApp: App {
    @StateObject private var model = ExperimentViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
