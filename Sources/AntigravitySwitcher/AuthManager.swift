import AppKit
import Foundation

class AntigravityAuthManager {
    static let shared = AntigravityAuthManager()

    let geminiDir: String
    let tokenFile: String
    let currentFile: String
    let accountsDir: String
    let backupDir: String
    private let keychainService = "gemini"
    private let keychainAccount = "antigravity"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        geminiDir = "\(home)/.gemini"
        tokenFile = "\(geminiDir)/jetski-standalone-oauth-token"
        let baseSwitcherDir = "\(home)/.antigravity-switcher"
        currentFile = "\(baseSwitcherDir)/current"
        accountsDir = "\(baseSwitcherDir)/accounts"
        backupDir = "\(baseSwitcherDir)/backups"
        try? FileManager.default.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
    }

    // MARK: - Token Bundle IO

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

    /// 从钥匙串读取凭据（go-keyring-base64: 前缀的 base64 JSON）
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

    /// 当前 live 凭据：文件优先，文件缺失时回退钥匙串
    func readLiveBundle() -> TokenBundle? {
        if let b = readTokenBundle(tokenFile) { return b }
        return readKeychainBundle()
    }

    /// 把凭据写回两处：token 文件 + 钥匙串
    @discardableResult
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

    func clearKeychain() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", keychainService, "-a", keychainAccount]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - Current & Accounts Management

    func currentAlias() -> String {
        if let data = try? String(contentsOfFile: currentFile, encoding: .utf8) {
            let alias = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty { return alias }
        }
        return detectCurrentAlias()
    }

    private func detectCurrentAlias() -> String {
        guard let live = readLiveBundle() else { return "?" }
        if let match = listAccounts().first(where: { $0.refreshToken == live.refreshToken }) {
            writeCurrentAlias(match.alias)
            return match.alias
        }
        return "?"
    }

    func writeCurrentAlias(_ alias: String) {
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

    func listAccounts() -> [AGAccount] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: accountsDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".meta.json") }
            .sorted()
            .compactMap { file -> AGAccount? in
                let alias = String(file.dropLast(5))
                guard let bundle = readTokenBundle("\(accountsDir)/\(file)") else { return nil }
                return AGAccount(
                    alias: alias,
                    email: readEmail(alias: alias),
                    authMethod: bundle.authMethod,
                    accessToken: bundle.accessToken,
                    refreshToken: bundle.refreshToken,
                    expiryDate: bundle.expiryDate
                )
            }
    }

    // MARK: - Switching

    @discardableResult
    func switchTo(alias: String, restartApp: Bool = true) -> Bool {
        let fm = FileManager.default
        let current = currentAlias()
        let targetFile = "\(accountsDir)/\(alias).json"
        guard fm.fileExists(atPath: targetFile) else { return false }

        // 1. 如果 Antigravity 正在运行且需要重启，先退出
        if restartApp {
            quitAntigravity()
        }

        // 2. 当前 live 凭据写回当前账号快照
        if !current.isEmpty && current != "?" && fm.fileExists(atPath: tokenFile) {
            let currentAccountFile = "\(accountsDir)/\(current).json"
            let tmpFile = currentAccountFile + ".tmp"
            do {
                if fm.fileExists(atPath: tmpFile) { try fm.removeItem(atPath: tmpFile) }
                try fm.copyItem(atPath: tokenFile, toPath: tmpFile)
                if fm.fileExists(atPath: currentAccountFile) { try fm.removeItem(atPath: currentAccountFile) }
                try fm.moveItem(atPath: tmpFile, toPath: currentAccountFile)
            } catch {
                try? fm.removeItem(atPath: tmpFile)
            }
        }

        // 3. 把目标账号凭据写到 Antigravity 凭据位（文件 + 钥匙串）
        guard let bundle = readTokenBundle(targetFile) else { return false }
        guard writeLiveBundle(bundle) else { return false }

        // 4. 更新当前 alias
        writeCurrentAlias(alias)

        // 5. 重新拉起 Antigravity
        if restartApp {
            launchAntigravity()
        }
        return true
    }

    // MARK: - Sync & Rename & Delete

    func syncAuthToAccounts() {
        let fm = FileManager.default
        guard let live = readLiveBundle() else { return }
        if !fm.isReadableFile(atPath: accountsDir) {
            try? fm.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)
        }
        let accounts = listAccounts()

        // 已存在同一 refresh_token → 更新快照
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

        // 发现新账号
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
    }

    func renameAccount(alias: String, to newAliasRaw: String) -> String? {
        let clean = newAliasRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean != alias else { return nil }

        let fm = FileManager.default
        var newAlias = clean
        var i = 1
        let existing = Set(listAccounts().map { $0.alias })
        while existing.contains(newAlias) && newAlias != alias {
            newAlias = "\(clean)\(i)"
            i += 1
        }

        let oldPath = "\(accountsDir)/\(alias).json"
        let newPath = "\(accountsDir)/\(newAlias).json"
        let oldMeta = "\(accountsDir)/\(alias).meta.json"
        let newMeta = "\(accountsDir)/\(newAlias).meta.json"

        do {
            try fm.copyItem(atPath: oldPath, toPath: newPath)
            if fm.fileExists(atPath: oldMeta) {
                try fm.copyItem(atPath: oldMeta, toPath: newMeta)
                try? fm.removeItem(atPath: oldMeta)
            }
            try fm.removeItem(atPath: oldPath)
            if currentAlias() == alias {
                writeCurrentAlias(newAlias)
            }
            return newAlias
        } catch {
            return nil
        }
    }

    func deleteAccount(alias: String) -> Bool {
        guard alias != currentAlias() else { return false }
        let fm = FileManager.default
        let path = "\(accountsDir)/\(alias).json"
        let meta = "\(accountsDir)/\(alias).meta.json"
        let ok = (try? fm.removeItem(atPath: path)) != nil
        try? fm.removeItem(atPath: meta)
        return ok
    }

    // MARK: - Add Account Flow (添加账号功能)

    /// 直接捕获当前 live 的凭据为新账号（如果尚未在列表中）
    func captureCurrentLiveAsNewAccount(alias customAlias: String? = nil) -> (success: Bool, message: String, account: AGAccount?) {
        guard let live = readLiveBundle() else {
            return (false, "未检测到 Antigravity 登录凭据，请先在 Antigravity 中登录", nil)
        }
        let accounts = listAccounts()
        if let existing = accounts.first(where: { $0.refreshToken == live.refreshToken }) {
            return (false, "该账号已经添加过（别名：\(existing.displayName)）", existing)
        }

        var alias = customAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if alias.isEmpty {
            alias = "acc-" + String(Int(Date().timeIntervalSince1970) % 100000)
        }
        let existingAliases = Set(accounts.map { $0.alias })
        var finalAlias = alias
        var i = 1
        while existingAliases.contains(finalAlias) {
            finalAlias = "\(alias)\(i)"
            i += 1
        }

        if saveBundle(live, to: "\(accountsDir)/\(finalAlias).json") {
            writeEmail(alias: finalAlias, email: "识别中…")
            writeCurrentAlias(finalAlias)
            let newAcct = AGAccount(
                alias: finalAlias,
                email: "识别中…",
                authMethod: live.authMethod,
                accessToken: live.accessToken,
                refreshToken: live.refreshToken,
                expiryDate: live.expiryDate
            )
            return (true, "已成功捕获并保存账号 \(finalAlias)", newAcct)
        }
        return (false, "保存凭据文件失败", nil)
    }

    /// 手动导入 JSON 凭据
    func importTokenJSON(_ jsonString: String, alias: String) -> (success: Bool, message: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundle = TokenBundle.from(json: json) else {
            return (false, "凭据 JSON 格式不正确，需包含 token.access_token 和 refresh_token")
        }

        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        var targetAlias = cleanAlias.isEmpty ? "acc-" + String(Int(Date().timeIntervalSince1970) % 100000) : cleanAlias
        let existingAliases = Set(listAccounts().map { $0.alias })
        var i = 1
        let base = targetAlias
        while existingAliases.contains(targetAlias) {
            targetAlias = "\(base)\(i)"
            i += 1
        }

        if saveBundle(bundle, to: "\(accountsDir)/\(targetAlias).json") {
            writeEmail(alias: targetAlias, email: "识别中…")
            return (true, "成功导入账号 \(targetAlias)")
        }
        return (false, "写入账号文件失败")
    }

    /// 引导登录添加账号：备份当前凭据，清空 live 凭据，拉起 Antigravity 触发登录
    func prepareForNewLogin() {
        let current = currentAlias()
        // 1. 确保当前账号已安全持久化到快照
        if let live = readLiveBundle(), !current.isEmpty && current != "?" {
            _ = saveBundle(live, to: "\(accountsDir)/\(current).json")
        }

        // 2. 清空当前 live 凭据（token 文件 + 钥匙串）
        let fm = FileManager.default
        if fm.fileExists(atPath: tokenFile) {
            try? fm.removeItem(atPath: tokenFile)
        }
        clearKeychain()

        // 3. 重启 Antigravity，让其进入登录欢迎页
        quitAntigravity()
        launchAntigravity()
    }

    // MARK: - Process Control

    func quitAntigravity() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName?.lowercased().contains("antigravity") == true) &&
            ($0.bundleURL?.path.hasPrefix("/Applications/Antigravity.app") ?? true) &&
            !$0.isTerminated
        }
        for app in apps {
            app.terminate()
        }
        for _ in 0..<40 {
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
