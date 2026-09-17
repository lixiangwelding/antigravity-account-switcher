import AppKit
import SwiftUI

extension NSView {
    func savePNG(to url: URL) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: url)
            print("Saved screenshot to \(url.path)")
        }
    }
}

@main
struct ScreenshotGenerator {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let state = AppState.shared

        let acct1 = AGAccount(
            alias: "1987414957",
            email: "1987414957@gmail.com",
            authMethod: "consumer",
            accessToken: "fake",
            refreshToken: "fake1",
            expiryDate: nil
        )
        let acct2 = AGAccount(
            alias: "2516017911",
            email: "2516017911@gmail.com",
            authMethod: "consumer",
            accessToken: "fake",
            refreshToken: "fake2",
            expiryDate: nil
        )
        let acct3 = AGAccount(
            alias: "mathildacichon33214",
            email: "mathildacichon33214@gmail.com",
            authMethod: "consumer",
            accessToken: "fake",
            refreshToken: "fake3",
            expiryDate: nil
        )

        state.accounts = [acct1, acct2, acct3]
        state.activeAccountID = "mathildacichon33214"

        let now = Date()
        let r1 = RateLimitInfo(
            primary: nil,
            secondary: RateLimitWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(3600 * 40))
        )
        let r2 = RateLimitInfo(
            primary: RateLimitWindow(usedPercent: 24, resetsAt: now.addingTimeInterval(3600 * 1.5)),
            secondary: RateLimitWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(3600 * 48))
        )
        let r3 = RateLimitInfo(
            primary: RateLimitWindow(usedPercent: 0, resetsAt: now.addingTimeInterval(3600 * 4.8)),
            secondary: RateLimitWindow(usedPercent: 95, resetsAt: now.addingTimeInterval(3600 * 55))
        )

        state.usageByAlias = [
            "1987414957": .success(r1),
            "2516017911": .success(r2),
            "mathildacichon33214": .success(r3)
        ]

        let docsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/images")
        try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        func renderView<V: View>(_ view: V, size: NSSize, filename: String) {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear

            let hosting = NSHostingView(rootView:
                view
                    .environmentObject(state)
                    .frame(width: size.width, height: size.height)
                    .cornerRadius(16)
                    .padding(14)
            )
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: size.width + 28, height: size.height + 28))
            window.contentView = hosting
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()

            let outURL = docsDir.appendingPathComponent(filename)
            hosting.savePNG(to: outURL)
        }

        // 1. 主页面
        state.currentPage = .main
        renderView(PopoverRootView(), size: NSSize(width: 326, height: 350), filename: "screenshot-main.png")

        // 2. 管理账号页面 (列表)
        state.currentPage = .manageAccounts
        renderView(PopoverRootView(), size: NSSize(width: 326, height: 320), filename: "screenshot-manage.png")

        // 3. 设置页面
        state.currentPage = .settings
        renderView(PopoverRootView(), size: NSSize(width: 326, height: 430), filename: "screenshot-settings.png")

        print("All screenshots generated successfully!")
    }
}
