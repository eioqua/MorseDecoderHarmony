import { MorseCodec } from './MorseCodec';

/**
 * 摩斯音频识别引擎（纯逻辑，不依赖任何 HarmonyOS 音频接口）
 *
 * 设计目标：
 *  - 输入：单声道浮点采样（-1 ~ 1）+ 采样率，可整段喂给 recognize()，也可用
 *    MorseToneDetector.push() 边录边识别；
 *  - 输出：归一化摩斯码字符串，直接交给 MorseCodec.decode() 得到文字，
 *    音频识别与文本解码共用同一套码表；
 *  - 抗噪：只在目标频点上做窄带检测，并用"音调纯度"（目标频点功率 / 全带功率）
 *    与"守频点对比"两道判据挡掉宽带杂音（噪声、说话声、音乐）；
 *  - 自适应：自动找音调频率、自动估速（WPM）与点长；也可以由用户硬锁定频率。
 *
 * 信号处理流程（每 hop = frameMs 毫秒执行一次分析）：
 *  两级一阶低通 -> 整数抽取到 ~8kHz 分析率 -> 滑动分析窗（长窗 = 1/带宽）
 *  -> 短窗(8ms)矩形 Goertzel 得包络，用来决定起振/停振时刻（时间分辨率 = hop）
 *  -> 长窗 Hann Goertzel 得目标频点幅度、守频点幅度、全带功率
 *  -> 音调纯度 = 2*(目标幅度/窗相干增益)^2 / 全带功率（纯正弦≈1，宽带噪声≈2/窗长）
 *  -> 噪声底/峰值双滑动跟踪 + 双门限滞回 + 纯度门限 -> "响/静"段时长序列
 *  -> 1 维 k-means 聚类估出单位时间 u，再用"每个时长 ÷ 最近整数比"最小二乘细化 u
 *  -> 按 2u / 5u 切分点与划、字母与单词；短于 minMarkMs 的毛刺丢弃，
 *     短于 minGapMs 的间隔把前后两个音合并（发射机掉音、采集丢帧容错）
 *
 * 算法参考（成熟 CW 解码器的通行做法）：
 *  - 自适应点划判别与多通道解码：cw-dit（Rust）https://github.com/swilcox/cw-dit
 *  - 单位时间拟合 / 间隔聚类：ditdah https://lib.rs/crates/ditdah
 *  - 窄带 Goertzel 选频与噪声抑制：AetherSDR CW Decoder
 *    https://github.com/aethersdr/AetherSDR/wiki/CW-Decoder
 *
 * 已知限制：
 *  - 只发了一个孤立的、且与字母间隔等长的元素时（例如连续发 T），点/划缺少时间锚点；
 *    这里用"标记时长 ≈ 间隔时长 则标记应为划"来推断（见 durationModel 的单簇分支）；
 *  - 内录音乐/人声时，若其谐波正好落在目标频点附近且持续超过最短音长，仍可能误触发，
 *    此时应把目标频率调离人声基频，或提高降噪强度（purityMin）。
 */

/** 识别参数，全部可选，不传就用默认值 */
export interface MorseToneOptions {
  /** 音调扫描下限（Hz），默认 300 */
  minToneHz?: number;
  /** 音调扫描上限（Hz），默认 1500 */
  maxToneHz?: number;
  /** 分析跳步（ms），默认 5。决定时间分辨率 */
  frameMs?: number;
  /** 固定音调（Hz）：>0 表示硬锁定这个频点，0/不传表示自动扫描并锁定 */
  toneHz?: number;
  /** 判定灵敏度，默认 0.45；门限 = 噪声底 × (3.6 × sensitivity / 0.45)，越大越不易误触发 */
  sensitivity?: number;
  /** 目标分析采样率，默认 8000 */
  analysisRate?: number;
  /** 频率容差/检测带宽（Hz），默认 20（即 50ms 分析窗）；越小越能躲开杂音，但分析窗越长、时间分辨率越差 */
  toleranceHz?: number;
  /** 音调纯度门限 0~1，默认 0.45；越大越能挡杂音，但弱信号/失真信号更容易漏掉 */
  purityMin?: number;
  /** 最短音长（ms），默认 12；比这更短的"响"当作毛刺丢弃 */
  minMarkMs?: number;
  /** 最短间隔（ms），默认 8；比这更短的"静"把前后两个音合并成一个 */
  minGapMs?: number;
}

/** 合成参数，全部可选 */
export interface MorseSynthOptions {
  /** 点长（ms），默认 60（即 20 WPM） */
  dotMs?: number;
  /** 音调频率（Hz），默认 700 */
  toneHz?: number;
  /** 采样率，默认 16000 */
  sampleRate?: number;
  /** 振幅 0~1，默认 0.6 */
  amplitude?: number;
  /** 叠加的白噪声幅度 0~1，默认 0 */
  noise?: number;
  /** 开头静音（ms），默认 100 */
  leadingMs?: number;
  /** 结尾静音（ms），默认 100 */
  trailingMs?: number;
}

/** 一段"响"或"静" */
export interface MorseToneSegment {
  isTone: boolean;
  durationMs: number;
}

/** 实时状态，给界面轮询显示 */
export interface MorseAudioStatus {
  /** 当前是否检测到音调 */
  toneOn: boolean;
  /** 归一化电平 0~1 */
  level: number;
  /** 估计/锁定的音调频率（Hz），未检测到为 0 */
  toneHz: number;
  /** 估计速度（WPM） */
  wpm: number;
  /** 估计的点长（ms） */
  dotMs: number;
  /** 估计的划长（ms） */
  dashMs: number;
  /** 当前识别出的摩斯码 */
  morse: string;
  /** 已完成的发声段数 */
  markCount: number;
  /** 最近一帧的音调纯度 0~1（越高越像纯音） */
  purity: number;
  /** 最近一帧信噪比（包络 / 噪声底） */
  snr: number;
  /** 频率是否已锁定 */
  locked: boolean;
  /** 是否为用户在设置里指定的固定频率 */
  manual: boolean;
}

/** 整段识别结果 */
export interface MorseAudioResult {
  morse: string;
  text: string;
  wpm: number;
  dotMs: number;
  dashMs: number;
  toneHz: number;
  peak: number;
  noise: number;
  markCount: number;
  purity: number;
  locked: boolean;
}

/** 点划/间隔判定模型 */
interface DurationModel {
  /** 单位时间（点长）ms */
  dot: number;
  /** 划长 ms */
  dash: number;
  /** 点/划分界 ms */
  dashTh: number;
  /** 字母间隔分界 ms */
  letterTh: number;
  /** 单词间隔分界 ms */
  wordTh: number;
}

