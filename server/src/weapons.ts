/** Weapon catalog — port of weapon_policy.gd / weapon_data.gd. */

export const WEAPON_RIFLE = 0;
export const WEAPON_SMG = 1;
export const WEAPON_LMG = 2;

export const ENGAGEMENT_RANGE_TILES = 40;
export const CONE_RANGE_BONUS_TILES = 8;

export interface WeaponData {
  weaponId: string;
  weaponName: string;
  weaponType: number;
  rangeTiles: number;
  roundsPerAttack: number;
  ammoCapacity: number;
  tracerCount: number;
  fireIntervalSec: number;
  aimFactorSqr: number;
  aimFactor: number;
  aimPlus: number;
  rangeConstCub: number;
  rangeConstSqr: number;
  rangeConstPent: number;
  suppressionGenerated: number;
  stressLimitTiles: number;
  stressAimFactor: number;
}

function rifle(id: string, name: string): WeaponData {
  return {
    weaponId: id,
    weaponName: name,
    weaponType: WEAPON_RIFLE,
    rangeTiles: ENGAGEMENT_RANGE_TILES,
    roundsPerAttack: 1,
    ammoCapacity: 70,
    tracerCount: 1,
    fireIntervalSec: 0,
    aimFactorSqr: 2000,
    aimFactor: 0,
    aimPlus: 0,
    rangeConstCub: 1,
    rangeConstSqr: 0,
    rangeConstPent: 0,
    suppressionGenerated: 0.25,
    stressLimitTiles: 25,
    stressAimFactor: 0.5,
  };
}

function smg(id: string, name: string, rounds: number): WeaponData {
  return {
    weaponId: id,
    weaponName: name,
    weaponType: WEAPON_SMG,
    rangeTiles: ENGAGEMENT_RANGE_TILES,
    roundsPerAttack: rounds,
    ammoCapacity: 200,
    tracerCount: rounds,
    fireIntervalSec: 0,
    aimFactorSqr: 2000,
    aimFactor: 0,
    aimPlus: 0,
    rangeConstCub: 0,
    rangeConstSqr: 0,
    rangeConstPent: 0.02,
    suppressionGenerated: 2.0,
    stressLimitTiles: 13,
    stressAimFactor: 1.5,
  };
}

function lmg(id: string, name: string, rounds: number, bulletUnused = 6): WeaponData {
  void bulletUnused;
  return {
    weaponId: id,
    weaponName: name,
    weaponType: WEAPON_LMG,
    rangeTiles: ENGAGEMENT_RANGE_TILES,
    roundsPerAttack: rounds,
    ammoCapacity: 900,
    tracerCount: rounds,
    fireIntervalSec: 0,
    aimFactorSqr: 8000,
    aimFactor: 0,
    aimPlus: 0,
    rangeConstCub: 1,
    rangeConstSqr: 0,
    rangeConstPent: 0,
    suppressionGenerated: 0.6,
    stressLimitTiles: 25,
    stressAimFactor: 2.0,
  };
}

const DEFS: Record<string, WeaponData> = {
  m1_garand: rifle("m1_garand", "M1 Garand"),
  kar98k: rifle("kar98k", "Kar98k"),
  thompson: smg("thompson", "Thompson", 4),
  mp40: smg("mp40", "MP40", 5),
  bar: lmg("bar", "BAR", 7),
  mg42: lmg("mg42", "MG42", 6, 7),
};

export function getWeapon(weaponId: string): WeaponData | null {
  return DEFS[weaponId] ?? null;
}

export function defaultRifleForTeam(teamId: number): string {
  return teamId === 2 ? "kar98k" : "m1_garand";
}

export function ammoCost(weapon: WeaponData, available: number): number {
  return Math.min(weapon.roundsPerAttack, Math.max(available, 0));
}

export function hitDenominator(weapon: WeaponData, d: number): number {
  const d2 = d * d;
  const d3 = d2 * d;
  const d5 = d3 * d2;
  return weapon.rangeConstCub * d3 + weapon.rangeConstSqr * d2 + weapon.rangeConstPent * d5;
}

export function hitNumerator(weapon: WeaponData, aimTime: number): number {
  return weapon.aimFactorSqr * aimTime * aimTime + weapon.aimFactor * aimTime + weapon.aimPlus;
}

export function effectiveWeaponRange(weapon: WeaponData | null): number {
  if (weapon === null) {
    return ENGAGEMENT_RANGE_TILES + CONE_RANGE_BONUS_TILES;
  }
  return Math.max(ENGAGEMENT_RANGE_TILES, weapon.rangeTiles) + CONE_RANGE_BONUS_TILES;
}
