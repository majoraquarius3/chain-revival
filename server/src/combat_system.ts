/** Authoritative aim, fire, hit/death, suppression, recovery, and stun scan. */

import type { GameState } from "./game_state";
import { towardCell } from "./facing";
import { beginFirePrep } from "./fire_prep";
import {
  combatRange,
  effectiveFireCycleSec,
  finalHitChance,
  LETHALITY_MULTIPLIER,
  weaponFor,
} from "./hit_resolution";
import { evaluate, LOS_BLOCKED } from "./los";
import { COVER_COMPLETE, COVER_MODERATE } from "./map_objects";
import {
  findBestAutoTarget,
  isAutoTargetValid,
  isPriorityTrackable,
  TARGET_LOST_GRACE_MSEC,
} from "./perception";
import type { SoldierState } from "./soldier_state";
import {
  decayStress,
  fireDelayModifier,
  MAX_STRESS,
  MODERATE_COVER_SUPPRESSION_MULT,
  PRONE_SUPPRESSION_MULT,
  stressBand,
  suppressionGain,
} from "./stress_accuracy";
import {
  FIRE_AT_WILL,
  POSITION_DOWN,
  type CombatShotPayload,
  type CombatStatusUpdate,
  type Vec2i,
} from "./types";
import { ammoCost, effectiveWeaponRange } from "./weapons";

export interface CombatTickResult {
  shots: CombatShotPayload[];
  statusUpdates: CombatStatusUpdate[];
}

export { beginFirePrep } from "./fire_prep";

export function isFirePrepComplete(state: GameState, shooter: SoldierState): boolean {
  if (shooter.fireReadyAfterMsec <= 0) {
    return false;
  }
  return state.clock.getTicksMsec() >= shooter.fireReadyAfterMsec;
}

export function canFireYet(state: GameState, shooter: SoldierState, rangeTiles: number): boolean {
  if (shooter.lastShotMsec <= 0) {
    return true;
  }
  const weapon = weaponFor(shooter);
  const interval = effectiveFireCycleSec(weapon, false, rangeTiles) * fireDelayModifier(shooter.stress);
  const elapsed = (state.clock.getTicksMsec() - shooter.lastShotMsec) / 1000;
  return elapsed >= interval;
}

export function isFacingTarget(shooter: SoldierState, target: SoldierState): boolean {
  const aim = towardCell(shooter.gridPosition, target.gridPosition);
  return aim.x === shooter.facing.x && aim.y === shooter.facing.y;
}

