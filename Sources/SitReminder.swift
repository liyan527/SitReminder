import SwiftUI
import AppKit
import ServiceManagement
import CoreGraphics

// MARK: - App 入口（菜单栏应用，无 Dock 图标）

#if !PREVIEW
@main
struct SitReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = ReminderState.shared

    var body: some Scene {
        MenuBarExtra {
            SettingsPanel()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let state = ReminderState.shared
            state.firstLaunchSetup()
            state.start()
            if CommandLine.arguments.contains("--test-reminder") {
                state.remindNow(preview: true)
            }
        }
    }
}

// MARK: - 状态与计时逻辑

@MainActor
final class ReminderState: ObservableObject {
    static let shared = ReminderState()

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); resetCycle("设置: 开关=\(enabled)") }
    }
    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Keys.interval); resetCycle("设置: 间隔=\(intervalMinutes)分钟") }
    }
    @Published var restMinutes: Int {
        didSet { defaults.set(restMinutes, forKey: Keys.rest) }
    }
    @Published var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: Keys.snooze) }
    }
    @Published var awayResetMinutes: Int {
        didSet { defaults.set(awayResetMinutes, forKey: Keys.awayReset) }
    }
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.sound) }
    }

    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var isAway = false
    @Published private(set) var reminderShowing = false
    @Published private(set) var isLocked = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNote: String = ""

    let rest = RestSession()
    private var nextFire = Date()
    private var lastTick = Date()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var sleepStart: Date?
    private var pendingSleep: TimeInterval = 0
    private var lockedAt: Date?
    private var lastHeartbeat = Date()
    let overlay = OverlayController()

    var nextFireDate: Date { nextFire }

    #if PREVIEW
    func previewSet(remaining: Int) {
        nextFire = Date().addingTimeInterval(TimeInterval(remaining))
        remainingSeconds = remaining
    }
    #endif

    private enum Keys {
        static let enabled = "enabled"
        static let interval = "intervalMinutes"
        static let rest = "restMinutes"
        static let snooze = "snoozeMinutes"
        static let awayReset = "awayResetMinutes"
        static let sound = "playSound"
        static let initialized = "initialized"
        static let loginStatus = "loginItemStatus"
    }

    private init() {
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.interval: 45,
            Keys.rest: 3,
            Keys.snooze: 5,
            Keys.awayReset: 5,
            Keys.sound: true,
        ])
        enabled = defaults.bool(forKey: Keys.enabled)
        intervalMinutes = defaults.integer(forKey: Keys.interval)
        restMinutes = defaults.integer(forKey: Keys.rest)
        snoozeMinutes = defaults.integer(forKey: Keys.snooze)
        awayResetMinutes = defaults.integer(forKey: Keys.awayReset)
        playSound = defaults.bool(forKey: Keys.sound)
    }

    // 首次启动默认开启“开机自启”
    func firstLaunchSetup() {
        if !defaults.bool(forKey: Keys.initialized) {
            defaults.set(true, forKey: Keys.initialized)
            setLaunchAtLogin(true)
        } else {
            refreshLoginStatus()
        }
    }

    func start() {
        Log.write("启动: 间隔=\(intervalMinutes)分钟 休息=\(restMinutes)分钟 离开阈值=\(awayResetMinutes)分钟")
        // 菜单栏应用没有可见窗口，会被 App Nap 节流，计时器可能几分钟才触发一次。这里禁止 App Nap。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "久坐提醒计时")
        // 系统睡眠时长由睡眠/唤醒通知计算，不再用计时间隔推断
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReminderState.shared.systemWillSleep() }
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReminderState.shared.systemDidWake() }
        }
        // 锁屏时停止计时器，解锁后再恢复
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReminderState.shared.screenLocked() }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReminderState.shared.screenUnlocked() }
        }
        resetCycle("启动")
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        lastTick = Date()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ReminderState.shared.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func screenLocked() {
        guard lockedAt == nil else { return }
        lockedAt = Date()
        isLocked = true
        timer?.invalidate()
        timer = nil
        Log.write("锁屏: 停止计时，剩余 \(remainingSeconds) 秒")
    }

    private func screenUnlocked() {
        guard let t = lockedAt else { return }
        let locked = Date().timeIntervalSince(t)
        lockedAt = nil
        isLocked = false
        pendingSleep = 0          // 锁屏期间的睡眠已包含在锁屏时长里
        isAway = false
        Log.write("解锁: 锁屏 \(Int(locked)) 秒")
        let awayThreshold = TimeInterval(awayResetMinutes * 60)
        if reminderShowing {
            // 锁屏时间算作休息
            if locked >= awayThreshold || locked >= TimeInterval(rest.remaining) {
                finishRest("锁屏期间已休息")
            } else {
                rest.tick(idle: 99, credit: locked)
            }
        } else if locked >= awayThreshold {
            resetCycle("锁屏后解锁")
        } else {
            // 短暂锁屏：从暂停处接着计时
            nextFire = nextFire.addingTimeInterval(locked)
            Log.write("短暂锁屏，接着计时: 下次提醒 \(Log.time(nextFire))")
        }
        startTimer()
    }

    private func systemWillSleep() {
        guard lockedAt == nil else { return }
        sleepStart = Date()
        Log.write("系统睡眠")
    }

    private func systemDidWake() {
        guard lockedAt == nil else { sleepStart = nil; return }
        if let s = sleepStart {
            pendingSleep += Date().timeIntervalSince(s)
        }
        sleepStart = nil
        Log.write("系统唤醒: 睡眠 \(Int(pendingSleep)) 秒")
    }

    func resetCycle(_ reason: String) {
        nextFire = Date().addingTimeInterval(TimeInterval(intervalMinutes * 60))
        remainingSeconds = intervalMinutes * 60
        Log.write("重新计时(\(reason)): 下次提醒 \(Log.time(nextFire))")
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(lastTick)
        lastTick = now
        let idle = Self.systemIdleSeconds()
        let slept = pendingSleep
        pendingSleep = 0

        if gap > 10 && slept == 0 {
            Log.write("警告: 计时间隔 \(Int(gap)) 秒，空闲 \(Int(idle)) 秒")
        }
        if now.timeIntervalSince(lastHeartbeat) >= 600 {
            lastHeartbeat = now
            Log.write("心跳: 剩余 \(remainingSeconds) 秒 空闲 \(Int(idle)) 秒 离开=\(isAway) 提醒中=\(reminderShowing)")
        }

        // 强制休息进行中
        if reminderShowing {
            let wasCompleted = rest.completed
            // 只有没碰键鼠的时间才算休息；系统睡眠时间也算
            let credit = (idle >= 1.5 ? min(gap, idle) : 0) + slept
            rest.tick(idle: idle, credit: credit)
            if rest.completed && !wasCompleted && playSound {
                NSSound(named: "Hero")?.play()
            }
            if rest.completed && !wasCompleted { Log.write("休息完成") }
            // 休息完成后，回到电脑前动一下键鼠即自动开始新一轮
            if wasCompleted && idle < 1.2 {
                finishRest("休息完成后回到电脑")
            }
            return
        }

        // 离开电脑（无键鼠操作或系统睡眠）超过阈值，视为已经起身休息
        let awayThreshold = TimeInterval(awayResetMinutes * 60)
        if !isAway && max(idle, slept) >= awayThreshold {
            isAway = true
            Log.write("判定离开: 空闲 \(Int(idle)) 秒 睡眠 \(Int(slept)) 秒")
        }
        // 回到电脑前：重新开始计时
        if isAway && idle < 3 {
            isAway = false
            resetCycle("离开后回来")
            return
        }

        if let until = pausedUntil {
            if now < until {
                remainingSeconds = Int(until.timeIntervalSince(now))
                return
            }
            pausedUntil = nil
            resetCycle("暂停结束")
        }

        guard enabled, !isAway else { return }

        remainingSeconds = max(0, Int(ceil(nextFire.timeIntervalSince(now))))
        if now >= nextFire {
            Log.write("触发提醒")
            showReminder(preview: false)
        }
    }

    // MARK: 操作

    func remindNow(preview: Bool) { showReminder(preview: preview) }

    func pause(hours: Double) {
        pausedUntil = Date().addingTimeInterval(hours * 3600)
        Log.write("暂停 \(hours) 小时")
    }

    func resume() {
        pausedUntil = nil
        resetCycle("恢复提醒")
    }

    private func showReminder(preview: Bool) {
        guard !reminderShowing else { return }
        reminderShowing = true
        rest.begin(totalSeconds: preview ? 15 : restMinutes * 60,
                   sittingMinutes: intervalMinutes,
                   snoozeMinutes: snoozeMinutes,
                   isPreview: preview)
        if playSound { NSSound(named: "Glass")?.play() }
        overlay.show {
            AnyView(RestOverlayView(
                session: ReminderState.shared.rest,
                onSnooze: { ReminderState.shared.snooze() },
                onSkip: { ReminderState.shared.finishRest("紧急跳过") },
                onFinish: { ReminderState.shared.finishRest("点击继续工作") }
            ))
        }
        defaults.set(overlay.screenCount, forKey: "lastOverlayScreenCount")
        Log.write("显示遮挡: \(overlay.screenCount) 块屏幕 预览=\(preview)")
    }

    func snooze() {
        guard reminderShowing, !rest.snoozeUsed else { return }
        overlay.close()
        reminderShowing = false
        rest.snoozeUsed = true
        nextFire = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        remainingSeconds = snoozeMinutes * 60
        Log.write("推迟 \(snoozeMinutes) 分钟: 下次提醒 \(Log.time(nextFire))")
    }

    func finishRest(_ reason: String) {
        overlay.close()
        reminderShowing = false
        rest.snoozeUsed = false
        isAway = false
        resetCycle(reason)
    }

    // MARK: 开机自启（SMAppService，macOS 13+）

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginNote = ""
        } catch {
            loginNote = "设置失败：\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        let name: String
        switch status {
        case .enabled:
            launchAtLogin = true
            name = "enabled"
        case .requiresApproval:
            launchAtLogin = true
            loginNote = "需要在「系统设置 > 通用 > 登录项」中允许"
            name = "requiresApproval"
        case .notRegistered:
            launchAtLogin = false
            name = "notRegistered"
        case .notFound:
            launchAtLogin = false
            name = "notFound"
        @unknown default:
            launchAtLogin = false
            name = "unknown"
        }
        defaults.set(name, forKey: Keys.loginStatus)
    }

    // MARK: 工具

    static func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    var menuTitle: String {
        if reminderShowing { return "休息" }
        if pausedUntil != nil { return "暂停" }
        if !enabled { return "关" }
        if isAway { return "休息" }
        return format(remainingSeconds)
    }
}