const DOT_MIN_MS = 8;
const DOT_MAX_MS = 600;
/** 字母间隔 = 2 个单位时间 */
const LETTER_GAP_RATIO = 2;
/** 单词间隔 = 5 个单位时间 */
const WORD_GAP_RATIO = 5;
/** 长时间没有音调后重新扫描频率（仅自动模式） */
const RESCAN_AFTER_MS = 2500;
/** 起振/停振都要连续这么多帧才确认，压掉瞬时毛刺 */
const ON_CONFIRM_FRAMES = 2;
const OFF_CONFIRM_FRAMES = 2;
/**
 * 知道音调电平后，门限取电平的一半（半高门限）：包络前沿/后沿都被斜边削掉同样多，
 * 时长不失真。这条常量只是"没有音调参考时"的噪声底倍数下限，保证安静环境也能停振。
 */
const OFF_NOISE_FLOOR = 1.4;
/** 音调电平跟踪时间常数（ms）：跟着当前音调的包络平台走，前后沿的中点判定靠它 */
const TONE_LEVEL_MS = 15;
/** 包络平滑时间常数（ms）：压掉瞬时衰落；前后沿同时延迟，所以音与间隔的时长都不失真 */
const ENV_SMOOTH_MS = 5;
/** 掉音合并阈值上限 = 粗估点长 × 这个比例（发射机掉音、采集丢帧都远短于 1 个单位时间） */
const DROPOUT_RATIO = 0.5;
/** 开录后先安静这么久，用来摸清环境噪声底 */
const WARMUP_MS = 300;
/** 判定门限 = 噪声底 × 这个倍数（默认灵敏度下） */
const SNR_GATE_BASE = 3.6;
/** 包络用的短窗长度（ms）：决定起振/停振的时间精度 */
const ENV_MS = 8;
/** 守频点相对目标频点的偏移倍数（× 容差），用来判断"目标频点是不是局部峰" */
const GUARD_OFFSET = 2;
/** 目标频点至少要达到守频点的这个比例，才认为它是真正的音调峰 */
const GUARD_RATIO = 0.7;
/** 频率扫描步进（Hz） */
const SCAN_STEP_HZ = 25;

function mean(values: number[]): number {
  if (values.length === 0) {
    return 0;
  }
  let sum = 0;
  for (let i = 0; i < values.length; i++) {
    sum += values[i];
  }
  return sum / values.length;
}

/** 中心点离得太近就合并，避免把同一类时长的抖动当成两类 */
function mergeCloseCenters(centers: number[]): number[] {
  const sorted: number[] = centers.slice().sort((a: number, b: number) => a - b);
  const out: number[] = [];
  for (let i = 0; i < sorted.length; i++) {
    if (out.length === 0) {
      out.push(sorted[i]);
    } else {
      const prev = out[out.length - 1];
      if (sorted[i] <= prev * 1.35) {
        out[out.length - 1] = (prev + sorted[i]) / 2;
      } else {
        out.push(sorted[i]);
      }
    }
  }
  return out;
}

/** 1 维 k-means：时长序列被分成 k 类，返回升序的中心点（1 单位/3 单位/7 单位） */
function clusterCenters(values: number[], k: number): number[] {
  const v: number[] = values.slice().sort((a: number, b: number) => a - b);
  if (v.length === 0) {
    return [];
  }
  if (v.length <= k) {
    return mergeCloseCenters(v);
  }
  const centers: number[] = [];
  for (let i = 0; i < k; i++) {
    let idx = Math.floor((i + 0.5) * v.length / k);
    if (idx >= v.length) {
      idx = v.length - 1;
    }
    centers.push(v[idx]);
  }
  for (let iter = 0; iter < 12; iter++) {
    const sum: number[] = [];
    const cnt: number[] = [];
    for (let i = 0; i < k; i++) {
      sum.push(0);
      cnt.push(0);
    }
    for (let i = 0; i < v.length; i++) {
      let best = 0;
      let bestD = Math.abs(v[i] - centers[0]);
      for (let c = 1; c < k; c++) {
        const d = Math.abs(v[i] - centers[c]);
        if (d < bestD) {
          bestD = d;
          best = c;
        }
      }
      sum[best] += v[i];
      cnt[best]++;
    }
    for (let c = 0; c < k; c++) {
      if (cnt[c] > 0) {
        centers[c] = sum[c] / cnt[c];
      }
    }
    centers.sort((a: number, b: number) => a - b);
  }
  return mergeCloseCenters(centers);
}

/**
 * 用"每个时长 ÷ 最近的整数比"反过来最小二乘估计单位时间。
 * 点=1u、划=3u、字母间隔=3u、单词间隔=7u，各自除以自己的倍数后都应该是 u，
 * 取平均就能把发送方速度的偏差、测量抖动一起抹平。
 */
function refineUnit(initial: number, marks: number[], gaps: number[]): number {
  if (initial <= 0) {
    return 0;
  }
  const candidates: number[] = [];
  // 发声段：1 单位（点）或 3 单位（划）。
  // 窗口下界定在 2.2u，避免把"被门限拉长的点"（1.5~2u）当成划而把 u 拉低三分之一
  for (let i = 0; i < marks.length; i++) {
    const d = marks[i];
    if (Math.abs(d - initial) <= initial * 0.4) {
      candidates.push(d);
    } else if (d >= initial * 2.2 && d <= initial * 3.9) {
      candidates.push(d / 3);
    }
  }
  // 静音段：1 单位（字母内）、3 单位（字母间）、7 单位（单词间）
  for (let i = 0; i < gaps.length; i++) {
    const d = gaps[i];
    if (Math.abs(d - initial) <= initial * 0.4) {
      candidates.push(d);
    } else if (d >= initial * 2.2 && d <= initial * 3.9) {
      candidates.push(d / 3);
    } else if (d >= initial * 5 && d <= initial * 8.5) {
      candidates.push(d / 7);
    }
  }
  if (candidates.length < 3) {
    return initial;
  }
  const refined = mean(candidates);
  // 一次别改太多，避免刚进来的段噪声把速度带飞
  if (refined <= initial * 0.5 || refined >= initial * 2) {
    return initial;
  }
  return initial * 0.35 + refined * 0.65;
}

/** 速度先验区间（ms）：正常手键/自动键约 8~48 WPM，即点长 25~150ms，中位 20 WPM = 60ms */
const DOT_PRIOR_MIN_MS = 25;
const DOT_PRIOR_MAX_MS = 150;
const DOT_PRIOR_MID_MS = 60;

