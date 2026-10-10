import { describe, it, expect } from '@ohos/hypium';
import { MorseCodec } from '../main/ets/model/MorseCodec';
import {
  MorseAudio,
  MorseAudioResult,
  MorseAudioStatus,
  MorseSynthOptions,
  MorseToneDetector
} from '../main/ets/model/MorseAudio';

const RATE = 16000;

/** 手动拼一段"响/静"计划，用来造出发送方不标准的波形 */
interface Seg {
  isTone: boolean;
  durationMs: number;
}

function seg(isTone: boolean, durationMs: number): Seg {
  const s: Seg = { isTone: isTone, durationMs: durationMs };
  return s;
}

/** 用真实编码器把文字变成摩斯码，再合成成音频，喂给识别器 */
function synth(text: string, dotMs: number, toneHz: number, sampleRate: number, noise: number): Float32Array {
  const opts: MorseSynthOptions = {
    dotMs: dotMs,
    toneHz: toneHz,
    sampleRate: sampleRate,
    noise: noise,
    amplitude: 0.6,
    // 识别器开录后要先安静 300ms 校准噪声底，这里给足
    leadingMs: 400
  };
  return MorseAudio.synthesize(MorseCodec.encode(text), opts);
}

function noiseOnly(count: number, amplitude: number): Float32Array {
  const out = new Float32Array(count);
  let seed = 987654321;
  for (let i = 0; i < count; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (seed / 0x7fffffff * 2 - 1) * amplitude;
  }
  return out;
}

