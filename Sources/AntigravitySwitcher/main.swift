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
        statusItem.autosaveName = "AntigravitySwitcherItem"
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItemAppearance()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 356, height: 460)
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
        let symbolName: String
        switch state {
        case 2:
            symbolName = "exclamationmark.triangle"
        case 1:
            symbolName = "sparkle"
        default:
            symbolName = "sparkles"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Antigravity Switcher")?.withSymbolConfiguration(config) {
            sym.isTemplate = true
            return sym
        }

        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.black.setFill()

        let path = NSBezierPath()
        let cx = s * 0.5
        let cy = s * 0.5
        let rOuter: CGFloat = 7.5
        let rInner: CGFloat = 2.2

        path.move(to: NSPoint(x: cx, y: cy + rOuter))
        path.curve(to: NSPoint(x: cx + rOuter, y: cy),
                   controlPoint1: NSPoint(x: cx + rInner, y: cy + rInner),
                   controlPoint2: NSPoint(x: cx + rInner, y: cy + rInner))
        path.curve(to: NSPoint(x: cx, y: cy - rOuter),
                   controlPoint1: NSPoint(x: cx + rInner, y: cy - rInner),
                   controlPoint2: NSPoint(x: cx + rInner, y: cy - rInner))
        path.curve(to: NSPoint(x: cx - rOuter, y: cy),
                   controlPoint1: NSPoint(x: cx - rInner, y: cy - rInner),
                   controlPoint2: NSPoint(x: cx - rInner, y: cy - rInner))
        path.curve(to: NSPoint(x: cx, y: cy + rOuter),
                   controlPoint1: NSPoint(x: cx - rInner, y: cy + rInner),
                   controlPoint2: NSPoint(x: cx - rInner, y: cy + rInner))
        path.close()
        path.fill()

        img.unlockFocus()
        img.isTemplate = true
        return img
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
