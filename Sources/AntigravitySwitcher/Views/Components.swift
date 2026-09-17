import AppKit
import SwiftUI

// MARK: - 毛玻璃背景
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - 圆形头像徽标
struct AccountAvatarView: View {
    let indexText: String
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color(white: 0.28).opacity(0.8) : Color(white: 0.2).opacity(0.6))
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isActive ? 0.25 : 0.1), lineWidth: 1)
                )

            Text(indexText)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - 胶囊进度条 (与截图 1:1 对齐)
struct QuotaProgressBar: View {
    let remaining: Int // 0 ~ 100
    var width: CGFloat = 88
    var height: CGFloat = 4.5

    var barColor: Color {
        if remaining <= 10 {
            return Color(red: 0.96, green: 0.28, blue: 0.28)
        } else if remaining <= 25 {
            return Color(red: 0.98, green: 0.62, blue: 0.2)
        } else {
            // 截图中的现代亮蓝
            return Color(red: 0.15, green: 0.53, blue: 1.0)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // 轨道底色
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: width, height: height)

            // 填充色
            let fillWidth = max(0, min(CGFloat(remaining) / 100.0 * width, width))
            Capsule()
                .fill(barColor)
                .frame(width: fillWidth, height: height)
        }
    }
}

// MARK: - 时间格式化
func formatResetTime(_ date: Date?) -> String {
    guard let d = date else { return "" }
    let now = Date()
    let cal = Calendar.current

    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")

    // 如果是今天 24 小时以内
    if cal.isDateInToday(d) || (d.timeIntervalSince(now) < 18 * 3600 && d.timeIntervalSince(now) > 0) {
        df.dateFormat = "HH:mm"
        return "重置于 \(df.string(from: d))"
    } else {
        // 例如 Sep 19 at 21:46
        df.dateFormat = "MMM d 'at' HH:mm"
        return "重置于 \(df.string(from: d))"
    }
}
