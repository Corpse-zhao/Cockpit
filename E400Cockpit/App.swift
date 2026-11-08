import SwiftUI

@main
struct E400CockpitApp: App {
    @StateObject private var central = CockpitCentral()
    /// 电池是独立的一条 BLE 链路，和控制器互不影响
    @StateObject private var bms = BmsCentral()
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue
    @AppStorage("tutorial_seen") private var tutorialSeen = false
    @State private var showTutorial = false

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
            .environmentObject(bms)
            .preferredColorScheme(.dark)
            .tint(ThemeStore.preset(for: themeID).accent)
            // 首次启动弹一次使用教程，看完（或关了 App）就不再打扰
            .fullScreenCover(isPresented: $showTutorial) {
                TutorialView()
            }
            .onAppear {
                if !tutorialSeen { showTutorial = true }
            }
        }
    }
}
