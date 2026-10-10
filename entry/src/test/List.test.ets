import localUnitTest from './LocalUnit.test';
import morseAudioTest from './MorseAudio.test';

export default function testsuite() {
  localUnitTest();
  morseAudioTest();
}
