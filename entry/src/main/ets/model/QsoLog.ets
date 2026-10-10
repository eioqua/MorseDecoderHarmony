/**
 * 通联日志（QSO Log）：记录模型 + 本地持久化 + 录音文件管理 + ADIF / 纯文本导出。
 *
 * 存储策略：
 * - 记录本身用 preferences（轻量 KV）存成一段 JSON。业余通联日志一般几十到几千条，
 *   一次读写完全够用，也省掉了建库建表的复杂度。
 * - 录音单独落在应用沙箱 filesDir/qso_audio/<id>.wav，记录里只保存文件名，
 *   这样删除记录时能顺手把音频一起删掉，不会留下孤儿文件。
 * - 导出的 ADIF/文本写到 filesDir/qso_export/，同时界面提供"复制到剪贴板"，
 *   因为应用沙箱对普通用户不可见。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** preferences 文件名与键名 */
const PREF_NAME = 'morse_qso';
const PREF_KEY_LIST = 'records';
/** 沙箱子目录名 */
const AUDIO_DIR = 'qso_audio';
const EXPORT_DIR = 'qso_export';

export interface QsoRecord {
  /** 记录 ID，同时作为录音文件名 */
  id: string;
  /** 通联时间，ISO 8601 的 UTC 字符串 */
  timeUtc: string;
  /** 对方呼号 */
  call: string;
  /** 我方呼号 */
  myCall: string;
  /** 频率（kHz，0 表示未填） */
  freqKhz: number;
  /** 业余波段，如 40m；留空时按频率自动推导 */
  band: string;
  /** 工作模式，默认 CW */
  mode: string;
  /** 我方发出的信号报告 */
  rstSent: string;
  /** 我方收到的信号报告 */
  rstRcvd: string;
  /** 对方 QTH */
  qth: string;
  /** 设备型号 */
  rig: string;
  /** 天线 */
  antenna: string;
  /** 发射功率 */
  powerW: string;
  /** 备注 */
  notes: string;
  /** 记录时识别到的摩斯码 */
  morse: string;
  /** 摩斯码译文 */
  text: string;
  /** 录音文件名（''＝无录音） */
  audioFile: string;
  /** 录音时长（毫秒） */
  audioMs: number;
}

interface BandRange {
  low: number;
  high: number;
  name: string;
}

/** IARU 三个区的业余波段划分（单位 kHz），按频率升序 */
const BAND_RANGES: BandRange[] = [
  { low: 1800, high: 2000, name: '160m' },
  { low: 3500, high: 4000, name: '80m' },
  { low: 5351.5, high: 5366.5, name: '60m' },
  { low: 7000, high: 7300, name: '40m' },
  { low: 10100, high: 10150, name: '30m' },
  { low: 14000, high: 14350, name: '20m' },
  { low: 18068, high: 18168, name: '17m' },
  { low: 21000, high: 21450, name: '15m' },
  { low: 24890, high: 24990, name: '12m' },
  { low: 28000, high: 29700, name: '10m' },
  { low: 50000, high: 54000, name: '6m' },
  { low: 144000, high: 148000, name: '2m' },
  { low: 430000, high: 440000, name: '70cm' }
];

/** 按频率推导业余波段，不在任何波段内返回 '' */
export function bandOf(freqKhz: number): string {
  if (!(freqKhz > 0)) {
    return '';
  }
  for (let i = 0; i < BAND_RANGES.length; i++) {
    const range = BAND_RANGES[i];
    if (freqKhz >= range.low && freqKhz <= range.high) {
      return range.name;
    }
  }
  return '';
}

/** 频率显示文本，如 7023 kHz / 7023.5 kHz */
export function freqText(freqKhz: number): string {
  if (!(freqKhz > 0)) {
    return '';
  }
  const isInt = Math.round(freqKhz) === freqKhz;
  return (isInt ? freqKhz.toFixed(0) : freqKhz.toFixed(1)) + ' kHz';
}

function pad2(value: number): string {
  return value < 10 ? '0' + value : '' + value;
}

/** 自己解析 ISO 字符串（格式固定为 toISOString() 的输出），不依赖运行时的 ISO 解析能力 */
export function parseIsoUtc(text: string): Date {
  if (text.length < 19) {
    return new Date();
  }
  const year = Number.parseInt(text.substring(0, 4), 10);
  const month = Number.parseInt(text.substring(5, 7), 10);
  const day = Number.parseInt(text.substring(8, 10), 10);
  const hour = Number.parseInt(text.substring(11, 13), 10);
  const minute = Number.parseInt(text.substring(14, 16), 10);
  const second = Number.parseInt(text.substring(17, 19), 10);
  if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
    return new Date();
  }
  return new Date(Date.UTC(year, month - 1, day, hour, minute, second));
}

