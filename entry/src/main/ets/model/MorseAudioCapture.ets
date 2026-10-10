import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MorseCodec } from './MorseCodec';
import { MorseAudio, MorseToneDetector, MorseToneOptions } from './MorseAudio';

/**
 * 声音来源
 *  - MIC：手机麦克风，对着另一台设备的喇叭/对讲机拾音；
 *  - PLAYBACK：手机内录，直接抓系统正在播放的声音（在别的 App 里放摩斯音频即可）。
 */
export enum MorseCaptureSource {
  MIC = 0,
  PLAYBACK = 1
}

/** 给界面轮询用的采集状态 */
export interface MorseCaptureStatus {
  running: boolean;
  starting: boolean;
  source: MorseCaptureSource;
  /** 实际生效的采样率 */
  sampleRate: number;
  /** 实际生效的声道数 */
  channels: number;
  /** 出错信息，空串表示正常 */
  error: string;
  /** 麦克风权限被拒绝 */
  denied: boolean;
  /** 内录是否已被系统授权 */
  authorized: boolean;
  toneOn: boolean;
  level: number;
  toneHz: number;
  wpm: number;
  dotMs: number;
  /** 估计的划长（ms），界面上用来跟点长对照 */
  dashMs: number;
  /** 音调纯度 0~1：越高说明听到的越像"干净的单音"，越低说明更像杂音 */
  purity: number;
  /** 是否已经锁定音调频率 */
  locked: boolean;
  morse: string;
  text: string;
  markCount: number;
}

/** 一种采集参数组合，创建失败就换下一种 */
interface CaptureProfile {
  samplingRate: audio.AudioSamplingRate;
  channels: audio.AudioChannel;
  /** 采样率与声道的数值形式，用于构造检测器/降混音 */
  rate: number;
  channelCount: number;
}

/** 内录还要挑一种抓取范围 */
interface PlaybackProfile extends CaptureProfile {
  mode: audio.AudioPlaybackCaptureMode;
}

const S16: audio.AudioSampleFormat = audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE;
const RAW: audio.AudioEncodingType = audio.AudioEncodingType.ENCODING_TYPE_RAW;

// 不同设备支持的采样率/声道组合不一样，按优先级逐个试
const MIC_PROFILES: CaptureProfile[] = [
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
    channels: audio.AudioChannel.CHANNEL_1,
    rate: 48000,
    channelCount: 1
  },
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
    channels: audio.AudioChannel.CHANNEL_1,
    rate: 16000,
    channelCount: 1
  },
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
    channels: audio.AudioChannel.CHANNEL_2,
    rate: 48000,
    channelCount: 2
  },
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
    channels: audio.AudioChannel.CHANNEL_2,
    rate: 44100,
    channelCount: 2
  }
];

const PLAYBACK_PROFILES: PlaybackProfile[] = [
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
    channels: audio.AudioChannel.CHANNEL_2,
    rate: 48000,
    channelCount: 2,
    mode: audio.AudioPlaybackCaptureMode.MODE_EXCLUDING_SELF
  },
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
    channels: audio.AudioChannel.CHANNEL_1,
    rate: 48000,
    channelCount: 1,
    mode: audio.AudioPlaybackCaptureMode.MODE_EXCLUDING_SELF
  },
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
    channels: audio.AudioChannel.CHANNEL_2,
    rate: 48000,
    channelCount: 2,
    mode: audio.AudioPlaybackCaptureMode.MODE_MEDIA
  },
  {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
    channels: audio.AudioChannel.CHANNEL_2,
    rate: 44100,
    channelCount: 2,
    mode: audio.AudioPlaybackCaptureMode.MODE_MEDIA
  }
];

/**
 * 音频采集：把麦克风或系统内录的 PCM 实时喂给 MorseToneDetector。
 *
 * 线程模型：readData 回调只做"转单声道 + 送检测器"这两件轻活，
 * 界面用定时器轮询 status()，绝不跨线程改 @State。
 */
