// Presenter — 外接投影屏定时显示：时钟 → 倒计时 → 当天 PDF，并提供全局翻页快捷键
//
// 编译：bash build.sh（需要 Xcode 命令行工具）
// 运行：双击 Presenter.app；测试：open Presenter.app --args --test
//
// 设计要点
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

// MARK: - 设置

let defaultHotkeys: [String: [String]] = [
    "next": ["ctrl+alt+right", "ctrl+alt+down"],
    "prev": ["ctrl+alt+left", "ctrl+alt+up"],
    "first": ["ctrl+alt+1"],
    "black": ["ctrl+alt+b"],
    "pdfNow": ["ctrl+alt+p"],
    "quit": ["ctrl+alt+escape"],
]

struct PresenterConfig {
    var clockAt = "10:25:00"
    var countdownAt = "10:28:30"
    var pdfAt = "10:30:00"
    var pdfFolder = "pdf"
    var pdfNameFormat = "yyyyMMdd"
    var screenName = ""
    var lateStartMinutes = 240
    var hotkeys: [String: [String]] = defaultHotkeys
}

struct DaySchedule {
    var clock: Date
    var countdown: Date
    var pdf: Date
    var day: Date
}

enum StagePhase: Equatable {
    case waiting
    case clock
    case countdown(Date)
    case pdf
    case done

    var isVisible: Bool {
        switch self {
        case .clock, .countdown, .pdf: return true
        case .waiting, .done: return false
        }
    }

    var name: String {
        switch self {
        case .waiting: return "等待"
        case .clock: return "时钟"
        case .countdown: return "倒计时"
        case .pdf: return "PDF"
        case .done: return "今天已结束"
        }
    }
}

// MARK: - 快捷键解析

enum HotAction: String, CaseIterable {
    case next, prev, first, last, black, pdfNow, countdownNow, clockNow, auto, quit

