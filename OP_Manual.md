# 直播小助手（Presenter）操作手册

橡城华人希望教会主日直播投影控制程序 · Nov 15, 2026 

## 一、概况

直播小助手（以下称Presenter） 是装在直播用 MacBook Air 上的投影控制程序（本手册对应 2.4 版）：主日早上自动启动，按时间表在投影上切换欢迎页、主日学 PDF、时钟、倒计时、敬拜 PDF，需要时在下方叠加实时翻译字幕，12:15 自动退出。OBS 在内建屏上照常直播，两者互不干扰。

**两块屏幕的分工**

- **内建屏**：OBS（直播）。Presenter 的状态提示和橙色提醒也出现在这里的上方，不抢焦点、鼠标点击会穿透，不会出现在投影上。
- **外接投影**：Presenter 的全屏画面。必须设为“扩展显示器”，不要“镜像”。
- **菜单栏图标**：随时显示当前状态，点开可以手动切换画面、查看问题。

**主日时间表**（在 `config.json` 的 `schedule` 里修改）

| 时间 | 投影显示 | 说明 |
| --- | --- | --- |
| 按 crontab 设置（建议 09:05） | 自动启动 | 启动时从 Google Drive 下载当天的两个 PDF |
| 09:10 | 欢迎页 | Logo + 中英文欢迎语 |
| 09:12 | 主日学 PDF | 如 `Sunday-20261115.pdf`；10:17 起橙色提醒，可按 ⌃⌥E 延长 |
| 10:18 | 欢迎页 |  |
| 10:21 | 时钟页 | 当前时间（带秒） |
| 10:28:30 | 90 秒倒计时 |  |
| 10:30 | 敬拜 PDF | 如 `20261115.pdf`；10:26 再从 Google Drive 检查一次新版 |
| 10:40 | 实时翻译字幕条 | 每月第一个星期天，叠加在投影下方 1/5，同时叠加到 OBS 直播画面；10:38 在后台先准备好 |
| 12:15 | 自动退出 | 12:14 提醒，可按 ⌃⌥E 推迟 |

**主要功能**

- 按时间表自动切换；晚开也能直接进入当时该显示的画面。
- 全局快捷键翻页、黑屏、延长当前画面；启动时自动避开 OBS 已用的快捷键。
- 从 Google Drive 文件夹把当天的 Google Slides 自动导出成 PDF，放进“下载”文件夹。
- 实时翻译字幕两种来源，随时切换：Kaleo 网页，或本机识别 + Apple 翻译（不联网）。字幕从左到右、逐行向上滚动，并同时叠加到 OBS 直播画面上，线上听众也看得到。
- 本机翻译的质量工具：术语表、今日术语、整句翻译、高保真翻译、字幕记录和复查。

&#91;embedded content: 系统组成 · 3 个来源、2 块屏幕\]

Presenter 只读取 PDF、Kaleo 文字和讲台声音，不经手 OBS 的直播信号；两者用同一个 Maono 输入，互不影响。

## 二、安装与升级

Air 上没有 Xcode，所以在另一台有 Xcode 的 M1 Mac 上编译，发布到 GitHub 的 release 分支，Air 用 git 取下来。Air 需要 macOS 26（现为 26.4）。

**两类文件**
- **通用的**（来自 release 分支，升级时更新）：`Presenter.app`、`config.json`、`stage.html`、`glossary.csv`、`glossary-bible.csv`、`presenter.sh`、说明文档。不要在 Air 上直接改。
- **本机的**（`*-local.*` 等，升级时不动，不在仓库里）：`config-local.json`、`glossary-local.csv`、`stage-local.html`、`images/LogoNew.png`、`gdrive-sa.json`（凭证）、`rclone`。

**编译和发布（在 M1 上）**

1. 在源代码文件夹（`git clone https://github.com/BinYuOnCa/Presenter.git`）里先提交改动。
2. 运行 `./build.sh --release`：编译、发布到 release 分支并推送。只想编译试试就运行 `./build.sh`。
3. release 分支只保留最近 10 个版本。要更早的版本：切到那个源代码版本（发布说明里写着 `main@提交号`），重新 `./build.sh`。
4. 需要 Xcode 26 以上（本机识别和 Apple 翻译需要）。编译出错时把终端里的错误信息完整保存下来。

**第一次安装到 Air（或新换的电脑）**

1. 终端运行 `xcode-select --install` 安装命令行工具（git 要用）。
2. `git clone --depth 1 -b release https://github.com/BinYuOnCa/Presenter.git ~/Presenter`
3. 把本机文件放进 `~/Presenter`（从旧电脑 AirDrop）：`config-local.json`、`glossary-local.csv`、`stage-local.html`、`images/LogoNew.png`、`gdrive-sa.json`、`rclone`。
   全新的教会：照 `config-local.example.json` 建 `config-local.json`，`cp stage.html stage-local.html` 后改文字，Google Drive 见下面。
4. 系统设置 › 显示器：投影仪设为“扩展显示器”，建议内建屏作主显示器。
5. 彩排一次：`~/Presenter/presenter.sh test tomorrow`，把系统弹出的权限询问都点“允许”：“下载”文件夹、麦克风、语音识别。
6. 设置自动启动（见下面）。

**升级**

```bash
~/Presenter/presenter.sh update
```

- 只更新通用的文件；本机文件、字幕记录、crontab 都不动。通用的文件在本机改过的话，先备份成 `.bak`。
- **升级后一定先手动彩排一次**（`./presenter.sh test tomorrow`）：每次重新编译后系统会再问一次“下载”文件夹等权限。不先点“允许”，周日自动启动时会卡在这个询问上。

**从 v2.4 及以前（zip 安装）改成 git 升级**，在 Air 上运行一次：