export class MorseAudioCapture {
  private context: common.UIAbilityContext;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private detector: MorseToneDetector | undefined = undefined;
  private running: boolean = false;
  private starting: boolean = false;
  private source: MorseCaptureSource = MorseCaptureSource.MIC;
  private sampleRate: number = 0;
  private channels: number = 1;
  private error: string = '';
  private denied: boolean = false;
  private authorized: boolean = false;
  private ring: boolean = true;
  /** 识别参数（来自设置页）：开始聆听时交给检测器，聆听中也支持实时改 */
  private toneOptions: MorseToneOptions = {};

  constructor(context: common.UIAbilityContext, options?: MorseToneOptions) {
    this.context = context;
    if (options !== undefined) {
      this.toneOptions = options;
    }
  }

  /**
   * 更新识别参数：正在聆听时立刻生效（频率/降噪/灵敏度/最短音长），
   * 带宽、采样率、帧长这类依赖分析窗的项要重新开始聆听才生效。
   */
  setToneOptions(options: MorseToneOptions): void {
    this.toneOptions = options;
    const det = this.detector;
    if (det !== undefined) {
      det.applyToneOptions(options);
    }
  }

  /** 申请麦克风权限（用户态权限，会弹系统对话框） */
  async requestMicPermission(): Promise<boolean> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    try {
      const result = await atManager.requestPermissionsFromUser(this.context, perms);
      if (result.authResults.length > 0) {
        return result.authResults[0] === 0;
      }
      return false;
    } catch (err) {
      const e = err as BusinessError;
      this.error = '申请麦克风权限失败：' + e.code + ' ' + e.message;
      return false;
    }
  }

  private buildOptions(profile: CaptureProfile, playbackMode: audio.AudioPlaybackCaptureMode): audio.AudioCapturerOptions {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: profile.samplingRate,
      channels: profile.channels,
      sampleFormat: S16,
      encodingType: RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: this.source === MorseCaptureSource.MIC
        ? audio.SourceType.SOURCE_TYPE_MIC
        : audio.SourceType.SOURCE_TYPE_PLAYBACK_CAPTURE,
      capturerFlags: 0
    };
    if (this.source === MorseCaptureSource.MIC) {
      const opts: audio.AudioCapturerOptions = { streamInfo: streamInfo, capturerInfo: capturerInfo };
      return opts;
    }
    const opts: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo,
      playbackCaptureMode: playbackMode
    };
    return opts;
  }

  private describe(err: ESObject): string {
    const e = err as BusinessError;
    return e.code + ' ' + e.message;
  }

  /** 开始采集，成功返回 true */
  async start(source: MorseCaptureSource): Promise<boolean> {
    if (this.running || this.starting) {
      return false;
    }
    this.starting = true;
    this.source = source;
    this.error = '';
    this.denied = false;
    this.authorized = source === MorseCaptureSource.MIC;

    if (source === MorseCaptureSource.MIC) {
      const granted = await this.requestMicPermission();
      if (!granted) {
        this.denied = true;
        if (this.error.length === 0) {
          this.error = '没有麦克风权限，请在系统设置里打开后重试';
        }
        this.starting = false;
        return false;
      }
    }

    let created: audio.AudioCapturer | undefined = undefined;
    let rate = 0;
    let chans = 1;
    let lastErr = '';
    if (source === MorseCaptureSource.MIC) {
      for (let i = 0; i < MIC_PROFILES.length; i++) {
        const p = MIC_PROFILES[i];
        try {
          created = await audio.createAudioCapturer(this.buildOptions(p, audio.AudioPlaybackCaptureMode.MODE_DEFAULT));
          rate = p.rate;
          chans = p.channelCount;
          break;
        } catch (err) {
          created = undefined;
          lastErr = this.describe(err);
        }
      }
    } else {
      for (let i = 0; i < PLAYBACK_PROFILES.length; i++) {
        const p = PLAYBACK_PROFILES[i];
        try {
          created = await audio.createAudioCapturer(this.buildOptions(p, p.mode));
          rate = p.rate;
          chans = p.channelCount;
          break;
        } catch (err) {
          created = undefined;
          lastErr = this.describe(err);
        }
      }
    }

    if (created === undefined) {
      const what = source === MorseCaptureSource.MIC ? '麦克风' : '内录';
      this.error = what + '采集创建失败：' + lastErr;
      this.starting = false;
      return false;
    }

    this.capturer = created;
    this.sampleRate = rate;
    this.channels = chans;
    this.detector = new MorseToneDetector(rate, this.toneOptions);
    const channels = chans;
    // 只做轻活：16bit 交错 PCM -> 单声道浮点 -> 检测器
    try {
      this.capturer.on('readData', (buffer: ArrayBuffer) => {
        const det = this.detector;
        if (det === undefined) {
          return;
        }
        det.push(MorseAudio.pcm16ToMonoFloat(buffer, channels));
      });
    } catch (err) {
      this.error = '注册音频回调失败：' + this.describe(err);
      await this.stop();
      return false;
    }

    try {
      await this.capturer.start();
    } catch (err) {
      this.error = '启动采集失败：' + this.describe(err);
      await this.stop();
      return false;
    }

    this.running = true;
    this.starting = false;

    if (source === MorseCaptureSource.PLAYBACK) {
      try {
        this.capturer.requestPlaybackCaptureStart((state: audio.PlaybackCaptureStartState) => {
          if (state === audio.PlaybackCaptureStartState.STATE_SUCCESS) {
            this.authorized = true;
          } else if (state === audio.PlaybackCaptureStartState.STATE_NOT_AUTHORIZED) {
            this.authorized = false;
            this.error = '系统未授权内录（部分机型/应用商店版本不支持），可改用麦克风识别';
          } else {
            this.authorized = false;
            this.error = '内录启动失败：系统拒绝或内部错误';
          }
        });
      } catch (err) {
        this.authorized = false;
        this.error = '内录请求失败：' + this.describe(err);
      }
    }
    return true;
  }

  async stop(): Promise<void> {
    const c = this.capturer;
    this.capturer = undefined;
    this.running = false;
    this.starting = false;
    this.detector = undefined;
    if (c !== undefined) {
      try {
        c.off('readData');
      } catch (err) {
        console.error('off readData failed: ' + JSON.stringify(err));
      }
      try {
        await c.stop();
      } catch (err) {
        console.error('capturer stop failed: ' + JSON.stringify(err));
      }
      try {
        await c.release();
      } catch (err) {
        console.error('capturer release failed: ' + JSON.stringify(err));
      }
    }
  }

  /** 清空已识别的摩斯码，继续听 */
  clear(): void {
    const det = this.detector;
    if (det !== undefined) {
      det.reset();
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  status(): MorseCaptureStatus {
    const det = this.detector;
    let toneOn = false;
    let level = 0;
    let toneHz = 0;
    let wpm = 0;
    let dotMs = 0;
    let dashMs = 0;
    let purity = 0;
    let locked = false;
    let morse = '';
    let text = '';
    let marks = 0;
    if (det !== undefined) {
      const st = det.status();
      toneOn = st.toneOn;
      level = st.level;
      toneHz = st.toneHz;
      wpm = st.wpm;
      dotMs = st.dotMs;
      dashMs = st.dashMs;
      purity = st.purity;
      locked = st.locked;
      morse = st.morse;
      marks = st.markCount;
      if (morse.length > 0) {
        text = MorseCodec.decode(morse).text;
      }
    }
    const out: MorseCaptureStatus = {
      running: this.running,
      starting: this.starting,
      source: this.source,
      sampleRate: this.sampleRate,
      channels: this.channels,
      error: this.error,
      denied: this.denied,
      authorized: this.authorized,
      toneOn: toneOn,
      level: level,
      toneHz: toneHz,
      wpm: wpm,
      dotMs: dotMs,
      dashMs: dashMs,
      purity: purity,
      locked: locked,
      morse: morse,
      text: text,
      markCount: marks
    };
    return out;
  }
}