/**
 * 用速度先验消解结构歧义。
 * 当标记和间隔"同长、且各自只有一类"时，两种解释在结构上完全等价：
 * 把标记当点 -> u = asDot（间隔就是 1u 的字符内间隔，整段是"一个多元素的字母"）；
 * 把标记当划 -> u = asDash（间隔就是 3u 的字母间隔，整段是"多个单元素字母"）。
 * 'H'（四个点，20 WPM）与 'TTTT'（四个划，20 WPM）就是这种同形。
 * 唯一可用的额外信息是"哪种解释给出的速度更像正常电报速度"，所以取落在
 * [25,150]ms 区间内的那个；都在或都不在时取更接近 60ms 的。
 */
function pickBySpeedPrior(asDot: number, asDash: number): number {
  if (asDot <= 0) {
    return asDash;
  }
  if (asDash <= 0) {
    return asDot;
  }
  const dotOk = asDot >= DOT_PRIOR_MIN_MS && asDot <= DOT_PRIOR_MAX_MS;
  const dashOk = asDash >= DOT_PRIOR_MIN_MS && asDash <= DOT_PRIOR_MAX_MS;
  if (dotOk !== dashOk) {
    return dotOk ? asDot : asDash;
  }
  const dDot = Math.abs(Math.log(asDot / DOT_PRIOR_MID_MS));
  const dDash = Math.abs(Math.log(asDash / DOT_PRIOR_MID_MS));
  return dDot <= dDash ? asDot : asDash;
}

/** 流式音调检测器：不断 push 采样，随时读取 buildMorse()/status() */
export class MorseToneDetector {
  private sampleRate: number;
  private analysisRate: number;
  private decim: number;

  // 抽取前的两级一阶低通
  private lpAlpha: number;
  private lp1: number = 0;
  private lp2: number = 0;
  private decimSum: number = 0;
  private decimCount: number = 0;

  // 滑动分析窗（长窗，用于选频与纯度）
  private frameMs: number;
  private hopSamples: number;
  private windowSamples: number;
  private window: Float32Array;
  private hann: Float32Array;
  private hannMean: number = 0.5;
  private hop: Float32Array;
  private hopFill: number = 0;
  /** 窗口已填充的采样数（凑满一窗才开始分析） */
  private fillSamples: number = 0;
  /** 已分析的帧数，段的时长就是按它计的 */
  private frameIndex: number = 0;
  /** 最近一帧的包络幅度，用来算信噪比 */
  private lastEnv: number = 0;
  /** 平滑后的包络（门限判定只看它），抑制噪声引起的瞬时深衰落 */
  private envSmooth: number = 0;
  private alphaEnv: number;

  // 包络（短窗）
  private envSamples: number;

  // 频率扫描 / 锁定
  private minToneHz: number;
  private maxToneHz: number;
  private bankHz: number[] = [];
  private bankCoeff: number[] = [];
  private toleranceHz: number;
  private toneHz: number = 0;
  private locked: boolean = false;
  private manual: boolean = false;
  private targetCoeff: number = 0;
  private guardCoeffLo: number = 0;
  private guardCoeffHi: number = 0;

  // 幅度跟踪
  private sensitivity: number;
  private snrGate: number;
  private purityMin: number;
  private noise: number = 0;
  private peak: number = 0;
  private alphaPeakUp: number;
  private alphaPeakDown: number;
  private alphaNoiseFall: number;
  private alphaNoiseRise: number;
  private level: number = 0;
  private purity: number = 0;
  /** 最近一次确认过的音调的纯度峰值：静音时 purity 会掉到 0，界面上要看这个值 */
  private purityHold: number = 0;
  /** 当前音调的包络电平（半高门限的参考），没听到过音调时为 0 */
  private toneLevel: number = 0;
  private alphaLevel: number;
  private alphaLevelDown: number;
  private warmupMags: number[] = [];
  private warmed: boolean = false;

  // 段状态机
  private minMarkMs: number;
  private minGapMs: number;
  /** 当前生效的掉音合并阈值（两遍估计的第二遍会把它按点长放大） */
  private mergeGapMs: number = 8;
  private toneOn: boolean = false;
  private segStartFrame: number = 0;
  private segments: MorseToneSegment[] = [];
  private markCount: number = 0;
  private quietFrames: number = 0;
  private onRun: number = 0;
  private onRunStart: number = 0;
  private offRun: number = 0;
  private offRunStart: number = 0;



