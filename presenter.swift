// Presenter — 外接投影屏按时间表自动切换：欢迎页 / PDF / 时钟 / 倒计时，并提供全局翻页快捷键
//
// 编译：bash build.sh（需要 Xcode 命令行工具）
// 运行：双击 Presenter.app
// 彩排：killall Presenter; open Presenter.app --args --test
//
// 设计要点
// - 时间表、PDF 文件名规则、快捷键都在 config.json 里，默认：
//   09:10 欢迎页 → 09:12 pdf1 → 10:18 欢迎页 → 10:21 时钟 → 10:28:30 倒计时 → 10:30 pdf2 → 12:15 退出
// - PDF 从 ~/Downloads 读取：pdf1 = 符合 ^[ A-Z][a-z]+-yyyymmdd\.pdf$ 的文件，pdf2 = yyyymmdd.pdf
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

struct PresenterConfig {
    var events: [EventSpec] = defaultEventSpecs
    var pdfFolder = "~/Downloads"
    var dateFormat = "yyyyMMdd"
    var pdfPatterns: [String: String] = defaultPDFPatterns
    var screenName = ""
    var hotkeys: [String: [String]] = defaultHotkeys
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
    case next, prev, first, last, black, pdfNow, welcomeNow, clockNow, countdownNow, auto, quit

