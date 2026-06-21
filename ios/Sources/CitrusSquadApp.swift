import SwiftUI

@main
struct CitrusSquadApp: App {
    init() {
        // If a Maps key was entered on a previous launch, hand it to the SDK before any map view is
        // built. A key entered fresh this session is provided from AppModel the moment it is set.
        let storedKey = UserDefaults.standard.string(forKey: "citrussquad.gmapsKey") ?? ""
        MapsBootstrap.provideKeyIfNeeded(storedKey)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
