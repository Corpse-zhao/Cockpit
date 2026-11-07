import SwiftUI

@main
struct E400CockpitApp: App {
    @StateObject private var central = CockpitCentral()
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem { Label("仪表", systemImage: "speedometer") }
                ConsoleView()
                    .tabItem { Label("数据台", systemImage: "terminal") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .environmentObject(central)
            .preferredColorScheme(.dark)
            .tint(ThemeStore.preset(for: themeID).accent)
        }
    }
}
