import SwiftUI

struct MainPageView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 账号卡片列表
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    if appState.accounts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("尚未添加任何 Antigravity 账号")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Button("前往管理账号添加") {
                                withAnimation {
                                    appState.currentPage = .manageAccounts
                                }
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                            .controlSize(.small)
                        }
                        .padding(.vertical, 32)
                    } else {
                        ForEach(Array(appState.accounts.enumerated()), id: \.element.id) { index, acct in
                            let isActive = (acct.alias == appState.activeAccountID)
                            let usage = appState.usageByAlias[acct.alias]
                            AccountCardView(
                                account: acct,
                                index: index + 1,
                                isActive: isActive,
                                usageState: usage
                            ) {
                                if !isActive {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        appState.switchAccount(to: acct.alias)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 380)

            // 版本更新 / 状态提示横条 (1:1 复刻截图)
            if let banner = appState.bannerText {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.1, green: 0.75, blue: 1.0))
                        .frame(width: 7, height: 7)

                    Text(banner)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()

                    if let actionTitle = appState.bannerActionTitle {
                        Button(action: {
                            if let url = URL(string: "https://github.com/lixiangwelding/antigravity-account-switcher/releases/latest") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text(actionTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // 细分割线
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.8)

            // 底部操作栏 (1:1 复刻截图：管理账号 / 设置 / 退出应用)
            HStack(spacing: 0) {
                // 管理账号
                FooterActionButton(
                    icon: "person.2",
                    title: "管理账号"
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        appState.currentPage = .manageAccounts
                    }
                }

                // 设置
                FooterActionButton(
                    icon: "gearshape",
                    title: "设置"
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        appState.currentPage = .settings
                    }
                }

                // 退出应用
                FooterActionButton(
                    icon: "power",
                    title: "退出应用"
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: 356)
    }
}

// MARK: - 底部按钮组件
struct FooterActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isHovered ? .white : Color(white: 0.82))

                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(isHovered ? .white : Color(white: 0.82))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.0))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { h in
            isHovered = h
        }
    }
}
