import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return tr("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        }
    }

    static func bestMatch(_ preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let tag = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if tag == "zh" || tag.hasPrefix("zh-") {
                if tag.contains("hant") { return .traditionalChinese }
                if tag.contains("hans") { return .simplifiedChinese }
                if tag.split(separator: "-").contains(where: { ["tw", "hk", "mo"].contains(String($0)) }) {
                    return .traditionalChinese
                }
                return .simplifiedChinese
            }
            if tag == "en" || tag.hasPrefix("en-") { return .english }
            if tag == "ja" || tag.hasPrefix("ja-") { return .japanese }
        }
        return .english
    }
}

// 语言偏好与ReminderState分离；切换语言不会重置或暂停提醒。
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    private let defaults = UserDefaults.standard
    @Published var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: "uiLanguage") }
    }
    private var localeObserver: NSObjectProtocol?

    private init() {
        selection = AppLanguage(rawValue: defaults.string(forKey: "uiLanguage") ?? "") ?? .system
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if self?.selection == .system { self?.objectWillChange.send() }
        }
    }
    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
    }

    var language: AppLanguage {
        selection == .system ? AppLanguage.bestMatch(Locale.preferredLanguages) : selection
    }
    var locale: Locale { Locale(identifier: language.rawValue) }

    // 简体中文原文为key，列顺序固定为英文、繁体中文、日文。
    static let messages: [String: [String]] = [
        "久坐提醒": ["SitReminder", "久坐提醒", "座りすぎリマインダー"],
        "语言": ["Language", "語言", "言語"],
        "跟随系统": ["System", "跟隨系統", "システム"],
        "提醒": ["Reminders", "提醒", "リマインダー"],
        "提醒间隔": ["Interval", "提醒間隔", "通知間隔"],
        "离开电脑休息": ["Break length", "離開電腦休息", "休憩時間"],
        "可推迟一次": ["Snooze once", "可延後一次", "一度だけ延期"],
        "分钟": ["min", "分鐘", "分"],
        "%d 分": ["%d min", "%d 分", "%d 分"],
        "自动识别": ["Away detection", "自動偵測", "離席検出"],
        "锁屏时停止计时。离开或锁屏超过设定时长，回来后从头计时。": [
            "Pauses while locked. A long enough break or lock resets the timer when you return.",
            "鎖定螢幕時停止計時。離開或鎖定超過設定時間，回來後重新計時。",
            "画面ロック中は一時停止します。設定時間以上離席・ロックすると、戻ったときに最初から計測します。"],
        "离开判定": ["Away after", "離開判定", "離席と判定"],
        "通用": ["General", "一般", "一般"],
        "提醒声音": ["Sound", "提醒音效", "通知音"],
        "开机自动启动": ["Launch at login", "登入時自動啟動", "ログイン時に起動"],
        "查看日志": ["View logs", "檢視記錄", "ログを表示"],
        "退出久坐提醒": ["Quit", "結束久坐提醒", "終了"],
        "暂停 1 小时": ["Pause 1 h", "暫停 1 小時", "1時間停止"],
        "恢复提醒": ["Resume", "恢復提醒", "再開"],
        "重新计时": ["Restart", "重新計時", "リセット"],
        "预览 15 秒": ["Preview 15 s", "預覽 15 秒", "15秒プレビュー"],
        "正在休息": ["Taking a break", "正在休息", "休憩中"],
        "已暂停": ["Paused", "已暫停", "一時停止中"],
        "提醒已关闭": ["Reminders off", "提醒已關閉", "通知はオフです"],
        "检测到你已离开": ["Away detected", "偵測到你已離開", "離席を検出"],
        "距离下次起身": ["Next break in", "距離下次起身", "次の休憩まで"],
        "休息中": ["Break", "休息中", "休憩中"],
        "到点后自动恢复提醒": ["Reminders will resume automatically", "到時自動恢復提醒", "時間になると自動で再開します"],
        "打开「久坐提醒」开始计时": ["Enable reminders to start the timer", "開啟「久坐提醒」開始計時", "通知をオンにすると計測を開始します"],
        "回来后从头计时": ["A fresh cycle starts when you return", "回來後重新計時", "戻ると最初から計測します"],
        "离开电脑，倒计时结束后继续工作": ["Step away until the break is complete", "離開電腦，倒數結束後繼續工作", "休憩が終わるまでパソコンから離れましょう"],
        "%@ 提醒你起来走动": ["Time to move at %@", "%@ 提醒你起來走動", "%@ に休憩をお知らせ"],
        "休息": ["Break", "休息", "休憩"],
        "暂停": ["Pause", "暫停", "停止"],
        "关": ["Off", "關", "オフ"],
        "设置失败：%@": ["Could not save setting: %@", "設定失敗：%@", "設定を保存できませんでした：%@"],
        "需要在「系统设置 > 通用 > 登录项」中允许": [
            "Allow SitReminder in System Settings > General > Login Items.",
            "需要在「系統設定 > 一般 > 登入項目」中允許。",
            "「システム設定 > 一般 > ログイン項目」で許可してください。"],
        "站起来走两步，接杯水。": ["Take a short walk and get some water.", "站起來走兩步，倒杯水。", "少し歩いて、水を飲みましょう。"],
        "活动一下肩颈，转转脖子。": ["Gently stretch your neck and shoulders.", "活動一下肩頸，輕輕轉動脖子。", "首と肩をゆっくりほぐしましょう。"],
        "走到窗边看看远处，让眼睛休息一下。": ["Look out of a window and rest your eyes.", "走到窗邊看看遠處，讓眼睛休息一下。", "窓の外の遠くを見て、目を休めましょう。"],
        "伸个懒腰，舒展一下后背。": ["Stretch gently and relax your back.", "伸個懶腰，舒展一下背部。", "背伸びをして、背中を伸ばしましょう。"],
        "做几个深蹲，让血液流动起来。": ["Try a few gentle squats to get moving.", "做幾個輕鬆的深蹲，活動一下。", "無理のない範囲で、軽くスクワットをしてみましょう。"],
        "休息完成": ["Break complete", "休息完成", "休憩が終わりました"],
        "起来走动一下": ["Time to move", "起來走動一下", "立って動きましょう"],
        "继续工作": ["Back to work", "繼續工作", "作業に戻る"],
        "推迟 %d 分钟（仅一次）": ["Snooze %d min (once)", "延後 %d 分鐘（僅一次）", "%d分延期（1回のみ）"],
        "结束预览（Esc）": ["End preview (Esc)", "結束預覽（Esc）", "プレビュー終了（Esc）"],
        "紧急跳过": ["Skip this break", "緊急略過", "休憩をスキップ"],
        "动态效果已关闭": ["Motion reduced", "動態效果已關閉", "動きを抑制中"],
        "播放动画": ["Play animation", "播放動畫", "アニメーション再開"],
        "暂停动画": ["Pause animation", "暫停動畫", "アニメーション停止"],
        "欢迎回来。动一下鼠标或点击下方按钮，开始新一轮计时。": [
            "Welcome back. Move the mouse or click below to start a new cycle.",
            "歡迎回來。移動滑鼠或點擊下方按鈕，開始新一輪計時。",
            "おかえりなさい。マウスを動かすか、下のボタンを押すと計測を再開します。"],
        "你已经连续坐了 %d 分钟。请离开座位。\n%@": [
            "You have been sitting for %d min. Step away from your desk.\n%@",
            "你已經連續坐了 %d 分鐘。請離開座位。\n%@",
            "%d分間座り続けています。席を立ちましょう。\n%@"],
        "检测到键盘或鼠标操作，计时已暂停。请离开电脑。": [
            "Keyboard or mouse activity detected. Break timer paused. Step away.",
            "偵測到鍵盤或滑鼠操作，計時已暫停。請離開電腦。",
            "キーボードやマウスの操作を検出。休憩タイマーを一時停止中です。離席しましょう。"],
        "离开电脑计时中，碰键盘或鼠标会暂停计时": [
            "Break timer running. Keyboard or mouse activity pauses it.",
            "離開電腦計時中，操作鍵盤或滑鼠會暫停計時",
            "休憩を計測中。キーボードやマウスを操作すると一時停止します。"],
        "确认%@（再点一次）": ["Confirm: %@ (click again)", "確認%@（再點一次）", "%@（もう一度で確定）"],
    ]

    static func text(_ source: String, language: AppLanguage) -> String {
        guard let variants = messages[source] else { return source }
        switch language {
        case .english: return variants[0]
        case .traditionalChinese: return variants[1]
        case .japanese: return variants[2]
        case .system, .simplifiedChinese: return source
        }
    }
}

func tr(_ source: String, _ arguments: CVarArg...) -> String {
    let localization = AppLocalization.shared
    let text = AppLocalization.text(source, language: localization.language)
    return arguments.isEmpty ? text : String(format: text, locale: localization.locale, arguments: arguments)
}
