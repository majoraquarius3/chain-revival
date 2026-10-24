import { stepCostMsec } from "./movement_policy";
import { GameRandom } from "./game_random";
import { defaultRifleForTeam, getWeapon } from "./weapons";
import {
  FIRE_AT_WILL,
  MOVEMENT_CRAWL,
  MOVEMENT_RUN,
  POSITION_DOWN,
  POSITION_UP,
  TEAM_GERMANY,
  type SoldierSnapshot,
  type Vec2i,
  vec,
} from "./types";

const USA_DEAD = ["ADDSS", "ADOAS", "ADFUS", "ADLYS"];
const GER_DEAD = ["GDLYS", "GDFUS"];

export class SoldierState {
  readonly soldierId: number;
  readonly teamId: number;
  gridPosition: Vec2i;
  facing: Vec2i;
  positionState = POSITION_UP;
  movementMode = MOVEMENT_RUN;
  isDead = false;
  isMoving = false;
  currentPath: Vec2i[] = [];
  pathIndex = 0;
  moveAccumMsec = 0;
  moveStepCostMsec = 0;
  moveSpeedMult = 1.0;
  stunnedUntilMsec = 0;
  pendingPositionState = -1;
  pendingStanceUntilMsec = 0;
  fireControlState = FIRE_AT_WILL;
  engagedTargetTeamId = -1;
  engagedTargetSoldierId = -1;
  sustainedFire = false;
  lastFiredMsec = 0;
  lastShotMsec = 0;
  fireReadyAfterMsec = 0;
  engagedTargetLostMsec = 0;
  weaponId = "";
  ammoCurrent = 0;
  ammoMax = 0;
  marksman = 0;
  stress = 0;
  receivedSuppressionThisTick = false;
  standOnStunRecovery = false;
  stanceAtDeath = POSITION_UP;
  deathSpriteFamily = "";
  private readonly lastSeen = new Map<string, { msec: number; cell: Vec2i }>();

  constructor(soldierId: number, teamId: number, gridPosition: Vec2i, facing: Vec2i) {
    this.soldierId = soldierId;
    this.teamId = teamId;
    this.gridPosition = { ...gridPosition };
    this.facing = { ...facing };
    this.assignWeapon(defaultRifleForTeam(teamId), true);
  }

  assignWeapon(weaponId: string, refill: boolean): void {
    const weapon = getWeapon(weaponId);
    if (weapon === null) {
      return;
    }
    this.weaponId = weapon.weaponId;
    this.ammoMax = weapon.ammoCapacity;
    if (refill || this.ammoCurrent <= 0) {
      this.ammoCurrent = this.ammoMax;
    }
  }

  isStunned(nowMsec: number): boolean {
    return nowMsec < this.stunnedUntilMsec;
  }

  applyStun(nowMsec: number, durationSec = 4): void {
    if (this.isDead) {
      return;
    }
    this.stunnedUntilMsec = nowMsec + Math.trunc(Math.max(durationSec, 0) * 1000);
    this.clearPath();
    this.endSustainedFire();
    this.resetFirePrep();
  }

  /** Shared authoritative hook for the later grenade phase. */
  applyGrenadeStun(nowMsec: number, durationSec = 6): void {
    if (this.isDead) {
      return;
    }
    this.stunnedUntilMsec = nowMsec + Math.trunc(Math.max(durationSec, 0) * 1000);
    this.positionState = POSITION_DOWN;
    this.movementMode = MOVEMENT_CRAWL;
    this.clearPendingPosition();
    this.standOnStunRecovery = true;
    this.clearPath();
    this.endSustainedFire();
    this.resetFirePrep();
  }

  recoverFromStunIfExpired(nowMsec: number): boolean {
    if (this.isDead || this.isStunned(nowMsec) || !this.standOnStunRecovery) {
      return false;
    }
    this.standOnStunRecovery = false;
    if (this.positionState !== POSITION_DOWN) {
      return false;
    }
    this.clearPendingPosition();
    this.positionState = POSITION_UP;
    return true;
  }

  clearPendingPosition(): void {
    this.pendingPositionState = -1;
    this.pendingStanceUntilMsec = 0;
  }

  expirePendingStance(nowMsec: number): void {
    if (this.pendingPositionState >= 0 && nowMsec >= this.pendingStanceUntilMsec) {
      this.clearPendingPosition();
    }
  }

  beginPendingStance(target: number, nowMsec: number, gateMsec: number): void {
    this.pendingPositionState = target;
    this.pendingStanceUntilMsec = nowMsec + gateMsec;
  }

  clearPath(): void {
    this.currentPath = [];
    this.isMoving = false;
    this.pathIndex = 0;
    this.moveAccumMsec = 0;
    this.moveStepCostMsec = 0;
    this.moveSpeedMult = 1.0;
  }