func format(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

// 事件日志：~/Library/Logs/SitReminder.log，超过 1MB 时清空重写
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SitReminder.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func time(_ d: Date) -> String { formatter.string(from: d) }

    static func write(_ message: String) {
        #if PREVIEW
        return
        #else
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

// MARK: - 菜单栏图标

struct MenuBarLabel: View {
    @EnvironmentObject var state: ReminderState
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "figure.stand")
            Text(state.menuTitle).monospacedDigit()
        }
    }
}

// MARK: - 设置面板（点击菜单栏图标弹出，iOS 设置风格）

enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    // iOS systemGroupedBackground / secondarySystemGroupedBackground
    static let groupedBackground = dynamic(rgb(242, 242, 247), rgb(0, 0, 0))
    static let card = dynamic(rgb(255, 255, 255), rgb(28, 28, 30))
    static let separator = dynamic(rgb(198, 198, 200), rgb(56, 56, 58))
    static let fill = dynamic(rgb(118, 118, 128, 0.12), rgb(118, 118, 128, 0.24))
    static let segmentSelected = dynamic(rgb(255, 255, 255), rgb(99, 99, 102))
    static let green = Color(nsColor: rgb(52, 199, 89))
    static let orange = Color(nsColor: rgb(255, 149, 0))
    static let blue = Color(nsColor: rgb(0, 122, 255))
    static let indigo = Color(nsColor: rgb(88, 86, 214))
    static let teal = Color(nsColor: rgb(48, 176, 199))
    static let pink = Color(nsColor: rgb(255, 45, 85))
    static let gray = Color(nsColor: rgb(142, 142, 147))
    static let red = Color(nsColor: rgb(255, 59, 48))
}

