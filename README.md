# Presenter — 投影屏按时间表自动切换

内建屏放 OBS，外接投影屏由 Presenter 自动接管（时间都可以在 `config.json` 里改）：

| 时间 | 投影屏显示（全屏） |
|---|---|
| 09:10:00 | 欢迎页：居中显示 Logo 和中英文欢迎语，四周留白 10% |
| 09:12:00 | **pdf1**：`~/Downloads` 里符合 `^[ A-Z][a-z]+-yyyymmdd.pdf$` 的文件（如 `Sunday-20261025.pdf`），第 1 页 |
| 10:18:00 | 关闭 pdf1，回到欢迎页 |
| 10:21:00 | 时钟页：Logo、固定文字、日期和当前时间（带秒），四周留白 10% |
| 10:28:30 | 其他不变，时间变成 90 秒倒计时（01:30 → 00:01） |
| 10:30:00 | **pdf2**：`~/Downloads/yyyymmdd.pdf`（如 `20261025.pdf`），第 1 页 |
| 12:15:00 | Presenter 自动退出 |

翻页用全局快捷键，焦点留在 OBS 也照样有效。投影窗口不会抢焦点，鼠标点击也会穿透。

---

## 一、编译（在有 Xcode 的 Mac 上）

```bash
mv ~/Downloads/Presenter ~/        # 解压出来的文件夹放到主目录
cd ~/Presenter && bash build.sh
```
成功后主目录里会生成 `Presenter-ready.zip`（Apple 芯片版本，需要 macOS 11 及以上）。
只有改了 `presenter.swift` 才需要重新编译；改 `stage.html`、`config.json`、Logo 不用。

## 二、装到直播用的 MacBook Air

1. AirDrop `Presenter-ready.zip` 到 Air，解压后放到主目录 `~/Presenter`（替换旧的）。
2. 终端运行：
   ```bash
   killall Presenter; xattr -dr com.apple.quarantine ~/Presenter
   ```
3. 把 `LogoNew.png` 放进 `~/Presenter/images/`。
4. **彩排一次**（见第五节）。第一次运行时系统会问 **“Presenter 想访问‘下载’文件夹中的文件”**，点 **“好/允许”**。
   - 每次换上新编译的版本，都会再问一次，所以换版本后一定要先手动运行一次，否则周日自动启动时会卡在这个询问上。
   - 如果不小心点了“不允许”：系统设置 › 隐私与安全性 › 文件和文件夹 › Presenter，打开“下载文件夹”。
5. 系统设置 › 显示器：投影仪设为 **扩展显示器**（不要“镜像”）；建议内建屏作主显示器。
6. 设置每周日 9:09 自动启动（见第四节）。

## 三、每周要做的

把两个 PDF 下载/放到 **“下载”文件夹**（`~/Downloads`），文件名：

- pdf1：英文单词（首字母大写，其余小写）+ `-` + 日期，例如 `Sunday-20261025.pdf`、`Bible-20261025.pdf`
  （`SundaySchool-20261025.pdf` 这种中间有大写的**不符合**规则）
- pdf2：只有日期，例如 `20261025.pdf`

注意：浏览器重复下载同名文件会变成 `20261025 (1).pdf`，**这种不会被使用**。
Presenter 会把“含今天日期但不符合规则”的 PDF 列在状态提示和菜单里提醒你。pdf1 有多个文件符合时用最新的那个。

到时间就会自动启动、自动切换、12:15 自动退出。启动时内建屏上方会弹出几秒状态提示，确认：
- pdf1、pdf2 都是 ✅
- 投影屏 ✅

菜单栏图标随时显示状态：`⏱9:10`（等待）→ `👋欢迎页` → `📄3/12`（第 3 页 / 共 12 页）→ `🕐时钟` → `⏳1:23` → `📄1/20`。
图标前出现 **⚠️** 表示有问题（缺 PDF、读不了“下载”文件夹、没检测到投影屏、快捷键冲突），点开菜单看原因。

## 四、每周日 9:09 自动启动（crontab）

在 Air 的终端运行：

```bash
cd ~/Presenter
bash autostart.sh on 14:05 daily   # ① 先测试：把时间设成几分钟后
# 到点后看 Presenter 是否自动打开（会弹状态提示；当天时间表已结束时，它会提示后自动退出——这就说明启动成功了）
bash autostart.sh on               # ② 改回每周日 09:09
bash autostart.sh status           # 查看当前设置
```
- 第一次设置 crontab 时，macOS 可能弹出“终端想要管理您的电脑”，点“好”。
- 启动记录在 `~/Presenter/cron.log`。取消：`bash autostart.sh off`。
- cron 运行条件：**Mac 开机、已登录、没有锁屏、没有合盖睡眠**；错过时间不会补跑。建议：
  - 系统设置 › 锁定屏幕：屏幕保护程序/关闭显示器后“需要密码”设为较长时间或“永不”；
  - 或者让 Mac 每周日 9:05 自动唤醒：`sudo pmset repeat wakeorpoweron U 09:05:00`（取消：`sudo pmset repeat cancel`）。
- 9:09 时如果还有 Presenter 在运行（比如彩排没退出），会先把它关掉再启动。

## 五、彩排

