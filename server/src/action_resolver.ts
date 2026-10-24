/**
 * Authoritative movement resolution — port of ActionResolver.execute_move /
 * process_movement_tick (movement slice only).
 */

import { facingName, teamDisplayName, towardCell, towardWorldPoint } from "./facing";
import type { GameState } from "./game_state";
import { evaluate, LOS_BLOCKED } from "./los";
import { speedMultiplier, stepCostMsec } from "./movement_policy";
import { beginFirePrep } from "./fire_prep";
import { combatRange } from "./hit_resolution";
import { canAssignManualPriority, canSpot } from "./perception";
import { findPath } from "./pathfinder";
import type { SoldierState } from "./soldier_state";
import { isPanicked, movementModifier } from "./stress_accuracy";
import {
  FIRE_AT_WILL,
  FIRE_HOLD,
  MOVEMENT_CRAWL,
  MOVE_SCOPE_SQUAD,
  POSITION_DOWN,
  POSITION_UP,
  type FaceCommandIntent,
  type FaceResultPayload,
  type FireAtCommandIntent,
  type FireAtResultPayload,
  type FireControlCommandIntent,
  type FireControlResultPayload,
  type MoveCommandIntent,
  type MoveOrderPayload,
  type MoveResultPayload,
  type MovementTickPayload,
  type PositionCommandIntent,
  type PositionResultPayload,
  type SoldierUpdatePayload,
  type StanceTransitionOrder,
  type TargetUpdatePayload,
  type Vec2i,
  chebyshev,
  vec,
  vecEq,
} from "./types";

/** Matches typical stand/drop anim length; server does not wait for clients. */
const STANCE_PENDING_GATE_MSEC = 450;

export interface ActionResult {
  success: boolean;
  statusMessage: string;
  moveOrders: MoveOrderPayload[];
  movementHalts: Array<{ teamId: number; soldierId: number; snapCell: Vec2i }>;
  movementSteps: MovementTickPayload["movementSteps"];
  movementCompletions: MovementTickPayload["movementCompletions"];
  faceUpdates: Array<{ teamId: number; soldierId: number; facing: Vec2i }>;
  stanceTransitionOrders: StanceTransitionOrder[];
  soldierUpdates: SoldierUpdatePayload[];
  targetUpdates: TargetUpdatePayload[];
  syncFireAtUi: boolean;
}

export function emptyAction(success = true, statusMessage = ""): ActionResult {
  return {
    success,
    statusMessage,
    moveOrders: [],
    movementHalts: [],
    movementSteps: [],
    movementCompletions: [],
    faceUpdates: [],
    stanceTransitionOrders: [],
    soldierUpdates: [],
    targetUpdates: [],
    syncFireAtUi: false,
  };
}

export function fail(message: string): ActionResult {
  return emptyAction(false, message);
}

export function executeMove(
  gameState: GameState,
  cmd: MoveCommandIntent,
  actingTeamId: number,
): ActionResult {
  if (cmd.teamId !== actingTeamId) {
    return fail("That soldier is not under your control.");
  }

  const target = gameState.map.clampToBounds(cmd.targetCell);
  if (!gameState.map.isWalkable(target)) {
    if (gameState.map.isBlocked(target)) {
      return fail("That tile is blocked.");
    }
    return fail("No path to that tile.");
  }

  if (cmd.scope === MOVE_SCOPE_SQUAD) {
    return executeSquadMove(gameState, cmd, target);
  }

  const soldier = gameState.getSoldier(cmd.teamId, cmd.soldierId);
  if (soldier === null) {
    return fail("Soldier unavailable.");
  }
  const resolved = resolveMoveOrder(soldier, cmd.movementMode, gameState.clock.getTicksMsec());
  if (resolved.rejected) {
    return fail(resolved.message);
  }

  const result = emptyAction();
  standUpForLocomotion(soldier, resolved.mode, result);
  if (!assignMovePath(gameState, soldier, target, resolved.mode, result)) {
    if (vecEq(target, soldier.gridPosition)) {
      return fail("Soldier is already at that tile.");
    }
    return fail("No path to that tile.");
  }
  const modeLabel = movementLabel(resolved.mode);
  result.statusMessage = `Soldier ${cmd.soldierId} ${modeLabel} to (${target.x}, ${target.y})`;
  gameState.markPerceptionDirty();
  return result;
}