struct SettingsPanel: View {
    @EnvironmentObject var state: ReminderState

    var body: some View {
        VStack(spacing: 16) {
            HeaderCard()

            SettingsSection(title: "提醒") {
                SettingRow(icon: "figure.stand", color: Palette.green, title: "久坐提醒") {
                    IOSSwitch(isOn: $state.enabled)
                }
                RowDivider()
                VStack(spacing: 8) {
                    SettingRow(icon: "timer", color: Palette.orange, title: "提醒间隔") {
                        CapsuleStepper(value: $state.intervalMinutes, range: 5...180, step: 5, unit: "分钟")
                    }
                    SegmentedChips(options: [30, 45, 60, 90], selection: $state.intervalMinutes)
                        .padding(.leading, 48)
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                }
                RowDivider()
                SettingRow(icon: "figure.walk", color: Palette.blue, title: "离开电脑休息") {
                    CapsuleStepper(value: $state.restMinutes, range: 1...15, step: 1, unit: "分钟")
                }
                RowDivider()
                SettingRow(icon: "clock.arrow.circlepath", color: Palette.indigo, title: "可推迟一次") {
                    CapsuleStepper(value: $state.snoozeMinutes, range: 1...30, step: 1, unit: "分钟")
                }
            }

            SettingsSection(title: "自动识别",
                            footer: "锁屏时停止计时。离开或锁屏超过设定时长，回来后从头计时。") {
                SettingRow(icon: "lock.fill", color: Palette.teal, title: "离开判定") {
                    CapsuleStepper(value: $state.awayResetMinutes, range: 1...30, step: 1, unit: "分钟")
                }
            }

            SettingsSection(title: "通用", footer: state.loginNote.isEmpty ? nil : state.loginNote) {
                SettingRow(icon: "speaker.wave.2.fill", color: Palette.pink, title: "提醒声音") {
                    IOSSwitch(isOn: $state.playSound)
                }
                RowDivider()
                SettingRow(icon: "power", color: Palette.gray, title: "开机自动启动") {
                    IOSSwitch(isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                }
            }

            HStack {
                Button("查看日志") { NSWorkspace.shared.open(Log.url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.blue)
                Spacer()
                Button("退出久坐提醒") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.red)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
        }
        .padding(14)
        .frame(width: 340)
        .background(Palette.groupedBackground)
        .onAppear { state.refreshLoginStatus() }
    }
}

// 顶部卡片：圆环倒计时 + 快捷操作
struct HeaderCard: View {
    @EnvironmentObject var state: ReminderState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(ringColor.opacity(0.18), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: ringIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(ringColor)
                }
                .frame(width: 66, height: 66)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(bigText)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                if state.pausedUntil == nil {
                    QuickAction(icon: "pause.fill", title: "暂停 1 小时", color: Palette.orange) {
                        state.pause(hours: 1)
                    }
                } else {
                    QuickAction(icon: "play.fill", title: "恢复提醒", color: Palette.green) {
                        state.resume()
                    }
                }
                QuickAction(icon: "arrow.counterclockwise", title: "重新计时", color: Palette.blue) {
                    state.resetCycle("手动")
                }
                QuickAction(icon: "eye.fill", title: "预览 15 秒", color: Palette.indigo) {
                    state.remindNow(preview: true)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
    }

    private var total: Double { Double(max(1, state.intervalMinutes * 60)) }

    private var progress: Double {
        if state.pausedUntil != nil || !state.enabled { return 0 }
        if state.reminderShowing { return 1 }
        return min(1, max(0, 1 - Double(state.remainingSeconds) / total))
    }

    private var ringColor: Color {
        if state.pausedUntil != nil { return Palette.orange }
        if !state.enabled { return Palette.gray }
        return Palette.green
    }

    private var ringIcon: String {
        if state.pausedUntil != nil { return "pause.fill" }
        if !state.enabled { return "moon.zzz.fill" }
        if state.reminderShowing || state.isAway { return "figure.walk" }
        return "figure.stand"
    }

    private var statusTitle: String {
        if state.reminderShowing { return "正在休息" }
        if state.pausedUntil != nil { return "已暂停" }
        if !state.enabled { return "提醒已关闭" }
        if state.isAway { return "检测到你已离开" }
        return "距离下次起身"
    }

    private var bigText: String {
        if let until = state.pausedUntil { return Self.hm(until) }
        if !state.enabled { return "--:--" }
        if state.reminderShowing || state.isAway { return "休息中" }
        return format(state.remainingSeconds)
    }

    private var subtitle: String {
        if state.pausedUntil != nil { return "到点后自动恢复提醒" }
        if !state.enabled { return "打开「久坐提醒」开始计时" }
        if state.isAway { return "回来后从头计时" }
        if state.reminderShowing { return "离开电脑，倒计时结束后继续工作" }
        return "\(Self.hm(state.nextFireDate)) 提醒你起来走动"
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(color.opacity(0.14)))
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let icon: String
    let color: Color
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 0.5)
            .padding(.leading, 48)
    }
}

