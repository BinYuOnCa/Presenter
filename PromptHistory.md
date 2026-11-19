在MacBook Air（双屏，Built-In LCD显示OBS， 外接投影仪PDF等）上自动实现如下步骤：
	•	10：25：00在外接投影上显示当前时间（带秒）和一些固定的背景文字和图片，全屏；
	•	10：28：30开始，外接投影上其他内容不变，当前时间变为90秒倒计时，全屏；
	•	10：30：00，倒计时结束，显示指定的PDF文件（文件名为当天日期，格式yyyymmdd.pdf）第一页，全屏；
	•	实现全局快捷键，无论焦点是否在PDF全屏窗口显示的应用上，都可以实现PDF显示翻页。这些全局快捷键不能与OBS快捷键有冲突。

==> Presenter_0.zip


那台用来直播的MacBook Air上没有xcode，可否在这台机器上编译，然后复制到Book Air上运行？


==>Preenter_1.zip


将stage.html改为附件中HTML一样的输出。另，本机也是M1芯片，不用考虑对Intel芯片的支持。
==> Presenter_2.zip

按上面步骤编译后Air Drop 到Book Air上，运行了 xattr ，第一次运行 open Presenter.app --args --test --countdown 10 时一切正常。因为目前BookAir只有Built-in Screen，故内容显示在中间，按⌃⌥Esc才退出。 再次尝试运行open Presenter.app，没有任何内容显示。 已将20261025.pdf文件复制到pdf子目录。运行 open Presenter.app --args --test --countdown 10 时也没任何内容显示。
=> Presenter_3.zip

几个调整： * 9：10：00在外接投影上显示一个简单的欢迎页面，居中显示Logo 和中英文欢迎语即可，四周留白10%，全屏； * 9：12：00 在外接投影上显示指定的PDF文件（文件名符合regexp：”^[ A-Z][a-z]+-yyyymmdd.pdf$”，其中yyyymmdd为当天日期）  ，全屏 * 10：18：00 关闭上述PDF文件，外接投影回到最初的简单欢迎页面，全屏； * 10：21：00在外接投影上显示当前时间（带秒）和一些固定的背景文字和图片，该页面四周请留白10%，除时间和倒计时外的其他文本酌情减少字体大小。全屏； * 10：28：30开始，外接投影上其他内容不变，当前时间变为90秒倒计时，全屏； * 10：30：00倒计时结束，显示指定的PDF文件（文件名为当天日期，格式yyyymmdd.pdf）第一页，全屏； * 12：15：00，退出程序；
 另： * PDF文件均从～/Downloads目录中读取，logo文件, log文件 和stage.html文件位置不变； * 生成Crontab任务，每个周日的上午9：09自动启动这个程序

==> Presenter_4.zip

今天在直播过程中实际用上了Presenter，包括crontab自动启动，一切正常。现在两个新需求： - 第一个阶段原计划10：15结束，故设定10：18关闭pdf1回到欢迎页，结果到10：19才结束。我只好手动选择再次打开pdf1。 可否让我在10：18之前有机会手动延长关闭pdf1回到欢迎页的时间？这种情况较少发生，故如果不做任何操作的话，还是10：18自动进行。 - 今天需用到实时翻译，具体就用浏览器打开一个指定的网页https://app.withkaleo.com/c/oakville-chinese-hope-church，它就会自动显示当前的实时翻译。这个安排目前是固定每个月的第一个星期天。需要实时翻译的内容同步显示在大屏幕 上，只占屏幕下方1/5高度的版面，显示两到三行文本，自动刷新。
===> Presenter_5.zip
	•	翻译窗口显示时间从10:40开始，且可以通过快捷键手工打开/关闭（可以用同一个快捷键）
	•	翻译窗口可否叠加到Pdf上方显示？我们制作Pdf时可以将需要使用翻译窗口的页面下边1/5留白


===> Presenter_6.zip
可否自动到指定的Google Drive找到符合条件的Google Slides 并存为pdf文件到Download目录？每个周日应该只有两个文件符合条件，一个文件名为：yyyymmdd，另一个符合正则表达式"^[A-Z][a-z]+-yyyymmdd$"。需要满足什么条件可以做到这个过程自动化？
这次下载成功了，但目标文件在~/Download/rclone_test/20261115.pdf。请让其下载到Download目录下，并且将Presenter自动做这件事。

====> Presenter_8.zip

如何实现自动提取指定Sound Input的内容并同步显示在屏幕上？类似Youtube的自动cc 功能 ，支持英语和普通话即可，如果能互译就更好了。
Google Drive下载问题已经解决。 Air 的MacOS版本： Tahoe 26.4, Memory: 8GB OBS用的音频输入设备名称： Maono ProStudio 2x2 Lite 保留Kaleo的功能，同时实现Apple 本机识别 + Apple 翻译。 使用时可以从这两者中选择，不需要同时显示，但需要可随时切换到其中任意一种实现。

===> Presenter_9.zip
%  ./build.sh ./build.sh: line 28: SDKV?: unbound variable % xcrun --show-sdk-version 27.2
===> Presenter_10.zip

