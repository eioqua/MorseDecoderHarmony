/**
 * 摩斯电码（Morse Code）编解码核心引擎。
 *
 * 设计说明：
 *  - 纯逻辑实现，不依赖任何 ArkUI / 系统能力，因此可以被 LocalTest 直接单测，
 *    也可以被后续的音频识别模块复用（识别出点划序列后直接调用 decode）。
 *  - 采用 ITU-R M.1677-1 标准码表：字母 A-Z、数字 0-9、常用标点。
 *
 * 输入约定（手工输入场景）：
 *  - 点用 '.'，划用 '-'
 *  - 字母之间用 1 个空格分隔
 *  - 单词之间用 '/'（斜杠）或连续 2 个及以上空格分隔
 *  - 容错：· • ● ． 。 会被当作点；－ — – ― − _ 会被当作划；
 *          ／ ｜ 会被当作单词分隔符；全角空格 \u3000、制表符、换行都会被当作分隔符；
 *          其余无法识别的字符会被忽略，并视作一个字母分隔符。
 */

/** 码表条目：字符 -> 摩斯编码 */
export interface MorseEntry {
  /** 明文字符，如 'A' '7' '.' */
  ch: string;
  /** 摩斯编码，如 '.-' '--...' '.-.-.-' */
  code: string;
}

/** 解码结果 */
export interface MorseDecodeResult {
  /** 解码后的明文（无法识别的编码记为 '?'） */
  text: string;
  /** 解析出的所有编码单元（按出现顺序） */
  tokens: string[];
  /** 无法识别的编码单元（可能重复） */
  unknownTokens: string[];
  /** 成功识别的字符数（不含 '?' 占位） */
  letterCount: number;
  /** 单词数 */
  wordCount: number;
  /** 被忽略的非摩斯字符数量 */
  ignoredCount: number;
}

/** 解析后的点划序列 */
interface MorseSequence {
  /** 每个编码单元，例如 '.-' */
  tokens: string[];
  /** 与 tokens 等长，true 表示该编码单元之后是一个单词间隔 */
  wordBreaks: boolean[];
  /** 被忽略的字符数量 */
  ignoredCount: number;
}

/** 字符分类结果 */
enum CharKind {
  DOT,
  DASH,
  LETTER_GAP,
  WORD_GAP,
  IGNORED
}

const DOT_ALIAS: string = '.·•●．。∙⋅';
const DASH_ALIAS: string = '-－—–―−_¯';
const WORD_SEP: string = '/|\\／｜';
const GAP_ALIAS: string = ' \t\n\r\v\f\u3000\u00A0';

/** 单词判定阈值：连续 >= 2 个空白视为单词间隔 */
const WORD_GAP_THRESHOLD: number = 2;

/** 码表（唯一数据源，编码表与解码表均由它派生，避免两处数据不一致） */
const MORSE_TABLE: MorseEntry[] = [
  // 字母
  { ch: 'A', code: '.-' },
  { ch: 'B', code: '-...' },
  { ch: 'C', code: '-.-.' },
  { ch: 'D', code: '-..' },
  { ch: 'E', code: '.' },
  { ch: 'F', code: '..-.' },
  { ch: 'G', code: '--.' },
  { ch: 'H', code: '....' },
  { ch: 'I', code: '..' },
  { ch: 'J', code: '.---' },
  { ch: 'K', code: '-.-' },
  { ch: 'L', code: '.-..' },
  { ch: 'M', code: '--' },
  { ch: 'N', code: '-.' },
  { ch: 'O', code: '---' },
  { ch: 'P', code: '.--.' },
  { ch: 'Q', code: '--.-' },
  { ch: 'R', code: '.-.' },
  { ch: 'S', code: '...' },
  { ch: 'T', code: '-' },
  { ch: 'U', code: '..-' },
  { ch: 'V', code: '...-' },
  { ch: 'W', code: '.--' },
  { ch: 'X', code: '-..-' },
  { ch: 'Y', code: '-.--' },
  { ch: 'Z', code: '--..' },
  // 数字
  { ch: '0', code: '-----' },
  { ch: '1', code: '.----' },
  { ch: '2', code: '..---' },
  { ch: '3', code: '...--' },
  { ch: '4', code: '....-' },
  { ch: '5', code: '.....' },
  { ch: '6', code: '-....' },
  { ch: '7', code: '--...' },
  { ch: '8', code: '---..' },
  { ch: '9', code: '----.' },
  // 常用标点
  { ch: '.', code: '.-.-.-' },
  { ch: ',', code: '--..--' },
  { ch: '?', code: '..--..' },
  { ch: '\'', code: '.----.' },
  { ch: '!', code: '-.-.--' },
  { ch: '/', code: '-..-.' },
  { ch: '(', code: '-.--.' },
  { ch: ')', code: '-.--.-' },
  { ch: '&', code: '.-...' },
  { ch: ':', code: '---...' },
  { ch: ';', code: '-.-.-.' },
  { ch: '=', code: '-...-' },
  { ch: '+', code: '.-.-.' },
  { ch: '-', code: '-....-' },
  { ch: '_', code: '..--.-' },
  { ch: '"', code: '.-..-.' },
  { ch: '$', code: '...-..-' },
  { ch: '@', code: '.--.-.' }
];