/** 记录时间（UTC），解析失败时退回当前时间 */
export function recordTime(record: QsoRecord): Date {
  return parseIsoUtc(record.timeUtc);
}

/** UTC 显示文本：YYYY-MM-DD HH:mm */
export function utcText(date: Date): string {
  return '' + date.getUTCFullYear() + '-' + pad2(date.getUTCMonth() + 1) + '-' + pad2(date.getUTCDate()) +
    ' ' + pad2(date.getUTCHours()) + ':' + pad2(date.getUTCMinutes());
}

/** ADIF 的 qso_date：YYYYMMDD */
export function utcAdifDate(date: Date): string {
  return '' + date.getUTCFullYear() + pad2(date.getUTCMonth() + 1) + pad2(date.getUTCDate());
}

/** ADIF 的 time_on：HHMM */
export function utcAdifTime(date: Date): string {
  return pad2(date.getUTCHours()) + pad2(date.getUTCMinutes());
}

/** 导出文件名用的时间戳：YYYYMMDD_HHmm */
export function utcFileStamp(date: Date): string {
  return utcAdifDate(date) + '_' + utcAdifTime(date);
}

/** 把界面上的 'YYYY-MM-DD HH:mm' 文本解析回 ISO（UTC）；非法输入返回 '' */
export function isoFromUtcText(text: string): string {
  const trimmed = text.trim();
  if (trimmed.length < 10) {
    return '';
  }
  const year = Number.parseInt(trimmed.substring(0, 4), 10);
  const month = Number.parseInt(trimmed.substring(5, 7), 10);
  const day = Number.parseInt(trimmed.substring(8, 10), 10);
  if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
    return '';
  }
  let hour = 0;
  let minute = 0;
  if (trimmed.length >= 16) {
    const h = Number.parseInt(trimmed.substring(11, 13), 10);
    const mi = Number.parseInt(trimmed.substring(14, 16), 10);
    if (!Number.isNaN(h)) {
      hour = h;
    }
    if (!Number.isNaN(mi)) {
      minute = mi;
    }
  }
  return new Date(Date.UTC(year, month - 1, day, hour, minute, 0)).toISOString();
}

let idSeed: number = 0;

/** 生成记录 ID（同时用作录音文件名，只含字母数字和下划线） */
export function nextRecordId(): string {
  idSeed++;
  return 'q' + Date.now().toString(36) + '_' + idSeed.toString(36);
}

/** 新建一条空白记录（时间取当前 UTC） */
export function newQsoRecord(myCall: string, rig: string): QsoRecord {
  return {
    id: nextRecordId(),
    timeUtc: new Date().toISOString(),
    call: '',
    myCall: myCall,
    freqKhz: 0,
    band: '',
    mode: 'CW',
    rstSent: '599',
    rstRcvd: '599',
    qth: '',
    rig: rig,
    antenna: '',
    powerW: '',
    notes: '',
    morse: '',
    text: '',
    audioFile: '',
    audioMs: 0
  };
}

/** 把从 JSON 读回来的记录补齐默认值（兼容旧版本缺字段的数据） */
function normalizeRecord(raw: QsoRecord): QsoRecord {
  const record = newQsoRecord('', '');
  if (raw.id) {
    record.id = raw.id;
  }
  if (raw.timeUtc) {
    record.timeUtc = raw.timeUtc;
  }
  if (raw.call) {
    record.call = raw.call;
  }
  if (raw.myCall) {
    record.myCall = raw.myCall;
  }
  if (raw.freqKhz > 0) {
    record.freqKhz = raw.freqKhz;
  }
  if (raw.band) {
    record.band = raw.band;
  }
  if (raw.mode) {
    record.mode = raw.mode;
  }
  if (raw.rstSent) {
    record.rstSent = raw.rstSent;
  }
  if (raw.rstRcvd) {
    record.rstRcvd = raw.rstRcvd;
  }
  if (raw.qth) {
    record.qth = raw.qth;
  }
  if (raw.rig) {
    record.rig = raw.rig;
  }
  if (raw.antenna) {
    record.antenna = raw.antenna;
  }
  if (raw.powerW) {
    record.powerW = raw.powerW;
  }
  if (raw.notes) {
    record.notes = raw.notes;
  }
  if (raw.morse) {
    record.morse = raw.morse;
  }
  if (raw.text) {
    record.text = raw.text;
  }
  if (raw.audioFile) {
    record.audioFile = raw.audioFile;
  }
  if (raw.audioMs > 0) {
    record.audioMs = raw.audioMs;
  }
  if (!record.band && record.freqKhz > 0) {
    record.band = bandOf(record.freqKhz);
  }
  return record;
}

