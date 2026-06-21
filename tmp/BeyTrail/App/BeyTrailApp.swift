import SwiftUI

@main
struct BeyTrailApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}
