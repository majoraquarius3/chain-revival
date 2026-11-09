/** Shared grid / soldier types for the authoritative local match. */

export const TEAM_USA = 1;
export const TEAM_GERMANY = 2;

export const MOVE_SCOPE_SINGLE = 0;
export const MOVE_SCOPE_SQUAD = 1;

export const MOVEMENT_RUN = 0;
export const MOVEMENT_WALK = 1;
export const MOVEMENT_CRAWL = 2;

export const POSITION_UP = 0;
export const POSITION_DOWN = 1;

export const FIRE_HOLD = 0;
export const FIRE_AT_WILL = 1;

export const MATCH_ID = "local-mp-1";
export const DEFAULT_MAP_ID = "ff_farm";

export interface Vec2i {
  x: number;
  y: number;
}

export function vec(x: number, y: number): Vec2i {
  return { x, y };
}

export function vecEq(a: Vec2i, b: Vec2i): boolean {
  return a.x === b.x && a.y === b.y;
}

export function vecKey(cell: Vec2i): string {
  return `${cell.x},${cell.y}`;
}

export function chebyshev(a: Vec2i, b: Vec2i): number {
  return Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y));
}

export function sideToTeamId(side: "USA" | "GERMANY"): number {
  return side === "GERMANY" ? TEAM_GERMANY : TEAM_USA;
}

export function teamIdToSide(teamId: number): "USA" | "GERMANY" {
  return teamId === TEAM_GERMANY ? "GERMANY" : "USA";
}

export interface SoldierSnapshot {
  soldierId: number;
  teamId: number;
  gridPosition: Vec2i;
  facing: Vec2i;
  positionState: number;
  movementMode: number;
  isDead: boolean;
  isMoving: boolean;
  currentPath: Vec2i[];
  pathIndex: number;
  moveSpeedMult: number;
  fireControlState: number;
  engagedTargetTeamId: number;
  engagedTargetSoldierId: number;
  sustainedFire: boolean;
  weaponId: string;
  ammoCurrent: number;
  fireReadyAfterMsec: number;
  lastShotMsec: number;
  stress: number;
  stunnedUntilMsec: number;
  standOnStunRecovery: boolean;
  deathSpriteFamily: string;
  stanceAtDeath: number;
}

export interface TargetUpdatePayload {
  teamId: number;
  soldierId: number;
  fireControlState: number;
  engagedTargetTeamId: number;
  engagedTargetSoldierId: number;
  sustainedFire: boolean;
}

export interface VisibleSoldierRef {
  teamId: number;
  soldierId: number;
}

export interface VisibilitySidePayload {
  teamId: number;
  visible: VisibleSoldierRef[];
}

export interface VisibilityUpdatePayload {
  type: "visibility_update";
  matchId: string;
  simMsec: number;
  tickId: number;
  sides: VisibilitySidePayload[];
}

export interface TargetSyncPayload {
  type: "target_sync";
  matchId: string;
  simMsec: number;
  tickId: number;
  targetUpdates: TargetUpdatePayload[];
}

export interface MatchSnapshot {
  type: "match_snapshot";
  matchId: string;
  mapId: string;
  simMsec: number;
  tickId: number;
  simRunning: boolean;
  matchPhase: string;
  soldiers: SoldierSnapshot[];
  visibility: VisibilitySidePayload[];
}

export interface MoveOrderPayload {
  teamId: number;
  soldierId: number;
  path: Vec2i[];
  speedMult: number;
  movementMode: number;
  positionState: number;
}

export interface SoldierUpdatePayload {
  teamId: number;
  soldierId: number;
  facing: Vec2i;
  positionState: number;
  movementMode: number;
}

export interface StanceTransitionOrder {
  teamId: number;
  soldierId: number;
  targetPositionState: number;
}

export interface MoveResultPayload {
  type: "move_result";
  matchId: string;
  requestId: string;
  success: boolean;
  statusMessage: string;
  moveOrders: MoveOrderPayload[];
  movementHalts: Array<{ teamId: number; soldierId: number; snapCell: Vec2i }>;
  stanceTransitionOrders: StanceTransitionOrder[];
  soldierUpdates: SoldierUpdatePayload[];
}

export interface FaceCommandIntent {
  type: "face_command";
  matchId: string;
  requestId: string;
  teamId: number;
  soldierId: number;
  targetCell: Vec2i;
  scope: number;
  aimWorld: Vec2i | null;
}

