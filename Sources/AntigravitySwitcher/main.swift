import AppKit
import Foundation
import UserNotifications
import ServiceManagement

// MARK: - Data Models
// 移植自 jieguangzhou/CodexSwitcher —— Codex auth.json 机制替换为
// Antigravity 的 ~/.gemini/jetski-standalone-oauth-token + 钥匙串 gemini/antigravity

struct TokenBundle {
    var accessToken: String
    var tokenType: String
    var refreshToken: String
    var expiry: String
    var authMethod: String

    static func from(json: [String: Any]) -> TokenBundle? {
        guard let tok = json["token"] as? [String: Any],
              let at = tok["access_token"] as? String,
              let rt = tok["refresh_token"] as? String else { return nil }
        return TokenBundle(
            accessToken: at,
            tokenType: tok["token_type"] as? String ?? "Bearer",
            refreshToken: rt,
            expiry: tok["expiry"] as? String ?? "",
            authMethod: json["auth_method"] as? String ?? "consumer")
    }

    func toJSONData() -> Data? {
        let obj: [String: Any] = [
            "token": [
                "access_token": accessToken,
                "token_type": tokenType,
                "refresh_token": refreshToken,
                "expiry": expiry
            ],
            "auth_method": authMethod
        ]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    var expiryDate: Date? { parseISO(expiry) }
    var isTokenExpired: Bool {
        guard let d = expiryDate else { return false }
        return d < Date().addingTimeInterval(60)
    }
}

func parseISO(_ s: String) -> Date? {
    guard !s.isEmpty else { return nil }
    let fmts = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"]
    for f in fmts {
        let df = DateFormatter()
        df.dateFormat = f
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        if let d = df.date(from: s) { return d }
    }
    return ISO8601DateFormatter().date(from: s)
}

func isoUTC(from date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
    f.timeZone = TimeZone(identifier: "UTC")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
}

struct AGAccount {
    let alias: String
    let email: String
    let authMethod: String
    let accessToken: String
    let refreshToken: String
    let expiryDate: Date?

    var planColor: NSColor { NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0) }
    var planLabel: String { authMethod == "consumer" ? "FREE" : authMethod.uppercased() }
}

struct RateLimitWindow {
    let usedPercent: Int
    let resetsAt: Date?

    var remaining: Int { 100 - min(max(usedPercent, 0), 100) }

    var barColor: NSColor {
        if remaining <= 10 { return NSColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1.0) }
        if remaining <= 25 { return NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1.0) }
        if remaining <= 50 { return NSColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1.0) }
        if remaining <= 75 { return NSColor(red: 0.3, green: 0.78, blue: 0.5, alpha: 1.0) }
        return NSColor(red: 0.25, green: 0.72, blue: 0.45, alpha: 1.0)
    }

    var textColor: NSColor {
        if remaining <= 10 { return NSColor(red: 0.9, green: 0.25, blue: 0.25, alpha: 1.0) }
        if remaining <= 25 { return NSColor(red: 0.85, green: 0.5, blue: 0.15, alpha: 1.0) }
        return NSColor.secondaryLabelColor
    }
}

struct RateLimitInfo {
    let primary: RateLimitWindow?   // 5 小时窗口
    let secondary: RateLimitWindow? // 7 天窗口
}

enum FetchState {
    case idle
    case loading
    case success(RateLimitInfo)
    case failed(String)
}

// MARK: - Config

struct AppConfig {
    var refreshIntervalMinutes: Int = 30
    var minRefreshIntervalSeconds: Int = 30
    var alert5hThreshold: Int = 30    // 5h 剩余低于该值告警
    var alertWeekThreshold: Int = 10  // 7天 剩余低于该值告警
    var restartAntigravity: Bool = true

    private static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.antigravity-switcher/config.json"
    }()

    static func load() -> AppConfig {
        var config = AppConfig()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }
        if let v = json["refresh_interval_minutes"] as? Int, v > 0 { config.refreshIntervalMinutes = v }
        if let v = json["min_refresh_interval_seconds"] as? Int, v > 0 { config.minRefreshIntervalSeconds = v }
        if let v = json["alert_5h_threshold"] as? Int { config.alert5hThreshold = v }
        if let v = json["alert_week_threshold"] as? Int { config.alertWeekThreshold = v }
        if let v = json["restart_antigravity"] as? Bool { config.restartAntigravity = v }
        return config
    }

    func save() {
        let json: [String: Any] = [
            "refresh_interval_minutes": refreshIntervalMinutes,
            "min_refresh_interval_seconds": minRefreshIntervalSeconds,
            "alert_5h_threshold": alert5hThreshold,
            "alert_week_threshold": alertWeekThreshold,
            "restart_antigravity": restartAntigravity
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: AppConfig.configPath))
        }
    }
}

// MARK: - Auth Manager

class AntigravityAuthManager {
    static let shared = AntigravityAuthManager()

