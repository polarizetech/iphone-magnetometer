import SwiftUI
import UIKit

@main
struct BiomimeticRadarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// Exists for one reason: the background upload session hands its events back through here when
/// the app was suspended or relaunched while chunks were in flight. Touching `StreamUploader.shared`
/// here also guarantees the session is recreated with the same identifier before iOS delivers them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == StreamUploader.sessionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in StreamUploader.shared.handleBackgroundEvents(completion: completionHandler) }
    }
}
