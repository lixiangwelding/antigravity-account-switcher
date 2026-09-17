import Foundation

class RateLimitClient {
    static let shared = RateLimitClient()

    private let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let clientSecret = "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"
    private let tokenURL = "https://oauth2.googleapis.com/token"

    // 关键修正：Antigravity 真实日常动态配额端点，带实时 remainingFraction 消耗！
    private let quotaURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    private let codeAssistURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private let userinfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    var usageByAlias: [String: FetchState] = [:]
    var lastFetchTime: Date?
    var onUpdate: (() -> Void)?

    func fetchAll(_ accounts: [AGAccount]) {
        lastFetchTime = Date()
        for acct in accounts {
            if acct.refreshToken.isEmpty {
                usageByAlias[acct.alias] = .failed("缺少刷新凭据")
                continue
            }
            if usageByAlias[acct.alias] == nil {
                usageByAlias[acct.alias] = .loading
            }
            fetchForAccount(acct)
        }
        DispatchQueue.main.async { self.onUpdate?() }
    }

    func refreshIfNeeded(_ accounts: [AGAccount], minInterval: TimeInterval) {
        if let last = lastFetchTime, Date().timeIntervalSince(last) < minInterval { return }
        fetchAll(accounts)
    }

    func fetchForAccount(_ acct: AGAccount) {
        let auth = AntigravityAuthManager.shared
        let alias = acct.alias

        func proceed(with access: String) {
            self.fetchQuota(access: access, alias: alias)
            self.fetchPlan(access: access, alias: alias)
            if auth.readEmail(alias: alias) == "?" || auth.readEmail(alias: alias) == "识别中…" {
                self.resolveEmail(access: access, alias: alias)
            }
        }

        guard let bundle = auth.readTokenBundle("\(auth.accountsDir)/\(alias).json") else {
            setState(alias, .failed("未找到凭据文件"))
            return
        }

        if let exp = bundle.expiryDate, exp > Date().addingTimeInterval(120), !bundle.accessToken.isEmpty {
            proceed(with: bundle.accessToken)
        } else {
            refreshBundle(bundle) { fresh in
                guard let fresh = fresh else {
                    self.setState(alias, .failed("Token 刷新失败"))
                    return
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
                  let at = json["access_token"] as? String else {
                completion(nil)
                return
            }
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
            if error != nil { self.setState(alias, .failed("网络错误")); return }
            guard let http = response as? HTTPURLResponse, let data = data else {
                self.setState(alias, .failed("无响应")); return
            }
            if http.statusCode == 401 { self.setState(alias, .failed("Token 已过期")); return }
            if http.statusCode != 200 { self.setState(alias, .failed("HTTP \(http.statusCode)")); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.setState(alias, .failed("解析失败")); return
            }
            self.setState(alias, .success(self.parseResponse(json)))
        }.resume()
    }

    /// 获取账号当前 Plan（PRO / FREE / ULTRA）
    private func fetchPlan(access: String, alias: String) {
        guard let url = URL(string: codeAssistURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let paidTier = json["paidTier"] as? [String: Any] ?? [:]
            let userTier = json["userTier"] as? [String: Any] ?? [:]
            let currentTier = json["currentTier"] as? [String: Any] ?? [:]

            let allTierStrings = [
                paidTier["id"] as? String ?? "",
                paidTier["name"] as? String ?? "",
                userTier["id"] as? String ?? "",
                userTier["name"] as? String ?? "",
                currentTier["id"] as? String ?? "",
                currentTier["name"] as? String ?? "",
                json["g1Tier"] as? String ?? ""
            ].map { $0.lowercased() }

            var plan = "FREE"
            if allTierStrings.contains(where: { $0.contains("ultra") }) {
                plan = "ULTRA"
            } else if allTierStrings.contains(where: { $0.contains("pro") }) {
                plan = "PRO"
            } else if allTierStrings.contains(where: { $0.contains("standard") }) {
                plan = "STANDARD"
            } else {
                plan = "FREE"
            }

            DispatchQueue.main.async {
                let auth = AntigravityAuthManager.shared
                let meta = auth.readMeta(alias: alias)
                if meta["plan"] as? String != plan {
                    auth.writePlan(alias: alias, plan: plan)
                    AppState.shared.reloadAccounts()
                }
            }
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
                if alias.hasPrefix("acc-") {
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
        DispatchQueue.main.async {
            self.usageByAlias[alias] = state
            self.onUpdate?()
        }
    }

    private func parseResponse(_ json: [String: Any]) -> RateLimitInfo {
        var primary: RateLimitWindow? = nil
        var secondary: RateLimitWindow? = nil
        var claudePrimary: RateLimitWindow? = nil
        var claudeSecondary: RateLimitWindow? = nil

        if let groups = json["groups"] as? [[String: Any]] {
            for g in groups {
                let groupName = (g["displayName"] as? String ?? "").lowercased()
                guard let buckets = g["buckets"] as? [[String: Any]] else { continue }

                var fiveWindow: RateLimitWindow?
                var weeklyWindow: RateLimitWindow?

                for b in buckets {
                    let window = b["window"] as? String ?? ""
                    guard let frac = b["remainingFraction"] as? Double else { continue }
                    let remaining = Int((frac * 100).rounded())
                    let reset = (b["resetTime"] as? String).flatMap { parseISO($0) }
                    let w = RateLimitWindow(usedPercent: 100 - remaining, resetsAt: reset)
                    if window == "5h" {
                        fiveWindow = w
                    } else if window == "weekly" {
                        weeklyWindow = w
                    }
                }

                if groupName.contains("gemini") {
                    // 主模型配额（对应 Antigravity 核心 Gemini 模型池）
                    primary = fiveWindow
                    secondary = weeklyWindow
                } else if groupName.contains("claude") || groupName.contains("gpt") {
                    // 第三方模型配额
                    claudePrimary = fiveWindow
                    claudeSecondary = weeklyWindow
                }
            }

            // 兜底：如果没匹配到具体名称，使用遍历出来的非空值
            if primary == nil {
                primary = claudePrimary
            }
            if secondary == nil {
                secondary = claudeSecondary
            }
        }
        return RateLimitInfo(
            primary: primary,
            secondary: secondary,
            claudePrimary: claudePrimary,
            claudeSecondary: claudeSecondary,
            planType: nil
        )
    }
}