function buildEncodeTable(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  for (let i = 0; i < MORSE_TABLE.length; i++) {
    table.set(MORSE_TABLE[i].ch, MORSE_TABLE[i].code);
  }
  return table;
}

function buildDecodeTable(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  for (let i = 0; i < MORSE_TABLE.length; i++) {
    table.set(MORSE_TABLE[i].code, MORSE_TABLE[i].ch);
  }
  return table;
}

const ENCODE_TABLE: Map<string, string> = buildEncodeTable();
const DECODE_TABLE: Map<string, string> = buildDecodeTable();

function classify(c: string): CharKind {
  if (DOT_ALIAS.indexOf(c) >= 0) {
    return CharKind.DOT;
  }
  if (DASH_ALIAS.indexOf(c) >= 0) {
    return CharKind.DASH;
  }
  if (WORD_SEP.indexOf(c) >= 0) {
    return CharKind.WORD_GAP;
  }
  if (GAP_ALIAS.indexOf(c) >= 0) {
    return CharKind.LETTER_GAP;
  }
  return CharKind.IGNORED;
}

export class MorseCodec {
  /** 码表副本（供界面展示参考表） */
  static table(): MorseEntry[] {
    const copy: MorseEntry[] = [];
    for (let i = 0; i < MORSE_TABLE.length; i++) {
      copy.push({ ch: MORSE_TABLE[i].ch, code: MORSE_TABLE[i].code });
    }
    return copy;
  }

  /** 判断字符是否为摩斯点/划（含异体符号） */
  static isMorseSymbol(c: string): boolean {
    return DOT_ALIAS.indexOf(c) >= 0 || DASH_ALIAS.indexOf(c) >= 0;
  }

  /** 单个字符 -> 摩斯编码；不支持的字符返回空串 */
  static encodeChar(ch: string): string {
    if (ch.length === 0) {
      return '';
    }
    const code: string | undefined = ENCODE_TABLE.get(ch.toUpperCase());
    return code === undefined ? '' : code;
  }

  /** 摩斯编码 -> 单个字符；无法识别返回空串 */
  static letterOf(token: string): string {
    if (token.length === 0) {
      return '';
    }
    const ch: string | undefined = DECODE_TABLE.get(token);
    return ch === undefined ? '' : ch;
  }

  /**
   * 明文 -> 摩斯码。
   * 字母间用空格，单词间用 ' / '；表中没有的字符用 '?' 占位，便于使用者发现漏码。
   */
  static encode(text: string): string {
    const words: string[] = [];
    let current: string[] = [];
    for (let i = 0; i < text.length; i++) {
      const c: string = text.charAt(i);
      if (GAP_ALIAS.indexOf(c) >= 0) {
        if (current.length > 0) {
          words.push(current.join(' '));
          current = [];
        }
        continue;
      }
      const code: string = MorseCodec.encodeChar(c);
      current.push(code.length > 0 ? code : '?');
    }
    if (current.length > 0) {
      words.push(current.join(' '));
    }
    return words.join(' / ');
  }

