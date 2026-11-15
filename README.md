# Presenter — 投影屏按时间表自动切换

内建屏放 OBS，外接投影屏由 Presenter 自动接管（时间都可以在 `config.json` 里改）：

| 时间 | 投影屏显示（全屏） |
|---|---|
| 09:10:00 | 欢迎页：居中显示 Logo 和中英文欢迎语，四周留白 10% |
| 启动时 | 从 Google Drive 指定文件夹把今天的两个 Google Slides 导出成 PDF，存进 `~/Downloads`（见第三节） |
| 09:12:00 | **pdf1**：`~/Downloads` 里符合 `^[A-Z][a-z]+-yyyymmdd.pdf$` 的文件（如 `Sunday-20261025.pdf`），第 1 页 |
| 10:18:00 | 关闭 pdf1，回到欢迎页（10:17 会先提醒，需要时按 `⌃⌥E` 延长） |
| 10:21:00 | 时钟页：Logo、固定文字、日期和当前时间（带秒），四周留白 10% |
| 10:28:30 | 其他不变，时间变成 90 秒倒计时（01:30 → 00:01） |
| 10:30:00 | **pdf2**：`~/Downloads/yyyymmdd.pdf`（如 `20261025.pdf`），第 1 页 |
| 10:40:00 | **每月第一个星期天**：实时翻译叠加在 pdf2 下方 1/5（`⌃⌥T` 随时手动显示/隐藏） |
| 12:15:00 | Presenter 自动退出（12:14 会先提醒，需要时按 `⌃⌥E` 延长） |

翻页用全局快捷键，焦点留在 OBS 也照样有效。投影窗口不会抢焦点，鼠标点击也会穿透。

---

## 一、编译（在有 Xcode 的 Mac 上）

```bash
mv ~/Downloads/Presenter ~/        # 解压出来的文件夹放到主目录（已有旧的就先删掉或改名）
cd ~/Presenter && bash build.sh
```
成功后主目录里会生成 `Presenter-ready.zip`（Apple 芯片版本，需要 macOS 11 及以上）。
只有改了 `presenter.swift` 才需要重新编译；改 `stage.html`、`config.json`、Logo 不用。

## 二、装到直播用的 MacBook Air

### 第一次安装

1. AirDrop `Presenter-ready.zip` 到 Air，解压后放到主目录 `~/Presenter`。
2. 终端运行：
   ```bash
   killall Presenter; xattr -dr com.apple.quarantine ~/Presenter
   ```
3. 把 `LogoNew.png` 放进 `~/Presenter/images/`。
4. **彩排一次**（见第七节）。第一次运行时系统会问 **“Presenter 想访问‘下载’文件夹中的文件”**，点 **“好/允许”**。
5. 系统设置 › 显示器：投影仪设为 **扩展显示器**（不要“镜像”）；建议内建屏作主显示器。
6. 设置每周日 9:09 自动启动（见第六节）。

### 从旧版本升级（保留 Logo 和自己改过的 stage.html）

AirDrop 新的 `Presenter-ready.zip` 到 Air，在“下载”里解压，然后终端运行：
```bash
killall Presenter
rm -rf ~/Presenter/Presenter.app
cp -R ~/Downloads/Presenter/Presenter.app ~/Downloads/Presenter/config.json ~/Downloads/Presenter/README.md ~/Presenter/
xattr -dr com.apple.quarantine ~/Presenter
rm -rf ~/Downloads/Presenter ~/Downloads/Presenter-ready.zip
```
只换 App、`config.json` 和说明；`images/LogoNew.png`、`stage.html`、crontab 设置都不动。
（如果你改过旧的 `config.json`，把改动抄到新的里；新的 `config.json` 里要填 `gdrive.folderId`，见第三节。）
`~/Presenter/rclone` 和 rclone 的登录设置也都不受影响。

**换上新版本后一定要先手动运行一次**（彩排即可），系统会再问一次能否访问“下载”文件夹，点“允许”；
否则周日自动启动时会卡在这个询问上。不小心点了“不允许”：系统设置 › 隐私与安全性 › 文件和文件夹 › Presenter，打开“下载文件夹”。

## 三、PDF 从哪里来：Google Drive 自动下载

### 每周要做的

只要在 Google Drive 那个文件夹里准备好两个 **Google Slides**，标题：
- pdf1：英文单词（首字母大写，其余小写）+ `-` + 日期，例如 `Sunday-20261025`、`Bible-20261025`
  （`SundaySchool-20261025` 这种中间有大写的**不符合**规则）
- pdf2：只有日期，例如 `20261025`