export function resolveShot(
  state: GameState,
  shooter: SoldierState,
  target: SoldierState,
  autoEngagement: boolean,
): CombatShotPayload {
  const shot = emptyShot(state, shooter, target);
  if (shooter.isDead || shooter.isMoving || shooter.isStunned(state.clock.getTicksMsec())) {
    return shot;
  }
  if (!isFirePrepComplete(state, shooter)) {
    shot.onCooldown = true;
    return shot;
  }
  if (target.isDead || shooter.teamId === target.teamId) {
    return shot;
  }
  const weapon = weaponFor(shooter);
  if (weapon === null) {
    return shot;
  }
  shot.weaponId = weapon.weaponId;
  shot.weaponName = weapon.weaponName;
  if (shooter.ammoCurrent <= 0) {
    shot.noAmmo = true;
    return shot;
  }
  const distance = combatRange(shooter.gridPosition, target.gridPosition);
  if (distance > effectiveWeaponRange(weapon)) {
    shot.outOfRange = true;
    return shot;
  }

  const facing = towardCell(shooter.gridPosition, target.gridPosition);
  if (facing.x !== 0 || facing.y !== 0) {
    shooter.facing = facing;
    shot.facing = { ...facing };
  }

  const los = evaluate(shooter.gridPosition, target.gridPosition, state.map, state.losOccupants());
  shot.coverType = los.coverType;
  shot.cornerPeek = los.cornerPeek;
  shot.peekSide = los.peekSide;
  shot.cornerCell = { ...los.cornerCell };
  if (los.status === LOS_BLOCKED) {
    shot.blocked = true;
    return shot;
  }
  if (!canFireYet(state, shooter, distance)) {
    shot.onCooldown = true;
    return shot;
  }

  const cost = ammoCost(weapon, shooter.ammoCurrent);
  shooter.ammoCurrent -= cost;
  const now = state.clock.getTicksMsec();
  shooter.lastShotMsec = now;
  shooter.lastFiredMsec = now;
  beginFirePrep(state, shooter, distance);
  shot.fired = true;
  state.nextShotId += 1;
  shot.shotId = state.nextShotId;
  shot.tracerCount = weapon.tracerCount;
  shot.ammoCurrent = shooter.ammoCurrent;
  shot.fireReadyAfterMsec = shooter.fireReadyAfterMsec;

  applySuppressionFromShot(shooter, target, weapon, los);

  if (los.targetUsingWallCover) {
    shot.hadCover = true;
    return shot;
  }

  const { chance, breakdown } = finalHitChance(shooter, target, weapon, los);
  shot.hitFinal = chance;
  shot.hitBreakdown = breakdown;
  if (los.coverType === COVER_MODERATE || los.coverType === COVER_COMPLETE) {
    shot.hadCover = true;
  }
  const perRoundKill = clamp(chance * LETHALITY_MULTIPLIER, 0, 1);
  const rounds = Math.max(cost, 0);
  shot.killChance = rounds > 0 ? 1 - (1 - perRoundKill) ** rounds : 0;
  let scored = false;
  for (let i = 0; i < rounds; i += 1) {
    if (state.rng.chance(perRoundKill)) {
      scored = true;
      break;
    }
  }
  if (scored) {
    shot.hit = true;
    applyKill(state, shooter, target, shot);
  }
  void autoEngagement;
  return shot;
}

export function tryEngagedFire(state: GameState, shooter: SoldierState): CombatShotPayload | null {
  if (shooter.isDead || shooter.isMoving || shooter.isStunned(state.clock.getTicksMsec())) {
    return null;
  }
  if (!shooter.sustainedFire) {
    return null;
  }
  const target = resolveEngagedTarget(state, shooter, true);
  if (target === null) {
    return null;
  }
  if (shooter.engagedTargetLostMsec > 0) {
    return null;
  }
  if (!isFacingTarget(shooter, target)) {
    shooter.facing = towardCell(shooter.gridPosition, target.gridPosition);
    return null;
  }
  const weapon = weaponFor(shooter);
  if (weapon === null || shooter.ammoCurrent <= 0) {
    return null;
  }
  if (!isFirePrepComplete(state, shooter)) {
    return null;
  }
  const range = combatRange(shooter.gridPosition, target.gridPosition);
  if (!canFireYet(state, shooter, range)) {
    return null;
  }
  return resolveShot(state, shooter, target, true);
}

export function tryAutoEngagement(state: GameState, shooter: SoldierState): CombatShotPayload | null {
  if (shooter.isDead || shooter.isMoving || shooter.isStunned(state.clock.getTicksMsec())) {
    return null;
  }
  if (shooter.sustainedFire) {
    return null;
  }
  if (shooter.fireControlState !== FIRE_AT_WILL) {
    return null;
  }
  if (shooter.ammoCurrent <= 0) {
    return null;
  }
  const target = resolveEngagedTarget(state, shooter, false);
  if (target === null) {
    return null;
  }
  if (shooter.engagedTargetLostMsec > 0) {
    return null;
  }
  if (!isFacingTarget(shooter, target)) {
    shooter.facing = towardCell(shooter.gridPosition, target.gridPosition);
    return null;
  }
  const weapon = weaponFor(shooter);
  if (weapon === null) {
    return null;
  }
  if (!isFirePrepComplete(state, shooter)) {
    return null;
  }
  const range = combatRange(shooter.gridPosition, target.gridPosition);
  if (!canFireYet(state, shooter, range)) {
    return null;
  }
  return resolveShot(state, shooter, target, true);
}

