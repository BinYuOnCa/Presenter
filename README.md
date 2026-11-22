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

（菜单和提示里，pdf1 显示为 **主日学**、pdf2 显示为 **敬拜**；名字可在 `config.json` 的 `pdfNames` 里改。）

---

## 一、编译和发布（在有 Xcode 的 Mac 上）

```bash
git clone https://github.com/BinYuOnCa/Presenter.git ~/GitRepos/Presenter   # 源代码在 main 分支
cd ~/GitRepos/Presenter
./build.sh                  # 只编译，并打包 Presenter-ready.zip（给没有 git 的电脑用）
./build.sh --release        # 编译 + 发布到 GitHub 的 release 分支，直播电脑运行 ./presenter.sh update 就能更新
```
- `--release` 要求源代码已提交（发布的每个版本都写明对应的源代码版本 `main@提交号`），记得也 `git push` main。
- release 分支只保留最近 10 个版本（`KEEP_RELEASES=20 ./build.sh --release` 可以改），所以仓库不会越来越大。
  要更早的版本：`git checkout <提交号>` 切到那个源代码版本，重新 `./build.sh` 即可。
- 发布和打包的内容只有：`Presenter.app`、`config.json`、`config-local.example.json`、`stage.html`、两个通用术语表、`presenter.sh`、说明文档。
  **不含**任何 `*-local.*` 文件、服务账号密钥、rclone、日志和字幕记录。
- 只有改了 `presenter.swift` 才需要重新编译；改 `config-local.json`、`stage-local.html`、术语表、Logo 不用。

## 二、装到直播用的 MacBook Air（或其他电脑）

所有文件都在 `~/Presenter`。通用的文件来自 release 分支，`./presenter.sh update` 会更新它们；
这台电脑/本教会自己的东西放在 **`*-local.*`** 文件里，更新时不会动：

| 本机文件 | 内容 |
|---|---|
| `config-local.json` | 覆盖 `config.json` 的设置：Drive 文件夹 ID、服务账号密钥、Kaleo 网页、音频输入设备等（照 `config-local.example.json` 写） |
| `glossary-local.csv` | 教会自己的术语表（教会名、牧者同工、团契） |
| `stage-local.html` | 本教会的欢迎页、时钟页（从 `stage.html` 复制后修改；有它就不用 `stage.html`） |
| `images/LogoNew.png` | Logo |
| `gdrive-sa.json` | Google 服务账号密钥（凭证，**只**放在这台电脑上，见第三节） |
| `rclone` | 从 Google Drive 下载用的工具 |

### 第一次安装

1. 装 git（Mac 自带的 git 第一次用要装命令行工具）：`xcode-select --install`
2. 下载程序：
   ```bash
   git clone --depth 1 -b release https://github.com/BinYuOnCa/Presenter.git ~/Presenter
   ```
3. 把本机文件放进 `~/Presenter`（从旧电脑 AirDrop 过来，或按上表新建）：`config-local.json`、`glossary-local.csv`、`stage-local.html`、`images/LogoNew.png`；
   再按第三节放 `rclone` 和 `gdrive-sa.json`。
4. **彩排一次**：`~/Presenter/presenter.sh test tomorrow`。第一次运行时系统会问 **“Presenter 想访问‘下载’文件夹中的文件”**，点 **“好/允许”**。
5. 系统设置 › 显示器：投影仪设为 **扩展显示器**（不要“镜像”）；建议内建屏作主显示器。
6. 设置每周日自动启动：`~/Presenter/presenter.sh autostart on 09:05`（见第六节）。

### 升级

```bash
~/Presenter/presenter.sh update
```
从 release 分支取最新版本，只替换通用的文件；`*-local.*`、Logo、凭证、rclone、字幕记录、crontab 都不动。
通用的文件（如 `config.json`、`stage.html`）如果在本机改过，会先备份成 `.bak`，请把改动搬到对应的 `*-local` 文件里。

**从 v2.4 及以前（用 zip 安装的）改成用 git 升级**，在 Air 上运行一次：
```bash
cd ~/Presenter
mv -n glossary.csv glossary-local.csv     # 旧的 glossary.csv 是教会自己的术语表
mv -n stage.html stage-local.html         # 改过欢迎页/时钟页的话
curl -fsSLO https://raw.githubusercontent.com/BinYuOnCa/Presenter/release/presenter.sh && chmod +x presenter.sh
./presenter.sh update                     # 把这个文件夹接到 release 分支；改过的 config.json 备份成 config.json.bak
```
然后照 `config-local.example.json` 建 `config-local.json`，把 `config.json.bak` 里自己改过的设置（`gdrive.folderId`、`gdrive.remote`、音频输入等）写进去。
已有的 crontab 不用重设。

**换上新版本后一定要先手动运行一次**（`./presenter.sh test tomorrow`），系统会再问一次能否访问“下载”文件夹，点“允许”；
否则周日自动启动时会卡在这个询问上。不小心点了“不允许”：系统设置 › 隐私与安全性 › 文件和文件夹 › Presenter，打开“下载文件夹”。

没有 git 的电脑也可以用 `Presenter-ready.zip`：解压到 `~/Presenter`，运行 `xattr -dr com.apple.quarantine ~/Presenter`；升级时同样解压覆盖（`*-local.*` 不在 zip 里，不会被覆盖）。

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