周日 Presenter 启动时会自动把它们导出成 `Sunday-20261025.pdf`、`20261025.pdf`，存进“下载”文件夹。不用再手动下载、改名。

**什么时候下载：**
- 启动时下载一次（云端没改过、“下载”里也已经有这个文件时会跳过）。
- 每个 PDF 开始前 4 分钟再检查一次（pdf2 是 10:26）：云端改过才重新下载，礼拜前临时改的 Slides 也能用上最新版。
- 菜单栏图标 › **从 Google Drive 重新下载**：随时手动再取一次。正在显示的 PDF 会换成新版，停在原来那一页。
- 到点时还在下载：先显示前一个画面（欢迎页 / “敬拜马上开始!”），下载好立刻显示，最多等 1 分钟。

**取不到时：** 没联网、云端没找到今天的 Slides、Google 出错……都会自动重试；仍然不行就用“下载”里已有的同名 PDF，菜单栏标 ⚠️，状态提示写明原因。
所以想保险的话，周六手动放一份 PDF 到“下载”，就是备份。

启动时内建屏上方会弹出几秒状态提示，下载完成后再弹一次，确认：
- Google Drive pdf1、pdf2 都是 ✅
- 投影屏 ✅
- 每月第一个星期天：实时翻译 ✅

注意：手动下载的 PDF，浏览器重复下载同名文件会变成 `20261025 (1).pdf`，**这种不会被使用**。
Presenter 会把“含今天日期但不符合规则”的 PDF 列在状态提示和菜单里提醒你。

### 一次性设置（已经做过 rclone 授权的话，只需要第 3、4 步）

1. **rclone 放在 Presenter 文件夹里**：`~/Presenter/rclone`（Presenter 会自动找到它）。第一次运行被系统拦时：`xattr -d com.apple.quarantine ~/Presenter/rclone`。
2. **授权 Google 账号**：`~/Presenter/rclone config`，远程名字用 `gdrive`，scope 选 `drive.readonly`，填自己建的 client_id / client_secret。
   Google Cloud 里的应用要设为 **“正式版”（In production）**，否则授权 7 天后失效。
3. **填文件夹 ID**：`config.json` 里 `"gdrive"` 的 `"folderId"`，填 Drive 文件夹网址里 `folders/` 后面那一串。
4. **测试**（周六晚上，按明天的日期下载）：
   ```bash
   killall Presenter; open ~/Presenter/Presenter.app --args --test --date 20261115
   ```
   状态提示里 Google Drive pdf1、pdf2 应该是 ✅，“下载”里出现两个 PDF。

**设置项**（`config.json` 的 `gdrive`）：`enabled`（false = 不下载）、`folderId`、`remote`（rclone 里的名字）、`rclone`（rclone 的位置，留空自动找）、
`recheckBeforeMinutes`（开始前几分钟再检查，0 = 不检查）、`waitSeconds`（到点时最多等几秒）。下载到 `pdfFolder`（默认“下载”）。

**授权失效时**（很少见：半年没用过、在 Google 账号里撤销了、应用没设成正式版）：状态里会显示连接 Google Drive 失败，运行一次
`~/Presenter/rclone config reconnect gdrive:` 重新登录即可。撤销授权：Google 账号 › 安全 › 第三方连接。

菜单栏图标随时显示状态：`⏱9:10`（等待）→ `👋欢迎页` → `📄3/12`（第 3 页 / 共 12 页）→ `🕐时钟` → `⏳1:23` → `📄1/20💬`（💬 = 正在显示实时翻译）。
延长时会显示到几点，如 `📄12/12→10:20`。图标前出现 **⚠️** 表示有问题，点开菜单看原因。

## 四、延长当前画面（例如 pdf1 那段超时）

- **10:17:00 起**（pdf1 结束前 60 秒），内建屏上方会出现**橙色提醒**：“⏰ 60 秒后（10:18:00）关闭 pdf1，切换到欢迎页”，并倒数秒数。
- 需要延长就按 **`⌃⌥E`**：当前画面延长 2 分钟（10:20），可以连按（10:22、10:24…）。延长后到新时间前 60 秒会再提醒一次。
- **不操作就照常 10:18 切换**。
- 错过了提醒、已经切到欢迎页：菜单栏图标 › **显示 pdf1**，会回到刚才那一页（15 分钟内），之后可以再按 `⌃⌥E` 延长。
- 延长后提前结束了：按 **`⌃⌥R`**（恢复按时间表），马上切到时间表现在该显示的画面。
- 延长超过后面的时间点时，中间的画面会跳过。例如 pdf1 延长到 10:22，就直接从 pdf1 切到时钟（10:21 起的那项）；倒计时照样 10:28:30 开始。
- pdf2 在 12:14 也会提醒，按 `⌃⌥E` 可以推迟 12:15 的自动退出。
- 每次延长几分钟、提前几秒提醒、哪些 PDF 要提醒：`config.json` 的 `extend`。
- 提醒框在内建屏（OBS 那块屏）上方，不抢焦点、鼠标点击会穿透，不会出现在投影上。