/**
 * 字符串的 UTF-8 字节数（ADIF 的长度字段要的是**字节数**，一个汉字算 3 字节）。
 * 不用 TextEncoder：本 SDK 上 `encodeInto` 返回的是写入字节数而不是缓冲，
 * 依赖它拿长度会写出 `<call:undefined>` 这种坏标签，所以这里自己数。
 */
export function utf8Length(text: string): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 0x80) {
      bytes += 1;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        bytes += 4; // 代理对（emoji 等）算 4 字节
        i++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/** ADIF 字段：长度必须是**值的 UTF-8 字节数**，中文备注才不会写坏 */
function adifField(tag: string, value: string): string {
  if (value.length === 0) {
    return '';
  }
  return '<' + tag + ':' + utf8Length(value) + '>' + value + ' ';
}

/** 导出为 ADIF 3.1.4 文本 */
export function toAdif(records: QsoRecord[]): string {
  let out = 'ADIF export from MorseTonglian (摩斯通联)\n';
  out += '<adif_ver:5>3.1.4 <programid:13>MorseTonglian <EOH>\n';
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    const date = recordTime(record);
    let line = '';
    line += adifField('call', record.call);
    line += adifField('qso_date', utcAdifDate(date));
    line += adifField('time_on', utcAdifTime(date));
    line += adifField('band', record.band);
    if (record.freqKhz > 0) {
      line += adifField('freq', (record.freqKhz / 1000).toFixed(5)); // ADIF 的 freq 单位是 MHz
    }
    line += adifField('mode', record.mode.length > 0 ? record.mode : 'CW');
    line += adifField('rst_sent', record.rstSent);
    line += adifField('rst_rcvd', record.rstRcvd);
    line += adifField('station_callsign', record.myCall);
    line += adifField('my_rig', record.rig);
    line += adifField('my_ant', record.antenna);
    line += adifField('tx_pwr', record.powerW);
    line += adifField('qth', record.qth);
    line += adifField('comment', record.notes);
    line += adifField('app_morse_code', record.morse);
    line += adifField('app_morse_text', record.text);
    if (record.audioMs > 0) {
      line += adifField('app_audio_ms', '' + Math.round(record.audioMs));
    }
    out += line + '<EOR>\n';
  }
  return out;
}

/** 导出为人类可读的纯文本 */
export function toText(records: QsoRecord[]): string {
  let out = '';
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    const date = recordTime(record);
    const call = record.call.length > 0 ? record.call : '(未填呼号)';
    out += '[' + utcText(date) + ' UTC] ' + call + '\n';
    if (record.myCall.length > 0) {
      out += '  QSO: ' + record.myCall + ' <-> ' + call + '\n';
    }
    let band = record.band;
    if (!band && record.freqKhz > 0) {
      band = bandOf(record.freqKhz);
    }
    const freq = freqText(record.freqKhz);
    let freqLine = '';
    if (freq.length > 0) {
      freqLine = freq + (band.length > 0 ? ' (' + band + ')' : '');
    } else if (band.length > 0) {
      freqLine = band;
    }
    let head = '  ' + (record.mode.length > 0 ? record.mode : 'CW');
    if (freqLine.length > 0) {
      head += '  ' + freqLine;
    }
    out += head + '\n';
    out += '  RST: 发 ' + (record.rstSent.length > 0 ? record.rstSent : '-') +
      ' / 收 ' + (record.rstRcvd.length > 0 ? record.rstRcvd : '-') + '\n';
    if (record.qth.length > 0) {
      out += '  QTH: ' + record.qth + '\n';
    }
    let station = '';
    if (record.rig.length > 0) {
      station += '设备 ' + record.rig + '  ';
    }
    if (record.antenna.length > 0) {
      station += '天线 ' + record.antenna + '  ';
    }
    if (record.powerW.length > 0) {
      station += '功率 ' + record.powerW;
    }
    if (station.length > 0) {
      out += '  ' + station + '\n';
    }
    if (record.morse.length > 0) {
      out += '  摩斯: ' + record.morse + '\n';
    }
    if (record.text.length > 0) {
      out += '  译文: ' + record.text + '\n';
    }
    if (record.audioMs > 0) {
      out += '  录音: ' + Math.round(record.audioMs / 1000) + ' 秒\n';
    }
    if (record.notes.length > 0) {
      out += '  备注: ' + record.notes + '\n';
    }
    out += '\n';
  }
  return out;
}