function executeSquadMove(
  gameState: GameState,
  cmd: MoveCommandIntent,
  squadTarget: Vec2i,
): ActionResult {
  const now = gameState.clock.getTicksMsec();
  const orderable: SoldierState[] = [];
  const notices: string[] = [];
  for (const soldier of gameState.soldiersOnTeam(cmd.teamId)) {
    const preview = resolveMoveOrder(soldier, cmd.movementMode, now);
    if (preview.rejected) {
      if (preview.message) {
        notices.push(preview.message);
      }
      continue;
    }
    orderable.push(soldier);
  }
  if (orderable.length === 0) {
    return fail(notices[0] ?? "No soldiers could move to that tile.");
  }

  const formationRefs = new Map<number, Vec2i>();
  for (const soldier of orderable) {
    formationRefs.set(soldier.soldierId, formationReferenceCell(soldier));
  }
  const anchor = orderable[0];
  const anchorPos = formationRefs.get(anchor.soldierId) as Vec2i;
  const result = emptyAction();
  let leadPath: Vec2i[] = [];
  let leadStart = vec(-999, -999);
  let ordered = 0;

  for (const soldier of orderable) {
    const resolved = resolveMoveOrder(soldier, cmd.movementMode, now);
    standUpForLocomotion(soldier, resolved.mode, result);
    const memberRef = formationRefs.get(soldier.soldierId) as Vec2i;
    const offset = vec(memberRef.x - anchorPos.x, memberRef.y - anchorPos.y);
    const memberTarget = squadRelativeCell(gameState, squadTarget, offset);
    let assigned = false;
    if (leadPath.length > 0 && leadStart.x > -900) {
      assigned = assignTranslatedSquadPath(
        gameState,
        soldier,
        resolved.mode,
        leadPath,
        leadStart,
        memberTarget,
        result,
      );
    }
    if (!assigned) {
      assigned = assignMovePath(gameState, soldier, memberTarget, resolved.mode, result);
      if (assigned && leadPath.length === 0 && result.moveOrders.length > 0) {
        const last = result.moveOrders[result.moveOrders.length - 1];
        if (last.soldierId === soldier.soldierId) {
          leadPath = last.path.map((c) => ({ ...c }));
          if (leadPath.length > 0) {
            leadStart = leadPath[0];
          }
        }
      }
    }
    if (assigned) {
      ordered += 1;
    }
  }
  if (ordered === 0) {
    return fail(notices[0] ?? "No soldiers could move to that tile.");
  }
  result.statusMessage = `Fireteam moving to (${squadTarget.x}, ${squadTarget.y})`;
  gameState.markPerceptionDirty();
  return result;
}

function resolveMoveOrder(
  soldier: SoldierState,
  requestedMode: number,
  nowMsec: number,
): { mode: number; message: string; rejected: boolean } {
  if (soldier.isDead) {
    return { mode: requestedMode, message: "Soldier unavailable.", rejected: true };
  }
  if (soldier.isStunned(nowMsec)) {
    return {
      mode: requestedMode,
      message: "Soldier is stunned and cannot move.",
      rejected: true,
    };
  }
  return { mode: requestedMode, message: "", rejected: false };
}

function standUpForLocomotion(soldier: SoldierState, mode: number, result: ActionResult): void {
  soldier.clearPendingPosition();
  if (mode === MOVEMENT_CRAWL) {
    if (soldier.positionState !== POSITION_DOWN) {
      soldier.positionState = POSITION_DOWN;
    }
    pushSoldierUpdate(result, soldier);
    return;
  }
  if (soldier.positionState !== POSITION_DOWN) {
    pushSoldierUpdate(result, soldier);
    return;
  }
  soldier.positionState = POSITION_UP;
  pushSoldierUpdate(result, soldier);
}

function formationReferenceCell(soldier: SoldierState): Vec2i {
  if (soldier.isMoving && soldier.currentPath.length > 0) {
    return { ...soldier.currentPath[soldier.currentPath.length - 1] };
  }
  return { ...soldier.gridPosition };
}

function squadRelativeCell(gameState: GameState, base: Vec2i, offset: Vec2i): Vec2i {
  const cell = vec(base.x + offset.x, base.y + offset.y);
  if (gameState.map.isWalkable(cell)) {
    return cell;
  }
  const fallback = nearestWalkable(gameState, cell, 3);
  if (fallback !== null) {
    return fallback;
  }
  if (gameState.map.isWalkable(base)) {
    return base;
  }
  return cell;
}