**星期五、六：** 云端和“下载”里都没有今天日期的文件，就顺延用接下来那个星期天日期的（例如星期六 20261121 用 `Sunday-20261122`、`20261122`；今日术语 `terms-` 也一样）。周五、周六彩排不用加 `--date` 也能看到这个主日的 PDF。有今天日期的文件时总是用今天的。日志和状态提示里会注明“今天没有，用星期天 20261122 的”。星期一到四不做顺延查找。哪几天顺延：`config.json` 的 `"nextSundayOn": ["fri", "sat"]`（`[]` = 不顺延）。

**取不到时：** 没联网、云端没找到今天的 Slides、Google 出错……都会自动重试；仍然不行就用“下载”里已有的同名 PDF，菜单栏标 ⚠️，状态提示写明原因。
所以想保险的话，周六手动放一份 PDF 到“下载”，就是备份。

启动时内建屏上方会弹出几秒状态提示，下载完成后再弹一次，确认：
- Google Drive pdf1、pdf2 都是 ✅
- 投影屏 ✅
- 每月第一个星期天：实时翻译 ✅

注意：手动下载的 PDF，浏览器重复下载同名文件会变成 `20261025 (1).pdf`，**这种不会被使用**。
Presenter 会把“含今天日期但不符合规则”的 PDF 列在状态提示和菜单里提醒你。

### 一次性设置

