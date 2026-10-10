import { MorseCodec, MorseDecodeResult, MorseEntry } from '../model/MorseCodec';
import { MorseAudioCapture, MorseCaptureSource, MorseCaptureStatus } from '../model/MorseAudioCapture';
import { MorseToneOptions } from '../model/MorseAudio';
import {
  bandOf,
  freqText,
  isoFromUtcText,
  newQsoRecord,
  QsoLog,
  QsoRecord,
  recordTime,
  toAdif,
  toText,
  utcFileStamp,
  utcText
} from '../model/QsoLog';
import {
  buildToneOptions,
  denoiseToMinMarkMs,
  denoiseToPurity,
  DEFAULT_COLOR_MODE,
  DEFAULT_DENOISE,
  DEFAULT_MY_CALL,
  DEFAULT_MY_RIG,
  DEFAULT_SENSITIVITY,
  DEFAULT_TOLERANCE,
  DEFAULT_TONE_HZ,
  DENOISE_MAX,
  DENOISE_MIN,
  KEY_COLOR_MODE,
  KEY_DENOISE,
  KEY_MY_CALL,
  KEY_MY_RIG,
  KEY_SENSITIVITY,
  KEY_TOLERANCE,
  KEY_TONE_HZ,
  MorseUiSettings,
  registerMorseSettings,
  SENSITIVITY_MAX,
  SENSITIVITY_MIN,
  TOLERANCE_MAX,
  TOLERANCE_MIN,
  TONE_HZ_MAX,
  TONE_HZ_MIN,
  TONE_HZ_STEP
} from '../model/MorseSettings';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

// 必须在任何组件构造之前注册，否则 @StorageLink 会先用默认值建键、把上次保存的设置覆盖掉
registerMorseSettings();

/** 侧栏页面 */
const PAGE_LISTEN = 0;
const PAGE_CODEC = 1;
const PAGE_TABLE = 2;
const PAGE_SETTINGS = 3;
const PAGE_LOG = 4;
/** 编解码页的两种模式 */
const MODE_DECODE = 0;
const MODE_ENCODE = 1;
/** 外观取值 */
const COLOR_SYSTEM = 'system';
const COLOR_LIGHT = 'light';
const COLOR_DARK = 'dark';

/** 常用的电键侧音频率，方便一键切到常见值 */
const TONE_PRESETS: number[] = [600, 700, 800, 1000];

/** 侧栏抽屉：宽度（vp）与展开/收起时长（ms） */
const DRAWER_WIDTH = 218;
const DRAWER_OPEN_MS = 240;
const DRAWER_CLOSE_MS = 190;
/** 手势：左边缘起手热区宽度、甩动判定速度（vp/s）、补完动画的最短时长 */
const DRAWER_EDGE_WIDTH = 20;
const DRAWER_FLING = 400;
const DRAWER_MIN_MS = 80;

