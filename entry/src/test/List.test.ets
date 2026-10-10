import localUnitTest from './LocalUnit.test';
import morseAudioTest from './MorseAudio.test';
import qsoLogTest from './QsoLog.test';

export default function testsuite() {
  localUnitTest();
  morseAudioTest();
  qsoLogTest();
}