1. **rclone 放在 Presenter 文件夹里**：`~/Presenter/rclone`（Presenter 会自动找到它；也可以 `brew install rclone`）。第一次运行被系统拦时：`xattr -d com.apple.quarantine ~/Presenter/rclone`。
2. **建 Google 服务账号**（推荐；不用登录、不会过期，而且只能看到共享给它的文件夹）：
   1. [Google Cloud Console](https://console.cloud.google.com/) 新建（或选一个）项目 › “API 和服务” › 启用 **Google Drive API**。
   2. “IAM 和管理” › 服务账号 › 创建服务账号（名字随意，不用给角色）。
   3. 打开这个服务账号 › 密钥 › 添加密钥 › 创建新密钥 › JSON，下载的文件改名为 **`gdrive-sa.json`**，放进 `~/Presenter/`。
      这个文件就是凭证：只放在直播电脑上，不要发到群里、不要放进仓库（`.gitignore` 已排除，`build.sh` 也不会打包它）。
   4. 在 Google Drive 里把放 Slides 的那个文件夹 **共享** 给服务账号的邮箱（`xxx@项目名.iam.gserviceaccount.com`，在密钥文件的 `client_email` 里），权限“查看者”。
3. **写进 `config-local.json`**（没有就复制 `config-local.example.json`）：
   ```json
   "gdrive": { "folderId": "Drive 文件夹网址里 folders/ 后面那一串", "serviceAccountFile": "gdrive-sa.json" }
   ```
   用了服务账号就**不需要** `rclone config`。
4. **测试**（周六晚上，按明天的日期下载）：
   ```bash
   ~/Presenter/presenter.sh test tomorrow
   ```
   状态提示里 Google Drive pdf1、pdf2 应该是 ✅，“下载”里出现两个 PDF。

**不用服务账号**（旧做法，用自己的 Google 账号）：`~/Presenter/rclone config` 建一个远程（scope 选 `drive.readonly`，填自己建的 client_id / client_secret，
Google Cloud 里的应用要设为“正式版”，否则 7 天后失效），然后在 `config-local.json` 里写 `"gdrive": { "folderId": "…", "remote": "远程名字" }`，不写 `serviceAccountFile`。
授权失效时运行 `~/Presenter/rclone config reconnect 远程名字:` 重新登录。

**设置项**（`gdrive`，本机的写在 `config-local.json`）：`enabled`（false = 不下载）、`folderId`、`serviceAccountFile`（服务账号密钥，相对于 Presenter 文件夹）、
`remote`（不用服务账号时 rclone 里的名字）、`rclone`（rclone 的位置，留空自动找）、`recheckBeforeMinutes`（开始前几分钟再检查，0 = 不检查）、`waitSeconds`（到点时最多等几秒）。下载到 `pdfFolder`（默认“下载”）。

**连不上时**：没联网；或者密钥被删了（Cloud Console 里重新建一个密钥替换 `gdrive-sa.json`）；或者文件夹没共享给服务账号的邮箱。

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
- 字幕条黑底白字，显示最新的 3 行。**字从左到右写，一行写满就整行向上滚动**（像电视直播字幕），已经写完的行不再变动，方便边听边读；只有最下面正在说的那一行会随识别结果微调。左右各留白 10%。也可以改成透明背景、字直接写在留白处（见下面的设置）。
- **同时叠加到直播视频上**：OBS 加一个“浏览器”来源，无论切到哪个摄像头或画面，线上都能看到字幕，见下面“OBS 字幕叠加”。
- 字幕有两种来源，**随时可以切换**（`⌃⌥S`，或菜单栏图标 › 实时翻译 › 字幕来源），同一时间只显示其中一种：
  - **Kaleo 网页**（默认）：见下面这几条。
  - **本机识别 + 翻译（Apple）**：Air 自己听调音台的声音，转成文字再翻译，不用联网，见下一小节。
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

### 本机识别 + 翻译（Apple）

Air 自己从 **Maono ProStudio 2x2 Lite**（和 OBS 同一个输入，互不影响）听讲台的声音，用 macOS 26 自带的语音识别转成文字，再用 Apple 翻译翻成另一种语言，显示在同一条字幕条里。全部在本机完成，不联网、不收费，对推流的负担很小。

- **显示方式**（默认“原文 + 译文”）：最上面一行是原文（稍暗，一边说一边出字），下面两行是译文（每句话说完后约 2–3 秒出现）。
  也可以只显示译文或只显示原文：快捷键 `⌃⌥Y` 只显示译文、`⌃⌥O` 只显示原文、`⌃⌥A` 原文 + 译文，或菜单栏图标 › 实时翻译 › 显示。
- **识别语言**：默认识别普通话、翻成英语。讲员说英语时按 **`⌃⌥L`** 切换成“识别英语、翻成中文”，再按一次切回。
- 15 秒没人说话会清空字幕条（显示暗色的“实时翻译 · Live Translation”）。
- 字幕开始前 2 分钟自动启动识别（例如 10:38），不需要显示字幕时自动停止。
- 菜单栏图标显示 🎙 表示正在显示本机识别的字幕（💬 是 Kaleo）。

**第一次使用前的准备（在 Air 上，只做一次）：**
1. **下载翻译语言**：系统设置 › 通用 › 语言与地区 › 翻译语言，下载 **中文（普通话）** 和 **英语**。
2. **试一次**（用本机识别作字幕来源，每个 PDF 显示 5 分钟）：
   ```bash
   ~/Presenter/presenter.sh test --apple --pdftime 300
   ```
   预览窗出现后按 **`⌃⌥T`** 马上显示字幕条。
   - 第一次会询问 **“麦克风”** 和 **“语音识别”** 权限，都点“允许”。
   - 第一次还会自动下载识别模型（几分钟，需要联网），菜单 › 实时翻译 › “本机识别”那一行会显示进度。
   - 对着讲台麦克风说几句，看字幕条是否出现原文和译文。
3. 想让本机识别成为默认来源：`config.json` 里 `caption` 的 `"source"` 改成 `"apple"`。

**常见问题：**
- 菜单里“本机识别”显示 ⚠️ 找不到 “Maono ProStudio 2x2 Lite”：会改用系统默认输入，日志里列出了现有的输入设备名字，把正确的名字填到 `config-local.json` 的 `caption.apple.inputDevice`（`config.json` 默认留空 = 系统默认输入）。
- 讲台麦克风只接在第 1 路输入：`"channel": 1`（默认 0 = 两路混在一起）。
- 显示“翻译语言还没下载”：做上面第 1 步，然后按两次 `⌃⌥S`（切走再切回）重新开始。
- 识别准确度主要看音质：调音台给的干净讲台信号最好。人名、地名、专有名词认错或翻错：见下一小节“提高翻译质量”。
- 需要 macOS 26 和 Xcode 26 编译。用旧版 Xcode 编译时，编译脚本会提示“不包含本机识别功能”，其他功能照常。

### 自动补标点（只对本机识别有效）

讲员语速快时，识别结果常常很长一串没有标点，既难读、也影响翻译。Presenter 会按讲员的停顿自动补标点：
- 识别结果里有每个词的时间，Presenter 同时自己听音量、记下安静的时段；两个词之间停顿超过 **0.3 秒补“，”**，超过 **0.8 秒补“。”**。已经有标点的地方不补。
- 默认只对普通话（`caption.apple.autoPunctuation`：`zh`；`all` = 英语也补；`off` = 不补）。
- 标点还是太少：把 `pauseComma` / `pausePeriod` 调小（例如 `0.25` / `0.6`）；太多就调大。调好的效果在字幕记录里能看到。
- 整句翻译遇到很长、一直没有句号的句子，等到 7 秒时会在最后一个逗号处断开，前半句先翻。
- 判断“安静”的标准会随现场音量自动调整（取最近约半分钟音量的低处和高处的中间）。识别开始后的头几十秒数据还不够，补的标点会少一些；字幕在 10:40 出现、识别 10:38 就开始，所以一般不影响。
- 日志里会有一行“本机识别：按停顿补标点（这段的词在 x–y 秒，音频已到 z 秒）”：两个时间差不多说明时间对得上；如果写“识别结果没有词的时间”，就只在每段之间补逗号。

### 提高翻译质量：术语表、整句翻译、字幕记录（只对本机识别有效）

本机识别有四个帮助提高质量的功能，默认都已打开：

**1. 整句翻译（`⌃⌥J` 开/关）**
原文还是一边说一边出字；译文等一句话说完（句号、问号，或停顿 1.2 秒，最长等 7 秒）再整句翻译。翻译时有完整的上下文，人名、代词更准，代价是译文晚一两秒出现。
讲得很快、句子很长、觉得译文太慢时，按 `⌃⌥J` 关掉（每一段马上翻），再按一次打开。菜单 › 实时翻译 里也能切换。

**2. 高保真翻译**
菜单 › 实时翻译 › 翻译质量：**高保真**（默认）/ **快速**。高保真在 Apple Intelligence 打开时用它的模型翻译（质量更好），没打开时自动用普通模型，和“快速”一样。
- 要真正用上：Air 的 系统设置 › Apple Intelligence 与 Siri，打开 Apple Intelligence（M1 支持；第一次要下载模型）。
- 菜单里会显示“翻译平均 x 秒/句”。如果 Air 和 OBS 一起跑变慢、发热，或者译文太慢，改成“快速”。

**3. 术语表**（`glossary-local.csv`、`glossary-bible.csv`、`glossary.csv`，在 Presenter 文件夹里）
- 识别出来先**纠错**：第 3 列写了的错误写法会改成正确的字（投影上的原文也显示正确的字）。
- 翻译前把中文术语**换成固定的英文译名**再翻译（英文讲员时反过来），译名就不会每次不一样。
三个术语表，优先级从高到低：
- `glossary-local.csv`：教会自己的词（教会名字、牧者同工姓名、团契事工），**不放进仓库**，优先级最高。里面已经放了教会名字作例子，牧者同工的名字请按真实的改。
- `glossary-bible.csv`：圣经 66 卷书名、常见人名、地名和教会用语（和合本 → NIV 译法），以后还会加入常见神学用语；升级时可以直接覆盖。
- `glossary.csv`：一般用语（与圣经和本教会无关，例如本地地名），优先级最低；升级时可以直接覆盖。
- 用 **TextEdit** 编辑（菜单 › 实时翻译 › 术语表和字幕记录 › 打开教会术语表，打开的是 `glossary-local.csv`）。不要用 Numbers 打开再保存，会变成 `.numbers` 文件。也可以用 Excel 编辑后“另存为 CSV UTF-8”。
- **保存后几秒内自动生效**，不用重开 Presenter（正在识别时，下一句开始用新的术语表）。

每行一个词，用逗号分开：

```
中文,English,中文常被识别成,英文常被识别成,方向
以利亚,Elijah,一里亚|伊利亚
王约翰牧师,Pastor John Wang,王约汉牧师
诗篇,Psalm,,,中→英
!一粒沙
```
- 第 3 列（中文识别错的写法）、第 4 列（英文讲员时英文识别错的写法）：多个用 `|` 分开，可以不填。
- 第 5 列方向：不填 = 双向；`中→英` = 只在中文翻英文时替换（书卷名用这个，免得英文讲员说 Job、Acts 时被换成书卷名）。
- 只写中文、不写英文：不指定译名，只是保护这个词不被拆开（例如名字“王约翰”里的“约翰”不会被单独换成 John）。
- `!` 开头的行：这几个字**永远不自动改**（读音纠正改错时用）。
- `#` 开头的行是注释。中文逗号、Tab 分隔也可以。

**4. 今日术语和读音纠正**
每周的讲道会有一些只用这一次的名字。Presenter 把下面这些当成“今日术语”：
- **今天 PDF 里出现的术语**：Presenter 读出主日学和敬拜 PDF 里的文字，术语表里的词出现在 PDF 里，就算今日术语；PDF 里“讲员：王约翰牧师”这类行里的名字也算。全自动，不用做什么。
- **今日术语文件**（可选）：在 Google Drive 放 Slides 的那个文件夹里建一个 **Google 表格**，标题 `terms-20261122`（当天日期），A 列中文、B 列英文、C 列常被识别成。Presenter 启动时和敬拜前会和 PDF 一起把它下载到“下载”文件夹（`terms-20261122.csv`）。
  也可以用 Google 文档（每行 `以利沙, Elisha` 或 `以利沙 Elisha`），或者直接把 `terms-20261122.csv` / `.txt` 放进 Presenter 文件夹或“下载”文件夹。格式和 `glossary-local.csv` 一样，而且优先于所有术语表。

今日术语多了一种纠正：**读音相同就自动改**（不看声调，三个字以上的词）。例如今天讲以利沙，识别成“衣里沙”会自动改成“以利沙”。
但像“哥哥他”（各各他）、“八十八”（拔示巴）、“一粒沙”（以利沙）这样本身就是普通词语的，**不会自动改**，只在字幕记录里记成“可能是…？”，留给你复查时决定。
（两个字的词读音相同的太多，不做读音纠正；需要时把错误写法写进第 3 列。）

**字幕记录**
每次用本机识别，Presenter 都把识别和翻译存到 `transcripts/` 文件夹，按时段分文件（`config.json` 的 `transcripts`，可以自己改）：

| 时段 | 文件名 | 例子 |
| --- | --- | --- |
| 星期天 9:15–10:25 | 书卷名_日期（书卷名取自 pdf1 的文件名，去掉日期） | `Genesis_20261122.txt`（pdf1 是 `Genesis-20261122.pdf`） |
| 星期天 10:30–12:10 | Worship_日期 | `Worship_20261122.txt` |
| 其他时间 | transcript_日期_小时（24 小时制） | `transcript_20261122_14.txt` |

```json
"transcripts": {
  "files": [
    { "days": ["sun"], "from": "09:15", "to": "10:25", "name": "{pdf1}_{date}" },
    { "days": ["sun"], "from": "10:30", "to": "12:10", "name": "Worship_{date}" }
  ],
  "default": "transcript_{date}_{hour}"
}
```
- `files` 从上往下找第一条符合的；`days` 写 `sun` `mon` `tue` `wed` `thu` `fri` `sat`（也可写“周日”“周一”…），不写 = 每天；`from` 含、`to` 不含（10:25:00 起算下一段）。
- `name` 里可用 `{date}`（yyyymmdd）、`{hour}`（两位小时）、`{pdf1}` / `{pdf2}`（那个 PDF 的文件名去掉日期和 `.pdf`；找不到 PDF 时用 `pdfNames` 里的名字）。`.txt` 自动加上。
- 写错的项启动时在菜单栏标 ⚠️ 并跳过；启动日志里列出每条规则。

每句一段：

```
[10:41:05]
原：今天我们来看衣里沙的故事
改：今天我们来看以利沙的故事	【衣里沙→以利沙（读音）】
送：今天我们来看 Elisha 的故事
译：Today we look at the story of Elisha.
```
`原` = 识别出来的原文；`改` = 纠正后（后面是改了什么，没改就没有这一行）；`送` = 送去翻译的文字（术语已换成译名）；`译` = 译文。
每段开头的 `=====` 行记着当时的设置（语言、整句翻译、翻译质量），下面一行 `参数：` 记着当时生效的全部识别参数，再下面是用了哪些术语表、今日术语：
```
===== 2026-11-22 10:40:12 本机识别：普通话 → 英语（zh-CN→en-US） · 整句翻译开 · 翻译高保真 =====
参数：source=apple  language=zh-CN  translateTo=auto  display=both  inputDevice="Maono ProStudio 2x2 Lite"  channel=0  clearAfterSeconds=15  sentenceMode=true  sentenceMaxSeconds=7  sentencePauseSeconds=1.2  translationQuality=high  autoPunctuation=zh  pauseComma=0.3  pausePeriod=0.8  glossary=true  beforeTranslation=true  fuzzy=today  fuzzyMinLength=3  captionLines=3
```
参数名和 `config.json` 的 `caption.apple` / `glossary` 里一样，方便以后对照不同讲员的语速调整（例如某位讲员讲得快、标点太少，就把那天的 `pauseComma` / `pausePeriod` 调小再比较）。
开始识别、换语言、切换整句翻译 / 翻译质量 / 显示方式、术语表重新载入、开关后台识别时都会再写一段；换到另一个文件时，新文件开头也会写，每个文件都能单独复查。

**后台识别并记录（`⌃⌥M`，菜单 › 实时翻译 里也能开关）**
**默认一启动就打开**：本机识别一直在后台运行，结果照常写进上面的字幕记录，**不管实时翻译显示没显示、字幕来源是哪个**。按 `⌃⌥M` 关闭（关闭后只在要显示本机识别字幕时才识别），再按一次打开。
- 不想默认打开：`config.json`（或 `config-local.json`）的 `caption.apple` 里写 `"backgroundTranscribe": false`；只是这次不开：启动参数 `--nobackground`。
- 启动提示和日志里会写“后台识别：✅ 开”。本机识别不可用（macOS 26 以下）或 `saveTranscript` 是 `false` 时不打开。
- 字幕来源是 Kaleo 时，投影和 OBS 上照样显示 Kaleo 的字幕；Kaleo 网页也一直保持载入，它的文字另存一个文件，文件名后面加 `_Kaleo`，例如 `Worship_20261122.txt`（本机识别）和 `Worship_20261122_Kaleo.txt`（Kaleo），方便逐段对比两边的识别和翻译：
  ```
  [10:41:05]
  Kaleo：Today we look at the story of Elisha. He followed Elijah...
  ```
  Kaleo 的文字一句说完（或攒到 300 字、或 20 秒）写一段；停止后台识别、切换字幕来源、退出 Presenter 时，把最后还没写的也写进去。
- 字幕记录的 `参数：` 行会记 `source=kaleo … background=true`。
- `*_Kaleo.txt` 不参加复查（格式不同）。
- 后台识别一直在跑，Air 会比只开 Kaleo 多用一些电和 CPU；第一次运行时系统会问麦克风和语音识别权限，要点“允许”。
- 用 `⌃⌥M` 关掉后，重开 Presenter 又会按设置打开。

#### 从字幕记录整理术语表：具体步骤（每个用本机识别的主日后，约 10–15 分钟）

**第 1 步：生成复查报告**
- Presenter 还在运行：菜单 › 实时翻译 › 术语表和字幕记录 › **复查最近一天的字幕记录**。
- 已经退出（12:15 以后）：终端运行
  ```bash
  ~/Presenter/presenter.sh review              # 最近一天的字幕记录
  ~/Presenter/presenter.sh review 20261115     # 某一天的
  ```
  不会投影，只做复查。同一天的几个文件（例如 `Genesis_20261115.txt`、`Worship_20261115.txt`）合在一起复查。几十秒到一两分钟后，`transcripts/review-20261115.txt` 会自动用 TextEdit 打开，Presenter 随后自己退出。

报告有三部分：

**第 2 步：看“一、译文里的人名、地名”**（还不在术语表里的，按出现次数排列，每个带一句例子）
```
  Wang Yuehan ×3（像拼音：多半是没认出的中文名字）
     例：[10:41:05] 今天由王约汉牧师讲道
         Today, Pastor Wang Yuehan preached
```
对每一个判断：
- 是人名/地名，译文不对（像拼音、或译错了）→ 在 `glossary-local.csv` 加一行 `中文,正确的英文`。
- 原文的字也听错了（例子里“约汉”应该是“约翰”）→ 同时把错的写法放进第 3 列：`王约翰牧师,Pastor John Wang,王约汉牧师`。
- 译文本来就对（例如 Toronto）→ 不用管；想固定下来也可以加一行。
- 只在这一次讲道出现的（例如客座讲员的家乡）→ 不加也行，或者下次放进当天的今日术语。

**第 3 步：看“二、自动纠正”**
- **已改**：确认每一条都改对了。
  - 改错了（例如讲的是沙子，“一粒沙”却被改成“以利沙”）→ `glossary-local.csv` 加一行 `!一粒沙`，以后不再改。
  - 某个第 3 列的写法本身是常用词、老是误改 → 把它从第 3 列删掉。
- **可能听错**（读音相同但像普通词语，没有改）：
  - 确实是听错，而且这个错误写法平时不会出现 → 加到那个词的第 3 列，例如 `以利亚,Elijah,一里亚`。
  - 这个写法平时也会说（“哥哥他”“八十八”）→ 不要加到术语表，否则以后每次都会被改。不管它，或者只在讲那段经文的那周写进今日术语文件的第 3 列。

**第 4 步：顺便扫一眼字幕记录本身**（可选）
用 TextEdit 打开 `transcripts/` 里那天的字幕记录（如 `Worship_20261115.txt`），按 ⌘F 搜关键的人名、地名，或者快速看几段 `原`/`译`：

| 字幕记录里看到 | 是什么问题 | `glossary-local.csv` 里怎么写 |
|---|---|---|
| `原：……一里亚……`（应是以利亚） | 识别错（字错了） | `以利亚,Elijah,一里亚`（这个词已经有一行就在那行第 3 列加，多个用 `\|` 分开） |
| `原` 是对的，`译` 里成了 Yi Liya | 翻译错 | `以利亚,Elijah` |
| `送` 里的英文词让 `译` 变得别扭 | 这个词不适合翻译前替换 | 改成只写中文：`那个词,`；或者第 5 列写 `英→中` |
| `改` 把对的字改错了 | 误改 | `!那几个字` |
| 英文讲员：`原：……Oak Ville……` | 英文识别错 | `橡城,Oakville,,Oak Ville` |

`glossary-bible.csv` / `glossary.csv` 里已有的词要加错误写法：在 `glossary-local.csv` 里写一行同样的中文，**英文也要写上**，例如 `以利沙,Elisha,一粒沙`（`glossary-local.csv` 优先）。

**第 5 步：保存，再复查一次**
保存 `glossary-local.csv` 后，重复第 1 步。报告的“三、用现在的术语表重新处理，结果有变化的句子”会列出每一句的 `旧改/新改`、`新送`、`旧译/新译`（用新的术语表重新翻译过）：
- 新的都对 → 完成，下次自动用上。
- 有新问题（例如某个词替换后译文反而别扭）→ 调整那一行，再复查。

**主日前（可选，5 分钟）**：知道讲道会提到哪些不常见的名字（讲员、经文里的人名地名）时，在 Google Drive 建 `terms-日期` 表格写上，当天的识别和翻译就会用上（见上面“今日术语”）。

**相关设置**（`config.json`）：
- `caption.apple`：`sentenceMode`（整句翻译）、`sentenceMaxSeconds`（最多等几秒）、`sentencePauseSeconds`（停顿几秒算一句）、`translationQuality`（`high` / `fast`）、`saveTranscript`（存字幕记录）。
- `glossary`：`files`（术语表文件，前面的优先）、`beforeTranslation`（翻译前替换）、`fuzzy`（读音纠正：`today` 只对今日术语 / `all` / `off`）、`fuzzyMinLength`、`pdfTerms`（从 PDF 找今日术语）、`termsFile`（今日术语文件名规则）、`fromGoogleDrive`。

### OBS 字幕叠加（线上听众也能看到字幕）

Presenter 运行时会在本机提供一个字幕网页：**`http://127.0.0.1:8765/caption`**。网页背景透明，只有底部一条半透明黑底白字的字幕条（同样逐行向上滚动）；没有字幕、Presenter 没在运行时自动隐藏。Kaleo 和本机识别两种来源都可以用。

**在 OBS 里设置（只做一次）：**
1. 场景列表 › **+** › 新建一个场景，名字叫“字幕叠加”。
2. 在“字幕叠加”场景里：来源 › **+** › **浏览器**（Browser）：
   - URL：`http://127.0.0.1:8765/caption`（菜单栏图标 › 实时翻译 › 复制 OBS 字幕网址）
   - 宽度、高度：和 OBS 的画布一样（设置 › 视频 › 基础（画布）分辨率），例如 1920 × 1080
   - “不可见时关闭源”“场景激活时刷新浏览器”都**不要勾**
3. 到每一个直播用的场景里：来源 › **+** › **场景** › 选“字幕叠加”，拖到来源列表**最上面**。以后新建场景也记得加。
   （装了 Downstream Keyer 插件的话，也可以只在插件里加一次，所有场景都会有。）
4. 试一下：`~/Presenter/presenter.sh test --apple --caption --pdftime 300`，在 OBS 预览里看字幕条出现、切换场景字幕还在。
   不开 OBS 也可以先看效果：菜单栏图标 › 实时翻译 › 在浏览器里预览 OBS 字幕页。

**显示/隐藏：** 默认跟投影字幕条一起（10:40 自动出现，`⌃⌥T` 两边一起开关）。想让线上在字幕时段内一直有字幕（例如某几页 PDF 没留白，只在投影上按 `⌃⌥T` 隐藏）：菜单 › 实时翻译 › “OBS 字幕：字幕时段内一直显示”，或 `config.json` 的 `obs.visibility` 改成 `"auto"`。

**样式**（`config.json` 的 `obs`）：`lines`（行数，默认 3：原文 + 译文时原文 1 行、译文 2 行）、`heightPercent`（占视频高度，默认 15）、`bottomPercent`（离底边，默认 4）、`marginPercent`（左右留白，默认 10）、`background`（默认 `rgba(0,0,0,0.55)`，最后一个数是不透明度）、`color`。显示原文/译文跟投影一样（`⌃⌥A` / `⌃⌥Y` / `⌃⌥O`）。

**菜单里的状态：** “OBS 字幕叠加：✅ http://127.0.0.1:8765/caption（OBS 已连接）”。显示“端口可能被占用”：把 `obs.port` 改成别的数（如 8766），OBS 里的网址也跟着改。

### 字幕条设置

字幕条的设置都在 `config.json` 的 `caption`：
- 几点开始/停止：`"from": "10:40:00"`、`"to": ""`（留空 = 一直到 pdf2 结束）
- 哪些画面显示：例如 pdf1 期间也要翻译 `"showDuring": ["pdf1", "pdf2"]`
- 高度、行数：`"heightPercent": 20`、`"lines": 3`
- 左右留白：`"marginPercent": 10`（各留屏幕宽度的 10%）
- 透明背景、深蓝色字（适合浅色背景的 PDF）：`"background": "transparent"`、`"color": "#1a237e"`
  （浅色字会自动加黑色描边，深色字自动加白色描边）
- 不叠加、改成把 PDF 缩到上方 4/5：`"overlay": false`

## 六、每周日自动启动（crontab）

建议改成 **9:05** 启动，给 Google Drive 下载多留几分钟：`./presenter.sh autostart on 09:05`


在 Air 的终端运行：

```bash
cd ~/Presenter
./presenter.sh autostart on 14:05 daily   # ① 先测试：把时间设成几分钟后
# 到点后看 Presenter 是否自动打开（会弹状态提示；当天时间表已结束时，它会提示后自动退出——这就说明启动成功了）
./presenter.sh autostart on               # ② 改回每周日 09:09
./presenter.sh autostart status           # 查看当前设置
```
- 第一次设置 crontab 时，macOS 可能弹出“终端想要管理您的电脑”，点“好”。
- 启动记录在 `~/Presenter/cron.log`。取消：`./presenter.sh autostart off`。
- cron 运行条件：**Mac 开机、已登录、没有锁屏、没有合盖睡眠**；错过时间不会补跑。建议：
  - 系统设置 › 锁定屏幕：屏幕保护程序/关闭显示器后“需要密码”设为较长时间或“永不”；
  - 或者让 Mac 每周日 9:05 自动唤醒：`sudo pmset repeat wakeorpoweron U 09:05:00`（取消：`sudo pmset repeat cancel`）。
- 9:09 时如果还有 Presenter 在运行（比如彩排没退出），会先把它关掉再启动。

## 七、彩排

```bash
~/Presenter/presenter.sh test              # 按今天的日期
~/Presenter/presenter.sh test tomorrow     # 按明天的日期（周六晚上用）
~/Presenter/presenter.sh test 20261122 --apple --pdftime 300   # 指定日期，后面的参数原样传给 Presenter
```
`presenter.sh` 会先退出正在运行的 Presenter 再启动（程序已在运行时，带参数的 open 不会生效）。
其他操作：`start`（正式启动）、`stop`（退出）、`review`（复查字幕记录）、`log`（看实时日志）、`autostart`、`update`；不带参数运行 `./presenter.sh` 看说明。

测试模式把整个时间表压缩成约 1 分钟：欢迎页 5 秒 → pdf1 15 秒 → 欢迎页 5 秒 → 时钟 6 秒 → 倒计时 10 秒 → pdf2 15 秒 → 自动退出。
测试模式里，PDF 结束前 5 秒提醒，`⌃⌥E` 每次延长 10 秒。
“下载”里没有当天的 PDF 时，用 `pdf/sample.pdf` 代替。没接投影仪时，在本屏中间开小窗预览。

其他参数：
- `--caption`：不管哪天都显示实时翻译（试字幕条用；测试模式不看 10:40，pdf2 一开始就显示）；`--nocaption`：不显示
- `--apple` / `--kaleo`：这次用本机识别 / Kaleo 作为字幕来源
- `--nobackground`：这次启动不打开后台识别（默认会打开，见第五节“后台识别并记录”）
- `--input "MacBook"`：这次本机识别用哪个音频输入（名字包含即可；`--input ""` = 系统默认输入）。现有输入的名字在菜单栏图标 › 实时翻译 里能看到
- `--channel 1`：只用第 1 路输入（0 = 混合）；`--lang en`：这次识别英语（`zh` = 普通话）
- 例：用 MacBook 自带麦克风试本机识别 —— `./presenter.sh test --apple --input "MacBook" --pdftime 300`，然后按 `⌃⌥T`
- `--countdown 90`：倒计时用 90 秒；`--pdftime 60`：每个 PDF 显示 60 秒（方便试翻页、试延长）
- `--at 10:16:50`：按真实时间表运行，但假装现在是 10:16:50（试 10:17 的提醒和延长；`--at 10:39:30 --caption` 试 10:40 字幕条出现）
- `--date 20261101`：按某天的日期找 PDF（也按这个日期从 Google Drive 下载，周六晚上试明天的文件很方便）
- `--nogdrive`：这次不从 Google Drive 下载，只用“下载”里已有的文件
- `--review`：不投影，只复查最近一天的字幕记录（`--review 20261115` 复查某一天），见第五节“从字幕记录整理术语表”

例：试字幕条 2 分钟 —— `./presenter.sh test --caption --pdftime 120`

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
| **字幕来源 Kaleo ↔ 本机识别** | `⌃⌥S` |
| **本机识别语言 普通话 ↔ 英语** | `⌃⌥L` |
| 本机识别：只显示原文 | `⌃⌥O`（Original） |
| 本机识别：只显示译文 | `⌃⌥Y`（译文） |
| 本机识别：原文 + 译文 | `⌃⌥A`（All） |
| 本机识别：整句翻译 开/关 | `⌃⌥J`（句） |
| 后台识别并记录 开/关（不管字幕来源、是否显示） | `⌃⌥M`（Mic） |
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

**快捷键使用统计**（`config.json` 的 `hotkeyStats`，默认 `true`）：
- 每按一次快捷键，在 Presenter 文件夹的 `hotkey-usage.csv` 里记一行：`date,time,action,key,name,mode`（`mode`：`live` 正式 / `test` 测试模式）。所有日子都在这一个文件里，可以用 Excel / Numbers 打开做透视表，看不同时段各快捷键的使用频率。只记快捷键，菜单里点的不算。
- Presenter 退出前（到 `quit` 时间、按 `⌃⌥Esc`、菜单退出都算），在 `presenter.log` 里写当天的报告：每 5 分钟一格（只列按过的格），每列一个动作，再加总计；下面是动作名的中文说明和各按键的次数。同一天重开过 Presenter 的话，报告是全天累计；测试模式只统计测试模式的按键。
  ```
  ===== 快捷键使用报告 2026-11-22（共 8 次，每 5 分钟一格）=====
  time         total  next  prev  extend  caption  quit
  09:15-09:20      3     2     1       -        -     -
  10:30-10:35      2     -     -       2        -     -
  ...
  total            8     3     1       2        1     1
  ```

## 九、修改内容

- **先复制一份**：`cp stage.html stage-local.html`，以后只改 `stage-local.html`（不放进仓库，升级不会被覆盖；有它时 Presenter 用它，没有才用通用的 `stage.html`）。
- **Logo**：`images/LogoNew.png`（放在 `stage-local.html` 旁边也可以）；找不到就不显示。
- **欢迎页文字、时钟页文字**：编辑 `stage-local.html` 的 `<body>` 部分；倒计时提示语和结束语在 `<script>` 开头的“文字设置”里。
- **字号、颜色、留白**：`stage-local.html` 顶部 `:root` 里的变量（都有注释）。
- **预览**：浏览器直接打开 `stage-local.html`；地址后加 `?mode=welcome`、`?mode=clock`、`?mode=countdown&s=90`、`?mode=final`。
- **时间表、PDF 文件夹、文件名规则、延长、实时翻译**：`config.json` 里是默认值；要改的项写进 `config-local.json`（同名项覆盖 `config.json`）。时间表可以增减项目，`show` 可用 `welcome`、`clock`、`countdown`、`quit` 或 `pdfs` 里的名字。

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
| `build.sh` | 编译成 `Presenter.app`，打包 `Presenter-ready.zip`；`--release` 发布到 release 分支 |
| `presenter.sh` | 彩排、启动、退出、自动启动（crontab）、更新、复查字幕记录、看日志 |
| `config.json` | 时间表、PDF 文件夹和文件名规则、延长、实时翻译、术语表设置、快捷键 |
| `config-local.json` | 本机设置：Drive 文件夹 ID、服务账号密钥、Kaleo 网页、音频输入设备等，覆盖 `config.json` 的同名项（不放进仓库，格式见 `config-local.example.json`） |
| `gdrive-sa.json` | Google 服务账号密钥（凭证；不放进仓库，也不打包） |
| `stage.html` | 通用的欢迎页、时钟页、倒计时画面 |
| `stage-local.html` | 本教会的画面（有它就不用 `stage.html`；不放进仓库） |
| `images/` | 放 `LogoNew.png` |
| `pdf/sample.pdf` | 仅测试模式使用 |
| `autostart.sh` | 旧入口，等于 `presenter.sh autostart` |
| `rclone` | 从 Google Drive 下载用的工具（自己放进来） |
| `gdrive-state.json` | 记录上次从 Google Drive 下载的版本（运行后生成，删掉也没关系） |
| `presenter.log`、`cron.log` | 运行日志（退出前写当天的快捷键使用报告）、自动启动记录（运行后生成） |
| `hotkey-usage.csv` | 每次按快捷键的记录（日期、时间、动作、按键），统计不同时段的使用频率用（运行后生成） |
| `caption-dump-*` | “保存网页结构和截图”生成的文件（调整实时翻译用） |
| `glossary-local.csv` | 教会自己的术语表（教会名字、牧者同工、团契事工；优先级最高；不放进仓库，升级时不要覆盖） |
| `glossary-bible.csv` | 圣经术语表：圣经书卷、人名、地名、教会用语、神学用语（升级时可以覆盖） |
| `glossary.csv` | 一般术语表：与圣经和本教会无关的词，如本地地名（优先级最低；升级时可以覆盖） |
| `terms-yyyymmdd.csv` | 当天的今日术语（可选；也可以放在“下载”里或 Google Drive） |
| `transcripts/` | 本机识别的字幕记录（按时段分文件，如 `Genesis_日期.txt`、`Worship_日期.txt`、`transcript_日期_小时.txt`）、后台识别时 Kaleo 的文字 `*_Kaleo.txt`，和复查报告 `review-日期.txt`（运行后生成） |
