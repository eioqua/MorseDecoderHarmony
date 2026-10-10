import { describe, it, expect } from '@ohos/hypium';
import {
  bandOf,
  freqText,
  isoFromUtcText,
  newQsoRecord,
  QsoRecord,
  recordTime,
  toAdif,
  toText,
  utf8Length,
  utcAdifDate,
  utcAdifTime,
  utcFileStamp,
  utcText
} from '../main/ets/model/QsoLog';
import { encodeWav16, QSO_AUDIO_RATE, QsoAudioRecorder } from '../main/ets/model/QsoAudio';

/** 造一条字段齐全的记录 */
function fullRecord(): QsoRecord {
  return {
    id: 'q1',
    timeUtc: '2026-10-10T20:56:00.000Z',
    call: 'BG1ABC',
    myCall: 'BG2XYZ',
    freqKhz: 7023,
    band: '40m',
    mode: 'CW',
    rstSent: '599',
    rstRcvd: '579',
    qth: 'Beijing',
    rig: 'IC-7300',
    antenna: 'DP',
    powerW: '100W',
    notes: 'first QSO',
    morse: '.... . .-.. .-.. ---',
    text: 'HELLO',
    audioFile: 'q1.wav',
    audioMs: 4200
  };
}

/** 从 ArrayBuffer 头部按 ASCII 读一段文本（校验 WAV 块标识） */
function asciiAt(buffer: ArrayBuffer, offset: number, length: number): string {
  const view = new DataView(buffer);
  let text = '';
  for (let i = 0; i < length; i++) {
    text += String.fromCharCode(view.getUint8(offset + i));
  }
  return text;
}