// iOS 风格开关（绿色）
struct IOSSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.green : Palette.fill)
                    .frame(width: 42, height: 25)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .frame(width: 21, height: 21)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
    }
}

// iOS 风格 「− 数值 +」 调节器
struct CapsuleStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            Text("\(value) \(unit)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 54)
            stepButton("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .background(Capsule().fill(Palette.fill))
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
    }
}

// iOS 风格分段选择
struct SegmentedChips: View {
    let options: [Int]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { m in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = m }
                } label: {
                    Text("\(m) 分")
                        .font(.system(size: 12, weight: selection == m ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == m ? Palette.segmentSelected : Color.clear)
                                .shadow(color: .black.opacity(selection == m ? 0.12 : 0), radius: 2, x: 0, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.fill))
    }
}

// MARK: - 全屏遮挡窗口（每块屏幕一个）

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var windows: [NSWindow] = []
    private var makeContent: (() -> AnyView)?
    private var screenObserver: NSObjectProtocol?

    var screenCount: Int { windows.count }

    func show(content: @escaping () -> AnyView) {
        makeContent = content
        rebuild()
        if screenObserver == nil {
            // 插拔显示器或分辨率变化时重建，保证所有屏幕都被覆盖
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if ReminderState.shared.reminderShowing {
                        ReminderState.shared.overlay.rebuild()
                    }
                }
            }
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching,
                                     .disableHideApplication, .disableAppleMenu]
    }

    func rebuild() {
        guard let makeContent else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.contentView = FirstMouseHostingView(rootView: makeContent())
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        let mainIndex = NSScreen.screens.firstIndex(where: { $0 == NSScreen.main }) ?? 0
        if windows.indices.contains(mainIndex) {
            windows[mainIndex].makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        makeContent = nil
        NSApp.presentationOptions = []
    }
}