```bash
cd ~/Presenter
mv -n glossary.csv glossary-local.csv     # 旧的 glossary.csv 是教会自己的术语表
mv -n stage.html stage-local.html         # 欢迎页/时钟页（有教会名字的那份）
curl -fsSLO https://raw.githubusercontent.com/BinYuOnCa/Presenter/release/presenter.sh && chmod +x presenter.sh
./presenter.sh update                     # 改过的 config.json 会备份成 config.json.bak
```

然后照 `config-local.example.json` 建 `config-local.json`，把 `config.json.bak` 里自己的设置写进去：`gdrive.folderId`、`gdrive.remote`（Air 上是 `GoogleDrive`；改用服务账号后不需要）、`caption.url`、`caption.apple.inputDevice`（Maono ProStudio 2x2 Lite）。已有的 crontab 不用重设。

**每周日自动启动（crontab）**

```bash
cd ~/Presenter
./presenter.sh autostart on 14:05 daily   # 先测试：时间设成几分钟后，确认会自动打开
./presenter.sh autostart on 09:05         # 再改回每周日 09:05
./presenter.sh autostart status           # 查看当前设置；取消：./presenter.sh autostart off
```

- 到时 Mac 必须开机、已登录、没有锁屏、没有合盖睡眠，错过不补。可以让 Mac 每周日自动唤醒：`sudo pmset repeat wakeorpoweron U 09:00:00`。
- 启动记录在 `~/Presenter/cron.log`。到点时还有 Presenter 在运行会先关掉再启动。

**Google Drive 一次性设置**（已完成的话跳过；详细步骤见 README 第三节）

1. 把 `rclone` 放在 `~/Presenter/rclone`；被系统拦时运行 `xattr -d com.apple.quarantine ~/Presenter/rclone`。
2. Google Cloud Console：启用 Google Drive API → 建一个服务账号 → 建 JSON 密钥，改名 `gdrive-sa.json` 放进 `~/Presenter/`（凭证，只放在这台电脑上）。
3. 把放 Slides 的 Drive 文件夹共享给服务账号的邮箱（密钥文件里的 `client_email`），权限“查看者”。
4. `config-local.json` 写：`"gdrive": { "folderId": "文件夹网址 folders/ 后面那一串", "serviceAccountFile": "gdrive-sa.json" }`。不需要 `rclone config`。
5. 周六晚上按明天的日期测试：`~/Presenter/presenter.sh test tomorrow`，状态提示里 Google Drive 两个 PDF 都应是 ✅。

还没换成服务账号时，旧的 `rclone config` 授权照样能用：`config-local.json` 里写 `gdrive.remote`（Air 上是 `GoogleDrive`），不写 `serviceAccountFile`。

## 三、每周准备（周六）

周六只要把两个 Google Slides 放进 Google Drive 那个文件夹，并在晚上按明天的日期试一次；周日 Presenter 会自动下载。

**Google Slides 的标题规则**（日期为当天的 yyyymmdd）

| 用途 | 标题 | 示例 | 下载后的文件名 |
| --- | --- | --- | --- |
| 主日学（pdf1） | 英文单词（首字母大写，其余小写）+ `-` + 日期 | `Sunday-20261122`、`Bible-20261122` | `Sunday-20261122.pdf` |
| 敬拜（pdf2） | 只有日期 | `20261122` | `20261122.pdf` |
| 今日术语（可选） | `terms-` + 日期（Google 表格） | `terms-20261122` | `terms-20261122.csv` |

- `SundaySchool-20261122` 这种中间有大写的不符合规则。
- 手动下载时浏览器可能生成 `20261122 (1).pdf`，这种不会被使用。
- 星期五、六没有今天日期的文件，就自动顺延用接下来那个星期天的（周六直接 `presenter.sh test` 也能下载、显示明天的 PDF）；有今天的文件时总是用今天的；星期一到四不顺延。哪几天顺延：`"nextSundayOn": ["fri", "sat"]`（`[]` = 不顺延）。
- 每月第一个星期天要显示实时翻译：敬拜 PDF 里 10:40 以后的页，把下方 1/5 留白。
- 今日术语表格：A 列中文、B 列英文、C 列常被识别成的写法；写讲员名字和这次经文里不常见的人名地名。只对本机识别有效。

**周六晚上检查清单**

- [ ] 两个 Google Slides 已在 Drive 文件夹里，标题符合规则
- [ ] 第一个主日：敬拜 PDF 需要翻译的页下方 1/5 已留白
- [ ] （可选）`terms-日期` 表格已建好
- [ ] 终端运行 `~/Presenter/presenter.sh test 20261122`（换成明天的日期）
- [ ] 状态提示里 Google Drive 主日学、敬拜都是 ✅，“下载”里出现两个 PDF
- [ ] 投影上看一遍两个 PDF 的页面和顺序
- [ ] `~/Presenter/presenter.sh autostart status` 显示周日的自动启动时间
- [ ] Air 接电源、不合盖；锁屏时间设长或永不
- [ ] 想保险：再手动放一份 PDF 到“下载”，作为备份

## 四、主日当天

正常情况下当天只需要翻页；切换画面、下载 PDF、开关字幕、退出都是自动的。

**开机前（自动启动之前）**

- [ ] Air 接电源、开机、已登录、不合盖
- [ ] 投影仪已接好，是“扩展显示器”
- [ ] Maono ProStudio 2x2 Lite 已接好（OBS 和本机识别都用它）
- [ ] Air 已联网（Google Drive 下载、Kaleo 需要）

**按时间顺序**

1. **自动启动（建议 09:05）**：内建屏上方弹出状态提示，下载完成后再弹一次。确认：
   - Google Drive 主日学、敬拜都是 ✅
   - 投影屏 ✅
   - 第一个主日：实时翻译 ✅
   - 菜单栏图标前没有 ⚠️（有的话点开菜单看原因，对照第九节）
