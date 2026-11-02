// Presenter — 外接投影屏按时间表自动切换：欢迎页 / PDF / 时钟 / 倒计时，实时翻译字幕条，全局翻页快捷键
//
// 编译：bash build.sh（需要 Xcode 命令行工具）
// 运行：双击 Presenter.app
// 彩排：killall Presenter; open Presenter.app --args --test
//
// 设计要点
// - 时间表、PDF 文件名规则、快捷键都在 config.json 里，默认：
//   09:10 欢迎页 → 09:12 pdf1 → 10:18 欢迎页 → 10:21 时钟 → 10:28:30 倒计时 → 10:30 pdf2 → 12:15 退出
// - PDF 从 ~/Downloads 读取：pdf1 = 符合 ^[ A-Z][a-z]+-yyyymmdd\.pdf$ 的文件，pdf2 = yyyymmdd.pdf
// - PDF 结束前 60 秒在内建屏上方提醒，按 ⌃⌥E 可延长当前画面（每次 +2 分钟，可连按），不操作就按时间表切换。
// - 每月第一个星期天，pdf2 时在投影下方 1/5 显示实时翻译（Kaleo 网页在后台运行，提取最新文字显示成大字）。
// - 投影窗口是“不抢焦点”的面板：出现、切换、翻页都不会把焦点从 OBS 抢走，鼠标点击也会穿透。
// - 全局快捷键用系统热键接口（RegisterEventHotKey），不需要“辅助功能/输入监控”权限。
// - 启动时读取 OBS 的快捷键设置，与 OBS 相同的组合不会注册，并在菜单栏里标出。
// - 程序运行期间阻止系统/显示器休眠和屏保。
// - 投影屏断开时窗口自动隐藏（不会跑到内建屏盖住 OBS），重新接上后自动回来。

import Cocoa
import WebKit
import PDFKit
import Carbon

// MARK: - 日志

var logFileURL: URL?

func writeLog(_ message: String) {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let data = Data("[\(f.string(from: Date()))] \(message)\n".utf8)
    FileHandle.standardError.write(data)
    guard let url = logFileURL else { return }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        h.closeFile()
    } else {
        try? data.write(to: url)
    }
}

// MARK: - 小工具

typealias HMSTime = (h: Int, m: Int, s: Int)

func pad2(_ n: Int) -> String {
    return n < 10 ? "0\(n)" : "\(n)"
}

func hms(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
    return "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0)):\(pad2(c.second ?? 0))"
}

/// 9:10、10:28:30 这样的短格式（秒为 0 时省略）
func shortTime(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
    let h = c.hour ?? 0
    let m = c.minute ?? 0
    let s = c.second ?? 0
    return s == 0 ? "\(h):\(pad2(m))" : "\(h):\(pad2(m)):\(pad2(s))"
}

func durationText(_ s: TimeInterval) -> String {
    if s < 60 { return "\(Int(s.rounded())) 秒" }
    let m = s / 60
    if m == m.rounded() { return "\(Int(m)) 分钟" }
    return String(format: "%.1f 分钟", m)
}

func parseHMS(_ text: String) -> HMSTime? {
    let parts = text.split(separator: ":").map { Int(String($0).trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 || parts.count == 3 else { return nil }
    guard let h = parts[0], let m = parts[1] else { return nil }
    var s = 0
    if parts.count == 3 {
        guard let v = parts[2] else { return nil }
        s = v
    }
    guard (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s) else { return nil }
    return (h: h, m: m, s: s)
}

func seconds(_ t: HMSTime) -> Int {
    return t.h * 3600 + t.m * 60 + t.s
}

func dateOn(_ day: Date, _ t: HMSTime) -> Date {
    return Calendar.current.date(bySettingHour: t.h, minute: t.m, second: t.s, of: day) ?? day
}

func expandPath(_ p: String, base: URL) -> URL {
    let e = (p as NSString).expandingTildeInPath
    if e.hasPrefix("/") { return URL(fileURLWithPath: e).standardizedFileURL }
    return base.appendingPathComponent(e).standardizedFileURL
}

func modDate(_ url: URL) -> Date? {
    return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

/// 把字符串变成 JavaScript 字符串字面量（带引号）
func jsString(_ s: String) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
          let a = String(data: d, encoding: .utf8), a.count >= 2 else { return "\"\"" }
    return String(a.dropFirst().dropLast())
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

// MARK: - 设置与时间表

struct EventSpec {
    var at: String
    var show: String
}

struct ValidEvent {
    var t: HMSTime
    var show: String
}

struct TimelineEvent {
    var at: Date
    var show: String
}

let defaultEventSpecs: [EventSpec] = [
    EventSpec(at: "09:10:00", show: "welcome"),
    EventSpec(at: "09:12:00", show: "pdf1"),
    EventSpec(at: "10:18:00", show: "welcome"),
    EventSpec(at: "10:21:00", show: "clock"),
    EventSpec(at: "10:28:30", show: "countdown"),
    EventSpec(at: "10:30:00", show: "pdf2"),
    EventSpec(at: "12:15:00", show: "quit"),
]

let defaultPDFPatterns: [String: String] = [
    "pdf1": "^[ A-Z][a-z]+-{date}\\.pdf$",
    "pdf2": "^{date}\\.pdf$",
]

let defaultHotkeys: [String: [String]] = [
    "next": ["ctrl+alt+right", "ctrl+alt+down"],
    "prev": ["ctrl+alt+left", "ctrl+alt+up"],
    "first": ["ctrl+alt+1"],
    "black": ["ctrl+alt+b"],
    "extend": ["ctrl+alt+e"],
    "auto": ["ctrl+alt+r"],
    "caption": ["ctrl+alt+t"],
    "pdfNow": ["ctrl+alt+p"],
    "quit": ["ctrl+alt+escape"],
]

/// 舞台页画面（其余名字都是 PDF）
let stageShows: Set<String> = ["welcome", "clock", "countdown", "quit"]

func isPDFShow(_ show: String) -> Bool {
    return !stageShows.contains(show)
}

func showLabel(_ show: String) -> String {
    switch show {
    case "welcome": return "欢迎页"
    case "clock": return "时钟"
    case "countdown": return "倒计时"
    case "quit": return "退出"
    default: return show
    }
}

struct CaptionConfig {
    var url = "https://app.withkaleo.com/c/oakville-chinese-hope-church"
    var when = "firstSunday"            // firstSunday | sunday | always | never
    var showDuring: [String] = ["pdf2"]
    var from = "10:40:00"               // 几点开始自动显示（空 = 画面一开始就显示）
    var to = ""                         // 几点停止自动显示（空 = 一直到画面结束）
    var heightPercent: Double = 20
    var lines = 3
    var mode = "text"                   // text（提取文字显示大字）| page（显示原网页）
    var textSelector = ""
    var color = "#ffffff"
    var background = "#000000"
    var overlay = true                  // true = 叠加在 PDF 下部（PDF 保持全屏）；false = PDF 缩到上方 4/5
    var pageZoom: Double = 1.5
    var reloadIfStaleMinutes: Double = 10
}

struct PresenterConfig {
    var events: [EventSpec] = defaultEventSpecs
    var pdfFolder = "~/Downloads"
    var dateFormat = "yyyyMMdd"
    var pdfPatterns: [String: String] = defaultPDFPatterns
    var screenName = ""
    var hotkeys: [String: [String]] = defaultHotkeys
    var extendMinutes: Double = 2
    var warnSeconds: Double = 60
    var warnFor: [String]?              // nil = 所有 PDF
    var caption = CaptionConfig()
}

enum Scene: Equatable {
    case waiting
    case welcome
    case clock
    case countdown(Date)   // 倒计时结束时刻
    case pdf(String)       // PDF 名称（config 里 pdfs 的键）
    case quit

    var isVisible: Bool {
        switch self {
        case .welcome, .clock, .countdown, .pdf: return true
        case .waiting, .quit: return false
        }
    }

    var label: String {
        switch self {
        case .waiting: return "等待"
        case .welcome: return "欢迎页"
        case .clock: return "时钟"
        case .countdown: return "倒计时"
        case .pdf(let k): return k
        case .quit: return "退出"
        }
    }

    /// 与时间表里 show 对应的名字
    var key: String {
        switch self {
        case .welcome: return "welcome"
        case .clock: return "clock"
        case .countdown: return "countdown"
        case .pdf(let k): return k
        case .waiting, .quit: return ""
        }
    }
}

// MARK: - 在 PDF 文件夹里找当天的文件（在后台线程运行）

struct PDFScan {
    var checked = false
    var readable = true
    var permissionDenied = false
    var error = ""
    var matches: [String: URL] = [:]
    var counts: [String: Int] = [:]
    var unused: [String] = []   // 含当天日期、但不符合任何规则的 PDF
}

func scanPDFFolder(_ folder: URL, date: String, rules: [String: NSRegularExpression]) -> PDFScan {
    var r = PDFScan()
    r.checked = true
    let items: [URL]
    do {
        items = try FileManager.default.contentsOfDirectory(at: folder,
                                                            includingPropertiesForKeys: [.contentModificationDateKey],
                                                            options: [])
    } catch {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix: Int? = (underlying?.domain == NSPOSIXErrorDomain) ? underlying?.code : nil
        r.readable = false
        if ns.code == CocoaError.Code.fileReadNoSuchFile.rawValue || ns.code == CocoaError.Code.fileNoSuchFile.rawValue {
            r.error = "文件夹不存在：\(folder.path)"
        } else if ns.code == CocoaError.Code.fileReadNoPermission.rawValue || posix == Int(EPERM) || posix == Int(EACCES) {
            r.permissionDenied = true
            r.error = "没有权限读取 \(folder.path)"
        } else {
            r.error = ns.localizedDescription
        }
        return r
    }
    var best: [String: (url: URL, mod: Date)] = [:]
    for u in items {
        let name = u.lastPathComponent
        let range = NSRange(location: 0, length: (name as NSString).length)
        var matched = false
        for (key, re) in rules where re.firstMatch(in: name, options: [], range: range) != nil {
            matched = true
            r.counts[key, default: 0] += 1
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            if let b = best[key], b.mod >= mod { continue }
            best[key] = (url: u, mod: mod)
        }
        if !matched && name.lowercased().hasSuffix(".pdf") && name.contains(date) {
            r.unused.append(name)
        }
    }
    for (k, v) in best { r.matches[k] = v.url }
    r.unused.sort()
    return r
}

struct CachedDoc {
    let url: URL
    let mod: Date?
    let doc: PDFDocument
}

// MARK: - 快捷键解析

enum HotAction: String, CaseIterable {
    case next, prev, first, last, black, extend, auto, caption, pdfNow, welcomeNow, clockNow, countdownNow, quit

    var title: String {
        switch self {
        case .next: return "下一页"
        case .prev: return "上一页"
        case .first: return "第一页"
        case .last: return "最后一页"
        case .black: return "黑屏开/关"
        case .extend: return "延长当前画面"
        case .auto: return "恢复按时间表（取消延长/手动切换）"
        case .caption: return "实时翻译 显示/隐藏"
        case .pdfNow: return "立即显示 PDF（当前或下一个）"
        case .welcomeNow: return "立即显示欢迎页"
        case .clockNow: return "立即显示时钟"
        case .countdownNow: return "立即开始倒计时"
        case .quit: return "退出 Presenter"
        }
    }
}

let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
    "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
    "delete": kVK_Delete,
    "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "home": kVK_Home, "end": kVK_End,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
    "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
    "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
    "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash,
    "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "semicolon": kVK_ANSI_Semicolon,
    "quote": kVK_ANSI_Quote, "backslash": kVK_ANSI_Backslash, "grave": kVK_ANSI_Grave,
    "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
]

let keyAliases: [String: String] = [
    "pgup": "pageup", "pgdn": "pagedown", "esc": "escape", "enter": "return",
    "←": "left", "→": "right", "↑": "up", "↓": "down",
    "bracketleft": "leftbracket", "bracketright": "rightbracket",
    "apostrophe": "quote", "backspace": "delete",
]

// 不带 ctrl/cmd 也允许注册的键（翻页笔常用 PageUp/PageDown）
let bareAllowedKeys: Set<String> = {
    var s: Set<String> = ["pageup", "pagedown", "home", "end"]
    for i in 1...20 { s.insert("f\(i)") }
    return s
}()

func keyLabel(_ k: String) -> String {
    switch k {
    case "left": return "←"
    case "right": return "→"
    case "up": return "↑"
    case "down": return "↓"
    case "space": return "Space"
    case "escape": return "Esc"
    case "return": return "↩"
    case "tab": return "Tab"
    case "delete": return "⌫"
    case "pageup": return "PgUp"
    case "pagedown": return "PgDn"
    case "home": return "Home"
    case "end": return "End"
    default: return k.uppercased()
    }
}

struct OBSBinding: Hashable {
    let key: String
    let ctrl: Bool
    let alt: Bool
    let shift: Bool
    let cmd: Bool
}

struct KeyCombo {
    let key: String
    let keyCode: UInt32
    let ctrl: Bool
    let alt: Bool
    let shift: Bool
    let cmd: Bool

    var modifiers: UInt32 {
        var m: UInt32 = 0
        if ctrl { m |= UInt32(controlKey) }
        if alt { m |= UInt32(optionKey) }
        if shift { m |= UInt32(shiftKey) }
        if cmd { m |= UInt32(cmdKey) }
        return m
    }

    var display: String {
        var s = ""
        if ctrl { s += "⌃" }
        if alt { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        s += keyLabel(key)
        return s
    }

    var obs: OBSBinding {
        return OBSBinding(key: key, ctrl: ctrl, alt: alt, shift: shift, cmd: cmd)
    }
}

enum ComboParse {
    case ok(KeyCombo)
    case fail(String)
}

func parseCombo(_ raw: String) -> ComboParse {
    let tokens = raw.lowercased()
        .split(separator: "+")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let last = tokens.last else { return .fail("空的快捷键") }
    var ctrl = false
    var alt = false
    var shift = false
    var cmd = false
    for t in tokens.dropLast() {
        switch t {
        case "ctrl", "control", "⌃": ctrl = true
        case "alt", "opt", "option", "⌥": alt = true
        case "shift", "⇧": shift = true
        case "cmd", "command", "⌘": cmd = true
        default: return .fail("不认识的修饰键“\(t)”")
        }
    }
    let key = keyAliases[last] ?? last
    guard let code = keyCodes[key] else { return .fail("不认识的按键“\(last)”") }
    if !ctrl && !cmd {
        if alt { return .fail("macOS 15 起不允许只用 ⌥ 或 ⌥⇧ 的全局快捷键，请加上 ctrl 或 cmd") }
        if !bareAllowedKeys.contains(key) { return .fail("不带 ctrl/cmd 的普通键会影响正常打字，已忽略") }
    }
    return .ok(KeyCombo(key: key, keyCode: UInt32(code), ctrl: ctrl, alt: alt, shift: shift, cmd: cmd))
}

// MARK: - 读取 OBS 的快捷键，避免冲突

func normalizeOBSKey(_ name: String) -> String {
    let n = name.lowercased()
    switch n {
    case "bracketleft": return "leftbracket"
    case "bracketright": return "rightbracket"
    case "apostrophe": return "quote"
    case "enter": return "return"
    case "backspace": return "delete"
    default: return n
    }
}

func loadOBSBindings() -> (bindings: Set<OBSBinding>, files: Int) {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/obs-studio")
    var files: [URL] = [root.appendingPathComponent("global.ini"), root.appendingPathComponent("user.ini")]
    if let dirs = try? fm.contentsOfDirectory(at: root.appendingPathComponent("basic/profiles"), includingPropertiesForKeys: nil) {
        for d in dirs { files.append(d.appendingPathComponent("basic.ini")) }
    }
    if let items = try? fm.contentsOfDirectory(at: root.appendingPathComponent("basic/scenes"), includingPropertiesForKeys: nil) {
        for f in items where f.pathExtension.lowercased() == "json" { files.append(f) }
    }
    var result = Set<OBSBinding>()
    var scanned = 0
    let pattern = "\\{[^{}]*\"key\"\\s*:\\s*\"OBS_KEY_([A-Za-z0-9_]+)\"[^{}]*\\}"
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return (result, 0) }
    for f in files {
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
        scanned += 1
        let ns = text as NSString
        for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let obj = ns.substring(with: m.range)
            let key = normalizeOBSKey(ns.substring(with: m.range(at: 1)))
            func flag(_ name: String) -> Bool {
                return obj.range(of: "\"\(name)\"\\s*:\\s*true", options: .regularExpression) != nil
            }
            result.insert(OBSBinding(key: key, ctrl: flag("control"), alt: flag("alt"), shift: flag("shift"), cmd: flag("command")))
        }
    }
    return (result, scanned)
}

// MARK: - 全局快捷键（Carbon 热键，无需任何权限）

var hotKeyHandler: ((UInt32) -> Void)?

final class HotKeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func install() {
        if installed { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, .init(MemoryLayout<EventHotKeyID>.size), nil, &hkID)
            if err == 0 {
                let id = hkID.id
                DispatchQueue.main.async { hotKeyHandler?(id) }
            }
            return 0
        }, 1, &spec, nil, nil)
        if status != 0 { writeLog("⚠️ 安装快捷键处理器失败：\(status)") }
    }

    func register(_ combo: KeyCombo, id: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5052_4553), id: id)  // 'PRES'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == 0, let r = ref { refs.append(r) }
        return status
    }

    func unregisterAll() {
        for r in refs { _ = UnregisterEventHotKey(r) }
        refs.removeAll()
    }
}

