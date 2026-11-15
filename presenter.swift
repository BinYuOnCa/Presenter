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
// - 本机识别（Apple）：术语表纠错 + 翻译前替换译名、整句翻译（⌃⌥J）、高保真翻译、字幕记录（transcripts/），
//   --review 复查字幕记录，帮助补充术语表。
// - 程序运行期间阻止系统/显示器休眠和屏保。
// - 投影屏断开时窗口自动隐藏（不会跑到内建屏盖住 OBS），重新接上后自动回来。

import Cocoa
import WebKit
import PDFKit
import Carbon
import NaturalLanguage
import Network
#if compiler(>=6.2)
import Speech
import Translation
import AVFoundation
import CoreAudio
import AudioToolbox
#endif

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
    "pdf1": "^[A-Z][a-z]+-{date}\\.pdf$",
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
    "captionSource": ["ctrl+alt+s"],
    "captionLanguage": ["ctrl+alt+l"],
    "showOriginal": ["ctrl+alt+o"],
    "showTranslation": ["ctrl+alt+y"],
    "showBoth": ["ctrl+alt+a"],
    "sentenceMode": ["ctrl+alt+j"],
    "pdfNow": ["ctrl+alt+p"],
    "quit": ["ctrl+alt+escape"],
]

/// 舞台页画面（其余名字都是 PDF）
let stageShows: Set<String> = ["welcome", "clock", "countdown", "quit"]

func isPDFShow(_ show: String) -> Bool {
    return !stageShows.contains(show)
}

/// PDF 在菜单和提示里显示的名字（config.json 的 pdfNames）
var pdfDisplayNames: [String: String] = ["pdf1": "主日学", "pdf2": "敬拜"]

func pdfName(_ key: String) -> String {
    if let n = pdfDisplayNames[key], !n.isEmpty { return n }
    return key
}

func showLabel(_ show: String) -> String {
    switch show {
    case "welcome": return "欢迎页"
    case "clock": return "时钟"
    case "countdown": return "倒计时"
    case "quit": return "退出"
    default: return pdfName(show)
    }
}

struct AppleCaptionConfig {
    var language = "zh-CN"              // 识别语言：zh-CN（普通话）或 en-US（英语）
    var translateTo = "auto"            // auto = 翻成另一种；none = 不翻译
    var inputDevice = "Maono ProStudio 2x2 Lite"
    var channel = 0                     // 0 = 混合所有输入；1、2 = 只用第几路输入
    var display = "both"                // both（原文 + 译文）| translation | original
    var clearAfterSeconds: Double = 15
    var sentenceMode = true             // 整句翻译：一句说完再翻（⌃⌥J 切换）
    var sentenceMaxSeconds: Double = 7  // 整句翻译最多等几秒
    var sentencePauseSeconds: Double = 1.2   // 停顿几秒算一句说完
    var translationQuality = "high"     // high（高保真，Apple Intelligence 可用时）| fast
    var saveTranscript = true           // 把识别和翻译存到 transcripts/transcript-yyyymmdd.txt
    var autoPunctuation = "zh"          // 按停顿补标点：zh（只对普通话）| all | off
    var pauseComma: Double = 0.3        // 停顿几秒补逗号
    var pausePeriod: Double = 0.8       // 停顿几秒补句号
}

struct GlossaryConfig {
    var enabled = true
    var files: [String] = ["glossary.csv", "glossary-bible.csv"]   // 前面的优先
    var beforeTranslation = true        // 翻译前把术语换成译名
    var fuzzy = "today"                 // 读音相同的自动纠正：today（只对今日术语）| all | off
    var fuzzyMinLength = 3              // 几个字以上的词才做读音纠正
    var pdfTerms = true                 // 今天 PDF 里出现的术语和名字算今日术语
    var termsFile = "^terms-{date}\\.(csv|txt)$"   // 今日术语文件（在 Presenter 文件夹或下载文件夹）
    var fromGoogleDrive = true          // 也从 Google Drive 文件夹下载今日术语文件
}

struct CaptionConfig {
    var source = "kaleo"                // kaleo（Kaleo 网页）| apple（本机识别 + 翻译）
    var apple = AppleCaptionConfig()
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
    var marginPercent: Double = 10      // 字幕左右各留白多少（占屏幕宽度的百分比）
}

/// OBS 字幕叠加：Presenter 在本机提供一个网页，OBS 用“浏览器”来源加到所有场景上
struct OBSCaptionConfig {
    var enabled = true
    var port = 8765
    var visibility = "same"             // same = 跟投影字幕条一起显示/隐藏；auto = 字幕时段内一直显示（投影上手动隐藏也照样显示）
    var lines = 3                       // 原文 + 译文时：原文 1 行、译文 2 行
    var heightPercent: Double = 15      // 占视频高度的百分比
    var bottomPercent: Double = 4       // 离视频底边多远
    var marginPercent: Double = 10      // 左右各留白多少
    var background = "rgba(0,0,0,0.55)"
    var color = "#ffffff"
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
    var gdrive = GDriveConfig()
    var glossary = GlossaryConfig()
    var obs = OBSCaptionConfig()
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
        case .pdf(let k): return pdfName(k)
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
    var mods: [String: Date] = [:]
    var terms: URL?             // 今日术语文件（terms-yyyymmdd.csv/txt）
    var glossaryStamp = ""      // 术语表文件和今日术语文件的修改时间（变了就重新载入）
}

func scanPDFFolder(_ folder: URL, date: String, rules: [String: NSRegularExpression],
                   termsRule: NSRegularExpression? = nil) -> PDFScan {
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
    var bestTerms: (url: URL, mod: Date)?
    for u in items {
        let name = u.lastPathComponent
        let range = NSRange(location: 0, length: (name as NSString).length)
        if let tr = termsRule, tr.firstMatch(in: name, options: [], range: range) != nil {
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            if bestTerms == nil || mod > bestTerms!.mod { bestTerms = (url: u, mod: mod) }
            continue
        }
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
    for (k, v) in best {
        r.matches[k] = v.url
        r.mods[k] = v.mod
    }
    r.terms = bestTerms?.url
    r.unused.sort()
    return r
}

/// 后台检查：PDF 文件夹 + 今日术语文件 + 术语表文件有没有改过
func scanEverything(folder: URL, date: String, rules: [String: NSRegularExpression], termsRule: NSRegularExpression?,
                    baseDir: URL, glossaryFiles: [URL]) -> PDFScan {
    var r = scanPDFFolder(folder, date: date, rules: rules, termsRule: termsRule)
    var stamp: [String] = []
    for u in glossaryFiles { stamp.append(u.lastPathComponent + "@" + String(modDate(u)?.timeIntervalSince1970 ?? 0)) }
    if let tr = termsRule, baseDir.standardizedFileURL != folder.standardizedFileURL,
       let b = newestFile(in: [baseDir], matching: tr) {
        let current = r.terms.flatMap { modDate($0) } ?? Date.distantPast
        if r.terms == nil || b.mod > current { r.terms = b.url }
    }
    if let t = r.terms { stamp.append(t.path + "@" + String(modDate(t)?.timeIntervalSince1970 ?? 0)) }
    r.glossaryStamp = stamp.joined(separator: "|")
    return r
}

// MARK: - Google Drive（用 rclone 把当天的 Google Slides 导出成 PDF，存到 PDF 文件夹）

struct GDriveConfig {
    var enabled = false
    var rclone = ""                     // 空 = 自动找（Presenter 文件夹里的 rclone 优先）
    var remote = "gdrive"               // rclone config 里起的名字
    var folderId = ""                   // Google Drive 文件夹网址里 folders/ 后面那一串
    var recheckBeforeMinutes: Double = 4
    var waitSeconds: Double = 60
}

struct GDriveRecord: Codable {
    var name: String
    var modTime: String
    var downloaded: Date
}

struct GDriveJob {
    let exe: URL
    let remote: String
    let folderId: String
    let keys: [String]
    let rules: [String: NSRegularExpression]
    let dest: URL
    let known: [String: GDriveRecord]
    let force: Bool
    var exportFormats = "pdf"           // Google 文档导出成什么格式（今日术语用 csv,txt）
    var wantPDF = true                  // 下载后检查是不是 PDF
    var isOptional = false              // 云端没有也不算问题（今日术语）
}

struct GDriveOutcome {
    let key: String
    let ok: Bool
    let downloaded: Bool
    let record: GDriveRecord?
    let message: String
}

struct ProcResult {
    let status: Int32
    let out: Data
    let err: String
    let timedOut: Bool

    var errorSummary: String {
        if timedOut { return "超时" }
        let lines = err.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Dangling shortcut") }
        if let last = lines.last { return String(last.prefix(200)) }
        return "rclone 退出码 \(status)"
    }
}

/// 运行一个命令（在后台线程调用）。输出写到临时文件，避免管道写满卡住
func runProcess(_ exe: URL, _ args: [String], timeout: TimeInterval) -> ProcResult {
    let fm = FileManager.default
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let outURL = tmp.appendingPathComponent("presenter-\(UUID().uuidString).out")
    let errURL = tmp.appendingPathComponent("presenter-\(UUID().uuidString).err")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? fm.removeItem(at: outURL)
        try? fm.removeItem(at: errURL)
    }
    guard let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL) else {
        return ProcResult(status: -1, out: Data(), err: "无法创建临时文件", timedOut: false)
    }
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = outH
    p.standardError = errH
    do {
        try p.run()
    } catch {
        outH.closeFile()
        errH.closeFile()
        return ProcResult(status: -1, out: Data(), err: "无法运行 \(exe.path)：\(error.localizedDescription)", timedOut: false)
    }
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while p.isRunning {
        if Date() > deadline {
            timedOut = true
            p.terminate()
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    p.waitUntilExit()
    outH.closeFile()
    errH.closeFile()
    let out = (try? Data(contentsOf: outURL)) ?? Data()
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    return ProcResult(status: p.terminationStatus, out: out, err: err, timedOut: timedOut)
}

/// rclone 的时间（如 2026-11-14T22:31:05.123456789-05:00）→ Date（去掉小数部分再解析）
func parseRcloneTime(_ s: String) -> Date? {
    let cleaned = s.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}

func isPDFFile(_ url: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { h.closeFile() }
    let head = h.readData(ofLength: 5)
    return head.count == 5 && String(data: head, encoding: .ascii) == "%PDF-"
}

/// 在 Google Drive 文件夹里找今天的 Slides，导出成 PDF 下载（在后台线程运行）
func runGDriveJob(_ job: GDriveJob) -> [GDriveOutcome] {
    let common = ["--drive-root-folder-id", job.folderId, "--drive-export-formats", job.exportFormats]
    var entries: [[String: Any]] = []
    var listErr: String?
    for attempt in 1...3 {
        let r = runProcess(job.exe, ["lsjson", job.remote + ":", "--files-only"] + common, timeout: 60)
        if r.status == 0, !r.timedOut,
           let arr = (try? JSONSerialization.jsonObject(with: r.out, options: [])) as? [[String: Any]] {
            entries = arr
            listErr = nil
            break
        }
        listErr = r.errorSummary
        writeLog("⚠️ Google Drive 列文件失败（第 \(attempt) 次）：\(r.errorSummary)")
        if attempt < 3 { Thread.sleep(forTimeInterval: 10) }
    }
    if let e = listErr {
        return job.keys.map {
            GDriveOutcome(key: $0, ok: false, downloaded: false, record: nil, message: "⚠️ 无法连接 Google Drive：\(e)")
        }
    }
    let fm = FileManager.default
    let tmpDir = job.dest.appendingPathComponent(".presenter-download", isDirectory: true)
    var outcomes: [GDriveOutcome] = []
    for key in job.keys {
        guard let re = job.rules[key] else { continue }
        var bestName = ""
        var bestMod = ""
        var bestDate = Date.distantPast
        var count = 0
        for e in entries {
            guard let name = e["Name"] as? String else { continue }
            let range = NSRange(location: 0, length: (name as NSString).length)
            guard re.firstMatch(in: name, options: [], range: range) != nil else { continue }
            count += 1
            let mod = (e["ModTime"] as? String) ?? ""
            let d = parseRcloneTime(mod) ?? Date.distantPast
            if bestName.isEmpty || d > bestDate {
                bestName = name
                bestMod = mod
                bestDate = d
            }
        }
        if bestName.isEmpty {
            outcomes.append(GDriveOutcome(key: key, ok: job.isOptional, downloaded: false, record: nil,
                                          message: job.isOptional ? "云端没有（可选）" : "⚠️ 云端文件夹里没有今天的文件"))
            continue
        }
        let target = job.dest.appendingPathComponent(bestName)
        if !job.force, let k = job.known[key], k.name == bestName, k.modTime == bestMod, fm.fileExists(atPath: target.path) {
            outcomes.append(GDriveOutcome(key: key, ok: true, downloaded: false, record: k,
                                          message: "✅ 已是最新：\(bestName)"))
            continue
        }
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: nil)
        let tmpFile = tmpDir.appendingPathComponent(bestName)
        var err = ""
        var done = false
        for attempt in 1...2 {
            try? fm.removeItem(at: tmpFile)
            let r = runProcess(job.exe, ["copyto", job.remote + ":" + bestName, tmpFile.path] + common, timeout: 240)
            let valid = job.wantPDF ? isPDFFile(tmpFile) : ((try? Data(contentsOf: tmpFile))?.isEmpty == false)
            if r.status == 0, !r.timedOut, valid {
                done = true
                break
            }
            err = (r.status == 0 && !r.timedOut) ? (job.wantPDF ? "下载的文件不是有效的 PDF" : "下载的文件是空的") : r.errorSummary
            writeLog("⚠️ 下载 \(bestName) 失败（第 \(attempt) 次）：\(err)")
            if attempt < 2 { Thread.sleep(forTimeInterval: 10) }
        }
        if !done {
            outcomes.append(GDriveOutcome(key: key, ok: false, downloaded: false, record: nil, message: "⚠️ 下载失败：\(err)"))
            continue
        }
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmpFile)
            } else {
                try fm.moveItem(at: tmpFile, to: target)
            }
        } catch {
            outcomes.append(GDriveOutcome(key: key, ok: false, downloaded: false, record: nil,
                                          message: "⚠️ 无法存到 PDF 文件夹：\(error.localizedDescription)"))
            continue
        }
        var msg = "✅ 已下载：\(bestName)"
        if count > 1 { msg += "（云端有 \(count) 个符合，用最新的）" }
        let rec = GDriveRecord(name: bestName, modTime: bestMod, downloaded: Date())
        outcomes.append(GDriveOutcome(key: key, ok: true, downloaded: true, record: rec, message: msg))
    }
    return outcomes
}

struct CachedDoc {
    let url: URL
    let mod: Date?
    let doc: PDFDocument
}

// MARK: - 快捷键解析