  isEngaged(): boolean {
    return this.engagedTargetTeamId >= 0 && this.engagedTargetSoldierId > 0;
  }

  setEngagedTarget(targetTeamId: number, targetSoldierId: number): boolean {
    const unchanged =
      this.engagedTargetTeamId === targetTeamId && this.engagedTargetSoldierId === targetSoldierId;
    this.engagedTargetTeamId = targetTeamId;
    this.engagedTargetSoldierId = targetSoldierId;
    this.engagedTargetLostMsec = 0;
    if (unchanged) {
      return false;
    }
    this.fireReadyAfterMsec = 0;
    this.lastShotMsec = 0;
    return true;
  }

  clearEngagedTarget(): void {
    this.engagedTargetTeamId = -1;
    this.engagedTargetSoldierId = -1;
    this.engagedTargetLostMsec = 0;
  }

  resetFirePrep(): void {
    this.fireReadyAfterMsec = 0;
  }

  recordLastSeen(teamId: number, soldierId: number, msec: number, cell: Vec2i): void {
    this.lastSeen.set(`${teamId}:${soldierId}`, { msec, cell: { ...cell } });
  }

  getLastSeen(teamId: number, soldierId: number): { msec: number; cell: Vec2i } | null {
    return this.lastSeen.get(`${teamId}:${soldierId}`) ?? null;
  }

  beginSustainedFire(): void {
    this.sustainedFire = true;
  }

  endSustainedFire(): void {
    this.sustainedFire = false;
    this.clearEngagedTarget();
    this.resetFirePrep();
  }

  clearEngagement(): void {
    this.clearEngagedTarget();
    this.resetFirePrep();
  }

  movementHeading(): Vec2i {
    if (this.isMoving && this.pathIndex >= 0 && this.pathIndex < this.currentPath.length) {
      const next = this.currentPath[this.pathIndex];
      const step = vec(next.x - this.gridPosition.x, next.y - this.gridPosition.y);
      if (step.x !== 0 || step.y !== 0) {
        return vec(Math.sign(step.x), Math.sign(step.y));
      }
    }
    return { ...this.facing };
  }

  markKilled(rng: GameRandom): void {
    this.stanceAtDeath = this.positionState;
    this.isDead = true;
    this.positionState = POSITION_DOWN;
    this.clearPendingPosition();
    this.stunnedUntilMsec = 0;
    this.standOnStunRecovery = false;
    this.receivedSuppressionThisTick = false;
    this.clearPath();
    this.endSustainedFire();
    this.resetFirePrep();
    if (this.deathSpriteFamily.length === 0) {
      const pool = this.teamId === TEAM_GERMANY ? GER_DEAD : USA_DEAD;
      this.deathSpriteFamily = pool[rng.randiRange(0, pool.length - 1)] ?? pool[0];
    }
  }

  assignPath(path: Vec2i[], speedMult: number): void {
    if (this.isDead) {
      return;
    }
    this.currentPath = path.map((cell) => ({ ...cell }));
    this.moveSpeedMult = speedMult;
    this.moveAccumMsec = 0;
    this.pathIndex = 1;
    this.isMoving = this.currentPath.length > 1;
    if (this.isMoving) {
      this.moveStepCostMsec = stepCostMsec(this.currentPath[0], this.currentPath[1], this.moveSpeedMult);
      this.clearEngagement();
      this.endSustainedFire();
    } else {
      this.moveStepCostMsec = 0;
      this.pathIndex = 0;
    }
  }

  toSnapshot(): SoldierSnapshot {
    return {
      soldierId: this.soldierId,
      teamId: this.teamId,
      gridPosition: { ...this.gridPosition },
      facing: { ...this.facing },
      positionState: this.positionState,
      movementMode: this.movementMode,
      isDead: this.isDead,
      isMoving: this.isMoving,
      currentPath: this.currentPath.map((cell) => ({ ...cell })),
      pathIndex: this.pathIndex,
      moveSpeedMult: this.moveSpeedMult,
      fireControlState: this.fireControlState,
      engagedTargetTeamId: this.engagedTargetTeamId,
      engagedTargetSoldierId: this.engagedTargetSoldierId,
      sustainedFire: this.sustainedFire,
      weaponId: this.weaponId,
      ammoCurrent: this.ammoCurrent,
      fireReadyAfterMsec: this.fireReadyAfterMsec,
      lastShotMsec: this.lastShotMsec,
      stress: this.stress,
      stunnedUntilMsec: this.stunnedUntilMsec,
      standOnStunRecovery: this.standOnStunRecovery,
      deathSpriteFamily: this.deathSpriteFamily,
      stanceAtDeath: this.stanceAtDeath,
    };
  }
}

export function defaultFacingForTeam(teamId: number): Vec2i {
  return teamId === 2 ? vec(1, 1) : vec(-1, -1);
}
