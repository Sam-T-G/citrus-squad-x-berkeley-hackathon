import SwiftUI

/// Owns the one shared `AppModel` and presents two faces of the app: the clean production operator
/// screen for the demo, and the diagnostics console for bench-testing the sensors and the link.
/// One model means one belt link, one decide loop, one set of services behind both tabs.
struct RootView: View {
    @State private var model = AppModel()

    var body: some View {
        TabView {
            ProductionView(model: model)
                .tabItem { Label("Operate", systemImage: "figure.walk") }
            DemoView(model: model)
                .tabItem { Label("Demo", systemImage: "eye") }
            ControlPanelView(model: model)
                .tabItem { Label("Diagnostics", systemImage: "slider.horizontal.3") }
        }
    }
}

#Preview {
    RootView()
}
