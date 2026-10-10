import { MorseToneOptions } from './MorseAudio';

/**
 * 界面设置项：统一放在 AppStorage 里，由 PersistentStorage 落盘，
 * 页面用 @StorageLink 绑定，改完立刻生效、下次启动还在。
 *
 * 注意：registerMorseSettings() 必须在任何组件构造之前调用
 * （Index.ets 的模块顶层），否则 @StorageLink 会先用默认值建键，
 * 把上次保存的值覆盖掉。
 */

export const KEY_TONE_HZ = 'mdToneHz';
export const KEY_TOLERANCE = 'mdToleranceHz';
export const KEY_DENOISE = 'mdDenoise';
export const KEY_SENSITIVITY = 'mdSensitivity';
export const KEY_COLOR_MODE = 'mdColorMode';
/** 通联日志用：我方呼号与常用设备（新建记录时预填） */
export const KEY_MY_CALL = 'mdMyCall';
export const KEY_MY_RIG = 'mdMyRig';

/** 0 = 自动选频（扫到音调后锁定）；>0 = 固定在这个频点，永不换频 */
export const DEFAULT_TONE_HZ = 0;
/** 检测带宽 Hz：越小频带越窄越抗噪，越大越能容忍对方频率漂移 */
export const DEFAULT_TOLERANCE = 20;
/** 降噪强度 0~100 */
export const DEFAULT_DENOISE = 40;
/** 灵敏度 0~100（50 对应检测器默认的 0.45） */
export const DEFAULT_SENSITIVITY = 50;
/** 外观：system | light | dark */
export const DEFAULT_COLOR_MODE = 'system';
export const DEFAULT_MY_CALL = '';
export const DEFAULT_MY_RIG = '';

export const TONE_HZ_MIN = 300;
export const TONE_HZ_MAX = 1500;
export const TONE_HZ_STEP = 25;
export const TOLERANCE_MIN = 10;
export const TOLERANCE_MAX = 100;
export const DENOISE_MIN = 0;
export const DENOISE_MAX = 100;
export const SENSITIVITY_MIN = 0;
export const SENSITIVITY_MAX = 100;

export function clamp01(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

/** 降噪强度 0~100 -> 音调纯度门限：越强越只认"像纯正弦"的声音 */
export function denoiseToPurity(denoise: number): number {
  return 0.20 + 0.60 * clamp01(denoise / 100);
}

/** 降噪强度 0~100 -> 最短音长（ms）：越强越容易把极短的干扰咔哒声当毛刺丢掉 */
export function denoiseToMinMarkMs(denoise: number): number {
  return 8 + 12 * clamp01(denoise / 100);
}

/** 灵敏度 0~100 -> 检测器灵敏度参数（0.45 是默认档） */
export function uiToSensitivity(value: number): number {
  return 0.10 + 0.70 * clamp01(value / 100);
}

/** 灵敏度参数 -> 界面用的 0~100（用于恢复默认/反显） */
export function sensitivityToUi(value: number): number {
  return clamp01((value - 0.10) / 0.70) * 100;
}

/** 界面上一次能调的全部识别参数 */
export interface MorseUiSettings {
  toneHz: number;
  toleranceHz: number;
  denoise: number;
  sensitivity: number;
}

/** 把界面设置翻译成检测器参数 */
export function buildToneOptions(settings: MorseUiSettings): MorseToneOptions {
  const options: MorseToneOptions = {
    toneHz: settings.toneHz,
    toleranceHz: settings.toleranceHz,
    sensitivity: uiToSensitivity(settings.sensitivity),
    purityMin: denoiseToPurity(settings.denoise),
    minMarkMs: denoiseToMinMarkMs(settings.denoise)
  };
  return options;
}

/** 把设置键注册进 AppStorage + PersistentStorage（应用启动时调用一次） */
export function registerMorseSettings(): void {
  PersistentStorage.persistProp<number>(KEY_TONE_HZ, DEFAULT_TONE_HZ);
  PersistentStorage.persistProp<number>(KEY_TOLERANCE, DEFAULT_TOLERANCE);
  PersistentStorage.persistProp<number>(KEY_DENOISE, DEFAULT_DENOISE);
  PersistentStorage.persistProp<number>(KEY_SENSITIVITY, DEFAULT_SENSITIVITY);
  PersistentStorage.persistProp<string>(KEY_COLOR_MODE, DEFAULT_COLOR_MODE);
  PersistentStorage.persistProp<string>(KEY_MY_CALL, DEFAULT_MY_CALL);
  PersistentStorage.persistProp<string>(KEY_MY_RIG, DEFAULT_MY_RIG);
}