// MARK: - Overlay Views（预览程序从这里开始抽取）

@MainActor
final class RestSession: ObservableObject {
    @Published var totalSeconds = 180
    @Published var remaining = 180
    @Published var sittingMinutes = 45
    @Published var snoozeMinutes = 5
    @Published var userActive = false
    @Published var completed = false
    @Published var snoozeUsed = false
    @Published var isPreview = false
    private var remainingExact: Double = 180

    func begin(totalSeconds: Int, sittingMinutes: Int, snoozeMinutes: Int, isPreview: Bool) {
        let keepSnoozeUsed = snoozeUsed && !completed
        self.totalSeconds = max(1, totalSeconds)
        self.remaining = max(1, totalSeconds)
        self.remainingExact = Double(max(1, totalSeconds))
        self.sittingMinutes = sittingMinutes
        self.snoozeMinutes = snoozeMinutes
        self.isPreview = isPreview
        self.userActive = false
        self.completed = false
        // 推迟后再次弹出时，不再允许推迟
        self.snoozeUsed = keepSnoozeUsed
    }

    // 只有离开键盘鼠标时才倒计时；credit 为本次可计入休息的秒数
    func tick(idle: TimeInterval, credit: TimeInterval) {
        guard !completed else { return }
        userActive = idle < 1.5
        remainingExact -= credit
        remaining = max(0, Int(ceil(remainingExact)))
        if remaining <= 0 {
            remaining = 0
            completed = true
            userActive = false
        }
    }