export function processCombatTick(state: GameState): CombatTickResult {
  const before = new Map(state.soldiers.map((soldier) => [statusKey(soldier), statusSnapshot(soldier, state.clock.getTicksMsec())]));
  for (const soldier of state.soldiers) {
    soldier.receivedSuppressionThisTick = false;
  }
  const shots: CombatShotPayload[] = [];
  for (const shooter of state.soldiers) {
    if (!shooter.sustainedFire) {
      continue;
    }
    const shot = tryEngagedFire(state, shooter);
    if (shot !== null && shot.fired) {
      shots.push(shot);
    }
  }
  for (const shooter of state.soldiers) {
    if (shooter.sustainedFire) {
      continue;
    }
    const shot = tryAutoEngagement(state, shooter);
    if (shot !== null && shot.fired) {
      shots.push(shot);
    }
  }
  for (const soldier of state.soldiers) {
    if (!soldier.isDead && soldier.stress > 0 && !soldier.receivedSuppressionThisTick) {
      soldier.stress = decayStress(soldier.stress, soldier.positionState === POSITION_DOWN, 0.5);
    }
    soldier.recoverFromStunIfExpired(state.clock.getTicksMsec());
  }
  const statusUpdates = state.soldiers
    .map((soldier) => statusSnapshot(soldier, state.clock.getTicksMsec()))
    .filter((status) => !statusEqual(before.get(`${status.teamId}:${status.soldierId}`), status));
  return { shots, statusUpdates };
}

export function applySuppressionFromShot(
  shooter: SoldierState,
  target: SoldierState,
  weapon: NonNullable<ReturnType<typeof weaponFor>>,
  los: ReturnType<typeof evaluate>,
): number {
  if (shooter.isDead || target.isDead || los.status === LOS_BLOCKED) {
    return 0;
  }
  const roundedRange = Math.round(combatRange(shooter.gridPosition, target.gridPosition));
  let gain = suppressionGain(weapon.suppressionGenerated, weapon.stressLimitTiles, roundedRange);
  if (los.coverType === COVER_MODERATE) {
    gain *= MODERATE_COVER_SUPPRESSION_MULT;
  }
  if (target.positionState === POSITION_DOWN) {
    gain *= PRONE_SUPPRESSION_MULT;
  }
  if (gain <= 0) {
    return 0;
  }
  const before = target.stress;
  target.stress = clamp(target.stress + gain, 0, MAX_STRESS);
  target.receivedSuppressionThisTick = true;
  return target.stress - before;
}

function resolveEngagedTarget(
  state: GameState,
  shooter: SoldierState,
  sustained: boolean,
): SoldierState | null {
  const now = state.clock.getTicksMsec();
  const current = shooter.isEngaged()
    ? state.getSoldier(shooter.engagedTargetTeamId, shooter.engagedTargetSoldierId)
    : null;
  if (sustained) {
    if (current !== null && !current.isDead && isPriorityTrackable(shooter, current, state)) {
      shooter.engagedTargetLostMsec = 0;
      return current;
    }
    if (current !== null && !targetLostGrace(shooter, now)) {
      return current;
    }
    shooter.clearEngagedTarget();
    return null;
  }
  if (current !== null && !current.isDead && isAutoTargetValid(shooter, current, state)) {
    shooter.engagedTargetLostMsec = 0;
    return current;
  }
  if (current !== null && !targetLostGrace(shooter, now)) {
    return current;
  }
  const next = findBestAutoTarget(state, shooter);
  if (next === null) {
    shooter.clearEngagedTarget();
    shooter.resetFirePrep();
    return null;
  }
  if (shooter.setEngagedTarget(next.teamId, next.soldierId)) {
    beginFirePrep(state, shooter, combatRange(shooter.gridPosition, next.gridPosition));
  }
  return next;
}