  constructor(sampleRate: number, options?: MorseToneOptions) {
    const opts: MorseToneOptions = options === undefined ? {} : options;
    this.sampleRate = sampleRate > 0 ? sampleRate : 16000;

    const target = opts.analysisRate !== undefined ? opts.analysisRate : 8000;
    let decim = Math.round(this.sampleRate / target);
    if (decim < 1) {
      decim = 1;
    }
    this.decim = decim;
    this.analysisRate = this.sampleRate / decim;

    this.minToneHz = opts.minToneHz !== undefined ? opts.minToneHz : 300;
    this.maxToneHz = opts.maxToneHz !== undefined ? opts.maxToneHz : 1500;
    this.sensitivity = opts.sensitivity !== undefined ? opts.sensitivity : 0.45;
    this.purityMin = opts.purityMin !== undefined ? opts.purityMin : 0.45;
    this.minMarkMs = opts.minMarkMs !== undefined ? opts.minMarkMs : 12;
    this.minGapMs = opts.minGapMs !== undefined ? opts.minGapMs : 8;
    this.toleranceHz = opts.toleranceHz !== undefined ? opts.toleranceHz : 20;
    if (this.toleranceHz < 10) {
      this.toleranceHz = 10;
    }

    // 低通截止取"最高音调 + 余量"，两级级联保证抽取时高频混叠尽量小；
    // 用户硬锁定的频点比扫描上限还高时，截止频率跟着抬高，别把它滤掉
    const manualHz = opts.toneHz !== undefined ? opts.toneHz : 0;
    let cutoff = this.maxToneHz + 400;
    if (manualHz > 0 && manualHz + 400 > cutoff) {
      cutoff = manualHz + 400;
    }
    const fc = cutoff;
    const rc = 1 / (2 * Math.PI * fc);
    const dt = 1 / this.sampleRate;
    this.lpAlpha = dt / (rc + dt);

    // 每 hop 分析一次：时间分辨率 = hop，频率分辨率 = 1/长窗
    this.frameMs = opts.frameMs !== undefined ? opts.frameMs : 5;
    let hop = Math.round(this.analysisRate * this.frameMs / 1000);
    if (hop < 4) {
      hop = 4;
    }
    this.hopSamples = hop;
    this.hop = new Float32Array(hop);

    // 分析窗长 = 1/带宽：容差 20Hz -> 50ms 窗，容差 100Hz -> 10ms 窗。
    // 窗越长频带越窄（越能躲开杂音），但时间分辨率越差、越难跟上对方的频率漂移
    let win = Math.round(this.analysisRate / this.toleranceHz);
    const winMin = hop * 2;
    const winMax = Math.round(this.analysisRate * 0.06);
    if (win < winMin) {
      win = winMin;
    }
    if (win > winMax) {
      win = winMax;
    }
    this.windowSamples = win;
    this.window = new Float32Array(win);
    this.hann = new Float32Array(win);
    let hannSum = 0;
    for (let i = 0; i < win; i++) {
      const w = 0.5 * (1 - Math.cos(2 * Math.PI * i / (win - 1)));
      this.hann[i] = w;
      hannSum += w;
    }
    this.hannMean = hannSum / win;
    if (this.hannMean < 0.1) {
      this.hannMean = 0.5;
    }

    let env = Math.round(this.analysisRate * ENV_MS / 1000);
    if (env > win) {
      env = win;
    }
    if (env < hop) {
      env = hop;
    }
    this.envSamples = env;

    // 时间常数按 hop 折算：峰值上升快、下降慢；噪声底降得快、抬得慢
    this.alphaPeakUp = 1 - Math.exp(-this.frameMs / 25);
    this.alphaPeakDown = Math.exp(-this.frameMs / 1200);
    this.alphaNoiseFall = 1 - Math.exp(-this.frameMs / 150);
    this.alphaNoiseRise = 1 - Math.exp(-this.frameMs / 8000);
    this.alphaEnv = 1 - Math.exp(-this.frameMs / ENV_SMOOTH_MS);
    this.alphaLevel = 1 - Math.exp(-this.frameMs / TONE_LEVEL_MS);
    // 长时间没有音调时缓慢忘掉旧电平（对方可能换了音量），但仍然保留一段记忆
    this.alphaLevelDown = Math.exp(-this.frameMs / 3000);
    this.mergeGapMs = this.minGapMs;
    // 灵敏度越大 -> 门限越高 -> 越不容易误触发
    this.snrGate = SNR_GATE_BASE * (this.sensitivity / 0.45);

    for (let hz = this.minToneHz; hz <= this.maxToneHz; hz += SCAN_STEP_HZ) {
      this.bankHz.push(hz);
      this.bankCoeff.push(2 * Math.cos(2 * Math.PI * hz / this.analysisRate));
    }

    if (manualHz > 0) {
      this.lockTone(manualHz, true);
    }
  }

  private coeffFor(hz: number): number {
    return 2 * Math.cos(2 * Math.PI * hz / this.analysisRate);
  }

  /** 锁定频点；manual=true 表示用户指定，永远不会自动换频 */
  private lockTone(hz: number, isManual: boolean): void {
    this.toneHz = hz;
    this.manual = isManual;
    this.locked = true;
    this.targetCoeff = this.coeffFor(hz);
    let lo = hz - this.toleranceHz * GUARD_OFFSET;
    let hi = hz + this.toleranceHz * GUARD_OFFSET;
    const nyq = this.analysisRate / 2;
    if (lo < 40) {
      lo = 40;
    }
    if (hi > nyq - 40) {
      hi = nyq - 40;
    }
    this.guardCoeffLo = this.coeffFor(lo);
    this.guardCoeffHi = this.coeffFor(hi);
  }

  /**
   * 聆听过程中实时改参数：只改"不依赖分析窗长/滤波器系数"的那几项，
   * 也就是用户最常调的识别频率、降噪强度、灵敏度和最短音长。
   * 带宽 toleranceHz、采样率、帧长决定滑动窗长度，必须重新开始聆听才会生效。
   */
  applyToneOptions(options?: MorseToneOptions): void {
    if (options === undefined) {
      return;
    }
    if (options.toneHz !== undefined) {
      if (options.toneHz > 0) {
        this.lockTone(options.toneHz, true);
      } else if (this.manual) {
        // 从"固定频率"切回"自动选频"：解锁后下一帧就会重新扫频
        this.manual = false;
        this.locked = false;
        this.toneHz = 0;
        this.quietFrames = 0;
      }
    }
    if (options.sensitivity !== undefined) {
      this.sensitivity = options.sensitivity;
      this.snrGate = SNR_GATE_BASE * (this.sensitivity / 0.45);
    }
    if (options.purityMin !== undefined) {
      let p = options.purityMin;
      if (p < 0.05) {
        p = 0.05;
      }
      if (p > 0.95) {
        p = 0.95;
      }
      this.purityMin = p;
    }
    if (options.minMarkMs !== undefined) {
      this.minMarkMs = options.minMarkMs;
    }
    if (options.minGapMs !== undefined) {
      this.minGapMs = options.minGapMs;
      if (this.mergeGapMs < this.minGapMs) {
        this.mergeGapMs = this.minGapMs;
      }
    }
  }

