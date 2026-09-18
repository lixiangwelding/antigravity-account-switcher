import AppKit
import SwiftUI
import Combine
import UserNotifications

enum AppPage: Hashable {
    case main
    case manageAccounts
    case settings
}

enum AddAccountMode: Hashable {
    case guideLogin     // 引导打开 Antigravity 登录
    case captureCurrent // 检测并捕获当前
    case manualJSON     // 手动粘贴 JSON
}

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var accounts: [AGAccount] = []
    @Published var activeAccountID: String = ""
    @Published var usageByAlias: [String: FetchState] = [:]
    @Published var config: AppConfig = AppConfig.load()
    @Published var currentPage: AppPage = .main

    // 添加账号流程状态
    @Published var isAddAccountSheetPresented: Bool = false
    @Published var addAccountMode: AddAccountMode = .guideLogin
    @Published var isListeningForLogin: Bool = false
    @Published var addAccountStatusMessage: String = ""
    @Published var addAccountError: String? = nil

    // Banner
    @Published var bannerText: String? = nil
    @Published var bannerActionTitle: String? = nil

    private var loginPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let auth = AntigravityAuthManager.shared
    private let quota = RateLimitClient.shared

    init() {
        self.config = AppConfig.load()
        reloadAccounts()

        quota.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.usageByAlias = self?.quota.usageByAlias ?? [:]
            }
        }
        checkForUpdates()
    }

    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/lixiangwelding/antigravity-account-switcher/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }
            let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
            let current = "1.2.1"
            if cleanTag.compare(current, options: .numeric) == .orderedDescending {
                DispatchQueue.main.async {
                    self?.bannerText = "发现新版本 \(tagName)"
                    self?.bannerActionTitle = "更新..."
                }
            }
        }.resume()
    }

    func reloadAccounts() {
        let list = auth.listAccounts()
        self.accounts = list
        self.activeAccountID = auth.currentAlias()
        self.usageByAlias = quota.usageByAlias
    }

    var activeAccount: AGAccount? {
        accounts.first { $0.alias == activeAccountID }
    }

    var otherAccounts: [AGAccount] {
        accounts.filter { $0.alias != activeAccountID }
    }

    // MARK: - Switching

    func switchAccount(to alias: String) {
        guard alias != activeAccountID else { return }
        let ok = auth.switchTo(alias: alias, restartApp: config.restartAntigravity)
        if ok {
            activeAccountID = alias
            reloadAccounts()
            // 稍后异步刷新配额
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if let acct = self.activeAccount {
                    self.quota.fetchForAccount(acct)
                }
            }
            postNotification(title: "Antigravity 账号已切换", body: "当前账号：\(activeAccount?.displayName ?? alias)")
        } else {
            postNotification(title: "切换失败", body: "无法切到账号 \(alias)")
        }
    }

    // MARK: - Delete & Rename

    func deleteAccount(alias: String) -> Bool {
        guard alias != activeAccountID else { return false }
        let ok = auth.deleteAccount(alias: alias)
        if ok {
            quota.usageByAlias.removeValue(forKey: alias)
            reloadAccounts()
        }
        return ok
    }

    func renameAccount(alias: String, newAlias: String) -> String? {
        let result = auth.renameAccount(alias: alias, to: newAlias)
        if let new = result {
            if let oldUsage = quota.usageByAlias[alias] {
                quota.usageByAlias[new] = oldUsage
                quota.usageByAlias.removeValue(forKey: alias)
            }
            reloadAccounts()
        }
        return result
    }

    func setAccountPlan(alias: String, plan: String) {
        auth.writePlan(alias: alias, plan: plan)
        reloadAccounts()
    }

    // MARK: - Usage Refresh

    func refreshAllUsage() {
        quota.fetchAll(accounts)
    }

    // MARK: - Add Account Flow (核心添加账号逻辑)

    /// 方式一：直接捕获当前已登录的账号
    func captureCurrentLiveAccount(customAlias: String? = nil) {
        let res = auth.captureCurrentLiveAsNewAccount(alias: customAlias)
        if res.success {
            addAccountStatusMessage = "成功添加账号！"
            addAccountError = nil
            reloadAccounts()
            if let newAcct = res.account {
                quota.fetchForAccount(newAcct)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.isAddAccountSheetPresented = false
            }
        } else {
            addAccountError = res.message
        }
    }

    /// 方式二：引导启动 Antigravity 登录新账号并自动捕获
    func beginGuideLogin() {
        isListeningForLogin = true
        addAccountError = nil
        addAccountStatusMessage = "正在启动 Antigravity 登录，请在浏览器中完成登录..."

        let prevTokens = Set(accounts.map { $0.refreshToken })
        auth.prepareForNewLogin()

        loginPollTimer?.invalidate()
        var attempts = 0
        loginPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            attempts += 1
            if attempts > 120 { // 3分钟超时
                timer.invalidate()
                self.isListeningForLogin = false
                self.addAccountError = "登录等待超时，已恢复之前账号"
                self.cancelGuideLogin()
                return
            }

            if let live = self.auth.readLiveBundle(), !live.refreshToken.isEmpty {
                // 检测是否为新凭据（不与历史账号相同）
                if !prevTokens.contains(live.refreshToken) {
                    timer.invalidate()
                    self.isListeningForLogin = false
                    self.captureCurrentLiveAccount()
                    return
                }
            }
        }
    }

    func cancelGuideLogin() {
        loginPollTimer?.invalidate()
        loginPollTimer = nil
        isListeningForLogin = false
        // 恢复之前选中的账号
        if !activeAccountID.isEmpty && activeAccountID != "?" {
            _ = auth.switchTo(alias: activeAccountID, restartApp: false)
        }
    }

    /// 方式三：手动粘贴 JSON 导入
    func importTokenJSON(_ jsonString: String, alias: String) {
        let res = auth.importTokenJSON(jsonString, alias: alias)
        if res.success {
            addAccountStatusMessage = "凭据导入成功！"
            addAccountError = nil
            reloadAccounts()
            refreshAllUsage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isAddAccountSheetPresented = false
            }
        } else {
            addAccountError = res.message
        }
    }

    // MARK: - Config

    func updateConfig(_ newConfig: AppConfig) {
        self.config = newConfig
        newConfig.save()
    }

    // MARK: - Helpers

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