export default function qsoLogTest() {
  describe('QsoLogTest', () => {
    it('band_of_amateur_bands', 0, () => {
      expect(bandOf(7023)).assertEqual('40m');
      expect(bandOf(14050)).assertEqual('20m');
      expect(bandOf(144100)).assertEqual('2m');
      expect(bandOf(1800)).assertEqual('160m');
      expect(bandOf(440000)).assertEqual('70cm');
      // 边界：刚好在波段外、以及 GPS/广播等非业余频段
      expect(bandOf(6999)).assertEqual('');
      expect(bandOf(1000)).assertEqual('');
      expect(bandOf(0)).assertEqual('');
      expect(bandOf(-100)).assertEqual('');
    });

    it('freq_text_formats', 0, () => {
      expect(freqText(7023)).assertEqual('7023 kHz');
      expect(freqText(7023.5)).assertEqual('7023.5 kHz');
      expect(freqText(0)).assertEqual('');
    });

    it('utc_formatting_helpers', 0, () => {
      const date = new Date(Date.UTC(2026, 9, 10, 20, 56, 0));
      expect(utcText(date)).assertEqual('2026-10-10 20:56');
      expect(utcAdifDate(date)).assertEqual('20261010');
      expect(utcAdifTime(date)).assertEqual('2056');
      expect(utcFileStamp(date)).assertEqual('20261010_2056');
    });

    it('iso_from_utc_text_round_trip', 0, () => {
      expect(isoFromUtcText('2026-10-10 20:56')).assertEqual('2026-10-10T20:56:00.000Z');
      // 解析回来还是同一时刻（自己解析 ISO，不依赖运行时）
      expect(utcText(recordTime({
        id: '', timeUtc: isoFromUtcText('2026-10-10 20:56'), call: '', myCall: '',
        freqKhz: 0, band: '', mode: 'CW', rstSent: '', rstRcvd: '', qth: '', rig: '',
        antenna: '', powerW: '', notes: '', morse: '', text: '', audioFile: '', audioMs: 0
      }))).assertEqual('2026-10-10 20:56');
      expect(isoFromUtcText('2026-10-10')).assertEqual('2026-10-10T00:00:00.000Z');
      expect(isoFromUtcText('')).assertEqual('');
    });

    it('utf8_length_counts_bytes', 0, () => {
      expect(utf8Length('')).assertEqual(0);
      expect(utf8Length('BG1ABC')).assertEqual(6);
      expect(utf8Length('北京')).assertEqual(6);
      expect(utf8Length('中文备注')).assertEqual(12);
      expect(utf8Length('café')).assertEqual(5);   // é 占 2 字节
      expect(utf8Length('a\u00e9\u4e2d')).assertEqual(6);
    });

    it('adif_header_and_record_fields', 0, () => {
      const adif = toAdif([fullRecord()]);
      expect(adif.includes('<adif_ver:5>3.1.4')).assertTrue();
      expect(adif.includes('<programid:13>MorseTonglian')).assertTrue();
      expect(adif.includes('<EOH>')).assertTrue();
      expect(adif.includes('<call:6>BG1ABC')).assertTrue();
      expect(adif.includes('<qso_date:8>20261010')).assertTrue();
      expect(adif.includes('<time_on:4>2056')).assertTrue();
      expect(adif.includes('<band:3>40m')).assertTrue();
      // freq 以 MHz 计，5 位小数
      expect(adif.includes('<freq:7>7.02300')).assertTrue();
      expect(adif.includes('<mode:2>CW')).assertTrue();
      expect(adif.includes('<rst_sent:3>599')).assertTrue();
      expect(adif.includes('<rst_rcvd:3>579')).assertTrue();
      expect(adif.includes('<station_callsign:6>BG2XYZ')).assertTrue();
      expect(adif.includes('<my_rig:7>IC-7300')).assertTrue();
      expect(adif.includes('<my_ant:2>DP')).assertTrue();
      expect(adif.includes('<tx_pwr:4>100W')).assertTrue();
      expect(adif.includes('<qth:7>Beijing')).assertTrue();
      expect(adif.includes('<comment:9>first QSO')).assertTrue();
      expect(adif.includes('<app_audio_ms:4>4200')).assertTrue();
      expect(adif.endsWith('<EOR>\n')).assertTrue();
    });

    it('adif_lengths_are_utf8_bytes', 0, () => {
      const record = fullRecord();
      record.qth = '北京';
      record.notes = '中文备注';
      const adif = toAdif([record]);
      // 2 个汉字 = 6 字节，4 个汉字 = 12 字节
      expect(adif.includes('<qth:6>北京')).assertTrue();
      expect(adif.includes('<comment:12>中文备注')).assertTrue();
    });

    it('adif_omits_empty_fields', 0, () => {
      const record = newQsoRecord('', '');
      const adif = toAdif([record]);
      expect(adif.includes('<call:')).assertFalse();
      expect(adif.includes('<qth:')).assertFalse();
      expect(adif.includes('<freq:')).assertFalse();
      expect(adif.includes('<band:')).assertFalse();
      expect(adif.includes('<comment:')).assertFalse();
      // 模式为空时按 CW 导出，呼号栏位仍然缺失但结构完整
      expect(adif.includes('<mode:2>CW')).assertTrue();
      expect(adif.includes('<EOR>')).assertTrue();
    });

    it('new_qso_record_defaults', 0, () => {
      const record = newQsoRecord('BG2XYZ', 'IC-7300');
      expect(record.myCall).assertEqual('BG2XYZ');
      expect(record.rig).assertEqual('IC-7300');
      expect(record.mode).assertEqual('CW');
      expect(record.rstSent).assertEqual('599');
      expect(record.rstRcvd).assertEqual('599');
      expect(record.call).assertEqual('');
      expect(record.freqKhz).assertEqual(0);
      expect(record.audioMs).assertEqual(0);
      expect(record.id.length > 0).assertTrue();
      // 时间落在合理范围（刚刚生成）
      const ageMs = Date.now() - recordTime(record).getTime();
      expect(ageMs < 60000).assertTrue();
    });

    it('text_export_contains_key_fields', 0, () => {
      const text = toText([fullRecord()]);
      expect(text.includes('[2026-10-10 20:56 UTC]')).assertTrue();
      expect(text.includes('BG1ABC')).assertTrue();
      expect(text.includes('RST: 发 599 / 收 579')).assertTrue();
      expect(text.includes('7023 kHz')).assertTrue();
      expect(text.includes('40m')).assertTrue();
      expect(text.includes('IC-7300')).assertTrue();
      expect(text.includes('HELLO')).assertTrue();
    });

    it('wav_header_is_valid_pcm16_mono', 0, () => {
      const pcm = new Float32Array(3);
      pcm[0] = 0;
      pcm[1] = 1;
      pcm[2] = -1;
      const wav = encodeWav16(pcm, QSO_AUDIO_RATE);
      const view = new DataView(wav);
      expect(wav.byteLength).assertEqual(44 + 3 * 2);
      expect(asciiAt(wav, 0, 4)).assertEqual('RIFF');
      expect(asciiAt(wav, 8, 4)).assertEqual('WAVE');
      expect(asciiAt(wav, 12, 4)).assertEqual('fmt ');
      expect(asciiAt(wav, 36, 4)).assertEqual('data');
      expect(view.getUint32(4, true)).assertEqual(36 + 6);
      expect(view.getUint16(20, true)).assertEqual(1);
      expect(view.getUint16(22, true)).assertEqual(1);
      expect(view.getUint32(24, true)).assertEqual(8000);
      expect(view.getUint32(28, true)).assertEqual(16000);
      expect(view.getUint16(32, true)).assertEqual(2);
      expect(view.getUint16(34, true)).assertEqual(16);
      expect(view.getUint32(40, true)).assertEqual(6);
      expect(view.getInt16(44, true)).assertEqual(0);
      expect(view.getInt16(46, true)).assertEqual(32767);
      expect(view.getInt16(48, true)).assertEqual(-32767);
    });

    it('recorder_decimates_to_8k', 0, () => {
      const recorder = new QsoAudioRecorder(48000, 1);
      const chunk = new Float32Array(4800);
      for (let i = 0; i < chunk.length; i++) {
        chunk[i] = i % 2 === 0 ? 0.5 : -0.5;
      }
      recorder.pushMono(chunk);
      // 48000 / 8000 = 6 倍抽取
      expect(recorder.samples()).assertEqual(800);
      expect(recorder.durationMs()).assertEqual(100);
      expect(recorder.info().sampleRate).assertEqual(QSO_AUDIO_RATE);
      expect(recorder.info().bytes).assertEqual(44 + 1600);
      expect(recorder.toWav().byteLength).assertEqual(44 + 1600);
      expect(recorder.isEmpty()).assertFalse();
    });

    it('recorder_accepts_interleaved_pcm16', 0, () => {
      // 48kHz 立体声、12 帧 → 降混成 12 个单声道样本 → 6 倍抽取后 2 个
      const interleaved = new Int16Array(24);
      for (let i = 0; i < interleaved.length; i++) {
        interleaved[i] = 1000;
      }
      const recorder = new QsoAudioRecorder(48000, 2);
      recorder.push(interleaved.buffer as ArrayBuffer);
      expect(recorder.samples()).assertEqual(2);
      expect(recorder.durationMs()).assertEqual(0);
    });

    it('recorder_respects_max_seconds_and_clear', 0, () => {
      const recorder = new QsoAudioRecorder(8000, 1, 0.001); // 最多 8 个样本
      recorder.pushMono(new Float32Array(100));
      expect(recorder.samples()).assertEqual(8);
      expect(recorder.isFull()).assertTrue();
      recorder.clear();
      expect(recorder.isEmpty()).assertTrue();
      expect(recorder.samples()).assertEqual(0);
      expect(recorder.toWav().byteLength).assertEqual(44);
    });
  });
}