// MARK: - 投影窗口

final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
    // 不让系统把窗口挤到菜单栏下面
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { return frameRect }
}

/// 投影窗口的内容区：尺寸变化时重新排版（PDF 区 / 字幕条）
final class StageContainer: NSView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

// MARK: - 内建屏上方的提示框（不抢焦点、鼠标穿透）

final class HUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var lastText = ""
    private let background: NSColor
    private let font: NSFont

    init(background: NSColor, fontSize: CGFloat) {
        self.background = background
        self.font = NSFont.systemFont(ofSize: fontSize)
    }

    var isVisible: Bool {
        return panel?.isVisible ?? false
    }

    func show(_ text: String, on screen: NSScreen?, seconds: TimeInterval?) {
        guard let screen = screen else { return }
        if seconds == nil && text == lastText && isVisible { return }
        lastText = text
        let vf = screen.visibleFrame
        let maxWidth = max(420, min(1150, vf.width - 120))
        let rect = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: 4000),
                                                   options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: font], context: nil)
        let pad: CGFloat = 20
        let labelSize = NSSize(width: ceil(rect.width) + 10, height: ceil(rect.height) + 6)
        let size = NSSize(width: labelSize.width + pad * 2, height: labelSize.height + pad * 2)
        let frame = NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.maxY - size.height - 30).rounded(),
                           width: size.width, height: size.height)
        let p: NSPanel
        let l: NSTextField
        if let existing = panel, let existingLabel = label {
            p = existing
            l = existingLabel
        } else {
            p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.ignoresMouseEvents = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.animationBehavior = .none
            let bg = NSView(frame: NSRect(origin: .zero, size: size))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = background.cgColor
            bg.layer?.cornerRadius = 14
            bg.autoresizingMask = [.width, .height]
            l = NSTextField(wrappingLabelWithString: "")
            l.font = font
            l.textColor = .white
            bg.addSubview(l)
            p.contentView = bg
            panel = p
            label = l
        }
        l.stringValue = text
        p.setFrame(frame, display: false)
        l.frame = NSRect(x: pad, y: pad, width: labelSize.width, height: labelSize.height)
        p.contentView?.needsDisplay = true
        p.orderFrontRegardless()
        timer?.invalidate()
        timer = nil
        if let s = seconds {
            let t = Timer(timeInterval: s, repeats: false) { [weak self] _ in
                self?.hide()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        lastText = ""
        panel?.orderOut(nil)
    }
}

// MARK: - 内置网页

// stage.html 不存在时用的简易页面
let fallbackStageHTML = """
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#fff;color:blue;overflow:hidden;cursor:none;font-family:-apple-system,"PingFang SC",sans-serif}
#t{position:absolute;top:50%;left:0;right:0;transform:translateY(-50%);text-align:center;font-size:14vh;font-variant-numeric:tabular-nums}
</style></head><body><div id="t"></div><script>
var mode='clock',target=0,off=0;function p(n){return (n<10?'0':'')+n}
function r(){var n=new Date(Date.now()+off),s;if(mode==='welcome'){s='欢迎 · Welcome'}else if(mode==='countdown'){var l=Math.ceil((target-n.getTime())/1000);s=l>0?(p(Math.floor(l/60))+':'+p(l%60)):'敬拜马上开始!'}else{s=p(n.getHours())+':'+p(n.getMinutes())+':'+p(n.getSeconds())}var e=document.getElementById('t');if(e.textContent!==s){e.textContent=s}}
window.setMode=function(m,t,o){mode=m;target=Number(t)||0;off=Number(o)||0;r()};setInterval(r,50);r();
</script></body></html>
"""