2. **没有自动启动**：终端运行 `~/Presenter/presenter.sh start`。晚开也没关系，会直接进入当时该显示的画面。
3. **09:10 欢迎页 → 09:12 主日学 PDF**：用 `⌃⌥→` / `⌃⌥←` 翻页（焦点在 OBS 也有效）。需要提前显示 PDF 按 `⌃⌥P`。
4. **10:17 橙色提醒**：“60 秒后关闭主日学”。还没讲完就按 `⌃⌥E` 延长 2 分钟，可以连按；不操作就 10:18 照常切换。延长后提前结束按 `⌃⌥R` 恢复按时间表。
5. **10:18 欢迎页 → 10:21 时钟 → 10:28:30 倒计时 → 10:30 敬拜 PDF**：自动。敬拜 PDF 10:26 会再从 Google Drive 检查一次新版。
6. **敬拜期间**：翻页同上；需要时 `⌃⌥B` 黑屏，再按一次恢复。
7. **第一个主日 10:40 字幕条自动出现在投影和 OBS 直播画面上**（详见第五节）：
   - `⌃⌥T` 显示/隐藏（例如某页没留白）
   - `⌃⌥S` 在 Kaleo 和本机识别之间切换
   - 讲员说英语时按 `⌃⌥L`（只对本机识别）
8. **12:14 提醒、 12:15 自动退出**：聚会还没结束就按 `⌃⌥E` 推迟。提前退出按 `⌃⌥Esc`。

**手动切换的规则**：菜单里手动切到某个画面，只管到时间表的下一个时间点，之后自动恢复。例如 09:11 提前显示主日学，10:18 照样回到欢迎页。错过提醒、已切到欢迎页时，菜单 › 显示主日学会回到刚才那一页（15 分钟内）。

**主日后（用了本机识别的话）**：做一次字幕复查，见第六节。

## 五、实时翻译字幕

每月第一个星期天，敬拜 PDF 期间 10:40 起，字幕条自动叠加在投影下方 1/5，同时叠加到 OBS 直播画面；任何一天都可以按 `⌃⌥T` 手动显示。字从左到右写，一行写满就整行向上滚动，写完的行不再变动，只有最下面正在说的那一行会微调；左右各留白 10%。

**两种字幕来源**（`⌃⌥S` 随时切换，同一时间只显示一种）

|  | Kaleo 网页 | 本机识别 + Apple 翻译 |
| --- | --- | --- |
| 原理 | 10:38 在后台打开 Kaleo 翻译网页，提取正在更新的文字 | Air 从 Maono 听讲台声音，本机转成文字再翻译 |
| 需要联网 | 需要 | 不需要 |
| 菜单栏图标 | 💬 | 🎙 |
| 显示 | 大字文字（或「原网页」备用方式） | 原文 + 译文 / 只译文 / 只原文 |
| 提高质量的工具 | 无 | 术语表、今日术语、整句翻译、高保真、字幕记录 |
| 默认 | `caption.source` 为 `kaleo` 时 | `caption.source` 改成 `apple` |

**本机识别的使用**

- 显示方式：`⌃⌥A` 原文 + 译文（默认：上面一行原文，下面两行译文）、`⌃⌥Y` 只译文、`⌃⌥O` 只原文。
- 识别语言：默认普通话 → 英语；英文讲员时按 `⌃⌥L` 切成英语 → 中文，再按一次切回。
- **整句翻译**（默认开，`⌃⌥J` 开/关）：等一句说完（句号、问号，或停顿 1.2 秒，最长 7 秒）再翻译，更准，译文晚一两秒。讲得很快、觉得译文太慢时关掉。
- **高保真翻译**（菜单 › 实时翻译 › 翻译质量）：Air 打开 Apple Intelligence 时用它的模型，否则自动用普通模型。Air 变慢、发热或译文太慢时改成“快速”。菜单里有“翻译平均 x 秒/句”可以参考。
- 15 秒没人说话会清空字幕条。
- 术语表和今日术语自动生效：识别结果先纠错，翻译前把专有名词换成固定译名（详见第六节）。

**本机识别第一次使用前（只做一次）**

1. 系统设置 › 通用 › 语言与地区 › 翻译语言：下载中文（普通话）和英语。
2. （要用高保真）系统设置 › Apple Intelligence 与 Siri：打开 Apple Intelligence。
3. 试一次：`~/Presenter/presenter.sh test --apple --pdftime 300`，预览窗出现后按 `⌃⌥T`。麦克风、语音识别权限点“允许”；第一次会自动下载识别模型（几分钟）。
4. 对着讲台麦克风说几句，确认出现原文和译文。

**Kaleo 字幕显示不对时**：菜单 › 实时翻译 › 显示方式：原网页（直接把网页放大显示）；或按 `⌃⌥S` 换成本机识别。

**按停顿自动补标点**（本机识别，默认只对普通话）

- Presenter 同时用识别结果里每个词的时间和自己听到的音量判断停顿：停顿超过 0.3 秒补“，”，超过 0.8 秒补“。”；已有标点的地方不补。
- 标点还是太少：把 `caption.apple.pauseComma` / `pausePeriod` 调小（如 0.25 / 0.6）；太多就调大。效果在字幕记录里能看到。
- 很长、一直没有句号的句子，整句翻译等到 7 秒时在最后一个逗号处断开先翻。
- 识别开始后的头几十秒判断还不准，补的标点会少一些；10:38 开始识别、10:40 才显示，一般不影响。

**OBS 字幕叠加（线上听众也看得到）**

