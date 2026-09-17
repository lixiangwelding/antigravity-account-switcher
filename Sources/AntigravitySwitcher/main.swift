import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState.shared
    private let authManager = AntigravityAuthManager.shared
    private let quotaClient = RateLimitClient.shared

    private var refreshTimer: Timer?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var tokenFileMonitor: DispatchSourceFileSystemObject?
    private var lastFileEventTime: Date = .distantPast
    private var previousAlertState: (p5h: Bool, pWk: Bool) = (false, false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 请求通知权限
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 同步当前凭据
        authManager.syncAuthToAccounts()
        appState.reloadAccounts()

        // 构建状态栏图标与 Popover
        setupStatusItem()
        setupPopover()

        // 监听凭据文件变化
        watchAuthFiles()

        // 启动配额刷新与定时任务
        quotaClient.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.usageByAlias = self?.quotaClient.usageByAlias ?? [:]
                self?.updateStatusItemAppearance()
            }
        }
        quotaClient.fetchAll(authManager.listAccounts())
        scheduleTimer()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItemAppearance()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 304, height: 360)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let hosting = NSHostingController(rootView: PopoverRootView())
        popover.contentViewController = hosting
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        // 右键或特定事件依然保持唤出
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // 打开时默认回到主界面
            appState.currentPage = .main
            appState.reloadAccounts()

            // 智能刷新
            let minInterval = TimeInterval(appState.config.minRefreshIntervalSeconds)
            quotaClient.refreshIfNeeded(authManager.listAccounts(), minInterval: minInterval)

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        appState.reloadAccounts()
    }

    // MARK: - 定时器与告警

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let mins = appState.config.refreshIntervalMinutes
        guard mins > 0 else { return }
        let interval = TimeInterval(mins * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.quotaClient.fetchAll(self.authManager.listAccounts())
        }
    }

    // MARK: - 状态栏图标与提示

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let current = authManager.currentAlias()
        let active = authManager.listAccounts().first { $0.alias == current }
        var alert5h = false
        var alertWk = false
        var remaining5h = 100

        if let acct = active, case .success(let rl) = quotaClient.usageByAlias[acct.alias] {
            let p5h = rl.primary?.remaining ?? 100
            let pWk = rl.secondary?.remaining ?? 100
            remaining5h = p5h
            alert5h = p5h < appState.config.alert5hThreshold
            alertWk = pWk < appState.config.alertWeekThreshold

            if alert5h && !previousAlertState.p5h {
                sendNotification(title: "\(acct.displayName) - 5小时配额低", body: "5小时剩余仅 \(p5h)%")
            }
            if alertWk && !previousAlertState.pWk {
                sendNotification(title: "\(acct.displayName) - 7天配额低", body: "7天剩余仅 \(pWk)%")
            }
            previousAlertState = (alert5h, alertWk)

            button.toolTip = "Antigravity: \(acct.displayName) | 5小时: \(p5h)% | 7天: \(pWk)%"
        } else {
            button.toolTip = "Antigravity: \(active?.displayName ?? current)"
        }

        let iconState = alertWk ? 2 : (alert5h ? 1 : 0)
        button.image = makeMenuBarIcon(state: iconState)
        button.image?.isTemplate = true

        if appState.config.showMenuBarPercentage {
            button.title = " \(remaining5h)%"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func makeMenuBarIcon(state: Int) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        switch state {
        case 2:
            drawLyingAI(s: s)
        case 1:
            drawTiredAI(s: s)
        default:
            drawStandingAI(s: s)
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func drawStandingAI(s: CGFloat) {
        let cx = s * 0.5
        let antennaPath = NSBezierPath()
        antennaPath.move(to: NSPoint(x: cx, y: s * 0.78))
        antennaPath.line(to: NSPoint(x: cx, y: s * 0.88))
        antennaPath.lineWidth = 1.2
        antennaPath.lineCapStyle = .round
        antennaPath.stroke()
        NSBezierPath(ovalIn: NSRect(x: cx - 1.5, y: s * 0.88, width: 3, height: 3)).fill()

        let headR: CGFloat = s * 0.15
        let headY = s * 0.65
        NSBezierPath(ovalIn: NSRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)).stroke()
        let eyeR: CGFloat = 1.2
        NSBezierPath(ovalIn: NSRect(x: cx - headR * 0.5 - eyeR, y: headY + headR * 0.7, width: eyeR * 2, height: eyeR * 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx + headR * 0.5 - eyeR, y: headY + headR * 0.7, width: eyeR * 2, height: eyeR * 2)).fill()

        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: cx, y: headY))
        bodyPath.line(to: NSPoint(x: cx, y: s * 0.28))
        bodyPath.lineWidth = 1.5
        bodyPath.lineCapStyle = .round
        bodyPath.stroke()

        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: cx, y: s * 0.52))
        armPath.line(to: NSPoint(x: cx - s * 0.2, y: s * 0.6))
        armPath.move(to: NSPoint(x: cx, y: s * 0.52))
        armPath.line(to: NSPoint(x: cx + s * 0.2, y: s * 0.6))
        armPath.lineWidth = 1.3
        armPath.lineCapStyle = .round
        armPath.stroke()

        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: cx, y: s * 0.28))
        legPath.line(to: NSPoint(x: cx - s * 0.14, y: s * 0.08))
        legPath.move(to: NSPoint(x: cx, y: s * 0.28))
        legPath.line(to: NSPoint(x: cx + s * 0.14, y: s * 0.08))
        legPath.lineWidth = 1.3
        legPath.lineCapStyle = .round
        legPath.stroke()
    }

    private func drawTiredAI(s: CGFloat) {
        let cx = s * 0.5
        let antennaPath = NSBezierPath()
        antennaPath.move(to: NSPoint(x: cx, y: s * 0.75))
        antennaPath.line(to: NSPoint(x: cx - s * 0.05, y: s * 0.83))
        antennaPath.lineWidth = 1.2
        antennaPath.lineCapStyle = .round
        antennaPath.stroke()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.05 - 1.5, y: s * 0.82, width: 3, height: 3)).fill()

        let headR: CGFloat = s * 0.15
        let headY = s * 0.6
        NSBezierPath(ovalIn: NSRect(x: cx - headR - s * 0.02, y: headY, width: headR * 2, height: headR * 2)).stroke()
        let eyePath = NSBezierPath()
        eyePath.move(to: NSPoint(x: cx - headR * 0.7, y: headY + headR * 0.85))
        eyePath.line(to: NSPoint(x: cx - headR * 0.1, y: headY + headR * 0.75))
        eyePath.move(to: NSPoint(x: cx + headR * 0.1, y: headY + headR * 0.85))
        eyePath.line(to: NSPoint(x: cx + headR * 0.7, y: headY + headR * 0.75))
        eyePath.lineWidth = 1.0
        eyePath.lineCapStyle = .round
        eyePath.stroke()

        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: cx - s * 0.02, y: headY))
        bodyPath.curve(to: NSPoint(x: cx, y: s * 0.24),
                       controlPoint1: NSPoint(x: cx + s * 0.05, y: s * 0.5),
                       controlPoint2: NSPoint(x: cx - s * 0.05, y: s * 0.35))
        bodyPath.lineWidth = 1.5
        bodyPath.lineCapStyle = .round
        bodyPath.stroke()

        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: cx, y: s * 0.48))
        armPath.line(to: NSPoint(x: cx - s * 0.18, y: s * 0.32))
        armPath.move(to: NSPoint(x: cx, y: s * 0.48))
        armPath.line(to: NSPoint(x: cx + s * 0.18, y: s * 0.32))
        armPath.lineWidth = 1.3
        armPath.lineCapStyle = .round
        armPath.stroke()

        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: cx, y: s * 0.24))
        legPath.line(to: NSPoint(x: cx - s * 0.12, y: s * 0.06))
        legPath.move(to: NSPoint(x: cx, y: s * 0.24))
        legPath.line(to: NSPoint(x: cx + s * 0.12, y: s * 0.06))
        legPath.lineWidth = 1.3
        legPath.lineCapStyle = .round
        legPath.stroke()

        NSBezierPath(ovalIn: NSRect(x: cx + headR + 1, y: headY + headR * 0.5, width: 2, height: 3)).fill()
    }

    private func drawLyingAI(s: CGFloat) {
        let cy = s * 0.38
        let groundPath = NSBezierPath()
        groundPath.move(to: NSPoint(x: s * 0.05, y: s * 0.15))
        groundPath.line(to: NSPoint(x: s * 0.95, y: s * 0.15))
        groundPath.lineWidth = 0.8
        groundPath.lineCapStyle = .round
        groundPath.stroke()

        let headR: CGFloat = s * 0.13
        let headX = s * 0.75
        NSBezierPath(ovalIn: NSRect(x: headX, y: cy - headR + s * 0.02, width: headR * 2, height: headR * 2)).stroke()
        let exPath = NSBezierPath()
        let eyeCx1 = headX + headR * 0.6
        let eyeCx2 = headX + headR * 1.4
        let eyeCy = cy + s * 0.05
        let ex: CGFloat = 1.5
        exPath.move(to: NSPoint(x: eyeCx1 - ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx1 + ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx1 + ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx1 - ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx2 - ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx2 + ex, y: eyeCy + ex))
        exPath.move(to: NSPoint(x: eyeCx2 + ex, y: eyeCy - ex)); exPath.line(to: NSPoint(x: eyeCx2 - ex, y: eyeCy + ex))
        exPath.lineWidth = 1.0
        exPath.lineCapStyle = .round
        exPath.stroke()

        let bodyPath = NSBezierPath()
        bodyPath.move(to: NSPoint(x: headX, y: cy))
        bodyPath.line(to: NSPoint(x: s * 0.28, y: cy))
        bodyPath.lineWidth = 1.5
        bodyPath.lineCapStyle = .round
        bodyPath.stroke()

        let legPath = NSBezierPath()
        legPath.move(to: NSPoint(x: s * 0.28, y: cy))
        legPath.line(to: NSPoint(x: s * 0.15, y: cy + s * 0.1))
        legPath.move(to: NSPoint(x: s * 0.28, y: cy))
        legPath.line(to: NSPoint(x: s * 0.12, y: cy - s * 0.08))
        legPath.lineWidth = 1.3
        legPath.lineCapStyle = .round
        legPath.stroke()

        let armPath = NSBezierPath()
        armPath.move(to: NSPoint(x: s * 0.55, y: cy))
        armPath.line(to: NSPoint(x: s * 0.5, y: cy + s * 0.15))
        armPath.move(to: NSPoint(x: s * 0.45, y: cy))
        armPath.line(to: NSPoint(x: s * 0.42, y: cy - s * 0.12))
        armPath.lineWidth = 1.3
        armPath.lineCapStyle = .round
        armPath.stroke()

        let zFont = NSFont.systemFont(ofSize: 6, weight: .bold)
        ("z" as NSString).draw(at: NSPoint(x: s * 0.82, y: s * 0.6), withAttributes: [
            .font: zFont, .foregroundColor: NSColor.black
        ])
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - 文件监听

    private func onAuthChanged() {
        let now = Date()
        guard now.timeIntervalSince(lastFileEventTime) > 2 else { return }
        lastFileEventTime = now
        authManager.syncAuthToAccounts()
        appState.reloadAccounts()
        updateStatusItemAppearance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.quotaClient.fetchAll(self.authManager.listAccounts())
        }
    }

    private func watchAuthFiles() {
        let geminiDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        let dirFd = open(geminiDir.path, O_EVTONLY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                self?.onAuthChanged()
                self?.watchTokenFile()
            }
            source.setCancelHandler { close(dirFd) }
            source.resume()
            fileMonitor = source
        }
        watchTokenFile()
    }

    private func watchTokenFile() {
        tokenFileMonitor?.cancel()
        tokenFileMonitor = nil
        let authPath = authManager.tokenFile
        let authFd = open(authPath, O_EVTONLY)
        guard authFd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: authFd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.onAuthChanged()
            self?.watchTokenFile()
        }
        source.setCancelHandler { close(authFd) }
        source.resume()
        tokenFileMonitor = source
    }
}

// MARK: - Main Application Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
