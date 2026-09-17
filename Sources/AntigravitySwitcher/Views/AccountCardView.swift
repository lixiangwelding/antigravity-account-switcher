import SwiftUI

struct AccountCardView: View {
    let account: AGAccount
    let index: Int
    let isActive: Bool
    let usageState: FetchState?
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var indexLabel: String {
        let name = account.displayName
        // 如果是纯数字或首字母，类似截图中的 1, 2, M
        if let first = name.first, first.isLetter {
            return String(first).uppercased()
        }
        return "\(index)"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                // 左侧圆形头像
                AccountAvatarView(indexText: indexLabel, isActive: isActive)
                    .padding(.top, 2)

                // 右侧账号信息与用量
                VStack(alignment: .leading, spacing: 6) {
                    // 账号主名称与 Plan 徽标
                    HStack(spacing: 6) {
                        Text(account.displayName)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(account.planLabel)
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundColor(account.planColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(account.planBackgroundColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(account.planColor.opacity(0.35), lineWidth: 0.5)
                            )
                    }

                    // 5小时与7天用量
                    switch usageState {
                    case .success(let info):
                        VStack(alignment: .leading, spacing: 4) {
                            // Gemini 模型组
                            if let primary = info.primary {
                                HStack(spacing: 5) {
                                    Text("Gemini 5h")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Color(white: 0.7))
                                        .frame(width: 58, alignment: .leading)

                                    QuotaProgressBar(remaining: primary.remaining, width: 62)

                                    Text("\(primary.remaining)%")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Color(primary.textColor))
                                        .frame(width: 30, alignment: .trailing)

                                    if let reset = primary.resetsAt {
                                        Text(formatResetTime(reset))
                                            .font(.system(size: 8.5))
                                            .foregroundColor(Color(white: 0.45))
                                            .lineLimit(1)
                                    }
                                }
                            }

                            if let secondary = info.secondary {
                                HStack(spacing: 5) {
                                    Text("Gemini 7d")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Color(white: 0.7))
                                        .frame(width: 58, alignment: .leading)

                                    QuotaProgressBar(remaining: secondary.remaining, width: 62)

                                    Text("\(secondary.remaining)%")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Color(secondary.textColor))
                                        .frame(width: 30, alignment: .trailing)

                                    if let reset = secondary.resetsAt {
                                        Text(formatResetTime(reset))
                                            .font(.system(size: 8.5))
                                            .foregroundColor(Color(white: 0.45))
                                            .lineLimit(1)
                                    }
                                }
                            }

                            // Claude / 3P 模型组（如果有且不同于主模型）
                            if let cp = info.claudePrimary {
                                HStack(spacing: 5) {
                                    Text("Claude 5h")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Color(red: 0.85, green: 0.65, blue: 0.95))
                                        .frame(width: 58, alignment: .leading)

                                    QuotaProgressBar(remaining: cp.remaining, width: 62)

                                    Text("\(cp.remaining)%")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Color(cp.textColor))
                                        .frame(width: 30, alignment: .trailing)

                                    if let reset = cp.resetsAt {
                                        Text(formatResetTime(reset))
                                            .font(.system(size: 8.5))
                                            .foregroundColor(Color(white: 0.45))
                                            .lineLimit(1)
                                    }
                                }
                            }

                            if let cs = info.claudeSecondary {
                                HStack(spacing: 5) {
                                    Text("Claude 7d")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Color(red: 0.85, green: 0.65, blue: 0.95))
                                        .frame(width: 58, alignment: .leading)

                                    QuotaProgressBar(remaining: cs.remaining, width: 62)

                                    Text("\(cs.remaining)%")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Color(cs.textColor))
                                        .frame(width: 30, alignment: .trailing)

                                    if let reset = cs.resetsAt {
                                        Text(formatResetTime(reset))
                                            .font(.system(size: 8.5))
                                            .foregroundColor(Color(white: 0.45))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                    case .loading:
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                            Text("正在获取配额…")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.5))
                        }
                        .padding(.vertical, 4)

                    case .failed(let reason):
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0.95, green: 0.5, blue: 0.3))
                            .lineLimit(1)
                            .padding(.vertical, 2)

                    case .idle, .none:
                        HStack(spacing: 6) {
                            Text("5 小时")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.5))
                                .frame(width: 36, alignment: .leading)
                            QuotaProgressBar(remaining: 100, width: 84)
                            Text("100%")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(white: 0.6))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isActive {
                        // 1:1 还原选中的夜空深蓝发光卡片
                        LinearGradient(
                            colors: [
                                Color(red: 0.11, green: 0.22, blue: 0.38).opacity(0.88),
                                Color(red: 0.08, green: 0.16, blue: 0.28).opacity(0.88)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        // 普通卡片底色及悬停提亮
                        Color.white.opacity(isHovered ? 0.09 : 0.05)
                    }
                }
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isActive
                            ? Color(red: 0.25, green: 0.55, blue: 0.95).opacity(0.4)
                            : Color.white.opacity(isHovered ? 0.14 : 0.08),
                        lineWidth: isActive ? 1.0 : 0.5
                    )
            )
            .shadow(
                color: isActive ? Color(red: 0.2, green: 0.5, blue: 1.0).opacity(0.2) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { h in
            isHovered = h
        }
    }
}