function nearestWalkable(gameState: GameState, origin: Vec2i, radius: number): Vec2i | null {
  if (gameState.map.isWalkable(origin)) {
    return origin;
  }
  let best: Vec2i | null = null;
  let bestD = 999999;
  for (let dy = -radius; dy <= radius; dy += 1) {
    for (let dx = -radius; dx <= radius; dx += 1) {
      const cell = vec(origin.x + dx, origin.y + dy);
      if (!gameState.map.isWalkable(cell)) {
        continue;
      }
      const d = Math.abs(dx) + Math.abs(dy);
      if (d < bestD) {
        bestD = d;
        best = cell;
      }
    }
  }
  return best;
}

function assignMovePath(
  gameState: GameState,
  soldier: SoldierState,
  target: Vec2i,
  mode: number,
  result: ActionResult,
): boolean {
  if (soldier.isDead) {
    return false;
  }
  const start = soldier.gridPosition;
  if (vecEq(target, start) || !gameState.map.isWalkable(target)) {
    return false;
  }
  const path = findPath(gameState.map, start, target);
  if (path.length < 2) {
    return false;
  }
  for (let i = 1; i < path.length; i += 1) {
    if (gameState.map.isBlocked(path[i])) {
      return false;
    }
  }
  if (soldier.isMoving) {
    result.movementHalts.push({
      teamId: soldier.teamId,
      soldierId: soldier.soldierId,
      snapCell: { ...soldier.gridPosition },
    });
    soldier.clearPath();
  }
  soldier.movementMode = mode;
  const speedMult = speedMultiplier(mode) * movementModifier(soldier.stress);
  soldier.assignPath(path, speedMult);
  pushMoveOrder(result, soldier, path, speedMult);
  return true;
}

function assignTranslatedSquadPath(
  gameState: GameState,
  soldier: SoldierState,
  mode: number,
  leadPath: Vec2i[],
  leadStart: Vec2i,
  memberTarget: Vec2i,
  result: ActionResult,
): boolean {
  if (soldier.isDead || leadPath.length === 0) {
    return false;
  }
  const start = soldier.gridPosition;
  const path: Vec2i[] = [];
  if (vecEq(start, leadStart)) {
    for (const cell of leadPath) {
      path.push({ ...cell });
    }
  } else {
    const dx = start.x - leadStart.x;
    const dy = start.y - leadStart.y;
    for (const cell of leadPath) {
      const step = vec(cell.x + dx, cell.y + dy);
      if (!vecEq(step, start) && !gameState.map.isWalkable(step)) {
        return false;
      }
      path.push(step);
    }
  }
  if (path.length === 0 || !vecEq(path[0], start)) {
    return false;
  }
  if (vecEq(path[path.length - 1], start)) {
    return false;
  }
  const end = path[path.length - 1];
  if (!vecEq(end, memberTarget) && gameState.map.isWalkable(memberTarget)) {
    const prev = path.length >= 2 ? path[path.length - 2] : start;
    if (chebyshev(prev, memberTarget) <= 1) {
      path[path.length - 1] = { ...memberTarget };
    }
  }
  if (!vecEq(path[path.length - 1], memberTarget)) {
    return false;
  }
  if (soldier.isMoving) {
    result.movementHalts.push({
      teamId: soldier.teamId,
      soldierId: soldier.soldierId,
      snapCell: { ...soldier.gridPosition },
    });
    soldier.clearPath();
  }
  soldier.movementMode = mode;
  const speedMult = speedMultiplier(mode) * movementModifier(soldier.stress);
  soldier.assignPath(path, speedMult);
  pushMoveOrder(result, soldier, path, speedMult);
  return true;
}

export function processMovementTick(gameState: GameState): ActionResult {
  const result = emptyAction();
  const tickMsec = gameState.clock.tickMsec();
  for (const soldier of gameState.soldiers) {
    if (soldier.isDead || !soldier.isMoving) {
      continue;
    }
    advanceSoldier(gameState, soldier, tickMsec, result);
  }
  return result;
}