export interface FaceResultPayload {
  type: "face_result";
  matchId: string;
  requestId: string;
  success: boolean;
  statusMessage: string;
  faceUpdates: Array<{ teamId: number; soldierId: number; facing: Vec2i }>;
}

export interface PositionCommandIntent {
  type: "position_command";
  matchId: string;
  requestId: string;
  teamId: number;
  soldierId: number;
  positionState: number;
}

export interface PositionResultPayload {
  type: "position_result";
  matchId: string;
  requestId: string;
  success: boolean;
  statusMessage: string;
  positionState: number;
  movementHalts: Array<{ teamId: number; soldierId: number; snapCell: Vec2i }>;
  stanceTransitionOrders: StanceTransitionOrder[];
  soldierUpdates: SoldierUpdatePayload[];
}

export interface MovementTickPayload {
  type: "movement_tick";
  matchId: string;
  simMsec: number;
  tickId: number;
  movementSteps: Array<{
    teamId: number;
    soldierId: number;
    tile: Vec2i;
    stepDelta: Vec2i;
  }>;
  movementCompletions: Array<{ teamId: number; soldierId: number }>;
}

export interface MoveCommandIntent {
  type: "move_command";
  matchId: string;
  requestId: string;
  teamId: number;
  soldierId: number;
  targetCell: Vec2i;
  scope: number;
  movementMode: number;
}

export interface FireControlCommandIntent {
  type: "fire_control_command";
  matchId: string;
  requestId: string;
  teamId: number;
  soldierId: number;
  fireControlState: number;
}

export interface FireControlResultPayload {
  type: "fire_control_result";
  matchId: string;
  requestId: string;
  success: boolean;
  statusMessage: string;
  syncFireAtUi: boolean;
  targetUpdates: TargetUpdatePayload[];
}

export interface FireAtCommandIntent {
  type: "fire_at_command";
  matchId: string;
  requestId: string;
  teamId: number;
  soldierId: number;
  targetTeamId: number;
  targetSoldierId: number;
  scope: number;
  targetCell?: Vec2i;
  aimWorld?: Vec2i | null;
}

export interface CombatShotPayload {
  shotId: number;
  shooterTeamId: number;
  shooterId: number;
  targetTeamId: number;
  targetId: number;
  fired: boolean;
  hit: boolean;
  killed: boolean;
  blocked: boolean;
  noAmmo: boolean;
  outOfRange: boolean;
  onCooldown: boolean;
  hadCover: boolean;
  coverType: number;
  weaponId: string;
  weaponName: string;
  tracerCount: number;
  cornerPeek: boolean;
  peekSide: number;
  cornerCell: Vec2i;
  hitFinal: number;
  killChance: number;
  ammoCurrent: number;
  fireReadyAfterMsec: number;
  facing: Vec2i;
  deathSpriteFamily?: string;
  stanceAtDeath?: number;
  movementHalt?: Vec2i;
  hitBreakdown?: Record<string, number> | object;
  messages: string[];
}

export interface CombatShotsPayload {
  type: "combat_shots";
  matchId: string;
  simMsec: number;
  tickId: number;
  shots: CombatShotPayload[];
}

export interface CombatStatusUpdate {
  teamId: number;
  soldierId: number;
  stress: number;
  stressBand: number;
  receivedSuppression: boolean;
  stunnedUntilMsec: number;
  isStunned: boolean;
  standOnStunRecovery: boolean;
  positionState: number;
  movementMode: number;
  isMoving: boolean;
  engagedTargetTeamId: number;
  engagedTargetSoldierId: number;
  sustainedFire: boolean;
}

export interface CombatStatusPayload {
  type: "combat_status";
  matchId: string;
  simMsec: number;
  tickId: number;
  updates: CombatStatusUpdate[];
}

export interface FireAtResultPayload {
  type: "fire_at_result";
  matchId: string;
  requestId: string;
  success: boolean;
  statusMessage: string;
  syncFireAtUi: boolean;
  movementHalts: Array<{ teamId: number; soldierId: number; snapCell: Vec2i }>;
  faceUpdates: Array<{ teamId: number; soldierId: number; facing: Vec2i }>;
  targetUpdates: TargetUpdatePayload[];
}