    var progress: Double {
        1 - Double(remaining) / Double(totalSeconds)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct RestOverlayView: View {
    @ObservedObject var session: RestSession
    let onSnooze: () -> Void
    let onSkip: () -> Void
    let onFinish: () -> Void

    private let tip = [
        "站起来走两步，接杯水。",
        "活动一下肩颈，转转脖子。",
        "走到窗边看看远处，让眼睛休息一下。",
        "伸个懒腰，舒展一下后背。",
        "做几个深蹲，让血液流动起来。",
    ].randomElement()!

    var body: some View {
        ZStack {
            VisualEffectBlur()
            LinearGradient(colors: [Color(red: 0.02, green: 0.16, blue: 0.11).opacity(0.92),
                                    Color.black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 26) {
                Image(systemName: session.completed ? "checkmark.circle.fill" : "figure.walk")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(.green)

                Text(session.completed ? "休息完成" : "起来走动一下")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 22))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.75))

                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: session.progress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: session.progress)
                    Text(format(session.remaining))
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 220, height: 220)

                statusLine

                if session.completed {
                    Button("继续工作", action: onFinish)
                        .buttonStyle(PillButtonStyle(primary: true, large: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    HStack(spacing: 18) {
                        if !session.snoozeUsed && !session.isPreview {
                            Button("推迟 \(session.snoozeMinutes) 分钟（仅一次）", action: onSnooze)
                                .buttonStyle(PillButtonStyle(primary: false, large: true))
                        }
                        ConfirmSkipButton(title: session.isPreview ? "结束预览" : "紧急跳过",
                                         action: onSkip)
                    }
                }
            }
            .padding(40)
        }
        .ignoresSafeArea()
    }

    private var subtitle: String {
        if session.completed {
            return "欢迎回来。动一下鼠标或点击下方按钮，开始新一轮计时。"
        }
        return "你已经连续坐了 \(session.sittingMinutes) 分钟。请离开座位。\n\(tip)"
    }

    @ViewBuilder private var statusLine: some View {
        if session.completed {
            Text(" ").font(.system(size: 18))
        } else if session.userActive {
            Label("检测到键盘或鼠标操作，计时已暂停。请离开电脑。", systemImage: "pause.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            Label("离开电脑计时中，碰键盘或鼠标会暂停计时", systemImage: "figure.walk.motion")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

// 窗口未激活时，第一次点击也直接作用到按钮上
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// 点两次才跳过：第一次点击后按钮变红，4 秒内再点一次确认，防止误触
final class ConfirmModel: ObservableObject {
    @Published var armed = false
    var resetWork: DispatchWorkItem?
}

struct ConfirmSkipButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var model = ConfirmModel()

    var body: some View {
        Button(model.armed ? "确认\(title)（再点一次）" : title) {
            if model.armed {
                model.resetWork?.cancel()
                model.armed = false
                action()
            } else {
                model.armed = true
                let m = model
                let work = DispatchWorkItem { m.armed = false }
                model.resetWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
        .buttonStyle(SkipButtonStyle(armed: model.armed))
    }
}

struct SkipButtonStyle: ButtonStyle {
    let armed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: armed ? .semibold : .regular))
            .foregroundStyle(Color.white.opacity(armed ? 1 : 0.85))
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(Capsule().fill(armed ? Color.red.opacity(0.85) : Color.white.opacity(0.16)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

// 固定配色的按钮，不随窗口是否获得焦点变灰
struct PillButtonStyle: ButtonStyle {
    let primary: Bool
    var large: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 17 : 14, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, large ? 26 : 18)
            .padding(.vertical, large ? 12 : 9)
            .background(
                Capsule().fill(primary ? Color.green : Color.white.opacity(0.16))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