    var title: String {
        switch self {
        case .next: return "下一页"
        case .prev: return "上一页"
        case .first: return "第一页"
        case .last: return "最后一页"
        case .black: return "黑屏开/关"
        case .pdfNow: return "立即显示 PDF"
        case .countdownNow: return "立即开始倒计时"
        case .clockNow: return "立即显示时钟"
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
html,body{margin:0;height:100%;background:#000;color:#fff;overflow:hidden;cursor:none;font-family:-apple-system,"PingFang SC",sans-serif}
#t{position:absolute;top:50%;left:0;right:0;transform:translateY(-50%);text-align:center;font-size:28vh;font-variant-numeric:tabular-nums}
</style></head><body><div id="t"></div><script>
var mode='clock',target=0;function p(n){return (n<10?'0':'')+n}
function r(){var n=new Date(),s;if(mode==='countdown'){var l=Math.max(0,Math.ceil((target-n.getTime())/1000));s=Math.floor(l/60)+':'+p(l%60)}else{s=p(n.getHours())+':'+p(n.getMinutes())+':'+p(n.getSeconds())}document.getElementById('t').textContent=s}
window.setMode=function(m,t){mode=m;target=Number(t)||0;r()};setInterval(r,50);r();
</script></body></html>
"""

// MARK: - 主程序

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate {

    // 启动参数
    var baseDir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var testMode = false
    var testLead: TimeInterval = 8
    var testCountdown: TimeInterval?
    var pdfArg: String?
    var dirArg: String?
    var dateOverride: Date?

    // 设置
    var cfg = PresenterConfig()
    var problems: [String] = []
    var clockHMS: HMSTime = (h: 10, m: 25, s: 0)
    var countdownHMS: HMSTime = (h: 10, m: 28, s: 30)
    var pdfHMS: HMSTime = (h: 10, m: 30, s: 0)

    // 状态
    var schedule = DaySchedule(clock: Date(), countdown: Date(), pdf: Date(), day: Date())
    var phase: StagePhase = .waiting
    var manual: StagePhase?
    var applied = false
    var tickCount = 0
    var timer: Timer?
    var activity: NSObjectProtocol?

    // 界面
    var panel: StagePanel!
    var webView: WKWebView!
    var pdfView: PDFView!
    var blackView: NSView!
    var statusItem: NSStatusItem!
    var lastTitle = ""

    // 舞台页（时钟/倒计时）
    var pageLoaded = false
    var stageMode = "clock"
    var stageTarget: Date?

    // PDF
    var pdfLoadedURL: URL?
    var pdfLoadedMod: Date?
    var pdfShown = false
    var pdfExists = false
    var noScreenWarn = false

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

    var countdownLength: TimeInterval {
        return TimeInterval(seconds(pdfHMS) - seconds(countdownHMS))
    }

    var activeCountdownLength: TimeInterval {
        if testMode, let t = testCountdown { return t }
        return countdownLength
    }

    var pdfFolderURL: URL {
        return expandPath(cfg.pdfFolder, base: baseDir)
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
        if pdfArg == nil {
            try? FileManager.default.createDirectory(at: pdfFolderURL, withIntermediateDirectories: true, attributes: nil)
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

        buildSchedule(Date())
        periodicChecks()
        logSummary()

        let t = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
        showHUD(reopened: false)
    }

    // 程序已在运行时又被双击 / open：显示状态提示（新的启动参数不会生效）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        writeLog("再次打开：程序已在运行，新的启动参数不会生效")
        showHUD(reopened: true)
        return false
    }

    // MARK: 状态提示框（在内建屏上方显示几秒，告诉你程序在运行、状态如何）

    func showHUD(reopened: Bool) {
        var title = reopened ? "Presenter 已经在运行" : "Presenter 已启动"
        if testMode { title += "（测试模式）" }
        var lines: [String] = [title]
        if reopened { lines.append("要换成测试模式等其他参数，请先退出再打开") }
        lines.append("时间表：\(hms(schedule.clock)) 时钟 → \(hms(schedule.countdown)) 倒计时 → \(hms(schedule.pdf)) PDF")
        lines.append("当前：\(phase.name)")
        if let u = existingPDF() {
            lines.append("PDF：✅ \(u.lastPathComponent)")
        } else {
            lines.append("PDF：⚠️ 找不到 \(pdfBaseName()).pdf")
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
        var control = "控制：点菜单栏的 ⏱ 图标"
        if let q = hotkeyLabels[.quit] { control += "　·　退出：\(q)" }
        lines.append(control)
        let text = lines.joined(separator: "\n")

        guard let screen = NSScreen.screens.first(where: { isBuiltIn($0) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let font = NSFont.systemFont(ofSize: 15)
        let textRect = (text as NSString).boundingRect(with: NSSize(width: 3000, height: 3000),
                                                       options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: font], context: nil)
        let pad: CGFloat = 22
        let labelSize = NSSize(width: ceil(textRect.width) + 10, height: ceil(textRect.height) + 6)
        let size = NSSize(width: labelSize.width + pad * 2, height: labelSize.height + pad * 2)
        let vf = screen.visibleFrame
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
        let t = Timer(timeInterval: reopened ? 8 : 6, target: self, selector: #selector(hideHUD), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        hudTimer = t
    }

    @objc func hideHUD() {
        hud?.orderOut(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregisterAll()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        writeLog("===== Presenter 退出 =====")
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
            case "--lead":
                if let v = value(), let d = Double(v), d >= 0 { testLead = d }
            case "--pdf":
                pdfArg = value()
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
            applyTimes()
            return
        }
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            problems.append("config.json 格式有误，已使用默认设置")
            writeLog("⚠️ config.json 无法解析（检查逗号、引号），使用默认设置")
            applyTimes()
            return
        }
        if let v = obj["clockAt"] as? String { cfg.clockAt = v }
        if let v = obj["countdownAt"] as? String { cfg.countdownAt = v }
        if let v = obj["pdfAt"] as? String { cfg.pdfAt = v }
        if let v = obj["pdfFolder"] as? String, !v.isEmpty { cfg.pdfFolder = v }
        if let v = obj["pdfNameFormat"] as? String, !v.isEmpty { cfg.pdfNameFormat = v }
        if let v = obj["screenName"] as? String { cfg.screenName = v }
        if let v = obj["lateStartMinutes"] as? Int { cfg.lateStartMinutes = v }
        if let hk = obj["hotkeys"] as? [String: Any] {
            for (k, v) in hk where !k.hasPrefix("_") {
                if let arr = v as? [String] {
                    cfg.hotkeys[k] = arr
                } else if let s = v as? String {
                    cfg.hotkeys[k] = s.isEmpty ? [] : [s]
                }
            }
        }
        applyTimes()
    }

    func applyTimes() {
        guard let c = parseHMS(cfg.clockAt), let d = parseHMS(cfg.countdownAt), let p = parseHMS(cfg.pdfAt) else {
            problems.append("时间格式不对（应为 HH:MM:SS），已用默认 10:25:00 / 10:28:30 / 10:30:00")
            return
        }
        guard seconds(c) <= seconds(d), seconds(d) < seconds(p) else {
            problems.append("时间顺序不对（需 时钟 ≤ 倒计时 < PDF），已用默认时间")
            return
        }
        clockHMS = c
        countdownHMS = d
        pdfHMS = p
    }

    func buildSchedule(_ now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        if testMode {
            let start = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970) + 1)
            let cd = start.addingTimeInterval(testLead)
            schedule = DaySchedule(clock: start, countdown: cd, pdf: cd.addingTimeInterval(activeCountdownLength), day: day)
        } else {
            schedule = DaySchedule(clock: dateOn(day, clockHMS), countdown: dateOn(day, countdownHMS),
                                   pdf: dateOn(day, pdfHMS), day: day)
        }
        writeLog("时间表：\(hms(schedule.clock)) 时钟 → \(hms(schedule.countdown)) 倒计时（\(Int(schedule.pdf.timeIntervalSince(schedule.countdown))) 秒）→ \(hms(schedule.pdf)) PDF")
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
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.title = "Presenter"

        let container = NSView(frame: initial)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        panel.contentView = container

        // 底层：舞台页（时钟/倒计时），一直在，PDF 盖在它上面
        let wc = WKWebViewConfiguration()
        webView = WKWebView(frame: container.bounds, configuration: wc)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .black }
        // 让网页在首次绘制前保持透明（露出黑底），避免白闪
        if webView.responds(to: NSSelectorFromString("setDrawsBackground:"))
            || webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
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
        var js = "window.setMode && window.setMode('clock', 0)"
        if stageMode == "countdown", let t = stageTarget {
            js = "window.setMode && window.setMode('countdown', \(Int64(t.timeIntervalSince1970 * 1000)))"
        }
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
        if phase.isVisible { placePanel() } else { panel.orderOut(nil) }
        if pdfShown { pdfView.autoScales = true }
        periodicChecks()
    }

    @objc func didWake(_ note: Notification) {
        writeLog("系统唤醒")
        tick()
    }

    // MARK: 时间表

    func autoPhase(_ now: Date) -> StagePhase {
        let s = schedule
        if now < s.clock { return .waiting }
        if now < s.countdown { return .clock }
        if now < s.pdf { return .countdown(s.pdf) }
        if testMode || now < s.pdf.addingTimeInterval(TimeInterval(cfg.lateStartMinutes) * 60) { return .pdf }
        return .done
    }

    @objc func tick() {
        let now = Date()
        tickCount &+= 1
        if tickCount % 40 == 0 { periodicChecks() }  // 约每 2 秒

        // 过了午夜（例如前一晚就打开了程序），换成当天的时间表
        if !testMode, manual == nil, !phase.isVisible, Calendar.current.startOfDay(for: now) != schedule.day {
            buildSchedule(now)
        }

        // 手动倒计时结束 → PDF
        if case .countdown(let t)? = manual, now >= t { manual = .pdf }

        var desired = manual ?? autoPhase(now)
        // 已经开始显示后，不会因为“超过很久”而自动消失
        if manual == nil, desired == .done, phase.isVisible { desired = .pdf }

        if !applied || desired != phase {
            apply(desired)
            applied = true
        }

        // PDF 时间到了但文件缺失/打不开：每 2 秒重试
        if phase == .pdf, !pdfShown, tickCount % 40 == 0, refreshPDF() {
            showPDF()
        }

        updateStatusTitle(now)
    }

    func apply(_ p: StagePhase) {
        let old = phase
        phase = p
        writeLog("切换：\(old.name) → \(p.name)" + (manual == nil ? "" : "（手动）"))
        switch p {
        case .waiting, .done:
            pdfShown = false
            pdfView.isHidden = true
            panel.orderOut(nil)
            if p == .done {
                writeLog("今天的时间已过 \(cfg.lateStartMinutes) 分钟以上，不自动显示；需要时用菜单栏手动显示")
            }
        case .clock:
            showStage(mode: "clock", target: nil)
        case .countdown(let t):
            _ = refreshPDF()  // 提前载入，顺便检查文件
            showStage(mode: "countdown", target: t)
        case .pdf:
            if refreshPDF() {
                showPDF()
            } else {
                writeLog("⚠️ 找不到或打不开今天的 PDF（\(pdfBaseName()).pdf），先显示倒计时结束语，每 2 秒重试")
                // 倒计时的结束时刻设为“现在”，舞台页就会显示结束语（如“敬拜马上开始!”）
                showStage(mode: "countdown", target: Date())
            }
        }
    }

    func showStage(mode: String, target: Date?) {
        stageMode = mode
        stageTarget = target
        pushStageMode()
        pdfView.isHidden = true
        pdfShown = false
        placePanel()
    }

    func showPDF() {
        pdfView.isHidden = false
        pdfShown = true
        placePanel()
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        hidePDFScrollers()
    }

    // MARK: PDF

    func pdfBaseName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = cfg.pdfNameFormat
        return f.string(from: dateOverride ?? schedule.day)
    }

    func existingPDF() -> URL? {
        let fm = FileManager.default
        if let a = pdfArg {
            let u = expandPath(a, base: baseDir)
            return fm.fileExists(atPath: u.path) ? u : nil
        }
        let name = pdfBaseName()
        for ext in ["pdf", "PDF"] {
            let u = pdfFolderURL.appendingPathComponent(name + "." + ext)
            if fm.fileExists(atPath: u.path) { return u }
        }
        if testMode {
            let u = baseDir.appendingPathComponent("pdf/sample.pdf")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 载入（或确认已载入）当天的 PDF。文件没变就不重新载入，保留当前页。
    @discardableResult
    func refreshPDF() -> Bool {
        guard let url = existingPDF() else { return false }
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if url == pdfLoadedURL, mod == pdfLoadedMod, pdfView.document != nil { return true }
        guard let doc = PDFDocument(url: url) else {
            writeLog("⚠️ 无法打开 PDF：\(url.path)")
            return false
        }
        if doc.isLocked && !doc.unlock(withPassword: "") {
            writeLog("⚠️ PDF 有密码，无法打开：\(url.path)")
            return false
        }
        guard doc.pageCount > 0, let first = doc.page(at: 0) else {
            writeLog("⚠️ PDF 没有页面：\(url.path)")
            return false
        }
        pdfView.document = doc
        pdfView.go(to: first)
        pdfView.autoScales = true
        hidePDFScrollers()
        pdfLoadedURL = url
        pdfLoadedMod = mod
        writeLog("已载入 PDF：\(url.lastPathComponent)（\(doc.pageCount) 页）")
        return true
    }

    func reloadPDFKeepingPage() {
        var index = 0
        if let d = pdfView.document, let p = pdfView.currentPage { index = d.index(for: p) }
        pdfLoadedURL = nil
        if refreshPDF(), let d = pdfView.document, let p = d.page(at: min(index, d.pageCount - 1)) {
            pdfView.go(to: p)
        }
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
        switch action {
        case .next:
            if phase == .pdf, pdfShown, pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
        case .prev:
            if phase == .pdf, pdfShown, pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
        case .first:
            if phase == .pdf, pdfShown { pdfView.goToFirstPage(nil) }
        case .last:
            if phase == .pdf, pdfShown { pdfView.goToLastPage(nil) }
        case .black:
            blackView.isHidden = !blackView.isHidden
            writeLog(blackView.isHidden ? "取消黑屏" : "黑屏")
        case .pdfNow:
            manual = .pdf
        case .countdownNow:
            manual = .countdown(Date().addingTimeInterval(activeCountdownLength))
        case .clockNow:
            manual = .clock
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
        pdfExists = existingPDF() != nil
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

    var hasWarning: Bool {
        if hotkeyProblems > 0 || !problems.isEmpty || noScreenWarn { return true }
        switch phase {
        case .waiting, .clock, .countdown: return !pdfExists
        case .pdf, .done: return false
        }
    }

    func updateStatusTitle(_ now: Date) {
        var t: String
        switch phase {
        case .waiting:
            t = "⏱" + hms(schedule.clock)
        case .clock:
            t = "🕐时钟"
        case .countdown(let target):
            let left = max(0, Int(ceil(target.timeIntervalSince(now))))
            t = "⏳\(left / 60):" + pad2(left % 60)
        case .pdf:
            if pdfShown, let doc = pdfView.document, let page = pdfView.currentPage {
                t = "📄\(doc.index(for: page) + 1)/\(doc.pageCount)"
            } else {
                t = "📄无PDF"
            }
        case .done:
            t = "⏱已结束"
        }
        if !blackView.isHidden { t = "⬛" + t }
        if hasWarning { t = "⚠️" + t }
        if t != lastTitle {
            statusItem.button?.title = t
            lastTitle = t
        }
    }

    func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func addAction(_ menu: NSMenu, _ action: HotAction?, _ title: String, _ selector: Selector, on: Bool = false) {
        var text = title
        if let a = action, let label = hotkeyLabels[a] { text += "      " + label }
        let item = NSMenuItem(title: text, action: selector, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = schedule
        addInfo(menu, "时间表：\(hms(s.clock)) 时钟 → \(hms(s.countdown)) 倒计时 → \(hms(s.pdf)) PDF" + (testMode ? "（测试）" : ""))
        let mode = manual == nil ? "（自动）" : "（手动）"
        addInfo(menu, "当前：\(phase.name)\(mode)")
        if let u = existingPDF() {
            addInfo(menu, "PDF：✅ \(u.lastPathComponent)")
        } else {
            addInfo(menu, "PDF：⚠️ 找不到 \(pdfBaseName()).pdf（在 \(pdfFolderURL.path)）")
        }
        if let sc = targetScreen() {
            addInfo(menu, "投影屏：✅ " + screenLabel(sc))
        } else {
            addInfo(menu, testMode ? "投影屏：未检测到（测试模式用小窗预览）" : "投影屏：⚠️ 未检测到（需要“扩展”模式，不要镜像）")
        }
        for p in problems { addInfo(menu, "⚠️ " + p) }
        menu.addItem(NSMenuItem.separator())

        addAction(menu, .clockNow, "立即显示时钟", #selector(menuClock), on: manual == .clock)
        addAction(menu, .countdownNow, "立即开始倒计时（\(Int(activeCountdownLength)) 秒）", #selector(menuCountdown))
        addAction(menu, .pdfNow, "立即显示 PDF", #selector(menuPDF), on: manual == .pdf)
        addAction(menu, .auto, "按时间表自动", #selector(menuAuto), on: manual == nil)
        addAction(menu, .black, "黑屏", #selector(menuBlack), on: !blackView.isHidden)
        menu.addItem(NSMenuItem.separator())

        addAction(menu, nil, "重新载入 PDF（保留当前页）", #selector(menuReload))
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

    @objc func menuClock() { run(.clockNow) }
    @objc func menuCountdown() { run(.countdownNow) }
    @objc func menuPDF() { run(.pdfNow) }
    @objc func menuAuto() { run(.auto) }
    @objc func menuBlack() { run(.black) }
    @objc func menuReload() { reloadPDFKeepingPage(); tick() }
    @objc func menuOpenPDFFolder() { _ = NSWorkspace.shared.open(pdfFolderURL) }
    @objc func menuOpenBase() { _ = NSWorkspace.shared.open(baseDir) }
    @objc func menuOpenLog() {
        if let u = logFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
    @objc func menuQuit() { NSApp.terminate(nil) }

    func logSummary() {
        writeLog("显示器：" + NSScreen.screens.map { screenLabel($0) }.joined(separator: "，"))
        if let s = targetScreen() {
            writeLog("投影屏：\(screenLabel(s))")
        }
        if let u = existingPDF() {
            writeLog("今天的 PDF：✅ \(u.path)")
        } else {
            writeLog("今天的 PDF：⚠️ 还没有 \(pdfFolderURL.appendingPathComponent(pdfBaseName() + ".pdf").path)")
        }
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