/** 把任意值夹到 0~1，用于抽屉进度 */
function clamp01(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

/**
 * 应用主界面：侧栏（声音识别 / 编解码 / 码表 / 设置）+ 内容区。
 * 首页就是声音识别：打开就能听，不再需要先切页签。
 */
@Entry
@Component
struct Index {
  // ---------------- 设置（PersistentStorage 落盘，改完立刻生效） ----------------
  @StorageLink(KEY_TONE_HZ) toneHzSetting: number = DEFAULT_TONE_HZ;
  @StorageLink(KEY_TOLERANCE) tolerance: number = DEFAULT_TOLERANCE;
  @StorageLink(KEY_DENOISE) @Watch('onRecognitionSettingChanged') denoise: number = DEFAULT_DENOISE;
  @StorageLink(KEY_SENSITIVITY) @Watch('onRecognitionSettingChanged') sensitivity: number = DEFAULT_SENSITIVITY;
  @StorageLink(KEY_COLOR_MODE) @Watch('onColorModeChanged') colorMode: string = DEFAULT_COLOR_MODE;

  // ---------------- 界面状态 ----------------
  @State sidebarIndex: number = PAGE_LISTEN;
  /** 抽屉是否处于"已展开"逻辑状态（true 时遮罩与面板响应点击） */
  @State drawerOpen: boolean = false;
  /** 抽屉动画进度：0 = 完全收起，1 = 完全展开；驱动面板位移与遮罩透明度 */
  @State drawerAnim: number = 0;
  /** 手势拖动中：拖动期间热区必须保持可命中，否则手势链会当场中断 */
  @State drawerDragging: boolean = false;
  @State autoTone: boolean = true;

  // ---------------- 解码 ----------------
  @State morseInput: string = '';
  @State decoded: string = '';
  @State unknownText: string = '';
  @State currentToken: string = '';
  @State currentLetter: string = '';
  @State letterCount: number = 0;
  @State wordCount: number = 0;

  // ---------------- 编码 ----------------
  @State plainInput: string = '';
  @State encoded: string = '';
  @State codecMode: number = MODE_DECODE;

  // ---------------- 码表 ----------------
  @State table: MorseEntry[] = [];

  // ---------------- 声音识别 ----------------
  @State captureSource: MorseCaptureSource = MorseCaptureSource.MIC;
  @State captureRunning: boolean = false;
  @State captureStarting: boolean = false;
  @State captureError: string = '';
  @State captureDenied: boolean = false;
  @State captureToneOn: boolean = false;
  @State captureLevel: number = 0;
  @State captureToneHz: number = 0;
  @State captureWpm: number = 0;
  @State captureDotMs: number = 0;
  @State captureDashMs: number = 0;
  @State capturePurity: number = 0;
  @State captureLocked: boolean = false;
  @State captureMorse: string = '';
  @State captureText: string = '';
  @State captureMarkCount: number = 0;
  @State captureSampleRate: number = 0;
  @State captureAudioMs: number = 0;
  /** 是否有可挂到日志上的录音（正在听或刚听完） */
  @State logAudioReady: boolean = false;
  private capture: MorseAudioCapture | undefined = undefined;
  private captureTimer: number = -1;
  /** 停止聆听后保留的最后一段录音：停下来也还能存进通联日志 */
  private lastWav: ArrayBuffer | undefined = undefined;
  private lastAudioMs: number = 0;

  // ---------------- 通联日志 ----------------
  @StorageLink(KEY_MY_CALL) myCallSetting: string = DEFAULT_MY_CALL;
  @StorageLink(KEY_MY_RIG) myRigSetting: string = DEFAULT_MY_RIG;
  @State logRecords: QsoRecord[] = [];
  @State logEditing: boolean = false;
  @State logMessage: string = '';
  /** 正在编辑的记录 id（''＝新建） */
  @State logEditId: string = '';
  @State logEditAudioFile: string = '';
  @State logEditAudioMs: number = 0;
  /** 本次要写盘的录音时长（0＝没有新录音） */
  @State pendingMs: number = 0;
  private pendingWav: ArrayBuffer | undefined = undefined;
  private log: QsoLog | undefined = undefined;
  /** 编辑表单：一个字段一个状态，改哪块只重绘哪块 */
  @State fTime: string = '';
  @State fCall: string = '';
  @State fMyCall: string = '';
  @State fFreq: string = '';
  @State fBand: string = '';
  @State fMode: string = 'CW';
  @State fRstSent: string = '599';
  @State fRstRcvd: string = '599';
  @State fQth: string = '';
  @State fRig: string = '';
  @State fAntenna: string = '';
  @State fPower: string = '';
  @State fNotes: string = '';
  @State fMorse: string = '';
  @State fText: string = '';

  aboutToAppear(): void {
    this.table = MorseCodec.table();
    this.autoTone = this.toneHzSetting <= 0;
    this.applyColorMode();
    this.initLog();
  }

  aboutToDisappear(): void {
    this.stopCapture();
  }

  // ---------------- 设置 ----------------

  /** 当前设置翻译成识别参数 */
  private toneOptions(): MorseToneOptions {
    const settings: MorseUiSettings = {
      toneHz: this.toneHzSetting,
      toleranceHz: this.tolerance,
      denoise: this.denoise,
      sensitivity: this.sensitivity
    };
    return buildToneOptions(settings);
  }

  /** 聆听中改设置：立刻推给正在跑的检测器 */
  private onRecognitionSettingChanged(): void {
    const cap = this.capture;
    if (cap !== undefined) {
      cap.setToneOptions(this.toneOptions());
    }
  }

  private onColorModeChanged(): void {
    this.applyColorMode();
  }

  /** 跟随系统 / 强制浅色 / 强制深色 */
  private applyColorMode(): void {
    let mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (this.colorMode === COLOR_LIGHT) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (this.colorMode === COLOR_DARK) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        (ctx as common.UIAbilityContext).getApplicationContext().setColorMode(mode);
      }
    } catch (err) {
      console.error('setColorMode failed: ' + JSON.stringify(err));
    }
  }

  private resetSettings(): void {
    this.toneHzSetting = DEFAULT_TONE_HZ;
    this.tolerance = DEFAULT_TOLERANCE;
    this.denoise = DEFAULT_DENOISE;
    this.sensitivity = DEFAULT_SENSITIVITY;
    this.autoTone = true;
    this.onRecognitionSettingChanged();
    this.toast('已恢复默认设置');
  }

  private setToneHz(hz: number): void {
    this.toneHzSetting = hz;
    this.autoTone = false;
    this.onRecognitionSettingChanged();
  }

  private setAutoTone(on: boolean): void {
    this.autoTone = on;
    this.toneHzSetting = on ? 0 : 700;
    this.onRecognitionSettingChanged();
  }

  private colorModeLabel(): string {
    if (this.colorMode === COLOR_LIGHT) {
      return '浅色';
    }
    if (this.colorMode === COLOR_DARK) {
      return '深色';
    }
    return '跟随系统';
  }

  // ---------------- 解码 / 编码 ----------------

  private refreshDecode(): void {
    const result: MorseDecodeResult = MorseCodec.decode(this.morseInput);
    this.decoded = result.text;
    this.unknownText = result.unknownTokens.join(' ');
    this.letterCount = result.letterCount;
    this.wordCount = result.wordCount;
    const token: string = MorseCodec.trailingToken(this.morseInput);
    this.currentToken = token;
    this.currentLetter = MorseCodec.letterOf(token);
  }

  private appendSymbol(symbol: string): void {
    this.morseInput = this.morseInput + symbol;
    this.refreshDecode();
  }

  private backspace(): void {
    if (this.morseInput.length === 0) {
      return;
    }
    this.morseInput = this.morseInput.substring(0, this.morseInput.length - 1);
    this.refreshDecode();
  }

  private clearInput(): void {
    this.morseInput = '';
    this.refreshDecode();
  }

  /** 把识别结果送进编解码页继续编辑 */
  private sendToCodec(morse: string): void {
    this.morseInput = morse;
    this.refreshDecode();
    this.codecMode = MODE_DECODE;
    this.sidebarIndex = PAGE_CODEC;
  }

  // ---------------- 通联日志 ----------------

  private initLog(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.log = new QsoLog(ctx as common.UIAbilityContext);
    this.logRecords = this.log.load();
  }

  /** 频率文本 -> kHz（非法输入按 0 处理） */
  private freqToKhz(text: string): number {
    const value = Number.parseFloat(text);
    if (Number.isNaN(value) || value <= 0) {
      return 0;
    }
    return value;
  }

  /** 表单字段 -> 记录 */
  private draftFromFields(): QsoRecord {
    const record = newQsoRecord(this.fMyCall, this.fRig);
    if (this.logEditId.length > 0) {
      record.id = this.logEditId;
    }
    const iso = isoFromUtcText(this.fTime);
    record.timeUtc = iso.length > 0 ? iso : new Date().toISOString();
    record.call = this.fCall;
    record.myCall = this.fMyCall;
    record.freqKhz = this.freqToKhz(this.fFreq);
    record.band = this.fBand.length > 0 ? this.fBand : bandOf(record.freqKhz);
    record.mode = this.fMode;
    record.rstSent = this.fRstSent;
    record.rstRcvd = this.fRstRcvd;
    record.qth = this.fQth;
    record.rig = this.fRig;
    record.antenna = this.fAntenna;
    record.powerW = this.fPower;
    record.notes = this.fNotes;
    record.morse = this.fMorse;
    record.text = this.fText;
    record.audioFile = this.logEditAudioFile;
    record.audioMs = this.logEditAudioMs;
    return record;
  }

  /** 记录 -> 表单字段 */
  private loadFields(record: QsoRecord): void {
    this.logEditId = record.id;
    this.fTime = utcText(recordTime(record));
    this.fCall = record.call;
    this.fMyCall = record.myCall.length > 0 ? record.myCall : this.myCallSetting;
    this.fFreq = record.freqKhz > 0 ? record.freqKhz.toFixed(1) : '';
    this.fBand = record.band;
    this.fMode = record.mode.length > 0 ? record.mode : 'CW';
    this.fRstSent = record.rstSent;
    this.fRstRcvd = record.rstRcvd;
    this.fQth = record.qth;
    this.fRig = record.rig.length > 0 ? record.rig : this.myRigSetting;
    this.fAntenna = record.antenna;
    this.fPower = record.powerW;
    this.fNotes = record.notes;
    this.fMorse = record.morse;
    this.fText = record.text;
    this.logEditAudioFile = record.audioFile;
    this.logEditAudioMs = record.audioMs;
    this.logMessage = '';
  }

  /** 新建记录：预填我方呼号/设备，并带上刚识别到的摩斯码与录音 */
  private startNewLog(): void {
    const record = newQsoRecord(this.myCallSetting, this.myRigSetting);
    record.morse = this.captureMorse;
    record.text = this.captureText;
    const cap = this.capture;
    let wav: ArrayBuffer | undefined = undefined;
    let ms = 0;
    if (cap !== undefined) {
      wav = cap.recordedWav();
      ms = cap.recordingMs();
    } else {
      wav = this.lastWav;
      ms = this.lastAudioMs;
    }
    if (wav !== undefined) {
      this.pendingWav = wav;
      this.pendingMs = ms;
      record.audioMs = ms;
    } else {
      this.pendingWav = undefined;
      this.pendingMs = 0;
    }
    this.loadFields(record);
    this.logEditing = true;
    this.sidebarIndex = PAGE_LOG;
  }

  private editLogEntry(record: QsoRecord): void {
    this.pendingWav = undefined;
    this.pendingMs = 0;
    this.loadFields(record);
    this.logEditing = true;
  }

  /** 保存表单：需要时先把录音写进沙箱，再落库 */
  private saveLogEntry(): void {
    const log = this.log;
    if (log === undefined) {
      this.toast('日志不可用');
      return;
    }
    const record = this.draftFromFields();
    const wav = this.pendingWav;
    if (wav !== undefined) {
      const fileName = log.saveAudio(record.id, wav);
      if (fileName.length > 0) {
        record.audioFile = fileName;
        if (this.pendingMs > 0) {
          record.audioMs = this.pendingMs;
        }
      } else {
        this.toast('录音写入失败，记录仍会保存');
      }
    }
    let ok = false;
    if (this.logEditId.length > 0) {
      ok = log.update(record);
    } else {
      ok = log.add(record);
    }
    this.logRecords = log.load();
    this.pendingWav = undefined;
    this.pendingMs = 0;
    this.logEditing = false;
    this.logMessage = ok ? '已保存' : '保存失败';
    this.toast(ok ? '已保存到通联日志' : '保存失败');
  }

  private cancelLogEdit(): void {
    this.pendingWav = undefined;
    this.pendingMs = 0;
    this.logEditing = false;
  }

  private deleteLogEntry(id: string): void {
    const log = this.log;
    if (log === undefined) {
      return;
    }
    log.remove(id);
    this.logRecords = log.load();
    if (this.logEditId === id) {
      this.logEditing = false;
    }
    this.toast('已删除记录');
  }

  /** 列表项 key：带上会变的字段，否则编辑完 ForEach 不会重建这一项 */
  private logKey(record: QsoRecord): string {
    return record.id + '|' + record.timeUtc + '|' + record.call + '|' + record.audioMs.toString() +
      '|' + record.rstSent + '|' + record.rstRcvd + '|' + record.notes.length.toString();
  }

  /** 列表项副标题：频率 / 波段 / 模式 / 信号报告 / 设备 / 录音 */
  private logSummaryLine(record: QsoRecord): string {
    const parts: string[] = [];
    const freq = freqText(record.freqKhz);
    if (freq.length > 0) {
      parts.push(freq);
    }
    const band = record.band.length > 0 ? record.band : bandOf(record.freqKhz);
    if (band.length > 0) {
      parts.push(band);
    }
    if (record.mode.length > 0) {
      parts.push(record.mode);
    }
    if (record.rstSent.length > 0 || record.rstRcvd.length > 0) {
      parts.push('RST ' + (record.rstSent.length > 0 ? record.rstSent : '-') + '/' +
        (record.rstRcvd.length > 0 ? record.rstRcvd : '-'));
    }
    if (record.rig.length > 0) {
      parts.push(record.rig);
    }
    if (record.audioMs > 0) {
      parts.push('录音 ' + Math.round(record.audioMs / 1000).toString() + 's');
    }
    if (parts.length === 0) {
      return '（暂无详情）';
    }
    return parts.join(' · ');
  }

  private exportAdif(): void {
    const text = toAdif(this.logRecords);
    this.copyToClipboard(text);
    this.writeExportFile('adif', text);
  }

  private exportText(): void {
    const text = toText(this.logRecords);
    this.copyToClipboard(text);
    this.writeExportFile('txt', text);
  }

  /** 除复制外，再往沙箱导出目录写一份文件 */
  private writeExportFile(ext: string, content: string): void {
    const log = this.log;
    if (log === undefined) {
      return;
    }
    const name = 'qso_' + utcFileStamp(new Date()) + '.' + ext;
    const path = log.writeExport(name, content);
    if (path.length > 0) {
      this.logMessage = '已复制到剪贴板，并写出 ' + name;
    } else {
      this.logMessage = '已复制到剪贴板（导出文件写入失败）';
    }
  }

  // ---------------- 声音识别 ----------------

  private beginCapture(source: MorseCaptureSource): void {
    if (this.captureRunning || this.captureStarting) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.captureError = '拿不到应用上下文，无法录音';
      return;
    }
    this.captureStarting = true;
    this.captureSource = source;
    this.captureError = '';
    this.captureDenied = false;
    this.captureToneOn = false;
    this.captureLevel = 0;
    this.captureToneHz = 0;
    this.captureWpm = 0;
    this.captureDotMs = 0;
    this.captureDashMs = 0;
    this.capturePurity = 0;
    this.captureLocked = false;
    this.captureMorse = '';
    this.captureText = '';
    this.captureMarkCount = 0;
    this.captureAudioMs = 0;
    this.logAudioReady = false;
    this.lastWav = undefined;
    this.lastAudioMs = 0;

    const cap = new MorseAudioCapture(ctx as common.UIAbilityContext, this.toneOptions());
    this.capture = cap;
    cap.start(source).then((ok: boolean) => {
      this.captureStarting = false;
      if (!ok) {
        const st: MorseCaptureStatus = cap.status();
        this.captureError = st.error;
        this.captureDenied = st.denied;
        this.capture = undefined;
        return;
      }
      this.captureRunning = true;
      this.startCaptureTimer();
    }).catch((err: BusinessError) => {
      this.captureStarting = false;
      this.captureError = '启动采集失败：' + err.message;
      this.capture = undefined;
    });
  }

  private startCaptureTimer(): void {
    this.clearCaptureTimer();
    this.captureTimer = setInterval(() => {
      this.pollCapture();
    }, 120);
  }

  private clearCaptureTimer(): void {
    if (this.captureTimer >= 0) {
      clearInterval(this.captureTimer);
      this.captureTimer = -1;
    }
  }

  /** 在主线程轮询采集状态：readData 回调在音频线程，绝不在那里改 @State */
  private pollCapture(): void {
    const cap = this.capture;
    if (cap === undefined) {
      this.clearCaptureTimer();
      return;
    }
    const st: MorseCaptureStatus = cap.status();
    this.captureError = st.error;
    this.captureDenied = st.denied;
    if (!st.running && !st.starting) {
      this.captureRunning = false;
      this.captureToneOn = false;
      this.captureLevel = 0;
      this.clearCaptureTimer();
      return;
    }
    this.captureRunning = true;
    this.captureToneOn = st.toneOn;
    this.captureLevel = st.level;
    this.captureToneHz = st.toneHz;
    this.captureWpm = st.wpm;
    this.captureDotMs = st.dotMs;
    this.captureDashMs = st.dashMs;
    this.capturePurity = st.purity;
    this.captureLocked = st.locked;
    this.captureMorse = st.morse;
    this.captureText = st.text;
    this.captureMarkCount = st.markCount;
    this.captureSampleRate = st.sampleRate;
    if (st.audioMs > 0) {
      this.captureAudioMs = st.audioMs;
      this.logAudioReady = true;
    }
  }

  private stopCapture(): void {
    this.clearCaptureTimer();
    const cap = this.capture;
    this.capture = undefined;
    this.captureRunning = false;
    this.captureStarting = false;
    this.captureToneOn = false;
    this.captureLevel = 0;
    if (cap !== undefined) {
      // 停止前先把录音留一份：停下来之后仍然可以存进通联日志
      const wav = cap.recordedWav();
      if (wav !== undefined) {
        this.lastWav = wav;
        this.lastAudioMs = cap.recordingMs();
        this.captureAudioMs = this.lastAudioMs;
        this.logAudioReady = true;
      }
      cap.stop().then(() => {
        console.info('capture stopped');
      }).catch((err: BusinessError) => {
        this.captureError = '停止采集失败：' + err.message;
      });
    }
  }

  private clearCapture(): void {
    const cap = this.capture;
    if (cap !== undefined) {
      cap.clear();
    }
    this.captureMorse = '';
    this.captureText = '';
    this.captureMarkCount = 0;
    this.captureAudioMs = 0;
    this.lastWav = undefined;
    this.lastAudioMs = 0;
    this.logAudioReady = false;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      console.error('showToast failed: ' + JSON.stringify(err));
    }
  }

  private copyToClipboard(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制到剪贴板');
      }).catch((err: BusinessError) => {
        this.toast('复制失败：' + err.message);
      });
    } catch (err) {
      const e = err as BusinessError;
      this.toast('复制失败：' + e.message);
    }
  }

  // ---------------- 公共样式 ----------------

  @Styles
  cardStyle() {
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
  }

  @Styles
  keyStyle() {
    .height(46)
    .layoutWeight(1)
    .backgroundColor($r('app.color.input_bg'))
    .borderRadius(10)
    .borderWidth(1)
    .borderColor($r('app.color.divider'))
  }

  @Styles
  actionStyle() {
    .height(44)
    .layoutWeight(1)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(10)
    .borderWidth(1)
    .borderColor($r('app.color.accent_border'))
  }

  @Styles
  formInput() {
    .width('100%')
    .height(40)
    .backgroundColor($r('app.color.input_bg'))
    .borderRadius(8)
  }

  private pageTitle(): string {
    if (this.sidebarIndex === PAGE_CODEC) {
      return this.codecMode === MODE_DECODE ? '摩斯 → 明文' : '明文 → 摩斯';
    }
    if (this.sidebarIndex === PAGE_TABLE) {
      return '摩斯码表';
    }
    if (this.sidebarIndex === PAGE_SETTINGS) {
      return '设置';
    }
    if (this.sidebarIndex === PAGE_LOG) {
      return this.logEditing ? '编辑通联记录' : '通联日志';
    }
    return '声音识别';
  }

  // ---------------- 侧栏 ----------------

  /**
   * 展开抽屉：先挂上遮罩（drawerOpen = true），再用 animateTo 把进度从 0 推到 1。
   * 只动 drawerAnim 这一个数字，位移与遮罩透明度都是它的函数，所以两者天然同步。
   */
  private openDrawer(): void {
    this.drawerOpen = true;
    this.getUIContext().animateTo({ duration: DRAWER_OPEN_MS, curve: Curve.Friction }, () => {
      this.drawerAnim = 1;
    });
  }

  /** 收起抽屉：动画跑到 0 之后才摘掉遮罩，避免中途漏点 */
  private closeDrawer(): void {
    this.getUIContext().animateTo({
      duration: DRAWER_CLOSE_MS,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.drawerOpen = false;
      }
    }, () => {
      this.drawerAnim = 0;
    });
  }

  private toggleDrawer(): void {
    if (this.drawerOpen) {
      this.closeDrawer();
    } else {
      this.openDrawer();
    }
  }

  // ---------------- 抽屉手势（拖动跟手，松手补完动画） ----------------

  /** 手指按下：面板与遮罩就位，并进入跟手模式（此时热区要保持可命中） */
  private onDrawerDragStart(): void {
    this.drawerOpen = true;
    this.drawerDragging = true;
  }

  /**
   * 跟手：进度 = 起点进度 + 手指位移 / 面板宽。
   * 这里刻意不用 animateTo —— 拖动要即时响应，动画只用在松手之后。
   */
  private onDrawerDragUpdate(base: number, offsetX: number): void {
    this.drawerAnim = clamp01(base + offsetX / DRAWER_WIDTH);
  }

  /** 松手：先看甩动速度（向左为负），速度不够就看进度过没过一半，再用动画补完 */
  private onDrawerDragEnd(velocityX: number): void {
    this.drawerDragging = false;
    let target = 0;
    if (velocityX > DRAWER_FLING) {
      target = 1;
    } else if (velocityX < -DRAWER_FLING) {
      target = 0;
    } else {
      target = this.drawerAnim > 0.45 ? 1 : 0;
    }
    // 剩余距离越短，补完动画越快，手感才不会"松手后还在等"
    const remaining = Math.abs(target - this.drawerAnim);
    const duration = Math.max(DRAWER_MIN_MS, (target === 1 ? DRAWER_OPEN_MS : DRAWER_CLOSE_MS) * remaining);
    if (target === 1) {
      this.drawerOpen = true;
      this.getUIContext().animateTo({ duration: duration, curve: Curve.Friction }, () => {
        this.drawerAnim = 1;
      });
    } else {
      this.getUIContext().animateTo({
        duration: duration,
        curve: Curve.EaseIn,
        onFinish: () => {
          this.drawerOpen = false;
        }
      }, () => {
        this.drawerAnim = 0;
      });
    }
  }

  @Builder
  SideItem(label: string, hint: string, index: number) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.sidebarIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.sidebarIndex === index ? $r('app.color.accent') : $r('app.color.text_primary'))
        .width('100%')
      Text(hint)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .backgroundColor(this.sidebarIndex === index ? $r('app.color.selected_bg') : Color.Transparent)
    .onClick(() => {
      this.sidebarIndex = index;
      this.closeDrawer();
    })
  }

  @Builder
  SideBarView() {
    Column({ space: 2 }) {
      Column({ space: 2 }) {
        Text('摩斯通联')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('MorseTonglian')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 22, bottom: 16 })

      this.SideItem('声音识别', '麦克风 / 内录实时解码', PAGE_LISTEN)
      this.SideItem('编解码', '手敲摩斯或明文互转', PAGE_CODEC)
      this.SideItem('通联日志', 'QSO 记录 · 录音 · 导出', PAGE_LOG)
      this.SideItem('码表', '字母 / 数字 / 标点', PAGE_TABLE)
      this.SideItem('设置', '选频 · 降噪 · 外观', PAGE_SETTINGS)

      Blank()

      Text('点划靠时长自适应区分\n选频 + 纯度判据抗杂音')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_bg'))
  }

  @Builder
  TopBar() {
    Row({ space: 6 }) {
      Text('☰')
        .fontSize(20)
        .fontColor($r('app.color.text_primary'))
        .width(42)
        .height(42)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.toggleDrawer();
        })
      Text(this.pageTitle())
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.sidebarIndex === PAGE_CODEC) {
        Text(this.codecMode === MODE_DECODE ? '解码' : '编码')
          .fontSize(11)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.selected_bg'))
          .borderRadius(8)
      }
    }
    .width('100%')
    // 左边留出热区宽度，否则 ☰ 按钮左半边会被手势热区吃掉
    .padding({ left: 28, right: 14, top: 6, bottom: 2 })
  }

  // ---------------- 首页：声音识别 ----------------

  @Builder
  InfoChip(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor($r('app.color.input_bg'))
      .borderRadius(8)
      .margin({ right: 6, bottom: 6 })
  }

  @Builder
  ListenView() {
    Scroll() {
      Column({ space: 12 }) {
        // ---------- 声音来源 ----------
        Column({ space: 8 }) {
          Text('声音来源').fontSize(14).fontColor($r('app.color.text_secondary'))

          Row({ space: 8 }) {
            Button('麦克风识别')
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .borderRadius(10)
              .borderWidth(1)
              .borderColor($r('app.color.accent_border'))
              .backgroundColor(this.captureSource === MorseCaptureSource.MIC && this.captureRunning
                ? $r('app.color.accent') : $r('app.color.card_bg'))
              .fontColor(this.captureSource === MorseCaptureSource.MIC && this.captureRunning
                ? $r('app.color.on_accent') : $r('app.color.accent'))
              .enabled(!this.captureRunning && !this.captureStarting)
              .onClick(() => this.beginCapture(MorseCaptureSource.MIC))

            Button('手机内录')
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .borderRadius(10)
              .borderWidth(1)
              .borderColor($r('app.color.accent_border'))
              .backgroundColor(this.captureSource === MorseCaptureSource.PLAYBACK && this.captureRunning
                ? $r('app.color.accent') : $r('app.color.card_bg'))
              .fontColor(this.captureSource === MorseCaptureSource.PLAYBACK && this.captureRunning
                ? $r('app.color.on_accent') : $r('app.color.accent'))
              .enabled(!this.captureRunning && !this.captureStarting)
              .onClick(() => this.beginCapture(MorseCaptureSource.PLAYBACK))
          }
          .width('100%')

          Text('麦克风：对着另一台设备（对讲机 / 电台 / 音箱）外放的摩斯音。内录：直接抓手机正在播放的声音，不需要麦克风权限，但需要系统当场授权。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 实时状态 ----------
        Column({ space: 8 }) {
          Row() {
            Text(this.captureRunning
              ? (this.captureToneOn ? '● 正在接收信号' : '○ 正在聆听…')
              : (this.captureStarting ? '正在启动…' : '未开始'))
              .fontSize(14)
              .fontColor(this.captureToneOn ? $r('app.color.accent') : $r('app.color.text_secondary'))
            Blank()
            Text(this.captureRunning
              ? (this.captureLocked
                ? ('锁定 ' + this.captureToneHz.toFixed(0) + ' Hz' + (this.autoTone ? '（自动）' : '（手动）'))
                : '正在扫描频率…')
              : (this.captureMarkCount > 0 ? ('已识别 ' + this.captureMarkCount.toString() + ' 个点划段') : ''))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')

          Progress({ value: this.captureLevel * 100, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(8)
            .color($r('app.color.accent'))
            .backgroundColor($r('app.color.progress_bg'))

          if (this.captureRunning) {
            Flex({ wrap: FlexWrap.Wrap }) {
              this.InfoChip('速度 ' + this.captureWpm.toFixed(0) + ' WPM')
              this.InfoChip('点 ' + this.captureDotMs.toFixed(0) + ' ms')
              this.InfoChip('划 ' + this.captureDashMs.toFixed(0) + ' ms')
              this.InfoChip('纯度 ' + (this.capturePurity * 100).toFixed(0) + '%')
              this.InfoChip('采样 ' + (this.captureSampleRate / 1000).toFixed(1) + ' kHz')
              this.InfoChip('录音 ' + (this.captureAudioMs / 1000).toFixed(0) + ' s')
            }
            .width('100%')
          }

          if (this.captureError.length > 0) {
            Text(this.captureError)
              .fontSize(12)
              .fontColor($r('app.color.warn'))
              .width('100%')
          }
          if (this.captureDenied) {
            Text('可到「设置 → 应用 → 摩斯解码器 → 权限」里手动打开麦克风权限。')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 识别结果 ----------
        Column({ space: 8 }) {
          Row() {
            Text('识别结果').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.captureText.length > 0 ? this.captureText.length.toString() + ' 字符' : '')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')

          Text(this.captureText.length > 0 ? this.captureText : '等待声音…')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.captureText.length > 0 ? $r('app.color.accent') : $r('app.color.text_placeholder'))
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)

          if (this.captureMorse.length > 0) {
            Text(this.captureMorse)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 控制 ----------
        Row({ space: 8 }) {
          Button(this.captureRunning ? '停止聆听' : (this.captureStarting ? '正在启动…' : '开始聆听'))
            .layoutWeight(1)
            .height(46)
            .fontSize(16)
            .borderRadius(10)
            .backgroundColor(this.captureRunning ? $r('app.color.warn') : $r('app.color.accent'))
            .fontColor($r('app.color.on_accent'))
            .enabled(!this.captureStarting)
            .onClick(() => {
              if (this.captureRunning) {
                this.stopCapture();
              } else {
                this.beginCapture(this.captureSource);
              }
            })

          Button('清空重听')
            .layoutWeight(1)
            .height(46)
            .fontSize(16)
            .borderRadius(10)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.accent'))
            .borderWidth(1)
            .borderColor($r('app.color.accent_border'))
            .enabled(this.captureMorse.length > 0)
            .onClick(() => this.clearCapture())
        }
        .width('100%')

        Row({ space: 8 }) {
          Button('复制明文')
            .actionStyle()
            .fontColor($r('app.color.accent'))
            .fontSize(15)
            .enabled(this.captureText.length > 0)
            .onClick(() => this.copyToClipboard(this.captureText))
          Button('复制摩斯码')
            .actionStyle()
            .fontColor($r('app.color.accent'))
            .fontSize(15)
            .enabled(this.captureMorse.length > 0)
            .onClick(() => this.copyToClipboard(this.captureMorse))
          Button('去编辑')
            .actionStyle()
            .fontColor($r('app.color.accent'))
            .fontSize(15)
            .enabled(this.captureMorse.length > 0)
            .onClick(() => this.sendToCodec(this.captureMorse))
        }
        .width('100%')

        Button('保存到通联日志')
          .width('100%')
          .height(46)
          .fontSize(15)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.accent'))
          .borderWidth(1)
          .borderColor($r('app.color.accent_border'))
          .enabled(this.logAudioReady || this.captureMorse.length > 0)
          .onClick(() => this.startNewLog())

        Text('识别不理想时：在「设置」里把识别频率固定成对方电键的侧音频率（例如 700 Hz），再适当提高降噪强度；点长、划长是边听边自适应估算的，多听几个字符后会越来越准。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  // ---------------- 编解码（同一页，分段切换） ----------------

  @Builder
  CodecView() {
    Scroll() {
      Column({ space: 12 }) {
        // ---------- 模式切换 ----------
        Row({ space: 0 }) {
          Button('摩斯 → 明文')
            .layoutWeight(1)
            .height(38)
            .fontSize(14)
            .borderRadius(9)
            .backgroundColor(this.codecMode === MODE_DECODE ? $r('app.color.accent') : Color.Transparent)
            .fontColor(this.codecMode === MODE_DECODE ? $r('app.color.on_accent') : $r('app.color.accent'))
            .onClick(() => {
              this.codecMode = MODE_DECODE;
            })
          Button('明文 → 摩斯')
            .layoutWeight(1)
            .height(38)
            .fontSize(14)
            .borderRadius(9)
            .backgroundColor(this.codecMode === MODE_ENCODE ? $r('app.color.accent') : Color.Transparent)
            .fontColor(this.codecMode === MODE_ENCODE ? $r('app.color.on_accent') : $r('app.color.accent'))
            .onClick(() => {
              this.codecMode = MODE_ENCODE;
            })
        }
        .width('100%')
        .padding(4)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(12)
        .borderWidth(1)
        .borderColor($r('app.color.divider'))

        if (this.codecMode === MODE_DECODE) {
          this.DecodeSection()
        } else {
          this.EncodeSection()
        }
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  DecodeSection() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Row() {
          Text('摩斯码输入').fontSize(14).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('空格=字母间隔，/ 或连续空格=单词间隔').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')

        TextArea({ text: this.morseInput, placeholder: '例如：.... . .-.. .-.. --- / .-- --- .-. .-.. -..' })
          .placeholderColor($r('app.color.text_placeholder'))
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .caretColor($r('app.color.accent'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .height(110)
          .width('100%')
          .onChange((value: string) => {
            this.morseInput = value;
            this.refreshDecode();
          })
      }
      .alignItems(HorizontalAlign.Start)
      .cardStyle()

      Row({ space: 8 }) {
        Button('·').keyStyle().fontColor($r('app.color.text_primary')).onClick(() => this.appendSymbol('.'))
        Button('—').keyStyle().fontColor($r('app.color.text_primary')).onClick(() => this.appendSymbol('-'))
        Button('字母间隔').keyStyle().fontColor($r('app.color.text_primary')).fontSize(14).onClick(() => this.appendSymbol(' '))
        Button('单词间隔').keyStyle().fontColor($r('app.color.text_primary')).fontSize(14).onClick(() => this.appendSymbol(' / '))
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('退格').keyStyle().fontColor($r('app.color.text_primary')).onClick(() => this.backspace())
        Button('清空').keyStyle().fontColor($r('app.color.text_primary')).onClick(() => this.clearInput())
        Button('载入示例').keyStyle().fontColor($r('app.color.text_primary')).onClick(() => {
          this.morseInput = MorseCodec.sample();
          this.refreshDecode();
        })
      }
      .width('100%')

      Column({ space: 8 }) {
        Row() {
          Text('解码结果').fontSize(14).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(this.letterCount.toString() + ' 字符 · ' + this.wordCount.toString() + ' 词')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')

        Text(this.decoded.length > 0 ? this.decoded : '等待输入…')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.decoded.length > 0 ? $r('app.color.accent') : $r('app.color.text_placeholder'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)

        if (this.currentToken.length > 0) {
          Text('正在输入 ' + this.currentToken + (this.currentLetter.length > 0 ? ' → ' + this.currentLetter : ' （暂无对应字符）'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }

        if (this.unknownText.length > 0) {
          Text('无法识别：' + this.unknownText)
            .fontSize(13)
            .fontColor($r('app.color.warn'))
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .cardStyle()

      Row({ space: 8 }) {
        Button('复制结果')
          .actionStyle()
          .fontColor($r('app.color.accent'))
          .fontSize(15)
          .enabled(this.decoded.length > 0)
          .onClick(() => this.copyToClipboard(this.decoded))
        Button('复制归一化编码')
          .actionStyle()
          .fontColor($r('app.color.accent'))
          .fontSize(15)
          .enabled(this.morseInput.length > 0)
          .onClick(() => this.copyToClipboard(MorseCodec.normalize(this.morseInput)))
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  EncodeSection() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Text('明文输入').fontSize(14).fontColor($r('app.color.text_secondary'))
        TextArea({ text: this.plainInput, placeholder: '例如：HELLO WORLD' })
          .placeholderColor($r('app.color.text_placeholder'))
          .fontSize(18)
          .fontColor($r('app.color.text_primary'))
          .caretColor($r('app.color.accent'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(10)
          .height(110)
          .width('100%')
          .onChange((value: string) => {
            this.plainInput = value;
            this.encoded = MorseCodec.encode(value);
          })
      }
      .alignItems(HorizontalAlign.Start)
      .cardStyle()

      Column({ space: 8 }) {
        Row() {
          Text('摩斯编码').fontSize(14).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('码表中没有的字符用 ? 占位').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')

        Text(this.encoded.length > 0 ? this.encoded : '等待输入…')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.encoded.length > 0 ? $r('app.color.accent') : $r('app.color.text_placeholder'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .alignItems(HorizontalAlign.Start)
      .cardStyle()

      Row({ space: 8 }) {
        Button('复制编码')
          .actionStyle()
          .fontColor($r('app.color.accent'))
          .fontSize(15)
          .enabled(this.encoded.length > 0)
          .onClick(() => this.copyToClipboard(this.encoded))
        Button('用解码器验证')
          .actionStyle()
          .fontColor($r('app.color.accent'))
          .fontSize(15)
          .enabled(this.encoded.length > 0)
          .onClick(() => {
            this.morseInput = MorseCodec.normalize(this.encoded);
            this.refreshDecode();
            this.codecMode = MODE_DECODE;
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  // ---------------- 码表 ----------------

  @Builder
  TableView() {
    Scroll() {
      Column({ space: 10 }) {
        Text('标准码表（ITU-R M.1677-1）：字母 A-Z、数字 0-9、常用标点')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.table, (item: MorseEntry) => {
            Column({ space: 2 }) {
              Text(item.ch)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Text(item.code)
                .fontSize(13)
                .fontColor($r('app.color.accent'))
            }
            .width('25%')
            .padding({ top: 8, bottom: 8 })
          }, (item: MorseEntry) => item.ch)
        }
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(12)
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  // ---------------- 设置 ----------------

  // ---------------- 通联日志：界面 ----------------

  /** 表单/设置项的小标题行（右边可挂一句提示） */
  @Builder
  FieldLabel(text: string, hint: string) {
    Row() {
      Text(text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      if (hint.length > 0) {
        Text(hint)
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
  }

  @Builder
  LogListItem(record: QsoRecord) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(record.call.length > 0 ? record.call : '(未填呼号)')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        if (record.audioMs > 0) {
          Text('♪')
            .fontSize(13)
            .fontColor($r('app.color.accent'))
        }
        Blank()
        Text(utcText(recordTime(record)) + ' UTC')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      Text(this.logSummaryLine(record))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      if (record.morse.length > 0) {
        Text(record.morse)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Row({ space: 8 }) {
        Button('编辑')
          .layoutWeight(1)
          .height(34)
          .fontSize(13)
          .borderRadius(8)
          .backgroundColor($r('app.color.input_bg'))
          .fontColor($r('app.color.accent'))
          .onClick(() => this.editLogEntry(record))
        Button('删除')
          .layoutWeight(1)
          .height(34)
          .fontSize(13)
          .borderRadius(8)
          .backgroundColor($r('app.color.input_bg'))
          .fontColor($r('app.color.warn'))
          .onClick(() => this.deleteLogEntry(record.id))
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .cardStyle()
  }

  @Builder
  LogList() {
    Column({ space: 12 }) {
      Row() {
        Text('共 ' + this.logRecords.length.toString() + ' 条记录')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
      }
      .width('100%')

      Button('新建通联记录')
        .width('100%')
        .height(46)
        .fontSize(15)
        .borderRadius(10)
        .backgroundColor($r('app.color.accent'))
        .fontColor($r('app.color.on_accent'))
        .onClick(() => this.startNewLog())

      if (this.logRecords.length === 0) {
        Column({ space: 6 }) {
          Text('还没有记录')
            .fontSize(14)
            .fontColor($r('app.color.text_placeholder'))
            .width('100%')
          Text('在「声音识别」页听到通联内容后点「保存到通联日志」，会把识别到的摩斯码、译文和当时的录音一起带过来；也可以在这里直接新建，填上对方呼号、时间、信号报告、设备型号等信息。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()
      } else {
        ForEach(this.logRecords, (record: QsoRecord) => {
          this.LogListItem(record)
        }, (record: QsoRecord) => this.logKey(record))

        Row({ space: 8 }) {
          Button('导出 ADIF')
            .actionStyle()
            .fontColor($r('app.color.accent'))
            .fontSize(14)
            .onClick(() => this.exportAdif())
          Button('导出文本')
            .actionStyle()
            .fontColor($r('app.color.accent'))
            .fontSize(14)
            .onClick(() => this.exportText())
        }
        .width('100%')

        Text('导出会同时复制到剪贴板，并在应用沙箱 filesDir/qso_export 里写一份文件。ADIF 可直接导入 N1MM、Log4OM 等日志软件；录音是 8kHz 单声道 WAV，存在 filesDir/qso_audio。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }

      if (this.logMessage.length > 0) {
        Text(this.logMessage)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  LogEditor() {
    Column({ space: 10 }) {
      Row() {
        Text(this.logEditId.length > 0 ? '编辑记录' : '新建记录')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.pendingMs > 0
          ? ('将保存录音 ' + Math.round(this.pendingMs / 1000).toString() + ' 秒')
          : (this.logEditAudioMs > 0
            ? ('已有录音 ' + Math.round(this.logEditAudioMs / 1000).toString() + ' 秒')
            : '无录音'))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      this.FieldLabel('通联时间（UTC）', '格式 YYYY-MM-DD HH:mm')
      TextInput({ text: this.fTime, placeholder: '2026-10-10 20:56' })
        .formInput()
        .onChange((value: string) => {
          this.fTime = value;
        })

      this.FieldLabel('对方呼号', 'call')
      TextInput({ text: this.fCall, placeholder: '如 BG1ABC' })
        .formInput()
        .onChange((value: string) => {
          this.fCall = value;
        })

      this.FieldLabel('我方呼号', 'station_callsign')
      TextInput({ text: this.fMyCall, placeholder: '如 BG2XYZ' })
        .formInput()
        .onChange((value: string) => {
          this.fMyCall = value;
        })

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          this.FieldLabel('频率 kHz', '')
          TextInput({ text: this.fFreq, placeholder: '7023' })
            .formInput()
            .onChange((value: string) => {
              this.fFreq = value;
            })
        }
        .layoutWeight(1)

        Column({ space: 4 }) {
          this.FieldLabel('波段', '留空自动判断')
          TextInput({ text: this.fBand, placeholder: '40m' })
            .formInput()
            .onChange((value: string) => {
              this.fBand = value;
            })
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          this.FieldLabel('模式', '')
          TextInput({ text: this.fMode, placeholder: 'CW' })
            .formInput()
            .onChange((value: string) => {
              this.fMode = value;
            })
        }
        .layoutWeight(1)

        Column({ space: 4 }) {
          this.FieldLabel('功率', 'tx_pwr')
          TextInput({ text: this.fPower, placeholder: '100W' })
            .formInput()
            .onChange((value: string) => {
              this.fPower = value;
            })
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          this.FieldLabel('我方发报报告', 'rst_sent')
          TextInput({ text: this.fRstSent, placeholder: '599' })
            .formInput()
            .onChange((value: string) => {
              this.fRstSent = value;
            })
        }
        .layoutWeight(1)

        Column({ space: 4 }) {
          this.FieldLabel('我收对方报告', 'rst_rcvd')
          TextInput({ text: this.fRstRcvd, placeholder: '599' })
            .formInput()
            .onChange((value: string) => {
              this.fRstRcvd = value;
            })
        }
        .layoutWeight(1)
      }
      .width('100%')

      this.FieldLabel('对方 QTH', 'qth')
      TextInput({ text: this.fQth, placeholder: '如 Beijing' })
        .formInput()
        .onChange((value: string) => {
          this.fQth = value;
        })

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          this.FieldLabel('设备型号', 'my_rig')
          TextInput({ text: this.fRig, placeholder: '如 IC-7300' })
            .formInput()
            .onChange((value: string) => {
              this.fRig = value;
            })
        }
        .layoutWeight(1)

        Column({ space: 4 }) {
          this.FieldLabel('天线', 'my_ant')
          TextInput({ text: this.fAntenna, placeholder: '如 DP' })
            .formInput()
            .onChange((value: string) => {
              this.fAntenna = value;
            })
        }
        .layoutWeight(1)
      }
      .width('100%')

      this.FieldLabel('摩斯码', 'app_morse_code')
      TextArea({ text: this.fMorse, placeholder: '.... . .-.. .-.. ---' })
        .width('100%')
        .height(64)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(8)
        .onChange((value: string) => {
          this.fMorse = value;
        })

      this.FieldLabel('译文', 'app_morse_text')
      TextArea({ text: this.fText, placeholder: 'HELLO' })
        .width('100%')
        .height(64)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(8)
        .onChange((value: string) => {
          this.fText = value;
        })

      this.FieldLabel('备注', 'comment')
      TextArea({ text: this.fNotes, placeholder: '信号情况、天气、卡片收发…' })
        .width('100%')
        .height(64)
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(8)
        .onChange((value: string) => {
          this.fNotes = value;
        })

      Row({ space: 8 }) {
        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .borderRadius(10)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.on_accent'))
          .onClick(() => this.saveLogEntry())
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.accent'))
          .borderWidth(1)
          .borderColor($r('app.color.accent_border'))
          .onClick(() => this.cancelLogEdit())
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  LogView() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.logEditing) {
          this.LogEditor()
        } else {
          this.LogList()
        }
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  SettingRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(14).fontColor($r('app.color.text_primary'))
      Blank()
      Text(value).fontSize(13).fontColor($r('app.color.accent'))
    }
    .width('100%')
  }

  @Builder
  SettingsView() {
    Scroll() {
      Column({ space: 12 }) {
        // ---------- 识别频率 ----------
        Column({ space: 8 }) {
          Row() {
            Text('识别频率').fontSize(14).fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.autoTone ? '自动选频' : (this.toneHzSetting.toFixed(0) + ' Hz'))
              .fontSize(13)
              .fontColor($r('app.color.accent'))
          }
          .width('100%')

          Row() {
            Text('自动选频（扫描 300~1500 Hz，听到音调后锁定）')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.autoTone })
              .selectedColor($r('app.color.accent'))
              .onChange((isOn: boolean) => {
                this.setAutoTone(isOn);
              })
          }
          .width('100%')

          if (!this.autoTone) {
            Slider({
              value: this.toneHzSetting,
              min: TONE_HZ_MIN,
              max: TONE_HZ_MAX,
              step: TONE_HZ_STEP,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .trackColor($r('app.color.progress_bg'))
              .selectedColor($r('app.color.accent'))
              .blockColor($r('app.color.accent'))
              .onChange((value: number) => {
                this.setToneHz(value);
              })

            Row({ space: 8 }) {
              ForEach(TONE_PRESETS, (hz: number) => {
                Button(hz.toString() + ' Hz')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(12)
                  .borderRadius(9)
                  .backgroundColor(this.toneHzSetting === hz ? $r('app.color.accent') : $r('app.color.input_bg'))
                  .fontColor(this.toneHzSetting === hz ? $r('app.color.on_accent') : $r('app.color.text_primary'))
                  .onClick(() => this.setToneHz(hz))
              }, (hz: number) => hz.toString())
            }
            .width('100%')
          }

          Text('固定成对方电键的侧音频率（常见 600~1000 Hz）能显著提高识别率：频带外的人声、音乐、噪声都会被挡掉。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 降噪强度 ----------
        Column({ space: 6 }) {
          this.SettingRow('降噪强度', this.denoise.toFixed(0) + ' / 100')
          Slider({ value: this.denoise, min: DENOISE_MIN, max: DENOISE_MAX, step: 5, style: SliderStyle.OutSet })
            .width('100%')
            .trackColor($r('app.color.progress_bg'))
            .selectedColor($r('app.color.accent'))
            .blockColor($r('app.color.accent'))
            .onChange((value: number) => {
              this.denoise = value;
            })
          Text('纯度门限 ' + denoiseToPurity(this.denoise).toFixed(2) +
            ' · 最短音长 ' + denoiseToMinMarkMs(this.denoise).toFixed(0) + ' ms')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text('越大越只认"干净的单音"：杂音、咔哒声、说话声更难触发；但信号微弱或失真时可能漏掉点划。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 灵敏度 ----------
        Column({ space: 6 }) {
          this.SettingRow('灵敏度', this.sensitivity.toFixed(0) + ' / 100')
          Slider({ value: this.sensitivity, min: SENSITIVITY_MIN, max: SENSITIVITY_MAX, step: 5, style: SliderStyle.OutSet })
            .width('100%')
            .trackColor($r('app.color.progress_bg'))
            .selectedColor($r('app.color.accent'))
            .blockColor($r('app.color.accent'))
            .onChange((value: number) => {
              this.sensitivity = value;
            })
          Text('越大越不容易被环境噪声误触发；太小会把杂音当信号，太大可能听不到弱信号。默认 50。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 检测带宽 ----------
        Column({ space: 6 }) {
          this.SettingRow('检测带宽', this.tolerance.toFixed(0) + ' Hz')
          Slider({ value: this.tolerance, min: TOLERANCE_MIN, max: TOLERANCE_MAX, step: 5, style: SliderStyle.OutSet })
            .width('100%')
            .trackColor($r('app.color.progress_bg'))
            .selectedColor($r('app.color.accent'))
            .blockColor($r('app.color.accent'))
            .onChange((value: number) => {
              this.tolerance = value;
            })
          Text('越小频带越窄、抗噪越强，但对方频率漂移时容易漏掉；改动需要重新开始聆听才生效。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 外观 ----------
        Column({ space: 8 }) {
          this.SettingRow('外观', this.colorModeLabel())
          Row({ space: 8 }) {
            Button('跟随系统')
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .borderRadius(9)
              .backgroundColor(this.colorMode === COLOR_SYSTEM ? $r('app.color.accent') : $r('app.color.input_bg'))
              .fontColor(this.colorMode === COLOR_SYSTEM ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .onClick(() => {
                this.colorMode = COLOR_SYSTEM;
              })
            Button('浅色')
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .borderRadius(9)
              .backgroundColor(this.colorMode === COLOR_LIGHT ? $r('app.color.accent') : $r('app.color.input_bg'))
              .fontColor(this.colorMode === COLOR_LIGHT ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .onClick(() => {
                this.colorMode = COLOR_LIGHT;
              })
            Button('深色')
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .borderRadius(9)
              .backgroundColor(this.colorMode === COLOR_DARK ? $r('app.color.accent') : $r('app.color.input_bg'))
              .fontColor(this.colorMode === COLOR_DARK ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .onClick(() => {
                this.colorMode = COLOR_DARK;
              })
          }
          .width('100%')
          Text('选「跟随系统」时，系统切到深色，应用会一起切。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        // ---------- 电台信息（通联日志预填） ----------
        Column({ space: 6 }) {
          this.SettingRow('电台信息', '新建日志时预填')
          this.FieldLabel('我方呼号', 'station_callsign')
          TextInput({ text: this.myCallSetting, placeholder: '如 BG1ABC' })
            .formInput()
            .onChange((value: string) => {
              this.myCallSetting = value;
            })
          this.FieldLabel('常用设备型号', 'my_rig')
          TextInput({ text: this.myRigSetting, placeholder: '如 IC-7300' })
            .formInput()
            .onChange((value: string) => {
              this.myRigSetting = value;
            })
          Text('新建通联记录时会自动填上这两项；日志里每条记录仍可单独修改。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .cardStyle()

        Button('恢复默认设置')
          .width('100%')
          .height(46)
          .fontSize(15)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.accent'))
          .borderWidth(1)
          .borderColor($r('app.color.accent_border'))
          .onClick(() => this.resetSettings())

        Text('识别原理：抽取到 8kHz 后在滑动窗上做 Goertzel 测目标频点幅度，用「纯度」（目标频点功率 / 全带功率）挡掉杂音；起振/停振用半高门限，保证点划时长不被削偏；点长、划长、字母间隔、单词间隔用聚类 + 整数比拟合自适应估计，所以 8~48 WPM 都能跟上。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  build() {
    // 自绘抽屉：不用 SideBarContainer —— 它没有动画属性，也不给"点内容区收回"的遮罩。
    // 面板与遮罩常驻渲染（不参与布局拦截），只由 drawerAnim 驱动位移和透明度，
    // 这样 animateTo 一定能对它们做插值，收起后 hitTestBehavior 为 None 也不会误吃点击。
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 内容区 ----------
      Column() {
        this.TopBar()

        if (this.sidebarIndex === PAGE_LISTEN) {
          this.ListenView()
        } else if (this.sidebarIndex === PAGE_CODEC) {
          this.CodecView()
        } else if (this.sidebarIndex === PAGE_TABLE) {
          this.TableView()
        } else if (this.sidebarIndex === PAGE_SETTINGS) {
          this.SettingsView()
        } else {
          this.LogView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      // ---------- 遮罩：点它收回抽屉；在它上面向左滑也能收回 ----------
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .opacity(this.drawerAnim)
        .hitTestBehavior(this.drawerOpen ? HitTestMode.Default : HitTestMode.None)
        .onClick(() => {
          this.closeDrawer();
        })
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.onDrawerDragStart();
            })
            .onActionUpdate((event: GestureEvent) => {
              this.onDrawerDragUpdate(1, event.offsetX);
            })
            .onActionEnd((event: GestureEvent) => {
              this.onDrawerDragEnd(event.velocityX);
            })
            .onActionCancel(() => {
              this.onDrawerDragEnd(0);
            })
        )

      // ---------- 抽屉面板：从左侧滑入 ----------
      Column() {
        this.SideBarView()
      }
      .width(DRAWER_WIDTH)
      .height('100%')
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: { right: 1 }, color: $r('app.color.divider') })
      .translate({ x: -DRAWER_WIDTH * (1 - this.drawerAnim) })
      .hitTestBehavior(this.drawerOpen && !this.drawerDragging ? HitTestMode.Default : HitTestMode.None)

      // ---------- 左边缘热区：从这里起手右滑即可拉出抽屉 ----------
      // 必须放在最上层才能优先接到触摸；拖动期间保持可命中，否则手势链会中断。
      Column()
        .width(DRAWER_EDGE_WIDTH)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(this.drawerOpen && !this.drawerDragging ? HitTestMode.None : HitTestMode.Default)
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.onDrawerDragStart();
            })
            .onActionUpdate((event: GestureEvent) => {
              this.onDrawerDragUpdate(0, event.offsetX);
            })
            .onActionEnd((event: GestureEvent) => {
              this.onDrawerDragEnd(event.velocityX);
            })
            .onActionCancel(() => {
              this.onDrawerDragEnd(0);
            })
        )
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
