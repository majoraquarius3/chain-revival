import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { WebSocket } from "ws";
import { executeFireAt, executeMove, executePosition } from "../src/action_resolver";
import {
  beginFirePrep,
  processCombatTick,
  resolveShot,
} from "../src/combat_system";
import { towardCell } from "../src/facing";
import { GameState } from "../src/game_state";
import { finalHitChance } from "../src/hit_resolution";
import { evaluate } from "../src/los";
import { MapData } from "../src/map_data";
import { LocalMatch } from "../src/match";
import {
  accuracyModifierFor,
  decayStress,
  movementModifier,
  stressBand,
  suppressionGain,
} from "../src/stress_accuracy";
import {
  FIRE_HOLD,
  MATCH_ID,
  MOVEMENT_CRAWL,
  MOVEMENT_RUN,
  MOVE_SCOPE_SINGLE,
  POSITION_DOWN,
  POSITION_UP,
  TEAM_GERMANY,
  TEAM_USA,
  vec,
} from "../src/types";
import { effectiveWeaponRange, getWeapon } from "../src/weapons";

function fakeWs(): WebSocket & { sent: unknown[] } {
  const sent: unknown[] = [];
  return {
    sent,
    readyState: 1,
    OPEN: 1,
    send(text: string) {
      sent.push(JSON.parse(text) as unknown);
    },
  } as unknown as WebSocket & { sent: unknown[] };
}

function stateWithPair(range = 5): GameState {
  const state = new GameState(MapData.empty(40, 40));
  for (const soldier of state.soldiers) {
    soldier.isDead = soldier.soldierId !== 1;
  }
  const shooter = state.getSoldier(TEAM_USA, 1)!;
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  shooter.isDead = false;
  target.isDead = false;
  shooter.gridPosition = vec(5, 5);
  target.gridPosition = vec(5 + range, 5);
  shooter.facing = towardCell(shooter.gridPosition, target.gridPosition);
  target.facing = towardCell(target.gridPosition, shooter.gridPosition);
  shooter.fireControlState = FIRE_HOLD;
  target.fireControlState = FIRE_HOLD;
  state.perception.rebuildVisibility(state);
  return state;
}

function advance(state: GameState, msec: number): void {
  let remaining = msec;
  while (remaining > 0) {
    const slice = Math.min(500, remaining);
    state.clock.consumeRealtime(slice, () => {});
    remaining -= slice;
  }
}

function readyShot(state: GameState): void {
  const shooter = state.getSoldier(TEAM_USA, 1)!;
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  beginFirePrep(state, shooter, Math.hypot(
    target.gridPosition.x - shooter.gridPosition.x,
    target.gridPosition.y - shooter.gridPosition.y,
  ));
  advance(state, 5000);
}

test("shared Godot/TypeScript Phase 7 parity fixtures match", () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const fixture = JSON.parse(
    fs.readFileSync(path.resolve(here, "../../assets/data/combat_phase7_parity.json"), "utf8"),
  ) as {
    base_accuracy: Array<{ weapon_id: string; range: number; expected: number }>;
    stress_accuracy: Array<{ stress: number; range: number; aim_factor: number; expected: number }>;
    suppression_gain: Array<{ stress_factor: number; limit: number; range: number; expected: number }>;
    decay: Array<{ stress: number; prone: boolean; delta_sec: number; expected: number }>;
  };
  for (const row of fixture.base_accuracy) {
    const state = stateWithPair(row.range);
    const shooter = state.getSoldier(TEAM_USA, 1)!;
    const target = state.getSoldier(TEAM_GERMANY, 1)!;
    const weapon = getWeapon(row.weapon_id)!;
    const los = evaluate(shooter.gridPosition, target.gridPosition, state.map, state.losOccupants());
    assert.ok(Math.abs(finalHitChance(shooter, target, weapon, los).breakdown.base - row.expected) < 1e-12);
  }
  for (const row of fixture.stress_accuracy) {
    assert.ok(Math.abs(accuracyModifierFor(row.stress, row.range, row.aim_factor) - row.expected) < 1e-12);
  }
  for (const row of fixture.suppression_gain) {
    assert.ok(Math.abs(suppressionGain(row.stress_factor, row.limit, row.range) - row.expected) < 1e-12);
  }
  for (const row of fixture.decay) {
    assert.ok(Math.abs(decayStress(row.stress, row.prone, row.delta_sec) - row.expected) < 1e-12);
  }
});

test("accuracy breakdown preserves modifier order and point-blank final floor", () => {
  const state = stateWithPair(2);
  const shooter = state.getSoldier(TEAM_USA, 1)!;
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  shooter.stress = 100;
  shooter.positionState = POSITION_DOWN;
  target.positionState = POSITION_DOWN;
  const weapon = getWeapon(shooter.weaponId)!;
  const los = evaluate(shooter.gridPosition, target.gridPosition, state.map, state.losOccupants());
  const result = finalHitChance(shooter, target, weapon, los);
  assert.equal(result.breakdown.openGroundMult, 1.15);
  assert.ok(result.breakdown.stressMult < 1);
  assert.equal(result.breakdown.shooterProneMult, 1.15);
  assert.equal(result.breakdown.targetProneMult, 0.55);
  assert.equal(result.breakdown.pointBlankFloor, 0.92);
  assert.equal(result.chance, 0.92);
});