function targetLostGrace(shooter: SoldierState, now: number): boolean {
  if (shooter.engagedTargetLostMsec <= 0) {
    shooter.engagedTargetLostMsec = now;
    return false;
  }
  return now - shooter.engagedTargetLostMsec >= TARGET_LOST_GRACE_MSEC;
}

function applyKill(
  state: GameState,
  shooter: SoldierState,
  target: SoldierState,
  shot: CombatShotPayload,
): void {
  target.markKilled(state.rng);
  state.markPerceptionDirty();
  shot.killed = true;
  shot.deathSpriteFamily = target.deathSpriteFamily;
  shot.stanceAtDeath = target.stanceAtDeath;
  shot.movementHalt = target.gridPosition;
  for (const other of state.soldiers) {
    if (other.engagedTargetTeamId === target.teamId && other.engagedTargetSoldierId === target.soldierId) {
      other.clearEngagedTarget();
      other.resetFirePrep();
      other.endSustainedFire();
    }
  }
}

function statusKey(soldier: SoldierState): string {
  return `${soldier.teamId}:${soldier.soldierId}`;
}

function statusSnapshot(soldier: SoldierState, nowMsec: number): CombatStatusUpdate {
  return {
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    stress: soldier.stress,
    stressBand: stressBand(soldier.stress),
    receivedSuppression: soldier.receivedSuppressionThisTick,
    stunnedUntilMsec: soldier.stunnedUntilMsec,
    isStunned: soldier.isStunned(nowMsec),
    standOnStunRecovery: soldier.standOnStunRecovery,
    positionState: soldier.positionState,
    movementMode: soldier.movementMode,
    isMoving: soldier.isMoving,
    engagedTargetTeamId: soldier.engagedTargetTeamId,
    engagedTargetSoldierId: soldier.engagedTargetSoldierId,
    sustainedFire: soldier.sustainedFire,
  };
}

function statusEqual(a: CombatStatusUpdate | undefined, b: CombatStatusUpdate): boolean {
  return a !== undefined &&
    a.stress === b.stress &&
    a.stressBand === b.stressBand &&
    a.receivedSuppression === b.receivedSuppression &&
    a.stunnedUntilMsec === b.stunnedUntilMsec &&
    a.isStunned === b.isStunned &&
    a.standOnStunRecovery === b.standOnStunRecovery &&
    a.positionState === b.positionState &&
    a.movementMode === b.movementMode &&
    a.isMoving === b.isMoving &&
    a.engagedTargetTeamId === b.engagedTargetTeamId &&
    a.engagedTargetSoldierId === b.engagedTargetSoldierId &&
    a.sustainedFire === b.sustainedFire;
}

function emptyShot(state: GameState, shooter: SoldierState, target: SoldierState): CombatShotPayload {
  return {
    shotId: 0,
    shooterTeamId: shooter.teamId,
    shooterId: shooter.soldierId,
    targetTeamId: target.teamId,
    targetId: target.soldierId,
    fired: false,
    hit: false,
    killed: false,
    blocked: false,
    noAmmo: false,
    outOfRange: false,
    onCooldown: false,
    hadCover: false,
    coverType: 0,
    weaponId: shooter.weaponId,
    weaponName: "",
    tracerCount: 0,
    cornerPeek: false,
    peekSide: 0,
    cornerCell: { x: -999, y: -999 },
    hitFinal: 0,
    killChance: 0,
    ammoCurrent: shooter.ammoCurrent,
    fireReadyAfterMsec: shooter.fireReadyAfterMsec,
    facing: { ...shooter.facing },
    messages: [],
  };
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

export function faceToward(from: Vec2i, to: Vec2i): Vec2i {
  return towardCell(from, to);
}