## 五、实时翻译字幕条

**每月第一个星期天**，pdf2 期间 **10:40 起**，实时翻译叠加显示在投影下方 1/5：
- PDF 保持全屏，字幕条盖在 PDF 的下方 1/5 上。**做 PDF 时，需要翻译的那些页把下方 1/5 留白**。
  投影和 PDF 都是 16:9 时正好对齐；比例不同时（PDF 上下有黑边），字幕条也不会盖住超过 PDF 下方 1/5 的内容。
- 字幕条黑底白字，显示最新的 3 行，自动更新。也可以改成透明背景、字直接写在留白处（见下面的设置）。
- 翻译网页 `https://app.withkaleo.com/c/oakville-chinese-hope-church` 在 10:38 自动在后台打开；Presenter 从网页里找出正在更新的文字，显示成大字。
  还没有文字时，字幕条显示暗色的“实时翻译 · Live Translation”。
- 网页载入失败会每 15 秒重试；文字超过 10 分钟没更新会自动重新载入网页。
- 网页的声音会被静音，不会混进直播。

**手动控制：**
- **`⌃⌥T`：按一下显示，再按一下隐藏**（同一个键来回切换）。任何一天、任何画面都可以用，例如 10:40 前提前打开、某几页没留白时先隐藏。
- 手动显示/隐藏只管到下一个自动开关时间为止：例如 10:35 手动打开、10:37 关掉，10:40 照样自动打开；10:45 手动隐藏后会一直隐藏，直到再按 `⌃⌥T`。
- 菜单栏图标 › 实时翻译：自动 / 显示 / 隐藏；显示方式；重新载入翻译网页等。

**如果字幕条显示的内容不对**（Kaleo 网页的结构我没法提前看到，文字是自动寻找的）：
1. 菜单栏图标 › 实时翻译 › **显示方式：原网页** —— 直接把网页放大显示在下方，作为备用。
2. 菜单栏图标 › 实时翻译 › **保存网页结构和截图** —— 在 Presenter 文件夹生成 `caption-dump-日期时间.html / .txt / .png`，发给我，我可以据此把文字区域设准（填到 `config.json` 的 `textSelector`）。请在**正在翻译的时候**保存。
3. 如果 Kaleo 网页第一次打开需要选语言等操作：菜单 › 实时翻译 › **打开可点击的翻译网页窗口**，选好后关掉窗口，再选“重新载入翻译网页”（设置会被记住）。

字幕条的设置都在 `config.json` 的 `caption`：
- 几点开始/停止：`"from": "10:40:00"`、`"to": ""`（留空 = 一直到 pdf2 结束）
- 哪些画面显示：例如 pdf1 期间也要翻译 `"showDuring": ["pdf1", "pdf2"]`
- 高度、行数：`"heightPercent": 20`、`"lines": 3`
- 透明背景、深蓝色字（适合浅色背景的 PDF）：`"background": "transparent"`、`"color": "#1a237e"`
  （浅色字会自动加黑色描边，深色字自动加白色描边）
- 不叠加、改成把 PDF 缩到上方 4/5：`"overlay": false`

## 六、每周日自动启动（crontab）

建议改成 **9:05** 启动，给 Google Drive 下载多留几分钟：`bash autostart.sh on 09:05`


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

## 七、彩排

```bash
killall Presenter; cd ~/Presenter && open Presenter.app --args --test
```
**程序已在运行时，带参数的 open 不会生效**，所以先 `killall`。

测试模式把整个时间表压缩成约 1 分钟：欢迎页 5 秒 → pdf1 15 秒 → 欢迎页 5 秒 → 时钟 6 秒 → 倒计时 10 秒 → pdf2 15 秒 → 自动退出。
测试模式里，PDF 结束前 5 秒提醒，`⌃⌥E` 每次延长 10 秒。
“下载”里没有当天的 PDF 时，用 `pdf/sample.pdf` 代替。没接投影仪时，在本屏中间开小窗预览。