/** 按计划直接渲染音频（带 4ms 升余弦包络，避免爆音） */
function render(plan: Seg[], toneHz: number, rate: number, amplitude: number): Float32Array {
  let totalMs = 0;
  for (let i = 0; i < plan.length; i++) {
    totalMs += plan[i].durationMs;
  }
  const total = Math.round(totalMs * rate / 1000);
  const out = new Float32Array(total);
  const omega = 2 * Math.PI * toneHz / rate;
  const ramp = Math.max(1, Math.round(rate * 0.004));
  let cursor = 0;
  for (let i = 0; i < plan.length; i++) {
    const count = Math.round(plan[i].durationMs * rate / 1000);
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
  return out;
}

/** 往信号里打一些单点尖峰（宽带"咔哒"声），检验杂音能不能被挡掉 */
function injectClicks(samples: Float32Array, everySamples: number, amplitude: number): Float32Array {
  const out = samples.slice();
  for (let i = 1000; i < out.length; i += everySamples) {
    out[i] = amplitude;
    if (i + 1 < out.length) {
      out[i + 1] = -amplitude;
    }
  }
  return out;
}

export default function morseAudioTest() {
  describe('MorseAudioTest', () => {
    it('recognize_clean_20wpm', 0, () => {
      const samples = synth('HELLO WORLD', 60, 700, RATE, 0);
      const r: MorseAudioResult = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('HELLO WORLD');
      expect(r.morse).assertEqual(MorseCodec.encode('HELLO WORLD'));
      expect(r.wpm > 16 && r.wpm < 26).assertTrue();
      expect(r.toneHz > 650 && r.toneHz < 750).assertTrue();
    });

    it('recognize_sos_round_trip', 0, () => {
      const samples = synth('SOS', 60, 700, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.morse).assertEqual('... --- ...');
      expect(r.text).assertEqual('SOS');
    });

    it('recognize_with_background_noise', 0, () => {
      // 信号 0.6、噪声 0.15，信噪比约 12dB
      const samples = synth('HELLO WORLD', 60, 700, RATE, 0.15);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('HELLO WORLD');
    });

    it('recognize_slow_12wpm', 0, () => {
      const samples = synth('CQ CQ DE BD4XYZ K', 100, 600, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('CQ CQ DE BD4XYZ K');
      expect(r.wpm > 10 && r.wpm < 15).assertTrue();
    });

    it('recognize_fast_30wpm', 0, () => {
      const samples = synth('SOS 599', 40, 800, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('SOS 599');
      expect(r.wpm > 25 && r.wpm < 36).assertTrue();
    });

    it('recognize_alternate_tone_and_rate', 0, () => {
      const samples = synth('SOS', 60, 900, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('SOS');
      expect(r.toneHz > 850 && r.toneHz < 950).assertTrue();
    });

    it('recognize_48k_sample_rate', 0, () => {
      const samples = synth('HELLO WORLD', 60, 700, 48000, 0);
      const r = MorseAudio.recognize(samples, 48000);
      expect(r.text).assertEqual('HELLO WORLD');
    });

    it('recognize_44k1_sample_rate', 0, () => {
      const samples = synth('SOS', 60, 700, 44100, 0);
      const r = MorseAudio.recognize(samples, 44100);
      expect(r.text).assertEqual('SOS');
    });

    it('streaming_push_matches_batch', 0, () => {
      const samples = synth('HELLO WORLD', 60, 700, RATE, 0);
      const detector = new MorseToneDetector(RATE, { toneHz: 700 });
      const chunk = 480;
      for (let i = 0; i < samples.length; i += chunk) {
        let end = i + chunk;
        if (end > samples.length) {
          end = samples.length;
        }
        detector.push(samples.slice(i, end));
      }
      const st: MorseAudioStatus = detector.status();
      expect(detector.buildMorse()).assertEqual(MorseCodec.encode('HELLO WORLD'));
      expect(detector.text()).assertEqual('HELLO WORLD');
      expect(st.markCount > 15).assertTrue();
    });

    it('manual_tone_option_locks_frequency', 0, () => {
      const samples = synth('SOS', 60, 700, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE, { toneHz: 700 });
      expect(r.text).assertEqual('SOS');
      expect(r.toneHz).assertEqual(700);
      expect(r.locked).assertTrue();
    });

    it('noise_only_does_not_decode', 0, () => {
      const r = MorseAudio.recognize(noiseOnly(RATE * 3, 0.2), RATE);
      expect(r.text).assertEqual('');
      expect(r.markCount).assertEqual(0);
    });

    it('empty_and_silence_input', 0, () => {
      const empty = MorseAudio.recognize(new Float32Array(0), RATE);
      expect(empty.text).assertEqual('');
      expect(empty.morse).assertEqual('');
      const silence = MorseAudio.recognize(new Float32Array(RATE), RATE);
      expect(silence.text).assertEqual('');
      expect(silence.markCount).assertEqual(0);
    });

    it('reset_clears_state', 0, () => {
      const samples = synth('SOS', 60, 700, RATE, 0);
      const detector = new MorseToneDetector(RATE);
      detector.push(samples);
      expect(detector.buildMorse().length > 0).assertTrue();
      detector.reset();
      expect(detector.buildMorse()).assertEqual('');
      expect(detector.status().markCount).assertEqual(0);
    });

    it('pcm16_stereo_to_mono_float', 0, () => {
      const pcm = new Int16Array([1000, 3000, -1000, -3000]);
      const mono = MorseAudio.pcm16ToMonoFloat(pcm.buffer as ArrayBuffer, 2);
      expect(mono.length).assertEqual(2);
      expect(Math.abs(mono[0] - 2000 / 32768) < 1e-6).assertTrue();
      expect(Math.abs(mono[1] + 2000 / 32768) < 1e-6).assertTrue();
    });

    it('pcm16_mono_to_float_full_scale', 0, () => {
      const pcm = new Int16Array([32767, -32768]);
      const mono = MorseAudio.pcm16ToMonoFloat(pcm.buffer as ArrayBuffer, 1);
      expect(mono.length).assertEqual(2);
      expect(Math.abs(mono[0] - 1) < 1e-3).assertTrue();
      expect(Math.abs(mono[1] + 1) < 1e-3).assertTrue();
    });

    it('synthesize_length_matches_timing', 0, () => {
      // 一个点：起始静音 100ms + 点 60ms + 结尾静音 100ms = 260ms
      const samples = MorseAudio.synthesize('.', { dotMs: 60, sampleRate: RATE });
      expect(samples.length).assertEqual(Math.round(260 * RATE / 1000));
    });

    it('synthesize_marks_word_gaps', 0, () => {
      // 两个单词之间是 7 个单位时间
      const samples = MorseAudio.synthesize('.- -...', { dotMs: 50, sampleRate: RATE, leadingMs: 400 });
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('AB');
      expect(r.morse).assertEqual('.- -...');
    });

    it('recognize_digits_and_punctuation', 0, () => {
      const samples = synth('QTH? 599.', 60, 700, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('QTH? 599.');
    });

    // ---- 以下为抗噪 / 选频 / 自适应判定新增用例 ----

    it('recognize_in_loud_noise', 0, () => {
      // 噪声幅度 0.35，比信号的一半还高，靠"音调纯度"把音调挑出来
      const samples = synth('SOS', 60, 700, RATE, 0.35);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('SOS');
      expect(r.purity > 0.5).assertTrue();
    });

    it('click_noise_does_not_break_decode', 0, () => {
      // 每 100ms 打一个宽带尖峰，模拟咔哒杂音
      const samples = injectClicks(synth('SOS', 60, 700, RATE, 0.05), Math.round(RATE * 0.1), 0.9);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('SOS');
    });

    it('manual_lock_ignores_off_frequency_tone', 0, () => {
      // 对方在 1000Hz 上发报，用户锁在 700Hz：宁可不响，也不能乱响
      const samples = synth('SOS', 60, 1000, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE, { toneHz: 700 });
      expect(r.markCount).assertEqual(0);
      expect(r.text).assertEqual('');
    });

    it('auto_mode_ignores_tone_outside_scan_range', 0, () => {
      // 2000Hz 纯音落在扫描范围(300~1500)之外，不能触发解码
      const plan: Seg[] = [seg(false, 400), seg(true, 600), seg(false, 200)];
      const samples = render(plan, 2000, RATE, 0.6);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.markCount).assertEqual(0);
      expect(r.text).assertEqual('');
    });

    it('sloppy_sender_compressed_dashes', 0, () => {
      // 发送方把划发成了 1.9 个单位（固定 2 倍门限会判成点），靠两簇中点仍能判对
      const u = 60;
      const plan: Seg[] = [
        seg(false, 400),
        seg(true, u * 1), seg(false, u * 1), seg(true, u * 1.9),
        seg(false, u * 3.4),
        seg(true, u * 1.9), seg(false, u * 1), seg(true, u * 1),
        seg(false, u * 1), seg(true, u * 1), seg(false, u * 1), seg(true, u * 1),
        seg(false, 120)
      ];
      const r = MorseAudio.recognize(render(plan, 700, RATE, 0.6), RATE);
      expect(r.text).assertEqual('AB');
    });

    it('all_dash_letters_infer_dash', 0, () => {
      // 全是划、且间隔和划一样长（字母间隔 3 单位）时，应推断出"标记是划"
      const samples = synth('TTTT', 60, 700, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('TTTT');
      expect(r.dotMs > 45 && r.dotMs < 75).assertTrue();
    });

    it('all_dot_letters_decode', 0, () => {
      const samples = synth('HHHH', 60, 700, RATE, 0);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('HHHH');
    });

    it('letter_gaps_do_not_become_word_breaks', 0, () => {
      // 没有单词间隔时不能凭空多出 "/"（把点识别成斜杠的老毛病）
      const samples = synth('SOS', 35, 700, RATE, 0.1);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('SOS');
      expect(r.morse.indexOf('/') < 0).assertTrue();
    });

    it('word_break_is_kept', 0, () => {
      const samples = synth('SOS SOS', 60, 700, RATE, 0.1);
      const r = MorseAudio.recognize(samples, RATE);
      expect(r.text).assertEqual('SOS SOS');
      expect(r.morse.indexOf(' / ') > 0).assertTrue();
    });

    it('short_dropout_inside_dash_is_merged', 0, () => {
      // 'S' + 'O'，其中 O 的第一个划中间掉了 20ms 的音；minGapMs=30 时应该合并成一个划
      const plan: Seg[] = [
        seg(false, 400),
        seg(true, 60), seg(false, 60), seg(true, 60), seg(false, 60), seg(true, 60),
        seg(false, 180),
        seg(true, 90), seg(false, 20), seg(true, 90),
        seg(false, 60), seg(true, 180), seg(false, 60), seg(true, 180),
        seg(false, 120)
      ];
      const samples = render(plan, 700, RATE, 0.6);
      const merged = MorseAudio.recognize(samples, RATE, { minGapMs: 30 });
      expect(merged.text).assertEqual('SO');
    });

    it('narrow_tolerance_still_decodes', 0, () => {
      // 容差 25Hz -> 40ms 分析窗，时间分辨率变差但选频更狠
      const samples = synth('SOS', 60, 700, RATE, 0.15);
      const r = MorseAudio.recognize(samples, RATE, { toleranceHz: 25 });
      expect(r.text).assertEqual('SOS');
    });

    it('status_reports_speed_and_purity', 0, () => {
      const samples = synth('HELLO WORLD', 60, 700, RATE, 0);
      const detector = new MorseToneDetector(RATE);
      detector.push(samples);
      const st: MorseAudioStatus = detector.status();
      expect(st.locked).assertTrue();
      expect(st.purity > 0.6).assertTrue();
      expect(st.dotMs > 50 && st.dotMs < 70).assertTrue();
      expect(st.dashMs > st.dotMs * 2.2).assertTrue();
      expect(st.manual).assertFalse();
      expect(st.wpm > 16 && st.wpm < 26).assertTrue();
    });
  });
}