function advanceSoldier(
  gameState: GameState,
  soldier: SoldierState,
  tickMsec: number,
  result: ActionResult,
): void {
  if (soldier.currentPath.length < 2 || soldier.pathIndex <= 0) {
    completeMove(soldier, result);
    return;
  }
  soldier.moveAccumMsec += tickMsec;
  while (soldier.isMoving && soldier.moveAccumMsec >= soldier.moveStepCostMsec) {
    soldier.moveAccumMsec -= soldier.moveStepCostMsec;
    const from = soldier.currentPath[soldier.pathIndex - 1];
    const to = soldier.currentPath[soldier.pathIndex];
    if (gameState.map.isBlocked(to)) {
      completeMove(soldier, result);
      return;
    }
    if (chebyshev(from, to) > 1) {
      completeMove(soldier, result);
      return;
    }
    const stepDelta = vec(to.x - from.x, to.y - from.y);
    soldier.gridPosition = { ...to };
    if (stepDelta.x !== 0 || stepDelta.y !== 0) {
      soldier.facing = {
        x: Math.max(-1, Math.min(1, stepDelta.x)),
        y: Math.max(-1, Math.min(1, stepDelta.y)),
      };
    }
    result.movementSteps.push({
      teamId: soldier.teamId,
      soldierId: soldier.soldierId,
      tile: { ...to },
      stepDelta,
    });
    gameState.markPerceptionDirty();
    soldier.pathIndex += 1;
    if (soldier.pathIndex >= soldier.currentPath.length) {
      completeMove(soldier, result);
      return;
    }
    soldier.moveStepCostMsec = stepCostMsec(
      soldier.currentPath[soldier.pathIndex - 1],
      soldier.currentPath[soldier.pathIndex],
      soldier.moveSpeedMult,
    );
  }
}

function completeMove(soldier: SoldierState, result: ActionResult): void {
  soldier.clearPath();
  result.movementCompletions.push({
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
  });
}

function movementLabel(mode: number): string {
  if (mode === 1) {
    return "walk";
  }
  if (mode === 2) {
    return "crawl";
  }
  return "run";
}

function pushMoveOrder(
  result: ActionResult,
  soldier: SoldierState,
  path: Vec2i[],
  speedMult: number,
): void {
  result.moveOrders.push({
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    path: path.map((c) => ({ ...c })),
    speedMult,
    movementMode: soldier.movementMode,
    positionState: soldier.positionState,
  });
  pushSoldierUpdate(result, soldier);
}

function pushSoldierUpdate(result: ActionResult, soldier: SoldierState): void {
  const existing = result.soldierUpdates.findIndex(
    (u) => u.teamId === soldier.teamId && u.soldierId === soldier.soldierId,
  );
  const update: SoldierUpdatePayload = {
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    facing: { ...soldier.facing },
    positionState: soldier.positionState,
    movementMode: soldier.movementMode,
  };
  if (existing >= 0) {
    result.soldierUpdates[existing] = update;
  } else {
    result.soldierUpdates.push(update);
  }
}

function haltSoldierIfMoving(soldier: SoldierState, result: ActionResult): boolean {
  if (!soldier.isMoving) {
    return false;
  }
  result.movementHalts.push({
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    snapCell: { ...soldier.gridPosition },
  });
  soldier.clearPath();
  return true;
}

export function executeFace(
  gameState: GameState,
  cmd: FaceCommandIntent,
  actingTeamId: number,
): ActionResult {
  if (cmd.teamId !== actingTeamId) {
    return fail("That soldier is not under your control.");
  }
  const now = gameState.clock.getTicksMsec();
  if (cmd.scope === MOVE_SCOPE_SQUAD) {
    return executeFaceSquad(gameState, cmd, actingTeamId, now);
  }
  const soldier = gameState.getSoldier(actingTeamId, cmd.soldierId);
  if (soldier === null || soldier.isDead) {
    return fail("Soldier unavailable.");
  }
  if (soldier.isStunned(now)) {
    return fail("Soldier is stunned.");
  }
  const facing = towardWorldPoint(soldier.gridPosition, cmd.targetCell, cmd.aimWorld);
  if (facing.x === 0 && facing.y === 0) {
    return fail("Could not determine facing from that click.");
  }
  soldier.facing = { ...facing };
  const result = emptyAction(true, faceStatus(actingTeamId, soldier));
  result.faceUpdates.push({
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    facing: { ...soldier.facing },
  });
  gameState.markPerceptionDirty();
  return result;
}