    private let geminiDir: String
    let tokenFile: String
    private let currentFile: String
    let accountsDir: String
    private let keychainService = "gemini"
    private let keychainAccount = "antigravity"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        geminiDir = "\(home)/.gemini"
        tokenFile = "\(geminiDir)/jetski-standalone-oauth-token"
        currentFile = "\(home)/.antigravity-switcher/current"
        accountsDir = "\(home)/.antigravity-switcher/accounts"
        try? FileManager.default.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)
    }

    // ---------- 基础 IO ----------

    func readTokenBundle(_ path: String) -> TokenBundle? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return TokenBundle.from(json: json)
    }

    func saveBundle(_ bundle: TokenBundle, to path: String) -> Bool {
        guard let data = bundle.toJSONData() else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { return false }
    }

    /// 从钥匙串读凭据（go-keyring-base64: 前缀的 base64 JSON）
    func readKeychainBundle() -> TokenBundle? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("go-keyring-base64:") else { return nil }
        let b64 = String(raw.dropFirst("go-keyring-base64:".count))
        guard let json = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return TokenBundle.from(json: obj)
    }

    /// 当前登录凭据：文件优先，文件没了退回钥匙串（Antigravity 某些版本只写钥匙串）
    func readLiveBundle() -> TokenBundle? {
        if let b = readTokenBundle(tokenFile) { return b }
        return readKeychainBundle()
    }

    /// 把凭据写回两处：token 文件（存在过才写）+ 钥匙串
    func writeLiveBundle(_ bundle: TokenBundle) -> Bool {
        var ok = writeKeychain(bundle: bundle)
        let fm = FileManager.default
        if fm.fileExists(atPath: geminiDir) {
            if fm.fileExists(atPath: tokenFile) { try? fm.removeItem(atPath: tokenFile) }
            ok = saveBundle(bundle, to: tokenFile) || ok
        }
        return ok
    }

    private func writeKeychain(bundle: TokenBundle) -> Bool {
        guard let data = bundle.toJSONData() else { return false }
        let value = "go-keyring-base64:" + (data.base64EncodedString())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U", "-s", keychainService, "-a", keychainAccount, "-w", value]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func currentAlias() -> String {
        if let data = try? String(contentsOfFile: currentFile, encoding: .utf8) {
            let alias = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty { return alias }
        }
        return detectCurrentAlias()
    }

    /// current 文件缺失时，用 refresh_token 比对识别当前账号
    private func detectCurrentAlias() -> String {
        guard let live = readLiveBundle() else { return "?" }
        if let match = listAccounts().first(where: { $0.refreshToken == live.refreshToken }) {
            writeCurrentAlias(match.alias)
            return match.alias
        }
        return "?"
    }

    private func writeCurrentAlias(_ alias: String) {
        try? alias.write(toFile: currentFile, atomically: true, encoding: .utf8)
    }

    func readEmail(alias: String) -> String {
        let metaPath = "\(accountsDir)/\(alias).meta.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else { return "?" }
        return email
    }

    func writeEmail(alias: String, email: String) {
        let metaPath = "\(accountsDir)/\(alias).meta.json"
        let json: [String: Any] = ["email": email]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: metaPath))
        }
    }

    // ---------- 列表 ----------

    func listAccounts() -> [AGAccount] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: accountsDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") }
            .sorted()
            .compactMap { file -> AGAccount? in
                let alias = String(file.dropLast(5))
                guard let bundle = readTokenBundle("\(accountsDir)/\(file)") else { return nil }
                return AGAccount(alias: alias, email: readEmail(alias: alias),
                                 authMethod: bundle.authMethod,
                                 accessToken: bundle.accessToken,
                                 refreshToken: bundle.refreshToken,
                                 expiryDate: bundle.expiryDate)
            }
    }

    // ---------- 切换 ----------

    @discardableResult
    func switchTo(alias: String) -> Bool {
        let fm = FileManager.default
        let current = currentAlias()
        let targetFile = "\(accountsDir)/\(alias).json"
        guard fm.fileExists(atPath: targetFile) else { return false }

        // 1. 当前登录凭据先备份回它自己的账号文件（只在同 alias 存在时）
        if !current.isEmpty && current != "?" && fm.fileExists(atPath: tokenFile) {
            let currentAccountFile = "\(accountsDir)/\(current).json"
            let tmpFile = currentAccountFile + ".tmp"
            do {
                if fm.fileExists(atPath: tmpFile) { try fm.removeItem(atPath: tmpFile) }
                try fm.copyItem(atPath: tokenFile, toPath: tmpFile)
                if fm.fileExists(atPath: currentAccountFile) { try fm.removeItem(atPath: currentAccountFile) }
                try fm.moveItem(atPath: tmpFile, toPath: currentAccountFile)
            } catch { try? fm.removeItem(atPath: tmpFile) }
        }

        // 2. 把目标账号凭据写到 Antigravity 的两处凭据位（文件 + 钥匙串）
        guard let bundle = readTokenBundle(targetFile) else { return false }
        guard writeLiveBundle(bundle) else { return false }

        // 3. 记录当前 alias
        writeCurrentAlias(alias)
        return true
    }

    // ---------- 自动同步（监听 token 文件变化，自动入库） ----------

    func syncAuthToAccounts() {
        let fm = FileManager.default
        guard let live = readLiveBundle() else { return }
        if !fm.isReadableFile(atPath: accountsDir) {
            try? fm.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)
        }
        let accounts = listAccounts()

        // 已存在同一 refresh_token → 更新快照并标记为当前
        if let existing = accounts.first(where: { $0.refreshToken == live.refreshToken }) {
            let accountFile = "\(accountsDir)/\(existing.alias).json"
            try? fm.removeItem(atPath: accountFile)
            if fm.fileExists(atPath: tokenFile) {
                try? fm.copyItem(atPath: tokenFile, toPath: accountFile)
            } else if let data = live.toJSONData() {
                try? data.write(to: URL(fileURLWithPath: accountFile))
            }
            writeCurrentAlias(existing.alias)
            return
        }
        // 新账号 → 占位 alias（等 QuotaClient 拿到邮箱后改名）
        var alias = "acc-" + String(Int(Date().timeIntervalSince1970) % 100000)
        let existingAliases = Set(accounts.map { $0.alias })
        if existingAliases.contains(alias) {
            var i = 1
            while existingAliases.contains("\(alias)\(i)") { i += 1 }
            alias = "\(alias)\(i)"
        }
        _ = saveBundle(live, to: "\(accountsDir)/\(alias).json")
        writeEmail(alias: alias, email: "识别中…")
        writeCurrentAlias(alias)
        NotificationCenter.default.post(name: NSNotification.Name("AGNewAccountAdded"), object: alias)
    }

    func renameAccount(alias: String, to newAliasBase: String) -> String? {
        let fm = FileManager.default
        let newAlias0 = newAliasBase
        var newAlias = newAlias0
        var i = 1
        let existing = Set((try? fm.contentsOfDirectory(atPath: accountsDir))?.compactMap { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") ? String($0.dropLast(5)) : nil } ?? [])
        while existing.contains(newAlias) && newAlias != alias { newAlias = "\(newAlias0)\(i)"; i += 1 }
        do {
            try fm.copyItem(atPath: "\(accountsDir)/\(alias).json", toPath: "\(accountsDir)/\(newAlias).json")
            let email = readEmail(alias: alias)
            writeEmail(alias: newAlias, email: email)
            try fm.removeItem(atPath: "\(accountsDir)/\(alias).json")
            try? fm.removeItem(atPath: "\(accountsDir)/\(alias).meta.json")
            if currentAlias() == alias { writeCurrentAlias(newAlias) }
            return newAlias
        } catch { return nil }
    }

    func deleteAccount(alias: String) -> Bool {
        let ok1 = (try? FileManager.default.removeItem(atPath: "\(accountsDir)/\(alias).json")) != nil
        try? FileManager.default.removeItem(atPath: "\(accountsDir)/\(alias).meta.json")
        return ok1
    }

    // ---------- Antigravity 应用控制 ----------

    func quitAntigravity() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName?.lowercased().contains("antigravity") == true) &&
            ($0.bundleURL?.path.hasPrefix("/Applications/Antigravity.app") ?? true) &&
            !$0.isTerminated
        }
        for app in apps { app.terminate() }
        for _ in 0..<60 {
            let alive = NSWorkspace.shared.runningApplications.filter {
                ($0.localizedName?.lowercased().contains("antigravity") == true) &&
                ($0.bundleURL?.path.hasPrefix("/Applications/Antigravity.app") ?? true) &&
                !$0.isTerminated
            }
            if alive.isEmpty { break }
            usleep(100_000)
        }
    }

    func launchAntigravity() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-ga", "Antigravity"]
        try? p.run()
    }
}

