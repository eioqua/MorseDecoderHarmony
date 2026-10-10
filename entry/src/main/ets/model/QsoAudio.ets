/**
 * 通联日志用的录音缓冲：把采集到的原始 PCM 实时降采样成 8kHz 单声道，结束后编码为 WAV。
 *
 * 为什么是 8kHz：摩斯侧音集中在 300~1500Hz，8kHz 采样（奈奎斯特 4kHz）足够还原听感，
 * 体积却只有原始 48kHz 双声道的约 1/12（约 16KB/s，10 分钟约 9.6MB）。
 *
 * 纯逻辑实现，不依赖系统音频/文件 API，因此可以离线单元测试。
 */
import { MorseAudio } from './MorseAudio';

/** 录音目标采样率（Hz） */
export const QSO_AUDIO_RATE = 8000;
/** 单次录音最长时长（秒），防止长时间聆听把内存吃光 */
export const QSO_AUDIO_MAX_SECONDS = 600;
/** WAV（PCM16 单声道）固定头长度 */
const WAV_HEADER_BYTES = 44;

export interface QsoAudioInfo {
  sampleRate: number;
  samples: number;
  ms: number;
  bytes: number;
}

/** 往 DataView 里写 ASCII（WAV 的块标识都是 4 个 ASCII 字符） */
function writeAscii(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < text.length; i++) {
    view.setUint8(offset + i, text.charCodeAt(i));
  }
}

/**
 * 抽取降采样：每 factor 个样本取一次均值。
 * 取均值本身就起到简单的抗混叠低通作用，比直接丢样本干净（不会把高频噪声折叠进音频）。
 * limit 是本次最多产出的样本数（按目标采样率计）。
 */
function decimate(mono: Float32Array, factor: number, limit: number): Float32Array {
  if (limit <= 0 || mono.length <= 0) {
    return new Float32Array(0);
  }
  if (factor <= 1) {
    const n = mono.length < limit ? mono.length : limit;
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      out[i] = mono[i];
    }
    return out;
  }
  const count = Math.floor(mono.length / factor);
  const n = count < limit ? count : limit;
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const base = i * factor;
    let sum = 0;
    for (let k = 0; k < factor; k++) {
      sum += mono[base + k];
    }
    out[i] = sum / factor;
  }
  return out;
}

/**
 * 把 -1~1 的浮点单声道采样编码成 16bit PCM 单声道 WAV。
 * 单独抽成模块级函数，方便单测（也是未来"导出原始录音"的复用点）。
 */
export function encodeWav16(pcm: Float32Array, sampleRate: number): ArrayBuffer {
  const rate = sampleRate > 0 ? Math.round(sampleRate) : QSO_AUDIO_RATE;
  const dataBytes = pcm.length * 2;
  const buffer = new ArrayBuffer(WAV_HEADER_BYTES + dataBytes);
  const view = new DataView(buffer);

  // ---- RIFF 头 ----
  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, true); // 后续字节数 = 36 + 数据长度
  writeAscii(view, 8, 'WAVE');
  // ---- fmt 块（16 字节，PCM） ----
  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // 1 = PCM
  view.setUint16(22, 1, true); // 单声道
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true); // 字节率 = 采样率 × 声道 × 位深/8
  view.setUint16(32, 2, true); // 块对齐
  view.setUint16(34, 16, true); // 位深
  // ---- data 块 ----
  writeAscii(view, 36, 'data');
  view.setUint32(40, dataBytes, true);

  let offset = WAV_HEADER_BYTES;
  for (let i = 0; i < pcm.length; i++) {
    let v = pcm[i];
    if (v > 1) {
      v = 1;
    } else if (v < -1) {
      v = -1;
    }
    view.setInt16(offset, Math.round(v * 32767), true);
    offset += 2;
  }
  return buffer;
}

/** 录音缓冲：push 原始 PCM，最后 toWav() 取结果 */
export class QsoAudioRecorder {
  private decim: number;
  private channels: number;
  private maxSamples: number;
  private chunks: Float32Array[] = [];
  private total: number = 0;

  constructor(sourceRate: number, channels: number, maxSeconds: number = QSO_AUDIO_MAX_SECONDS) {
    const rate = sourceRate > 0 ? sourceRate : QSO_AUDIO_RATE;
    this.decim = Math.max(1, Math.round(rate / QSO_AUDIO_RATE));
    this.channels = channels > 0 ? channels : 1;
    const seconds = maxSeconds > 0 ? maxSeconds : QSO_AUDIO_MAX_SECONDS;
    this.maxSamples = Math.round(QSO_AUDIO_RATE * seconds);
  }

  /** 送入一路采集数据（16bit 交错 PCM） */
  push(buffer: ArrayBuffer): void {
    if (buffer.byteLength < 2) {
      return;
    }
    this.pushMono(MorseAudio.pcm16ToMonoFloat(buffer, this.channels));
  }

  /** 送入已经降混好的单声道浮点数据（采集回调里算过一次，避免重复降混） */
  pushMono(mono: Float32Array): void {
    if (mono.length <= 0 || this.total >= this.maxSamples) {
      return;
    }
    const out = decimate(mono, this.decim, this.maxSamples - this.total);
    if (out.length > 0) {
      this.chunks.push(out);
      this.total += out.length;
    }
  }

  clear(): void {
    this.chunks = [];
    this.total = 0;
  }

  isEmpty(): boolean {
    return this.total <= 0;
  }

  /** 已录到的样本数（按 8kHz 计） */
  samples(): number {
    return this.total;
  }

  durationMs(): number {
    return Math.round(this.total * 1000 / QSO_AUDIO_RATE);
  }

  isFull(): boolean {
    return this.total >= this.maxSamples;
  }

  info(): QsoAudioInfo {
    return {
      sampleRate: QSO_AUDIO_RATE,
      samples: this.total,
      ms: this.durationMs(),
      bytes: WAV_HEADER_BYTES + this.total * 2
    };
  }

  /** 拼成连续 PCM 再编码 WAV */
  toWav(): ArrayBuffer {
    const all = new Float32Array(this.total);
    let offset = 0;
    for (let c = 0; c < this.chunks.length; c++) {
      const chunk = this.chunks[c];
      all.set(chunk, offset);
      offset += chunk.length;
    }
    return encodeWav16(all, QSO_AUDIO_RATE);
  }
}
