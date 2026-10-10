import { describe, it, expect } from '@ohos/hypium';
import { MorseCodec, MorseDecodeResult, MorseEntry } from '../main/ets/model/MorseCodec';

export default function localUnitTest() {
  describe('MorseCodecTest', () => {
    it('encode_letters_and_sentence', 0, () => {
      expect(MorseCodec.encode('SOS')).assertEqual('... --- ...');
      expect(MorseCodec.encode('HELLO WORLD')).assertEqual('.... . .-.. .-.. --- / .-- --- .-. .-.. -..');
      // 小写输入按大写处理
      expect(MorseCodec.encode('sos')).assertEqual('... --- ...');
      // 多个空格只产生一个单词间隔
      expect(MorseCodec.encode('A   B')).assertEqual('.- / -...');
      expect(MorseCodec.encode('')).assertEqual('');
      expect(MorseCodec.encode('   ')).assertEqual('');
    });

    it('encode_digits_and_punctuation', 0, () => {
      expect(MorseCodec.encodeChar('0')).assertEqual('-----');
      expect(MorseCodec.encodeChar('9')).assertEqual('----.');
      expect(MorseCodec.encodeChar('.')).assertEqual('.-.-.-');
      expect(MorseCodec.encodeChar('?')).assertEqual('..--..');
      expect(MorseCodec.encodeChar(',')).assertEqual('--..--');
      expect(MorseCodec.encodeChar('@')).assertEqual('.--.-.');
      // 码表中没有的字符用 ? 占位
      expect(MorseCodec.encodeChar('中')).assertEqual('');
      expect(MorseCodec.encode('中')).assertEqual('?');
    });

    it('decode_sentence', 0, () => {
      const result: MorseDecodeResult =
        MorseCodec.decode('.... . .-.. .-.. --- / .-- --- .-. .-.. -..');
      expect(result.text).assertEqual('HELLO WORLD');
      expect(result.letterCount).assertEqual(10);
      expect(result.wordCount).assertEqual(2);
      expect(result.unknownTokens.length).assertEqual(0);
      expect(result.ignoredCount).assertEqual(0);
    });

    it('decode_word_separators', 0, () => {
      // 连续空格、斜杠、竖线都可以分隔单词
      expect(MorseCodec.decode('... --- ...   ... --- ...').text).assertEqual('SOS SOS');
      expect(MorseCodec.decode('... --- ... / ... --- ...').text).assertEqual('SOS SOS');
      expect(MorseCodec.decode('... --- ... | ... --- ...').text).assertEqual('SOS SOS');
      // 单个空格只是字母间隔
      expect(MorseCodec.decode('... --- ...').text).assertEqual('SOS');
      // 首尾空白不影响结果
      expect(MorseCodec.decode('  ... --- ...  ').text).assertEqual('SOS');
    });

    it('decode_tolerates_alternate_symbols', 0, () => {
      // 中点、全角点、长划等异体写法
      expect(MorseCodec.decode('···· · ·−·· ·−·· −−−').text).assertEqual('HELLO');
      expect(MorseCodec.decode('••••\u3000−−−').text).assertEqual('HO');
      expect(MorseCodec.normalize('···· · ·−·· ·−·· −−−')).assertEqual('.... . .-.. .-.. ---');
    });

    it('decode_unknown_token', 0, () => {
      const result: MorseDecodeResult = MorseCodec.decode('.... . .-.. .-.. --- .-.-');
      expect(result.text).assertEqual('HELLO?');
      expect(result.letterCount).assertEqual(5);
      expect(result.unknownTokens.length).assertEqual(1);
      expect(result.unknownTokens[0]).assertEqual('.-.-');
    });

    it('decode_ignores_unrelated_chars', 0, () => {
      const result: MorseDecodeResult = MorseCodec.decode('.-#-...');
      expect(result.text).assertEqual('AB');
      expect(result.ignoredCount).assertEqual(1);
    });

    it('decode_empty_input', 0, () => {
      expect(MorseCodec.decode('').text).assertEqual('');
      expect(MorseCodec.decode('').wordCount).assertEqual(0);
      expect(MorseCodec.decode('    ').text).assertEqual('');
      expect(MorseCodec.decode('....').text).assertEqual('H');
    });

    it('normalize_output', 0, () => {
      expect(MorseCodec.normalize('.... . .-.. .-.. ---   .-- --- .-. .-.. -..'))
        .assertEqual('.... . .-.. .-.. --- / .-- --- .-. .-.. -..');
      expect(MorseCodec.normalize('...---...')).assertEqual('...---...');
      expect(MorseCodec.normalize('')).assertEqual('');
    });

    it('trailing_token_preview', 0, () => {
      expect(MorseCodec.trailingToken('.... . .-')).assertEqual('.-');
      expect(MorseCodec.trailingToken('.... . ')).assertEqual('');
      expect(MorseCodec.trailingToken('')).assertEqual('');
      expect(MorseCodec.letterOf('.-')).assertEqual('A');
      expect(MorseCodec.letterOf('.-.-')).assertEqual('');
    });

    it('is_morse_symbol', 0, () => {
      expect(MorseCodec.isMorseSymbol('.')).assertTrue();
      expect(MorseCodec.isMorseSymbol('−')).assertTrue();
      expect(MorseCodec.isMorseSymbol('/')).assertFalse();
      expect(MorseCodec.isMorseSymbol('A')).assertFalse();
    });

    it('encode_then_decode_round_trip', 0, () => {
      const samples: string[] = ['SOS', 'HELLO WORLD', 'SOS! HELP.', 'CQ CQ DE BD4XYZ', '123 456'];
      for (let i = 0; i < samples.length; i++) {
        const morse: string = MorseCodec.encode(samples[i]);
        expect(MorseCodec.decode(morse).text).assertEqual(samples[i]);
      }
    });

    it('table_is_self_consistent', 0, () => {
      const entries: MorseEntry[] = MorseCodec.table();
      // 26 字母 + 10 数字 + 18 标点
      expect(entries.length).assertEqual(54);
      const codes: string[] = [];
      for (let i = 0; i < entries.length; i++) {
        // 正向与反向查表必须一致
        expect(MorseCodec.encodeChar(entries[i].ch)).assertEqual(entries[i].code);
        expect(MorseCodec.letterOf(entries[i].code)).assertEqual(entries[i].ch);
        // 编码不允许重复，否则解码会产生歧义
        expect(codes.indexOf(entries[i].code)).assertEqual(-1);
        codes.push(entries[i].code);
      }
      // table() 返回副本，修改它不应影响引擎
      entries[0].ch = 'ZZ';
      expect(MorseCodec.letterOf('.-')).assertEqual('A');
    });
  });
}