// MARK: - Rate Limit Client (cloudcode-pa)

class RateLimitClient {
    // 与 Antigravity / agy CLI 一致的 Google Cloud Code OAuth client
    private let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let clientSecret = "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"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    private let userinfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    var usageByAlias: [String: FetchState] = [:]
    var lastFetchTime: Date?
    var onUpdate: (() -> Void)?

    func fetchAll(_ accounts: [AGAccount]) {
        lastFetchTime = Date()
        for acct in accounts {
            if acct.refreshToken.isEmpty {
                usageByAlias[acct.alias] = .failed("No credentials")
                continue
            }
            // Only show loading if no previous data
            if usageByAlias[acct.alias] == nil { usageByAlias[acct.alias] = .loading }
            fetchForAccount(acct)
        }
        DispatchQueue.main.async { self.onUpdate?() }
    }

    func refreshIfNeeded(_ accounts: [AGAccount], minInterval: TimeInterval) {
        if let last = lastFetchTime, Date().timeIntervalSince(last) < minInterval { return }
        fetchAll(accounts)
    }

    private func fetchForAccount(_ acct: AGAccount) {
        let auth = AntigravityAuthManager.shared
        let alias = acct.alias

        func proceed(with access: String) {
            self.fetchQuota(access: access, alias: alias)
            // 邮箱未识别的账号顺带解析一次
            if auth.readEmail(alias: alias) == "?" || auth.readEmail(alias: alias) == "识别中…" {
                self.resolveEmail(access: access, alias: alias)
            }
        }

        // 读账号快照，必要时先刷新 access_token
        guard let bundle = auth.readTokenBundle("\(auth.accountsDir)/\(alias).json") else {
            setState(alias, .failed("No credentials")); return
        }
        if let exp = bundle.expiryDate, exp > Date().addingTimeInterval(120), !bundle.accessToken.isEmpty {
            proceed(with: bundle.accessToken)
        } else {
            refreshBundle(bundle) { fresh in
                guard let fresh = fresh else {
                    self.setState(alias, .failed("Token 刷新失败")); return
                }
                _ = auth.saveBundle(fresh, to: "\(auth.accountsDir)/\(alias).json")
                proceed(with: fresh.accessToken)
            }
        }
    }