  /**
   * 在滑动窗上做 Goertzel。
   * @param coeff 2cos(2πf/fs)
   * @param count 参与计算的样本数（从窗尾往前数）
   * @param weighted 是否加 Hann 窗
   * @returns 归一化幅度（整窗正弦输入约为 振幅/2）
   */
  private goertzel(coeff: number, count: number, weighted: boolean): number {
    const n = this.windowSamples;
    let s1 = 0;
    let s2 = 0;
    const start = n - count;
    for (let i = start; i < n; i++) {
      let x = this.window[i];
      if (weighted) {
        x *= this.hann[i];
      }
      const s0 = x + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    if (power <= 0) {
      return 0;
    }
    return Math.sqrt(power) / n;
  }

  /** 全带功率（窗内均方），纯度判据的分母 */
  private windowPower(): number {
    const n = this.windowSamples;
    let sum = 0;
    for (let i = 0; i < n; i++) {
      const v = this.window[i];
      sum += v * v;
    }
    return sum / n;
  }

  /** 自动模式：在频点银行里找最强的那个频点 */
  private scanBank(): number {
    let bestMag = 0;
    let bestHz = this.toneHz > 0 ? this.toneHz : this.minToneHz;
    for (let i = 0; i < this.bankHz.length; i++) {
      const m = this.goertzel(this.bankCoeff[i], this.windowSamples, true);
      if (m > bestMag) {
        bestMag = m;
        bestHz = this.bankHz[i];
      }
    }
    this.toneHz = bestHz;
    return bestMag;
  }

  /**
   * 处理一个滑动窗：
   * 先定频点（锁定值或扫描峰值），再算包络、纯度、守频，最后跑门限状态机。
   */
  private processWindow(): void {
    const total = this.windowPower();

    // 1) 定频点 + 长窗目标幅度
    let specMag = 0;
    let guardMag = 0;
    if (this.locked) {
      specMag = this.goertzel(this.targetCoeff, this.windowSamples, true);
      const lo = this.goertzel(this.guardCoeffLo, this.windowSamples, true);
      const hi = this.goertzel(this.guardCoeffHi, this.windowSamples, true);
      guardMag = lo > hi ? lo : hi;
    } else {
      specMag = this.scanBank();
      // 还没锁定频点时，扫描峰值所在的频点就是"当前听起来最像音调"的频点，包络也跟着它走。
      // 否则包络用的是构造时那个无效系数（等价于固定在一个假频点上），第一段点划必然被切碎
      this.targetCoeff = this.coeffFor(this.toneHz);
      const lo = this.goertzel(this.coeffFor(this.toneHz - this.toleranceHz * GUARD_OFFSET),
        this.windowSamples, true);
      const hi = this.goertzel(this.coeffFor(this.toneHz + this.toleranceHz * GUARD_OFFSET),
        this.windowSamples, true);
      guardMag = lo > hi ? lo : hi;
    }

    // 2) 音调纯度：目标频点功率 / 全带功率（修正 Hann 窗相干增益）
    const amp = specMag / this.hannMean;
    let purity = 0;
    if (total > 1e-12) {
      purity = 2 * amp * amp / total;
    }
    if (purity > 1) {
      purity = 1;
    }
    this.purity = purity;
    const purityOK = purity >= this.purityMin &&
      (guardMag <= 1e-12 || specMag >= guardMag * GUARD_RATIO);

    // 3) 短窗包络：决定起振/停振时刻。先做一次短时间常数平滑再判定：
    //    否则噪声会让"音调+噪声"的复数和偶尔深衰落，把点/划切成碎片
    const raw = this.goertzel(this.targetCoeff, this.envSamples, false);
    this.envSmooth += (raw - this.envSmooth) * this.alphaEnv;
    const env = this.envSmooth;
    this.lastEnv = env;

    // 4) 启动校准：先听一小段摸清噪声底，避免一开录就把底噪当信号
    if (!this.warmed) {
      this.warmupMags.push(env);
      this.level = 0;
      if (this.warmupMags.length * this.frameMs >= WARMUP_MS) {
        this.finishWarmup();
      }
      this.frameIndex++;
      return;
    }

    if (env > this.peak) {
      this.peak += (env - this.peak) * this.alphaPeakUp;
    } else {
      this.peak *= this.alphaPeakDown;
    }
    if (env < this.noise) {
      this.noise += (env - this.noise) * this.alphaNoiseFall;
    } else {
      this.noise += (env - this.noise) * this.alphaNoiseRise;
    }

    const span = this.peak - this.noise;
    let level = 0;
    if (span > 1e-12) {
      level = (env - this.noise) / span;
    }
    if (level < 0) {
      level = 0;
    }
    if (level > 1) {
      level = 1;
    }
    this.level = level;

    // 5) 门限判定。
    //    门限取"已知音调电平的一半"：包络的前后沿都是斜的，只有半高门限在时间上是对称的
    //    （斜边上升与下降各被切掉同样多），点/划与间隔的时长才不会一个被拉长一个被压短。
    //    没听过音调之前（toneLevel=0）只能用噪声底推门限。
    let onTh = this.noise * this.snrGate;
    let offTh = this.noise * OFF_NOISE_FLOOR;
    const halfTh = this.toneLevel * 0.5;
    if (halfTh > onTh) {
      onTh = halfTh;
    }
    if (halfTh > offTh) {
      offTh = halfTh;
    }

    if (!this.toneOn) {
      // 包络连续超门限才计数（起点由此回溯），但"是不是真的音调"由纯度把关：
      // 纯度暂时不达标只推迟确认，不会把已经数进来的那段起点丢掉
      if (env >= onTh) {
        if (this.onRun === 0) {
          this.onRunStart = this.frameIndex;
        }
        this.onRun++;
        if (this.onRun >= ON_CONFIRM_FRAMES && purityOK) {
          // 段的起点回溯到这一串超门限帧的第一帧，确认延迟不会造成系统性偏差
          this.closeSegment(this.onRunStart);
          this.toneOn = true;
          this.segStartFrame = this.onRunStart;
          this.onRun = 0;
          this.quietFrames = 0;
          this.purityHold = purity;
          // 刚确认第一段音调：把电平初始化到当前包络，这一段的后沿就能用半高门限判
          if (this.toneLevel <= 0) {
            this.toneLevel = env;
          }
          // 第一次听到"像音调"的信号就锁定它的频率，之后只测这一个频点
          if (!this.locked && this.toneHz > 0) {
            this.lockTone(this.toneHz, false);
          }
        }
      } else {
        this.onRun = 0;
        this.quietFrames++;
        // 一直没有音调就慢慢忘掉旧电平，避免对方换了个更轻的音调时听不见
        this.toneLevel *= this.alphaLevelDown;
        // 静了很久，允许重新扫描（对方可能换了音调）；用户指定的频率不换
        const quietMs = this.quietFrames * this.frameMs;
        if (this.locked && !this.manual && quietMs > RESCAN_AFTER_MS) {
          this.locked = false;
        }
      }
    } else {
      if (purity > this.purityHold) {
        this.purityHold = purity;
      }
      // 跟踪当前音调的包络平台，供"半高门限"使用
      this.toneLevel += (env - this.toneLevel) * this.alphaLevel;
      if (env < offTh) {
        if (this.offRun === 0) {
          this.offRunStart = this.frameIndex;
        }
        this.offRun++;
        if (this.offRun >= OFF_CONFIRM_FRAMES) {
          this.closeSegment(this.offRunStart);
          this.toneOn = false;
          this.segStartFrame = this.offRunStart;
          this.offRun = 0;
        }
      } else {
        this.offRun = 0;
        this.quietFrames = 0;
      }
    }

    this.frameIndex++;
  }

  /**
   * 校准结束：用启动窗口的帧能量估计噪声底。
   * 取最小的一半求均值，这样即使开录时信号已经来了，噪声底也不会被拉高。
   */
  private finishWarmup(): void {
    const sorted: number[] = this.warmupMags.slice().sort((a: number, b: number) => a - b);
    let half = Math.floor(sorted.length / 2);
    if (half < 1) {
      half = 1;
    }
    let sum = 0;
    for (let i = 0; i < half; i++) {
      sum += sorted[i];
    }
    this.noise = sum / half;
    if (this.noise < 1e-9) {
      this.noise = 1e-9;
    }
    this.peak = sorted[sorted.length - 1];
    if (this.peak < this.noise) {
      this.peak = this.noise;
    }
    this.warmed = true;
    this.segStartFrame = this.frameIndex;
    this.quietFrames = 0;
  }

  private closeSegment(endFrame: number): void {
    const durationMs = (endFrame - this.segStartFrame) * this.frameMs;
    if (durationMs <= 0) {
      return;
    }
    if (this.toneOn) {
      this.segments.push({ isTone: true, durationMs: durationMs });
      this.markCount++;
    } else {
      // 丢掉第一个音调之前的开头的静音
      if (this.markCount > 0) {
        this.segments.push({ isTone: false, durationMs: durationMs });
      }
    }
  }

  /** 送入单声道采样（-1 ~ 1），可以任意切片多次调用 */
  push(samples: Float32Array): void {
    for (let i = 0; i < samples.length; i++) {
      this.lp1 += this.lpAlpha * (samples[i] - this.lp1);
      this.lp2 += this.lpAlpha * (this.lp1 - this.lp2);
      this.decimSum += this.lp2;
      this.decimCount++;
      if (this.decimCount >= this.decim) {
        const v = this.decimSum / this.decim;
        this.decimSum = 0;
        this.decimCount = 0;
        this.hop[this.hopFill] = v;
        this.hopFill++;
        if (this.hopFill >= this.hopSamples) {
          this.advanceWindow();
          this.hopFill = 0;
        }
      }
    }
  }

  /** 窗口向前滑动一个 hop，凑满一窗后开始分析 */
  private advanceWindow(): void {
    const n = this.windowSamples;
    const hop = this.hopSamples;
    for (let i = 0; i < n - hop; i++) {
      this.window[i] = this.window[i + hop];
    }
    for (let i = 0; i < hop; i++) {
      this.window[n - hop + i] = this.hop[i];
    }
    if (this.fillSamples < n) {
      this.fillSamples += hop;
      return;
    }
    this.processWindow();
  }

  reset(): void {
    this.lp1 = 0;
    this.lp2 = 0;
    this.decimSum = 0;
    this.decimCount = 0;
    this.hopFill = 0;
    this.fillSamples = 0;
    this.frameIndex = 0;
    this.lastEnv = 0;
    for (let i = 0; i < this.windowSamples; i++) {
      this.window[i] = 0;
    }
    for (let i = 0; i < this.hopSamples; i++) {
      this.hop[i] = 0;
    }
    this.noise = 0;
    this.peak = 0;
    this.level = 0;
    this.purity = 0;
    this.purityHold = 0;
    this.envSmooth = 0;
    this.toneLevel = 0;
    this.mergeGapMs = this.minGapMs;
    this.toneOn = false;
    this.segStartFrame = 0;
    this.segments = [];
    this.markCount = 0;
    this.quietFrames = 0;
    this.onRun = 0;
    this.onRunStart = 0;
    this.offRun = 0;
    this.offRunStart = 0;

    const manualHz = this.manual ? this.toneHz : 0;
    if (manualHz > 0) {
      this.lockTone(manualHz, true);
    } else {
      this.locked = false;
      this.toneHz = 0;
    }
    this.warmupMags = [];
    this.warmed = false;
  }

  /** 当前跟踪到的峰值幅度（调试/界面用） */
  peakLevel(): number {
    return this.peak;
  }

  /** 当前跟踪到的噪声幅度（调试/界面用） */
  noiseLevel(): number {
    return this.noise;
  }

  /** 最近一次音调的纯度 0~1：静音时给上一次的峰值，方便界面显示识别质量 */
  purityLevel(): number {
    return this.toneOn ? this.purity : this.purityHold;
  }

  /** 频率是否已锁定 */
  isLocked(): boolean {
    return this.locked;
  }

  /** 当前锁定/估计到的频点（Hz），0 表示还没定 */
  lockedHz(): number {
    return this.toneHz;
  }

  /**
   * 合并毛刺与掉音，得到干净的段序列：
   *  - 短于 minMarkMs 的"响"直接丢掉（尖峰毛刺）；
   *  - 短于合并阈值的"静"把前后两个"响"合并成一个音（发射机掉音、采集丢帧）。
   * 合并阈值由调用方给：第二遍会用"粗估点长的一半"重算，避免把点划切碎。
   */
  private normalized(mergeGapMs: number): MorseToneSegment[] {
    const src = this.segments;
    const out: MorseToneSegment[] = [];
    let i = 0;
    while (i < src.length) {
      const s = src[i];
      if (s.isTone) {
        if (s.durationMs < this.minMarkMs) {
          i++;
          continue;
        }
        let dur = s.durationMs;
        let j = i + 1;
        while (j + 1 < src.length && !src[j].isTone && src[j].durationMs < mergeGapMs &&
          src[j + 1].isTone) {
          dur += src[j].durationMs + src[j + 1].durationMs;
          j += 2;
        }
        out.push({ isTone: true, durationMs: dur });
        i = j;
      } else {
        out.push(s);
        i++;
      }
    }
    return out;
  }

  /** 段序列里的"响"时长（短于 minMarkMs 的毛刺不算） */
  private marksOf(segs: MorseToneSegment[]): number[] {
    const marks: number[] = [];
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (s.isTone && s.durationMs >= this.minMarkMs) {
        marks.push(s.durationMs);
      }
    }
    return marks;
  }