Presenter 运行时在本机提供字幕网页 `http://127.0.0.1:8765/caption`：透明背景，只有底部一条半透明黑底白字的滚动字幕；没有字幕或 Presenter 没在运行时自动隐藏。Kaleo 和本机识别都可以用。

在 OBS 里设置（只做一次）：

1. 场景列表 › + › 新建场景“字幕叠加”。
2. 在“字幕叠加”里：来源 › + › 浏览器，URL 填 `http://127.0.0.1:8765/caption`（菜单 › 实时翻译 › 复制 OBS 字幕网址），宽高与 OBS 画布相同（如 1920 × 1080）；“不可见时关闭源”“场景激活时刷新浏览器”都不要勾。
3. 每个直播用的场景：来源 › + › 场景 › 选“字幕叠加”，拖到来源列表最上面；以后新建场景也要加。
4. 试一次：`~/Presenter/presenter.sh test --apple --caption --pdftime 300`，在 OBS 预览里切换场景，字幕应一直在。不开 OBS 也可以先看：菜单 › 实时翻译 › 在浏览器里预览 OBS 字幕页。

- 显示/隐藏默认跟投影字幕条一起（`⌃⌥T` 两边一起开关）。想让线上在字幕时段内一直有字幕：菜单 › 实时翻译 › “OBS 字幕：字幕时段内一直显示”。
- 显示原文/译文跟投影一样（`⌃⌥A` / `⌃⌥Y` / `⌃⌥O`）；样式在 `config.json` 的 `obs` 里改（第十一节）。
- 菜单里看状态：“OBS 字幕叠加：✅ …（OBS 已连接）”。

## 六、主日后：字幕复查和术语表

每个用了本机识别的主日后花 10–15 分钟复查一次字幕记录，把认错、翻错的词加进 `glossary-local.csv`，以后每次自动用上。

**术语表格式**（用 TextEdit 编辑，保存后几秒内自动生效；不要用 Numbers 打开再保存）

```csv
中文,English,中文常被识别成,英文常被识别成,方向
以利亚,Elijah,一里亚|伊利亚,,
王约翰牧师,Pastor John Wang,王约汉牧师,,
诗篇,Psalm,,,中→英
```

- 第 3 列、第 4 列：识别错的写法，多个用 `|` 分开，可以不填。
- 第 5 列：不填 = 双向；`中→英` = 只在中文翻英文时替换。
- 只写中文不写英文：不指定译名，只保护这个词不被拆开。
- `!` 开头的行（如 `!一粒沙`）：这几个字永远不自动改。`#` 开头是注释。
- 优先级：`glossary-local.csv`（教会自己的：牧者同工、团契）> `glossary-bible.csv`（圣经书卷、人名、地名、神学用语）> `glossary.csv`（一般用语）。给后两个表里的词加错误写法：在 `glossary-local.csv` 写同样的中文，英文也要写上。
- 今日术语：当天 PDF 里出现的术语和“讲员：xxx”这类名字自动算；也可以用 `terms-日期` 表格（第三节）。今日术语还会做“读音相同就改”，但像“哥哥他”“八十八”这样的普通词语只记下来、不改。

**复查步骤**

1. **生成复查报告**：
   - Presenter 还在运行：菜单 › 实时翻译 › 术语表和字幕记录 › 复查最近一天的字幕记录。
   - 已退出：`~/Presenter/presenter.sh review`（某天：`--review 20261115`）。不会投影，同一天的几个字幕记录文件合在一起复查，生成 `transcripts/review-日期.txt` 并用 TextEdit 打开。
2. **看报告“一、译文里的人名、地名”**：没认出或译错的名字（标“像拼音”的多半是没认出的中文名字）→ 加一行 `中文,English`；原文的字也错了 → 错的写法放第 3 列。
3. **看“二、自动纠正”**：
   - “已改”里改错的 → 加一行 `!那几个字`。
   - “可能听错”确实是听错，而且这个写法平时不会说 → 加到那个词的第 3 列；平时也会说的不要加。
4. **（可选）用 ⌘F 扫一眼字幕记录** `transcripts/` 里那天的文件（主日学 `书卷名_日期.txt`、敬拜 `Worship_日期.txt`、其他时间 `transcript_日期_小时.txt`），按下表处理。
5. **保存后再复查一次**：看报告“三”里每句的旧译 / 新译，都对就完成。

| 字幕记录里看到 | 是什么问题 | `glossary-local.csv` 里怎么写 |
| --- | --- | --- |
| `原：……一里亚……`（应是以利亚） | 识别错（字错了） | `以利亚,Elijah,一里亚` |
| `原` 对，`译` 里成了 Yi Liya | 翻译错 | `以利亚,Elijah` |
| `送` 里的英文词让译文变别扭 | 这个词不适合翻译前替换 | 只写中文；或第 5 列写方向 |
| `改` 把对的字改错了 | 误改 | `!那几个字` |
| 英文讲员：`原：……Oak Ville……` | 英文识别错 | `橡城,Oakville,,Oak Ville` |

字幕记录每句四行：`原` = 识别原文，`改` = 纠正后（后面注明改了什么），`送` = 送去翻译的文字，`译` = 译文。
每段开头的 `参数：` 行记着当时生效的识别参数（`clearAfterSeconds`、`sentenceMode`、`sentencePauseSeconds`、`pauseComma`、`pausePeriod` 等，名字同 `config.json`）。复查时对照讲员的语速调整：标点太少就调小 `pauseComma` / `pausePeriod`，一句话被切断就调大 `sentencePauseSeconds`。

## 七、快捷键清单

全部是全局快捷键：焦点在 OBS 或任何程序都有效。`⌃` = Control，`⌥` = Option。

