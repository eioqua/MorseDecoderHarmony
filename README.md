# 摩斯通联（MorseTonglian）

一个 HarmonyOS（ArkTS / Stage 模型）应用：把摩斯电码实时翻译成文字——既能手敲，也能**听声音**。附带编码、码表、设置、深色模式，以及给业余无线电用的**通联日志**（QSO Log）。

- 包名 `com.morse.tonglian`，应用名「摩斯通联」（桌面图标）。
- 三种输入：手敲 `.` `-`、用手机麦克风听、或内录手机正在播放的音频。
- 手敲输入：直接敲 `.` `-`、用空格分隔字母、用 `/`（或连续空格）分隔单词，边输边解码。
- 字符集：26 个英文字母 + 10 个数字 + 18 个常用标点。
- 通联日志：记录双方呼号、时间、频率/波段、RST 信号报告、设备/天线/功率、QTH、备注，可带上当时识别到的摩斯码、译文和**现场录音**，一键导出 ADIF（可直接导入 N1MM / Log4OM 等日志软件）或纯文本。
- 引擎与界面分离：解码逻辑在 `MorseCodec`，识别算法在 `MorseAudio`，通联日志在 `QsoLog` + `QsoAudio`（都是纯逻辑，不依赖 ArkUI / 系统音频 API），采集封装在 `MorseAudioCapture`，设置映射在 `MorseSettings` —— 逻辑全部可单元测试。

## 界面结构

左侧抽屉（**自绘**，不用 `SideBarContainer`——它没有动画属性、也不给"点内容区收回"的遮罩）：

- 打开：点左上角 ☰，或**从屏幕最左边缘（20vp 热区）向右拖**——拖动过程中面板跟着手指走，松手时按"进度过 45% 或甩动速度超过 400vp/s"决定去留，再用动画补完剩余距离（滑入 240ms / 收回 190ms，`Curve.Friction` 展开、`Curve.EaseIn` 收回）；
- 收回：点右侧遮罩、在遮罩上向左滑、或点侧栏里的任意条目；
- 实现要点：面板位移用 `translate`、遮罩用 `opacity`，两者都由**同一个** `drawerAnim`（0→1）驱动，因此天然同步；面板与遮罩常驻渲染，用 `hitTestBehavior` 控制是否吃点击（收起后为 `HitTestMode.None`，不会误挡内容）；拖动期间由 `drawerDragging` 保证热区始终可命中，否则手势链会在拖动中途断掉。

五个页面：

| 页面 | 内容 |
| --- | --- |
| 声音识别（首页） | 打开就在这一页：麦克风 / 内录两个来源按钮、实时状态（正在接收信号 / 正在聆听 / 锁定频率）、音量条、速度·点长·划长·纯度·采样率·录音时长信息条、识别结果（明文 + 摩斯码）、开始/停止聆听、清空重听、复制明文/摩斯码、一键送进编解码页、**保存到通联日志**（连摩斯码、译文和这段录音一起带走） |
| 编解码 | **同一页**用顶部"摩斯 → 明文 / 明文 → 摩斯"分段开关切换：解码侧有屏幕键盘（`·` `—` 字母间隔 单词间隔 退格 清空 载入示例）与"正在输入"预览；编码侧输入明文实时出摩斯码，可复制或回填验证 |
| 通联日志 | 记录列表（呼号、UTC 时间、频率/波段/模式/RST/设备/录音时长，带 ♪ 标记有录音）+ 新建/编辑表单 + 删除 + 导出 ADIF / 文本 |
| 码表 | 全部 54 条摩斯电码对照表 |
| 设置 | 识别频率（自动 / 手动 + 预设）、降噪强度、灵敏度、检测带宽、外观（跟随系统 / 浅色 / 深色）、**电台信息（我方呼号 / 常用设备，新建日志时预填）**、恢复默认 |

所有设置项用 `PersistentStorage` 落盘（键：`mdToneHz`、`mdToleranceHz`、`mdDenoise`、`mdSensitivity`、`mdColorMode`、`mdMyCall`、`mdMyRig`），退出重进仍然保留。