  /** 段序列里的"静"时长；结尾那段静音是"录制还没停"，不是字母间隔，不参与估计 */
  private gapsOf(segs: MorseToneSegment[]): number[] {
    const gaps: number[] = [];
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (!s.isTone && i !== segs.length - 1 && s.durationMs >= this.minGapMs) {
        gaps.push(s.durationMs);
      }
    }
    return gaps;
  }

  /**
   * 从"响/静时长"推单位时间：标记分簇取点簇，再用字母内间隔校正，最后整数倍最小二乘细化。
   * 关键点：字母内间隔永远是 1u，是比标记更可靠的标尺（标记会被门限拉长/压短），
   * 而"标记和间隔一样长"时不能再假设间隔是 3u 的字母间隔 —— 那会把 u 估成三分之一。
   */
  private unitFromMarks(marks: number[], gaps: number[]): number {
    if (marks.length === 0) {
      return 0;
    }
    const mc = clusterCenters(marks, 2);
    let u = 0;
    let split = false;
    if (mc.length >= 2 && mc[1] > mc[0] * 1.7) {
      // 标记明显分成"短/长"两簇：短簇就是点
      u = mc[0];
      split = true;
    } else {
      // 只有一类标记：先按点算，下面再用间隔纠正
      u = mean(marks);
    }
    // 字母内间隔（1u）比标记可靠：只取和 u 同量级的间隔来校正，且只往下修
    let gapSum = 0;
    let gapCount = 0;
    for (let i = 0; i < gaps.length; i++) {
      const g = gaps[i];
      if (g >= u * 0.4 && g <= u * 1.7) {
        gapSum += g;
        gapCount++;
      }
    }
    if (gapCount > 0) {
      const gm = gapSum / gapCount;
      if (gm < u) {
        u = gm;
      }
    }
    if (!split) {
      // 全是同一类标记：可能是"全点"也可能是"全划"
      const gc = clusterCenters(gaps, 2);
      const mm = mean(marks);
      if (gc.length >= 2 && gc[1] > gc[0] * 1.7) {
        // 间隔分成两类，最短的那类里一定含 1u（字符内间隔），比标记可靠
        if (gc[0] < u) {
          u = gc[0];
        }
      } else if (gc.length >= 1 && gc[0] > mm * 1.6) {
        // 间隔明显比标记长 -> 标记只可能是点，间隔就是 3u/7u 的字母/单词间隔
        u = mm;
      } else {
        // 标记和间隔一样长，且都只有一类：结构上无法区分
        // "标记全是划（间隔是 3u 的字母间隔）"与"标记全是点（间隔是 1u 的字符内间隔）"，
        // 例如 'TTTT' 与 'H' 就是完全同形的，只能按"哪种速度更像正常电报速度"来定
        u = pickBySpeedPrior(mm, mm / 3);
      }
    }
    if (u < DOT_MIN_MS) {
      u = DOT_MIN_MS;
    }
    if (u > DOT_MAX_MS) {
      u = DOT_MAX_MS;
    }
    return refineUnit(u, marks, gaps);
  }

  /**
   * 由已完成的段反推：单位时间 u（点长）、划长、点/划分界、字母/单词间隔分界。
   * 全部是纯函数（每次都用当前段序列重算），所以"越听越准"，且同一段数据结果稳定。
   */
  private durationModel(): DurationModel {
    const model: DurationModel = { dot: 0, dash: 0, dashTh: 0, letterTh: 0, wordTh: 0 };
    // 两遍估计：先用最小合并阈值粗估点长，再按点长放大"掉音合并阈值"重算一次。
    // 噪声掉音 / 采集丢帧造成的短间隔会被合并，点划就不会碎成好几段。
    let merge = this.minGapMs;
    const roughSegs = this.normalized(merge);
    const rough = this.unitFromMarks(this.marksOf(roughSegs), this.gapsOf(roughSegs));
    if (rough > 0) {
      const adaptive = rough * DROPOUT_RATIO;
      if (adaptive > merge) {
        merge = adaptive;
      }
    }
    this.mergeGapMs = merge;
    const segs = this.normalized(merge);
    const marks = this.marksOf(segs);
    const gaps = this.gapsOf(segs);
    if (marks.length === 0) {
      return model;
    }

    // 1) 单位时间（点长）：所有时长聚类取最小簇，再用整数倍最小二乘细化
    const u = this.unitFromMarks(marks, gaps);

    // 2) 划长：有明显两簇就用两簇的中点，否则按 3u
    const mc = clusterCenters(marks, 2);
    let dash = u * 3;
    if (mc.length >= 2 && mc[1] > mc[0] * 1.6) {
      dash = mc[1];
    }
    let dashTh = (u + dash) / 2;
    if (dashTh < u * 1.4) {
      dashTh = u * 1.4;
    }
    if (dashTh > u * 4) {
      dashTh = u * 4;
    }

    model.dot = u;
    model.dash = dash;
    model.dashTh = dashTh;
    model.letterTh = u * LETTER_GAP_RATIO;
    model.wordTh = u * WORD_GAP_RATIO;
    return model;
  }

  /** 诊断用：一行打印噪声底/峰值/合并阈值/原始段/归一化段 */
  debugDump(): string {
    const raw: string[] = [];
    for (let i = 0; i < this.segments.length; i++) {
      const s = this.segments[i];
      raw.push((s.isTone ? 'T' : 'g') + s.durationMs.toFixed(0));
    }
    const norm: string[] = [];
    const ns = this.normalized(this.mergeGapMs);
    for (let i = 0; i < ns.length; i++) {
      const s = ns[i];
      norm.push((s.isTone ? 'T' : 'g') + s.durationMs.toFixed(0));
    }
    return 'noise=' + this.noise.toExponential(2) + ' peak=' + this.peak.toFixed(4) +
      ' merge=' + this.mergeGapMs.toFixed(1) + ' dot=' + this.durationModel().dot.toFixed(1) +
      ' dash=' + this.durationModel().dash.toFixed(1) +
      ' dashTh=' + this.durationModel().dashTh.toFixed(1) +
      ' letterTh=' + this.durationModel().letterTh.toFixed(1) +
      ' wordTh=' + this.durationModel().wordTh.toFixed(1) +
      ' locked=' + this.toneHz.toFixed(0) + ' morse=' + this.buildMorse() +
      ' raw[' + raw.join(',') + '] norm[' + norm.join(',') + ']';
  }

  /** 用已完成的段估计点长（1 个单位时间），单位 ms；估计不出来返回 0 */
  estimateDotMs(): number {
    return this.durationModel().dot;
  }

  /** 每次都用当前最新的判定模型重新切分全部段，所以越听越准 */
  buildMorse(): string {
    const model = this.durationModel();
    if (model.dot <= 0) {
      return '';
    }
    const segs = this.normalized(this.mergeGapMs);
    let out = '';
    let pendingGap = -1;
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (s.isTone) {
        if (pendingGap >= 0 && out.length > 0) {
          if (pendingGap >= model.wordTh) {
            out += ' / ';
          } else if (pendingGap >= model.letterTh) {
            out += ' ';
          }
        }
        pendingGap = -1;
        out += s.durationMs > model.dashTh ? '-' : '.';
      } else {
        pendingGap = s.durationMs;
      }
    }
    return out;
  }

  /** 当前音频到文字的最终结果 */
  text(): string {
    return MorseCodec.decode(this.buildMorse()).text;
  }

  status(): MorseAudioStatus {
    const model = this.durationModel();
    const s: MorseAudioStatus = {
      toneOn: this.toneOn,
      level: this.level,
      toneHz: this.locked || this.toneHz > 0 ? this.toneHz : 0,
      dotMs: model.dot,
      dashMs: model.dash,
      wpm: model.dot > 0 ? 1200 / model.dot : 0,
      morse: this.buildMorse(),
      markCount: this.markCount,
      purity: this.toneOn ? this.purity : this.purityHold,
      snr: this.noise > 1e-12 ? this.lastEnv / this.noise : 0,
      locked: this.locked,
      manual: this.manual
    };
    return s;
  }
}