其他参数：
- `--caption`：不管哪天都显示实时翻译（试字幕条用；测试模式不看 10:40，pdf2 一开始就显示）；`--nocaption`：不显示
- `--countdown 90`：倒计时用 90 秒；`--pdftime 60`：每个 PDF 显示 60 秒（方便试翻页、试延长）
- `--at 10:16:50`：按真实时间表运行，但假装现在是 10:16:50（试 10:17 的提醒和延长；`--at 10:39:30 --caption` 试 10:40 字幕条出现）
- `--date 20261101`：按某天的日期找 PDF（也按这个日期从 Google Drive 下载，周六晚上试明天的文件很方便）
- `--nogdrive`：这次不从 Google Drive 下载，只用“下载”里已有的文件

例：试字幕条 2 分钟 —— `killall Presenter; open Presenter.app --args --test --caption --pdftime 120`

想看实时日志：`./Presenter.app/Contents/MacOS/Presenter --test`（按 Ctrl+C 结束）。

## 八、快捷键（全局，焦点在哪个程序都有效）

| 动作 | 默认快捷键 |
|---|---|
| 下一页 | `⌃⌥→` 或 `⌃⌥↓`（Control + Option + 方向键） |
| 上一页 | `⌃⌥←` 或 `⌃⌥↑` |
| 回到第一页 | `⌃⌥1` |
| **延长当前画面**（每次 +2 分钟） | `⌃⌥E` |
| **恢复按时间表**（取消延长和手动切换） | `⌃⌥R` |
| **实时翻译 显示/隐藏** | `⌃⌥T` |
| 黑屏开/关 | `⌃⌥B` |
| 立即显示 PDF（当前时段的，或下一个） | `⌃⌥P` |
| 退出 Presenter | `⌃⌥Esc` |

菜单栏里还可以手动切到欢迎页、pdf1、时钟、倒计时、pdf2。
**手动切换只管到时间表的下一个时间点**，之后自动恢复按时间表。例如 9:11 按 `⌃⌥P` 提前显示 pdf1，10:18 照样回到欢迎页；
10:25 手动开始倒计时，倒计时完显示 pdf2，一直到 12:15。

**和 OBS 不冲突的保证：**
- 启动时程序会读取 OBS 的快捷键设置（`~/Library/Application Support/obs-studio`），与 OBS 相同的组合**不会启用**，菜单栏会标 ⚠️。
  菜单 › 快捷键 里会显示“已读取 N 个绑定”；你在 OBS 里设过快捷键而这里显示 0，说明没读到，请人工核对。
- 被其他软件占用的组合（例如 Rectangle、Magnet 等窗口管理工具常用 `⌃⌥←/→`、`⌃⌥E`）也会被检测出来并标 ⚠️。

**改快捷键**：编辑 `config.json` 里的 `hotkeys`，写法如 `"ctrl+alt+right"`、`"ctrl+cmd+n"`。
用翻页笔（多数发送 PageDown/PageUp）：在 `next` 里加 `"pagedown"`，`prev` 里加 `"pageup"`。
macOS 15 起不允许只用 Option（⌥）或 Option+Shift 的全局快捷键，组合里请带上 ctrl 或 cmd。

## 九、修改内容

- **Logo**：`images/LogoNew.png`（放在 `stage.html` 旁边也可以）；找不到就不显示。
- **欢迎页文字、时钟页文字**：编辑 `stage.html` 的 `<body>` 部分；倒计时提示语和结束语在 `<script>` 开头的“文字设置”里。
- **字号、颜色、留白**：`stage.html` 顶部 `:root` 里的变量（都有注释）。
- **预览**：浏览器直接打开 `stage.html`；地址后加 `?mode=welcome`、`?mode=clock`、`?mode=countdown&s=90`、`?mode=final`。
- **时间表、PDF 文件夹、文件名规则、延长、实时翻译**：`config.json`。时间表可以增减项目，`show` 可用 `welcome`、`clock`、`countdown`、`quit` 或 `pdfs` 里的名字。

## 十、容错

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
| `config.json` | 时间表、PDF 文件夹和文件名规则、延长、实时翻译、快捷键 |
| `stage.html` | 欢迎页、时钟页、倒计时画面 |
| `images/` | 放 `LogoNew.png` |
| `pdf/sample.pdf` | 仅测试模式使用 |
| `autostart.sh` | 用 crontab 设置/取消自动启动 |
| `rclone` | 从 Google Drive 下载用的工具（自己放进来） |
| `gdrive-state.json` | 记录上次从 Google Drive 下载的版本（运行后生成，删掉也没关系） |
| `presenter.log`、`cron.log` | 运行日志、自动启动记录（运行后生成） |
| `caption-dump-*` | “保存网页结构和截图”生成的文件（调整实时翻译用） |
