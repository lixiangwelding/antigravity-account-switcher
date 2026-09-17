import AppKit
import Foundation
import SwiftUI

// MARK: - Token Bundle

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
    let fmts = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZZZ",
        "yyyy-MM-dd'T'HH:mm:ssZZZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss"
    ]
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

// MARK: - Account Model

struct AGAccount: Identifiable, Hashable {
    var id: String { alias }
    let alias: String
    var email: String
    var plan: String
    let authMethod: String
    var accessToken: String
    var refreshToken: String
    var expiryDate: Date?

    var displayName: String {
        if !alias.isEmpty && !alias.hasPrefix("acc-") {
            return alias
        }
        if email != "?" && email != "识别中…" && !email.isEmpty {
            return email.components(separatedBy: "@").first ?? email
        }
        return alias
    }

    var displaySubtext: String {
        if email != "?" && email != "识别中…" && !email.isEmpty {
            return email
        }
        return alias
    }

    var avatarLetter: String {
        let name = displayName
        if let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }

    var planLabel: String {
        let p = plan.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return p.isEmpty ? "FREE" : p
    }

    var planColor: Color {
        switch planLabel {
        case "PRO":
            return Color(red: 0.78, green: 0.45, blue: 1.0)
        case "ULTRA":
            return Color(red: 1.0, green: 0.65, blue: 0.2)
        default:
            return Color(red: 0.35, green: 0.65, blue: 1.0)
        }
    }

    var planBackgroundColor: Color {
        switch planLabel {
        case "PRO":
            return Color(red: 0.68, green: 0.3, blue: 0.95).opacity(0.2)
        case "ULTRA":
            return Color(red: 0.95, green: 0.55, blue: 0.1).opacity(0.2)
        default:
            return Color(red: 0.25, green: 0.55, blue: 0.95).opacity(0.16)
        }
    }
}

// MARK: - Rate Limit Models

struct RateLimitWindow: Hashable {
    let usedPercent: Int
    let resetsAt: Date?

    var remaining: Int { 100 - min(max(usedPercent, 0), 100) }

    var barColor: NSColor {
        if remaining <= 10 { return NSColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1.0) }
        if remaining <= 25 { return NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1.0) }
        return NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 1.0)
    }

    var textColor: NSColor {
        if remaining <= 10 { return NSColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1.0) }
        if remaining <= 25 { return NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1.0) }
        return .white
    }
}

struct RateLimitInfo: Hashable {
    let primary: RateLimitWindow?   // 5 小时窗口 (Gemini)
    let secondary: RateLimitWindow? // 7 天窗口 (Gemini)
    let claudePrimary: RateLimitWindow?   // 5 小时窗口 (Claude & GPT)
    let claudeSecondary: RateLimitWindow? // 7 天窗口 (Claude & GPT)
    let planType: String?
}

enum FetchState: Hashable {
    case idle
    case loading
    case success(RateLimitInfo)
    case failed(String)
}

// MARK: - App Config

struct AppConfig: Codable, Equatable {
    var refreshIntervalMinutes: Int = 30
    var minRefreshIntervalSeconds: Int = 30
    var alert5hThreshold: Int = 30    // 5h 剩余低于该值告警
    var alertWeekThreshold: Int = 10  // 7天 剩余低于该值告警
    var restartAntigravity: Bool = true
    var showMenuBarPercentage: Bool = false

    private static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.antigravity-switcher/config.json"
    }()

    static func load() -> AppConfig {
        var config = AppConfig()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }
        if let v = json["refresh_interval_minutes"] as? Int, v >= 0 { config.refreshIntervalMinutes = v }
        if let v = json["min_refresh_interval_seconds"] as? Int, v > 0 { config.minRefreshIntervalSeconds = v }
        if let v = json["alert_5h_threshold"] as? Int { config.alert5hThreshold = v }
        if let v = json["alert_week_threshold"] as? Int { config.alertWeekThreshold = v }
        if let v = json["restart_antigravity"] as? Bool { config.restartAntigravity = v }
        if let v = json["show_menu_bar_percentage"] as? Bool { config.showMenuBarPercentage = v }
        return config
    }

    func save() {
        let json: [String: Any] = [
            "refresh_interval_minutes": refreshIntervalMinutes,
            "min_refresh_interval_seconds": minRefreshIntervalSeconds,
            "alert_5h_threshold": alert5hThreshold,
            "alert_week_threshold": alertWeekThreshold,
            "restart_antigravity": restartAntigravity,
            "show_menu_bar_percentage": showMenuBarPercentage
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: AppConfig.configPath))
        }
    }
}