/** 音频侧的对外门面 */
export class MorseAudio {
  /** 整段识别：直接给一段录音，返回摩斯码与文字 */
  static recognize(samples: Float32Array, sampleRate: number, options?: MorseToneOptions): MorseAudioResult {
    const detector = new MorseToneDetector(sampleRate, options);
    detector.push(samples);
    const morse = detector.buildMorse();
    const model = detector.status();
    const r: MorseAudioResult = {
      morse: morse,
      text: MorseCodec.decode(morse).text,
      dotMs: model.dotMs,
      dashMs: model.dashMs,
      wpm: model.wpm,
      toneHz: model.toneHz,
      peak: detector.peakLevel(),
      noise: detector.noiseLevel(),
      markCount: model.markCount,
      purity: detector.purityLevel(),
      locked: detector.isLocked()
    };
    return r;
  }

  /**
   * 把 16bit 小端交错 PCM 转成单声道浮点采样（多声道取平均）。
   * 采集回调给的就是这种 buffer。
   */
  static pcm16ToMonoFloat(buffer: ArrayBuffer, channels: number): Float32Array {
    const ch = channels > 0 ? channels : 1;
    // 奇数个字节时按整数个采样处理，避免 Int16Array 构造抛异常
    const usable: number = buffer.byteLength - (buffer.byteLength % 2);
    const view = new Int16Array(buffer, 0, usable / 2);
    const frames = Math.floor(view.length / ch);
    const out = new Float32Array(frames);
    for (let i = 0; i < frames; i++) {
      let sum = 0;
      for (let c = 0; c < ch; c++) {
        sum += view[i * ch + c];
      }
      out[i] = sum / ch / 32768;
    }
    return out;
  }

