import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var launchAtLogin: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.currentPage = .main
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("返回")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Text("设置")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.8)

            // 设置表单
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    // 分组 1: 常规选项
                    VStack(alignment: .leading, spacing: 10) {
                        Text("常规设置")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.55))

                        VStack(spacing: 8) {
                            // 开机自启
                            Toggle(isOn: $launchAtLogin) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("开机自动启动")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.white)
                                }
                            }
                            .toggleStyle(SwitchToggleStyle())
                            .onChange(of: launchAtLogin) { oldValue, newValue in
                                toggleLaunchAtLogin(newValue)
                            }

                            Divider().background(Color.white.opacity(0.08))

                            // 切换自动重启 Antigravity
                            Toggle(isOn: Binding(
                                get: { appState.config.restartAntigravity },
                                set: { v in
                                    var cfg = appState.config
                                    cfg.restartAntigravity = v
                                    appState.updateConfig(cfg)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("切换账号后自动重启 Antigravity")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.white)
                                }
                            }
                            .toggleStyle(SwitchToggleStyle())

                            Divider().background(Color.white.opacity(0.08))

                            // 状态栏显示配额
                            Toggle(isOn: Binding(
                                get: { appState.config.showMenuBarPercentage },
                                set: { v in
                                    var cfg = appState.config
                                    cfg.showMenuBarPercentage = v
                                    appState.updateConfig(cfg)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("状态栏显示 5h 剩余百分比")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.white)
                                }
                            }
                            .toggleStyle(SwitchToggleStyle())
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }

                    // 分组 2: 自动刷新频率
                    VStack(alignment: .leading, spacing: 10) {
                        Text("用量刷新与告警")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.55))

                        VStack(spacing: 10) {
                            HStack {
                                Text("自动刷新周期")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.white)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { appState.config.refreshIntervalMinutes },
                                    set: { v in
                                        var cfg = appState.config
                                        cfg.refreshIntervalMinutes = v
                                        appState.updateConfig(cfg)
                                    }
                                )) {
                                    Text("5 分钟").tag(5)
                                    Text("15 分钟").tag(15)
                                    Text("30 分钟").tag(30)
                                    Text("1 小时").tag(60)
                                    Text("手动刷新").tag(0)
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(width: 100)
                            }

                            Divider().background(Color.white.opacity(0.08))

                            HStack {
                                Text("5小时告警阈值")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.white)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { appState.config.alert5hThreshold },
                                    set: { v in
                                        var cfg = appState.config
                                        cfg.alert5hThreshold = v
                                        appState.updateConfig(cfg)
                                    }
                                )) {
                                    Text("低于 10%").tag(10)
                                    Text("低于 20%").tag(20)
                                    Text("低于 30%").tag(30)
                                    Text("低于 50%").tag(50)
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(width: 100)
                            }

                            Divider().background(Color.white.opacity(0.08))

                            HStack {
                                Text("7天告警阈值")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.white)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { appState.config.alertWeekThreshold },
                                    set: { v in
                                        var cfg = appState.config
                                        cfg.alertWeekThreshold = v
                                        appState.updateConfig(cfg)
                                    }
                                )) {
                                    Text("低于 5%").tag(5)
                                    Text("低于 10%").tag(10)
                                    Text("低于 20%").tag(20)
                                    Text("低于 30%").tag(30)
                                }
                                .pickerStyle(MenuPickerStyle())
                                .frame(width: 100)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }

                    // 分组 3: 快捷操作与关于
                    VStack(alignment: .leading, spacing: 10) {
                        Text("维护与存储")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.55))

                        VStack(spacing: 8) {
                            Button(action: {
                                appState.refreshAllUsage()
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text("立即刷新全部账号配额")
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .padding(8)
                            }
                            .buttonStyle(PlainButtonStyle())

                            Divider().background(Color.white.opacity(0.08))

                            Button(action: {
                                let path = ("~/.antigravity-switcher" as NSString).expandingTildeInPath
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }) {
                                HStack {
                                    Image(systemName: "folder")
                                    Text("在访达中打开配置目录")
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .padding(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }

                    // 版本说明
                    Text("Antigravity Switcher v1.1.0\n专为 Google Antigravity 设计的多账号切换与配额监控")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(white: 0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 304)
        .onAppear {
            if #available(macOS 13.0, *) {
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
            }
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("LaunchAtLogin error: \(error)")
            }
        }
    }
}