test("weapon firing envelope preserves the cone range bonus", () => {
  assert.equal(effectiveWeaponRange(getWeapon("m1_garand")), 48);
});

test("a fired miss still applies suppression and exposes a status delta", () => {
  const state = stateWithPair(5);
  const shooter = state.getSoldier(TEAM_USA, 1)!;
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  shooter.beginSustainedFire();
  shooter.setEngagedTarget(target.teamId, target.soldierId);
  readyShot(state);
  state.rng.forceChance = false;
  const result = processCombatTick(state);
  assert.equal(result.shots.length, 1);
  assert.equal(result.shots[0].hit, false);
  assert.ok(Math.abs(target.stress - 71.42857142857143) < 1e-9);
  assert.equal(target.receivedSuppressionThisTick, true);
  assert.equal(result.statusUpdates.find((u) => u.teamId === target.teamId)?.stressBand, 4);
});

test("wall protection still receives suppression but blocked LOS does not", () => {
  const wall = stateWithPair(4);
  wall.map.placeObject(vec(8, 5), "wall_straight", "SWAL");
  readyShot(wall);
  wall.rng.forceChance = false;
  const wallShot = resolveShot(
    wall,
    wall.getSoldier(TEAM_USA, 1)!,
    wall.getSoldier(TEAM_GERMANY, 1)!,
    true,
  );
  assert.equal(wallShot.fired, true);
  assert.ok(wall.getSoldier(TEAM_GERMANY, 1)!.stress > 0);

  const blocked = stateWithPair(6);
  blocked.map.placeObject(vec(8, 5), "coc_blocker", "");
  readyShot(blocked);
  const blockedShot = resolveShot(
    blocked,
    blocked.getSoldier(TEAM_USA, 1)!,
    blocked.getSoldier(TEAM_GERMANY, 1)!,
    true,
  );
  assert.equal(blockedShot.fired, false);
  assert.equal(blocked.getSoldier(TEAM_GERMANY, 1)!.stress, 0);
});

test("cover and prone reduce suppression, repeated fire caps it, cooldown prevents duplicates", () => {
  const state = stateWithPair(5);
  state.map.placeObject(vec(9, 5), "haybail", "BG01");
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  target.positionState = POSITION_DOWN;
  readyShot(state);
  state.rng.forceChance = false;
  const first = resolveShot(state, state.getSoldier(TEAM_USA, 1)!, target, true);
  const expected = 71.42857142857143 * 0.65 * 0.75;
  assert.ok(Math.abs(target.stress - expected) < 1e-9);
  const duplicate = resolveShot(state, state.getSoldier(TEAM_USA, 1)!, target, true);
  assert.equal(duplicate.fired, false);
  assert.equal(target.stress, expected);
  target.stress = 99;
  advance(state, 7500);
  resolveShot(state, state.getSoldier(TEAM_USA, 1)!, target, true);
  assert.equal(target.stress, 100);
});

test("stress decays per scan, prone decays faster, and incoming fire interrupts decay", () => {
  const state = stateWithPair(5);
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  target.stress = 50;
  const standing = processCombatTick(state);
  assert.ok(Math.abs(target.stress - decayStress(50, false, 0.5)) < 1e-12);
  assert.ok(standing.statusUpdates.some((u) => u.soldierId === target.soldierId && u.teamId === target.teamId));
  target.stress = 50;
  target.positionState = POSITION_DOWN;
  processCombatTick(state);
  assert.ok(Math.abs(target.stress - decayStress(50, true, 0.5)) < 1e-12);

  target.positionState = POSITION_UP;
  target.stress = 10;
  const shooter = state.getSoldier(TEAM_USA, 1)!;
  shooter.beginSustainedFire();
  shooter.setEngagedTarget(target.teamId, target.soldierId);
  readyShot(state);
  state.rng.forceChance = false;
  processCombatTick(state);
  assert.ok(target.stress > 80);
});

