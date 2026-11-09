/** Runtime 0–100 stress/suppression policy — port of SuppressionPolicy. */

export const STRESS_SCALE = 100 / 7;
export const MAX_STRESS = 100;
export const STRESS_INITIAL = 0;
export const STRESS_FALL_MULTIPLIER = 0.3;
export const DECAY_REFERENCE_SEC = 5.5;
export const MODERATE_COVER_SUPPRESSION_MULT = 0.65;
export const PRONE_SUPPRESSION_MULT = 0.75;
const DEFAULT_EXPERIENCE = 4.0;
const TIER_KEYS = [-8, -4, 0, 4, 8];
const TIER_ROWS: number[][] = [
  [0.5, 0.5, 0.5, 0.5, 1.0, 1.0, 1.0],
  [1.0, 1.5, 1.5, 2.0, 2.5, 3.0, 3.0],
  [1.0, 4.0, 4.0, 4.0, 4.0, 4.0, 4.0],
  [1.0, 4.0, 4.5, 4.5, 5.0, 5.0, 5.0],
  [1.0, 4.0, 4.5, 4.5, 5.0, 5.0, 5.0],
];
const FIRE_DELAY_BY_BAND = [1.0, 1.05, 1.15, 1.3, 1.5];
const BAND_NERVOUS = 10;
const BAND_SUPPRESSED = 25;
const BAND_PINNED = 45;
const BAND_PANICKED = 70;
const MOVEMENT_BY_BAND = [1.0, 0.9, 0.75, 0.5, 0.35];

export function fireDelayModifier(stress: number): number {
  const band = stressBand(stress);
  return FIRE_DELAY_BY_BAND[band] ?? 1;
}

export function accuracyModifierFor(
  runtimeStress: number,
  distanceTiles: number,
  stressAimFactor = 1.0,
): number {
  const tier = DEFAULT_EXPERIENCE - runtimeStress / STRESS_SCALE;
  const band = Math.max(0, Math.min(6, Math.round(distanceTiles)));
  const tableMult = accuracyMultiplier(tier, band);
  return applyStressAimFactor(tableMult, stressAimFactor);
}

export function stressBand(stress: number): number {
  if (stress < BAND_NERVOUS) {
    return 0;
  }
  if (stress < BAND_SUPPRESSED) {
    return 1;
  }
  if (stress < BAND_PINNED) {
    return 2;
  }
  if (stress < BAND_PANICKED) {
    return 3;
  }
  return 4;
}

export function movementModifier(stress: number): number {
  return MOVEMENT_BY_BAND[stressBand(stress)] ?? 1;
}

export function isPanicked(stress: number): boolean {
  return stress >= BAND_PANICKED;
}

export function suppressionGain(
  stressFactor: number,
  stressLimitTiles: number,
  roundedRangeTiles: number,
): number {
  if (stressLimitTiles <= 0 || roundedRangeTiles >= stressLimitTiles) {
    return 0;
  }
  const original = (stressLimitTiles - roundedRangeTiles) * stressFactor;
  return original > 0 ? original * STRESS_SCALE : 0;
}

export function decayStress(runtimeStress: number, prone: boolean, deltaSec: number): number {
  if (runtimeStress <= STRESS_INITIAL) {
    return STRESS_INITIAL;
  }
  const dt = Math.max(deltaSec, 0);
  if (dt <= 0) {
    return runtimeStress;
  }
  let retainPeriod = STRESS_FALL_MULTIPLIER;
  if (prone) {
    retainPeriod *= 0.5;
  }
  const retain = Math.pow(clamp(retainPeriod, 0, 1), dt / Math.max(DECAY_REFERENCE_SEC, 0.001));
  return Math.max(STRESS_INITIAL, runtimeStress * retain);
}

function accuracyMultiplier(effectiveTier: number, rangeBand: number): number {
  const raw = rawWeight(effectiveTier, rangeBand);
  const ref = rawWeight(TIER_KEYS[TIER_KEYS.length - 1], rangeBand);
  if (ref <= 0.0001) {
    return 1;
  }
  return clamp(raw / ref, 0, 2);
}

function applyStressAimFactor(tableMultiplier: number, stressAimFactor: number): number {
  const degradation = 1 - clamp(tableMultiplier, 0, 1);
  return clamp(1 - degradation * Math.max(stressAimFactor, 0), 0.05, 1);
}

function rawWeight(effectiveTier: number, band: number): number {
  const b = Math.max(0, Math.min(6, band));
  if (effectiveTier <= TIER_KEYS[0]) {
    return TIER_ROWS[0][b];
  }
  if (effectiveTier >= TIER_KEYS[TIER_KEYS.length - 1]) {
    return TIER_ROWS[TIER_ROWS.length - 1][b];
  }
  for (let i = 0; i < TIER_KEYS.length - 1; i += 1) {
    const lo = TIER_KEYS[i];
    const hi = TIER_KEYS[i + 1];
    if (effectiveTier >= lo && effectiveTier <= hi) {
      const t = hi === lo ? 0 : (effectiveTier - lo) / (hi - lo);
      return TIER_ROWS[i][b] + (TIER_ROWS[i + 1][b] - TIER_ROWS[i][b]) * t;
    }
  }
  return 1;
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}