    var title: String {
        switch self {
        case .next: return "下一页"
        case .prev: return "上一页"
        case .first: return "第一页"
        case .last: return "最后一页"
        case .black: return "黑屏开/关"
        case .pdfNow: return "立即显示 PDF（当前或下一个）"
        case .welcomeNow: return "立即显示欢迎页"
        case .clockNow: return "立即显示时钟"
        case .countdownNow: return "立即开始倒计时"
        case .auto: return "恢复按时间表自动"
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

// MARK: - 主程序

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate {

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

    // 界面
    var panel: StagePanel!
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

    // 快捷键
    let hotKeys = HotKeyCenter()
    var hotkeyActions: [UInt32: HotAction] = [:]
    var hotkeyLabels: [HotAction: String] = [:]
    var hotkeyReport: [String] = []
    var hotkeyProblems = 0
    var obsSummary = ""

    // 状态提示框
    var hud: NSPanel?
    var hudTimer: Timer?
    var launchHUDShown = false

    var pdfFolderURL: URL {
        return expandPath(cfg.pdfFolder, base: baseDir)
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
        if let at = atArg {
            let target = dateOn(Calendar.current.startOfDay(for: Date()), at)
            timeOffset = target.timeIntervalSince(Date())
            writeLog("模拟时间：从 \(hms(target)) 开始（--at）")
        }

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

        let container = NSView(frame: initial)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.autoresizesSubviews = true
        panel.contentView = container

        // 底层：舞台页（欢迎页/时钟/倒计时），一直在，PDF 盖在它上面
        let wc = WKWebViewConfiguration()
        webView = WKWebView(frame: container.bounds, configuration: wc)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        container.addSubview(webView)

        // 中层：PDF
        pdfView = PDFView(frame: container.bounds)
        pdfView.autoresizingMask = [.width, .height]
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = .black
        pdfView.autoScales = true
        pdfView.isHidden = true
        container.addSubview(pdfView)

        // 顶层：黑屏
        blackView = NSView(frame: container.bounds)
        blackView.autoresizingMask = [.width, .height]
        blackView.wantsLayer = true
        blackView.layer?.backgroundColor = NSColor.black.cgColor
        blackView.isHidden = true
        container.addSubview(blackView)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        pushStageMode()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        writeLog("⚠️ 舞台页加载失败：\(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        writeLog("⚠️ 舞台页进程意外退出，重新加载")
        loadStage()
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
        if pdfShownKey != nil { pdfView.autoScales = true }
        periodicChecks()
    }

    @objc func didWake(_ note: Notification) {
        writeLog("系统唤醒")
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
    /// 都没有 → 当前项（只管到下一个时间点）。手动切换在这一项结束时自动失效，恢复按时间表。
    func manualIndexFor(_ show: String, now: Date) -> Int {
        let cur = autoIndex(now)
        if cur >= 0, cur < timeline.count, timeline[cur].show == show { return cur }
        if let j = timeline.indices.first(where: { $0 > cur && timeline[$0].show == show }) { return j }
        return max(cur, 0)
    }

    func setManual(_ show: String) {
        let now = appNow()
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
        let cur = autoIndex(appNow())
        if cur >= 0, cur < timeline.count, isPDFShow(timeline[cur].show) { return timeline[cur].show }
        if let j = timeline.indices.first(where: { $0 > cur && isPDFShow(timeline[$0].show) }) { return timeline[j].show }
        return timeline.last(where: { isPDFShow($0.show) })?.show
    }

    @objc func tick() {
        let now = appNow()
        tickCount &+= 1
        if tickCount % 40 == 0 { periodicChecks() }  // 约每 2 秒

        let idx = autoIndex(now)
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

        // PDF 时间到了但文件缺失/打不开：每 2 秒重试
        if case .pdf(let key) = currentScene, pdfShownKey == nil, tickCount % 40 == 0 {
            if showPDF(key) { writeLog("\(key)：文件已找到，开始显示") }
        }

        if tickCount % 20 == 0 { preloadUpcoming(now) }
        updateStatusTitle(now)
    }

    func apply(_ s: Scene, index: Int) {
        let old = currentScene
        currentScene = s
        sceneIndex = index
        writeLog("切换：\(old.label) → \(s.label)" + (manual == nil ? "" : "（手动）"))
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
            if !showPDF(key) {
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

    /// 显示 PDF 第一页
    func showPDF(_ key: String) -> Bool {
        guard let doc = loadDoc(key) else { return false }
        if pdfView.document !== doc { pdfView.document = doc }
        if let first = doc.page(at: 0) { pdfView.go(to: first) }
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
        pdfView.document = nil
        docCache[k] = nil
        pdfShownKey = nil
        writeLog("关闭 \(k)")
    }

    /// 下一项是 PDF 且 2 分钟内开始：提前载入，切换时立刻显示
    func preloadUpcoming(_ now: Date) {
        let idx = manual != nil ? manualIndex : autoIndex(now)
        let j = idx + 1
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
            manual = nil
            writeLog("恢复按时间表自动")
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
        if hotkeyProblems > 0 { lines.append("快捷键：⚠️ 有冲突，详见菜单栏图标") }
        for p in problems { lines.append("⚠️ \(p)") }
        var control = "控制：点菜单栏图标"
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
            addInfo(menu, "\(mark)\(shortTime(e.at))  \(showLabel(e.show))")
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
        addAction(menu, .auto, "按时间表自动", #selector(menuAuto), on: manual == nil)
        addAction(menu, .black, "黑屏", #selector(menuBlack), on: !blackView.isHidden)
        addInfo(menu, "（手动切换到下一个时间点自动恢复按时间表）")
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
    @objc func menuPDFNow() { run(.pdfNow) }
    @objc func menuAuto() { run(.auto) }
    @objc func menuBlack() { run(.black) }
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

    // MARK: 状态提示框（在内建屏上方显示几秒，告诉你程序在运行、状态如何）

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
        let text = lines.joined(separator: "\n")

        guard let screen = NSScreen.screens.first(where: { isBuiltIn($0) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let font = NSFont.systemFont(ofSize: 15)
        let maxWidth = max(420, min(1150, vf.width - 120))
        let textRect = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: 4000),
                                                       options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: font], context: nil)
        let pad: CGFloat = 22
        let labelSize = NSSize(width: ceil(textRect.width) + 10, height: ceil(textRect.height) + 6)
        let size = NSSize(width: labelSize.width + pad * 2, height: labelSize.height + pad * 2)
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 30,
                           width: size.width, height: size.height)

        let hp: NSPanel
        if let existing = hud {
            hp = existing
        } else {
            hp = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hp.isReleasedWhenClosed = false
            hp.hidesOnDeactivate = false
            hp.level = .statusBar
            hp.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            hp.ignoresMouseEvents = true
            hp.isOpaque = false
            hp.backgroundColor = .clear
            hp.hasShadow = true
            hud = hp
        }
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.9).cgColor
        bg.layer?.cornerRadius = 14
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = .white
        label.frame = NSRect(x: pad, y: pad, width: labelSize.width, height: labelSize.height)
        bg.addSubview(label)
        hp.contentView = bg
        hp.setFrame(frame, display: true)
        hp.orderFrontRegardless()

        hudTimer?.invalidate()
        let t = Timer(timeInterval: seconds, target: self, selector: #selector(hideHUD), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        hudTimer = t
    }

    @objc func hideHUD() {
        hud?.orderOut(nil)
    }

    func logSummary() {
        writeLog("显示器：" + NSScreen.screens.map { screenLabel($0) }.joined(separator: "，"))
        if let s = targetScreen() {
            writeLog("投影屏：\(screenLabel(s))")
        }
        writeLog("PDF 文件夹：\(pdfFolderURL.path)")
        for key in pdfKeys() { writeLog("\(key) 规则：\(rulePatterns[key] ?? "（无效）")") }
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