```bash
killall Presenter; cd ~/Presenter && open Presenter.app --args --test
```
**程序已在运行时，带参数的 open 不会生效**，所以先 `killall`。

测试模式把整个时间表压缩成约 1 分钟：欢迎页 5 秒 → pdf1 15 秒 → 欢迎页 5 秒 → 时钟 6 秒 → 倒计时 10 秒 → pdf2 15 秒 → 自动退出。
“下载”里没有当天的 PDF 时，用 `pdf/sample.pdf` 代替。没接投影仪时，在本屏中间开小窗预览。

其他参数：
- `--countdown 90`：倒计时用 90 秒；`--pdftime 60`：每个 PDF 显示 60 秒（方便试翻页）
- `--at 10:28:00`：按真实时间表运行，但假装现在是 10:28:00（试某个切换点很方便，例如 `--at 10:17:50`、`--at 12:14:50`）
- `--date 20261101`：按某天的日期找 PDF

想看实时日志：`./Presenter.app/Contents/MacOS/Presenter --test`（按 Ctrl+C 结束）。

## 六、快捷键（全局，焦点在哪个程序都有效）

| 动作 | 默认快捷键 |
|---|---|
| 下一页 | `⌃⌥→` 或 `⌃⌥↓`（Control + Option + 方向键） |
| 上一页 | `⌃⌥←` 或 `⌃⌥↑` |
| 回到第一页 | `⌃⌥1` |
| 黑屏开/关 | `⌃⌥B` |
| 立即显示 PDF（当前时段的，或下一个） | `⌃⌥P` |
| 退出 Presenter | `⌃⌥Esc` |

菜单栏里还可以手动切到欢迎页、pdf1、时钟、倒计时、pdf2。
**手动切换只管到时间表的下一个时间点**，之后自动恢复按时间表。例如 9:11 按 `⌃⌥P` 提前显示 pdf1，10:18 照样回到欢迎页；
10:25 手动开始倒计时，倒计时完显示 pdf2，一直到 12:15。

**和 OBS 不冲突的保证：**
- 启动时程序会读取 OBS 的快捷键设置（`~/Library/Application Support/obs-studio`），与 OBS 相同的组合**不会启用**，菜单栏会标 ⚠️。
  菜单 › 快捷键 里会显示“已读取 N 个绑定”；你在 OBS 里设过快捷键而这里显示 0，说明没读到，请人工核对。
- 被其他软件占用的组合（例如 Rectangle、Magnet 等窗口管理工具常用 `⌃⌥←/→`）也会被检测出来并标 ⚠️。

**改快捷键**：编辑 `config.json` 里的 `hotkeys`，写法如 `"ctrl+alt+right"`、`"ctrl+cmd+n"`。
用翻页笔（多数发送 PageDown/PageUp）：在 `next` 里加 `"pagedown"`，`prev` 里加 `"pageup"`。
macOS 15 起不允许只用 Option（⌥）或 Option+Shift 的全局快捷键，组合里请带上 ctrl 或 cmd。

## 七、修改内容

- **Logo**：`images/LogoNew.png`（放在 `stage.html` 旁边也可以）；找不到就不显示。
- **欢迎页文字、时钟页文字**：编辑 `stage.html` 的 `<body>` 部分；倒计时提示语和结束语在 `<script>` 开头的“文字设置”里。
- **字号、颜色、留白**：`stage.html` 顶部 `:root` 里的变量（都有注释）。
- **预览**：浏览器直接打开 `stage.html`；地址后加 `?mode=welcome`、`?mode=clock`、`?mode=countdown&s=90`、`?mode=final`。
- **时间表、PDF 文件夹、文件名规则**：`config.json`。时间表可以增减项目，`show` 可用 `welcome`、`clock`、`countdown`、`quit` 或 `pdfs` 里的名字。

## 八、容错

- **晚开也行**：程序按当前时间直接进入对应画面，例如 10:29 打开就显示剩余倒计时，10:40 打开就显示 pdf2。12:15 之后打开会提示“今天的时间表已结束”并退出。
- **PDF 临时补上**：到点找不到 pdf1 → 继续显示欢迎页；找不到 pdf2 → 显示“敬拜马上开始!”；每 2 秒重试，文件一放进“下载”就自动显示（第 1 页）。
- **投影线松了**：窗口自动隐藏（不会跑到内建屏挡住 OBS），重新接上自动恢复。
- **不会休眠**：运行期间阻止系统休眠、显示器休眠和屏保。不要合上笔记本盖子。
- 出问题看菜单里的“查看日志”（`presenter.log`）。

## 文件说明

| 文件 | 作用 |
|---|---|
| `presenter.swift` | 程序源代码 |
| `build.sh` | 编译成 `Presenter.app`，并打包 `Presenter-ready.zip` |
| `config.json` | 时间表、PDF 文件夹和文件名规则、快捷键 |
| `stage.html` | 欢迎页、时钟页、倒计时画面 |
| `images/` | 放 `LogoNew.png` |
| `pdf/sample.pdf` | 仅测试模式使用 |
| `autostart.sh` | 用 crontab 设置/取消自动启动 |
| `presenter.log`、`cron.log` | 运行日志、自动启动记录（运行后生成） |