    private func refreshBundle(_ bundle: TokenBundle, completion: @escaping (TokenBundle?) -> Void) {
        guard let url = URL(string: tokenURL) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body = "client_id=\(clientID)&client_secret=\(clientSecret)&refresh_token=\(bundle.refreshToken)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = json["access_token"] as? String else { completion(nil); return }
            let expiresIn = json["expires_in"] as? Double ?? 3600
            var fresh = bundle
            fresh.accessToken = at
            fresh.expiry = isoUTC(from: Date().addingTimeInterval(expiresIn - 120))
            completion(fresh)
        }.resume()
    }

    private func fetchQuota(access: String, alias: String) {
        guard let url = URL(string: quotaURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if error != nil { self.setState(alias, .failed("Network error")); return }
            guard let http = response as? HTTPURLResponse, let data = data else {
                self.setState(alias, .failed("No response")); return
            }
            if http.statusCode == 401 { self.setState(alias, .failed("Token expired")); return }
            if http.statusCode != 200 { self.setState(alias, .failed("HTTP \(http.statusCode)")); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.setState(alias, .failed("Parse error")); return
            }
            self.setState(alias, .success(self.parseResponse(json)))
        }.resume()
    }

    private func resolveEmail(access: String, alias: String) {
        guard let url = URL(string: userinfoURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String else { return }
            DispatchQueue.main.async {
                let auth = AntigravityAuthManager.shared
                auth.writeEmail(alias: alias, email: email)
                if alias.hasPrefix("acc-") {  // 占位账号改名成邮箱前缀
                    let prefix = email.components(separatedBy: "@").first ?? alias
                    if let newAlias = auth.renameAccount(alias: alias, to: prefix) {
                        self.usageByAlias[newAlias] = self.usageByAlias[alias]
                        self.usageByAlias.removeValue(forKey: alias)
                    }
                }
                self.onUpdate?()
            }
        }.resume()
    }

    private func setState(_ alias: String, _ state: FetchState) {
        DispatchQueue.main.async { self.usageByAlias[alias] = state; self.onUpdate?() }
    }

    private func parseResponse(_ json: [String: Any]) -> RateLimitInfo {
        var primary: RateLimitWindow? = nil
        var secondary: RateLimitWindow? = nil
        // groups[].buckets[]: window = "5h" / "weekly", remainingFraction 0~1
        if let groups = json["groups"] as? [[String: Any]] {
            var five: [RateLimitWindow] = []
            var week: [RateLimitWindow] = []
            for g in groups {
                guard let buckets = g["buckets"] as? [[String: Any]] else { continue }
                for b in buckets {
                    let window = b["window"] as? String ?? ""
                    guard let frac = b["remainingFraction"] as? Double else { continue }
                    let remaining = Int((frac * 100).rounded())
                    let reset = (b["resetTime"] as? String).flatMap { parseISO($0) }
                    let w = RateLimitWindow(usedPercent: 100 - remaining, resetsAt: reset)
                    if window == "5h" { five.append(w) }
                    else if window == "weekly" { week.append(w) }
                }
            }
            // 取剩余最少的窗口（最悲观）
            primary = five.min { $0.remaining < $1.remaining }
            secondary = week.min { $0.remaining < $1.remaining }
        }
        return RateLimitInfo(primary: primary, secondary: secondary)
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let authManager = AntigravityAuthManager.shared
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let rateLimitClient = RateLimitClient()
    private var refreshTimer: Timer?
    private var config = AppConfig.load()
    private var previousAlertState: (p5h: Bool, pWk: Bool) = (false, false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rateLimitClient.onUpdate = { [weak self] in self?.updateMenu() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        authManager.syncAuthToAccounts()
        updateMenu()
        watchAuthFile()
        rateLimitClient.fetchAll(authManager.listAccounts())
        scheduleTimer()
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(config.refreshIntervalMinutes, 1) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.rateLimitClient.fetchAll(self.authManager.listAccounts())
        }
    }

    // Refresh on menu open (smart: skip if recent)
    func menuWillOpen(_ menu: NSMenu) {
        let minInterval = TimeInterval(config.minRefreshIntervalSeconds)
        rateLimitClient.refreshIfNeeded(authManager.listAccounts(), minInterval: minInterval)
    }

    // MARK: - Drawing Helpers

    /// AI character icons for status bar
    private func makeAIIcon(state: Int) -> NSImage {
        // state: 0 = standing (normal), 1 = tired (5h alert), 2 = lying (week alert)
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        switch state {
        case 2: drawLyingAI(s: s)
        case 1: drawTiredAI(s: s)
        default: drawStandingAI(s: s)
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func drawStandingAI(s: CGFloat) {
        let cx = s * 0.5
        // Antenna
        let antennaPath = NSBezierPath()
        antennaPath.move(to: NSPoint(x: cx, y: s * 0.78))
        antennaPath.line(to: NSPoint(x: cx, y: s * 0.88))
        antennaPath.lineWidth = 1.2; antennaPath.lineCapStyle = .round; antennaPath.stroke()
        NSBezierPath(ovalIn: NSRect(x: cx - 1.5, y: s * 0.88, width: 3, height: 3)).fill()

        // Head
        let headR: CGFloat = s * 0.15
        let headY = s * 0.65
        NSBezierPath(ovalIn: NSRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)).stroke()
        // Eyes
        let eyeR: CGFloat = 1.2
        NSBezierPath(ovalIn: NSRect(x: cx - headR * 0.5 - eyeR, y: headY + headR * 0.7, width: eyeR * 2, height: eyeR * 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx + headR * 0.5 - eyeR, y: headY + headR * 0.7, width: eyeR * 2, height: eyeR * 2)).fill()

        // Body
        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: cx, y: headY))
        bodyPath.line(to: NSPoint(x: cx, y: s * 0.28))
        bodyPath.lineWidth = 1.5; bodyPath.lineCapStyle = .round; bodyPath.stroke()

        // Arms (up, like waving)
        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: cx, y: s * 0.52))
        armPath.line(to: NSPoint(x: cx - s * 0.2, y: s * 0.6))
        armPath.move(to: NSPoint(x: cx, y: s * 0.52))
        armPath.line(to: NSPoint(x: cx + s * 0.2, y: s * 0.6))
        armPath.lineWidth = 1.3; armPath.lineCapStyle = .round; armPath.stroke()

        // Legs
        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: cx, y: s * 0.28))
        legPath.line(to: NSPoint(x: cx - s * 0.14, y: s * 0.08))
        legPath.move(to: NSPoint(x: cx, y: s * 0.28))
        legPath.line(to: NSPoint(x: cx + s * 0.14, y: s * 0.08))
        legPath.lineWidth = 1.3; legPath.lineCapStyle = .round; legPath.stroke()
    }

    private func drawTiredAI(s: CGFloat) {
        let cx = s * 0.5
        // Antenna (drooping)
        let antennaPath = NSBezierPath()
        antennaPath.move(to: NSPoint(x: cx, y: s * 0.75))
        antennaPath.line(to: NSPoint(x: cx - s * 0.05, y: s * 0.83))
        antennaPath.lineWidth = 1.2; antennaPath.lineCapStyle = .round; antennaPath.stroke()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.05 - 1.5, y: s * 0.82, width: 3, height: 3)).fill()

        // Head (slightly drooping)
        let headR: CGFloat = s * 0.15
        let headY = s * 0.6
        NSBezierPath(ovalIn: NSRect(x: cx - headR - s * 0.02, y: headY, width: headR * 2, height: headR * 2)).stroke()
        // Tired eyes (lines instead of dots)
        let eyePath = NSBezierPath()
        eyePath.move(to: NSPoint(x: cx - headR * 0.7, y: headY + headR * 0.85))
        eyePath.line(to: NSPoint(x: cx - headR * 0.1, y: headY + headR * 0.75))
        eyePath.move(to: NSPoint(x: cx + headR * 0.1, y: headY + headR * 0.85))
        eyePath.line(to: NSPoint(x: cx + headR * 0.7, y: headY + headR * 0.75))
        eyePath.lineWidth = 1.0; eyePath.lineCapStyle = .round; eyePath.stroke()

        // Body (slouching, slight curve)
        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: cx - s * 0.02, y: headY))
        bodyPath.curve(to: NSPoint(x: cx, y: s * 0.24),
                       controlPoint1: NSPoint(x: cx + s * 0.05, y: s * 0.5),
                       controlPoint2: NSPoint(x: cx - s * 0.05, y: s * 0.35))
        bodyPath.lineWidth = 1.5; bodyPath.lineCapStyle = .round; bodyPath.stroke()

        // Arms (hanging down)
        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: cx, y: s * 0.48))
        armPath.line(to: NSPoint(x: cx - s * 0.18, y: s * 0.32))
        armPath.move(to: NSPoint(x: cx, y: s * 0.48))
        armPath.line(to: NSPoint(x: cx + s * 0.18, y: s * 0.32))
        armPath.lineWidth = 1.3; armPath.lineCapStyle = .round; armPath.stroke()

        // Legs (wobbly)
        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: cx, y: s * 0.24))
        legPath.line(to: NSPoint(x: cx - s * 0.12, y: s * 0.06))
        legPath.move(to: NSPoint(x: cx, y: s * 0.24))
        legPath.line(to: NSPoint(x: cx + s * 0.12, y: s * 0.06))
        legPath.lineWidth = 1.3; legPath.lineCapStyle = .round; legPath.stroke()

        // Sweat drop
        NSBezierPath(ovalIn: NSRect(x: cx + headR + 1, y: headY + headR * 0.5, width: 2, height: 3)).fill()
    }

    private func drawLyingAI(s: CGFloat) {
        let cy = s * 0.38
        // Ground line
        let groundPath = NSBezierPath()
        groundPath.move(to: NSPoint(x: s * 0.05, y: s * 0.15))
        groundPath.line(to: NSPoint(x: s * 0.95, y: s * 0.15))
        groundPath.lineWidth = 0.8; groundPath.lineCapStyle = .round; groundPath.stroke()

        // Lying body (horizontal)
        // Head (right side)
        let headR: CGFloat = s * 0.13
        let headX = s * 0.75
        NSBezierPath(ovalIn: NSRect(x: headX, y: cy - headR + s * 0.02, width: headR * 2, height: headR * 2)).stroke()
        // X eyes (knocked out)
        let exPath = NSBezierPath()
        let eyeCx1 = headX + headR * 0.6; let eyeCx2 = headX + headR * 1.4
        let eyeCy = cy + s * 0.05
        let ex: CGFloat = 1.5
        exPath.move(to: NSPoint(x: eyeCx1 - ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx1 + ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx1 + ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx1 - ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx2 - ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx2 + ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx2 + ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx2 - ex, y: eyeCy + ex))
        exPath.lineWidth = 1.0; exPath.lineCapStyle = .round; exPath.stroke()

        // Body (horizontal line)
        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: headX, y: cy))
        bodyPath.line(to: NSPoint(x: s * 0.28, y: cy))
        bodyPath.lineWidth = 1.5; bodyPath.lineCapStyle = .round; bodyPath.stroke()

        // Legs (slightly bent, to the left)
        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: s * 0.28, y: cy))
        legPath.line(to: NSPoint(x: s * 0.15, y: cy + s * 0.1))
        legPath.move(to: NSPoint(x: s * 0.28, y: cy))
        legPath.line(to: NSPoint(x: s * 0.12, y: cy - s * 0.08))
        legPath.lineWidth = 1.3; legPath.lineCapStyle = .round; legPath.stroke()

        // Arms (flopped)
        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: s * 0.55, y: cy))
        armPath.line(to: NSPoint(x: s * 0.5, y: cy + s * 0.15))
        armPath.move(to: NSPoint(x: s * 0.45, y: cy))
        armPath.line(to: NSPoint(x: s * 0.42, y: cy - s * 0.12))
        armPath.lineWidth = 1.3; armPath.lineCapStyle = .round; armPath.stroke()

        // Zzz
        let zFont = NSFont.systemFont(ofSize: 6, weight: .bold)
        ("z" as NSString).draw(at: NSPoint(x: s * 0.82, y: s * 0.6), withAttributes: [
            .font: zFont, .foregroundColor: NSColor.black
        ])
        ("z" as NSString).draw(at: NSPoint(x: s * 0.72, y: s * 0.7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 5, weight: .bold), .foregroundColor: NSColor.black
        ])
    }

    private func formatResetTime(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if d.timeIntervalSinceNow < 24 * 3600 {
            f.dateFormat = "HH:mm"
            return "重置于 " + f.string(from: d)
        }
        f.dateFormat = "MMM d HH:mm"
        return "重置于 " + f.string(from: d)
    }

    private func makeProgressBar(remaining: Int, width: CGFloat = 100, height: CGFloat = 8) -> NSImage {
        let pct = CGFloat(min(max(remaining, 0), 100)) / 100.0
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()

        let radius: CGFloat = 4
        let trackColor = NSColor.separatorColor.withAlphaComponent(0.3)
        let bgRect = NSRect(x: 0, y: 0, width: width, height: height)
        trackColor.setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius).fill()

        let fillWidth = width * pct
        if fillWidth > 0 {
            let window = RateLimitWindow(usedPercent: 100 - remaining, resetsAt: nil)
            let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: height)
            window.barColor.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }

        img.unlockFocus()
        return img
    }

    private func barAttachment(remaining: Int) -> NSAttributedString {
        let img = makeProgressBar(remaining: remaining)
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: 2, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: att)
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Build Menu

    private func displayName(_ acct: AGAccount) -> String {
        let email = acct.email
        if email == "?" || email == "识别中…" { return acct.alias }
        return email
    }

    private func updateMenu() {
        let current = authManager.currentAlias()
        let accounts = authManager.listAccounts()
        let active = accounts.first(where: { $0.alias == current })
        let others = accounts.filter { $0.alias != current }

        // Status bar - icon only, with red dot alerts
        if let button = statusItem.button {
            var alert5h = false, alertWk = false
            if let acct = active, case .success(let rl) = rateLimitClient.usageByAlias[acct.alias] {
                let p5h = rl.primary?.remaining ?? 100
                let pWk = rl.secondary?.remaining ?? 100
                alert5h = p5h < config.alert5hThreshold
                alertWk = pWk < config.alertWeekThreshold

                // Send notification on new alerts (not on every refresh)
                if alert5h && !previousAlertState.p5h {
                    sendNotification(title: "\(displayName(acct)) - 5小时配额低",
                        body: "5小时剩余：\(p5h)%")
                }
                if alertWk && !previousAlertState.pWk {
                    sendNotification(title: "\(displayName(acct)) - 7天配额低",
                        body: "7天剩余：\(pWk)%")
                }
                previousAlertState = (alert5h, alertWk)

                button.toolTip = "Antigravity: \(displayName(acct)) | 5小时: \(p5h)% | 7天: \(pWk)%"
            } else {
                button.toolTip = "Antigravity: \(active.map { displayName($0) } ?? current)"
            }
            let iconState = alertWk ? 2 : (alert5h ? 1 : 0)
            button.image = makeAIIcon(state: iconState)
            button.title = ""
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 320

        // ─── 当前账号 ───
        if let acct = active {
            buildCard(menu, acct, isActive: true)
            menu.addItem(NSMenuItem.separator())
        }

        // ─── 其他账号 ───
        if !others.isEmpty {
            for (i, account) in others.enumerated() {
                buildCard(menu, account, isActive: false)
                if i < others.count - 1 { menu.addItem(NSMenuItem.separator()) }
            }
            menu.addItem(NSMenuItem.separator())
        }

        // ─── 操作 ───
        addMenuItem(menu, "刷新全部", #selector(refreshUsage), "r")

        if !others.isEmpty {
            let removeItem = NSMenuItem(title: "删除账号", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for acct in others {
                let item = NSMenuItem(title: displayName(acct), action: #selector(deleteAccount(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = acct.alias
                sub.addItem(item)
            }
            removeItem.submenu = sub
            menu.addItem(removeItem)
        }

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        if #available(macOS 13.0, *) {
            launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else { launchItem.isEnabled = false }
        menu.addItem(launchItem)

        // 设置子菜单
        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()

        let refreshHeader = NSMenuItem(title: "自动刷新", action: nil, keyEquivalent: "")
        refreshHeader.isEnabled = false
        settingsMenu.addItem(refreshHeader)
        for (label, mins) in [("5 分钟", 5), ("15 分钟", 15), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("关闭", 0)] {
            let opt = NSMenuItem(title: "  \(label)", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            opt.target = self; opt.tag = mins
            opt.state = config.refreshIntervalMinutes == mins ? .on : .off
            settingsMenu.addItem(opt)
        }

        settingsMenu.addItem(NSMenuItem.separator())

        let restartItem = NSMenuItem(title: "切换后自动重启 Antigravity", action: #selector(toggleRestartAntigravity(_:)), keyEquivalent: "")
        restartItem.target = self
        restartItem.state = config.restartAntigravity ? .on : .off
        settingsMenu.addItem(restartItem)

        settingsMenu.addItem(NSMenuItem.separator())

        // 5h 告警阈值
        let alert5hHeader = NSMenuItem(title: "5小时告警阈值（低于）", action: nil, keyEquivalent: "")
        alert5hHeader.isEnabled = false
        settingsMenu.addItem(alert5hHeader)
        for pct in [10, 20, 30, 50] {
            let opt = NSMenuItem(title: "  \(pct)%", action: #selector(setAlert5hThreshold(_:)), keyEquivalent: "")
            opt.target = self; opt.tag = pct
            opt.state = config.alert5hThreshold == pct ? .on : .off
            settingsMenu.addItem(opt)
        }

        settingsMenu.addItem(NSMenuItem.separator())

        // 7天告警阈值
        let alertWkHeader = NSMenuItem(title: "7天告警阈值（低于）", action: nil, keyEquivalent: "")
        alertWkHeader.isEnabled = false
        settingsMenu.addItem(alertWkHeader)
        for pct in [5, 10, 20, 30] {
            let opt = NSMenuItem(title: "  \(pct)%", action: #selector(setAlertWeekThreshold(_:)), keyEquivalent: "")
            opt.target = self; opt.tag = pct
            opt.state = config.alertWeekThreshold == pct ? .on : .off
            settingsMenu.addItem(opt)
        }

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        addMenuItem(menu, "退出应用", #selector(quit), "q")
        statusItem.menu = menu
    }

    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func buildCard(_ menu: NSMenu, _ acct: AGAccount, isActive: Bool) {
        let item = NSMenuItem()
        let s = NSMutableAttributedString()
        let indent = "  "
        let name = displayName(acct)

        // Row 1: 名称 + plan
        if isActive {
            s.append(NSAttributedString(string: "\u{25CF} ", attributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.systemGreen
            ]))
        }
        s.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .medium),
            .foregroundColor: NSColor.labelColor
        ]))

        // Plan badge
        let badgeText = " \(acct.planLabel) "
        s.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 9)]))
        let badge = NSMutableAttributedString(string: badgeText, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: acct.planColor,
            .backgroundColor: acct.planColor.withAlphaComponent(0.12),
            .baselineOffset: 2
        ])
        s.append(badge)

        // Row 2: alias（与名称不同时显示）
        if name != acct.alias {
            s.append(NSAttributedString(string: "\n\(indent) \(acct.alias)", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }

        // Row 3-4: usage bars
        let state = rateLimitClient.usageByAlias[acct.alias] ?? .idle
        switch state {
        case .success(let rl):
            let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let labelColor = NSColor.tertiaryLabelColor
            let pctFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

            if let p = rl.primary {
                s.append(NSAttributedString(string: "\n\(indent) ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                s.append(NSAttributedString(string: "5小时 ", attributes: [.font: labelFont, .foregroundColor: labelColor]))
                s.append(barAttachment(remaining: p.remaining))
                s.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                let pctStr = String(format: "%3d%%", p.remaining)
                s.append(NSAttributedString(string: pctStr, attributes: [.font: pctFont, .foregroundColor: p.textColor]))
                if let r = p.resetsAt, p.remaining < 100 {
                    s.append(NSAttributedString(string: "  \(formatResetTime(r))", attributes: [
                        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: labelColor]))
                }
            }
            if let sec = rl.secondary {
                s.append(NSAttributedString(string: "\n\(indent) ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                s.append(NSAttributedString(string: "7天   ", attributes: [.font: labelFont, .foregroundColor: labelColor]))
                s.append(barAttachment(remaining: sec.remaining))
                s.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
                let pctStr = String(format: "%3d%%", sec.remaining)
                s.append(NSAttributedString(string: pctStr, attributes: [.font: pctFont, .foregroundColor: sec.textColor]))
                if let r = sec.resetsAt, sec.remaining < 100 {
                    s.append(NSAttributedString(string: "  \(formatResetTime(r))", attributes: [
                        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: labelColor]))
                }
            }

        case .loading:
            s.append(NSAttributedString(string: "\n\(indent) 加载中…", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor
            ]))

        case .failed(let reason):
            s.append(NSAttributedString(string: "\n\(indent) \(reason)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1.0)
            ]))

        case .idle: break
        }

        item.attributedTitle = s
        if isActive {
            item.isEnabled = false
        } else {
            item.target = self; item.action = #selector(switchAccount(_:))
            item.representedObject = acct.alias
        }
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        let email = authManager.readEmail(alias: alias)
        if config.restartAntigravity { authManager.quitAntigravity() }
        guard authManager.switchTo(alias: alias) else {
            let a = NSAlert(); a.messageText = "切换失败"
            a.informativeText = "无法切换到 '\(alias)'"; a.alertStyle = .warning; a.runModal()
            return
        }
        if config.restartAntigravity { authManager.launchAntigravity() }
        updateMenu()
        // Refresh in background after a delay, don't block UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.rateLimitClient.fetchAll(self.authManager.listAccounts())
        }
        sendNotification(title: "Antigravity 账号已切换", body: "当前使用：\(email == "?" ? alias : email)")
    }

    @objc private func deleteAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        if alias == authManager.currentAlias() {
            let a = NSAlert(); a.messageText = "不能删除当前账号"
            a.informativeText = "请先切换到其他账号。"; a.alertStyle = .warning; a.runModal()
            return
        }
        let c = NSAlert(); c.messageText = "删除 '\(authManager.readEmail(alias: alias) == "?" ? alias : authManager.readEmail(alias: alias))'？"
        c.informativeText = "以后可以重新在 Antigravity 登录该账号再添加。"
        c.alertStyle = .warning; c.addButton(withTitle: "删除"); c.addButton(withTitle: "取消")
        if c.runModal() == .alertFirstButtonReturn {
            if authManager.deleteAccount(alias: alias) {
                rateLimitClient.usageByAlias.removeValue(forKey: alias); updateMenu()
            }
        }
    }

    @objc private func refreshUsage() {
        rateLimitClient.fetchAll(authManager.listAccounts())
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        config.refreshIntervalMinutes = sender.tag
        config.save(); scheduleTimer(); updateMenu()
    }

    @objc private func toggleRestartAntigravity(_ sender: NSMenuItem) {
        config.restartAntigravity = !config.restartAntigravity
        config.save(); updateMenu()
    }

    @objc private func setAlert5hThreshold(_ sender: NSMenuItem) {
        config.alert5hThreshold = sender.tag
        config.save(); previousAlertState = (false, false); updateMenu()
    }

    @objc private func setAlertWeekThreshold(_ sender: NSMenuItem) {
        config.alertWeekThreshold = sender.tag
        config.save(); previousAlertState = (false, false); updateMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
                updateMenu()
            } catch {}
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private var lastFileEventTime: Date = .distantPast
    private var authFileMonitor: DispatchSourceFileSystemObject?

    private func onAuthChanged() {
        let now = Date()
        guard now.timeIntervalSince(lastFileEventTime) > 2 else { return }
        lastFileEventTime = now
        authManager.syncAuthToAccounts()
        updateMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.rateLimitClient.fetchAll(self.authManager.listAccounts())
        }
    }

    private func watchAuthFile() {
        let geminiDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")

        // Watch directory (catches new files, renames)
        let dirFd = open(geminiDir.path, O_EVTONLY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                self?.onAuthChanged()
                // Re-watch token file in case it was recreated
                self?.watchTokenFile()
            }
            source.setCancelHandler { close(dirFd) }
            source.resume()
            fileMonitor = source
        }

        watchTokenFile()
    }

    private func watchTokenFile() {
        // Cancel previous watcher
        authFileMonitor?.cancel()
        authFileMonitor = nil

        let authPath = authManager.tokenFile
        let authFd = open(authPath, O_EVTONLY)
        guard authFd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: authFd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.onAuthChanged()
            // File may have been replaced, re-watch
            self?.watchTokenFile()
        }
        source.setCancelHandler { close(authFd) }
        source.resume()
        authFileMonitor = source
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