/** 日志仓库：读写 preferences 与沙箱文件 */
export class QsoLog {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  private store(): preferences.Preferences | undefined {
    try {
      const options: preferences.Options = { name: PREF_NAME };
      return preferences.getPreferencesSync(this.context, options);
    } catch (e) {
      return undefined;
    }
  }

  /** 读取全部记录，按时间倒序（最新的在前） */
  load(): QsoRecord[] {
    const list: QsoRecord[] = [];
    const store = this.store();
    if (store === undefined) {
      return list;
    }
    let text = '';
    try {
      const raw = store.getSync(PREF_KEY_LIST, '');
      if (typeof raw === 'string') {
        text = raw as string;
      }
    } catch (e) {
      return list;
    }
    if (text.length === 0) {
      return list;
    }
    let parsed: QsoRecord[] = [];
    try {
      parsed = JSON.parse(text) as QsoRecord[];
    } catch (e) {
      return list;
    }
    for (let i = 0; i < parsed.length; i++) {
      list.push(normalizeRecord(parsed[i]));
    }
    list.sort((a: QsoRecord, b: QsoRecord) => recordTime(b).getTime() - recordTime(a).getTime());
    return list;
  }

  private persist(list: QsoRecord[]): boolean {
    const store = this.store();
    if (store === undefined) {
      return false;
    }
    try {
      store.putSync(PREF_KEY_LIST, JSON.stringify(list));
      store.flush().then(() => {
      }).catch(() => {
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 新增一条记录 */
  add(record: QsoRecord): boolean {
    const list = this.load();
    list.push(record);
    return this.persist(list);
  }

  /** 按 id 覆盖更新 */
  update(record: QsoRecord): boolean {
    const list = this.load();
    let found = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === record.id) {
        list[i] = record;
        found = true;
        break;
      }
    }
    if (!found) {
      list.push(record);
    }
    return this.persist(list);
  }

  /** 删除记录及其录音 */
  remove(id: string): boolean {
    const list = this.load();
    const kept: QsoRecord[] = [];
    let audioFile = '';
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        audioFile = list[i].audioFile;
      } else {
        kept.push(list[i]);
      }
    }
    if (audioFile.length > 0) {
      this.deleteAudio(audioFile);
    }
    return this.persist(kept);
  }

  // ---------------- 沙箱文件 ----------------

  private dirPath(name: string): string {
    return this.context.filesDir + '/' + name;
  }

  /** 确保目录存在（沙箱内首次使用需要自建） */
  private ensureDir(name: string): string {
    const dir = this.dirPath(name);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
    }
    return dir;
  }

  /** 保存录音，成功返回文件名（失败返回 ''） */
  saveAudio(id: string, wav: ArrayBuffer): string {
    const fileName = id + '.wav';
    const path = this.ensureDir(AUDIO_DIR) + '/' + fileName;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      try {
        fs.writeSync(file.fd, wav);
      } finally {
        fs.closeSync(file);
      }
      return fileName;
    } catch (e) {
      return '';
    }
  }

  audioPath(fileName: string): string {
    return this.dirPath(AUDIO_DIR) + '/' + fileName;
  }

  hasAudio(fileName: string): boolean {
    if (fileName.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(this.audioPath(fileName));
    } catch (e) {
      return false;
    }
  }

  deleteAudio(fileName: string): void {
    if (fileName.length === 0) {
      return;
    }
    try {
      fs.unlinkSync(this.audioPath(fileName));
    } catch (e) {
    }
  }

  /** 写出导出文件，返回完整路径（失败返回 ''） */
  writeExport(fileName: string, content: string): string {
    const path = this.ensureDir(EXPORT_DIR) + '/' + fileName;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      return path;
    } catch (e) {
      return '';
    }
  }

  exportDir(): string {
    return this.dirPath(EXPORT_DIR);
  }
}
