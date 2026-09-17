import Foundation

class RateLimitClient {
    static let shared = RateLimitClient()

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
            primary = five.min { $0.remaining < $1.remaining }
            secondary = week.min { $0.remaining < $1.remaining }
        }
        return RateLimitInfo(primary: primary, secondary: secondary)
    }
}