enum HotAction: String, CaseIterable {
    case next, prev, first, last, black, extend, auto, caption, captionSource, captionLanguage
    case showOriginal, showTranslation, showBoth, sentenceMode
    case pdfNow, welcomeNow, clockNow, countdownNow, quit

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
        case .captionSource: return "字幕来源 Kaleo ↔ 本机识别"
        case .captionLanguage: return "本机识别语言 普通话 ↔ 英语"
        case .showOriginal: return "本机识别 只显示原文"
        case .showTranslation: return "本机识别 只显示译文"
        case .showBoth: return "本机识别 原文 + 译文"
        case .sentenceMode: return "本机识别 整句翻译 开/关"
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

// 滚动字幕的显示程序（投影字幕条和 OBS 叠加页共用）：从左到右写，一行写满整行向上滚动，写完的行不再变动
let captionRendererJS = #"""
(function () {
  'use strict';
  // 滚动字幕：从左到右写，一行写满就整行向上滚动；已经写完的行不再变动
  var box = document.getElementById('box');
  var phEl = document.getElementById('ph');
  var band = document.getElementById('band');
  var cfg = { lines: 3, fg: '#ffffff', bg: 'transparent', ph: '', margin: -1, hideEmpty: false, shadow: '' };
  var st = { e: -1, m: 'single', v: true };
  var canvas = document.createElement('canvas');
  var ctx = canvas.getContext('2d');
  var FAMILY = '-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Helvetica Neue",Arial,sans-serif';
  var CLOSE = '，。！？、；：,.!?;:…）)》」』”’%】';
  var OPEN = '（(《「『“‘【';
  var WORD = /[A-Za-z0-9À-ɏЀ-ӿ'’_\-]+[.,!?;:%)\]}"”’]*|\s+|[\s\S]/g;

  function makeStream(id) {
    var clip = document.createElement('div');
    clip.className = 'clip';
    var inner = document.createElement('div');
    inner.className = 'inner t' + (id === 'a' ? ' orig' : '');
    clip.appendChild(inner);
    box.appendChild(clip);
    return { id: id, clip: clip, el: inner, done: [], open: '', raw: '', tail: '', n: 0, lh: 0, w: 0,
             font: '', total: -1, animK: 0, animUntil: 0, last: 0 };
  }
  var A = makeStream('a');   // 原文（本机识别）
  var B = makeStream('b');   // 译文 / Kaleo

  function width(s) { return ctx.measureText(s).width; }
  function fit(s, w) {
    var lo = 1, hi = s.length;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (width(s.slice(0, mid)) <= w) { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
  }

  // 把文字排成行：英文按单词换行，中文可以在任何字之间换行；标点不放在行首，开括号不留在行尾
  function layout(x, text) {
    var out = [], cur = '', toks = text.match(WORD) || [], w = x.w;
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i];
      if (/^\s+$/.test(t)) { if (cur && cur.charAt(cur.length - 1) !== ' ') { cur += ' '; } continue; }
      if (!cur) { cur = t; }
      else if (width(cur + t) <= w) { cur += t; continue; }
      else if (t.length <= 2 && CLOSE.indexOf(t.charAt(0)) >= 0) { cur += t; continue; }
      else {
        var line = cur.replace(/\s+$/, ''), carry = '';
        while (line.length > 1 && OPEN.indexOf(line.charAt(line.length - 1)) >= 0) {
          carry = line.charAt(line.length - 1) + carry;
          line = line.slice(0, -1);
        }
        out.push(line);
        cur = carry + t;
      }
      while (cur.length > 1 && width(cur) > w) {
        var k = fit(cur, w);
        out.push(cur.slice(0, k));
        cur = cur.slice(k);
      }
    }
    return { lines: out, open: cur };
  }

  function addText(x, s) {
    if (!s) { return; }
    x.raw += s;
    if (x.raw.length > 2400) { x.raw = x.raw.slice(-1600); }
    if (!x.w) { return; }
    ctx.font = x.font;
    var r = layout(x, x.open + s);
    for (var i = 0; i < r.lines.length; i++) { x.done.push(r.lines[i]); }
    if (x.done.length > 40) { x.done.splice(0, x.done.length - 40); }
    x.open = r.open;
  }

  function relayout(x) {
    x.done = []; x.open = ''; x.total = -1;
    if (!x.w || !x.raw) { return; }
    ctx.font = x.font;
    var r = layout(x, x.raw);
    x.done = r.lines.slice(-40);
    x.open = r.open;
  }

  function resetStream(x) {
    x.done = []; x.open = ''; x.raw = ''; x.tail = ''; x.total = -1; x.last = 0; x.animUntil = 0;
    x.el.innerHTML = '';
    x.el.style.transition = 'none';
    x.el.style.transform = 'translateY(0)';
  }

  function allLines(x) {
    ctx.font = x.font;
    var r = layout(x, x.open + x.tail);
    var arr = x.done.concat(r.lines);
    if (/\S/.test(r.open)) { arr.push(r.open); }
    return arr;
  }

  function render(x) {
    if (!x.n) { x.clip.style.display = 'none'; x.total = -1; return; }
    x.clip.style.display = 'block';
    var all = allLines(x), total = all.length, n = x.n, now = Date.now(), k = 0, extra = 0;
    if (x.total >= 0 && total > x.total) { k = Math.min(total - x.total, n); }
    x.total = total;
    if (k > 0) { extra = k; } else if (now < x.animUntil) { extra = x.animK; }
    var rows = all.slice(Math.max(0, total - n - extra));
    var el = x.el;
    while (el.childNodes.length < rows.length) {
      var d = document.createElement('div');
      d.className = 'ln';
      el.appendChild(d);
    }
    while (el.childNodes.length > rows.length) { el.removeChild(el.firstChild); }
    for (var i = 0; i < rows.length; i++) {
      var c = el.childNodes[i];
      if (c.textContent !== rows[i]) { c.textContent = rows[i]; }
      c.style.height = x.lh + 'px';
      c.style.lineHeight = x.lh + 'px';
    }
    if (k > 0) {
      el.style.transition = 'none';
      el.style.transform = 'translateY(' + (k * x.lh) + 'px)';
      void el.offsetHeight;
      el.style.transition = 'transform 320ms ease-out';
      el.style.transform = 'translateY(0)';
      x.animK = k;
      x.animUntil = now + 340;
    }
  }

  function hasText(x) { return x.n > 0 && x.total > 0; }

  function updateVisibility() {
    var any = hasText(A) || hasText(B);
    if (phEl) {
      phEl.textContent = cfg.ph;
      phEl.style.display = (!any && cfg.ph) ? 'flex' : 'none';
    }
    var show = st.v && (any || !cfg.hideEmpty);
    if (band) { band.style.opacity = show ? '1' : '0'; }
    else { document.body.style.opacity = st.v ? '1' : '0'; }
  }

  function setStream(x, n, lh, fs, w) {
    var font = '600 ' + fs + 'px ' + FAMILY;
    var changed = x.lh !== lh || x.w !== w || x.font !== font;
    x.n = n; x.lh = lh; x.w = w; x.font = font;
    x.el.style.font = font;
    x.clip.style.height = (n * lh) + 'px';
    if (changed) { relayout(x); }
  }

  function layoutAll() {
    if (cfg.margin >= 0) {
      box.style.left = cfg.margin + '%';
      box.style.right = cfg.margin + '%';
    }
    var H = box.clientHeight || window.innerHeight || 200;
    var W = box.clientWidth || window.innerWidth || 800;
    var lines = Math.max(1, cfg.lines), la = 0, lb = 0, m = st.m;
    if (m === 'both') {
      la = lines >= 2 ? Math.max(1, Math.floor(lines / 3)) : 0;
      lb = lines - la;
    } else if (m === 'original') {
      la = lines;
    } else {
      lb = lines;
    }
    var lh = Math.max(10, Math.floor(H * 0.88 / lines));
    var fs = Math.max(8, Math.floor(lh / 1.3));
    setStream(A, la, lh, fs, W);
    setStream(B, lb, lh, fs, W);
    if (phEl) { phEl.style.fontSize = Math.floor(fs * 0.8) + 'px'; }
    render(A); render(B); updateVisibility();
  }

  function applyStream(x, s) {
    if (!s) { return; }
    if (s.r) { x.done = []; x.open = ''; x.raw = ''; x.total = -1; }
    var add = s.add || [];
    for (var i = 0; i < add.length; i++) { addText(x, add[i]); }
    x.tail = s.t || '';
    if (typeof s.id === 'number') { x.last = s.id; }
  }

  // Presenter 送来的变化：e = 第几轮（变了就清空重来），m = 显示方式，v = 是否显示，
  // a / b = 原文 / 译文：add = 新定下来的文字，t = 还会变的最后一段，id = 已收到第几段
  window.capApply = function (d) {
    if (!d) { return; }
    if (d.e !== st.e) { st.e = d.e; resetStream(A); resetStream(B); }
    var modeChanged = !!d.m && d.m !== st.m;
    if (d.m) { st.m = d.m; }
    st.v = d.v !== false;
    applyStream(A, d.a);
    applyStream(B, d.b);
    if (modeChanged) { layoutAll(); } else { render(A); render(B); updateVisibility(); }
  };

  window.capState = function () { return { e: st.e, a: A.last, b: B.last }; };

  window.capStyle = function (o) {
    for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k)) { cfg[k] = o[k]; } }
    box.style.color = cfg.fg;
    if (phEl) { phEl.style.color = cfg.fg; }
    if (!band) { document.documentElement.style.background = cfg.bg; document.body.style.background = cfg.bg; }
    var sh = cfg.shadow;
    if (!sh) {
      var light = true;
      try {
        var mm = getComputedStyle(box).color.match(/\d+(\.\d+)?/g);
        light = (0.299 * mm[0] + 0.587 * mm[1] + 0.114 * mm[2]) > 140;
      } catch (e) {}
      sh = String(cfg.bg).toLowerCase() === 'transparent'
        ? (light ? '0 0 6px rgba(0,0,0,.95),0 0 2px #000' : '0 0 6px rgba(255,255,255,.95),0 0 2px #fff') : 'none';
    }
    box.style.textShadow = sh;
    layoutAll();
  };

  window.addEventListener('resize', layoutAll);
  layoutAll();
})();
"""#

let captionPageCSS = #"""
html,body{margin:0;height:100%;overflow:hidden;background:transparent}
.clip{position:relative;overflow:hidden;flex:none}
.inner{position:absolute;left:0;right:0;bottom:0;will-change:transform}
.ln{white-space:pre;overflow:hidden;text-align:left}
.t{font-weight:600}
.orig{opacity:.78}
"""#

// 投影上的字幕条（左右留白由 caption.marginPercent 决定）
let captionHTML = "<!doctype html><html><head><meta charset=\"utf-8\"><style>" + captionPageCSS + #"""
body{cursor:none}
#box{position:fixed;top:0;bottom:0;left:10%;right:10%;display:flex;flex-direction:column;justify-content:center}
#ph{position:fixed;left:0;right:0;top:0;bottom:0;display:none;align-items:center;justify-content:center;opacity:.35;font-weight:400;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Helvetica Neue",Arial,sans-serif}
</style></head><body><div id="box"></div><div id="ph"></div><script>
"""# + captionRendererJS + "</script></body></html>"

// OBS 浏览器来源用的字幕页：每 0.2 秒向 Presenter 取一次新文字；Presenter 没在运行时自动隐藏
let obsPollJS = #"""
(function () {
  var fails = 0;
  function poll() {
    var s = capState();
    fetch('/state?e=' + s.e + '&a=' + s.a + '&b=' + s.b, { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) { fails = 0; capApply(d); setTimeout(poll, 200); })
      .catch(function () {
        fails++;
        if (fails > 5) { var b = document.getElementById('band'); if (b) { b.style.opacity = '0'; } }
        setTimeout(poll, 1000);
      });
  }
  poll();
})();
"""#

/// CSS 里用的颜色值：去掉会破坏样式的字符
func cssValue(_ s: String) -> String {
    return String(s.filter { !";{}<>\"\\".contains($0) })
}

func obsCaptionHTML(_ o: OBSCaptionConfig) -> String {
    let band = "#band{position:fixed;left:\(o.marginPercent)%;right:\(o.marginPercent)%;bottom:\(o.bottomPercent)%;"
        + "height:\(o.heightPercent)%;background:\(cssValue(o.background));border-radius:1.2vh;opacity:0;transition:opacity .4s}"
        + "#box{position:absolute;left:3%;right:3%;top:0;bottom:0;display:flex;flex-direction:column;justify-content:center}"
    let style = "{fg:\(jsString(o.color)),bg:'transparent',lines:\(o.lines),ph:'',margin:-1,hideEmpty:true,"
        + "shadow:'0 0 4px rgba(0,0,0,.85),0 0 1px #000'}"
    return "<!doctype html><html><head><meta charset=\"utf-8\"><title>Presenter 字幕</title><style>" + captionPageCSS + band
        + "</style></head><body><div id=\"band\"><div id=\"box\"></div></div><script>" + captionRendererJS
        + "\ncapStyle(\(style));\n" + obsPollJS + "</script></body></html>"
}

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

// MARK: - 术语表：专有名词纠错 + 翻译前替换（本机识别用）
//
// 文件格式（glossary.csv、glossary-bible.csv、terms-yyyymmdd.csv/.txt 都一样）：
//   中文,English,中文常被识别成,英文常被识别成,方向
//   - 第 3/4 列：识别错的写法，多个用 | 分开 → 识别出来后先改正（原文字幕也显示正确的字）
//   - 翻译前把中文术语换成英文（或反过来），译名就固定了
//   - 方向：空 = 双向；中→英 = 只在中文翻英文时替换；英→中 = 只在英文翻中文时替换
//   - “!”开头的行：这些词永远不改（自动纠正改错时用）
//   - 今日术语（terms 文件、今天 PDF 里出现的术语和名字）还会做“读音相同”的自动纠正

struct GlossaryEntry {
    var zh: String
    var en: String
    var zhVariants: [String]
    var enVariants: [String]
    var direction: Int          // 0 双向；1 只在中→英时替换；2 只在英→中时替换
}

struct GlossarySource {
    let name: String            // 文件名，或“PDF”
    let entries: [GlossaryEntry]
    let protected: [String]     // “!”开头的行：这些词永远不改
    let today: Bool             // 今日术语：优先，并参与“读音相同”的自动纠正
}

/// 一处纠正。how：表（术语表第 3/4 列写明的）| 拼音（和今日术语读音相同，已改）| 可能（读音相同但像普通词语，没改，只记下来）
struct CaptionFix {
    let from: String
    let to: String
    let how: String
}

/// 本机识别的一句（写进字幕记录）
struct CaptionRecord {
    let time: Date
    let language: String        // 识别语言
    let raw: String             // 识别原文
    let fixed: String           // 纠正后
    let fixes: [CaptionFix]
    let sent: String            // 送去翻译的文字（翻译前替换后）；没翻译时为空
    let translated: String
    let seconds: Double         // 翻译用时
}

/// 读文本文件：UTF-8（可带 BOM）、UTF-16、GB18030（Windows 版 Excel 存的 CSV）
func readTextFile(_ url: URL) -> String? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    var s: String?
    if d.count >= 2 && ((d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xFE) || (d[d.startIndex] == 0xFE && d[d.startIndex + 1] == 0xFF)) {
        s = String(data: d, encoding: .utf16)
    } else if let u = String(data: d, encoding: .utf8) {
        s = u
    } else {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        s = String(data: d, encoding: String.Encoding(rawValue: gb))
    }
    guard var t = s else { return nil }
    if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
    return t
}

/// 一行 → 各列（英文逗号、中文逗号、Tab 都算分隔；支持英文双引号）
func splitGlossaryLine(_ line: String) -> [String] {
    var cols: [String] = []
    var cur = ""
    var inQuote = false
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if inQuote {
            if c == "\"" {
                if i + 1 < chars.count && chars[i + 1] == "\"" {
                    cur.append("\"")
                    i += 1
                } else {
                    inQuote = false
                }
            } else {
                cur.append(c)
            }
        } else if c == "\"" {
            inQuote = true
        } else if c == "," || c == "，" || c == "\t" {
            cols.append(cur.trimmingCharacters(in: .whitespaces))
            cur = ""
        } else {
            cur.append(c)
        }
        i += 1
    }
    cols.append(cur.trimmingCharacters(in: .whitespaces))
    return cols
}

func splitVariants(_ s: String, extra: String) -> [String] {
    var seps: Set<Character> = ["|", "｜"]
    for c in extra { seps.insert(c) }
    return s.split(whereSeparator: { seps.contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
}

func glossaryDirection(_ s: String) -> Int {
    var t = s.lowercased()
    for ch in [" ", "-", ">", "→", "到", "—", "–"] { t = t.replacingOccurrences(of: ch, with: "") }
    if t.hasPrefix("中") || t.hasPrefix("zh") { return 1 }
    if t.hasPrefix("英") || t.hasPrefix("en") { return 2 }
    return 0
}

func parseGlossary(_ text: String, name: String) -> (entries: [GlossaryEntry], protected: [String], problems: [String]) {
    var entries: [GlossaryEntry] = []
    var protected: [String] = []
    var problems: [String] = []
    let hanLatin = try? NSRegularExpression(pattern: "^([\\p{Han}·]+)\\s+([A-Za-z].*)$", options: [])
    var n = 0
    for rawLine in text.components(separatedBy: .newlines) {
        n += 1
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("!") || line.hasPrefix("！") {
            for p in splitVariants(String(line.dropFirst()), extra: ",，、") where !p.isEmpty { protected.append(p) }
            continue
        }
        var cols = splitGlossaryLine(line)
        if cols.allSatisfy({ $0.isEmpty }) { continue }      // 只有逗号的行（Excel 常见）
        // 一行里只有“以利沙 Elisha”这样用空格隔开的（Google 文档里常这样写）
        if cols.count == 1, let re = hanLatin {
            let ns = cols[0] as NSString
            if let m = re.firstMatch(in: cols[0], options: [], range: NSRange(location: 0, length: ns.length)) {
                cols = [ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)]
            }
        }
        let zh = cols[0]
        let en = cols.count > 1 ? cols[1] : ""
        if zh == "中文" || zh.lowercased() == "chinese" { continue }   // 标题行
        if zh.isEmpty && en.isEmpty {
            problems.append("\(name) 第 \(n) 行：第 1、2 列都是空的")
            continue
        }
        let zv = cols.count > 2 ? splitVariants(cols[2], extra: "、").filter { !$0.isEmpty && $0 != zh } : []
        let ev = cols.count > 3 ? splitVariants(cols[3], extra: "").filter { !$0.isEmpty && $0.lowercased() != en.lowercased() } : []
        if zh.isEmpty && !zv.isEmpty { problems.append("\(name) 第 \(n) 行：写了中文误识别（第 3 列），但第 1 列中文是空的") }
        if en.isEmpty && !ev.isEmpty { problems.append("\(name) 第 \(n) 行：写了英文误识别（第 4 列），但第 2 列英文是空的") }
        let dir = cols.count > 4 ? glossaryDirection(cols[4]) : 0
        entries.append(GlossaryEntry(zh: zh, en: en, zhVariants: zv, enVariants: ev, direction: dir))
    }
    return (entries, protected, problems)
}

/// 汉字 → 不带声调的拼音（如 以 → yi）；不是汉字返回 nil
var pinyinCache: [Character: String] = [:]

func pinyinSyllable(_ c: Character) -> String? {
    if let s = pinyinCache[c] { return s.isEmpty ? nil : s }
    var r = ""
    let scalars = c.unicodeScalars
    if scalars.count == 1, let u = scalars.first, u.properties.isIdeographic,
       let marked = String(c).applyingTransform(.mandarinToLatin, reverse: false),
       let latin = marked.applyingTransform(.stripDiacritics, reverse: false) {
        r = latin.lowercased().trimmingCharacters(in: .whitespaces)
        if r == String(c) || r.contains(" ") { r = "" }
    }
    pinyinCache[c] = r
    return r.isEmpty ? nil : r
}

func pinyinKey(_ s: String) -> String? {
    var parts: [String] = []
    for c in s {
        guard let p = pinyinSyllable(c) else { return nil }
        parts.append(p)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// 一组词 → 正则（长的优先）；latin = 英文词，前后不能紧挨字母数字
func glossaryRegex(_ words: [String], latin: Bool, ignoreCase: Bool) -> NSRegularExpression? {
    let ws = Array(Set(words.filter { !$0.isEmpty })).sorted { a, b in
        a.count != b.count ? a.count > b.count : a < b
    }
    if ws.isEmpty { return nil }
    let alt = ws.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    let pattern = latin ? "(?<![A-Za-z0-9])(?:\(alt))(?![A-Za-z0-9])" : "(?:\(alt))"
    return try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
}

/// 按 re 找词，换成 lookup 的结果；和 block 找到的词重叠的不换
func glossaryReplace(_ text: String, _ re: NSRegularExpression?, blockedBy block: NSRegularExpression?,
                     _ lookup: (String) -> String?) -> (text: String, pairs: [(String, String)]) {
    guard let re = re, !text.isEmpty else { return (text, []) }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let blocked: [NSRange] = block?.matches(in: text, options: [], range: full).map { $0.range } ?? []
    var out = ""
    var pos = 0
    var pairs: [(String, String)] = []
    for m in re.matches(in: text, options: [], range: full) {
        let r = m.range
        if blocked.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
        let word = ns.substring(with: r)
        guard let rep = lookup(word), rep != word else { continue }
        out += ns.substring(with: NSRange(location: pos, length: r.location - pos))
        out += rep
        pos = r.location + r.length
        pairs.append((word, rep))
    }
    if pairs.isEmpty { return (text, []) }
    out += ns.substring(from: pos)
    return (out, pairs)
}

/// 中文里夹了英文词之后，整理空格（标点前后不要空格）
func tidyMixedSpaces(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: " +([，。！？、：；,.!?:;）)”」』])", with: "$1", options: .regularExpression)
    t = t.replacingOccurrences(of: "([（(“「『，。！？、：；]) +", with: "$1", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespaces)
}

/// 中文分词结果里由两个字以上组成的词（字的位置，左闭右开）
func chineseWordSpans(_ text: String) -> [(Int, Int)] {
    let tok = NLTokenizer(unit: .word)
    tok.string = text
    tok.setLanguage(.simplifiedChinese)
    var spans: [(Int, Int)] = []
    tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let a = text.distance(from: text.startIndex, to: range.lowerBound)
        let b = text.distance(from: text.startIndex, to: range.upperBound)
        if b - a > 1 { spans.append((a, b)) }
        return true
    }
    return spans
}

final class CaptionGlossary {
    let summary: String
    let todayTerms: [String]
    let problems: [String]
    let fuzzyCount: Int
    private let beforeTranslation: Bool
    private let zhFix: [String: String]
    private let enFix: [String: String]
    private let zh2en: [String: String]
    private let en2zhCase: [String: String]
    private let en2zhNoCase: [String: String]
    private let englishWords: Set<String>
    private let zhFixRE: NSRegularExpression?
    private let enFixRE: NSRegularExpression?
    private let zhBlockRE: NSRegularExpression?
    private let enBlockRE: NSRegularExpression?
    private let zh2enRE: NSRegularExpression?
    private let zh2enBlockRE: NSRegularExpression?
    private let en2zhCaseRE: NSRegularExpression?
    private let en2zhNoCaseRE: NSRegularExpression?
    private let en2zhBlockRE: NSRegularExpression?
    private let fuzzy: [Int: [String: String]]
    private let fuzzyLengths: [Int]
    private let protectedChars: [[Character]]

    static let numeralChars: Set<Character> = Set("一二三四五六七八九十百千万亿零两几")

    /// sources 按优先顺序排列：今日术语 → glossary.csv → glossary-bible.csv
    init(sources: [GlossarySource], fuzzyMode: String, fuzzyMinLength: Int, beforeTranslation: Bool,
         problems: [String], summary: String) {
        var zhFix: [String: String] = [:]
        var enFix: [String: String] = [:]
        var zh2en: [String: String] = [:]
        var en2zhCase: [String: String] = [:]
        var en2zhNoCase: [String: String] = [:]
        var englishWords = Set<String>()
        var zTargets = Set<String>()
        var eTargets = Set<String>()
        var zhOnly = Set<String>()
        var enOnly = Set<String>()
        var protectedList: [String] = []
        var today: [String] = []
        var fz: [Int: [String: (term: String, prio: Int)]] = [:]
        for (prio, src) in sources.enumerated() {
            protectedList += src.protected
            for e in src.entries {
                let zh = e.zh
                let en = e.en
                if !zh.isEmpty {
                    for v in e.zhVariants where zhFix[v] == nil {
                        zhFix[v] = zh
                        zTargets.insert(zh)
                    }
                }
                if !en.isEmpty {
                    for w in en.lowercased().split(whereSeparator: { !$0.isLetter }) { englishWords.insert(String(w)) }
                    for v in e.enVariants where enFix[v.lowercased()] == nil {
                        enFix[v.lowercased()] = en
                        eTargets.insert(en)
                    }
                }
                if !zh.isEmpty && !en.isEmpty {
                    if e.direction != 2 && zh2en[zh] == nil { zh2en[zh] = en }
                    if e.direction != 1 {
                        if en.rangeOfCharacter(from: .uppercaseLetters) != nil {
                            if en2zhCase[en] == nil { en2zhCase[en] = zh }
                        } else if en2zhNoCase[en.lowercased()] == nil {
                            en2zhNoCase[en.lowercased()] = zh
                        }
                    }
                } else if !zh.isEmpty {
                    zhOnly.insert(zh)
                } else {
                    enOnly.insert(en)
                }
                if src.today && !zh.isEmpty && !today.contains(zh) { today.append(zh) }
                let useFuzzy = fuzzyMode == "all" || (fuzzyMode == "today" && src.today)
                if useFuzzy && zh.count >= fuzzyMinLength, let key = pinyinKey(zh) {
                    var table = fz[zh.count] ?? [:]
                    if let old = table[key] {
                        // 同一个文件里两个词读音一样：分不清，不自动纠正
                        if old.term != zh && old.prio == prio { table[key] = (term: "", prio: prio) }
                    } else {
                        table[key] = (term: zh, prio: prio)
                    }
                    fz[zh.count] = table
                }
            }
        }
        // 只有中文（或只有英文）的词：保护它不被拆开替换；但别的文件里给了译名的词不算
        zhOnly.subtract(zh2en.keys)
        enOnly = enOnly.filter { en2zhCase[$0] == nil && en2zhNoCase[$0.lowercased()] == nil }
        var fuzzy: [Int: [String: String]] = [:]
        var fuzzyCount = 0
        for (len, table) in fz {
            var t: [String: String] = [:]
            for (k, v) in table where !v.term.isEmpty {
                t[k] = v.term
                fuzzyCount += 1
            }
            if !t.isEmpty { fuzzy[len] = t }
        }
        self.summary = summary
        self.problems = problems
        self.todayTerms = today
        self.beforeTranslation = beforeTranslation
        self.zhFix = zhFix
        self.enFix = enFix
        self.zh2en = zh2en
        self.en2zhCase = en2zhCase
        self.en2zhNoCase = en2zhNoCase
        self.englishWords = englishWords
        self.fuzzy = fuzzy
        self.fuzzyCount = fuzzyCount
        self.fuzzyLengths = fuzzy.keys.sorted(by: >)
        self.protectedChars = protectedList.filter { !$0.isEmpty }.map { Array($0) }
        self.zhFixRE = glossaryRegex(Array(zhFix.keys), latin: false, ignoreCase: false)
        self.enFixRE = glossaryRegex(Array(enFix.keys), latin: true, ignoreCase: true)
        self.zhBlockRE = glossaryRegex(Array(zTargets) + protectedList, latin: false, ignoreCase: false)
        self.enBlockRE = glossaryRegex(Array(eTargets) + protectedList, latin: true, ignoreCase: true)
        self.zh2enRE = glossaryRegex(Array(zh2en.keys), latin: false, ignoreCase: false)
        self.zh2enBlockRE = glossaryRegex(Array(zhOnly) + protectedList, latin: false, ignoreCase: false)
        self.en2zhCaseRE = glossaryRegex(Array(en2zhCase.keys), latin: true, ignoreCase: false)
        self.en2zhNoCaseRE = glossaryRegex(Array(en2zhNoCase.keys), latin: true, ignoreCase: true)
        self.en2zhBlockRE = glossaryRegex(Array(enOnly) + protectedList, latin: true, ignoreCase: true)
    }

    /// 识别结果纠错：先按术语表第 3/4 列，再按今日术语的读音（只对中文）
    func correct(_ text: String, language: String, fuzzyOK: Bool = true) -> (text: String, fixes: [CaptionFix]) {
        var fixes: [CaptionFix] = []
        if language.hasPrefix("zh") {
            let r = glossaryReplace(text, zhFixRE, blockedBy: zhBlockRE) { self.zhFix[$0] }
            fixes += r.pairs.map { CaptionFix(from: $0.0, to: $0.1, how: "表") }
            let s = fuzzyOK ? fuzzyFix(r.text, fixes: &fixes) : r.text
            return (s, fixes)
        }
        let r = glossaryReplace(text, enFixRE, blockedBy: enBlockRE) { self.enFix[$0.lowercased()] }
        fixes += r.pairs.map { CaptionFix(from: $0.0, to: $0.1, how: "表") }
        return (r.text, fixes)
    }

    /// 翻译前：把术语换成目标语言的译名
    func prepareForTranslation(_ text: String, language: String) -> String {
        guard beforeTranslation else { return text }
        if language.hasPrefix("zh") {
            let r = glossaryReplace(text, zh2enRE, blockedBy: zh2enBlockRE) { w in self.zh2en[w].map { " \($0) " } }
            return r.pairs.isEmpty ? text : tidyMixedSpaces(r.text)
        }
        var s = glossaryReplace(text, en2zhCaseRE, blockedBy: en2zhBlockRE) { self.en2zhCase[$0] }.text
        s = glossaryReplace(s, en2zhNoCaseRE, blockedBy: en2zhBlockRE) { self.en2zhNoCase[$0.lowercased()] }.text
        return s
    }

    /// 这个英文名字的每个词都已经在术语表里（复查时用）
    func knowsEnglish(_ name: String) -> Bool {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !words.isEmpty && words.allSatisfy { englishWords.contains($0) }
    }

    /// 和今日术语读音相同（不看声调）的几个字 → 换成术语。看起来像普通词语的（如“哥哥他”“八十八”）不改，只记成“可能”
    private func fuzzyFix(_ text: String, fixes: inout [CaptionFix]) -> String {
        guard let shortest = fuzzyLengths.last else { return text }
        let chars = Array(text)
        let n = chars.count
        if n < shortest { return text }
        let syl = chars.map { pinyinSyllable($0) }
        var used = [Bool](repeating: false, count: n)
        for p in protectedChars where p.count <= n {
            var i = 0
            while i + p.count <= n {
                if Array(chars[i..<(i + p.count)]) == p {
                    for k in i..<(i + p.count) { used[k] = true }
                    i += p.count
                } else {
                    i += 1
                }
            }
        }
        var spans: [(Int, Int)]?
        var reps: [(start: Int, len: Int, term: String)] = []
        for len in fuzzyLengths where len <= n {
            guard let table = fuzzy[len] else { continue }
            var i = 0
            while i + len <= n {
                if used[i..<(i + len)].contains(true) {
                    i += 1
                    continue
                }
                var parts: [String] = []
                for k in i..<(i + len) {
                    guard let s = syl[k] else { break }
                    parts.append(s)
                }
                guard parts.count == len, let term = table[parts.joined(separator: " ")] else {
                    i += 1
                    continue
                }
                let window = String(chars[i..<(i + len)])
                if window != term {
                    if spans == nil { spans = chineseWordSpans(text) }
                    if CaptionGlossary.looksLikeWords(window, start: i, len: len, spans: spans ?? []) {
                        fixes.append(CaptionFix(from: window, to: term, how: "可能"))
                    } else {
                        reps.append((start: i, len: len, term: term))
                        fixes.append(CaptionFix(from: window, to: term, how: "拼音"))
                    }
                }
                for k in i..<(i + len) { used[k] = true }
                i += len
            }
        }
        if reps.isEmpty { return text }
        reps.sort { $0.start < $1.start }
        var out = ""
        var pos = 0
        for r in reps {
            out += String(chars[pos..<r.start])
            out += r.term
            pos = r.start + r.len
        }
        out += String(chars[pos..<n])
        return out
    }

    /// 这几个字像是普通词语：全是数字，或里面有一个更短的词（“哥哥他”里的“哥哥”），或有词跨过边界
    static func looksLikeWords(_ window: String, start: Int, len: Int, spans: [(Int, Int)]) -> Bool {
        if window.allSatisfy({ numeralChars.contains($0) }) { return true }
        let end = start + len
        for (a, b) in spans {
            if a >= start && b <= end && b - a < len { return true }
            if (a < start && b > start) || (a < end && b > end) { return true }
        }
        return false
    }
}

/// PDF 里的文字（找今天的专有名词用）
func extractPDFText(_ url: URL) -> String {
    guard let doc = PDFDocument(url: url) else { return "" }
    if doc.isLocked && !doc.unlock(withPassword: "") { return "" }
    return doc.string ?? ""
}

/// PDF 里“讲员：王约翰牧师”这类行里的名字
func pdfSpeakerNames(_ text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: "(讲员|讲道|证道|讲台|主讲|讲者|主领|领会|领诗|领唱|司会|主席|司琴|伴奏|读经|启应|祷告|代祷|报告|翻译)\\s*[:：]\\s*([\\p{Han}·]{2,10})", options: []),
          let title = try? NSRegularExpression(pattern: "(牧师|传道人|传道|长老|执事|弟兄|姊妹|姐妹|师母|博士|老师|同工|教授|宣教士|主任|先生|女士)", options: []) else { return [] }
    let ns = text as NSString
    var out: [String] = []
    for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
        let s = ns.substring(with: m.range(at: 2))
        let sn = s as NSString
        var name = s
        if let t = title.firstMatch(in: s, options: [], range: NSRange(location: 0, length: sn.length)) {
            name = sn.substring(to: t.range.location)
        } else if s.count > 4 {
            continue      // 没有称呼又太长：多半连着后面的字，不可靠
        }
        if name.count >= 2 && name.count <= 4 && !out.contains(name) { out.append(name) }
    }
    return out
}

/// 今天 PDF 里出现的术语（照术语表）和名字 → 今日术语
func findPDFTerms(_ texts: [String], in sources: [GlossarySource]) -> (entries: [GlossaryEntry], termCount: Int, nameCount: Int) {
    let all = texts.joined(separator: "\n")
    var seen = Set<String>()
    var out: [GlossaryEntry] = []
    var terms = 0
    for src in sources {
        for e in src.entries where e.zh.count >= 2 && !seen.contains(e.zh) && all.contains(e.zh) {
            seen.insert(e.zh)
            out.append(e)
            terms += 1
        }
    }
    var names = 0
    for name in pdfSpeakerNames(all) where !seen.contains(name) {
        seen.insert(name)
        out.append(GlossaryEntry(zh: name, en: "", zhVariants: [], enVariants: [], direction: 0))
        names += 1
    }
    return (out, terms, names)
}

/// 文件夹里符合规则的最新文件
func newestFile(in folders: [URL], matching re: NSRegularExpression) -> (url: URL, mod: Date)? {
    var best: (url: URL, mod: Date)?
    for dir in folders {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: []) else { continue }
        for u in items {
            let name = u.lastPathComponent
            guard re.firstMatch(in: name, options: [], range: NSRange(location: 0, length: (name as NSString).length)) != nil else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            if let b = best, b.mod >= mod { continue }
            best = (url: u, mod: mod)
        }
    }
    return best
}

// MARK: - 字幕记录复查

struct TranscriptItem {
    var time = ""
    var language = "zh-CN"
    var target = "en-US"
    var raw = ""
    var fixed = ""
    var sent = ""
    var translated = ""
}

/// 读字幕记录（transcript-yyyymmdd.txt）
func parseTranscript(_ text: String) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    var cur: TranscriptItem?
    var lang = "zh-CN"
    var target = "en-US"
    let langRE = try? NSRegularExpression(pattern: "（(zh-CN|en-US)→([A-Za-z-]*)）", options: [])
    for line in text.components(separatedBy: .newlines) {
        if line.hasPrefix("=====") {
            if let c = cur { items.append(c) }
            cur = nil
            let ns = line as NSString
            if let re = langRE, let m = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) {
                lang = ns.substring(with: m.range(at: 1))
                target = ns.substring(with: m.range(at: 2))
            }
        } else if line.hasPrefix("[") && line.hasSuffix("]") && line.count <= 12 {
            if let c = cur { items.append(c) }
            var it = TranscriptItem()
            it.time = String(line.dropFirst().dropLast())
            it.language = lang
            it.target = target
            cur = it
        } else if var c = cur {
            if line.hasPrefix("原：") {
                c.raw = String(line.dropFirst(2))
            } else if line.hasPrefix("改：") {
                let body = line.dropFirst(2)
                c.fixed = String(body.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? body)
            } else if line.hasPrefix("送：") {
                c.sent = String(line.dropFirst(2))
            } else if line.hasPrefix("译：") {
                c.translated = String(line.dropFirst(2))
            }
            cur = c
        }
    }
    if let c = cur { items.append(c) }
    return items.filter { !$0.raw.isEmpty }
}

let pinyinSyllables: Set<String> = Set("""
ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang \
chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan \
dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo ei en eng er fa fan fang fei fen feng \
fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen \
heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan \
kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao \
lie lin ling liu long lou lu luan lue lun luo lv ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou \
mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv ou pa pai pan pang \
pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran \
rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei \
shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te teng \
ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing \
xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng \
zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan \
zui zun zuo ai an ang ao
""".split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

/// 像拼音拼出来的词（如 Yuehan、Wang），多半是没认出的中文名字
func isPinyinLike(_ word: String) -> Bool {
    let w = Array(word.lowercased())
    let n = w.count
    guard n >= 2, w.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return false }
    var ok = [Bool](repeating: false, count: n + 1)
    ok[0] = true
    for i in 0..<n where ok[i] {
        for len in 2...6 where i + len <= n {
            if pinyinSyllables.contains(String(w[i..<(i + len)])) { ok[i + len] = true }
        }
    }
    return ok[n]
}

func isEnglishWord(_ w: String) -> Bool {
    let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil)
    return r.location == NSNotFound
}

/// 英文句子里的人名、地名（NaturalLanguage 认出来的，加上像拼音的大写词）
func englishNameCandidates(_ text: String) -> [String] {
    var out: [String] = []
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let range = text.startIndex..<text.endIndex
    tagger.setLanguage(.english, range: range)
    let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
    tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: opts) { tag, r in
        if let tag = tag, tag == .personalName || tag == .placeName || tag == .organizationName {
            let s = String(text[r])
            if !out.contains(s) { out.append(s) }
        }
        return true
    }
    for w in text.split(whereSeparator: { !$0.isLetter }) {
        let word = String(w)
        guard let f = word.first, f.isUppercase, isPinyinLike(word), !isEnglishWord(word) else { continue }
        if !out.contains(where: { $0.contains(word) }) { out.append(word) }
    }
    return out
}

typealias ReviewTranslate = (String) async -> String?

// MARK: - 字幕数据（投影字幕条和 OBS 叠加共用）
//
// 每路字幕 = 已经定下来的文字（一段一段追加，不再改）+ 最后一段还会变的文字（tail）。
// 显示端只需要拿“上次之后新增的段落”和最新的 tail，已经显示好的行就不会重排。

/// 本机识别送出来的字幕变化
enum CaptionEvent {
    case committed(String)      // 一段原文定下来了
    case volatile(String)       // 正在说的原文（还会变）
    case translation(String)    // 一句译文
    case clear                  // 清空（开始识别、长时间没人说话）
}

final class CaptionStream {
    private(set) var chunks: [(id: Int, text: String)] = []
    private(set) var lastId = 0
    private(set) var tail = ""
    var hasCommitted: Bool { return !chunks.isEmpty }

    func append(_ s: String) {
        guard !s.isEmpty else { return }
        lastId += 1
        chunks.append((id: lastId, text: s))
        if chunks.count > 400 { chunks.removeFirst(chunks.count - 400) }
    }

    func setTail(_ s: String) { tail = s }

    func clear() {
        chunks = []
        tail = ""
    }

    /// since 之后新增的段落；since 太旧（或显示端刚打开）就给全部，r = true 表示显示端先清空
    func delta(since: Int) -> [String: Any] {
        let fresh = since <= 0 || since > lastId || (chunks.first.map { since < $0.id - 1 } ?? false)
        let add = fresh ? chunks.map { $0.text } : chunks.filter { $0.id > since }.map { $0.text }
        return ["r": fresh, "add": add, "t": tail, "id": lastId]
    }
}

final class CaptionFeed {
    private(set) var epoch = 1
    let a = CaptionStream()     // 原文（本机识别）
    let b = CaptionStream()     // 译文；Kaleo 的文字也放这里

    func reset() {
        epoch += 1
        a.clear()
        b.clear()
    }

    /// 给某个显示端的变化：它上次收到的是第 e 轮、a/b 各到第几段
    func delta(epoch e: Int, a sa: Int, b sb: Int, mode: String, visible: Bool) -> [String: Any] {
        let same = e == epoch
        return ["e": epoch, "m": mode, "v": visible,
                "a": a.delta(since: same ? sa : 0), "b": b.delta(since: same ? sb : 0)]
    }
}

/// Kaleo 网页给的是“最近约 400 字”的滑动窗口：接到已有文字后面，较早的部分定下来，最后约 40 字还可能改
final class SnapshotMerger {
    private var committed = ""
    private var tail = ""
    let keep = 40

    func reset() {
        committed = ""
        tail = ""
    }

    /// snap 应该接在已有文字的哪里：从最早可能的位置找起，第一个“一直对到末尾”的位置就是；
    /// 都对不到末尾（最后几个字被网页改过）就取对上最多字的位置；找不到返回 -1
    static func align(_ cs: [Character], _ ss: [Character]) -> Int {
        guard let s0 = ss.first else { return -1 }
        let k = min(8, ss.count)
        let lo = max(0, cs.count - ss.count - 20)
        var best = -1
        var bestL = 0
        var p = lo
        while p < cs.count {
            if cs[p] == s0 {
                var l = 0
                while p + l < cs.count && l < ss.count && cs[p + l] == ss[l] { l += 1 }
                if p + l == cs.count && (l >= min(k, cs.count) || l == ss.count) { return p }
                if l >= min(k, 6) && l > bestL {
                    bestL = l
                    best = p
                }
            }
            p += 1
        }
        return best
    }

    func merge(_ snap: String) -> (append: String, tail: String) {
        guard !snap.isEmpty else { return ("", tail) }
        let combined = committed + tail
        let merged: String
        if combined.isEmpty {
            merged = snap
        } else {
            let cs = Array(combined)
            let p = SnapshotMerger.align(cs, Array(snap))
            merged = p >= 0 ? String(cs[0..<p]) + snap : combined + " " + snap   // 接不上（网页重新载入等）：当作新的一段
        }
        var newTail = merged.hasPrefix(committed) ? String(merged.dropFirst(committed.count))
                                                  : String(merged.dropFirst(min(committed.count, merged.count)))
        var append = ""
        if newTail.count > keep {
            var cut = newTail.index(newTail.endIndex, offsetBy: -keep)
            if let sp = newTail[..<cut].lastIndex(of: " "), newTail.distance(from: sp, to: cut) < 20 {
                cut = newTail.index(after: sp)
            }
            append = String(newTail[..<cut])
            newTail = String(newTail[cut...])
        }
        committed += append
        if committed.count > 1200 { committed = String(committed.suffix(1200)) }
        tail = newTail
        return (append, newTail)
    }
}

/// 只在本机（127.0.0.1）提供字幕页的极简网页服务，给 OBS 的“浏览器”来源用
final class CaptionServer {
    let port: UInt16
    var handler: ((String, [String: String]) -> (status: Int, type: String, body: Data))?
    private(set) var state = "未启动"
    private var listener: NWListener?

    init(port: UInt16) {
        self.port = port
    }

    var url: String { return "http://127.0.0.1:\(port)/caption" }

    func start() {
        guard listener == nil else { return }
        guard let p = NWEndpoint.Port(rawValue: port) else {
            state = "⚠️ 端口不对：\(port)"
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        do {
            let l = try NWListener(using: params, on: p)
            l.stateUpdateHandler = { [weak self] st in
                guard let self = self else { return }
                switch st {
                case .ready:
                    self.state = "✅ \(self.url)"
                    writeLog("OBS 字幕页：\(self.url)")
                case .failed(let e):
                    self.state = "⚠️ 无法启动：\(e.localizedDescription)（端口 \(self.port) 可能被占用）"
                    writeLog("⚠️ OBS 字幕页无法启动：\(e.localizedDescription)")
                    self.listener?.cancel()
                    self.listener = nil
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: .main)
            listener = l
            state = "启动中…"
        } catch {
            state = "⚠️ 无法启动：\(error.localizedDescription)"
            writeLog("⚠️ OBS 字幕页无法启动：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                c.cancel()
                return
            }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buf.count > 65536 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let first = head.components(separatedBy: "\r\n").first ?? ""
        let parts = first.split(separator: " ")
        var path = "/"
        var query: [String: String] = [:]
        if parts.count >= 2, let comps = URLComponents(string: String(parts[1])) {
            path = comps.path
            for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        let r = handler?(path, query) ?? (status: 404, type: "text/plain; charset=utf-8", body: Data("not found".utf8))
        var header = "HTTP/1.1 \(r.status) " + (r.status == 200 ? "OK" : "Not Found") + "\r\n"
        header += "Content-Type: \(r.type)\r\nContent-Length: \(r.body.count)\r\nCache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - 本机实时字幕：Apple 语音识别 + Apple 翻译（需要 macOS 26，并用 Xcode 26 编译）

func languageName(_ id: String) -> String {
    if id.hasPrefix("zh") { return "普通话" }
    if id.hasPrefix("en") { return "英语" }
    return id
}

/// 本机识别的统一接口。具体实现只在 Xcode 26（Swift 6.2）编译、macOS 26 上运行时才有
protocol LiveRecognizer: AnyObject {
    var running: Bool { get }
    var retryAt: Date? { get }
    var statusText: String { get }
    var translationProblem: String? { get }
    var translationStats: String { get }
    var glossary: CaptionGlossary? { get set }
    var sentenceMode: Bool { get set }          // 整句翻译：一句说完再翻
    var sentenceMaxSeconds: Double { get set }  // 整句翻译最多等几秒
    var sentencePause: Double { get set }       // 停顿几秒算一句说完
    var highFidelity: Bool { get set }          // 高保真翻译（macOS 26.4，Apple Intelligence 可用时）
    var onUpdate: ((String, String) -> Void)? { get set }   // 原文、译文
    var onStatus: ((String) -> Void)? { get set }
    var onRecord: ((CaptionRecord) -> Void)? { get set }    // 每一句（写字幕记录）
    var onCaption: ((CaptionEvent) -> Void)? { get set }    // 字幕变化（滚动字幕用）
    var autoPunctuation: String { get set }     // 按停顿补标点：zh | all | off
    var pauseComma: Double { get set }          // 停顿几秒补逗号
    var pausePeriod: Double { get set }         // 停顿几秒补句号
    func start(language: String, target: String, device: String, channel: Int)
    func stop()
    func clearIfIdle(after seconds: TimeInterval)
    func inputNames() -> [String]
}

#if compiler(>=6.2)

struct LiveCaptionError: LocalizedError {
    let message: String
    var errorDescription: String? { return message }
}

/// 转换音频时，每段音频只交给转换器一次
final class OnceFlag {
    var used = false
}

/// 音频线程记下“安静”的时段（秒，从开始识别算起，和识别结果里的时间对得上），用来按停顿补标点。
/// 安静的标准随现场音量自动调整：取最近约半分钟音量的低处和高处的中间
final class PauseTracker {
    private let lock = NSLock()
    private var seconds: Double = 0
    private var silences: [(start: Double, end: Double)] = []
    private var quietSince: Double?
    private var levels: [Float] = []
    private var threshold: Float = -200

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        seconds = 0
        silences = []
        quietSince = nil
        levels = []
        threshold = -200
    }

    /// 音频线程：每一段送进识别器的声音
    func feed(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        let sr = buf.format.sampleRate
        guard n > 0, sr > 0 else { return }
        var sum: Double = 0
        if let f = buf.floatChannelData {
            let ch = f[0]
            for i in 0..<n {
                let v = Double(ch[i])
                sum += v * v
            }
        } else if let d = buf.int16ChannelData {
            let ch = d[0]
            for i in 0..<n {
                let v = Double(ch[i]) / 32768.0
                sum += v * v
            }
        }
        let rms = (sum / Double(n)).squareRoot()
        let db = Float(20 * log10(max(rms, 1e-7)))
        lock.lock()
        defer { lock.unlock() }
        let t0 = seconds
        seconds += Double(n) / sr
        levels.append(db)
        if levels.count > 400 { levels.removeFirst(levels.count - 400) }
        if levels.count >= 30 {
            let sorted = levels.sorted()
            let low = max(sorted[sorted.count / 10], -80)
            let high = sorted[sorted.count * 7 / 10]
            threshold = high - low >= 12 ? (low + high) / 2 : -200    // 音量高低差不多（一直在放音乐等）：不判断停顿
        }
        if db < threshold {
            if quietSince == nil { quietSince = t0 }
        } else if let q = quietSince {
            silences.append((start: q, end: t0))
            if silences.count > 400 { silences.removeFirst(silences.count - 400) }
            quietSince = nil
        }
    }

    /// 和 [from, to] 重叠的安静时段（正在安静的算到现在）
    func quiet(from: Double, to: Double) -> [(start: Double, end: Double)] {
        lock.lock()
        defer { lock.unlock() }
        var out = silences.filter { $0.end > from && $0.start < to }
        if let q = quietSince, q < to { out.append((start: q, end: seconds)) }
        return out
    }

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }
}

/// 建立 Apple 翻译会话（本机识别和字幕复查共用）
@available(macOS 26.0, *)
enum TranslatorFactory {
    static func translationID(_ id: String) -> String {
        if id.hasPrefix("zh") { return "zh-Hans" }
        if id.hasPrefix("en") { return "en" }
        return id
    }

    /// high = 高保真：macOS 26.4 起可用，Apple Intelligence 可用时用它的模型，否则自动用普通模型
    @MainActor
    static func make(source: String, target: String, high: Bool) async -> (session: TranslationSession?, problem: String?) {
        let src = Locale.Language(identifier: translationID(source))
        let dst = Locale.Language(identifier: translationID(target))
        let status = await LanguageAvailability().status(from: src, to: dst)
        switch status {
        case .installed:
            #if compiler(>=6.3)
            if high {
                if #available(macOS 26.4, *) {
                    return (TranslationSession(installedSource: src, target: dst, preferredStrategy: .highFidelity), nil)
                }
            }
            #endif
            return (TranslationSession(installedSource: src, target: dst), nil)
        case .supported:
            return (nil, "翻译语言还没下载：系统设置 › 通用 › 语言与地区 › 翻译语言，下载中文（普通话）和英语")
        case .unsupported:
            return (nil, "不支持\(languageName(source))到\(languageName(target))的翻译")
        @unknown default:
            return (nil, "无法确定翻译语言的状态")
        }
    }
}

@available(macOS 26.0, *)
final class LiveCaptionEngine: LiveRecognizer {
    private(set) var running = false
    private(set) var retryAt: Date?
    private(set) var statusText = "未启动"
    private(set) var translationProblem: String?
    private(set) var translationStats = ""
    var glossary: CaptionGlossary?
    var sentenceMode = true
    var sentenceMaxSeconds: Double = 7
    var sentencePause: Double = 1.2
    var highFidelity = true {
        didSet {
            guard highFidelity != oldValue, running, !target.isEmpty else { return }
            Task { @MainActor in await self.setUpTranslator() }
        }
    }
    var onUpdate: ((String, String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onRecord: ((CaptionRecord) -> Void)?
    var onCaption: ((CaptionEvent) -> Void)?
    var autoPunctuation = "zh"
    var pauseComma: Double = 0.3
    var pausePeriod: Double = 0.8

    private let pauses = PauseTracker()
    private var lastFinalEnd: Double = -1       // 上一段原文最后一个词结束的时间（秒）
    private var lastFinalText = ""
    private var timingLogged = false

    /// 等着翻译的一句
    private struct PendingUnit {
        let time: Date
        let raw: String
        let fixed: String
        let fixes: [CaptionFix]
        let sent: String
    }

    private var buffer: [String] = []           // 整句翻译：还没送去翻译的识别段落（原文）
    private var bufferStart = Date()
    private var lastFinal = Date()
    private var flushScheduled = false
    private var pendingUnits: [PendingUnit] = []
    private var durations: [Double] = []
    private var translatedCount = 0

    private var generation = 0
    private var language = "zh-CN"
    private var target = ""
    private var startTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var translator: TranslationSession?
    private var configObserver: NSObjectProtocol?
    private var analyzerFormat: AVAudioFormat?
    private var channel = 0
    private var audioRestarts: [Date] = []

    private var finals: [String] = []
    private var translations: [String] = []
    private var volatileText = ""
    private var translating = false
    private var lastActivity = Date()

    func start(language: String, target: String, device: String, channel: Int) {
        stop()
        generation += 1
        let gen = generation
        self.language = language
        self.target = target
        self.channel = channel
        audioRestarts = []
        running = true
        retryAt = nil
        translationProblem = nil
        finals = []
        translations = []
        volatileText = ""
        lastActivity = Date()
        lastFinalEnd = -1
        lastFinalText = ""
        timingLogged = false
        onCaption?(.clear)
        publish()
        setStatus("启动中…")
        startTask = Task { @MainActor in
            do {
                try await self.run(gen: gen, device: device, channel: channel)
            } catch {
                self.fail(error.localizedDescription, gen: gen, retryAfter: 30)
            }
        }
    }

    func stop() {
        flushOnStop()
        generation += 1
        let wasRunning = running
        running = false
        flushScheduled = false
        startTask?.cancel()
        startTask = nil
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        analyzerFormat = nil
        continuation?.finish()
        continuation = nil
        if let a = analyzer {
            Task { await a.cancelAndFinishNow() }
        }
        analyzer = nil
        translator = nil
        translating = false
        if wasRunning { setStatus("已停止") }
    }

    /// 停止时：还没翻译的句子也记进字幕记录
    private func flushOnStop() {
        if !buffer.isEmpty {
            let raw = Self.join(buffer, zh: language.hasPrefix("zh"))
            let c = glossary?.correct(raw, language: language) ?? (text: raw, fixes: [CaptionFix]())
            onRecord?(CaptionRecord(time: bufferStart, language: language, raw: raw, fixed: c.text, fixes: c.fixes,
                                    sent: "", translated: "", seconds: 0))
            buffer = []
        }
        for u in pendingUnits { record(u, translated: "", seconds: 0) }
        pendingUnits = []
    }

    private func fail(_ message: String, gen: Int, retryAfter: TimeInterval) {
        guard gen == generation else { return }
        stop()
        retryAt = Date().addingTimeInterval(retryAfter)
        setStatus("⚠️ \(message)")
    }

    func inputNames() -> [String] {
        return Self.inputDevices().map { $0.name }
    }

    func clearIfIdle(after seconds: TimeInterval) {
        guard seconds > 0, running else { return }
        let hasText = !finals.isEmpty || !translations.isEmpty || !volatileText.isEmpty
        if hasText && Date().timeIntervalSince(lastActivity) > seconds {
            finals = []
            translations = []
            volatileText = ""
            lastFinalText = ""
            onCaption?(.clear)
            publish()
        }
    }

    @MainActor
    private func run(gen: Int, device: String, channel: Int) async throws {
        // 1. 权限（第一次会弹出询问）
        guard await Self.requestMicrophone() else {
            throw LiveCaptionError(message: "没有麦克风权限：系统设置 › 隐私与安全性 › 麦克风，打开 Presenter")
        }
        if !(await Self.requestSpeechAuthorization()) {
            writeLog("⚠️ 本机识别：没有“语音识别”权限，可能无法识别（系统设置 › 隐私与安全性 › 语音识别）")
        }
        guard gen == generation else { return }

        // 2. 识别模型
        guard SpeechTranscriber.isAvailable else {
            throw LiveCaptionError(message: "这台 Mac 不支持本机语音识别")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw LiveCaptionError(message: "本机识别不支持\(languageName(language))")
        }
        // 带每个词的时间（按停顿补标点用）
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            if !isInstalled { setStatus("正在下载\(languageName(language))识别模型…（第一次需要几分钟）") }
            try await request.downloadAndInstall()
        }
        guard gen == generation else { return }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveCaptionError(message: "识别模型没有可用的音频格式")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        guard gen == generation else {
            cont.finish()
            await analyzer.cancelAndFinishNow()
            return
        }
        self.analyzer = analyzer
        self.continuation = cont
        self.analyzerFormat = format

        // 3. 翻译
        await setUpTranslator()
        guard gen == generation else { return }

        // 4. 音频输入
        pauses.reset()
        let engine = AVAudioEngine()
        let picked = Self.selectInput(engine: engine, wanted: device)
        try startAudio(engine)
        self.engine = engine
        // 切换输入设备、刚启动时，系统常会发“音频设置有变化”的通知：引擎还在运行就不管，停了就原地重新接上
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.audioConfigChanged(gen: gen)
            }
        }

        var st = "✅ 正在识别\(languageName(language))"
        if !target.isEmpty { st += "，翻成\(languageName(target))" }
        st += "（\(picked.name)）"
        if !picked.ok { st = "⚠️ 找不到“\(device)”，" + st }
        if let p = translationProblem { st += "；⚠️ \(p)" }
        setStatus(st)

        // 5. 结果
        for try await result in transcriber.results {
            if gen != generation { return }
            if result.isFinal {
                handle(punctuated(result.text), isFinal: true)
            } else {
                handle(String(result.text.characters), isFinal: false)
            }
        }
        if gen == generation {
            throw LiveCaptionError(message: "识别意外结束，稍后自动重新开始")
        }
    }

    /// 装上音频“水龙头”并启动引擎（按当前的输入格式）
    private func startAudio(_ e: AVAudioEngine) throws {
        guard let format = analyzerFormat, let cont = continuation else {
            throw LiveCaptionError(message: "识别器还没准备好")
        }
        e.inputNode.removeTap(onBus: 0)
        let inFormat = e.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw LiveCaptionError(message: "音频输入不可用")
        }
        guard let converter = AVAudioConverter(from: inFormat, to: format) else {
            throw LiveCaptionError(message: "无法转换音频格式")
        }
        Self.configure(converter, channel: channel, inputChannels: inFormat.channelCount)
        e.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat,
                               block: Self.makeTap(converter: converter, format: format, continuation: cont, pauses: pauses))
        e.prepare()
        try e.start()
    }

    private func audioConfigChanged(gen: Int) {
        guard gen == generation, let e = engine else { return }
        if e.isRunning {
            writeLog("本机识别：音频设置有变化，引擎仍在运行，继续")
            return
        }
        let now = Date()
        audioRestarts = audioRestarts.filter { now.timeIntervalSince($0) < 30 }
        if audioRestarts.count >= 3 {
            fail("音频设备一直在变化，30 秒后重新开始", gen: gen, retryAfter: 30)
            return
        }
        audioRestarts.append(now)
        do {
            try startAudio(e)
            writeLog("本机识别：音频设置有变化，已重新接上音频")
        } catch {
            fail("音频设备有变化：\(error.localizedDescription)", gen: gen, retryAfter: 5)
        }
    }

    private func handle(_ text: String, isFinal: Bool) {
        lastActivity = Date()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            volatileText = ""
            if !t.isEmpty {
                let shown = glossary?.correct(t, language: language).text ?? t
                onCaption?(.committed(shown))
                finals.append(shown)
                if finals.count > 30 { finals.removeFirst(finals.count - 30) }
                if buffer.isEmpty { bufferStart = Date() }
                buffer.append(t)
                lastFinal = Date()
                checkFlush()
            }
        } else {
            // 还在变的文字：只按术语表改（读音纠正等这一段定下来再做）
            volatileText = glossary?.correct(t, language: language, fuzzyOK: false).text ?? t
        }
        onCaption?(.volatile(volatileText))
        publish()
    }

    /// 按停顿补标点：识别结果里有每个词的时间，再对照音频里安静的时段，
    /// 词与词之间停顿超过 pauseComma 秒补逗号，超过 pausePeriod 秒补句号（英文 , .）。已有标点的地方不补
    private func punctuated(_ text: AttributedString) -> String {
        let plain = String(text.characters)
        let zh = language.hasPrefix("zh")
        guard autoPunctuation == "all" || (autoPunctuation == "zh" && zh) else { return plain }
        var pieces: [(s: String, a: Double, b: Double)] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let r = run.audioTimeRange {
                pieces.append((s: piece, a: r.start.seconds, b: r.end.seconds))
            } else if pieces.isEmpty {
                pieces.append((s: piece, a: -1, b: -1))
            } else {
                pieces[pieces.count - 1].s += piece
            }
        }
        let comma = zh ? "，" : ","
        let period = zh ? "。" : "."
        let timedIdx = pieces.indices.filter { pieces[$0].a >= 0 && pieces[$0].b >= pieces[$0].a }
        guard let fi = timedIdx.first, let li = timedIdx.last else {
            // 没有时间信息：只在两段之间补逗号
            if !timingLogged {
                timingLogged = true
                writeLog("本机识别：识别结果没有词的时间，只在每段之间补逗号")
            }
            var out = plain
            if zh && !lastFinalText.isEmpty && !Self.endsWithPunct(lastFinalText) && !Self.startsWithPunct(plain) {
                out = comma + plain
            }
            lastFinalText = out
            return out
        }
        if !timingLogged {
            timingLogged = true
            writeLog(String(format: "本机识别：按停顿补标点（这段的词在 %.1f–%.1f 秒，音频已到 %.1f 秒）",
                            pieces[fi].a, pieces[li].b, pauses.now))
        }
        // 可以补标点的位置：-1 = 这段开头（和上一段之间），i = 第 i 个词后面；值 = (时间, 停顿秒数)
        var bounds: [Int: (t: Double, p: Double)] = [:]
        let first = pieces[fi]
        if lastFinalEnd >= 0, !lastFinalText.isEmpty, !Self.endsWithPunct(lastFinalText), !Self.startsWithPunct(plain) {
            bounds[-1] = (t: (lastFinalEnd + first.a) / 2, p: max(0, first.a - lastFinalEnd))
        }
        for j in 0..<max(0, timedIdx.count - 1) {
            let i = timedIdx[j]
            let k = timedIdx[j + 1]
            guard k == i + 1 else { continue }
            bounds[i] = (t: (pieces[i].b + pieces[k].a) / 2, p: max(0, pieces[k].a - pieces[i].b))
        }
        // 每段安静的时间算给离它最近的那个位置（停顿常被算进前一个或后一个词的时长里）
        if !bounds.isEmpty {
            for q in pauses.quiet(from: first.a - 3, to: pieces[li].b) {
                let d = q.end - q.start
                guard d >= pauseComma else { continue }
                var best: Int?
                var bestDist = Double.greatestFiniteMagnitude
                for (key, v) in bounds {
                    let dist = (v.t >= q.start - 0.05 && v.t <= q.end + 0.05) ? 0 : min(abs(v.t - q.start), abs(v.t - q.end))
                    if dist < bestDist {
                        bestDist = dist
                        best = key
                    }
                }
                if let key = best, bestDist <= 0.25, let v = bounds[key] {
                    bounds[key] = (t: v.t, p: max(v.p, d))
                }
            }
        }
        let commaAt = pauseComma
        let periodAt = pausePeriod
        func mark(_ p: Double) -> String {
            return p >= periodAt ? period : (p >= commaAt ? comma : "")
        }
        var out = ""
        if let v = bounds[-1] {
            let m = mark(v.p)
            out += m
            if !zh && !m.isEmpty && !(plain.first?.isWhitespace ?? false) { out += " " }
        }
        for i in pieces.indices {
            out += pieces[i].s
            guard let v = bounds[i], i + 1 < pieces.count, !Self.endsWithPunct(out),
                  !Self.startsWithPunct(pieces[i + 1].s) else { continue }
            let m = mark(v.p)
            if m.isEmpty { continue }
            // 英文：标点紧跟单词，放在空格前面
            let trimmed = out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let spaces = String(out.dropFirst(trimmed.count))
            out = trimmed + m + spaces
        }
        lastFinalEnd = pieces[li].b
        lastFinalText = out
        return out
    }

    /// 整句翻译：一句说完（句号、问号…）、停顿、或等太久，就把攒着的几段一起送去翻译。不是整句模式就每段马上送
    private func checkFlush() {
        guard !buffer.isEmpty else { return }
        let joined = Self.join(buffer, zh: language.hasPrefix("zh"))
        let now = Date()
        let paused = volatileText.isEmpty && now.timeIntervalSince(lastFinal) >= sentencePause
        let tooLong = now.timeIntervalSince(bufferStart) >= sentenceMaxSeconds
        if !sentenceMode || Self.endsSentence(joined) || paused {
            flushBuffer()
            return
        }
        if tooLong {
            // 太长还没有句号：在最后一个逗号处断开，前面送去翻译，后面留着接下一段
            if let cut = Self.clauseBreak(joined) {
                let rest = String(joined.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
                buffer = [String(joined.prefix(cut))]
                flushBuffer()
                if !rest.isEmpty {
                    buffer = [rest]
                    bufferStart = Date()
                }
            } else {
                flushBuffer()
            }
            return
        }
        if !flushScheduled {
            flushScheduled = true
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.flushScheduled = false
                self.checkFlush()
            }
        }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        var raw = Self.join(buffer, zh: language.hasPrefix("zh"))
        let time = bufferStart
        buffer = []
        // 段首补的标点（属于上一句的结尾）不送去翻译
        while let f = raw.first, Self.punctuationChars.contains(f) || f == " " { raw.removeFirst() }
        guard !raw.isEmpty else { return }
        let c = glossary?.correct(raw, language: language) ?? (text: raw, fixes: [CaptionFix]())
        guard translator != nil else {
            onRecord?(CaptionRecord(time: time, language: language, raw: raw, fixed: c.text, fixes: c.fixes,
                                    sent: "", translated: "", seconds: 0))
            return
        }
        let sent = glossary?.prepareForTranslation(c.text, language: language) ?? c.text
        pendingUnits.append(PendingUnit(time: time, raw: raw, fixed: c.text, fixes: c.fixes, sent: sent))
        while pendingUnits.count > 6 {
            writeLog("⚠️ 本机翻译跟不上，跳过一句")
            record(pendingUnits.removeFirst(), translated: "", seconds: 0)
        }
        if !translating { pumpTranslations() }
    }

    private func record(_ u: PendingUnit, translated: String, seconds: Double) {
        onRecord?(CaptionRecord(time: u.time, language: language, raw: u.raw, fixed: u.fixed, fixes: u.fixes,
                                sent: u.sent, translated: translated, seconds: seconds))
    }

    @MainActor
    private func setUpTranslator() async {
        guard !target.isEmpty else {
            translator = nil
            translationProblem = nil
            return
        }
        let r = await TranslatorFactory.make(source: language, target: target, high: highFidelity)
        translator = r.session
        translationProblem = r.problem
        if let p = r.problem {
            writeLog("⚠️ 本机翻译：\(p)")
        } else {
            writeLog("本机翻译：\(languageName(language)) → \(languageName(target))，" + (highFidelity ? "高保真（Apple Intelligence 可用时用它）" : "快速"))
        }
        if !pendingUnits.isEmpty && !translating { pumpTranslations() }
    }

    private func pumpTranslations() {
        guard let tr = translator, !pendingUnits.isEmpty else {
            translating = false
            return
        }
        translating = true
        let unit = pendingUnits.removeFirst()
        let gen = generation
        Task { @MainActor in
            let t0 = Date()
            var out = ""
            do {
                out = try await tr.translate(unit.sent).targetText
            } catch {
                if self.translationProblem == nil {
                    self.translationProblem = "翻译出错：\(error.localizedDescription)"
                    writeLog("⚠️ 本机翻译出错：\(error.localizedDescription)")
                }
            }
            let secs = Date().timeIntervalSince(t0)
            let t = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.record(unit, translated: t, seconds: secs)
            guard gen == self.generation else { return }
            if !t.isEmpty {
                self.noteDuration(secs)
                self.onCaption?(.translation(t))
                self.translations.append(t)
                if self.translations.count > 30 { self.translations.removeFirst(self.translations.count - 30) }
                self.publish()
            }
            self.pumpTranslations()
        }
    }

    private func noteDuration(_ s: Double) {
        durations.append(s)
        if durations.count > 20 { durations.removeFirst(durations.count - 20) }
        let avg = durations.reduce(0, +) / Double(durations.count)
        translationStats = String(format: "翻译平均 %.2f 秒/句（最近 %ld 句）", avg, durations.count)
        translatedCount += 1
        if translatedCount % 25 == 0 { writeLog("本机翻译：\(translationStats)") }
    }

    private func publish() {
        var parts = finals
        if !volatileText.isEmpty { parts.append(volatileText) }
        let original = Self.tail(parts, zh: language.hasPrefix("zh"), max: 240)
        let translated = Self.tail(translations, zh: target.hasPrefix("zh"), max: 400)
        onUpdate?(original, translated)
    }

    private func setStatus(_ s: String) {
        statusText = s
        onStatus?(s)
    }

    // MARK: 工具

    /// 最后几段文字（中文不加空格，英文用空格连接）
    static func tail(_ parts: [String], zh: Bool, max: Int) -> String {
        var picked: [String] = []
        var n = 0
        for p in parts.reversed() {
            picked.insert(p, at: 0)
            n += p.count
            if n >= max { break }
        }
        let s = picked.joined(separator: zh ? "" : " ")
        return s.count > max ? String(s.suffix(max)) : s
    }

    static func join(_ parts: [String], zh: Bool) -> String {
        return parts.joined(separator: zh ? "" : " ")
    }

    static let punctuationChars: Set<Character> = Set("，。！？、；：,.!?;:…—”’）)》」』")

    static func endsWithPunct(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespaces).last else { return true }
        return punctuationChars.contains(c)
    }

    static func startsWithPunct(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespaces).first else { return true }
        return punctuationChars.contains(c)
    }

    /// 最后一个逗号（分号、冒号）后面的位置；逗号太靠前（前 30%）不算
    static func clauseBreak(_ s: String) -> Int? {
        let chars = Array(s)
        var i = chars.count - 1
        while i > 0 {
            if "，,；;：:".contains(chars[i]) {
                return Double(i) >= Double(chars.count) * 0.3 && i + 1 < chars.count ? i + 1 : nil
            }
            i -= 1
        }
        return nil
    }

    /// 以句号、问号、感叹号等结尾（后面的引号、括号不算）
    static func endsSentence(_ s: String) -> Bool {
        var t = Substring(s)
        while let last = t.last, "”’」』)）\"' ".contains(last) { t = t.dropLast() }
        guard let c = t.last else { return false }
        return "。！？!?；;….".contains(c)
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func requestSpeechAuthorization() async -> Bool {
        let s = SFSpeechRecognizer.authorizationStatus()
        if s == .authorized { return true }
        if s == .denied || s == .restricted { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// 所有有输入声道的音频设备
    static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [(id: AudioDeviceID, name: String)] = []
        for id in ids where inputChannelCount(id) > 0 {
            out.append((id: id, name: deviceName(id) ?? "音频设备 \(id)"))
        }
        return out
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var n = 0
        for b in list { n += Int(b.mNumberChannels) }
        return n
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// 按名字选音频输入（包含即可）；找不到就用系统默认输入
    static func selectInput(engine: AVAudioEngine, wanted: String) -> (name: String, ok: Bool) {
        let w = wanted.trimmingCharacters(in: .whitespaces)
        if w.isEmpty { return (name: "系统默认输入", ok: true) }
        let devices = inputDevices()
        guard let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(w) }) else {
            writeLog("⚠️ 找不到音频输入“\(w)”，改用系统默认输入。现有输入：" + devices.map { $0.name }.joined(separator: "、"))
            return (name: "系统默认输入", ok: false)
        }
        if let def = defaultInputDevice(), def == d.id {
            return (name: d.name, ok: true)   // 已经是系统默认输入，不用切换
        }
        guard let au = engine.inputNode.audioUnit else { return (name: "系统默认输入", ok: false) }
        var id = d.id
        let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            writeLog("⚠️ 设置音频输入“\(d.name)”失败（\(status)），改用系统默认输入")
            return (name: "系统默认输入", ok: false)
        }
        return (name: d.name, ok: true)
    }

    /// 多声道 → 单声道：channel = 0 混合所有声道；1、2… 只用第几个输入
    static func configure(_ converter: AVAudioConverter, channel: Int, inputChannels: AVAudioChannelCount) {
        guard converter.outputFormat.channelCount == 1, inputChannels > 1 else { return }
        if channel >= 1 && channel <= Int(inputChannels) {
            converter.channelMap = [NSNumber(value: channel - 1)]
        } else {
            converter.downmix = true
        }
    }

    /// 音频线程里：把每段声音转换成识别模型要的格式，送进识别器
    static func makeTap(converter: AVAudioConverter, format: AVAudioFormat,
                        continuation: AsyncStream<AnalyzerInput>.Continuation, pauses: PauseTracker) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            let flag = OnceFlag()
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if flag.used {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                flag.used = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || out.frameLength == 0 { return }
            pauses.feed(out)
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }
}

#endif


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
    let captionFeed = CaptionFeed()             // 滚动字幕的文字（投影和 OBS 共用）
    let kaleoMerger = SnapshotMerger()
    var projectorSent = (e: 0, a: 0, b: 0)      // 投影字幕条已经收到的进度
    var captionPushPending = false
    var captionServer: CaptionServer?
    var obsLastPoll: Date?
    var sourceRequested = false
    var sourceState = "未载入"
    var sourceRetryAt: Date?
    var sourceOnTop = false
    var captionText = ""
    var captionTextAt: Date?
    var captionPath: String?
    var captionActivity = Date()
    var captionSource = "kaleo"         // kaleo | apple
    var captionSourceArg: String?       // --apple / --kaleo
    var inputArg: String?               // --input "设备名"（"" = 系统默认输入）
    var channelArg: Int?                // --channel 0/1/2
    var langArg: String?                // --lang zh / en
    var recognizer: LiveRecognizer?
    var appleLanguage = "zh-CN"
    var appleDisplay = "both"
    var appleOriginal = ""
    var appleTranslation = ""
    var appleStatus = "未启动"

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

    // Google Drive
    let gdriveQueue = DispatchQueue(label: "local.presenter.gdrive")
    var noGDrive = false
    var gdriveExe: URL?
    var gdriveReady = false
    var gdriveSetupProblem: String?
    var gdriveBusyKeys = Set<String>()
    var gdrivePending: (keys: Set<String>, force: Bool, reason: String, announce: Bool)?
    var gdriveStatus: [String: String] = [:]
    var gdriveRecords: [String: GDriveRecord] = [:]
    var gdriveWaitUntil: [String: Date] = [:]
    var gdriveRechecked = Set<Int>()
    var termsFetchBusy = false

    // 术语表 / 整句翻译 / 字幕记录
    var glossary: CaptionGlossary?
    var glossaryStamp = ""
    var glossaryLoaded = false
    var glossaryInfo = "术语表：未载入"
    var glossaryProblems: [String] = []
    var termsRule: NSRegularExpression?
    let textQueue = DispatchQueue(label: "local.presenter.pdftext")
    var pdfTexts: [String: (url: URL, mod: Date?, text: String)] = [:]
    var pdfTextBusy = Set<String>()
    var sentenceMode = true
    var highFidelity = true
    var transcriptHeaderPending = false
    var reviewMode = false              // --review：只复查字幕记录，然后退出
    var reviewArg: String?
    var reviewBusy = false

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
        if reviewMode {
            startReviewMode()
            return
        }
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
        captionSource = captionSourceArg ?? cfg.caption.source
        if let v = inputArg { cfg.caption.apple.inputDevice = v.trimmingCharacters(in: .whitespaces) }
        if let v = channelArg { cfg.caption.apple.channel = v }
        if let v = langArg { cfg.caption.apple.language = v }
        appleLanguage = cfg.caption.apple.language
        appleDisplay = cfg.caption.apple.display
        sentenceMode = cfg.caption.apple.sentenceMode
        highFidelity = cfg.caption.apple.translationQuality != "fast"
        setupRecognizer()
        if captionSource == "apple" && recognizer == nil {
            problems.append("本机识别需要 macOS 26，并用 Xcode 26 编译；字幕来源已改用 Kaleo")
            captionSource = "kaleo"
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
        setupGDrive()
        if gdriveReady && !lateLaunch {
            let lead = cfg.gdrive.recheckBeforeMinutes * 60 + 60
            for (j, e) in timeline.enumerated() where isPDFShow(e.show) && e.at.timeIntervalSince(appNow()) <= lead {
                gdriveRechecked.insert(j)
            }
            startGDriveFetch(pdfKeys(), force: false, reason: "启动时下载今天的 PDF", announce: true)
            startTermsFetch()
        }
        startCaptionServer()
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
        recognizer?.stop()
        captionServer?.stop()
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
            case "--input":
                inputArg = value() ?? ""
            case "--channel":
                if let v = value(), let n = Int(v), n >= 0 { channelArg = n }
            case "--lang":
                if let v = value() { langArg = v.lowercased().hasPrefix("en") ? "en-US" : "zh-CN" }
            case "--review":
                reviewMode = true
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { reviewArg = value() }
            case "--apple":
                captionSourceArg = "apple"
            case "--kaleo":
                captionSourceArg = "kaleo"
            case "--caption":
                captionForced = true
            case "--nogdrive":
                noGDrive = true
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
        if let names = obj["pdfNames"] as? [String: Any] {
            for (k, v) in names where !k.hasPrefix("_") {
                if let n = v as? String { pdfDisplayNames[k] = n.trimmingCharacters(in: .whitespaces) }
            }
        }
        if let e = obj["extend"] as? [String: Any] {
            if let v = e["minutes"] as? Double, v > 0 { cfg.extendMinutes = v }
            if let v = e["warnSeconds"] as? Double, v >= 0 { cfg.warnSeconds = v }
            if let v = e["warnFor"] as? [String] { cfg.warnFor = v }
        }
        if let g = obj["gdrive"] as? [String: Any] {
            if let v = g["enabled"] as? Bool { cfg.gdrive.enabled = v }
            if let v = g["rclone"] as? String { cfg.gdrive.rclone = v.trimmingCharacters(in: .whitespaces) }
            if let v = g["remote"] as? String, !v.isEmpty {
                cfg.gdrive.remote = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            }
            if let v = g["folderId"] as? String { cfg.gdrive.folderId = v.trimmingCharacters(in: .whitespaces) }
            if let v = g["recheckBeforeMinutes"] as? Double, v >= 0 { cfg.gdrive.recheckBeforeMinutes = v }
            if let v = g["waitSeconds"] as? Double, v >= 0 { cfg.gdrive.waitSeconds = v }
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
            if let v = c["source"] as? String, v == "kaleo" || v == "apple" { cfg.caption.source = v }
            if let a = c["apple"] as? [String: Any] {
                if let v = a["language"] as? String { cfg.caption.apple.language = v.lowercased().hasPrefix("en") ? "en-US" : "zh-CN" }
                if let v = a["translateTo"] as? String { cfg.caption.apple.translateTo = v.trimmingCharacters(in: .whitespaces) }
                if let v = a["inputDevice"] as? String { cfg.caption.apple.inputDevice = v.trimmingCharacters(in: .whitespaces) }
                if let v = a["channel"] as? Int, v >= 0, v <= 16 { cfg.caption.apple.channel = v }
                if let v = a["display"] as? String, ["both", "translation", "original"].contains(v) { cfg.caption.apple.display = v }
                if let v = a["clearAfterSeconds"] as? Double, v >= 0 { cfg.caption.apple.clearAfterSeconds = v }
                if let v = a["sentenceMode"] as? Bool { cfg.caption.apple.sentenceMode = v }
                if let v = a["sentenceMaxSeconds"] as? Double, v >= 1, v <= 30 { cfg.caption.apple.sentenceMaxSeconds = v }
                if let v = a["sentencePauseSeconds"] as? Double, v >= 0.3, v <= 10 { cfg.caption.apple.sentencePauseSeconds = v }
                if let v = a["translationQuality"] as? String { cfg.caption.apple.translationQuality = v.lowercased() == "fast" ? "fast" : "high" }
                if let v = a["saveTranscript"] as? Bool { cfg.caption.apple.saveTranscript = v }
                if let v = a["autoPunctuation"] as? String, ["zh", "all", "off"].contains(v) { cfg.caption.apple.autoPunctuation = v }
                if let v = a["pauseComma"] as? Double, v >= 0.1, v <= 3 { cfg.caption.apple.pauseComma = v }
                if let v = a["pausePeriod"] as? Double, v >= 0.2, v <= 5 { cfg.caption.apple.pausePeriod = v }
            }
            if let v = c["marginPercent"] as? Double, v >= 0, v <= 30 { cfg.caption.marginPercent = v }
            if let v = c["textSelector"] as? String { cfg.caption.textSelector = v.trimmingCharacters(in: .whitespaces) }
            if let v = c["color"] as? String, !v.isEmpty { cfg.caption.color = v }
            if let v = c["background"] as? String, !v.isEmpty { cfg.caption.background = v }
            if let v = c["overlay"] as? Bool { cfg.caption.overlay = v }
            if let v = c["pageZoom"] as? Double, v > 0 { cfg.caption.pageZoom = v }
            if let v = c["reloadIfStaleMinutes"] as? Double, v >= 0 { cfg.caption.reloadIfStaleMinutes = v }
        }
        if let o = obj["obs"] as? [String: Any] {
            if let v = o["enabled"] as? Bool { cfg.obs.enabled = v }
            if let v = o["port"] as? Int, v >= 1024, v <= 65535 { cfg.obs.port = v }
            if let v = o["visibility"] as? String, v == "same" || v == "auto" { cfg.obs.visibility = v }
            if let v = o["lines"] as? Int, v >= 1, v <= 6 { cfg.obs.lines = v }
            if let v = o["heightPercent"] as? Double, v >= 5, v <= 50 { cfg.obs.heightPercent = v }
            if let v = o["bottomPercent"] as? Double, v >= 0, v <= 50 { cfg.obs.bottomPercent = v }
            if let v = o["marginPercent"] as? Double, v >= 0, v <= 30 { cfg.obs.marginPercent = v }
            if let v = o["background"] as? String, !v.isEmpty { cfg.obs.background = v }
            if let v = o["color"] as? String, !v.isEmpty { cfg.obs.color = v }
        }
        if let g = obj["glossary"] as? [String: Any] {
            if let v = g["enabled"] as? Bool { cfg.glossary.enabled = v }
            if let v = g["files"] as? [String] {
                cfg.glossary.files = v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if let v = g["beforeTranslation"] as? Bool { cfg.glossary.beforeTranslation = v }
            if let v = g["fuzzy"] as? String, ["today", "all", "off"].contains(v) { cfg.glossary.fuzzy = v }
            if let v = g["fuzzyMinLength"] as? Int, v >= 2, v <= 8 { cfg.glossary.fuzzyMinLength = v }
            if let v = g["pdfTerms"] as? Bool { cfg.glossary.pdfTerms = v }
            if let v = g["termsFile"] as? String, !v.isEmpty { cfg.glossary.termsFile = v }
            if let v = g["fromGoogleDrive"] as? Bool { cfg.glossary.fromGoogleDrive = v }
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
        termsRule = nil
        if cfg.glossary.enabled {
            let p = cfg.glossary.termsFile.replacingOccurrences(of: "{date}", with: date)
            termsRule = try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
            if termsRule == nil { problems.append("glossary.termsFile 不是有效的正则表达式：\(cfg.glossary.termsFile)") }
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

        let pageOnTop = captionVisible && captionMode == "page" && captionSource == "kaleo"
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
        captionView.isHidden = !(captionVisible && !pageOnTop)
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
            projectorSent = (e: 0, a: 0, b: 0)
            applyCaptionStyle()
            refreshCaptionDisplay()
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
        if sourceRequested && captionSource == "kaleo" { loadSource("系统唤醒后重新载入") }
        if let r = recognizer, r.running, captionSource == "apple" { startRecognizer("系统唤醒后重新开始") }
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
        if case .pdf(let key) = currentScene, pdfShownKey == nil, tickCount % 40 == 0, !waitingForDownload(key) {
            if showPDF(key) { writeLog("\(pdfName(key))：文件已找到，开始显示") }
        }

        if tickCount % 20 == 0 {
            gdriveTick(now)
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
            if gdriveBusyKeys.contains(key) && cfg.gdrive.waitSeconds > 0 {
                // 正在从 Google Drive 下载最新版：先显示前一个画面，下载完马上显示（最多等 waitSeconds 秒）
                gdriveWaitUntil[key] = appNow().addingTimeInterval(cfg.gdrive.waitSeconds)
                writeLog("\(pdfName(key))：正在从 Google Drive 下载，最多等 \(Int(cfg.gdrive.waitSeconds)) 秒")
                showFallback(forIndex: index)
            } else if !showPDF(key, restore: manual != nil) {
                writeLog("⚠️ \(pdfName(key))：找不到或打不开 PDF，先显示前一个画面，每 2 秒重试")
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
        var lines = ["⏰ \(Int(ceil(left))) 秒后（\(hms(end))）关闭\(pdfName(key))，\(action)"]
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
        let tr = termsRule
        let base = baseDir
        let files = glossaryFileURLs()
        // 在后台线程读文件夹：第一次读“下载”时系统会弹权限请求，不会卡住画面
        scanQueue.async {
            let result = scanEverything(folder: folder, date: date, rules: r, termsRule: tr, baseDir: base, glossaryFiles: files)
            DispatchQueue.main.async {
                self.scanFinished(result)
            }
        }
    }

    func rescanNow() {
        scanFinished(scanEverything(folder: pdfFolderURL, date: pdfDateString(), rules: rules, termsRule: termsRule,
                                    baseDir: baseDir, glossaryFiles: glossaryFileURLs()))
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
                writeLog("\(pdfName(key))：✅ \(u.lastPathComponent)")
            } else if r.readable {
                writeLog("\(pdfName(key))：⚠️ 还没有符合规则的文件（\(rulePatterns[key] ?? "?")）")
            }
        }
        if r.unused != old.unused && !r.unused.isEmpty {
            writeLog("注意：含今天日期但不符合规则（不会使用）：" + r.unused.joined(separator: "、"))
        }
        // 正处在 PDF 时段但还没显示（例如程序晚开、文件刚放进来）：马上再试
        if case .pdf(let key) = currentScene, pdfShownKey == nil, !waitingForDownload(key), showPDF(key) {
            writeLog("\(pdfName(key))：文件已找到，开始显示")
        }
        // 术语表、今日术语文件改过 → 重新载入；今天的 PDF 换了 → 重新找 PDF 里的术语
        if r.glossaryStamp != glossaryStamp || !glossaryLoaded {
            let first = !glossaryLoaded
            glossaryStamp = r.glossaryStamp
            rebuildGlossary(first ? "载入" : "文件有变化，重新载入", announce: !first)
        }
        updatePDFTexts()
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
        writeLog("已载入\(pdfName(key))：\(url.lastPathComponent)（\(doc.pageCount) 页）")
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
        if target > 0 { writeLog("\(pdfName(key))：回到刚才的第 \(target + 1) 页") }
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
        writeLog("关闭\(pdfName(k))")
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

    // MARK: Google Drive

    func setupGDrive() {
        let g = cfg.gdrive
        guard g.enabled, !noGDrive else { return }
        if g.folderId.isEmpty {
            let msg = "config.json 里 gdrive.folderId 还没填（Google Drive 文件夹 ID）"
            gdriveSetupProblem = msg
            problems.append(msg)
            return
        }
        var candidates: [URL] = []
        if !g.rclone.isEmpty { candidates.append(expandPath(g.rclone, base: baseDir)) }
        candidates.append(baseDir.appendingPathComponent("rclone"))
        candidates.append(baseDir.appendingPathComponent("bin/rclone"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/rclone"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/rclone"))
        candidates.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("bin/rclone"))
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            let msg = "找不到 rclone（请把 rclone 放在 Presenter 文件夹里）"
            gdriveSetupProblem = msg
            problems.append(msg)
            return
        }
        gdriveExe = exe
        gdriveReady = true
        loadGDriveState()
    }

    var gdriveStateURL: URL {
        return baseDir.appendingPathComponent("gdrive-state.json")
    }

    func loadGDriveState() {
        guard let d = try? Data(contentsOf: gdriveStateURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let r = try? dec.decode([String: GDriveRecord].self, from: d) { gdriveRecords = r }
    }

    func saveGDriveState() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(gdriveRecords) { try? d.write(to: gdriveStateURL, options: .atomic) }
    }

    /// 开始从 Google Drive 下载（正在下载时排队，等这一轮完成再做）
    func startGDriveFetch(_ keys: [String], force: Bool, reason: String, announce: Bool) {
        guard gdriveReady, let exe = gdriveExe else { return }
        let want = keys.filter { rules[$0] != nil }
        if want.isEmpty { return }
        if !gdriveBusyKeys.isEmpty {
            var p = gdrivePending ?? (keys: Set<String>(), force: false, reason: reason, announce: false)
            p.keys.formUnion(want)
            p.force = p.force || force
            p.announce = p.announce || announce
            gdrivePending = p
            return
        }
        gdriveBusyKeys = Set(want)
        for k in want { gdriveStatus[k] = "下载中…" }
        writeLog("Google Drive：\(reason)（\(want.joined(separator: "、"))）")
        let job = GDriveJob(exe: exe, remote: cfg.gdrive.remote, folderId: cfg.gdrive.folderId, keys: want,
                            rules: rules, dest: pdfFolderURL, known: gdriveRecords, force: force)
        gdriveQueue.async {
            let outcomes = runGDriveJob(job)
            DispatchQueue.main.async {
                self.gdriveFinished(outcomes, announce: announce)
            }
        }
    }

    func gdriveFinished(_ outcomes: [GDriveOutcome], announce: Bool) {
        gdriveBusyKeys.removeAll()
        var changed: [String] = []
        var problem = false
        for o in outcomes {
            gdriveStatus[o.key] = o.downloaded ? "\(o.message)（\(hms(Date()))）" : o.message
            if let r = o.record { gdriveRecords[o.key] = r }
            if o.downloaded { changed.append(o.key) }
            if !o.ok { problem = true }
            writeLog("Google Drive \(pdfName(o.key))：\(o.message)")
        }
        saveGDriveState()
        rescanNow()
        // 正在显示的 PDF 有了新版本（手动重新下载时）：重新载入，停在原来那一页
        if let k = pdfShownKey, changed.contains(k) { reloadShownPDFKeepingPage() }
        if announce || problem || !changed.isEmpty {
            let title = problem ? "Google Drive：有文件没取到（会用 PDF 文件夹里已有的文件）" : "Google Drive：PDF 已准备好"
            showHUD(title: title, note: nil, seconds: problem ? 10 : 6)
        }
        if let p = gdrivePending {
            gdrivePending = nil
            startGDriveFetch(Array(p.keys), force: p.force, reason: p.reason, announce: p.announce)
        }
    }

    /// 开场时正在下载这个 PDF，而且还没等够 waitSeconds
    func waitingForDownload(_ key: String) -> Bool {
        guard gdriveBusyKeys.contains(key), let u = gdriveWaitUntil[key] else { return false }
        return appNow() < u
    }

    /// 每个 PDF 开始前几分钟，再检查一次云端有没有更新（有更新才下载）
    func gdriveTick(_ now: Date) {
        guard gdriveReady, !testMode, cfg.gdrive.recheckBeforeMinutes > 0 else { return }
        let lead = cfg.gdrive.recheckBeforeMinutes * 60
        for (j, e) in timeline.enumerated() where isPDFShow(e.show) && !gdriveRechecked.contains(j) {
            let dt = e.at.timeIntervalSince(now)
            if dt <= lead {
                gdriveRechecked.insert(j)
                if dt > 0 {
                    startGDriveFetch([e.show], force: false, reason: "\(pdfName(e.show)) 开始前再检查一次", announce: false)
                    startTermsFetch()
                }
            }
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
        let needed = captionNeededSoon(now)
        if captionSource == "apple" {
            guard let r = recognizer else { return }
            if needed {
                if !r.running {
                    if let retry = r.retryAt, Date() < retry { return }
                    startRecognizer("开始")
                }
                r.clearIfIdle(after: cfg.caption.apple.clearAfterSeconds)
            } else if r.running {
                r.stop()
                writeLog("本机识别：暂停（现在不需要显示字幕）")
            }
            return
        }
        if let r = recognizer, r.running { r.stop() }
        guard needed else { return }
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
                kaleoCaption(t)
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

    /// Kaleo 网页的最新文字（滑动窗口）→ 接到滚动字幕后面
    func kaleoCaption(_ t: String) {
        guard captionSource == "kaleo" else { return }
        let m = kaleoMerger.merge(t)
        captionFeed.b.append(m.append)
        captionFeed.b.setTail(m.tail)
        scheduleCaptionPush()
    }

    /// 本机识别的字幕变化 → 滚动字幕（英文段落之间加空格，中文不加）
    func appleCaption(_ ev: CaptionEvent) {
        guard captionSource == "apple" else { return }
        let origEnglish = !appleLanguage.hasPrefix("zh")
        switch ev {
        case .clear:
            captionFeed.reset()
        case .committed(let s):
            captionFeed.a.append(spaced(s, after: captionFeed.a, english: origEnglish))
            captionFeed.a.setTail("")
        case .volatile(let s):
            captionFeed.a.setTail(s.isEmpty ? "" : spaced(s, after: captionFeed.a, english: origEnglish))
        case .translation(let s):
            captionFeed.b.append(spaced(s, after: captionFeed.b, english: appleTargetFor(appleLanguage).hasPrefix("en")))
        }
        scheduleCaptionPush()
    }

    func spaced(_ s: String, after st: CaptionStream, english: Bool) -> String {
        guard english, st.hasCommitted, let f = s.first, !f.isWhitespace, !",.;:!?".contains(f) else { return s }
        return " " + s
    }

    /// 字幕显示方式：single（Kaleo）| both | original | translation
    func captionModeFor(_ display: String) -> String {
        if captionSource != "apple" { return "single" }
        if appleTargetFor(appleLanguage).isEmpty || recognizer?.translationProblem != nil { return "original" }
        switch display {
        case "original": return "original"
        case "translation": return "translation"
        default: return "both"
        }
    }

    /// 字幕有变化：这一轮事件处理完后推给投影字幕条（同一轮里多次变化只推一次）
    func scheduleCaptionPush() {
        if captionPushPending { return }
        captionPushPending = true
        DispatchQueue.main.async {
            self.captionPushPending = false
            self.pushCaptionToProjector()
        }
    }

    func pushCaptionToProjector() {
        guard captionPageLoaded else { return }
        let d = captionFeed.delta(epoch: projectorSent.e, a: projectorSent.a, b: projectorSent.b,
                                  mode: captionModeFor(appleDisplay), visible: true)
        projectorSent = (e: captionFeed.epoch, a: captionFeed.a.lastId, b: captionFeed.b.lastId)
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        captionView.evaluateJavaScript("window.capApply && window.capApply(\(json))", completionHandler: nil)
    }

    /// 把当前字幕来源的文字显示到字幕条
    func refreshCaptionDisplay() {
        scheduleCaptionPush()
    }

    // MARK: OBS 字幕叠加

    func startCaptionServer() {
        guard cfg.obs.enabled, captionServer == nil else { return }
        let server = CaptionServer(port: UInt16(cfg.obs.port))
        server.handler = { [weak self] path, query in
            guard let self = self else { return (status: 404, type: "text/plain", body: Data()) }
            return self.handleOBSRequest(path, query)
        }
        captionServer = server
        server.start()
    }

    func handleOBSRequest(_ path: String, _ q: [String: String]) -> (status: Int, type: String, body: Data) {
        switch path {
        case "/", "/caption", "/caption.html":
            return (status: 200, type: "text/html; charset=utf-8", body: Data(obsCaptionHTML(cfg.obs).utf8))
        case "/state":
            obsLastPoll = Date()
            let d = captionFeed.delta(epoch: Int(q["e"] ?? "") ?? -1, a: Int(q["a"] ?? "") ?? 0, b: Int(q["b"] ?? "") ?? 0,
                                      mode: captionModeFor(appleDisplay), visible: obsVisible())
            let data = (try? JSONSerialization.data(withJSONObject: d, options: [])) ?? Data("{}".utf8)
            return (status: 200, type: "application/json; charset=utf-8", body: data)
        default:
            return (status: 404, type: "text/plain; charset=utf-8", body: Data("not found".utf8))
        }
    }

    /// OBS 上要不要显示：same = 跟投影字幕条一样；auto = 字幕时段内（或手动打开时）一直显示
    func obsVisible() -> Bool {
        if cfg.obs.visibility == "auto" {
            return captionVisible || captionAutoVisible(appNow())
        }
        return captionVisible
    }

    func obsStatusText() -> String {
        guard cfg.obs.enabled else { return "OBS 字幕叠加：已关闭（config.json 的 obs.enabled）" }
        guard let s = captionServer else { return "OBS 字幕叠加：未启动" }
        var t = "OBS 字幕叠加：\(s.state)"
        if let last = obsLastPoll {
            t += Date().timeIntervalSince(last) < 5 ? "（OBS 已连接）" : "（OBS \(durationText(Date().timeIntervalSince(last))) 前连接过）"
        } else {
            t += "（OBS 还没连接）"
        }
        return t
    }

    /// 本机识别：要翻成哪种语言（空 = 不翻译）
    func appleTargetFor(_ lang: String) -> String {
        let t = cfg.caption.apple.translateTo.lowercased()
        if t == "auto" || t.isEmpty { return lang.hasPrefix("zh") ? "en-US" : "zh-CN" }
        if t == "none" { return "" }
        let target = t.hasPrefix("en") ? "en-US" : "zh-CN"
        return target == lang ? "" : target
    }

    func setupRecognizer() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let r = LiveCaptionEngine()
            r.onUpdate = { [weak self] original, translated in
                guard let self = self else { return }
                self.appleOriginal = original
                self.appleTranslation = translated
            }
            r.onCaption = { [weak self] ev in self?.appleCaption(ev) }
            r.autoPunctuation = cfg.caption.apple.autoPunctuation
            r.pauseComma = cfg.caption.apple.pauseComma
            r.pausePeriod = cfg.caption.apple.pausePeriod
            r.onStatus = { [weak self] status in
                self?.appleStatus = status
                writeLog("本机识别：\(status)")
            }
            r.onRecord = { [weak self] rec in self?.handleRecord(rec) }
            r.sentenceMode = sentenceMode
            r.sentenceMaxSeconds = cfg.caption.apple.sentenceMaxSeconds
            r.sentencePause = cfg.caption.apple.sentencePauseSeconds
            r.highFidelity = highFidelity
            r.glossary = glossary
            recognizer = r
        }
        #endif
        if recognizer == nil {
            appleStatus = "⚠️ 本机识别需要 macOS 26，并用 Xcode 26 编译"
        }
    }

    func startRecognizer(_ why: String) {
        guard let r = recognizer else { return }
        appleOriginal = ""
        appleTranslation = ""
        captionFeed.reset()
        refreshCaptionDisplay()
        writeLog("本机识别：\(why)（\(languageName(appleLanguage))，输入 \(cfg.caption.apple.inputDevice)）")
        transcriptHeaderPending = true
        r.start(language: appleLanguage, target: appleTargetFor(appleLanguage),
                device: cfg.caption.apple.inputDevice, channel: cfg.caption.apple.channel)
    }

    func captionSourceText() -> String {
        if captionSource == "apple" {
            let t = appleTargetFor(appleLanguage)
            return "本机识别（\(languageName(appleLanguage))" + (t.isEmpty ? "" : " → \(languageName(t))") + "）"
        }
        return "Kaleo 网页"
    }

    func setCaptionSource(_ src: String) {
        guard src != captionSource else { return }
        if src == "apple" && recognizer == nil {
            infoHUD.show("本机识别不可用：\(appleStatus)", on: builtInScreen(), seconds: 5)
            return
        }
        captionSource = src
        writeLog("字幕来源：\(captionSourceText())")
        infoHUD.show("字幕来源：\(captionSourceText())", on: builtInScreen(), seconds: 3)
        captionFeed.reset()
        kaleoMerger.reset()
        if src == "kaleo" {
            recognizer?.stop()
            if !captionText.isEmpty { kaleoCaption(captionText) }
        }
        layoutContent()
        refreshCaptionDisplay()
        captionTick(appNow())
    }

    func setAppleLanguage(_ lang: String) {
        guard lang != appleLanguage else { return }
        appleLanguage = lang
        let msg = "本机识别语言：\(languageName(lang))" + (appleTargetFor(lang).isEmpty ? "" : "，翻成\(languageName(appleTargetFor(lang)))")
        writeLog(msg)
        infoHUD.show(msg, on: builtInScreen(), seconds: 3)
        if let r = recognizer, r.running { startRecognizer("切换语言") }
    }

    func setAppleDisplay(_ d: String) {
        appleDisplay = d
        let name = d == "original" ? "只显示原文" : (d == "translation" ? "只显示译文" : "原文 + 译文")
        writeLog("本机识别字幕显示：\(name)")
        var msg = "字幕显示：\(name)"
        if captionSource != "apple" { msg += "\n（只对本机识别有效；现在的字幕来源是 Kaleo）" }
        infoHUD.show(msg, on: builtInScreen(), seconds: 3)
        refreshCaptionDisplay()
    }

    func applyCaptionStyle() {
        guard captionPageLoaded else { return }
        let c = cfg.caption
        let js = "window.capStyle && window.capStyle({fg:\(jsString(c.color)),bg:\(jsString(c.background)),lines:\(c.lines),"
            + "ph:\(jsString("实时翻译 · Live Translation")),margin:\(c.marginPercent)})"
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
        if v == true && !sourceRequested && captionSource == "kaleo" { loadSource("手动打开") }
        tick()
        captionTick(appNow())
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

    func setSentenceMode(_ on: Bool) {
        sentenceMode = on
        recognizer?.sentenceMode = on
        if recognizer?.running == true { transcriptHeaderPending = true }
        let msg = on ? "整句翻译：开（一句说完再翻，译文晚一两秒出来，更准）" : "整句翻译：关（每段马上翻）"
        writeLog(msg)
        var m = msg
        if captionSource != "apple" { m += "\n（只对本机识别有效；现在的字幕来源是 Kaleo）" }
        infoHUD.show(m, on: builtInScreen(), seconds: 3)
    }

    func setHighFidelity(_ on: Bool) {
        guard on != highFidelity else { return }
        highFidelity = on
        recognizer?.highFidelity = on
        if recognizer?.running == true { transcriptHeaderPending = true }
        let msg = on ? "翻译质量：高保真（Apple Intelligence 可用时用它，否则自动用普通模型）" : "翻译质量：快速"
        writeLog(msg)
        infoHUD.show(msg, on: builtInScreen(), seconds: 3)
    }

    // MARK: 术语表

    func rulePatternsTerms() -> String {
        return termsRule?.pattern ?? "（无）"
    }

    func glossaryFileURLs() -> [URL] {
        guard cfg.glossary.enabled else { return [] }
        return cfg.glossary.files.map { expandPath($0, base: baseDir) }
    }

    /// 读术语表文件 + 今日术语文件 + 今天 PDF 里的术语，建立新的术语表
    func buildGlossary(terms: URL?, pdfTexts texts: [String]) -> CaptionGlossary {
        var problems: [String] = []
        var fileSources: [GlossarySource] = []
        var parts: [String] = []
        for url in glossaryFileURLs() {
            let name = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: url.path) else {
                parts.append("\(name) 没有")
                continue
            }
            guard let text = readTextFile(url) else {
                problems.append("无法读取 \(name)")
                continue
            }
            let p = parseGlossary(text, name: name)
            problems += p.problems
            fileSources.append(GlossarySource(name: name, entries: p.entries, protected: p.protected, today: false))
            parts.append("\(name) \(p.entries.count) 条")
        }
        var sources: [GlossarySource] = []
        var todayParts: [String] = []
        if let t = terms {
            if let text = readTextFile(t) {
                let p = parseGlossary(text, name: t.lastPathComponent)
                problems += p.problems
                sources.append(GlossarySource(name: t.lastPathComponent, entries: p.entries, protected: p.protected, today: true))
                todayParts.append("\(t.lastPathComponent) \(p.entries.count) 条")
            } else {
                problems.append("无法读取 \(t.lastPathComponent)")
            }
        }
        if cfg.glossary.pdfTerms && !texts.isEmpty {
            let found = findPDFTerms(texts, in: sources + fileSources)
            if !found.entries.isEmpty {
                sources.append(GlossarySource(name: "PDF", entries: found.entries, protected: [], today: true))
                todayParts.append("PDF 里 \(found.termCount) 个术语" + (found.nameCount > 0 ? "、\(found.nameCount) 个名字" : ""))
            }
        }
        sources += fileSources
        var summary = "术语表：" + (parts.isEmpty ? "没有" : parts.joined(separator: "，"))
        summary += "；今日术语：" + (todayParts.isEmpty ? "没有" : todayParts.joined(separator: "，"))
        return CaptionGlossary(sources: sources, fuzzyMode: cfg.glossary.fuzzy, fuzzyMinLength: cfg.glossary.fuzzyMinLength,
                               beforeTranslation: cfg.glossary.beforeTranslation, problems: problems, summary: summary)
    }

    func rebuildGlossary(_ why: String, announce: Bool = false) {
        glossaryLoaded = true
        guard cfg.glossary.enabled else {
            glossary = nil
            recognizer?.glossary = nil
            glossaryInfo = "术语表：已关闭（config.json 的 glossary.enabled）"
            return
        }
        let texts = pdfKeys().compactMap { pdfTexts[$0]?.text }
        let g = buildGlossary(terms: scan.terms, pdfTexts: texts)
        glossary = g
        recognizer?.glossary = g
        glossaryInfo = g.summary
        if recognizer?.running == true { transcriptHeaderPending = true }
        writeLog("术语表（\(why)）：\(g.summary)")
        if !g.todayTerms.isEmpty { writeLog("今日术语：" + g.todayTerms.prefix(60).joined(separator: "、")) }
        for p in g.problems.filter({ !glossaryProblems.contains($0) }).prefix(10) { writeLog("⚠️ 术语表：\(p)") }
        glossaryProblems = g.problems
        if announce {
            var msg = "术语表已重新载入（下一句开始生效）\n\(g.summary)"
            if !g.problems.isEmpty { msg += "\n⚠️ 有 \(g.problems.count) 行看不懂，详见日志" }
            infoHUD.show(msg, on: builtInScreen(), seconds: 5)
        }
    }

    /// 今天的 PDF 有新文件：后台读出文字，找里面的术语和名字
    func updatePDFTexts() {
        guard cfg.glossary.enabled, cfg.glossary.pdfTerms else { return }
        for key in pdfKeys() {
            guard let u = scan.matches[key] else { continue }
            let mod = scan.mods[key]
            if let old = pdfTexts[key], old.url == u, old.mod == mod { continue }
            if pdfTextBusy.contains(key) { continue }
            pdfTextBusy.insert(key)
            textQueue.async {
                let text = extractPDFText(u)
                DispatchQueue.main.async {
                    self.pdfTextBusy.remove(key)
                    self.pdfTexts[key] = (url: u, mod: mod, text: text)
                    writeLog("\(pdfName(key))：读出 PDF 文字 \(text.count) 字（找今天的专有名词用）")
                    self.rebuildGlossary("\(pdfName(key)) 的 PDF")
                }
            }
        }
    }

    /// 从 Google Drive 文件夹下载今日术语（terms-yyyymmdd：Google 表格、Google 文档或 csv/txt 文件），存到下载文件夹
    func startTermsFetch() {
        guard gdriveReady, let exe = gdriveExe, cfg.glossary.enabled, cfg.glossary.fromGoogleDrive,
              let re = termsRule, !termsFetchBusy else { return }
        termsFetchBusy = true
        let job = GDriveJob(exe: exe, remote: cfg.gdrive.remote, folderId: cfg.gdrive.folderId, keys: ["terms"],
                            rules: ["terms": re], dest: pdfFolderURL, known: gdriveRecords, force: false,
                            exportFormats: "csv,txt", wantPDF: false, isOptional: true)
        gdriveQueue.async {
            let outcomes = runGDriveJob(job)
            DispatchQueue.main.async {
                self.termsFetchBusy = false
                for o in outcomes {
                    self.gdriveStatus["terms"] = o.message
                    if let r = o.record { self.gdriveRecords["terms"] = r }
                    if o.downloaded || !o.ok { writeLog("Google Drive 今日术语：\(o.message)") }
                }
                self.saveGDriveState()
                self.rescanNow()
            }
        }
    }

    /// 用 TextEdit 打开（csv 用 Numbers 打开再保存会变成 .numbers）
    func openInTextEdit(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            _ = NSWorkspace.shared.open(url)
        }
    }

    // MARK: 字幕记录

    var transcriptFolder: URL {
        return baseDir.appendingPathComponent("transcripts", isDirectory: true)
    }

    func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: d)
    }

    func transcriptURL(for d: Date) -> URL {
        return transcriptFolder.appendingPathComponent("transcript-\(dayString(d)).txt")
    }

    func appendTranscript(_ s: String) {
        guard cfg.caption.apple.saveTranscript else { return }
        let url = transcriptURL(for: Date())
        try? FileManager.default.createDirectory(at: transcriptFolder, withIntermediateDirectories: true, attributes: nil)
        let data = Data(s.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    func handleRecord(_ r: CaptionRecord) {
        if transcriptHeaderPending {
            transcriptHeaderPending = false
            appendTranscript(transcriptHeader())
        }
        appendTranscript(transcriptBlock(r))
    }

    func transcriptHeader() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let t = appleTargetFor(appleLanguage)
        var s = "\n===== \(f.string(from: Date())) 本机识别：\(languageName(appleLanguage))"
        s += t.isEmpty ? "，不翻译" : " → \(languageName(t))"
        s += "（\(appleLanguage)→\(t)）"
        s += " · 整句翻译" + (sentenceMode ? "开" : "关")
        s += " · 翻译" + (highFidelity ? "高保真" : "快速")
        if testMode { s += " · 测试模式" }
        s += " =====\n\(glossaryInfo)\n"
        if let g = glossary, !g.todayTerms.isEmpty { s += "今日术语：" + g.todayTerms.joined(separator: "、") + "\n" }
        return s + "\n"
    }

    /// 一句的记录：原 = 识别原文；改 = 纠正后（Tab 后面是改了什么）；送 = 送去翻译的文字（术语已换成译名）；译 = 译文
    func transcriptBlock(_ r: CaptionRecord) -> String {
        var s = "[\(hms(r.time))]\n原：\(r.raw)\n"
        let applied = r.fixes.filter { $0.how != "可能" }
        let maybe = r.fixes.filter { $0.how == "可能" }
        if r.fixed != r.raw || !maybe.isEmpty {
            var notes = applied.map { "\($0.from)→\($0.to)" + ($0.how == "拼音" ? "（读音）" : "") }
            notes += maybe.map { "可能是 \($0.from)→\($0.to)？" }
            s += "改：\(r.fixed)"
            if !notes.isEmpty { s += "\t【" + notes.joined(separator: "；") + "】" }
            s += "\n"
        }
        if !r.sent.isEmpty && r.sent != r.fixed { s += "送：\(r.sent)\n" }
        if !r.translated.isEmpty { s += "译：\(r.translated)\n" }
        return s + "\n"
    }

    func newestTranscript() -> URL? {
        guard let re = try? NSRegularExpression(pattern: "^transcript-[0-9]{8}\\.txt$", options: []) else { return nil }
        return newestFile(in: [transcriptFolder], matching: re)?.url
    }

    // MARK: 字幕记录复查

    /// open Presenter.app --args --review [20261115 | 文件]：不投影，只复查字幕记录，打开结果后退出
    func startReviewMode() {
        writeLog("复查模式（--review）")
        highFidelity = cfg.caption.apple.translationQuality != "fast"
        var file: URL?
        if let a = reviewArg?.trimmingCharacters(in: .whitespaces), !a.isEmpty {
            if a.count == 8, Int(a) != nil {
                file = transcriptFolder.appendingPathComponent("transcript-\(a).txt")
            } else {
                file = expandPath(a, base: baseDir)
            }
        } else {
            file = newestTranscript()
        }
        guard let f = file, FileManager.default.fileExists(atPath: f.path) else {
            let msg = "没有找到字幕记录" + (file.map { "：\($0.path)" } ?? "（transcripts 文件夹是空的）")
            writeLog("⚠️ " + msg)
            infoHUD.show("Presenter 复查：\(msg)", on: builtInScreen() ?? NSScreen.main, seconds: 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
            return
        }
        runReview(f) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }

    /// 复查用的术语表：今天的记录用现在的术语表；其他日子的记录用那天的今日术语文件和 PDF（还在的话）
    func glossaryForReview(day: String?) -> CaptionGlossary {
        if day == nil || day == dayString(Date()), let g = glossary { return g }
        var termsURL: URL?
        var texts: [String] = []
        if let d = day {
            let p = DateFormatter()
            p.locale = Locale(identifier: "en_US_POSIX")
            p.dateFormat = "yyyyMMdd"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = cfg.dateFormat
            if let date = p.date(from: d) {
                let ds = NSRegularExpression.escapedPattern(for: f.string(from: date))
                if cfg.glossary.enabled,
                   let re = try? NSRegularExpression(pattern: cfg.glossary.termsFile.replacingOccurrences(of: "{date}", with: ds),
                                                     options: [.caseInsensitive]) {
                    termsURL = newestFile(in: [pdfFolderURL, baseDir], matching: re)?.url
                }
                if cfg.glossary.pdfTerms {
                    for (_, pattern) in cfg.pdfPatterns {
                        guard let re = try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: "{date}", with: ds), options: []),
                              let u = newestFile(in: [pdfFolderURL], matching: re)?.url else { continue }
                        texts.append(extractPDFText(u))
                    }
                }
            }
        }
        return buildGlossary(terms: termsURL, pdfTexts: texts)
    }

    @MainActor
    func makeReviewTranslator(from source: String, to target: String) async -> ReviewTranslate? {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let r = await TranslatorFactory.make(source: source, target: target, high: highFidelity)
            if let session = r.session {
                return { text in
                    do {
                        return try await session.translate(text).targetText
                    } catch {
                        return nil
                    }
                }
            }
        }
        #endif
        return nil
    }

    func runReview(_ file: URL, done: (() -> Void)? = nil) {
        guard !reviewBusy else {
            infoHUD.show("正在复查，请稍候…", on: builtInScreen() ?? NSScreen.main, seconds: 3)
            return
        }
        guard let text = readTextFile(file) else {
            infoHUD.show("无法读取 \(file.lastPathComponent)", on: builtInScreen() ?? NSScreen.main, seconds: 6)
            done?()
            return
        }
        reviewBusy = true
        let items = parseTranscript(text)
        let name = file.lastPathComponent
        var day: String?
        if let re = try? NSRegularExpression(pattern: "([0-9]{8})", options: []),
           let m = re.firstMatch(in: name, options: [], range: NSRange(location: 0, length: (name as NSString).length)) {
            day = (name as NSString).substring(with: m.range(at: 1))
        }
        let g = glossaryForReview(day: day)
        infoHUD.show("正在复查 \(name)（\(items.count) 句）…\n有变化的句子要重新翻译，可能要一两分钟", on: builtInScreen() ?? NSScreen.main, seconds: nil)
        Task { @MainActor in
            let report = await self.makeReview(items: items, glossary: g, file: file)
            let out = file.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "transcript-", with: "review-"))
            do {
                try report.write(to: out, atomically: true, encoding: .utf8)
                writeLog("复查完成：\(out.path)")
                self.infoHUD.show("复查完成：\(out.lastPathComponent)\n（已用 TextEdit 打开）", on: self.builtInScreen() ?? NSScreen.main, seconds: 5)
                self.openInTextEdit(out)
            } catch {
                writeLog("⚠️ 无法保存复查结果：\(error.localizedDescription)")
                self.infoHUD.show("⚠️ 无法保存复查结果：\(error.localizedDescription)", on: self.builtInScreen() ?? NSScreen.main, seconds: 8)
            }
            self.reviewBusy = false
            done?()
        }
    }

    /// 生成复查报告：没认出的名字、自动纠正了什么、用现在的术语表重新处理后有变化的句子
    @MainActor
    func makeReview(items: [TranscriptItem], glossary g: CaptionGlossary, file: URL) async -> String {
        var translators: [String: ReviewTranslate] = [:]
        var noTranslator = Set<String>()
        var changed: [String] = []
        var fixStats: [String: (count: Int, example: String)] = [:]
        var fixOrder: [String] = []
        var maybeStats: [String: (count: Int, example: String)] = [:]
        var maybeOrder: [String] = []
        var names: [String: (count: Int, example: String)] = [:]
        var nameOrder: [String] = []
        var translatedCount = 0
        var retranslated = 0
        let stop: Set<String> = ["god", "jesus", "christ", "lord", "holy spirit", "bible", "amen", "father", "spirit", "sunday"]
        for it in items {
            let c = g.correct(it.raw, language: it.language)
            for f in c.fixes {
                let key = "\(f.from) → \(f.to)"
                let ex = "[\(it.time)] \(it.raw)"
                if f.how == "可能" {
                    if let v = maybeStats[key] { maybeStats[key] = (v.count + 1, v.example) } else { maybeStats[key] = (1, ex); maybeOrder.append(key) }
                } else {
                    let k = key + (f.how == "拼音" ? "（读音相同）" : "（术语表）")
                    if let v = fixStats[k] { fixStats[k] = (v.count + 1, v.example) } else { fixStats[k] = (1, ex); fixOrder.append(k) }
                }
            }
            let oldFixed = it.fixed.isEmpty ? it.raw : it.fixed
            var newTranslated = it.translated
            if !it.target.isEmpty && !it.translated.isEmpty {
                translatedCount += 1
                let newSent = g.prepareForTranslation(c.text, language: it.language)
                let oldSent = it.sent.isEmpty ? oldFixed : it.sent
                if newSent != oldSent {
                    let k = it.language + "→" + it.target
                    if translators[k] == nil && !noTranslator.contains(k) {
                        if let tr = await makeReviewTranslator(from: it.language, to: it.target) {
                            translators[k] = tr
                        } else {
                            noTranslator.insert(k)
                        }
                    }
                    if let tr = translators[k], let t = await tr(newSent) {
                        newTranslated = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        retranslated += 1
                    }
                    var block = "[\(it.time)]\n  原：\(it.raw)\n"
                    if c.text != oldFixed { block += "  旧改：\(oldFixed)\n  新改：\(c.text)\n" }
                    block += "  新送：\(newSent)\n  旧译：\(it.translated)\n  新译：\(newTranslated == it.translated ? "（没有重新翻译）" : newTranslated)\n"
                    changed.append(block)
                }
            } else if c.text != oldFixed {
                changed.append("[\(it.time)]\n  原：\(it.raw)\n  旧改：\(oldFixed)\n  新改：\(c.text)\n")
            }
            // 英文里的人名、地名：普通话讲道看译文，英文讲道看原文
            let english = it.language.hasPrefix("en") ? c.text : newTranslated
            if !english.isEmpty {
                for n in englishNameCandidates(english) where !g.knowsEnglish(n) && !stop.contains(n.lowercased()) {
                    let other = it.language.hasPrefix("en") ? newTranslated : c.text
                    let ex = "[\(it.time)] \(other)\n        \(english)"
                    if let v = names[n] { names[n] = (v.count + 1, v.example) } else { names[n] = (1, ex); nameOrder.append(n) }
                }
            }
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var r = "Presenter 字幕复查\n"
        r += "字幕记录：\(file.lastPathComponent)（\(items.count) 句，其中翻译了 \(translatedCount) 句）\n"
        r += "复查时间：\(f.string(from: Date()))\n"
        r += "\(g.summary)\n"
        if !g.todayTerms.isEmpty { r += "今日术语：" + g.todayTerms.joined(separator: "、") + "\n" }
        r += """

        怎么用（详见 README “提高翻译质量”一节）：
          1. 看“一”：译文里没认出的名字 → 在 glossary.csv 加一行：中文,English
          2. 看“二”：确认自动纠正没有改错。
             “可能听错”里确实是听错的 → 把错的写法加到那个词的第 3 列（多个用 | 分开）
             改错了的 → 在 glossary.csv 加一行：!那几个字（以后不再改）
          3. 保存 glossary.csv，再复查一次，看“三”里新的结果对不对

        """
        r += "\n一、译文里的人名、地名（还不在术语表里，按出现次数）\n"
        let sortedNames = nameOrder.sorted { (names[$0]?.count ?? 0) > (names[$1]?.count ?? 0) }
        if sortedNames.isEmpty { r += "  （没有）\n" }
        for n in sortedNames.prefix(80) {
            guard let v = names[n] else { continue }
            let pinyin = n.split(separator: " ").allSatisfy { isPinyinLike(String($0)) }
            r += "  \(n) ×\(v.count)" + (pinyin ? "（像拼音：多半是没认出的中文名字）" : "") + "\n"
            r += "     例：\(v.example)\n"
        }
        r += "\n二、自动纠正\n  已改：\n"
        if fixOrder.isEmpty { r += "    （没有）\n" }
        for k in fixOrder {
            guard let v = fixStats[k] else { continue }
            r += "    \(k) ×\(v.count)\n       例：\(v.example)\n"
        }
        r += "  可能听错（和今日术语读音相同，但看起来像普通词语，没有改）：\n"
        if maybeOrder.isEmpty { r += "    （没有）\n" }
        for k in maybeOrder {
            guard let v = maybeStats[k] else { continue }
            r += "    \(k)？ ×\(v.count)\n       例：\(v.example)\n"
        }
        r += "\n三、用现在的术语表重新处理，结果有变化的句子（\(changed.count) 句，重新翻译了 \(retranslated) 句）\n"
        if !noTranslator.isEmpty { r += "  （本机翻译现在不可用，没有重新翻译）\n" }
        if changed.isEmpty { r += "  （没有变化）\n" }
        for b in changed.prefix(300) { r += b + "\n" }
        if changed.count > 300 { r += "  ……还有 \(changed.count - 300) 句没有列出\n" }
        return r
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
        case .captionSource:
            setCaptionSource(captionSource == "apple" ? "kaleo" : "apple")
            return
        case .showOriginal, .showTranslation, .showBoth:
            let mode = action == .showOriginal ? "original" : (action == .showTranslation ? "translation" : "both")
            setAppleDisplay(mode)
            return
        case .sentenceMode:
            setSentenceMode(!sentenceMode)
            return
        case .captionLanguage:
            if captionSource != "apple" {
                infoHUD.show("现在的字幕来源是 Kaleo；先按 \(hotkeyLabels[.captionSource] ?? "菜单") 切换到本机识别", on: builtInScreen(), seconds: 4)
            } else {
                setAppleLanguage(appleLanguage.hasPrefix("zh") ? "en-US" : "zh-CN")
            }
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
        if gdriveStatus.values.contains(where: { $0.hasPrefix("⚠️") }) { return true }
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
        if captionVisible { t += captionSource == "apple" ? "🎙" : "💬" }
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

    /// 主菜单里的一行 PDF 摘要，例如“pdf1 ✅ · pdf2 ⚠️”
    func pdfSummary() -> String {
        if scan.checked && !scan.readable { return "⚠️ 无法读取 PDF 文件夹" }
        let parts = pdfKeys().map { key -> String in
            if pdfURL(for: key) != nil { return "\(pdfName(key)) ✅" }
            if gdriveBusyKeys.contains(key) { return "\(pdfName(key)) 下载中…" }
            return scan.checked ? "\(pdfName(key)) ⚠️ 缺" : "\(pdfName(key)) 检查中…"
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
        for key in pdfKeys() { lines.append("\(pdfName(key))：\(pdfStatus(key))") }
        if gdriveReady {
            for key in pdfKeys() { lines.append("Google Drive \(pdfName(key))：\(gdriveStatus[key] ?? "—")") }
        }
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
            lines.append("实时翻译：✅ 今天在 \(captionDuringText()) 时显示在投影下方（来源：\(captionSourceText())）")
        } else if let t = hotkeyLabels[.caption] {
            lines.append("实时翻译：今天不自动显示（需要时按 \(t)）")
        }
        if captionSource == "apple" && cfg.glossary.enabled { lines.append(glossaryInfo) }
        if captionToday && cfg.obs.enabled { lines.append(obsStatusText()) }
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

        // PDF：主菜单只放一行摘要和“重新下载”，其余放进“PDF 文件”二级菜单
        addInfo(menu, "PDF：" + pdfSummary())
        let gdOn = cfg.gdrive.enabled && !noGDrive
        if gdOn && gdriveReady {
            addAction(menu, nil, gdriveBusyKeys.isEmpty ? "从 Google Drive 重新下载" : "正在从 Google Drive 下载…（点击可排队再下载一次）",
                      #selector(menuGDriveFetch))
        }
        let pdfItem = NSMenuItem(title: "PDF 文件", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        addInfo(pm, "PDF 文件夹：\(pdfFolderURL.path)")
        if scan.checked && !scan.readable { addInfo(pm, folderStatus()) }
        for key in pdfKeys() { addInfo(pm, "\(pdfName(key))：\(pdfStatus(key))") }
        if !scan.unused.isEmpty {
            addInfo(pm, "注意：含今天日期但不符合规则（不会使用）：")
            for name in scan.unused.prefix(6) { addInfo(pm, "　　\(name)") }
        }
        if gdOn {
            pm.addItem(NSMenuItem.separator())
            if gdriveReady {
                addInfo(pm, "Google Drive 文件夹：\(cfg.gdrive.folderId)")
                for key in pdfKeys() { addInfo(pm, "　\(pdfName(key))：\(gdriveStatus[key] ?? "—")") }
            } else {
                addInfo(pm, "Google Drive：⚠️ \(gdriveSetupProblem ?? "没有启用")")
            }
        }
        pm.addItem(NSMenuItem.separator())
        addAction(pm, nil, "重新检查 PDF / 重新载入当前 PDF", #selector(menuReload))
        addAction(pm, nil, "打开 PDF 文件夹", #selector(menuOpenPDFFolder))
        if gdOn && gdriveReady {
            addAction(pm, nil, "在浏览器打开 Google Drive 文件夹", #selector(menuGDriveOpen))
        }
        pdfItem.submenu = pm
        menu.addItem(pdfItem)
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
        cm.addItem(NSMenuItem.separator())
        addInfo(cm, "字幕来源：")
        addAction(cm, nil, "Kaleo 网页", #selector(menuSourceKaleo), on: captionSource == "kaleo")
        addAction(cm, nil, "本机识别 + 翻译（Apple）", #selector(menuSourceApple), on: captionSource == "apple")
        addAction(cm, .captionSource, "切换字幕来源", #selector(menuSourceToggle))
        cm.addItem(NSMenuItem.separator())
        addAction(cm, .caption, "显示/隐藏（切换）", #selector(menuCaptionToggle))
        addAction(cm, nil, "自动（按日期和时间表）", #selector(menuCaptionAuto), on: captionOverride == nil)
        addAction(cm, nil, "显示", #selector(menuCaptionOn), on: captionOverride == true)
        addAction(cm, nil, "隐藏", #selector(menuCaptionOff), on: captionOverride == false)
        addInfo(cm, "（手动显示/隐藏到下一个自动开关时间为止）")
        cm.addItem(NSMenuItem.separator())
        // 本机识别
        addInfo(cm, "本机识别：\(appleStatus)")
        if let p = recognizer?.translationProblem { addInfo(cm, "翻译：⚠️ \(p)") }
        addAction(cm, nil, "识别普通话（翻成英语）", #selector(menuAppleZh), on: appleLanguage.hasPrefix("zh"))
        addAction(cm, nil, "识别英语（翻成中文）", #selector(menuAppleEn), on: appleLanguage.hasPrefix("en"))
        addAction(cm, .captionLanguage, "切换识别语言", #selector(menuAppleLangToggle))
        addAction(cm, .showBoth, "显示：原文 + 译文", #selector(menuAppleBoth), on: appleDisplay == "both")
        addAction(cm, .showTranslation, "显示：只显示译文", #selector(menuAppleTranslation), on: appleDisplay == "translation")
        addAction(cm, .showOriginal, "显示：只显示原文", #selector(menuAppleOriginal), on: appleDisplay == "original")
        addAction(cm, .sentenceMode, "整句翻译（一句说完再翻，更准）", #selector(menuSentenceToggle), on: sentenceMode)
        addAction(cm, nil, "翻译质量：高保真（Apple Intelligence 可用时）", #selector(menuQualityHigh), on: highFidelity)
        addAction(cm, nil, "翻译质量：快速", #selector(menuQualityFast), on: !highFidelity)
        if let st = recognizer?.translationStats, !st.isEmpty { addInfo(cm, st) }
        // 术语表和字幕记录
        let gItem = NSMenuItem(title: "术语表和字幕记录" + (glossaryProblems.isEmpty ? "" : " ⚠️"), action: nil, keyEquivalent: "")
        let gm = NSMenu()
        addInfo(gm, glossaryInfo)
        if let g = glossary, !g.todayTerms.isEmpty {
            let shown = g.todayTerms.prefix(12).joined(separator: "、")
            addInfo(gm, "今日术语：" + shown + (g.todayTerms.count > 12 ? " 等 \(g.todayTerms.count) 个" : ""))
        }
        if gdriveReady && cfg.glossary.fromGoogleDrive, let st = gdriveStatus["terms"] { addInfo(gm, "Google Drive 今日术语：\(st)") }
        if !glossaryProblems.isEmpty { addInfo(gm, "⚠️ 术语表有 \(glossaryProblems.count) 行看不懂（详见日志）") }
        addAction(gm, nil, "打开教会术语表 glossary.csv", #selector(menuOpenGlossary))
        if let t = scan.terms { addAction(gm, nil, "打开今日术语 \(t.lastPathComponent)", #selector(menuOpenTerms)) }
        addAction(gm, nil, "重新载入术语表", #selector(menuReloadGlossary))
        gm.addItem(NSMenuItem.separator())
        addAction(gm, nil, "打开今天的字幕记录", #selector(menuOpenTranscript))
        addAction(gm, nil, reviewBusy ? "正在复查…" : "复查最近的字幕记录（生成 review 文件）", #selector(menuReview))
        addAction(gm, nil, "打开字幕记录文件夹", #selector(menuOpenTranscriptFolder))
        gItem.submenu = gm
        cm.addItem(gItem)
        addInfo(cm, "音频输入：\(cfg.caption.apple.inputDevice.isEmpty ? "系统默认输入" : cfg.caption.apple.inputDevice)"
                + (cfg.caption.apple.channel > 0 ? "，第 \(cfg.caption.apple.channel) 路" : ""))
        if let names = recognizer?.inputNames(), !names.isEmpty {
            addInfo(cm, "这台 Mac 的音频输入：" + names.joined(separator: "、"))
        }
        cm.addItem(NSMenuItem.separator())
        // OBS
        addInfo(cm, obsStatusText())
        if cfg.obs.enabled && captionServer != nil {
            addAction(cm, nil, "复制 OBS 字幕网址（浏览器来源用）", #selector(menuCopyOBSURL))
            addAction(cm, nil, "在浏览器里预览 OBS 字幕页", #selector(menuOpenOBSPage))
            addAction(cm, nil, "OBS 字幕：跟投影字幕条一起显示/隐藏", #selector(menuOBSSame), on: cfg.obs.visibility == "same")
            addAction(cm, nil, "OBS 字幕：字幕时段内一直显示（投影上隐藏也显示）", #selector(menuOBSAuto), on: cfg.obs.visibility == "auto")
        }
        cm.addItem(NSMenuItem.separator())
        // Kaleo
        addInfo(cm, "Kaleo 网页：" + (sourceRequested ? sourceState : "未载入（需要时自动载入）"))
        addInfo(cm, captionTextStatus())
        if let p = captionPath { addInfo(cm, "文字区域：\(p)") }
        addAction(cm, nil, "显示方式：提取文字（大字）", #selector(menuCaptionText), on: captionMode == "text")
        addAction(cm, nil, "显示方式：原网页", #selector(menuCaptionPage), on: captionMode == "page")
        cm.addItem(NSMenuItem.separator())
        addAction(cm, nil, "重新载入翻译网页", #selector(menuCaptionReload))
        addAction(cm, nil, "打开可点击的翻译网页窗口（首次设置用）", #selector(menuCaptionSetup))
        addAction(cm, nil, "保存网页结构和截图（发给开发者调整用）", #selector(menuCaptionDump))
        capItem.submenu = cm
        menu.addItem(capItem)
        menu.addItem(NSMenuItem.separator())

        let tools = NSMenuItem(title: "工具", action: nil, keyEquivalent: "")
        let tm = NSMenu()
        addAction(tm, nil, "打开 Presenter 文件夹", #selector(menuOpenBase))
        addAction(tm, nil, "查看日志", #selector(menuOpenLog))
        tools.submenu = tm
        menu.addItem(tools)

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
    @objc func menuSourceKaleo() { setCaptionSource("kaleo") }
    @objc func menuSourceApple() { setCaptionSource("apple") }
    @objc func menuSourceToggle() { run(.captionSource) }
    @objc func menuAppleZh() { setAppleLanguage("zh-CN") }
    @objc func menuAppleEn() { setAppleLanguage("en-US") }
    @objc func menuAppleLangToggle() { run(.captionLanguage) }
    @objc func menuAppleBoth() { setAppleDisplay("both") }
    @objc func menuAppleTranslation() { setAppleDisplay("translation") }
    @objc func menuAppleOriginal() { setAppleDisplay("original") }
    @objc func menuSentenceToggle() { run(.sentenceMode) }
    @objc func menuQualityHigh() { setHighFidelity(true) }
    @objc func menuQualityFast() { setHighFidelity(false) }
    @objc func menuOpenGlossary() {
        let url = glossaryFileURLs().first ?? baseDir.appendingPathComponent("glossary.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "中文,English,中文常被识别成,英文常被识别成,方向\n".write(to: url, atomically: true, encoding: .utf8)
        }
        openInTextEdit(url)
    }
    @objc func menuOpenTerms() {
        if let t = scan.terms { openInTextEdit(t) }
    }
    @objc func menuReloadGlossary() {
        rescanNow()
        rebuildGlossary("手动重新载入", announce: true)
    }
    @objc func menuOpenTranscript() {
        let url = transcriptURL(for: Date())
        if FileManager.default.fileExists(atPath: url.path) {
            openInTextEdit(url)
        } else {
            infoHUD.show("今天还没有字幕记录（本机识别开始后才有）", on: builtInScreen(), seconds: 4)
        }
    }
    @objc func menuReview() {
        if let u = newestTranscript() {
            runReview(u)
        } else {
            infoHUD.show("还没有字幕记录（本机识别开始后才有）", on: builtInScreen(), seconds: 4)
        }
    }
    @objc func menuOpenTranscriptFolder() {
        try? FileManager.default.createDirectory(at: transcriptFolder, withIntermediateDirectories: true, attributes: nil)
        _ = NSWorkspace.shared.open(transcriptFolder)
    }
    @objc func menuCaptionAuto() { setCaptionOverride(nil) }
    @objc func menuCaptionOn() { setCaptionOverride(true) }
    @objc func menuCaptionOff() { setCaptionOverride(false) }
    @objc func menuCaptionText() { setCaptionMode("text") }
    @objc func menuCaptionPage() { setCaptionMode("page") }
    @objc func menuCaptionReload() { loadSource("手动重新载入") }
    @objc func menuCaptionSetup() { openCaptionSetupWindow() }
    @objc func menuCaptionDump() { dumpCaptionPage() }
    @objc func menuCopyOBSURL() {
        guard let s = captionServer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.url, forType: .string)
        infoHUD.show("已复制：\(s.url)\n在 OBS 里：来源 › + › 浏览器，粘贴到“URL”", on: builtInScreen(), seconds: 5)
    }
    @objc func menuOpenOBSPage() {
        guard let s = captionServer, let u = URL(string: s.url) else { return }
        _ = NSWorkspace.shared.open(u)
    }
    @objc func menuOBSSame() {
        cfg.obs.visibility = "same"
        infoHUD.show("OBS 字幕：跟投影字幕条一起显示/隐藏", on: builtInScreen(), seconds: 3)
    }
    @objc func menuOBSAuto() {
        cfg.obs.visibility = "auto"
        infoHUD.show("OBS 字幕：字幕时段内一直显示（投影上按 ⌃⌥T 隐藏时也显示）", on: builtInScreen(), seconds: 3)
    }
    @objc func menuReload() {
        rescanNow()
        if pdfShownKey == nil { tick() } else { reloadShownPDFKeepingPage() }
    }
    @objc func menuGDriveFetch() {
        startGDriveFetch(pdfKeys(), force: true, reason: "手动重新下载", announce: true)
        startTermsFetch()
    }
    @objc func menuGDriveOpen() {
        if let u = URL(string: "https://drive.google.com/drive/folders/\(cfg.gdrive.folderId)") { NSWorkspace.shared.open(u) }
    }

    /// 重新载入正在显示的 PDF（文件更新了），停在原来那一页
    func reloadShownPDFKeepingPage() {
        guard let k = pdfShownKey else { return }
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
        for key in pdfKeys() { writeLog("\(pdfName(key)) 规则：\(rulePatterns[key] ?? "（无效）")") }
        writeLog("延长：每次 +\(durationText(extendStep))；PDF 结束前 \(durationText(warnLead)) 提醒")
        writeLog("实时翻译：\(captionDayText())；网址 \(cfg.caption.url)；显示方式 \(captionMode)")
        writeLog("字幕来源：\(captionSourceText())；本机识别：\(recognizer == nil ? appleStatus : "可用")；音频输入 \(cfg.caption.apple.inputDevice)")
        if let names = recognizer?.inputNames() { writeLog("这台 Mac 的音频输入：" + names.joined(separator: "、")) }
        if gdriveReady, let exe = gdriveExe {
            writeLog("Google Drive：rclone = \(exe.path)；远程 \(cfg.gdrive.remote)；文件夹 \(cfg.gdrive.folderId)；下载到 \(pdfFolderURL.path)")
        }
        writeLog("本机识别：整句翻译\(sentenceMode ? "开" : "关")（最多等 \(cfg.caption.apple.sentenceMaxSeconds) 秒，停顿 \(cfg.caption.apple.sentencePauseSeconds) 秒算一句）；翻译\(highFidelity ? "高保真" : "快速")；字幕记录\(cfg.caption.apple.saveTranscript ? "保存到 transcripts 文件夹" : "不保存")")
        writeLog("本机识别补标点：" + (cfg.caption.apple.autoPunctuation == "off" ? "关" :
                 "\(cfg.caption.apple.autoPunctuation == "all" ? "普通话和英语" : "普通话")，停顿 \(cfg.caption.apple.pauseComma) 秒补逗号、\(cfg.caption.apple.pausePeriod) 秒补句号"))
        writeLog("字幕左右留白 \(cfg.caption.marginPercent)%；" + (cfg.obs.enabled ? "OBS 字幕页 http://127.0.0.1:\(cfg.obs.port)/caption（\(cfg.obs.visibility == "auto" ? "字幕时段内一直显示" : "跟投影字幕条一起显示/隐藏")）" : "OBS 字幕叠加已关闭"))
        writeLog(cfg.glossary.enabled
                 ? "术语表：\(cfg.glossary.files.joined(separator: "、"))；读音纠正 \(cfg.glossary.fuzzy)（\(cfg.glossary.fuzzyMinLength) 字以上）；今日术语文件 \(rulePatternsTerms())"
                 : "术语表：已关闭")
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