| 类别 | 动作 | 快捷键 |
| --- | --- | --- |
| 翻页 | 下一页 | `⌃⌥→` 或 `⌃⌥↓` |
| 翻页 | 上一页 | `⌃⌥←` 或 `⌃⌥↑` |
| 翻页 | 回到第一页 | `⌃⌥1` |
| 画面 | 立即显示 PDF（当前时段的，或下一个） | `⌃⌥P` |
| 画面 | 黑屏开/关 | `⌃⌥B` |
| 时间表 | 延长当前画面（每次 +2 分钟，可连按） | `⌃⌥E` |
| 时间表 | 恢复按时间表（取消延长和手动切换） | `⌃⌥R` |
| 字幕 | 实时翻译显示/隐藏 | `⌃⌥T` |
| 字幕 | 字幕来源 Kaleo ↔ 本机识别 | `⌃⌥S` |
| 本机识别 | 识别语言 普通话 ↔ 英语 | `⌃⌥L` |
| 本机识别 | 原文 + 译文 | `⌃⌥A` |
| 本机识别 | 只显示译文 | `⌃⌥Y` |
| 本机识别 | 只显示原文 | `⌃⌥O` |
| 本机识别 | 整句翻译开/关 | `⌃⌥J` |
| 程序 | 退出 Presenter | `⌃⌥Esc` |

- 启动时会读取 OBS 的快捷键设置；和 OBS 或其他软件冲突的组合不会启用，菜单栏标 ⚠️，菜单 › 快捷键 里可以看到哪个没启用。
- 改快捷键：`config.json` 的 `hotkeys`，写法如 `"ctrl+alt+right"`。欢迎页、时钟、倒计时也可以配快捷键（`welcomeNow`、`clockNow`、`countdownNow`，默认没有）。
- 用翻页笔：在 `next` 里加 `"pagedown"`，`prev` 里加 `"pageup"`。
- macOS 15 起不允许只用 Option 的全局快捷键，组合里要带 ctrl 或 cmd。
- 使用统计：每按一次快捷键记到 `hotkey-usage.csv`（所有日子一个文件，可用 Excel 统计）；Presenter 退出前在 `presenter.log` 里写当天报告：每 5 分钟一格的各快捷键次数和总计。不想记录：`config.json` 里 `"hotkeyStats": false`。

## 八、菜单栏图标和菜单

菜单栏图标一眼就能看出现在在哪一步；图标前出现 ⚠️ 就是有问题，点开菜单看原因。

| 图标显示 | 意思 |
| --- | --- |
| `⏱9:10` | 等待中，9:10 开始第一个画面 |
| `👋欢迎页` | 正在显示欢迎页 |
| `📄3/12` | 正在显示 PDF，第 3 页 / 共 12 页 |
| `📄12/12→10:20` | 已延长到 10:20 |
| `🕐时钟` | 正在显示时钟页 |
| `⏳1:23` | 倒计时还剩 1 分 23 秒 |
| `…💬` | 正在显示 Kaleo 字幕 |
| `…🎙` | 正在显示本机识别字幕 |
| `⚠️…` | 有问题，点开菜单看原因 |

**菜单里有什么**（从上到下）

- **时间表、当前画面、PDF 状态**：今天的安排和两个 PDF 是否找到。
- **从 Google Drive 重新下载**：随时手动再取一次；正在显示的 PDF 换成新版，停在原来那一页。
- **PDF 文件**：PDF 文件夹、每个 PDF 的状态、Google Drive 下载状态、“含今天日期但不符合规则”的文件；重新检查 PDF、打开 PDF 文件夹、在浏览器打开 Google Drive 文件夹。
- **投影屏状态**和当前的 ⚠️ 问题。
- **画面控制**：延长当前画面、手动切到欢迎页 / 主日学 / 时钟 / 倒计时 / 敬拜、立即显示 PDF、恢复按时间表、黑屏。
- **实时翻译**：
  - 字幕来源（Kaleo / 本机识别）；显示/隐藏；自动 / 显示 / 隐藏。
  - 本机识别：状态、识别语言、显示方式、整句翻译、翻译质量（高保真 / 快速）、翻译平均用时、音频输入。
  - 术语表和字幕记录：术语表和今日术语的条数、打开教会术语表、打开今日术语、重新载入术语表、打开今天的字幕记录、复查最近一天的字幕记录、打开字幕记录文件夹。
  - OBS：字幕叠加状态（是否已连接）、复制 OBS 字幕网址、在浏览器里预览 OBS 字幕页、显示方式（跟投影字幕条一起 / 字幕时段内一直显示）。
  - Kaleo：显示方式（提取文字 / 原网页）、重新载入翻译网页、打开可点击的翻译网页窗口、保存网页结构和截图。
- **工具**：打开 Presenter 文件夹、查看日志。
- **快捷键**：每个快捷键是否启用、有没有冲突、读到了几个 OBS 绑定。
- **退出 Presenter**。

## 九、常见问题与解决办法

大多数问题菜单栏都会标 ⚠️ 并写明原因；更详细的记录在菜单 › 工具 › 查看日志（`presenter.log`）。

**启动和显示**

| 现象 | 原因 | 解决办法 |
| --- | --- | --- |
| `open` 后什么都没出现，或带的参数没生效 | 已经有一个 Presenter 在运行 | 用 `./presenter.sh test …`（会先退出旧的），或先 `./presenter.sh stop` |
| 周日没有自动启动 | 到点时 Mac 睡眠、合盖、锁屏或没登录 | 手动 `open ~/Presenter/Presenter.app`；看 `~/Presenter/cron.log`；设 `pmset` 自动唤醒 |
| 启动后很快自己退出 | 12:15 以后打开，今天的时间表已结束 | 正常。要试用 `--test` 或 `--at` |
| 12:15 退出了，聚会还没结束 | 12:14 的提醒时没按延长 | 用“预览”打开 PDF 全屏放到投影上；下次 12:14 按 `⌃⌥E` |
| 投影上没有画面 | 投影是“镜像”，或线松了 | 系统设置 › 显示器 改成扩展；重新接上后自动恢复 |
| 接了多块外接屏，画面上了另一块 | 自动选屏选错 | `config.json` 的 `screenName` 填投影屏名字里的几个字 |
| 快捷键没反应 | 和 OBS 或其他软件（Rectangle、Magnet）冲突，没启用 | 菜单 › 快捷键 看哪个没启用；在 `config.json` 的 `hotkeys` 里换一个 |
| `zsh: permission denied: ./Presenter.app` | `.app` 不能直接运行 | 用 `./presenter.sh test …` 或 `open Presenter.app --args …` |