  /** 把任意书写形式的摩斯码解析为点划序列 */
  static parse(raw: string): MorseSequence {
    const tokens: string[] = [];
    const wordBreaks: boolean[] = [];
    let currentToken: string = '';
    let gapRun: number = 0;
    let ignoredCount: number = 0;

    for (let i = 0; i < raw.length; i++) {
      const c: string = raw.charAt(i);
      const kind: CharKind = classify(c);
      if (kind === CharKind.DOT || kind === CharKind.DASH) {
        if (gapRun > 0 && currentToken.length > 0) {
          // 遇到新符号，结算上一个编码单元
          tokens.push(currentToken);
          wordBreaks.push(gapRun >= WORD_GAP_THRESHOLD);
          currentToken = '';
        }
        gapRun = 0;
        currentToken += (kind === CharKind.DOT ? '.' : '-');
      } else if (kind === CharKind.LETTER_GAP) {
        gapRun++;
      } else if (kind === CharKind.WORD_GAP) {
        // 斜杠/竖线一律视为单词间隔（等价于足够长的空白）
        gapRun += WORD_GAP_THRESHOLD;
      } else {
        // 非摩斯字符：统计后视作字母分隔符，避免把无关字符悄悄并入同一个编码单元
        ignoredCount++;
        gapRun++;
      }
    }
    if (currentToken.length > 0) {
      tokens.push(currentToken);
      wordBreaks.push(false);
    }

    const sequence: MorseSequence = {
      tokens: tokens,
      wordBreaks: wordBreaks,
      ignoredCount: ignoredCount
    };
    return sequence;
  }

  /** 摩斯码 -> 明文 */
  static decode(raw: string): MorseDecodeResult {
    const sequence: MorseSequence = MorseCodec.parse(raw);
    const tokens: string[] = sequence.tokens;
    const words: string[] = [];
    const unknownTokens: string[] = [];
    let letterCount: number = 0;
    let currentWord: string = '';

    for (let i = 0; i < tokens.length; i++) {
      const ch: string = MorseCodec.letterOf(tokens[i]);
      if (ch.length > 0) {
        currentWord += ch;
        letterCount++;
      } else {
        currentWord += '?';
        unknownTokens.push(tokens[i]);
      }
      if (sequence.wordBreaks[i]) {
        words.push(currentWord);
        currentWord = '';
      }
    }
    if (currentWord.length > 0) {
      words.push(currentWord);
    }

    const result: MorseDecodeResult = {
      text: words.join(' '),
      tokens: tokens,
      unknownTokens: unknownTokens,
      letterCount: letterCount,
      wordCount: words.length,
      ignoredCount: sequence.ignoredCount
    };
    return result;
  }

  /** 归一化为标准书写形式：点划用 . - ，字母间空格，单词间 ' / ' */
  static normalize(raw: string): string {
    const sequence: MorseSequence = MorseCodec.parse(raw);
    const words: string[] = [];
    let currentWord: string = '';
    for (let i = 0; i < sequence.tokens.length; i++) {
      currentWord = currentWord.length > 0 ? (currentWord + ' ' + sequence.tokens[i]) : sequence.tokens[i];
      if (sequence.wordBreaks[i]) {
        words.push(currentWord);
        currentWord = '';
      }
    }
    if (currentWord.length > 0) {
      words.push(currentWord);
    }
    return words.join(' / ');
  }

  /**
   * 取末尾"尚未结算"的编码单元，用于实时预览当前正在输入的字符。
   * 例如输入 '.... . .-' 返回 '.-'。
   */
  static trailingToken(raw: string): string {
    let token: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: string = raw.charAt(i);
      const kind: CharKind = classify(c);
      if (kind === CharKind.DOT) {
        token += '.';
      } else if (kind === CharKind.DASH) {
        token += '-';
      } else if (kind === CharKind.LETTER_GAP || kind === CharKind.WORD_GAP) {
        token = '';
      }
    }
    return token;
  }

  /** 一组典型示例，供界面"载入示例"使用 */
  static sample(): string {
    return '.... . .-.. .-.. --- / .-- --- .-. .-.. -..';
  }
}