## 深色模式

- 颜色全部走资源引用（`$r('app.color.…')`）：`entry/src/main/resources/base/element/color.json` 与 `entry/src/main/resources/dark/element/color.json` 各定义同一套 15 个色名，系统按深浅色限定符自动挑选。
- 「跟随系统」把 `ColorMode` 设回 `COLOR_MODE_NOT_SET`，浅色/深色则强制 `COLOR_MODE_LIGHT` / `COLOR_MODE_DARK`：

  ```ts
  (ctx as common.UIAbilityContext).getApplicationContext()
    .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  ```

## 容错规则（手敲）

写摩斯码时常见的异体字符都会被正确识别，不必刻意切换输入法：

- 点：`.` `·` `•` `●` `．` `。` `∙` `⋅`
- 划：`-` `－` `—` `–` `―` `−` `_` `¯`
- 单词分隔：`/` `|` `\` `／` `｜`，或**连续 2 个及以上空格**（`decode` 里也接受一个 `/`）
- 字母分隔：任意空白字符（含全角空格 `\u3000`、制表符、换行）
- 其余无法识别的字符：忽略，并当作一个字母分隔符（不会把无关字符悄悄并进同一个编码单元）

解码时无法识别的编码单元会输出 `?`，并在界面上单独列出，便于定位输入错误。

## 声音识别（麦克风 / 手机内录）

两种声音来源：

- **麦克风识别**：用手机麦克风收听旁边设备（对讲机、电台、音箱）外放的摩斯音。需要 `ohos.permission.MICROPHONE`（用户态权限，首次点击会弹系统对话框）。
- **手机内录**：直接抓手机正在播放的音频（在别的 App 里放一段摩斯音频即可），不需要麦克风权限，但要系统当场授权（API 26 的 `requestPlaybackCaptureStart`），部分机型/版本不支持。

### 识别流程

`entry/src/main/ets/model/MorseAudio.ets`（纯逻辑，与系统 API 完全解耦）：

1. `MorseAudio.pcm16ToMonoFloat()` 把采集到的 16bit 交错 PCM 降混成单声道 Float32；
2. 两级一阶低通 + 整数抽取到约 8kHz，按 5ms 分帧；
3. 每帧在**滑动窗**上做 **Goertzel 单频检测**：窗长由检测带宽决定（`analysisRate / toleranceHz`，即 20Hz → 50ms 窗，约 16.7Hz 分辨率），同时算窗内总功率，得到**音调纯度** `purity = 目标频点功率 / 全带功率`；
4. **选频**：未锁定时每帧在 300–1500Hz（步进 25Hz）的频点库上扫描，取幅度最大者；一旦确认第一个音调就锁定该频点不再扫描，静默超过 2.5 秒后重新扫描。手动设定频率时直接锁定、永不换频；
5. 开录后前 300ms 作为校准窗口，取"最小一半帧幅度"的均值当噪声底（即使一开录信号就在响也不会把底噪抬高）；之后噪声底"快降慢升"、峰值"快升慢降"各自跟踪；
6. **门限**：起振门限 = `max(噪声底 × (3.6 × sensitivity / 0.45), 音调电平 × 0.5)`，停振门限 = 起振门限 × 0.5（正向滞回），再要求连续 2 帧确认以抑制抖动；
   - 音调电平是一条 15ms 时间常数的跟踪器，"半高门限"让包络的上升沿与下降沿被**对称**切割 —— 否则点划时长会系统性偏长（实测偏差可达 +17ms）；
   - **纯度门限**（由降噪强度映射）额外要求"像纯正弦"，人声、音乐、啪啪声等宽带噪声过不了；
7. 段时长序列 → **自适应点划估计**：把标记时长做 2 簇聚类（点簇 / 划簇），再用整数比拟合（1u / 3u / 7u 窗口）精修单位时长；字母内间隔恒为 1u，用它把单位时长向下校正；两簇不成比例时按"速度先验"（25–150ms，取更接近 60ms 的假设）消歧 —— 这正是 `TTTT` 与 `H` 这种同形序列的分辨依据；
8. 相邻两段之间的静默若短于自适应合并阈值（不小于 `minGapMs`），视为**发送方丢点/瞬断**而合并；
9. 输出归一化的摩斯码字符串，直接交给已有的 `MorseCodec.decode()` —— 声音与手敲共用同一套码表。

界面用 120ms 定时器轮询采集状态（`AudioCapturer.on('readData')` 回调里只做"降混 + 送检测器"，不碰 UI，避免跨线程改状态）。

### 设置项与算法参数的映射

| 设置 | 默认 | 作用 |
| --- | --- | --- |
| 识别频率 | 自动（0） | >0 时锁死该频点（常见电键侧音 600–1000Hz），频带外噪声直接挡掉 |
| 检测带宽 | 20 Hz | 窗长 = 采样率 / 带宽；越小越抗噪，越大越容忍对方频率漂移（改动需重新开始聆听） |
| 降噪强度 | 40 | → 纯度门限 `0.20 + 0.60 × d/100`、最短音长 `8 + 12 × d/100` ms |
| 灵敏度 | 50 | → 门限系数 `0.10 + 0.70 × v/100`（50 即检测器默认的 0.45） |
| 外观 | 跟随系统 | `setColorMode(COLOR_MODE_NOT_SET / LIGHT / DARK)` |
| 我方呼号 / 常用设备 | 空 | 新建通联记录时预填 `station_callsign` 与 `my_rig`，单条记录仍可改 |

### 采集配置

`MorseAudioCapture` 会按优先级**逐个尝试**采样率/声道组合（麦克风 48k 单声道 → 16k 单声道 → 48k 双声道 → 44.1k 双声道；内录 48k 双声道 → 48k 单声道 → 44.1k 双声道），第一个创建成功的组合生效，检测器按实际采样率初始化——不同设备支持的组合不一样，这样比写死一个更稳。

### 已知限制

- **没有真机验证过**：开发机上 `hdc list targets` 返回 `[Empty]`（无设备、无模拟器），采集层只做到"编译通过 + 静态审查"；DSP 部分用合成音频做了完整单元测试。
- **内录可能拿不到授权**：`ohos.permission.CAPTURE_PLAYBACK` 是 `system_grant` + `system_core` 权限，普通应用拿不到，因此**没有**在 `module.json5` 里声明它；内录走 API 26 的 `playbackCaptureMode` + `requestPlaybackCaptureStart`，被系统拒绝时会提示"改用麦克风识别"。
- **API 26 特性 vs 兼容版本 24**：`build-profile.json5` 的 `compatibleSdkVersion` 是 `6.1.1(24)`，引用 `AudioPlaybackCaptureMode` 会有一条"API 版本高于兼容版本"的编译警告（内录路径专有），麦克风路径不受影响。
- 识别需要相对干净的声音：**选频 + 纯度门限能挡掉大部分杂音**，但如果杂音恰好落在目标频点附近（同频干扰），或对方发报速度低到点长接近毛刺长度，仍可能出错。
- 极快发报（点长 < ~25ms，即快于 48 WPM）超出本引擎的可靠范围（8ms 包络窗 + 5ms 帧）。

## 通联日志（QSO Log）

业余无线电通联记录，字段按 ADIF 标准组织：

| 字段 | ADIF 标签 | 说明 |
| --- | --- | --- |
| 通联时间 | `qso_date` / `time_on` | UTC，界面按 `YYYY-MM-DD HH:mm` 填写（只填日期就按当天 00:00 UTC） |
| 对方呼号 / 我方呼号 | `call` / `station_callsign` | 我方呼号默认取设置里的"电台信息" |
| 频率、波段 | `freq` / `band` | 频率填 kHz，波段留空时按 IARU 波段表自动判断（160m…70cm）；导出时 `freq` 换算成 MHz |
| 模式 | `mode` | 默认 CW，留空导出时也按 CW |
| 信号报告 | `rst_sent` / `rst_rcvd` | 默认 599 / 599 |
| 设备 / 天线 / 功率 | `my_rig` / `my_ant` / `tx_pwr` | 设备默认取设置里的常用型号 |
| 对方 QTH | `qth` | |
| 备注 | `comment` | 天气、卡片收发等 |
| 摩斯码 / 译文 / 录音时长 | `app_morse_code` / `app_morse_text` / `app_audio_ms` | 应用私有标签，别的软件会忽略 |

- **录音**：从「声音识别」页点"保存到通联日志"时，把这次聆听的音频一起带过来（也可以先停止聆听再保存，采集停止前已经留了一份）。音频实时降采样成 **8kHz 单声道 16bit WAV**（`QsoAudio`，约 16 KB/s，10 分钟约 9.6MB，上限 10 分钟），存到应用沙箱 `filesDir/qso_audio/<记录id>.wav`；删除记录时连音频一起删。
- **存储**：记录本身用 `preferences`（文件名 `morse_qso`，键 `records`）存一段 JSON——几十到几千条一次读写足够，省掉建库建表。读回来时按 `normalizeRecord` 逐字段兜底，兼容旧版本缺字段的数据。
- **导出**：
  - 「导出 ADIF」生成 ADIF 3.1.4（头 `<adif_ver:5>3.1.4 <programid:13>MorseTonglian <EOH>`，逐条 `<EOR>`），字段长度按 **UTF-8 字节数**计算（中文备注才不会被写坏），可直接导入 N1MM、Log4OM 等；
  - 「导出文本」生成便于粘贴的纯文本；
  - 两者都会**复制到剪贴板**并在沙箱 `filesDir/qso_export/` 写一份文件（应用沙箱普通用户看不见，所以要复制一份）。

## 目录结构

```
MorseDecoder/                         # 工程目录名仍叫 MorseDecoder，应用名与包名已改成「摩斯通联」/ com.morse.tonglian
├── AppScope/                       # 应用级配置与资源（app_name = 摩斯通联）
├── entry/
│   └── src/
│       ├── main/
│       │   ├── ets/
│       │   │   ├── entryability/EntryAbility.ets     # 入口 UIAbility（含 setColorMode 跟随系统）
│       │   │   ├── model/MorseCodec.ets              # 摩斯码表 + 编码/解码/归一化（纯逻辑）
│       │   │   ├── model/MorseAudio.ets              # 音调检测 + 点划自适应（纯逻辑 DSP）
│       │   │   ├── model/MorseAudioCapture.ets       # AudioCapturer 采集封装 + 权限 + 录音缓冲
│       │   │   ├── model/QsoAudio.ets                # 通联录音：降采样到 8kHz、WAV(16bit 单声道) 编码
│       │   │   ├── model/QsoLog.ets                  # 通联记录：preferences 存储、波段表、ADIF/文本导出
│       │   │   ├── model/MorseSettings.ets           # 设置项键名/默认值/映射 + 落盘注册
│       │   │   └── pages/Index.ets                   # 自绘侧栏 + 五页面（声音识别 / 编解码 / 通联日志 / 码表 / 设置）
│       │   ├── resources/base/element/color.json     # 浅色配色（16 个色名）
│       │   ├── resources/dark/element/color.json     # 深色配色（同名同数量）
│       │   ├── resources/base/element/string.json    # 应用名、模块描述、麦克风权限理由
│       │   └── module.json5                          # ohos.permission.MICROPHONE（user_grant）
│       └── test/
│           ├── List.test.ets                         # 测试入口（三个套件）
│           ├── LocalUnit.test.ets                    # MorseCodec：13 个用例
│           ├── MorseAudio.test.ets                   # MorseAudio：30 个用例（含合成音频回归）
│           └── QsoLog.test.ets                       # QsoLog + QsoAudio：14 个用例（ADIF/WAV/波段）
└── build-profile.json5                               # signingConfigs 由 DevEco 自动生成（改包名后必须重新生成）
```

## 构建与测试

用 DevEco Studio 自带的 hvigor（工程根目录没有 hvigorw，用安装目录里的那个）：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
# 关键：SignHap 会用 PATH 上的 java，必须让它是 DevEco 自带的 JBR
$env:JAVA_HOME = 'C:\Program Files\Huawei\DevEco Studio\jbr'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;C:\Program Files\Huawei\DevEco Studio\tools\node;' + $env:Path
$hv = 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat'

# 单元测试（约 2.5 分钟）
& $hv --mode module -p product=default -p buildMode=debug test --no-daemon
# 打包（约 1 分钟；产物 entry/build/default/outputs/default/entry-default-signed.hap）
& $hv --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

两个坑：

- **`JAVA_HOME` 必须是 DevEco 的 JBR**。若 PATH 上是别的 JDK（本机是 `C:\Program Files\Java\jdk-17`），编译、打包都正常，但最后 `SignHap` 会报 `ERROR: 11012006 File IO failed / Invalid CEN header (invalid zip64 extra data field size)`，构建以 exit code 1 结束（HAP 已经生成，只是没签名）。
- **hvigor 打印 `BUILD SUCCESSFUL` 不代表用例全过**：用例失败时它照样返回 0 并打印成功，要 grep 日志里的 `ERROR: Error in <用例名>` 或看报告。

### 改了包名之后必须重新生成签名

签名配置文件里钉着当初生成它时的 `bundle-name`（旧的是 `com.example.morsedecoder`）。包名改成 `com.morse.tonglian` 后，`assembleHap` 会在最后一步失败：

```
ERROR: 00303074 Configuration Error
Error Message: The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs.
At file: build-profile.json5
```

修法：在 DevEco Studio 里 `File → Project Structure → Signing Configs`，勾选自动签名（或点它提示的 **Fix**）让它按新包名重新生成证书/profile；也可以删掉 `build-profile.json5` 里 `app.signingConfigs` 那一段，重新打开工程时让它生成。**这一步必须在 DevEco 里做**——签名用的 `.p7b` profile 只能由 DevEco/AGC 签发，命令行改不了。

只想验证代码能不能编译（不签名）时，用 `assembleHap` 看 `Finished :entry:default@CompileArkTS` 且日志里没有 `ArkTS Compiler Error` 即可——签名之前的编译、打包都已经成功。

测试报告与覆盖率：`entry/.test/default/outputs/test/reports/index.html`。

当前状态（本轮实测）：`test` → **57 个用例全部通过**（13 个 `MorseCodec` + 30 个 `MorseAudio` + 14 个 `QsoLog`/`QsoAudio`；覆盖 48k/44.1k 采样率、带噪/巨响噪声/咔哒声、慢速与快速、点划同形消歧、丢点合并、窄带宽、手动锁频与异频干扰、流式推送、WAV 头与 8kHz 抽取、ADIF 字段与 UTF-8 长度、波段边界等场景）。覆盖率：行 1011/1308 = 77.3%、函数 77/110 = 70%、分支 342/536 = 63.8%——`QsoAudio` 行覆盖 87/92、函数 13/13，`QsoLog` 行 163/334（未覆盖的是它依赖 `preferences`/`fileIo`/`Context` 的那部分方法，纯逻辑函数都已覆盖），Index.ets 的行 628/718 主要是界面分支。

## 后续可扩展

- 真机实测采集链路（麦克风 / 内录授权），按机型调整 profile 优先级；
- 内录拿不到授权时自动回落麦克风；
- 通联日志：录音回放（WAV 已存沙箱，接 `AudioRenderer` 即可）、按呼号/波段筛选、CSV 导出、导入 ADIF；
- 识别结果的时间轴视图（波形 + 点划标注）便于调参；
- 用摩斯音播放编码结果（`MorseAudio.synthesize()` 已经能合成音频，接上 `AudioRenderer` 即可）；
- 通联记录云同步与分享。