**PDF 和 Google Drive**

| 现象 | 原因 | 解决办法 |
| --- | --- | --- |
| 文件在“下载”里但找不到 PDF | “下载”文件夹权限被拒绝 | 系统设置 › 隐私与安全性 › 文件和文件夹 › Presenter，打开“下载文件夹” |
| 文件名是 `20261115 (1).pdf` | 浏览器重复下载，不符合规则 | 改名成 `20261115.pdf`，或删掉旧的再下载 |
| Google Drive：云端文件夹里没有今天的文件 | Slides 标题不符合规则、日期写错、放错文件夹 | 按第三节的规则改标题，然后菜单 › 从 Google Drive 重新下载 |
| Google Drive：连接失败 / 401 / 403 / 404 | 没联网；密钥被删；文件夹没共享给服务账号 | 先查网络；再查 `gdrive-sa.json` 和文件夹共享（用旧的 rclone 授权时：`~/Presenter/rclone config reconnect GoogleDrive:`）。当天先用“下载”里的备份 |
| 找不到服务账号密钥文件 | `gdrive-sa.json` 没放或名字不对 | 放进 `~/Presenter/`，名字和 `config-local.json` 的 `serviceAccountFile` 一致 |
| rclone：“Apple 无法验证” | macOS 拦截下载的程序 | `xattr -d com.apple.quarantine ~/Presenter/rclone` |
| 礼拜前临时改了 Slides | — | 菜单 › 从 Google Drive 重新下载；敬拜 10:26 也会自动再检查 |

**实时翻译**

| 现象 | 原因 | 解决办法 |
| --- | --- | --- |
| Kaleo 字幕内容不对或一直不更新 | 网页结构和自动提取不匹配 | 菜单 › 显示方式：原网页；或 `⌃⌥S` 换成本机识别；翻译时“保存网页结构和截图”以便调整 |
| Kaleo 网页需要先选语言 | 第一次打开 | 菜单 › 打开可点击的翻译网页窗口，选好后“重新载入翻译网页” |
| 本机识别 ⚠️ 找不到 Maono | 设备没接好或名字不同 | 菜单里看“这台 Mac 的音频输入”，把正确名字填到 `config-local.json` 的 `caption.apple.inputDevice` |
| 显示“翻译语言还没下载” | 中文或英语翻译模型没装 | 系统设置 › 通用 › 语言与地区 › 翻译语言 下载，再按两次 `⌃⌥S` |
| 反复提示“音频设备有变化” | 音频接口重新连接 | 检查 Maono 的 USB 线；按两次 `⌃⌥S` 重新开始；还不行换回 Kaleo |
| 讲台声音里混着音乐，识别很差 | 两路输入混在一起 | 讲台麦只在第 1 路时，`caption.apple.channel` 设为 1 |
| 译文太慢、Air 发热变慢 | 整句翻译或高保真占用时间 | `⌃⌥J` 关掉整句翻译；菜单 › 翻译质量：快速 |
| 人名、地名认错或翻错 | 不在术语表里 | 加进 `glossary-local.csv` 或当天的 `terms-日期`（第六节） |
| 自动纠正把对的词改错了 | 读音相同或第 3 列写法太常见 | `glossary-local.csv` 加一行 `!那个词`；或删掉那个第 3 列写法 |
| 菜单显示“术语表有 N 行看不懂” | 格式不对，或用 Numbers 保存成了别的格式 | 看日志里的行号；用 TextEdit 改成 `中文,English,…` 格式 |
| 翻译前替换让译文变别扭 | 中英夹杂的句子翻译得不好 | 给那个词只写中文；普遍如此就把 `glossary.beforeTranslation` 改成 `false` |
| `--review` 没反应 | Presenter 已经在运行 | 用菜单 › 术语表和字幕记录 › 复查最近一天的字幕记录 |
| 字幕标点太少、句子很长 | 讲员语速快，停顿短 | 把 `caption.apple.pauseComma` / `pausePeriod` 调小（如 0.25 / 0.6）；字幕记录里看效果 |
| 标点太多、句子断得太碎 | 停顿的标准太低 | 把这两个数调大；不要自动补标点就把 `caption.apple.autoPunctuation` 改成 `off` |
| 字幕最下面一行的字会变 | 那一行是正在说的话，识别结果还在修正 | 正常；上面写完的行不会再变 |
| OBS 直播画面上没有字幕 | 当前场景没加“字幕叠加”、网址不对，或字幕是隐藏状态 | 菜单 › 实时翻译 看是否“OBS 已连接”；每个场景都要加“字幕叠加”场景来源；投影上隐藏时 OBS 也隐藏（可改成“字幕时段内一直显示”） |
| 菜单显示 OBS 字幕页“端口可能被占用” | 别的程序用了 8765 端口 | `config.json` 的 `obs.port` 改成 8766，OBS 里的网址也跟着改 |

**升级和编译**