  /** 把摩斯码合成成音频（单元测试与"码音播放"都用它） */
  static synthesize(morse: string, options?: MorseSynthOptions): Float32Array {
    const opts: MorseSynthOptions = options === undefined ? {} : options;
    const dotMs = opts.dotMs !== undefined ? opts.dotMs : 60;
    const toneHz = opts.toneHz !== undefined ? opts.toneHz : 700;
    const sampleRate = opts.sampleRate !== undefined ? opts.sampleRate : 16000;
    const amplitude = opts.amplitude !== undefined ? opts.amplitude : 0.6;
    const noise = opts.noise !== undefined ? opts.noise : 0;
    const leadingMs = opts.leadingMs !== undefined ? opts.leadingMs : 100;
    const trailingMs = opts.trailingMs !== undefined ? opts.trailingMs : 100;

    // 1) 文本 -> 字母序列 + 字母之间的间隔类型
    const letters: string[] = [];
    const wordBreak: boolean[] = [];
    let current = '';
    let sepRun = 0;
    let sepHasSlash = false;
    let firstLetter = true;
    for (let i = 0; i < morse.length; i++) {
      const ch = morse.charAt(i);
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
        sepRun++;
        if (current.length > 0) {
          letters.push(current);
          wordBreak.push(false);
          current = '';
          firstLetter = false;
        }
      } else if (ch === '/' || ch === '|') {
        sepHasSlash = true;
        if (current.length > 0) {
          letters.push(current);
          wordBreak.push(false);
          current = '';
          firstLetter = false;
        }
      } else {
        if (sepRun > 0 && !firstLetter) {
          const isWord = sepHasSlash || sepRun >= 2;
          if (letters.length > 0) {
            wordBreak[letters.length - 1] = isWord;
          }
        }
        sepRun = 0;
        sepHasSlash = false;
        current += ch;
      }
    }
    if (current.length > 0) {
      letters.push(current);
      wordBreak.push(false);
    }

    // 2) 字母序列 -> 响/静 时长序列
    const plan: MorseToneSegment[] = [];
    if (letters.length > 0) {
      plan.push({ isTone: false, durationMs: leadingMs });
    }
    for (let i = 0; i < letters.length; i++) {
      const code = letters[i];
      for (let j = 0; j < code.length; j++) {
        const symbol = code.charAt(j);
        if (symbol === '-' || symbol === '_' || symbol === '−') {
          plan.push({ isTone: true, durationMs: dotMs * 3 });
        } else {
          plan.push({ isTone: true, durationMs: dotMs });
        }
        if (j < code.length - 1) {
          plan.push({ isTone: false, durationMs: dotMs });
        }
      }
      if (i < letters.length - 1) {
        plan.push({ isTone: false, durationMs: wordBreak[i] ? dotMs * 7 : dotMs * 3 });
      }
    }
    if (letters.length > 0) {
      plan.push({ isTone: false, durationMs: trailingMs });
    }

    // 3) 时长序列 -> 采样
    let totalMs = 0;
    for (let i = 0; i < plan.length; i++) {
      totalMs += plan[i].durationMs;
    }
    const total = Math.round(totalMs * sampleRate / 1000);
    const out = new Float32Array(total);
    let cursor = 0;
    const ramp = Math.max(1, Math.round(sampleRate * 0.004));
    const omega = 2 * Math.PI * toneHz / sampleRate;
    for (let i = 0; i < plan.length; i++) {
      const count = Math.round(plan[i].durationMs * sampleRate / 1000);
      if (plan[i].isTone) {
        for (let k = 0; k < count; k++) {
          let gain = 1;
          if (k < ramp) {
            gain = 0.5 * (1 - Math.cos(Math.PI * k / ramp));
          }
          const tail = count - 1 - k;
          if (tail < ramp) {
            const g2 = 0.5 * (1 - Math.cos(Math.PI * tail / ramp));
            if (g2 < gain) {
              gain = g2;
            }
          }
          if (cursor + k < total) {
            out[cursor + k] = amplitude * gain * Math.sin(omega * k);
          }
        }
      }
      cursor += count;
    }

    // 4) 可选叠加白噪声（固定种子，测试可复现）
    if (noise > 0) {
      let seed = 20240607;
      for (let i = 0; i < total; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        const r = seed / 0x7fffffff * 2 - 1;
        out[i] += r * noise;
      }
    }
    return out;
  }
}
