import SwiftUI

struct PopoverRootView: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        ZStack {
            // 背景磨砂暗色毛玻璃
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .edgesIgnoringSafeArea(.all)

            // 页面内容切换
            Group {
                switch appState.currentPage {
                case .main:
                    MainPageView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                case .manageAccounts:
                    ManageAccountsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                case .settings:
                    SettingsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .environmentObject(appState)
        }
        .frame(width: 356)
        .preferredColorScheme(.dark)
    }
}