| 现象 | 原因 | 解决办法 |
| --- | --- | --- |
| `build.sh` 编译失败 | Xcode 版本太旧，或代码问题 | 确认 Xcode 26 以上；把完整错误信息发给开发者 |
| 编译提示“不包含本机识别功能” | Xcode 低于 26 | 更新 Xcode；其他功能照常 |
| 升级后又问权限 | 新编译的 App 要重新授权 | 正常；彩排一次并点“允许” |

## 十、彩排与命令行参数

彩排用 `./presenter.sh test [tomorrow|日期] [参数…]`：整个时间表压缩成约 1 分钟，没接投影时在本屏中间开小窗预览。会先退出正在运行的 Presenter。

```bash
~/Presenter/presenter.sh test
```

测试模式：欢迎页 5 秒 → 主日学 15 秒 → 欢迎页 5 秒 → 时钟 6 秒 → 倒计时 10 秒 → 敬拜 15 秒 → 自动退出；PDF 结束前 5 秒提醒，`⌃⌥E` 每次延长 10 秒。“下载”里没有当天的 PDF 时用 `pdf/sample.pdf` 代替。

| 参数 | 作用 |
| --- | --- |
| `--test` | 压缩时间表彩排 |
| `--pdftime 300` | 每个 PDF 显示 300 秒（试翻页、延长、字幕） |
| `--countdown 90` | 倒计时用 90 秒 |
| `--at 10:16:50` | 按真实时间表运行，假装现在是 10:16:50（试 10:17 的提醒） |
| `--date 20261122` | 按某天的日期找 PDF，也按这天从 Google Drive 下载 |
| `--nogdrive` | 这次不从 Google Drive 下载 |
| `--caption` / `--nocaption` | 不管哪天都显示 / 不显示实时翻译 |
| `--apple` / `--kaleo` | 这次用本机识别 / Kaleo 作字幕来源 |
| `--input "MacBook"` | 这次用哪个音频输入（名字包含即可；`""` = 系统默认） |
| `--channel 1` | 只用第 1 路输入（0 = 混合） |
| `--lang en` | 这次识别英语（`zh` = 普通话） |
| `--review` / `--review 20261115` | 不投影，只复查最近一天 / 某一天的字幕记录 |

**常用组合**

- 周六晚上试明天的文件：`./presenter.sh test 20261122`
- 试字幕条 2 分钟：`./presenter.sh test --caption --pdftime 120`
- 用 MacBook 自带麦克风试本机识别：`./presenter.sh test --apple --input "MacBook" --pdftime 300`，然后按 `⌃⌥T`
- 试 10:40 字幕条自动出现：`./presenter.sh start` 不带参数；要模拟时间用 `./presenter.sh stop; open Presenter.app --args --at 10:39:30 --caption`
- 看实时日志：`./Presenter.app/Contents/MacOS/Presenter --test`（Ctrl+C 结束；这样运行时权限算在“终端”头上）

## 十一、config.json 设置速查

下表是 `config.json` 里的默认值。**不要直接改 `config.json`**（升级时会被替换）：要改的项写进 `config-local.json`，同名项覆盖 `config.json`，只写要改的那几项。改完要退出并重新打开 Presenter 才生效（术语表文件不用重开）。用 TextEdit 编辑，引号要是英文直引号 `"`，不能是弯引号。