% sed -i '' 's/\$SDKV：/${SDKV}：/; s/\$SDKV（/${SDKV}（/' build.sh % ./build.sh                                                        ▶ macOS SDK 27.2：包含本机识别 + 翻译 ▶ 正在编译（Apple 芯片 arm64）… error: unknown argument: '-weak_framework' ❌ 编译失败，请把上面的错误信息发给我

sed -i '' 's/-weak_framework Translation/-framework Translation/' build.sh
./build.sh


如何用MacBook Built-in Mic 作测试？或者直接将其设定为可命令行指定?


===>Presenter_11.zip

设置 > General>Language&Region>Transaction Language中，普通话 和 英语 已经下载。
运行没有显示，日志部分内容如下： [2026-11-15 01:37:14.193] 实时翻译：显示（手动） [2026-11-15 01:37:14.196] 显示实时翻译 [2026-11-15 01:37:14.201] 本机识别：开始（普通话，输入 MacBook） [2026-11-15 01:37:14.202] 本机识别：启动中… [2026-11-15 01:37:14.325] 本机识别：正在下载普通话识别模型…（第一次需要几分钟） [2026-11-15 01:37:14.596] 本机识别：✅ 正在识别普通话，翻成英语（MacBook Air Microphone） [2026-11-15 01:37:14.644] 本机识别：已停止 [2026-11-15 01:37:14.644] 本机识别：⚠️ 音频设备有变化，几秒后自动重新开始 [2026-11-15 01:37:17.645] 本机识别：开始（普通话，输入 MacBook） [2026-11-15 01:37:17.646] 本机识别：启动中… [2026-11-15 01:37:17.674] 本机识别：正在下载普通话识别模型…（第一次需要几分钟） [2026-11-15 01:37:17.910] 本机识别：✅ 正在识别普通话，翻成英语（MacBook Air Microphone）


===>Presenter_12.zip
几个改进点：
	•	快捷键给： 只显示原文，只显示译文，同时显示原文和译文
	•	主菜单项太多，将不常用的作为二级菜单：PDF 文件类 （除从Google Drive重新下载外）。
将菜单中 pdf1, pdf2 改名为：主日学，敬拜

====> Presenter_13.zip
现在所有目的都实现了。 下一步，如何能提高翻译的质量，比如，一些专有的名词，地名，人名，等，有什么办法来提升翻译的质量？
实现 1，2（可快捷切换），3，5，6，并列出从6中抽取内容加入1中具体过程。
===> Presenter_14.zip

今天使用中发现： - 字幕更新的方式不便于实时阅读，改成从左到右，一行一行向上滚动的方式。 - 字幕在屏幕上占比宽度左右留白10%。  - 讲员语速偏快，很多该有标点符号的地方都没有出现导致很长的句子。
另：字幕只在投影屏上显示，如果OBS的场景只有摄像机时，线上听众是看不到的。请将字幕同时也叠加到视频上，这样OBS无论如何切换摄像头或屏幕，线上听众都可以看到字幕。

===> Presenter_15.zip



生成一份操作手册，

==> Presenter 操作手册.md

修改代码，从configjson中将 private的内容分离出来，生成priv.json，加入.gitignore 以避免加入Repo；


❯ 将config.json中敏感信息单列出来放另一个json文件，并且将这个文件放入.gitignore中。同时，再生成一个glossary-priv.csv作为自定义的术语表，不存入repo. 这三个术语表分工如下，优先级从低到高：
  - glossary.csv  一般性的术语表，与圣经及本教会无关
  - glossary-bible.csv ， 圣经相关的术语表，除现有的内容外，以后还可能加入一些常见神学术语等
  - glossary-priv.csv  与教会相关的术语，包括教牧同工姓名，各团契名，等

 关于rclone的设置是否也可以放到config-priv.json，并且在程序中自动配置rclone？
 
  可否让build.sh生成的文件，直接放入repo的某个特定branch，这样，在Air上或其他机器上（相同配置不同机器，比如新换一台Mac Air作直播时）直接Clone后就使用？以后每次升级，也只需这边Build+push，那边Fetch就可以工作了。



❯ 仓库公开，对教会名称在仓库中并不介意，但从规范Best Practice角度，单独设定一个stage-priv.html中stage-local.html文件更Decent一些。
  config.json中对音频源用系统默认，允许在config-priv.json中高定同名配置覆盖。
  config-priv.json 和 config-local.jsaon哪个名字更好？
  crontab 和 彩排 均提供相应的shell Script,或不现一个script带不同的运行参数实现
  releaes仓库可否删除历史，比如10次以前的版本就删除，这样仓库增加到包含最近10次Relase后就不会因Relase再增大了。如实在需要以前的Relase，可以通过切换到以前的版本重新Build得到。
  对rclone先方案B :  A  + 自动配置，用服务帐号
  build.sh 打包时不带凭证，手工到Air（或以后新的Air电脑，或其他教会想用同样的Presenter的自己的电脑）上配置。






