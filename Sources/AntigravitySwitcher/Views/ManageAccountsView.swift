import SwiftUI

struct ManageAccountsView: View {
    @EnvironmentObject var appState: AppState

    @State private var showAddPanel: Bool = false
    @State private var editingAlias: String? = nil
    @State private var newAliasText: String = ""
    @State private var deletingAccount: AGAccount? = nil
    @State private var showDeleteConfirm: Bool = false

    // 手动粘贴 JSON
    @State private var manualJSON: String = ""
    @State private var manualAlias: String = ""
    @State private var selectedAddMode: Int = 0 // 0: 引导登录, 1: 捕获当前, 2: 手动粘贴

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

                Text("管理账号")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAddPanel.toggle()
                        appState.addAccountError = nil
                        appState.addAccountStatusMessage = ""
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: showAddPanel ? "list.bullet" : "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text(showAddPanel ? "列表" : "添加")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.25, green: 0.65, blue: 1.0))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 0.8)

            // 内容区
            ScrollView(.vertical, showsIndicators: false) {
                if showAddPanel {
                    // 添加账号工作台
                    addAccountSection
                } else {
                    // 账号列表管理
                    accountListSection
                }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 326)
        .alert(isPresented: $showDeleteConfirm) {
            Alert(
                title: Text("确认删除账号？"),
                message: Text("将删除账号 '\(deletingAccount?.displayName ?? "")' 的本地凭据档案。此操作不可撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    if let acct = deletingAccount {
                        _ = appState.deleteAccount(alias: acct.alias)
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - 账号列表区
    private var accountListSection: some View {
        VStack(spacing: 8) {
            ForEach(Array(appState.accounts.enumerated()), id: \.element.id) { index, acct in
                let isActive = (acct.alias == appState.activeAccountID)

                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        AccountAvatarView(indexText: acct.avatarLetter, isActive: isActive)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(acct.displayName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                Button(action: {
                                    let nextPlan: String
                                    switch acct.planLabel {
                                    case "PRO": nextPlan = "ULTRA"
                                    case "ULTRA": nextPlan = "FREE"
                                    default: nextPlan = "PRO"
                                    }
                                    appState.setAccountPlan(alias: acct.alias, plan: nextPlan)
                                }) {
                                    Text(acct.planLabel)
                                        .font(.system(size: 8.5, weight: .heavy))
                                        .foregroundColor(acct.planColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(acct.planBackgroundColor)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(acct.planColor.opacity(0.35), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("点击切换订阅级别 (PRO / ULTRA / FREE)")

                                if isActive {
                                    Text("活跃")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color(red: 0.15, green: 0.55, blue: 1.0)))
                                }
                            }

                            Text(acct.displaySubtext)
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(white: 0.55))
                                .lineLimit(1)
                        }

                        Spacer()

                        // 操作按钮
                        HStack(spacing: 8) {
                            // 改名按钮
                            Button(action: {
                                withAnimation {
                                    if editingAlias == acct.alias {
                                        editingAlias = nil
                                    } else {
                                        editingAlias = acct.alias
                                        newAliasText = acct.displayName
                                    }
                                }
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(white: 0.75))
                                    .padding(6)
                                    .background(Circle().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("重命名账号")

                            // 删除按钮 (当前活跃不可删)
                            Button(action: {
                                deletingAccount = acct
                                showDeleteConfirm = true
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(isActive ? Color.white.opacity(0.2) : Color(red: 0.95, green: 0.35, blue: 0.35))
                                    .padding(6)
                                    .background(Circle().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isActive)
                            .help(isActive ? "无法删除当前活跃账号" : "删除账号")
                        }
                    }

                    // 改名输入框折叠区
                    if editingAlias == acct.alias {
                        HStack(spacing: 6) {
                            TextField("新账号别名", text: $newAliasText)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(0.12))
                                )

                            Button("保存") {
                                if !newAliasText.isEmpty {
                                    _ = appState.renameAccount(alias: acct.alias, newAlias: newAliasText)
                                    editingAlias = nil
                                }
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                            .controlSize(.small)

                            Button("取消") {
                                editingAlias = nil
                            }
                            .buttonStyle(PlainButtonStyle())
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(isActive ? 0.08 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(isActive ? 0.2 : 0.06), lineWidth: 0.8)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - 添加账号区
    private var addAccountSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 模式选择分段器
            Picker("", selection: $selectedAddMode) {
                Text("引导登录").tag(0)
                Text("导入当前").tag(1)
                Text("手动导入").tag(2)
            }
            .pickerStyle(SegmentedPickerStyle())

            // 提示信息与状态反馈
            if let err = appState.addAccountError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 0.98, green: 0.4, blue: 0.4))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.15)))
            }

            if !appState.addAccountStatusMessage.isEmpty {
                Text(appState.addAccountStatusMessage)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.15)))
            }

            if selectedAddMode == 0 {
                // 引导登录模式
                VStack(alignment: .leading, spacing: 10) {
                    Text("💡 登录新 Google 账号")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)

                    Text("点击后将自动暂存当前账号并唤起 Antigravity。您只需在弹出的浏览器中登录新 Google 账号，完成后将自动识别并存为新账号。")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    if appState.isListeningForLogin {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("正在等待浏览器登录完成…")
                                    .font(.system(size: 12))
                                    .foregroundColor(.cyan)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)

                            Button("取消并恢复当前账号") {
                                appState.cancelGuideLogin()
                            }
                            .buttonStyle(PlainButtonStyle())
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: {
                            appState.beginGuideLogin()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text("开始登录新账号")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))

            } else if selectedAddMode == 1 {
                // 识别当前账号模式
                VStack(alignment: .leading, spacing: 10) {
                    Text("💡 导入当前已登录账号")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)

                    Text("如果您刚刚在 Antigravity 客户端手动登录了新账号，点击下方按钮可立即检测并保存为独立 Profile。")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: {
                        appState.captureCurrentLiveAccount()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("立即检测并保存当前账号")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))

            } else {
                // 手动粘贴 JSON 模式
                VStack(alignment: .leading, spacing: 10) {
                    Text("💡 粘贴 Token 凭据")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)

                    TextField("账号备注别名 (选填)", text: $manualAlias)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 11.5))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))

                    TextEditor(text: $manualJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(height: 80)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4)))

                    Button(action: {
                        appState.importTokenJSON(manualJSON, alias: manualAlias)
                    }) {
                        Text("导入凭据")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .disabled(manualJSON.isEmpty)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