function executeFaceSquad(
  gameState: GameState,
  cmd: FaceCommandIntent,
  actingTeamId: number,
  now: number,
): ActionResult {
  const result = emptyAction();
  let faced = 0;
  for (const soldier of gameState.soldiersOnTeam(actingTeamId)) {
    if (soldier.isDead || soldier.isStunned(now)) {
      continue;
    }
    const facing = towardWorldPoint(soldier.gridPosition, cmd.targetCell, cmd.aimWorld);
    if (facing.x === 0 && facing.y === 0) {
      continue;
    }
    soldier.facing = { ...facing };
    result.faceUpdates.push({
      teamId: soldier.teamId,
      soldierId: soldier.soldierId,
      facing: { ...soldier.facing },
    });
    faced += 1;
  }
  if (faced <= 0) {
    return fail("No soldiers could face that direction.");
  }
  result.statusMessage = `${teamDisplayName(actingTeamId)} Fireteam facing — ${faced} soldier(s) reoriented.`;
  gameState.markPerceptionDirty();
  return result;
}

export function executePosition(
  gameState: GameState,
  cmd: PositionCommandIntent,
  actingTeamId: number,
): ActionResult {
  if (cmd.teamId !== actingTeamId) {
    return fail("That soldier is not under your control.");
  }
  if (cmd.positionState !== POSITION_UP && cmd.positionState !== POSITION_DOWN) {
    return fail("Invalid stance.");
  }
  const now = gameState.clock.getTicksMsec();
  const soldier = gameState.getSoldier(actingTeamId, cmd.soldierId);
  if (soldier === null || soldier.isDead) {
    return fail("Soldier unavailable.");
  }
  if (soldier.isStunned(now)) {
    return fail("Soldier is stunned.");
  }
  soldier.expirePendingStance(now);
  if (soldier.pendingPositionState >= 0) {
    return fail("Soldier is already changing stance.");
  }
  const label = cmd.positionState === POSITION_DOWN ? "DOWN" : "UP";
  if (soldier.positionState === cmd.positionState) {
    return emptyAction(true, `Soldier ${soldier.soldierId} already ${label}`);
  }

  const result = emptyAction();
  if (haltSoldierIfMoving(soldier, result)) {
    /* halt while stance applies immediately */
  }
  soldier.positionState = cmd.positionState;
  soldier.beginPendingStance(cmd.positionState, now, STANCE_PENDING_GATE_MSEC);
  result.stanceTransitionOrders.push({
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    targetPositionState: cmd.positionState,
  });
  pushSoldierUpdate(result, soldier);
  result.statusMessage = `Soldier ${soldier.soldierId} changed to ${label}`;
  gameState.markPerceptionDirty();
  return result;
}

export function executeFireControl(
  gameState: GameState,
  cmd: FireControlCommandIntent,
  actingTeamId: number,
): ActionResult {
  if (cmd.teamId !== actingTeamId) {
    return fail("That soldier is not under your control.");
  }
  if (cmd.fireControlState !== FIRE_HOLD && cmd.fireControlState !== FIRE_AT_WILL) {
    return fail("Invalid fire-control state.");
  }
  const soldier = gameState.getSoldier(actingTeamId, cmd.soldierId);
  if (soldier === null || soldier.isDead) {
    return fail("Soldier unavailable.");
  }

  soldier.fireControlState = cmd.fireControlState;
  const result = emptyAction(
    true,
    `Soldier ${soldier.soldierId} set to ${fireControlLabel(cmd.fireControlState)}`,
  );
  if (cmd.fireControlState === FIRE_HOLD) {
    if (soldier.sustainedFire) {
      soldier.endSustainedFire();
      result.syncFireAtUi = true;
      result.statusMessage = `Soldier ${soldier.soldierId} set to Hold Fire — ceased fire.`;
    } else if (soldier.isEngaged()) {
      soldier.clearEngagement();
      result.syncFireAtUi = true;
      result.statusMessage = `Soldier ${soldier.soldierId} set to Hold Fire — ceased fire.`;
    }
  }
  pushTargetUpdate(result, soldier);
  return result;
}