test("stress changes accuracy, cadence, movement speed, and panic rejects manual Fire At", () => {
  const calm = stateWithPair(6);
  const stressed = stateWithPair(6);
  stressed.getSoldier(TEAM_USA, 1)!.stress = 50;
  const calmShooter = calm.getSoldier(TEAM_USA, 1)!;
  const stressedShooter = stressed.getSoldier(TEAM_USA, 1)!;
  const calmTarget = calm.getSoldier(TEAM_GERMANY, 1)!;
  const stressedTarget = stressed.getSoldier(TEAM_GERMANY, 1)!;
  const weapon = getWeapon(calmShooter.weaponId)!;
  const calmLos = evaluate(calmShooter.gridPosition, calmTarget.gridPosition, calm.map, calm.losOccupants());
  const stressedLos = evaluate(stressedShooter.gridPosition, stressedTarget.gridPosition, stressed.map, stressed.losOccupants());
  assert.ok(finalHitChance(stressedShooter, stressedTarget, weapon, stressedLos).chance <
    finalHitChance(calmShooter, calmTarget, weapon, calmLos).chance);
  beginFirePrep(stressed, stressedShooter, 6);
  assert.equal(stressedShooter.fireReadyAfterMsec - stressed.clock.getTicksMsec(), 6500);

  const move = executeMove(
    stressed,
    {
      type: "move_command",
      matchId: MATCH_ID,
      requestId: "stress-move",
      teamId: TEAM_USA,
      soldierId: 1,
      targetCell: vec(5, 8),
      scope: MOVE_SCOPE_SINGLE,
      movementMode: MOVEMENT_RUN,
    },
    TEAM_USA,
  );
  assert.equal(move.moveOrders[0].speedMult, 2 * movementModifier(50));

  const panic = stateWithPair(5);
  panic.getSoldier(TEAM_USA, 1)!.stress = 70;
  const fire = executeFireAt(
    panic,
    {
      type: "fire_at_command",
      matchId: MATCH_ID,
      requestId: "panic",
      teamId: TEAM_USA,
      soldierId: 1,
      targetTeamId: TEAM_GERMANY,
      targetSoldierId: 1,
      scope: MOVE_SCOPE_SINGLE,
    },
    TEAM_USA,
  );
  assert.equal(fire.success, false);
  assert.match(fire.statusMessage, /panicked/i);
});

test("stun is simulation-clock owned, blocks commands/fire, and grenade recovery stands up", () => {
  const state = stateWithPair(5);
  const soldier = state.getSoldier(TEAM_USA, 1)!;
  soldier.applyGrenadeStun(state.clock.getTicksMsec(), 1);
  assert.equal(soldier.positionState, POSITION_DOWN);
  assert.equal(soldier.movementMode, MOVEMENT_CRAWL);
  assert.equal(executePosition(
    state,
    {
      type: "position_command",
      matchId: MATCH_ID,
      requestId: "stun-stance",
      teamId: TEAM_USA,
      soldierId: 1,
      positionState: POSITION_UP,
    },
    TEAM_USA,
  ).success, false);
  assert.equal(resolveShot(state, soldier, state.getSoldier(TEAM_GERMANY, 1)!, true).fired, false);
  advance(state, 1000);
  const scan = processCombatTick(state);
  assert.equal(soldier.isStunned(state.clock.getTicksMsec()), false);
  assert.equal(soldier.positionState, POSITION_UP);
  assert.ok(scan.statusUpdates.some((u) => u.teamId === TEAM_USA && u.soldierId === 1));
});

test("death clears stun/engagement and dead soldiers cannot receive suppression", () => {
  const state = stateWithPair(5);
  const shooter = state.getSoldier(TEAM_USA, 1)!;
  const target = state.getSoldier(TEAM_GERMANY, 1)!;
  shooter.beginSustainedFire();
  shooter.setEngagedTarget(target.teamId, target.soldierId);
  target.applyStun(state.clock.getTicksMsec(), 10);
  readyShot(state);
  state.rng.forceChance = true;
  const shot = resolveShot(state, shooter, target, true);
  assert.equal(shot.killed, true);
  assert.equal(target.stunnedUntilMsec, 0);
  assert.equal(shooter.sustainedFire, false);
  const stressAtDeath = target.stress;
  readyShot(state);
  assert.equal(resolveShot(state, shooter, target, true).fired, false);
  assert.equal(target.stress, stressAtDeath);
});

test("stress bands and status fields are snapshot-serializable", () => {
  const state = stateWithPair(5);
  const soldier = state.getSoldier(TEAM_USA, 1)!;
  soldier.stress = 45;
  soldier.applyStun(state.clock.getTicksMsec(), 4);
  const snapshot = state.getSnapshot().soldiers.find((s) => s.teamId === TEAM_USA && s.soldierId === 1)!;
  assert.equal(stressBand(snapshot.stress), 3);
  assert.equal(snapshot.stunnedUntilMsec, 4000);
  assert.equal(snapshot.standOnStunRecovery, false);
});

test("both clients receive identical authoritative combat status deltas", () => {
  const match = new LocalMatch("ff_farm", { startDriver: false });
  const usaClient = fakeWs();
  const germanyClient = fakeWs();
  match.attachClient("usa", usaClient);
  match.attachClient("germany", germanyClient);
  match.gameState.getSoldier(TEAM_USA, 1)!.stress = 50;
  match.advanceRealtime(500);
  const usaStatus = usaClient.sent.filter(
    (message) => (message as { type?: string }).type === "combat_status",
  );
  const germanyStatus = germanyClient.sent.filter(
    (message) => (message as { type?: string }).type === "combat_status",
  );
  assert.deepEqual(usaStatus, germanyStatus);
  assert.equal(usaStatus.length, 1);
});