| 设置 | 当前值 | 说明 |
| --- | --- | --- |
| `schedule` | 09:10 欢迎页 … 12:15 退出 | 时间表；`show` 可用 `welcome`、`clock`、`countdown`、`quit`、`pdf1`、`pdf2` |
| `pdfFolder` | `~/Downloads` | PDF 从哪里读 |
| `pdfs.pdf1` / `pdfs.pdf2` | `^[A-Z][a-z]+-{date}\.pdf$` / `^{date}\.pdf$` | 文件名规则（正则），`{date}` = 当天 yyyymmdd |
| `pdfNames` | 主日学、敬拜 | 菜单和提示里显示的名字 |
| `gdrive.enabled` / `folderId` / `serviceAccountFile` | `true` / 文件夹 ID / `gdrive-sa.json` | Google Drive 下载；后两项写在 `config-local.json` |
| `gdrive.remote` | `gdrive` | 不用服务账号时 rclone 里的名字（Air 旧设置是 `GoogleDrive`） |
| `caption.url` | Kaleo 翻译网页 | 在 `config-local.json` |
| `gdrive.recheckBeforeMinutes` / `waitSeconds` | 4 / 60 | PDF 开始前几分钟再检查；到点还在下载时最多等几秒 |
| `nextSundayOn` | `["fri", "sat"]` | 这几天没有今天日期的文件时，下载和使用接下来那个星期天的 PDF、今日术语；`[]` = 不顺延 |
| `extend.minutes` / `warnSeconds` / `warnFor` | 2 / 60 / pdf1、pdf2 | 每次延长几分钟、提前几秒提醒、哪些画面提醒 |
| `caption.source` | `kaleo` | 默认字幕来源，`apple` = 本机识别 |
| `caption.when` | `firstSunday` | 哪天自动显示：`firstSunday`、`sunday`、`always`、`never` |
| `caption.showDuring` / `from` / `to` | pdf2 / 10:40:00 / 空 | 哪些画面、几点开始、几点停止（空 = 到画面结束） |
| `caption.heightPercent` / `lines` | 20 / 3 | 字幕条高度、行数 |
| `caption.marginPercent` | 10 | 字幕左右各留白（屏幕宽度的百分比） |
| `caption.background` / `color` | `#000000` / `#ffffff` | 背景（`transparent` = 透明）和字的颜色 |
| `caption.overlay` | `true` | 叠加在 PDF 下方；`false` = PDF 缩到上方 4/5 |
| `caption.mode` / `textSelector` | `text` / 空 | Kaleo：提取文字或 `page`（原网页）；找不准时填 CSS 选择器 |
| `caption.apple.language` / `translateTo` | `zh-CN` / `auto` | 识别语言；翻成另一种语言或 `none` |
| `caption.apple.inputDevice` / `channel` | 空（`config-local.json` 里是 Maono ProStudio 2x2 Lite）/ 0 | 音频输入，空 = 系统默认；0 = 混合，1、2 = 只用某一路 |
| `caption.apple.display` / `clearAfterSeconds` | `both` / 15 | 显示方式；多少秒没人说话清空 |
| `caption.apple.sentenceMode` / `sentenceMaxSeconds` / `sentencePauseSeconds` | `true` / 7 / 1.2 | 整句翻译、最多等几秒、停顿几秒算一句 |
| `caption.apple.translationQuality` | `high` | `high` = 高保真，`fast` = 快速 |
| `caption.apple.saveTranscript` | `true` | 保存字幕记录到 `transcripts/` |
| `transcripts.files` / `default` | 星期天 9:15–10:25 `{pdf1}_{date}`、10:30–12:10 `Worship_{date}` / `transcript_{date}_{hour}` | 字幕记录按时段分文件：`days`（sun…sat，不写 = 每天）、`from`、`to`（不含）、`name`；都不符合用 `default` |
| `hotkeyStats` | `true` | 快捷键使用记到 `hotkey-usage.csv`，退出前在日志里写报告 |
| `caption.apple.autoPunctuation` / `pauseComma` / `pausePeriod` | `zh` / 0.3 / 0.8 | 按停顿补标点：`zh` 只对普通话 / `all` / `off`；停顿几秒补逗号、句号 |
| `glossary.enabled` / `files` | `true` / glossary-local.csv、glossary-bible.csv、glossary.csv | 术语表开关和文件（前面的优先） |
| `glossary.beforeTranslation` | `true` | 翻译前把术语换成译名 |
| `glossary.fuzzy` / `fuzzyMinLength` | `today` / 3 | 读音纠正：只对今日术语 / `all` / `off`；几个字以上才做 |
| `glossary.pdfTerms` / `termsFile` / `fromGoogleDrive` | `true` / `^terms-{date}\.(csv\|txt)$` / `true` | 从 PDF 找今日术语、今日术语文件名、从 Google Drive 下载 |
| `obs.enabled` / `port` | `true` / 8765 | OBS 字幕页 `http://127.0.0.1:8765/caption` |
| `obs.visibility` | `same` | `same` = 跟投影字幕条一起显示/隐藏；`auto` = 字幕时段内一直显示 |
| `obs.lines` / `heightPercent` / `bottomPercent` / `marginPercent` | 3 / 15 / 4 / 10 | 叠加字幕的行数，占视频高度、离底边、左右留白的百分比 |
| `obs.background` / `color` | `rgba(0,0,0,0.55)` / `#ffffff` | 叠加字幕条的背景（最后一个数是不透明度）和字的颜色 |
| `screenName` | 空 | 自动选外接屏；多块外接屏时填投影屏名字里的几个字 |
| `hotkeys` | 见第七节 | 快捷键 |

## 十二、文件说明

程序和设置都在 Air 的 `~/Presenter`；PDF 和今日术语文件下载到 `~/Downloads`。

| 文件 | 作用 | 升级时 |
| --- | --- | --- |
| `Presenter.app` | 程序 | 自动更新 |
| `config.json` | 默认设置：时间表、PDF 规则、Google Drive、延长、实时翻译、术语表、快捷键 | 自动更新 |
| `config-local.json` | 本机设置：Drive 文件夹 ID、服务账号密钥、Kaleo 网页、音频输入等（覆盖 `config.json` 的同名项） | 不动 |
| `README.md` | 开发者写的完整说明 | 自动更新 |
| `glossary-local.csv` | 教会自己的术语表：教会名、牧者同工、团契（优先级最高） | 不动 |
| `glossary-bible.csv` | 圣经术语表：圣经书卷、人名、地名、教会用语、神学用语 | 自动更新 |
| `glossary.csv` | 一般术语表：与圣经和本教会无关的词（优先级最低） | 自动更新 |
| `stage.html` | 通用的欢迎页、时钟页、倒计时画面 | 自动更新 |
| `stage-local.html` | 本教会的画面（文字、字号、颜色、留白）；有它就不用 `stage.html` | 不动 |
| `presenter.sh` | 彩排、启动、退出、自动启动、更新、复查 | 自动更新 |
| `gdrive-sa.json` | Google 服务账号密钥（凭证） | 不动 |
| `images/LogoNew.png` | Logo | 不动 |
| `autostart.sh` | 旧入口，等于 `presenter.sh autostart` | 自动更新 |
| `rclone` | 从 Google Drive 下载用的工具 | 不动 |
| `pdf/sample.pdf` | 只在测试模式使用 | 自动更新 |
| `transcripts/书卷名_日期.txt`、`Worship_日期.txt`、`transcript_日期_小时.txt` | 本机识别的字幕记录（按时段分文件，见 `transcripts` 设置） | 自动生成 |
| `transcripts/review-日期.txt` | 字幕复查报告 | 自动生成 |
| `presenter.log` | 运行日志（菜单 › 工具 › 查看日志）；退出前写当天的快捷键使用报告 | 自动生成 |
| `hotkey-usage.csv` | 每次按快捷键的记录（统计使用频率用） | 自动生成 |
| `cron.log` | 自动启动记录 | 自动生成 |
| `gdrive-state.json` | 上次从 Google Drive 下载的版本（删掉也没关系） | 自动生成 |
| `caption-dump-*` | “保存网页结构和截图”生成（调整 Kaleo 用） | 自动生成 |
| `~/Downloads/terms-日期.csv` | 当天的今日术语（也可以放在 `~/Presenter`） | — |