export function executeFireAt(
  gameState: GameState,
  cmd: FireAtCommandIntent,
  actingTeamId: number,
): ActionResult {
  if (cmd.teamId !== actingTeamId) {
    return fail("That soldier is not under your control.");
  }

  const now = gameState.clock.getTicksMsec();
  const shooters =
    cmd.scope === MOVE_SCOPE_SQUAD
      ? gameState.soldiersOnTeam(actingTeamId)
      : [gameState.getSoldier(actingTeamId, cmd.soldierId)];

  const hasExplicitTarget = cmd.targetTeamId >= 0 && cmd.targetSoldierId > 0;
  if (!hasExplicitTarget) {
    return executeFireAtFaceOnly(gameState, cmd, shooters, now);
  }

  const target = gameState.getSoldier(cmd.targetTeamId, cmd.targetSoldierId);
  if (target === null || target.isDead) {
    return fail("Invalid target.");
  }
  if (target.teamId === actingTeamId) {
    return fail("Cannot assign a friendly as a priority target.");
  }

  const result = emptyAction();
  let engaged = 0;
  let firstNotice = "";
  let anyObscured = false;
  for (const shooter of shooters) {
    if (shooter === null || shooter.isDead) {
      continue;
    }
    if (shooter.isStunned(now)) {
      firstNotice = firstNotice || "Soldier is stunned and cannot fire.";
      continue;
    }
    if (isPanicked(shooter.stress)) {
      firstNotice = firstNotice || "Soldier is panicked and ignores the order.";
      continue;
    }
    if (!canAssignManualPriority(shooter, target, gameState, cmd.targetCell ?? target.gridPosition)) {
      continue;
    }
    haltSoldierIfMoving(shooter, result);
    if (canSpot(shooter, target, gameState)) {
      shooter.recordLastSeen(target.teamId, target.soldierId, now, target.gridPosition);
    }
    shooter.beginSustainedFire();
    shooter.fireControlState = FIRE_AT_WILL;
    shooter.setEngagedTarget(target.teamId, target.soldierId);
    beginFirePrep(gameState, shooter, combatRange(shooter.gridPosition, target.gridPosition));
    applyFireAtFacing(shooter, result, target.gridPosition, cmd.aimWorld ?? null);
    pushTargetUpdate(result, shooter);
    engaged += 1;
    const los = evaluate(
      shooter.gridPosition,
      target.gridPosition,
      gameState.map,
      gameState.losOccupants(),
    );
    if (los.status === LOS_BLOCKED) {
      anyObscured = true;
    }
  }

  if (engaged === 0) {
    if (firstNotice) {
      return fail(firstNotice);
    }
    if (cmd.targetCell !== undefined) {
      const face = executeFireAtFaceOnly(gameState, cmd, shooters, now);
      if (face.success) {
        face.statusMessage = "No visible target there.";
      }
      return face;
    }
    return fail("No visible target there.");
  }
  if (result.movementHalts.length > 0) {
    result.statusMessage = "";
  }
  result.syncFireAtUi = true;
  gameState.markPerceptionDirty();
  if (anyObscured && engaged === 1) {
    result.statusMessage = `Priority target ${teamDisplayName(target.teamId)} Soldier ${target.soldierId} — holding fire until line of sight clears.`;
  } else if (engaged === 1) {
    result.statusMessage = `Priority target ${teamDisplayName(target.teamId)} Soldier ${target.soldierId}.`;
  } else {
    result.statusMessage = `${engaged} soldiers assigned priority targets.`;
  }
  return result;
}

/** Same as GDScript execute_fire with no target: end sustained fire and face the click. */
function executeFireAtFaceOnly(
  gameState: GameState,
  cmd: FireAtCommandIntent,
  shooters: Array<SoldierState | null>,
  now: number,
): ActionResult {
  const faceCell = cmd.targetCell;
  if (faceCell === undefined) {
    return fail("Fire At requires an aim tile or an enemy.");
  }
  const result = emptyAction();
  let faced = 0;
  let firstNotice = "";
  for (const shooter of shooters) {
    if (shooter === null || shooter.isDead) {
      continue;
    }
    if (shooter.isStunned(now)) {
      firstNotice = firstNotice || "Soldier is stunned and cannot fire.";
      continue;
    }
    if (isPanicked(shooter.stress)) {
      firstNotice = firstNotice || "Soldier is panicked and ignores the order.";
      continue;
    }
    haltSoldierIfMoving(shooter, result);
    if (shooter.sustainedFire) {
      shooter.endSustainedFire();
    } else if (shooter.isEngaged()) {
      shooter.clearEngagement();
    }
    applyFireAtFacing(shooter, result, faceCell, cmd.aimWorld ?? null);
    pushTargetUpdate(result, shooter);
    faced += 1;
  }
  if (faced === 0) {
    return fail(firstNotice || "No available soldiers to fire.");
  }
  result.syncFireAtUi = true;
  result.statusMessage = "No visible target there.";
  return result;
}