// 字幕条：显示从翻译网页提取到的最新文字，底部对齐，只显示最后几行
let captionHTML = #"""
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;overflow:hidden;cursor:none;background:transparent}
#box{position:fixed;top:0;right:0;bottom:0;left:0;box-sizing:border-box;padding:0 3vw;display:flex;flex-direction:column;justify-content:center}
#clip{overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end}
#t{color:#fff;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue","PingFang SC",sans-serif;font-weight:600;overflow-wrap:break-word;word-wrap:break-word}
#t.ph{opacity:.35;font-weight:400;text-align:center}
</style></head><body><div id="box"><div id="clip"><div id="t" class="ph"></div></div></div><script>
(function(){
var clip=document.getElementById('clip'),el=document.getElementById('t'),ph='',has=false,lines=3;
function layout(){var h=window.innerHeight||200;var lh=Math.max(10,Math.floor(h*0.88/lines));clip.style.height=(lh*lines)+'px';el.style.lineHeight=lh+'px';el.style.fontSize=Math.floor(lh/(has?1.22:2))+'px';}
function show(t){if(t){has=true;el.className='';if(el.textContent!==t){el.textContent=t;}}else{has=false;el.className='ph';el.textContent=ph;}layout();}
window.setStyle=function(fg,bg,n,placeholder){el.style.color=fg;document.documentElement.style.background=bg;document.body.style.background=bg;var light=true;try{var m=getComputedStyle(el).color.match(/\d+(\.\d+)?/g);light=(0.299*m[0]+0.587*m[1]+0.114*m[2])>140;}catch(e){}el.style.textShadow=(String(bg).toLowerCase()==='transparent')?(light?'0 0 6px rgba(0,0,0,.95),0 0 2px #000':'0 0 6px rgba(255,255,255,.95),0 0 2px #fff'):'none';lines=Math.max(1,Number(n)||3);ph=placeholder;show(has?el.textContent:'');};
window.setCaption=function(t){show(t);};
window.addEventListener('resize',layout);layout();
})();
</script></body></html>
"""#

// 注入到翻译网页里的脚本：找出“正在更新的文字列表”，把最新几段文字发给 Presenter
// __SELECTOR__ 会被替换成 config.json 里的 caption.textSelector（为空时自动寻找）
let captionSourceJS = #"""
(function () {
  'use strict';
  if (window.__presenterInstalled) { return; }
  window.__presenterInstalled = true;

  var SELECTOR = __SELECTOR__;
  var MAX_CHARS = 400;
  var WINDOW_MS = 30000;

  var events = [];
  var pick = null, pickPath = '', newestFirst = false, partSig = null;
  var lastText = null, lastChoose = 0, lastMute = 0, pageMode = false, selectorCount = -1;

  function post(m) {
    try { window.webkit.messageHandlers.presenter.postMessage(m); } catch (e) {}
  }
  function clean(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
  function hasText(el) { return /\S/.test(el.textContent || ''); }
  function textOf(el) { return clean(el.innerText !== undefined ? el.innerText : el.textContent); }
  function weightOf(s) { var n = clean(s).length; return n > 200 ? 200 : n; }
  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, BR: 1, SVG: 1, svg: 1, HEAD: 1, TITLE: 1 };
  // 真正显示在页面上的元素（innerText 对没显示的元素会返回原始内容，例如脚本代码，要排除）
  function rendered(el) {
    if (SKIP[el.tagName]) { return false; }
    try { return el.getClientRects().length > 0; } catch (e) { return false; }
  }
  function isBlock(el) {
    if (SKIP[el.tagName]) { return false; }
    var d = '';
    try { d = window.getComputedStyle(el).display; } catch (e) { return false; }
    return d !== 'none' && d.indexOf('inline') !== 0;
  }
  function sigOf(el) {
    var c = (typeof el.className === 'string') ? (el.className.trim().split(/\s+/)[0] || '') : '';
    return el.tagName + '.' + c;
  }
  // 子元素里“同一类、块级、有字”的最多数量（文字列表的特征）
  function homogeneous(el) {
    var counts = {}, reps = {}, best = 0, k, c;
    for (c = el.firstElementChild; c; c = c.nextElementSibling) {
      if (!hasText(c)) { continue; }
      k = sigOf(c);
      counts[k] = (counts[k] || 0) + 1;
      reps[k] = c;
    }
    for (k in counts) {
      if (Object.prototype.hasOwnProperty.call(counts, k) && counts[k] > best && isBlock(reps[k])) { best = counts[k]; }
    }
    return best;
  }
  function cssPath(el) {
    var parts = [];
    while (el && el.nodeType === 1 && el !== document.documentElement && parts.length < 12) {
      var s = el.tagName.toLowerCase();
      if (el.id) { parts.unshift(s + '#' + el.id); break; }
      if (typeof el.className === 'string' && el.className.trim()) {
        s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
      }
      parts.unshift(s);
      el = el.parentElement;
    }
    return parts.join(' > ');
  }

  // 记录网页里每一次文字变化（新增的段落、正在更新的句子）
  var mo = new MutationObserver(function (list) {
    var now = Date.now();
    for (var i = 0; i < list.length; i++) {
      var m = list[i], el = m.target, anchor = m.target, w = 0, k, n, lastEl = null;
      if (m.type === 'characterData') {
        w = weightOf(m.target.data);
        el = m.target.parentElement;
        anchor = el ? el.parentElement : null;
      } else if (m.type === 'childList') {
        for (k = 0; k < m.addedNodes.length; k++) {
          n = m.addedNodes[k];
          if (n.nodeType === 1 || n.nodeType === 3) {
            w += weightOf(n.textContent);
            if (n.nodeType === 1) { lastEl = n; }
          }
        }
        if (w > 200) { w = 200; }
        if (lastEl) { el = lastEl; }
        anchor = m.target;   // 新内容加到了哪个元素里（整块重画时，新加的元素很快被替换，但它一般还在）
      }
      if (!w || !el || el.nodeType !== 1 || SKIP[el.tagName]) { continue; }
      events.push({ t: now, el: el, anchor: anchor, w: w });
    }
    if (events.length > 500) { events.splice(0, events.length - 500); }
  });
  mo.observe(document.documentElement, { subtree: true, childList: true, characterData: true });

  // 根据最近 30 秒的变化，找出字幕所在的列表
  function choose() {
    var now = Date.now(), i, live = [], total = 0;
    while (events.length && now - events[0].t > WINDOW_MS) { events.shift(); }
    for (i = 0; i < events.length; i++) {
      var ev = events[i], x = null;
      if (document.contains(ev.el)) { x = ev.el; }
      else if (ev.anchor && ev.anchor.nodeType === 1 && document.contains(ev.anchor)) { x = ev.anchor; }
      if (x) { live.push({ el: x, w: ev.w }); total += ev.w; }
    }
    if (!live.length) { return; }
    var score = new Map();
    for (i = 0; i < live.length; i++) {
      var a = live[i].el, d = 0;
      while (a && a !== document.documentElement && d < 30) {
        score.set(a, (score.get(a) || 0) + live[i].w);
        a = a.parentElement;
        d++;
      }
    }
    // 包含至少 60% 变化的最深的元素
    var need = total * 0.6, best = null, bestDepth = -1;
    score.forEach(function (s, el) {
      if (s < need) { return; }
      var depth = 0;
      for (var p = el; p; p = p.parentElement) { depth++; }
      if (depth > bestDepth) { best = el; bestDepth = depth; }
    });
    if (!best || best === document.body) { return; }   // 没有明显集中的变化：保持原来的
    // 往上最多 6 层，找“同类块级子元素”最多的那层（一段一段的字幕列表）
    var cand = null, candScore = 1, cur = best, lv;
    for (lv = 0; cur && cur !== document.body && cur !== document.documentElement && lv < 6; lv++) {
      var h = homogeneous(cur);
      if (h > candScore) { cand = cur; candScore = h; }
      cur = cur.parentElement;
    }
    if (!cand) {
      // 还没形成列表（例如第一句话，或网页只显示当前一句）：
      // 用变化所在的块级元素；如果往上有“两个以上子元素都在变”的元素（已完成的句子 + 正在说的句子），用它
      cand = best;
      while (cand && cand !== document.body && !isBlock(cand)) { cand = cand.parentElement; }
      var minW = total * 0.05;
      cur = cand;
      for (lv = 0; cur && cur !== document.body && lv < 3; lv++) {
        var active = 0;
        for (var c2 = cur.firstElementChild; c2; c2 = c2.nextElementSibling) {
          if ((score.get(c2) || 0) >= minW && isBlock(c2)) { active++; }
        }
        if (active >= 2) { cand = cur; break; }
        cur = cur.parentElement;
      }
      if (!cand || cand === document.body) { return; }
    }
    // 判断新内容加在列表顶部还是底部
    var child = live[live.length - 1].el;
    while (child && child.parentElement !== cand) { child = child.parentElement; }
    if (child) {
      var count = 0, at = -1;
      for (var c = cand.firstElementChild; c; c = c.nextElementSibling) {
        if (!hasText(c)) { continue; }
        if (c === child) { at = count; }
        count++;
      }
      if (count >= 2 && at === 0) { newestFirst = true; }
      else if (at >= 0 && at === count - 1) { newestFirst = false; }
    }
    // 每一段里如果有好几块（例如 说话人/时间 + 文字，或 原文 + 译文），只取“正在变化”的那一块
    var pc = {}, pn = 0, multi = new Map();
    for (i = 0; i < live.length; i++) {
      var node = live[i].el, prev = null;
      while (node && node.parentElement !== cand) { prev = node; node = node.parentElement; }
      if (!node || !prev || !isBlock(prev)) { continue; }
      if (!multi.has(node)) {
        var nb = 0;
        for (var q = node.firstElementChild; q; q = q.nextElementSibling) {
          if (hasText(q) && isBlock(q)) { nb++; }
        }
        multi.set(node, nb >= 2);
      }
      if (!multi.get(node)) { continue; }
      var sk = sigOf(prev);
      pc[sk] = (pc[sk] || 0) + live[i].w;
      pn += live[i].w;
    }
    var changed = cand !== pick;
    if (changed) { partSig = null; }
    if (pn > 0) {
      var top = null, topW = 0;
      for (var key in pc) {
        if (Object.prototype.hasOwnProperty.call(pc, key) && pc[key] > topW) { top = key; topW = pc[key]; }
      }
      var ps = topW >= pn * 0.7 ? top : null;
      if (ps !== partSig) { partSig = ps; changed = true; }
    } else {
      // 没有细节（整块重画）：看最近几段里哪一块的文字最多（例如文字比“说话人/时间”长得多）
      var lc = {}, lt = 0, seen = 0;
      for (var s2 = cand.lastElementChild; s2 && seen < 5; s2 = s2.previousElementSibling) {
        if (!rendered(s2)) { continue; }
        var nbk = 0, local = {}, sg;
        for (var q2 = s2.firstElementChild; q2; q2 = q2.nextElementSibling) {
          if (!hasText(q2) || !isBlock(q2)) { continue; }
          nbk++;
          sg = sigOf(q2);
          local[sg] = (local[sg] || 0) + clean(q2.textContent).length;
        }
        if (nbk < 2) { continue; }
        seen++;
        for (sg in local) {
          if (Object.prototype.hasOwnProperty.call(local, sg)) { lc[sg] = (lc[sg] || 0) + local[sg]; lt += local[sg]; }
        }
      }
      if (seen >= 2 && lt > 0) {
        var top2 = null, top2W = 0;
        for (var key2 in lc) {
          if (Object.prototype.hasOwnProperty.call(lc, key2) && lc[key2] > top2W) { top2 = key2; top2W = lc[key2]; }
        }
        var ps2 = top2W >= lt * 0.75 ? top2 : null;
        if (ps2 !== partSig) { partSig = ps2; changed = true; }
      }
    }
    if (changed) {
      pick = cand;
      pickPath = cssPath(cand) + (partSig ? '（每段取 ' + partSig + '）' : '');
      post({ type: 'status', path: pickPath, kids: cand.childElementCount, newestFirst: newestFirst });
    }
  }

  function segText(seg) {
    if (partSig) {
      var bits = [], len = 0;
      for (var k = seg.lastElementChild; k && len < MAX_CHARS; k = k.previousElementSibling) {
        if (sigOf(k) === partSig && rendered(k)) {
          var tt = textOf(k);
          if (tt) { bits.unshift(tt); len += tt.length + 1; }
        }
      }
      if (bits.length) { return bits.join(' '); }
    }
    return textOf(seg);
  }

  // 取最新的几段文字（按时间顺序，总长约 MAX_CHARS）
  function extract() {
    var parts = [], total = 0, c, t, i, nodes;
    if (SELECTOR) {
      try { nodes = document.querySelectorAll(SELECTOR); } catch (e) { nodes = []; }
      if (nodes.length !== selectorCount) {
        selectorCount = nodes.length;
        post({ type: 'status', path: 'selector: ' + SELECTOR + '（' + nodes.length + ' 个）', kids: nodes.length, newestFirst: false });
      }
      for (i = nodes.length - 1; i >= 0 && total < MAX_CHARS; i--) {
        t = textOf(nodes[i]);
        if (t) { parts.unshift(t); total += t.length + 1; }
      }
    } else {
      // 网页整块重画后原来的列表没了：马上重新找
      if (pick && !document.contains(pick)) { pick = null; try { choose(); } catch (e) {} }
      if (!pick) { return ''; }
      if (newestFirst) {
        for (c = pick.firstElementChild; c && total < MAX_CHARS; c = c.nextElementSibling) {
          if (!rendered(c)) { continue; }
          t = segText(c);
          if (t) { parts.unshift(t); total += t.length + 1; }
        }
      } else {
        for (c = pick.lastElementChild; c && total < MAX_CHARS; c = c.previousElementSibling) {
          if (!rendered(c)) { continue; }
          t = segText(c);
          if (t) { parts.unshift(t); total += t.length + 1; }
        }
      }
      if (!parts.length) {
        t = textOf(pick);
        if (t) { parts.push(t); }
      }
    }
    var text = clean(parts.join(' '));
    if (text.length > MAX_CHARS) { text = text.slice(text.length - MAX_CHARS); }
    return text;
  }

  function scrollToEnd() {
    try { window.scrollTo(0, newestFirst ? 0 : document.documentElement.scrollHeight); } catch (e) {}
    for (var el = pick; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
      if (el.scrollHeight > el.clientHeight + 2) { el.scrollTop = newestFirst ? 0 : el.scrollHeight; }
    }
  }

  function tick() {
    var now = Date.now(), text = '';
    if (!SELECTOR && now - lastChoose > 1000) {
      lastChoose = now;
      try { choose(); } catch (e) {}
    }
    try { text = extract(); } catch (e) {}
    // 有过文字之后，暂时取不到（网页重画中）就保留上一次的，不闪成空白
    if (text !== lastText && (text || !lastText)) {
      lastText = text;
      post({ type: 'text', text: text });
    }
    if (pageMode) { scrollToEnd(); }
    if (now - lastMute > 1000) {
      lastMute = now;
      var media = document.querySelectorAll('audio,video');
      for (var i = 0; i < media.length; i++) {
        try { media[i].muted = true; } catch (e) {}
      }
    }
  }

  window.__presenterSetMode = function (mode, zoom) {
    pageMode = (mode === 'page');
    document.documentElement.style.zoom = pageMode ? String(zoom || 1) : '';
  };
  window.__presenterDump = function () {
    return JSON.stringify({
      url: location.href, path: pickPath, newestFirst: newestFirst, selector: SELECTOR,
      sample: lastText || '', html: document.documentElement.outerHTML
    });
  };

  setInterval(tick, 250);
})();
"""#

// MARK: - 主程序

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    // 启动参数
    var baseDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var testMode = false
    var testCountdown: TimeInterval?
    var testPDFTime: TimeInterval?
    var atArg: HMSTime?
    var dirArg: String?
    var dateOverride: Date?
    var timeOffset: TimeInterval = 0   // --at 模拟时间用

    // 设置
    var cfg = PresenterConfig()
    var problems: [String] = []
    var validEvents: [ValidEvent] = []
    var rules: [String: NSRegularExpression] = [:]
    var rulePatterns: [String: String] = [:]

    // 状态
    var timeline: [TimelineEvent] = []
    var currentScene: Scene = .waiting
    var sceneIndex = -1
    var manual: Scene?
    var manualIndex = -1
    var holdIndex = -1          // 被延长的时间表项
    var holdUntil: Date?        // 延长到什么时候
    var applied = false
    var lateLaunch = false
    var quitPending = false
    var tickCount = 0
    var timer: Timer?
    var activity: NSObjectProtocol?

    // PDF
    let scanQueue = DispatchQueue(label: "local.presenter.scan")
    var scan = PDFScan()
    var scanInFlight = false
    var docCache: [String: CachedDoc] = [:]
    var badFiles = Set<String>()
    var pdfShownKey: String?
    var lastPages: [String: (index: Int, at: Date)] = [:]   // 关闭 PDF 时停在第几页（手动重新打开时回到这页）

    // 界面
    var panel: StagePanel!
    var container: StageContainer!
    var webView: WKWebView!
    var pdfView: PDFView!
    var blackView: NSView!
    var statusItem: NSStatusItem!
    var lastTitle = ""
    var noScreenWarn = false

    // 舞台页（欢迎页/时钟/倒计时）
    var pageLoaded = false
    var stageMode = "welcome"
    var stageTarget: Date?

    // 实时翻译
    var sourceView: WKWebView!          // 翻译网页（在其他画面后面运行）
    var captionView: WKWebView!         // 字幕条
    var captionSetupWindow: NSWindow?
    var captionToday = false
    var captionForced: Bool?            // --caption / --nocaption
    var captionOverride: Bool?          // 菜单/快捷键手动开关；nil = 自动
    var captionOverrideBase = false     // 手动开关时“自动”应该是什么状态；自动状态变了就恢复自动
    var captionMode = "text"
    var captionFrom: HMSTime?
    var captionTo: HMSTime?
    var captionVisible = false
    var captionPageLoaded = false
    var sourceRequested = false
    var sourceState = "未载入"
    var sourceRetryAt: Date?
    var sourceOnTop = false
    var captionText = ""
    var captionTextAt: Date?
    var captionPath: String?
    var captionActivity = Date()

    // 快捷键
    let hotKeys = HotKeyCenter()
    var hotkeyActions: [UInt32: HotAction] = [:]
    var hotkeyLabels: [HotAction: String] = [:]
    var hotkeyReport: [String] = []
    var hotkeyProblems = 0
    var obsSummary = ""

    // 提示框
    let infoHUD = HUD(background: NSColor(white: 0.08, alpha: 0.92), fontSize: 15)
    let warnHUD = HUD(background: NSColor(calibratedRed: 0.78, green: 0.33, blue: 0.0, alpha: 0.96), fontSize: 17)
    var launchHUDShown = false

    var pdfFolderURL: URL {
        return expandPath(cfg.pdfFolder, base: baseDir)
    }

    var extendStep: TimeInterval {
        return testMode ? 10 : cfg.extendMinutes * 60
    }

    var warnLead: TimeInterval {
        return testMode ? min(cfg.warnSeconds, 5) : cfg.warnSeconds
    }

    func appNow() -> Date {
        return Date().addingTimeInterval(timeOffset)
    }

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArgs()
        if let d = dirArg {
            baseDir = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let b = Bundle.main.bundleURL
            baseDir = b.pathExtension == "app" ? b.deletingLastPathComponent() : b
        }
        setupLog()
        writeLog("===== Presenter 启动" + (testMode ? "（测试模式）" : "") + " =====")
        writeLog("工作文件夹：\(baseDir.path)")

        loadConfig()
        applyEvents()
        compileRules()
        validateCaption()
        if let at = atArg {
            let target = dateOn(Calendar.current.startOfDay(for: Date()), at)
            timeOffset = target.timeIntervalSince(Date())
            writeLog("模拟时间：从 \(hms(target)) 开始（--at）")
        }
        computeCaptionDay()
        captionMode = cfg.caption.mode

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Presenter 定时投影")

        setupWindow()
        loadStage()
        setupStatusItem()

        hotKeyHandler = { [weak self] id in self?.handleHotKey(id) }
        setupHotkeys()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)

        buildTimeline(appNow())
        lateLaunch = !testMode && sceneForEvent(autoIndex(appNow())) == .quit
        logSummary()
        periodicChecks()

        let t = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()

        // 启动提示：等第一次检查 PDF 文件夹完成后显示；最多等 2 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showLaunchHUD() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregisterAll()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        writeLog("===== Presenter 退出 =====")
    }

    // 程序已在运行时又被双击 / open：显示状态提示（新的启动参数不会生效）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        writeLog("再次打开：程序已在运行，新的启动参数不会生效")
        var note = "要换成测试模式等其他参数，请先退出"
        if let q = hotkeyLabels[.quit] { note += "（\(q)）" }
        note += "再打开"
        showHUD(title: "Presenter 已经在运行", note: note, seconds: 8)
        return false
    }

    func parseArgs() {
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--test":
                testMode = true
            case "--countdown":
                if let v = value(), let d = Double(v), d > 0 { testCountdown = d }
            case "--pdftime":
                if let v = value(), let d = Double(v), d > 0 { testPDFTime = d }
            case "--at":
                if let v = value() { atArg = parseHMS(v) }
            case "--dir":
                dirArg = value()
            case "--caption":
                captionForced = true
            case "--nocaption":
                captionForced = false
            case "--date":
                if let v = value() {
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyyMMdd"
                    dateOverride = f.date(from: v)
                }
            default:
                break
            }
            i += 1
        }
    }

    func setupLog() {
        let url = baseDir.appendingPathComponent("presenter.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        logFileURL = url
    }

    func loadConfig() {
        let url = baseDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeLog("没有找到 config.json，使用默认设置")
            return
        }
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            problems.append("config.json 格式有误，已使用默认设置")
            writeLog("⚠️ config.json 无法解析（检查逗号、引号），使用默认设置")
            return
        }
        if let arr = obj["schedule"] as? [[String: Any]] {
            var specs: [EventSpec] = []
            for item in arr {
                let at = (item["at"] as? String) ?? ""
                let show = (item["show"] as? String) ?? ""
                if at.isEmpty && show.isEmpty { continue }
                specs.append(EventSpec(at: at, show: show))
            }
            cfg.events = specs
        }
        if let v = obj["pdfFolder"] as? String, !v.isEmpty { cfg.pdfFolder = v }
        if let v = obj["dateFormat"] as? String, !v.isEmpty { cfg.dateFormat = v }
        if let p = obj["pdfs"] as? [String: Any] {
            var pats: [String: String] = [:]
            for (k, v) in p where !k.hasPrefix("_") {
                if let s = v as? String, !s.isEmpty { pats[k] = s }
            }
            if !pats.isEmpty { cfg.pdfPatterns = pats }
        }
        if let v = obj["screenName"] as? String { cfg.screenName = v }
        if let e = obj["extend"] as? [String: Any] {
            if let v = e["minutes"] as? Double, v > 0 { cfg.extendMinutes = v }
            if let v = e["warnSeconds"] as? Double, v >= 0 { cfg.warnSeconds = v }
            if let v = e["warnFor"] as? [String] { cfg.warnFor = v }
        }
        if let c = obj["caption"] as? [String: Any] {
            if let v = c["url"] as? String { cfg.caption.url = v.trimmingCharacters(in: .whitespaces) }
            if let v = c["when"] as? String { cfg.caption.when = v }
            if let v = c["showDuring"] as? [String] { cfg.caption.showDuring = v }
            if let v = c["from"] as? String { cfg.caption.from = v.trimmingCharacters(in: .whitespaces) }
            if let v = c["to"] as? String { cfg.caption.to = v.trimmingCharacters(in: .whitespaces) }
            if let v = c["heightPercent"] as? Double, v >= 5, v <= 50 { cfg.caption.heightPercent = v }
            if let v = c["lines"] as? Int, v >= 1, v <= 6 { cfg.caption.lines = v }
            if let v = c["mode"] as? String, v == "text" || v == "page" { cfg.caption.mode = v }
            if let v = c["textSelector"] as? String { cfg.caption.textSelector = v.trimmingCharacters(in: .whitespaces) }
            if let v = c["color"] as? String, !v.isEmpty { cfg.caption.color = v }
            if let v = c["background"] as? String, !v.isEmpty { cfg.caption.background = v }
            if let v = c["overlay"] as? Bool { cfg.caption.overlay = v }
            if let v = c["pageZoom"] as? Double, v > 0 { cfg.caption.pageZoom = v }
            if let v = c["reloadIfStaleMinutes"] as? Double, v >= 0 { cfg.caption.reloadIfStaleMinutes = v }
        }
        if let hk = obj["hotkeys"] as? [String: Any] {
            for (k, v) in hk where !k.hasPrefix("_") {
                if let arr = v as? [String] {
                    cfg.hotkeys[k] = arr
                } else if let s = v as? String {
                    cfg.hotkeys[k] = s.isEmpty ? [] : [s]
                }
            }
        }
    }

    /// 检查时间表；有错就改用默认时间表
    func applyEvents() {
        for k in Array(cfg.pdfPatterns.keys) where stageShows.contains(k) {
            problems.append("pdfs 里不能用“\(k)”这个名字，已忽略")
            cfg.pdfPatterns[k] = nil
        }
        var out: [ValidEvent] = []
        var err: String?
        for (i, e) in cfg.events.enumerated() {
            let n = i + 1
            guard let t = parseHMS(e.at) else {
                err = "时间表第 \(n) 项的时间“\(e.at)”格式不对（应为 HH:MM:SS）"
                break
            }
            if !stageShows.contains(e.show) && cfg.pdfPatterns[e.show] == nil {
                err = "时间表第 \(n) 项的“\(e.show)”不认识（可用 welcome、clock、countdown、quit 或 pdfs 里的名字）"
                break
            }
            if let last = out.last {
                if last.show == "quit" {
                    err = "quit 必须是时间表的最后一项"
                    break
                }
                if seconds(t) <= seconds(last.t) {
                    err = "时间表第 \(n) 项的时间没有比上一项晚"
                    break
                }
            }
            out.append(ValidEvent(t: t, show: e.show))
        }
        if err == nil {
            if out.isEmpty {
                err = "时间表是空的"
            } else if out.last?.show == "countdown" {
                err = "countdown 后面必须还有一项（倒计时到下一项开始为止）"
            }
        }
        if let e = err {
            problems.append(e + "，已改用默认时间表")
            writeLog("⚠️ " + e + "，已改用默认时间表")
            for (k, v) in defaultPDFPatterns where cfg.pdfPatterns[k] == nil { cfg.pdfPatterns[k] = v }
            out = defaultEventSpecs.compactMap { s in parseHMS(s.at).map { ValidEvent(t: $0, show: s.show) } }
        }
        validEvents = out
    }

    func validateCaption() {
        let known = stageShows.union(cfg.pdfPatterns.keys)
        for s in cfg.caption.showDuring where !known.contains(s) || s == "quit" {
            problems.append("caption.showDuring 里的“\(s)”不认识")
        }
        if !cfg.caption.from.isEmpty {
            if let t = parseHMS(cfg.caption.from) { captionFrom = t } else {
                problems.append("caption.from 的时间“\(cfg.caption.from)”格式不对（应为 HH:MM:SS），已忽略")
            }
        }
        if !cfg.caption.to.isEmpty {
            if let t = parseHMS(cfg.caption.to) { captionTo = t } else {
                problems.append("caption.to 的时间“\(cfg.caption.to)”格式不对（应为 HH:MM:SS），已忽略")
            }
        }
        if !["firstSunday", "sunday", "always", "never"].contains(cfg.caption.when) {
            problems.append("caption.when 只能是 firstSunday、sunday、always、never，已按 firstSunday 处理")
            cfg.caption.when = "firstSunday"
        }
    }

    /// 今天要不要自动显示实时翻译
    func computeCaptionDay() {
        if let f = captionForced {
            captionToday = f
            return
        }
        let d = dateOverride ?? appNow()
        let c = Calendar.current.dateComponents([.weekday, .day], from: d)
        let isSunday = c.weekday == 1
        switch cfg.caption.when {
        case "always": captionToday = true
        case "never": captionToday = false
        case "sunday": captionToday = isSunday
        default: captionToday = isSunday && (c.day ?? 99) <= 7
        }
    }

    func pdfDateString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = cfg.dateFormat
        return f.string(from: dateOverride ?? appNow())
    }

    /// 把 {date} 换成当天日期，编译成正则表达式
    func compileRules() {
        rules = [:]
        rulePatterns = [:]
        let date = NSRegularExpression.escapedPattern(for: pdfDateString())
        for (key, pattern) in cfg.pdfPatterns {
            let p = pattern.replacingOccurrences(of: "{date}", with: date)
            do {
                rules[key] = try NSRegularExpression(pattern: p, options: [])
                rulePatterns[key] = p
            } catch {
                problems.append("PDF 规则“\(key)”不是有效的正则表达式：\(pattern)")
            }
        }
    }

    func buildTimeline(_ now: Date) {
        if testMode {
            var t = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970) + 1)
            timeline = []
            for e in validEvents {
                timeline.append(TimelineEvent(at: t, show: e.show))
                t = t.addingTimeInterval(testDuration(e.show))
            }
        } else {
            let day = Calendar.current.startOfDay(for: now)
            timeline = validEvents.map { TimelineEvent(at: dateOn(day, $0.t), show: $0.show) }
        }
        writeLog("时间表：" + timelineSummary(" → "))
    }

    func testDuration(_ show: String) -> TimeInterval {
        switch show {
        case "welcome": return 5
        case "clock": return 6
        case "countdown": return testCountdown ?? 10
        case "quit": return 0
        default: return testPDFTime ?? 15
        }
    }

    func timelineSummary(_ sep: String) -> String {
        return timeline.map { "\(shortTime($0.at)) \(showLabel($0.show))" }.joined(separator: sep)
    }

    /// 时间表里出现的 PDF 名称（按顺序，不重复）
    func pdfKeys() -> [String] {
        var keys: [String] = []
        for e in timeline where isPDFShow(e.show) && !keys.contains(e.show) { keys.append(e.show) }
        return keys
    }

    // MARK: 窗口

    func setupWindow() {
        let initial = NSRect(x: 0, y: 0, width: 1280, height: 720)
        panel = StagePanel(contentRect: initial, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .white
        panel.isOpaque = true
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.title = "Presenter"

        let c = StageContainer(frame: initial)
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor.white.cgColor
        c.autoresizesSubviews = false
        c.onResize = { [weak self] in self?.layoutContent() }
        panel.contentView = c
        container = c

        // 最底层：实时翻译网页。在其他画面后面运行，用来提取文字；“原网页”方式时移到字幕区显示
        let sc = WKWebViewConfiguration()
        sc.mediaTypesRequiringUserActionForPlayback = .all
        sc.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
        let js = captionSourceJS.replacingOccurrences(of: "__SELECTOR__", with: jsString(cfg.caption.textSelector))
        sc.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        sc.userContentController.add(self, name: "presenter")
        sourceView = WKWebView(frame: c.bounds, configuration: sc)
        sourceView.navigationDelegate = self
        c.addSubview(sourceView)

        // 舞台页（欢迎页/时钟/倒计时）
        webView = WKWebView(frame: c.bounds, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        c.addSubview(webView)

        // PDF
        pdfView = PDFView(frame: c.bounds)
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = .black
        pdfView.autoScales = true
        pdfView.isHidden = true
        c.addSubview(pdfView)

        // 字幕条
        captionView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        captionView.navigationDelegate = self
        if cfg.caption.background.lowercased() == "transparent" {
            // 透明背景：字直接显示在 PDF 上（需要关掉网页视图自己的白底）
            if captionView.responds(to: NSSelectorFromString("setDrawsBackground:"))
                || captionView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
                captionView.setValue(false, forKey: "drawsBackground")
            } else {
                problems.append("这台 Mac 不支持透明的字幕条背景，已改用黑色")
                cfg.caption.background = "#000000"
            }
        }
        captionView.isHidden = true
        c.addSubview(captionView)
        captionView.loadHTMLString(captionHTML, baseURL: nil)

        // 最上层：黑屏
        blackView = NSView(frame: c.bounds)
        blackView.wantsLayer = true
        blackView.layer?.backgroundColor = NSColor.black.cgColor
        blackView.isHidden = true
        c.addSubview(blackView)

        layoutContent()
    }

    /// 排版：有字幕条时，PDF/舞台页在上方，字幕条在下方
    func layoutContent() {
        guard let c = container, webView != nil, pdfView != nil, captionView != nil,
              sourceView != nil, blackView != nil else { return }
        let b = c.bounds
        let capH = captionVisible ? (b.height * CGFloat(cfg.caption.heightPercent) / 100).rounded() : 0
        let capRect = NSRect(x: 0, y: 0, width: b.width, height: capH)
        var mainRect = b
        if captionVisible && !cfg.caption.overlay {
            mainRect = NSRect(x: 0, y: capH, width: b.width, height: b.height - capH)
        }
        webView.frame = mainRect
        pdfView.frame = mainRect
        blackView.frame = b

        let pageOnTop = captionVisible && captionMode == "page"
        if pageOnTop != sourceOnTop {
            sourceOnTop = pageOnTop
            if pageOnTop {
                c.addSubview(sourceView, positioned: .below, relativeTo: blackView)
            } else {
                c.addSubview(sourceView, positioned: .below, relativeTo: webView)
            }
        }
        sourceView.frame = pageOnTop ? capRect : b
        captionView.frame = capRect
        captionView.isHidden = !(captionVisible && captionMode == "text")
        if pdfShownKey != nil {
            pdfView.autoScales = true
            pdfView.layoutDocumentView()
        }
    }

    func loadStage() {
        pageLoaded = false
        let url = baseDir.appendingPathComponent("stage.html")
        if FileManager.default.fileExists(atPath: url.path) {
            webView.loadFileURL(url, allowingReadAccessTo: baseDir)
        } else {
            writeLog("⚠️ 没找到 stage.html，使用内置的简易页面")
            webView.loadHTMLString(fallbackStageHTML, baseURL: nil)
        }
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        if wv === sourceView {
            sourceState = "✅ 已载入"
            writeLog("实时翻译网页：已载入")
            applySourceMode()
        } else if wv === captionView {
            captionPageLoaded = true
            applyCaptionStyle()
            pushCaption(captionText)
        } else {
            pageLoaded = true
            pushStageMode()
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(wv, error)
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(wv, error)
    }

    func handleLoadError(_ wv: WKWebView, _ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }  // 被新的载入取消，正常
        if wv === sourceView {
            sourceState = "⚠️ 载入失败：\(error.localizedDescription)"
            sourceRetryAt = appNow().addingTimeInterval(15)
            writeLog("⚠️ 实时翻译网页载入失败：\(error.localizedDescription)，15 秒后重试")
        } else if wv === captionView {
            writeLog("⚠️ 字幕条页面载入失败：\(error.localizedDescription)")
        } else {
            writeLog("⚠️ 舞台页加载失败：\(error.localizedDescription)")
        }
    }

    func webViewWebContentProcessDidTerminate(_ wv: WKWebView) {
        if wv === sourceView {
            loadSource("网页进程意外退出，重新载入")
        } else if wv === captionView {
            writeLog("⚠️ 字幕条进程意外退出，重新载入")
            captionPageLoaded = false
            captionView.loadHTMLString(captionHTML, baseURL: nil)
        } else {
            writeLog("⚠️ 舞台页进程意外退出，重新载入")
            loadStage()
        }
    }

    func pushStageMode() {
        guard pageLoaded else { return }
        var target: Int64 = 0
        if let t = stageTarget { target = Int64(t.timeIntervalSince1970 * 1000) }
        let offset = Int64(timeOffset * 1000)
        let js = "window.setMode && window.setMode('\(stageMode)', \(target), \(offset))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func isBuiltIn(_ s: NSScreen) -> Bool {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(n.uint32Value) != 0
    }

    func builtInScreen() -> NSScreen? {
        return NSScreen.screens.first(where: { isBuiltIn($0) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    func screenLabel(_ s: NSScreen) -> String {
        var label = "\(s.localizedName)（\(Int(s.frame.width))×\(Int(s.frame.height))"
        if isBuiltIn(s) { label += "，内建" }
        label += "）"
        return label
    }

    /// 投影屏：优先按 config 里的 screenName 匹配，否则取第一块非内建屏。
    /// 只有一块屏时不算投影屏（避免盖住 OBS）。
    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { return nil }
        let wanted = cfg.screenName.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty, let s = screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(wanted) }) {
            return s
        }
        return screens.first(where: { !isBuiltIn($0) })
    }

    func placePanel() {
        if let s = targetScreen() {
            panel.level = .screenSaver
            if panel.frame != s.frame { panel.setFrame(s.frame, display: true) }
        } else if testMode, let s = NSScreen.main ?? NSScreen.screens.first {
            // 测试且没有外接屏：在当前屏幕中间开一个小预览窗
            let f = s.visibleFrame
            let w = (f.width * 0.55).rounded()
            let h = (w * 9 / 16).rounded()
            panel.level = .floating
            panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        } else {
            panel.orderOut(nil)
            return
        }
        panel.orderFrontRegardless()
    }

    @objc func screensChanged(_ note: Notification) {
        writeLog("显示器变化：" + NSScreen.screens.map { screenLabel($0) }.joined(separator: "，"))
        if currentScene.isVisible { placePanel() } else { panel.orderOut(nil) }
        layoutContent()
        periodicChecks()
    }

    @objc func didWake(_ note: Notification) {
        writeLog("系统唤醒")
        if sourceRequested { loadSource("系统唤醒后重新载入") }
        tick()
    }

    // MARK: 时间表

    /// 当前时间落在时间表第几项（-1 = 第一项之前）
    func autoIndex(_ now: Date) -> Int {
        var idx = -1
        for (i, e) in timeline.enumerated() {
            if e.at <= now { idx = i } else { break }
        }
        return idx
    }

    /// 考虑“延长”之后的当前项：延长期间停在被延长的那一项
    func baseIndex(_ now: Date) -> Int {
        var idx = autoIndex(now)
        if let u = holdUntil, now < u, idx > holdIndex { idx = holdIndex }
        return idx
    }

    /// 正在显示的是时间表第几项（手动切换时是手动对应的那项）
    func currentItemIndex(_ now: Date) -> Int {
        return manual != nil ? manualIndex : baseIndex(now)
    }

    /// 当前画面什么时候结束（考虑延长）
    func currentEnd(_ now: Date) -> Date? {
        let i = currentItemIndex(now)
        guard i >= 0, i + 1 < timeline.count else { return nil }
        var end = timeline[i + 1].at
        if let u = holdUntil, holdIndex == i, u > end { end = u }
        return end
    }

    func sceneForEvent(_ i: Int) -> Scene {
        guard i >= 0, i < timeline.count else { return .waiting }
        let e = timeline[i]
        switch e.show {
        case "welcome": return .welcome
        case "clock": return .clock
        case "countdown":
            let end = i + 1 < timeline.count ? timeline[i + 1].at : e.at.addingTimeInterval(90)
            return .countdown(end)
        case "quit": return .quit
        default: return .pdf(e.show)
        }
    }

    /// 倒计时长度：时间表里倒计时那一项到下一项的间隔（默认 90 秒）
    func countdownLength(at i: Int) -> TimeInterval {
        if i >= 0, i + 1 < timeline.count, timeline[i].show == "countdown" {
            return timeline[i + 1].at.timeIntervalSince(timeline[i].at)
        }
        if let j = timeline.indices.first(where: { timeline[$0].show == "countdown" }), j + 1 < timeline.count {
            return timeline[j + 1].at.timeIntervalSince(timeline[j].at)
        }
        return 90
    }

    func sceneFor(show: String, index k: Int, now: Date) -> Scene {
        switch show {
        case "welcome": return .welcome
        case "clock": return .clock
        case "countdown": return .countdown(now.addingTimeInterval(countdownLength(at: k)))
        case "quit": return .quit
        default: return .pdf(show)
        }
    }

    /// 手动切换对应时间表的哪一项：当前项就是它 → 当前项；否则 → 后面第一次出现它的那项；
    /// 都没有 → 当前项。手动切换在这一项结束时自动失效，恢复按时间表。
    func manualIndexFor(_ show: String, now: Date) -> Int {
        let cur = baseIndex(now)
        if cur >= 0, cur < timeline.count, timeline[cur].show == show { return cur }
        if let j = timeline.indices.first(where: { $0 > cur && timeline[$0].show == show }) { return j }
        return max(cur, 0)
    }

    func setManual(_ show: String) {
        let now = appNow()
        holdUntil = nil
        holdIndex = -1
        let k = manualIndexFor(show, now: now)
        manual = sceneFor(show: show, index: k, now: now)
        manualIndex = k
        var until = "一直保持"
        if k + 1 < timeline.count { until = "保持到 \(shortTime(timeline[k + 1].at))" }
        writeLog("手动：\(showLabel(show))（\(until)，之后恢复按时间表）")
        tick()
    }

    /// ⌃⌥P：当前时段的 PDF；不在 PDF 时段 → 下一个 PDF；都过了 → 最后一个 PDF
    func pdfNowShow() -> String? {
        let cur = baseIndex(appNow())
        if cur >= 0, cur < timeline.count, isPDFShow(timeline[cur].show) { return timeline[cur].show }
        if let j = timeline.indices.first(where: { $0 > cur && isPDFShow(timeline[$0].show) }) { return timeline[j].show }
        return timeline.last(where: { isPDFShow($0.show) })?.show
    }

    /// ⌃⌥E：当前画面延长一段时间（可连按）
    func extendCurrent() {
        let now = appNow()
        switch currentScene {
        case .countdown:
            infoHUD.show("倒计时不能延长（它按时间表结束）", on: builtInScreen(), seconds: 3)
            return
        case .waiting, .quit:
            infoHUD.show("现在没有可延长的画面", on: builtInScreen(), seconds: 3)
            return
        default:
            break
        }
        let i = currentItemIndex(now)
        guard i >= 0, let end = currentEnd(now) else {
            infoHUD.show("当前画面是时间表的最后一项，不需要延长", on: builtInScreen(), seconds: 3)
            return
        }
        let newEnd = max(end, now).addingTimeInterval(extendStep)
        holdIndex = i
        holdUntil = newEnd
        writeLog("延长：\(currentScene.label) 保持到 \(hms(newEnd))")
        warnHUD.hide()
        var msg = "已延长：\(currentScene.label) 保持到 \(hms(newEnd))"
        var tips: [String] = []
        if let e = hotkeyLabels[.extend] { tips.append("再按 \(e) 继续延长") }
        if let r = hotkeyLabels[.auto] { tips.append("取消延长：\(r)") }
        if !tips.isEmpty { msg += "\n" + tips.joined(separator: "　·　") }
        infoHUD.show(msg, on: builtInScreen(), seconds: 6)
        tick()
    }

    @objc func tick() {
        let now = appNow()
        tickCount &+= 1
        if tickCount % 40 == 0 { periodicChecks() }  // 约每 2 秒

        if let u = holdUntil, now >= u {
            holdUntil = nil
            holdIndex = -1
            writeLog("延长时间到，恢复按时间表")
        }
        let idx = baseIndex(now)
        if manual != nil, idx > manualIndex {
            manual = nil
            writeLog("手动切换到期，恢复按时间表")
        }
        // 手动倒计时结束 → 时间表里倒计时后面那一项
        if case .countdown(let t)? = manual, now >= t {
            let k = manualIndex + 1
            if k < timeline.count {
                manual = sceneFor(show: timeline[k].show, index: k, now: now)
                manualIndex = k
            } else {
                manual = nil
            }
        }

        let desired: Scene
        let desiredIndex: Int
        if let m = manual {
            desired = m
            desiredIndex = manualIndex
        } else {
            desired = sceneForEvent(idx)
            desiredIndex = idx
        }

        if !applied || desired != currentScene {
            apply(desired, index: desiredIndex)
            applied = true
        }
        updateCaptionVisibility(now)

        // PDF 时间到了但文件缺失/打不开：每 2 秒重试
        if case .pdf(let key) = currentScene, pdfShownKey == nil, tickCount % 40 == 0 {
            if showPDF(key) { writeLog("\(key)：文件已找到，开始显示") }
        }

        if tickCount % 20 == 0 {
            preloadUpcoming(now)
            captionTick(now)
        }
        if tickCount % 10 == 0 { checkEndWarning(now) }
        updateStatusTitle(now)
    }

    func apply(_ s: Scene, index: Int) {
        let old = currentScene
        currentScene = s
        sceneIndex = index
        writeLog("切换：\(old.label) → \(s.label)" + (manual == nil ? "" : "（手动）"))
        warnHUD.hide()
        switch s {
        case .waiting:
            closePDF()
            panel.orderOut(nil)
        case .quit:
            closePDF()
            panel.orderOut(nil)
            scheduleQuit()
        case .welcome:
            showStage("welcome", target: nil)
        case .clock:
            showStage("clock", target: nil)
        case .countdown(let t):
            showStage("countdown", target: t)
        case .pdf(let key):
            if pdfShownKey != key { closePDF() }
            if !showPDF(key, restore: manual != nil) {
                writeLog("⚠️ \(key)：找不到或打不开 PDF，先显示前一个画面，每 2 秒重试")
                showFallback(forIndex: index)
            }
        }
    }

    func showStage(_ mode: String, target: Date?) {
        closePDF()
        stageMode = mode
        stageTarget = target
        pushStageMode()
        placePanel()
    }

    /// PDF 缺失时显示的画面：前一项是时钟 → 时钟；是倒计时 → 结束语（如“敬拜马上开始!”）；其他 → 欢迎页
    func showFallback(forIndex i: Int) {
        let prev = (i >= 1 && i - 1 < timeline.count) ? timeline[i - 1].show : "welcome"
        switch prev {
        case "clock": showStage("clock", target: nil)
        case "countdown": showStage("countdown", target: appNow())
        default: showStage("welcome", target: nil)
        }
    }

    func scheduleQuit() {
        if quitPending { return }
        quitPending = true
        let delay: TimeInterval = lateLaunch ? 10 : 1
        if lateLaunch {
            writeLog("启动时今天的时间表已结束，\(Int(delay)) 秒后退出")
        } else {
            writeLog("到达退出时间，Presenter 退出")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSApp.terminate(nil)
        }
    }

    /// PDF 结束前在内建屏上方提醒，可以按 ⌃⌥E 延长
    func checkEndWarning(_ now: Date) {
        guard warnLead > 0, case .pdf(let key) = currentScene, warnApplies(key),
              let end = currentEnd(now) else {
            warnHUD.hide()
            return
        }
        let left = end.timeIntervalSince(now)
        guard left > 0, left <= warnLead else {
            warnHUD.hide()
            return
        }
        let j = autoIndex(end)
        let nextShow = (j >= 0 && j < timeline.count) ? timeline[j].show : "welcome"
        let action = nextShow == "quit" ? "Presenter 将退出" : "切换到\(showLabel(nextShow))"
        var lines = ["⏰ \(Int(ceil(left))) 秒后（\(hms(end))）关闭 \(key)，\(action)"]
        if let e = hotkeyLabels[.extend] {
            lines.append("需要延长请按 \(e)（每按一次 +\(durationText(extendStep))）；不操作就按时切换")
        } else {
            lines.append("需要延长：菜单栏图标 › 延长当前画面")
        }
        if holdUntil != nil, let r = hotkeyLabels[.auto] {
            lines.append("（已延长过；取消延长：\(r)）")
        }
        warnHUD.show(lines.joined(separator: "\n"), on: builtInScreen(), seconds: nil)
    }

    func warnApplies(_ key: String) -> Bool {
        if let list = cfg.warnFor { return list.contains(key) }
        return true
    }

    // MARK: PDF

    func requestScan() {
        if scanInFlight { return }
        scanInFlight = true
        let folder = pdfFolderURL
        let date = pdfDateString()
        let r = rules
        // 在后台线程读文件夹：第一次读“下载”时系统会弹权限请求，不会卡住画面
        scanQueue.async {
            let result = scanPDFFolder(folder, date: date, rules: r)
            DispatchQueue.main.async {
                self.scanFinished(result)
            }
        }
    }

    func rescanNow() {
        scanFinished(scanPDFFolder(pdfFolderURL, date: pdfDateString(), rules: rules))
    }

    func scanFinished(_ r: PDFScan) {
        let old = scan
        scan = r
        scanInFlight = false
        if r.readable != old.readable || (!old.checked && !r.readable) {
            if r.readable {
                writeLog("PDF 文件夹可以读取：\(pdfFolderURL.path)")
            } else {
                writeLog("⚠️ PDF 文件夹无法读取：\(r.error)")
            }
        }
        for key in pdfKeys() where old.matches[key] != r.matches[key] || !old.checked {
            if let u = r.matches[key] {
                writeLog("\(key)：✅ \(u.lastPathComponent)")
            } else if r.readable {
                writeLog("\(key)：⚠️ 还没有符合规则的文件（\(rulePatterns[key] ?? "?")）")
            }
        }
        if r.unused != old.unused && !r.unused.isEmpty {
            writeLog("注意：含今天日期但不符合规则（不会使用）：" + r.unused.joined(separator: "、"))
        }
        // 正处在 PDF 时段但还没显示（例如程序晚开、文件刚放进来）：马上再试
        if case .pdf(let key) = currentScene, pdfShownKey == nil, showPDF(key) {
            writeLog("\(key)：文件已找到，开始显示")
        }
        if !launchHUDShown { showLaunchHUD() }
    }

    func pdfURL(for key: String) -> URL? {
        if let u = scan.matches[key] { return u }
        if testMode {
            let u = baseDir.appendingPathComponent("pdf/sample.pdf")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 载入 PDF（文件没变就用已载入的）
    func loadDoc(_ key: String) -> PDFDocument? {
        guard let url = pdfURL(for: key) else { return nil }
        let mod = modDate(url)
        if let c = docCache[key], c.url == url, c.mod == mod { return c.doc }
        let tag = url.path + "|" + String(mod?.timeIntervalSince1970 ?? 0)
        if badFiles.contains(tag) { return nil }
        guard let doc = PDFDocument(url: url) else {
            writeLog("⚠️ 无法打开 PDF：\(url.path)")
            badFiles.insert(tag)
            return nil
        }
        if doc.isLocked && !doc.unlock(withPassword: "") {
            writeLog("⚠️ PDF 有密码，无法打开：\(url.path)")
            badFiles.insert(tag)
            return nil
        }
        guard doc.pageCount > 0 else {
            writeLog("⚠️ PDF 没有页面：\(url.path)")
            badFiles.insert(tag)
            return nil
        }
        docCache[key] = CachedDoc(url: url, mod: mod, doc: doc)
        writeLog("已载入 \(key)：\(url.lastPathComponent)（\(doc.pageCount) 页）")
        return doc
    }

    /// 显示 PDF 第一页；restore = 手动重新打开时，回到 15 分钟内关闭时的那一页
    func showPDF(_ key: String, restore: Bool = false) -> Bool {
        guard let doc = loadDoc(key) else { return false }
        if pdfView.document !== doc { pdfView.document = doc }
        var target = 0
        if restore, let lp = lastPages[key], appNow().timeIntervalSince(lp.at) < 900 {
            target = max(0, min(lp.index, doc.pageCount - 1))
        }
        if let pg = doc.page(at: target) { pdfView.go(to: pg) }
        if target > 0 { writeLog("\(key)：回到刚才的第 \(target + 1) 页") }
        pdfView.isHidden = false
        pdfShownKey = key
        placePanel()
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        hidePDFScrollers()
        return true
    }

    /// 关闭正在显示的 PDF
    func closePDF() {
        pdfView.isHidden = true
        guard let k = pdfShownKey else { return }
        if let d = pdfView.document, let p = pdfView.currentPage {
            lastPages[k] = (index: d.index(for: p), at: appNow())
        }
        pdfView.document = nil
        docCache[k] = nil
        pdfShownKey = nil
        writeLog("关闭 \(k)")
    }

    /// 下一项是 PDF 且 2 分钟内开始：提前载入，切换时立刻显示
    func preloadUpcoming(_ now: Date) {
        let j = currentItemIndex(now) + 1
        guard j >= 0, j < timeline.count, isPDFShow(timeline[j].show) else { return }
        guard timeline[j].at.timeIntervalSince(now) < 120 else { return }
        _ = loadDoc(timeline[j].show)
    }

    func hidePDFScrollers() {
        if let sv = pdfView.documentView?.enclosingScrollView {
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
        }
    }

    // MARK: 实时翻译

    func shouldShowCaption(_ now: Date) -> Bool {
        guard currentScene.isVisible else { return false }
        if let o = captionOverride { return o }
        return captionAutoVisible(now)
    }

    /// 按日期、画面和时段，现在应不应该自动显示
    func captionAutoVisible(_ now: Date) -> Bool {
        return captionToday && cfg.caption.showDuring.contains(currentScene.key) && captionInWindow(now)
    }

    /// 在 caption.from ~ caption.to 时段内（测试模式的时间表是压缩的，不看时段）
    func captionInWindow(_ now: Date) -> Bool {
        if testMode { return true }
        let day = Calendar.current.startOfDay(for: now)
        if let f = captionFrom, now < dateOn(day, f) { return false }
        if let t = captionTo, now >= dateOn(day, t) { return false }
        return true
    }

    /// 下一次自动显示实时翻译的时间（画面开始时间和 from 时间取较晚的）
    func nextCaptionStart(_ now: Date) -> Date? {
        let day = Calendar.current.startOfDay(for: now)
        var start: Date?
        if cfg.caption.showDuring.contains(currentScene.key) {
            start = now
        } else {
            let idx = currentItemIndex(now)
            if let j = timeline.indices.first(where: { $0 > idx && cfg.caption.showDuring.contains(timeline[$0].show) }) {
                start = timeline[j].at
            }
        }
        guard var s = start else { return nil }
        if !testMode {
            if let f = captionFrom, dateOn(day, f) > s { s = dateOn(day, f) }
            if let t = captionTo, s >= dateOn(day, t) { return nil }
        }
        return s
    }

    /// 现在或 2 分钟内要显示实时翻译 → 需要载入网页
    func captionNeededSoon(_ now: Date) -> Bool {
        if shouldShowCaption(now) || captionOverride == true { return true }
        if captionOverride == false || !captionToday { return false }
        guard let start = nextCaptionStart(now) else { return false }
        return start.timeIntervalSince(now) < 120
    }

    func updateCaptionVisibility(_ now: Date) {
        // 手动开关只管到下一个自动开关点（例如 10:40 自动打开、画面结束自动关闭），之后恢复自动
        if captionOverride != nil && captionAutoVisible(now) != captionOverrideBase {
            captionOverride = nil
            writeLog("实时翻译：到了自动开关的时间，恢复自动")
        }
        let show = shouldShowCaption(now)
        guard show != captionVisible else { return }
        captionVisible = show
        writeLog(show ? "显示实时翻译" : "隐藏实时翻译")
        layoutContent()
        if show { applySourceMode() }
    }

    func captionTick(_ now: Date) {
        guard captionNeededSoon(now) else { return }
        if !sourceRequested {
            loadSource("开始载入")
        } else if let r = sourceRetryAt, now >= r {
            loadSource("重试")
        } else if captionVisible, captionPath != nil, cfg.caption.reloadIfStaleMinutes > 0,
                  now.timeIntervalSince(captionActivity) > cfg.caption.reloadIfStaleMinutes * 60 {
            loadSource("文字超过 \(durationText(cfg.caption.reloadIfStaleMinutes * 60)) 没有更新，重新载入")
        }
    }

    func loadSource(_ why: String) {
        sourceRequested = true
        sourceRetryAt = nil
        captionPath = nil
        captionActivity = appNow()
        guard let url = URL(string: cfg.caption.url), url.scheme == "https" || url.scheme == "http" else {
            sourceState = "⚠️ 网址无效：\(cfg.caption.url)"
            writeLog("⚠️ 实时翻译网址无效：\(cfg.caption.url)")
            return
        }
        sourceState = "载入中…"
        writeLog("实时翻译网页：\(why)（\(url.absoluteString)）")
        sourceView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "presenter", let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "text" {
            let t = (body["text"] as? String) ?? ""
            if t != captionText {
                captionText = t
                if !t.isEmpty {
                    captionTextAt = appNow()
                    captionActivity = appNow()
                }
                pushCaption(t)
            }
        } else if type == "status" {
            let path = (body["path"] as? String) ?? ""
            if path != (captionPath ?? "") {
                captionPath = path.isEmpty ? nil : path
                let order = (body["newestFirst"] as? Bool) == true ? "新内容在顶部" : "新内容在底部"
                writeLog("实时翻译：文字区域 = \(path)（\(order)）")
            }
        }
    }

    func pushCaption(_ t: String) {
        guard captionPageLoaded else { return }
        captionView.evaluateJavaScript("window.setCaption && window.setCaption(\(jsString(t)))", completionHandler: nil)
    }

    func applyCaptionStyle() {
        guard captionPageLoaded else { return }
        let c = cfg.caption
        let js = "window.setStyle && window.setStyle(\(jsString(c.color)), \(jsString(c.background)), \(c.lines), \(jsString("实时翻译 · Live Translation")))"
        captionView.evaluateJavaScript(js, completionHandler: nil)
    }

    func applySourceMode() {
        guard sourceRequested else { return }
        let js = "window.__presenterSetMode && window.__presenterSetMode(\(jsString(captionMode)), \(cfg.caption.pageZoom))"
        sourceView.evaluateJavaScript(js, completionHandler: nil)
    }

    func setCaptionOverride(_ v: Bool?) {
        captionOverride = v
        captionOverrideBase = captionAutoVisible(appNow())
        let text = v == nil ? "自动" : (v == true ? "显示（手动）" : "隐藏（手动）")
        writeLog("实时翻译：\(text)")
        var hint = ""
        if let k = hotkeyLabels[.caption], v != nil { hint = "\n再按 \(k) " + (v == true ? "隐藏" : "显示") }
        infoHUD.show("实时翻译：\(text)\(hint)", on: builtInScreen(), seconds: 3)
        if v == true && !sourceRequested { loadSource("手动打开") }
        tick()
    }

    func setCaptionMode(_ m: String) {
        guard m != captionMode else { return }
        captionMode = m
        writeLog("实时翻译显示方式：\(m == "page" ? "原网页" : "提取文字")")
        applySourceMode()
        layoutContent()
    }

    /// 打开一个可以点击的翻译网页窗口（首次需要选语言等设置时用；和投影里的网页共用设置）
    func openCaptionSetupWindow() {
        guard let url = URL(string: cfg.caption.url) else { return }
        let w: NSWindow
        if let existing = captionSetupWindow {
            w = existing
        } else {
            let frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
            w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = "实时翻译网页（设置用；关闭后在菜单里选“重新载入翻译网页”）"
            let c = WKWebViewConfiguration()
            c.mediaTypesRequiringUserActionForPlayback = .all
            c.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
            let wv = WKWebView(frame: frame, configuration: c)
            wv.autoresizingMask = [.width, .height]
            w.contentView = wv
            captionSetupWindow = w
        }
        (w.contentView as? WKWebView)?.load(URLRequest(url: url))
        if let s = builtInScreen() {
            let vf = s.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// 保存翻译网页的结构、截图和提取情况（发给开发者调整文字提取用）
    func dumpCaptionPage() {
        guard sourceRequested else {
            infoHUD.show("翻译网页还没有载入：先在菜单里选“显示”或“重新载入翻译网页”", on: builtInScreen(), seconds: 5)
            return
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let htmlURL = baseDir.appendingPathComponent("caption-dump-\(stamp).html")
        let infoURL = baseDir.appendingPathComponent("caption-dump-\(stamp).txt")
        let pngURL = baseDir.appendingPathComponent("caption-dump-\(stamp).png")
        let js = "window.__presenterDump ? window.__presenterDump() : JSON.stringify({html: document.documentElement.outerHTML})"
        sourceView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            var info = "时间：\(stamp)\n设置的网址：\(self.cfg.caption.url)\n显示方式：\(self.captionMode)\n网页状态：\(self.sourceState)\n"
            if let s = result as? String, let d = s.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any] {
                if let html = obj["html"] as? String {
                    try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
                }
                info += "当前网址：\(obj["url"] as? String ?? "")\n"
                info += "文字区域：\(obj["path"] as? String ?? "")\n"
                info += "新内容在顶部：\(obj["newestFirst"] as? Bool ?? false)\n"
                info += "选择器：\(obj["selector"] as? String ?? "")\n"
                info += "提取到的文字：\(obj["sample"] as? String ?? "")\n"
            } else {
                info += "⚠️ 读取网页失败：\(error?.localizedDescription ?? "未知原因")\n"
            }
            try? info.write(to: infoURL, atomically: true, encoding: .utf8)
            self.sourceView.takeSnapshot(with: nil) { image, _ in
                if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: pngURL)
                }
                writeLog("已保存翻译网页结构：caption-dump-\(stamp).html / .txt / .png")
                self.infoHUD.show("已保存到 Presenter 文件夹：caption-dump-\(stamp).html / .txt / .png", on: self.builtInScreen(), seconds: 6)
            }
        }
    }

    // MARK: 快捷键

    func setupHotkeys() {
        let obs = loadOBSBindings()
        obsSummary = obs.files == 0
            ? "OBS 快捷键：没找到 OBS 设置文件（请人工核对）"
            : "OBS 快捷键：已读取 \(obs.bindings.count) 个绑定并自动避开"
        hotKeys.install()
        var nextID: UInt32 = 1
        for action in HotAction.allCases {
            let combos = cfg.hotkeys[action.rawValue] ?? []
            if combos.isEmpty { continue }
            var shown: [String] = []
            for raw in combos {
                switch parseCombo(raw) {
                case .fail(let msg):
                    hotkeyProblems += 1
                    shown.append("⚠️“\(raw)”\(msg)")
                case .ok(let c):
                    if obs.bindings.contains(c.obs) {
                        hotkeyProblems += 1
                        shown.append("⚠️\(c.display) 与 OBS 快捷键相同，未启用")
                        continue
                    }
                    let st = hotKeys.register(c, id: nextID)
                    if st == 0 {
                        hotkeyActions[nextID] = action
                        nextID += 1
                        shown.append(c.display)
                        if hotkeyLabels[action] == nil { hotkeyLabels[action] = c.display }
                    } else if st == OSStatus(eventHotKeyExistsErr) {
                        hotkeyProblems += 1
                        shown.append("⚠️\(c.display) 已被其他程序占用")
                    } else {
                        hotkeyProblems += 1
                        shown.append("⚠️\(c.display) 注册失败（\(st)）")
                    }
                }
            }
            hotkeyReport.append(action.title + "：" + shown.joined(separator: "  "))
        }
        for k in cfg.hotkeys.keys.sorted() where HotAction(rawValue: k) == nil {
            hotkeyProblems += 1
            hotkeyReport.append("⚠️ config.json 里有不认识的动作“\(k)”")
        }
    }

    func handleHotKey(_ id: UInt32) {
        guard let action = hotkeyActions[id] else { return }
        run(action)
    }

    func run(_ action: HotAction) {
        let pdfOn = pdfShownKey != nil && !pdfView.isHidden
        switch action {
        case .next:
            if pdfOn, pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
        case .prev:
            if pdfOn, pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
        case .first:
            if pdfOn { pdfView.goToFirstPage(nil) }
        case .last:
            if pdfOn { pdfView.goToLastPage(nil) }
        case .black:
            blackView.isHidden = !blackView.isHidden
            writeLog(blackView.isHidden ? "取消黑屏" : "黑屏")
        case .extend:
            extendCurrent()
            return
        case .caption:
            setCaptionOverride(!captionVisible)
            return
        case .pdfNow:
            if let s = pdfNowShow() { setManual(s) }
            return
        case .welcomeNow:
            setManual("welcome")
            return
        case .clockNow:
            setManual("clock")
            return
        case .countdownNow:
            setManual("countdown")
            return
        case .auto:
            let had = manual != nil || holdUntil != nil
            manual = nil
            holdUntil = nil
            holdIndex = -1
            writeLog("恢复按时间表（取消延长和手动切换）")
            if had { infoHUD.show("已恢复按时间表", on: builtInScreen(), seconds: 3) }
        case .quit:
            NSApp.terminate(nil)
            return
        }
        tick()
    }

    // MARK: 菜单栏

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.title = "⏱"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func periodicChecks() {
        requestScan()
        let noScreen = !testMode && targetScreen() == nil
        if noScreen != noScreenWarn {
            noScreenWarn = noScreen
            if noScreen {
                writeLog("⚠️ 没检测到外接投影屏（请用“扩展”模式，不要镜像）")
            } else if let s = targetScreen() {
                writeLog("投影屏：\(screenLabel(s))")
            }
        }
    }

    /// 现在及以后要用到的 PDF 有没有缺
    func upcomingPDFMissing() -> Bool {
        guard scan.checked else { return false }
        let from = max(sceneIndex, 0)
        for i in timeline.indices where i >= from && isPDFShow(timeline[i].show) {
            if pdfURL(for: timeline[i].show) == nil { return true }
        }
        return false
    }

    var hasWarning: Bool {
        if hotkeyProblems > 0 || !problems.isEmpty || noScreenWarn { return true }
        if scan.checked && !scan.readable { return true }
        return upcomingPDFMissing()
    }

    func updateStatusTitle(_ now: Date) {
        var t: String
        switch currentScene {
        case .waiting:
            if let next = timeline.first(where: { $0.at > now }) {
                t = "⏱" + shortTime(next.at)
            } else {
                t = "⏱"
            }
        case .welcome:
            t = "👋欢迎页"
        case .clock:
            t = "🕐时钟"
        case .countdown(let target):
            let left = max(0, Int(ceil(target.timeIntervalSince(now))))
            t = "⏳\(left / 60):" + pad2(left % 60)
        case .pdf:
            if pdfShownKey != nil, let doc = pdfView.document, let page = pdfView.currentPage {
                t = "📄\(doc.index(for: page) + 1)/\(doc.pageCount)"
            } else {
                t = "📄缺PDF"
            }
        case .quit:
            t = "⏱结束"
        }
        if let u = holdUntil { t += "→" + shortTime(u) }
        if captionVisible { t += "💬" }
        if !blackView.isHidden { t = "⬛" + t }
        if hasWarning { t = "⚠️" + t }
        if t != lastTitle {
            statusItem.button?.title = t
            lastTitle = t
        }
    }

    func folderStatus() -> String {
        if scan.permissionDenied {
            return "⚠️ 没有权限读取“下载”文件夹：系统设置 › 隐私与安全性 › 文件和文件夹 › Presenter，打开“下载文件夹”，然后重新打开 Presenter"
        }
        return "⚠️ PDF 文件夹无法读取：\(scan.error)"
    }

    func pdfStatus(_ key: String) -> String {
        if let u = scan.matches[key] {
            var s = "✅ \(u.lastPathComponent)"
            if let n = scan.counts[key], n > 1 { s += "（有 \(n) 个符合，用最新的）" }
            return s
        }
        if testMode, pdfURL(for: key) != nil { return "（测试）用 pdf/sample.pdf 代替" }
        if !scan.checked { return "检查中…" }
        if !scan.readable { return "⚠️ 无法读取文件夹" }
        return "⚠️ 找不到（规则 \(rulePatterns[key] ?? cfg.pdfPatterns[key] ?? "?")）"
    }

    func captionDuringText() -> String {
        var t = cfg.caption.showDuring.map { showLabel($0) }.joined(separator: "、")
        if let f = captionFrom, let e = captionTo {
            t += "（\(f.h):\(pad2(f.m))–\(e.h):\(pad2(e.m))）"
        } else if let f = captionFrom {
            t += "（\(f.h):\(pad2(f.m)) 起）"
        } else if let e = captionTo {
            t += "（到 \(e.h):\(pad2(e.m))）"
        }
        return t
    }

    func captionDayText() -> String {
        if let f = captionForced {
            return f ? "今天：启动参数要求显示（--caption），\(captionDuringText()) 时显示" : "今天：启动参数要求不显示（--nocaption）"
        }
        switch cfg.caption.when {
        case "always": return "设置为每天：\(captionDuringText()) 时自动显示"
        case "never": return "设置为不自动显示（可手动打开）"
        case "sunday":
            return captionToday ? "今天是星期天：\(captionDuringText()) 时自动显示" : "今天不是星期天：不自动显示（可手动打开）"
        default:
            return captionToday ? "今天是本月第一个星期天：\(captionDuringText()) 时自动显示"
                                : "今天不是本月第一个星期天：不自动显示（可手动打开）"
        }
    }

    func captionTextStatus() -> String {
        if let at = captionTextAt { return "文字：✅ 最近更新 \(hms(at))" }
        if sourceRequested { return "文字：等待中（开始翻译后出现）" }
        return "文字：—"
    }

    /// 启动提示框和“再次打开”提示框里的状态
    func statusLines() -> [String] {
        var lines: [String] = []
        lines.append("时间表：" + timelineSummary(" · "))
        lines.append("当前：\(currentScene.label)" + (manual == nil ? "" : "（手动）"))
        if scan.checked && !scan.readable { lines.append(folderStatus()) }
        for key in pdfKeys() { lines.append("\(key)：\(pdfStatus(key))") }
        if !scan.unused.isEmpty {
            lines.append("注意：这些 PDF 含今天日期但不符合规则，不会使用：" + scan.unused.prefix(3).joined(separator: "、"))
        }
        if let sc = targetScreen() {
            lines.append("投影屏：✅ \(screenLabel(sc))")
        } else if testMode {
            lines.append("投影屏：未检测到（测试模式在本屏中间小窗预览）")
        } else {
            lines.append("投影屏：⚠️ 未检测到，接上投影（扩展模式）后才会显示")
        }
        if captionToday {
            lines.append("实时翻译：✅ 今天在 \(captionDuringText()) 时显示在投影下方")
        } else if let t = hotkeyLabels[.caption] {
            lines.append("实时翻译：今天不自动显示（需要时按 \(t)）")
        }
        if hotkeyProblems > 0 { lines.append("快捷键：⚠️ 有冲突，详见菜单栏图标") }
        for p in problems { lines.append("⚠️ \(p)") }
        var control = "控制：点菜单栏图标"
        if let e = hotkeyLabels[.extend] { control += "　·　延长当前画面：\(e)" }
        if let q = hotkeyLabels[.quit] { control += "　·　退出：\(q)" }
        lines.append(control)
        return lines
    }

    func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func addAction(_ menu: NSMenu, _ action: HotAction?, _ title: String, _ selector: Selector,
                   on: Bool = false, object: Any? = nil) {
        var text = title
        if let a = action, let label = hotkeyLabels[a] { text += "      " + label }
        let item = NSMenuItem(title: text, action: selector, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.representedObject = object
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addInfo(menu, "时间表" + (testMode ? "（测试）" : "") + "：")
        for (i, e) in timeline.enumerated() {
            let mark = i == sceneIndex ? "▶ " : "　 "
            var line = "\(mark)\(shortTime(e.at))  \(showLabel(e.show))"
            if let u = holdUntil, holdIndex == i { line += "（已延长到 \(shortTime(u))）" }
            addInfo(menu, line)
        }
        addInfo(menu, "当前：\(currentScene.label)" + (manual == nil ? "（自动）" : "（手动）"))
        menu.addItem(NSMenuItem.separator())

        addInfo(menu, "PDF 文件夹：\(pdfFolderURL.path)")
        if scan.checked && !scan.readable { addInfo(menu, folderStatus()) }
        for key in pdfKeys() { addInfo(menu, "\(key)：\(pdfStatus(key))") }
        if !scan.unused.isEmpty {
            addInfo(menu, "注意：含今天日期但不符合规则（不会使用）：")
            for name in scan.unused.prefix(6) { addInfo(menu, "　　\(name)") }
        }
        if let sc = targetScreen() {
            addInfo(menu, "投影屏：✅ \(screenLabel(sc))")
        } else {
            addInfo(menu, testMode ? "投影屏：未检测到（测试模式用小窗预览）" : "投影屏：⚠️ 未检测到（需要“扩展”模式，不要镜像）")
        }
        for p in problems { addInfo(menu, "⚠️ \(p)") }
        menu.addItem(NSMenuItem.separator())

        addAction(menu, .extend, "延长当前画面 +\(durationText(extendStep))", #selector(menuExtend))
        // 手动切换（到时间表的下一个时间点自动恢复）
        var seen: [String] = []
        for e in timeline where e.show != "quit" && !seen.contains(e.show) {
            seen.append(e.show)
            var title = "显示 \(showLabel(e.show))"
            var action: HotAction?
            var on = false
            switch e.show {
            case "welcome":
                action = .welcomeNow
                on = manual == .welcome
            case "clock":
                action = .clockNow
                on = manual == .clock
            case "countdown":
                title = "开始倒计时（\(Int(countdownLength(at: -1))) 秒）"
                action = .countdownNow
                if case .countdown? = manual { on = true }
            default:
                on = manual == .pdf(e.show)
            }
            addAction(menu, action, title, #selector(menuShow(_:)), on: on, object: e.show)
        }
        addAction(menu, .pdfNow, "立即显示 PDF（当前或下一个）", #selector(menuPDFNow))
        addAction(menu, .auto, "恢复按时间表（取消延长和手动切换）", #selector(menuAuto),
                  on: manual == nil && holdUntil == nil)
        addAction(menu, .black, "黑屏", #selector(menuBlack), on: !blackView.isHidden)
        addInfo(menu, "（手动切换到下一个时间点自动恢复按时间表）")
        menu.addItem(NSMenuItem.separator())

        // 实时翻译
        let capItem = NSMenuItem(title: "实时翻译" + (captionVisible ? "（显示中）" : ""), action: nil, keyEquivalent: "")
        let cm = NSMenu()
        addInfo(cm, captionDayText())
        addInfo(cm, "网页：" + (sourceRequested ? sourceState : "未载入（需要时自动载入）"))
        addInfo(cm, captionTextStatus())
        if let p = captionPath { addInfo(cm, "文字区域：\(p)") }
        cm.addItem(NSMenuItem.separator())
        addAction(cm, .caption, "显示/隐藏（切换）", #selector(menuCaptionToggle))
        addAction(cm, nil, "自动（按日期和时间表）", #selector(menuCaptionAuto), on: captionOverride == nil)
        addAction(cm, nil, "显示", #selector(menuCaptionOn), on: captionOverride == true)
        addAction(cm, nil, "隐藏", #selector(menuCaptionOff), on: captionOverride == false)
        addInfo(cm, "（手动显示/隐藏到下一个自动开关时间为止）")
        cm.addItem(NSMenuItem.separator())
        addAction(cm, nil, "显示方式：提取文字（大字）", #selector(menuCaptionText), on: captionMode == "text")
        addAction(cm, nil, "显示方式：原网页", #selector(menuCaptionPage), on: captionMode == "page")
        cm.addItem(NSMenuItem.separator())
        addAction(cm, nil, "重新载入翻译网页", #selector(menuCaptionReload))
        addAction(cm, nil, "打开可点击的翻译网页窗口（首次设置用）", #selector(menuCaptionSetup))
        addAction(cm, nil, "保存网页结构和截图（发给开发者调整用）", #selector(menuCaptionDump))
        capItem.submenu = cm
        menu.addItem(capItem)
        menu.addItem(NSMenuItem.separator())

        addAction(menu, nil, "重新检查 PDF / 重新载入当前 PDF", #selector(menuReload))
        addAction(menu, nil, "打开 PDF 文件夹", #selector(menuOpenPDFFolder))
        addAction(menu, nil, "打开 Presenter 文件夹", #selector(menuOpenBase))
        addAction(menu, nil, "查看日志", #selector(menuOpenLog))
        menu.addItem(NSMenuItem.separator())

        let hk = NSMenuItem(title: hotkeyProblems > 0 ? "快捷键 ⚠️" : "快捷键", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for line in hotkeyReport { sub.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: "")) }
        sub.addItem(NSMenuItem.separator())
        sub.addItem(NSMenuItem(title: obsSummary, action: nil, keyEquivalent: ""))
        sub.addItem(NSMenuItem(title: "修改：编辑 config.json 后重新打开 Presenter", action: nil, keyEquivalent: ""))
        hk.submenu = sub
        menu.addItem(hk)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出 Presenter", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func menuShow(_ sender: NSMenuItem) {
        guard let show = sender.representedObject as? String else { return }
        setManual(show)
    }
    @objc func menuExtend() { run(.extend) }
    @objc func menuPDFNow() { run(.pdfNow) }
    @objc func menuAuto() { run(.auto) }
    @objc func menuBlack() { run(.black) }
    @objc func menuCaptionToggle() { run(.caption) }
    @objc func menuCaptionAuto() { setCaptionOverride(nil) }
    @objc func menuCaptionOn() { setCaptionOverride(true) }
    @objc func menuCaptionOff() { setCaptionOverride(false) }
    @objc func menuCaptionText() { setCaptionMode("text") }
    @objc func menuCaptionPage() { setCaptionMode("page") }
    @objc func menuCaptionReload() { loadSource("手动重新载入") }
    @objc func menuCaptionSetup() { openCaptionSetupWindow() }
    @objc func menuCaptionDump() { dumpCaptionPage() }
    @objc func menuReload() {
        rescanNow()
        guard let k = pdfShownKey else { tick(); return }
        var index = 0
        if let d = pdfView.document, let p = pdfView.currentPage { index = d.index(for: p) }
        docCache[k] = nil
        badFiles.removeAll()
        guard let doc = loadDoc(k) else { return }
        pdfView.document = doc
        if let p = doc.page(at: min(index, doc.pageCount - 1)) { pdfView.go(to: p) }
        pdfView.autoScales = true
        hidePDFScrollers()
    }
    @objc func menuOpenPDFFolder() { _ = NSWorkspace.shared.open(pdfFolderURL) }
    @objc func menuOpenBase() { _ = NSWorkspace.shared.open(baseDir) }
    @objc func menuOpenLog() {
        if let u = logFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
    @objc func menuQuit() { NSApp.terminate(nil) }

    // MARK: 状态提示框

    func showLaunchHUD() {
        if launchHUDShown { return }
        launchHUDShown = true
        var title = "Presenter 已启动" + (testMode ? "（测试模式）" : "")
        var note: String?
        if lateLaunch {
            title = "今天的时间表已结束，Presenter 将在几秒后退出"
            note = "彩排请用：open Presenter.app --args --test（或 --at 10:28:00）"
        } else if let at = atArg {
            note = "模拟时间：从 \(pad2(at.h)):\(pad2(at.m)):\(pad2(at.s)) 开始"
        }
        showHUD(title: title, note: note, seconds: lateLaunch ? 9 : 7)
    }

    func showHUD(title: String, note: String?, seconds: TimeInterval) {
        var lines: [String] = [title]
        if let n = note { lines.append(n) }
        lines.append(contentsOf: statusLines())
        infoHUD.show(lines.joined(separator: "\n"), on: builtInScreen(), seconds: seconds)
    }

    func logSummary() {
        writeLog("显示器：" + NSScreen.screens.map { screenLabel($0) }.joined(separator: "，"))
        if let s = targetScreen() {
            writeLog("投影屏：\(screenLabel(s))")
        }
        writeLog("PDF 文件夹：\(pdfFolderURL.path)")
        for key in pdfKeys() { writeLog("\(key) 规则：\(rulePatterns[key] ?? "（无效）")") }
        writeLog("延长：每次 +\(durationText(extendStep))；PDF 结束前 \(durationText(warnLead)) 提醒")
        writeLog("实时翻译：\(captionDayText())；网址 \(cfg.caption.url)；显示方式 \(captionMode)")
        for line in hotkeyReport { writeLog("快捷键 " + line) }
        writeLog(obsSummary)
        for p in problems { writeLog("⚠️ " + p) }
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