function applyFireAtFacing(
  shooter: SoldierState,
  result: ActionResult,
  faceCell: { x: number; y: number },
  aimWorld: { x: number; y: number } | null,
): void {
  const facing = towardWorldPoint(shooter.gridPosition, faceCell, aimWorld);
  if (facing.x === 0 && facing.y === 0) {
    return;
  }
  shooter.facing = { ...facing };
  result.faceUpdates.push({
    teamId: shooter.teamId,
    soldierId: shooter.soldierId,
    facing: { ...shooter.facing },
  });
}

function fireControlLabel(state: number): string {
  return state === FIRE_HOLD ? "HOLD_FIRE" : "FIRE_AT_WILL";
}

function pushTargetUpdate(result: ActionResult, soldier: SoldierState): void {
  const update: TargetUpdatePayload = {
    teamId: soldier.teamId,
    soldierId: soldier.soldierId,
    fireControlState: soldier.fireControlState,
    engagedTargetTeamId: soldier.engagedTargetTeamId,
    engagedTargetSoldierId: soldier.engagedTargetSoldierId,
    sustainedFire: soldier.sustainedFire,
  };
  const existing = result.targetUpdates.findIndex(
    (u) => u.teamId === soldier.teamId && u.soldierId === soldier.soldierId,
  );
  if (existing >= 0) {
    result.targetUpdates[existing] = update;
  } else {
    result.targetUpdates.push(update);
  }
}

function faceStatus(teamId: number, soldier: SoldierState): string {
  return `${teamDisplayName(teamId)} Soldier ${soldier.soldierId} facing ${facingName(soldier.facing)}.`;
}

export function toMoveResultPayload(
  matchId: string,
  requestId: string,
  result: ActionResult,
): MoveResultPayload {
  return {
    type: "move_result",
    matchId,
    requestId,
    success: result.success,
    statusMessage: result.statusMessage,
    moveOrders: result.moveOrders,
    movementHalts: result.movementHalts,
    stanceTransitionOrders: result.stanceTransitionOrders,
    soldierUpdates: result.soldierUpdates,
  };
}

export function toFaceResultPayload(
  matchId: string,
  requestId: string,
  result: ActionResult,
): FaceResultPayload {
  return {
    type: "face_result",
    matchId,
    requestId,
    success: result.success,
    statusMessage: result.statusMessage,
    faceUpdates: result.faceUpdates,
  };
}

export function toPositionResultPayload(
  matchId: string,
  requestId: string,
  result: ActionResult,
): PositionResultPayload {
  const first = result.soldierUpdates[0];
  return {
    type: "position_result",
    matchId,
    requestId,
    success: result.success,
    statusMessage: result.statusMessage,
    positionState: first?.positionState ?? POSITION_UP,
    movementHalts: result.movementHalts,
    stanceTransitionOrders: result.stanceTransitionOrders,
    soldierUpdates: result.soldierUpdates,
  };
}

export function toFireControlResultPayload(
  matchId: string,
  requestId: string,
  result: ActionResult,
): FireControlResultPayload {
  return {
    type: "fire_control_result",
    matchId,
    requestId,
    success: result.success,
    statusMessage: result.statusMessage,
    syncFireAtUi: result.syncFireAtUi,
    targetUpdates: result.targetUpdates,
  };
}

export function toFireAtResultPayload(
  matchId: string,
  requestId: string,
  result: ActionResult,
): FireAtResultPayload {
  return {
    type: "fire_at_result",
    matchId,
    requestId,
    success: result.success,
    statusMessage: result.statusMessage,
    syncFireAtUi: result.syncFireAtUi,
    movementHalts: result.movementHalts,
    faceUpdates: result.faceUpdates,
    targetUpdates: result.targetUpdates,
  };
}
