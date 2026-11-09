import assert from "node:assert/strict";
import { test } from "node:test";
import { executeFireAt, executeMove, processMovementTick } from "../src/action_resolver";
import {
  beginFirePrep,
  isFirePrepComplete,
  processCombatTick,
  resolveShot,
  tryAutoEngagement,
  tryEngagedFire,
} from "../src/combat_system";
import { towardCell } from "../src/facing";
import { GameState } from "../src/game_state";
import { BASE_FIRE_CYCLE_SEC, baseHitChance, LETHALITY_MULTIPLIER } from "../src/hit_resolution";
import { MapData } from "../src/map_data";
import { COMBAT_SCAN_TICKS } from "../src/perception";
import {
  FIRE_AT_WILL,
  FIRE_HOLD,
  MATCH_ID,
  MOVEMENT_RUN,
  MOVE_SCOPE_SINGLE,
  POSITION_DOWN,
  TEAM_GERMANY,
  TEAM_USA,
  vec,
} from "../src/types";
import { getWeapon } from "../src/weapons";

function emptyState(): GameState {
  const state = new GameState(MapData.empty(24, 24));
  for (const s of state.soldiers) {
    if (s.soldierId !== 1) {
      s.isDead = true;
    }
  }
  return state;
}

function usa(state: GameState) {
  const s = state.getSoldier(TEAM_USA, 1);
  assert.ok(s);
  return s;
}

function ger(state: GameState) {
  const s = state.getSoldier(TEAM_GERMANY, 1);
  assert.ok(s);
  return s;
}

function pair(state: GameState, a = vec(4, 4), b = vec(4, 5)): void {
  const shooter = usa(state);
  const target = ger(state);
  shooter.isDead = false;
  target.isDead = false;
  shooter.gridPosition = a;
  target.gridPosition = b;
  shooter.facing = towardCell(a, b);
  target.facing = towardCell(b, a);
  shooter.fireControlState = FIRE_HOLD;
  target.fireControlState = FIRE_HOLD;
  shooter.sustainedFire = false;
  shooter.clearEngagement();
  state.perception.rebuildVisibility(state);
}

function advanceSim(state: GameState, msec: number): void {
  let left = msec;
  while (left > 0) {
    const slice = Math.min(500, left);
    state.clock.consumeRealtime(slice, () => {});
    left -= slice;
  }
}

function pump(state: GameState, msec: number): void {
  let left = msec;
  while (left > 0) {
    const slice = Math.min(500, left);
    state.clock.consumeRealtime(slice, (tickId) => {
      processMovementTick(state);
      state.perception.processTick(state, tickId);
      if (tickId % COMBAT_SCAN_TICKS === 0) {
        processCombatTick(state);
      }
    });
    left -= slice;
  }
}

test("rifle base hit chance matches recovered polynomial at range 11", () => {
  const weapon = getWeapon("m1_garand");
  assert.ok(weapon);
  const chance = baseHitChance(vec(0, 0), vec(11, 0), weapon, 0);
  assert.ok(Math.abs(chance - 0.090156) < 0.001);
});

test("target starts aiming on Fire At and cannot fire before the cycle", () => {
  const state = emptyState();
  pair(state);
  state.rng.forceChance = true;
  executeFireAt(
    state,
    {
      type: "fire_at_command",
      matchId: MATCH_ID,
      requestId: "aim",
      teamId: TEAM_USA,
      soldierId: 1,
      targetTeamId: TEAM_GERMANY,
      targetSoldierId: 1,
      scope: MOVE_SCOPE_SINGLE,
    },
    TEAM_USA,
  );
  const shooter = usa(state);
  assert.ok(shooter.fireReadyAfterMsec > 0);
  assert.equal(isFirePrepComplete(state, shooter), false);
  const early = tryEngagedFire(state, shooter);
  assert.equal(early, null);
  advanceSim(state, BASE_FIRE_CYCLE_SEC * 1000);
  assert.equal(isFirePrepComplete(state, shooter), true);
  const shot = resolveShot(state, shooter, ger(state), true);
  assert.equal(shot.fired, true);
});

test("movement interrupts aim and engagement", () => {
  const state = emptyState();
  pair(state);
  const shooter = usa(state);
  executeFireAt(
    state,
    {
      type: "fire_at_command",
      matchId: MATCH_ID,
      requestId: "move-int",
      teamId: TEAM_USA,
      soldierId: 1,
      targetTeamId: TEAM_GERMANY,
      targetSoldierId: 1,
      scope: MOVE_SCOPE_SINGLE,
    },
    TEAM_USA,
  );
  assert.equal(shooter.sustainedFire, true);
  executeMove(
    state,
    {
      type: "move_command",
      matchId: MATCH_ID,
      requestId: "run",
      teamId: TEAM_USA,
      soldierId: 1,
      targetCell: vec(shooter.gridPosition.x + 2, shooter.gridPosition.y),
      scope: MOVE_SCOPE_SINGLE,
      movementMode: MOVEMENT_RUN,
    },
    TEAM_USA,
  );
  assert.equal(shooter.isEngaged(), false);
  assert.equal(shooter.sustainedFire, false);
  assert.equal(shooter.fireReadyAfterMsec, 0);
});

test("cooldown blocks a second shot then expires", () => {
  const state = emptyState();
  pair(state);
  state.rng.forceChance = false;
  const shooter = usa(state);
  const target = ger(state);
  beginFirePrep(state, shooter, 1);
  advanceSim(state, 5000);
  const first = resolveShot(state, shooter, target, true);
  assert.equal(first.fired, true);
  assert.equal(first.shotId, 1);
  const second = resolveShot(state, shooter, target, true);
  assert.equal(second.fired, false);
  assert.equal(second.onCooldown, true);
  advanceSim(state, 5000);
  const third = resolveShot(state, shooter, target, true);
  assert.equal(third.fired, true);
  assert.equal(third.shotId, 2);
});

test("weapon-specific cadence uses fire_interval_sec when set", () => {
  const state = emptyState();
  pair(state);
  const shooter = usa(state);
  const weapon = getWeapon("m1_garand");
  assert.ok(weapon);
  weapon.fireIntervalSec = 2;
  beginFirePrep(state, shooter, 1);
  assert.equal(shooter.fireReadyAfterMsec, 2000);
  weapon.fireIntervalSec = 0;
});

test("manual Fire At sustained engagement fires after aim", () => {
  const state = emptyState();
  pair(state);
  state.rng.forceChance = true;
  executeFireAt(
    state,
    {
      type: "fire_at_command",
      matchId: MATCH_ID,
      requestId: "sust",
      teamId: TEAM_USA,
      soldierId: 1,
      targetTeamId: TEAM_GERMANY,
      targetSoldierId: 1,
      scope: MOVE_SCOPE_SINGLE,
    },
    TEAM_USA,
  );
  pump(state, 5500);
  assert.equal(ger(state).isDead, true);
  assert.ok(usa(state).lastShotMsec > 0);
});

test("Fire At Will sustained engagement aims then fires", () => {
  const state = emptyState();
  pair(state);
  state.rng.forceChance = true;
  const shooter = usa(state);
  shooter.fireControlState = FIRE_AT_WILL;
  state.perception.rebuildVisibility(state);
  state.perception.processTick(state, COMBAT_SCAN_TICKS, true);
  assert.equal(shooter.isEngaged(), true);
  assert.ok(shooter.fireReadyAfterMsec > 0);
  const early = tryAutoEngagement(state, shooter);
  assert.equal(early, null);
  pump(state, 5500);
  assert.equal(ger(state).isDead, true);
});

test("blocked LOS prevents a shot", () => {
  const state = emptyState();
  pair(state, vec(4, 4), vec(4, 10));
  state.map.placeObject(vec(4, 7), "coc_blocker", "");
  state.rng.forceChance = true;
  const shooter = usa(state);
  const target = ger(state);
  beginFirePrep(state, shooter, 6);
  advanceSim(state, 5000);
  const shot = resolveShot(state, shooter, target, true);
  assert.equal(shot.fired, false);
  assert.equal(shot.blocked, true);
});

test("out of range prevents a shot", () => {
  const state = emptyState();
  pair(state, vec(0, 0), vec(0, 50));
  usa(state).facing = towardCell(vec(0, 0), vec(0, 50));
  beginFirePrep(state, usa(state), 50);
  advanceSim(state, 5000);
  const shot = resolveShot(state, usa(state), ger(state), true);
  assert.equal(shot.fired, false);
  assert.equal(shot.outOfRange, true);
});

test("cover lowers hit chance versus open ground", () => {
  const open = emptyState();
  pair(open, vec(5, 1), vec(5, 8));
  beginFirePrep(open, usa(open), 7);
  advanceSim(open, 5000);
  open.rng.forceChance = false;
  const openShot = resolveShot(open, usa(open), ger(open), true);

  const covered = emptyState();
  pair(covered, vec(5, 1), vec(5, 8));
  covered.map.placeObject(vec(5, 7), "haybail", "BG01");
  beginFirePrep(covered, usa(covered), 7);
  advanceSim(covered, 5000);
  covered.rng.forceChance = false;
  const coverShot = resolveShot(covered, usa(covered), ger(covered), true);
  assert.equal(openShot.fired, true);
  assert.equal(coverShot.fired, true);
  assert.ok(coverShot.hadCover);
  assert.ok(coverShot.hitFinal < openShot.hitFinal);
});

test("complete wall-hug fires without a hit roll", () => {
  const state = emptyState();
  pair(state, vec(4, 4), vec(4, 8));
  state.map.placeObject(vec(4, 7), "wall_straight", "SWAL");
  beginFirePrep(state, usa(state), 4);
  advanceSim(state, 5000);
  state.rng.forceChance = true;
  const beforeCalls = state.rng.callCount;
  const shot = resolveShot(state, usa(state), ger(state), true);
  assert.equal(shot.fired, true);
  assert.equal(shot.hit, false);
  assert.equal(shot.killed, false);
  assert.equal(state.rng.callCount, beforeCalls);
});

test("mock RNG hit kills and miss does not", () => {
  const hitState = emptyState();
  pair(hitState);
  beginFirePrep(hitState, usa(hitState), 1);
  advanceSim(hitState, 5000);
  hitState.rng.forceChance = true;
  const hit = resolveShot(hitState, usa(hitState), ger(hitState), true);
  assert.equal(hit.hit, true);
  assert.equal(hit.killed, true);
  assert.equal(ger(hitState).isDead, true);

  const missState = emptyState();
  pair(missState);
  beginFirePrep(missState, usa(missState), 1);
  advanceSim(missState, 5000);
  missState.rng.forceChance = false;
  const miss = resolveShot(missState, usa(missState), ger(missState), true);
  assert.equal(miss.fired, true);
  assert.equal(miss.hit, false);
  assert.equal(ger(missState).isDead, false);
});

test("dead soldier cannot fire and dead target is cleared", () => {
  const state = emptyState();
  pair(state);
  const shooter = usa(state);
  shooter.isDead = true;
  beginFirePrep(state, shooter, 1);
  advanceSim(state, 5000);
  const shot = resolveShot(state, shooter, ger(state), true);
  assert.equal(shot.fired, false);

  const state2 = emptyState();
  pair(state2);
  state2.rng.forceChance = true;
  executeFireAt(
    state2,
    {
      type: "fire_at_command",
      matchId: MATCH_ID,
      requestId: "kill",
      teamId: TEAM_USA,
      soldierId: 1,
      targetTeamId: TEAM_GERMANY,
      targetSoldierId: 1,
      scope: MOVE_SCOPE_SINGLE,
    },
    TEAM_USA,
  );
  pump(state2, 5500);
  assert.equal(ger(state2).isDead, true);
  assert.equal(usa(state2).engagedTargetSoldierId === 1, false);
});

test("death cancels movement", () => {
  const state = emptyState();
  pair(state, vec(4, 4), vec(6, 4));
  const target = ger(state);
  target.assignPath([vec(6, 4), vec(7, 4), vec(8, 4)], 1);
  assert.equal(target.isMoving, true);
  beginFirePrep(state, usa(state), 2);
  advanceSim(state, 5000);
  state.rng.forceChance = true;
  resolveShot(state, usa(state), target, true);
  assert.equal(target.isDead, true);
  assert.equal(target.isMoving, false);
  assert.equal(target.currentPath.length, 0);
});

test("both-client combat payload is a delta not a full GameState", () => {
  const state = emptyState();
  pair(state);
  beginFirePrep(state, usa(state), 1);
  advanceSim(state, 5000);
  state.rng.forceChance = true;
  const shot = resolveShot(state, usa(state), ger(state), true);
  assert.ok(shot.shotId > 0);
  assert.ok(!("soldiers" in shot));
  assert.equal(shot.killed, true);
  assert.ok(shot.deathSpriteFamily);
});

test("lethality is applied to hit chance", () => {
  assert.equal(LETHALITY_MULTIPLIER, 0.6);
});

test("prone shooter and target change final hit chance", () => {
  const stand = emptyState();
  pair(stand, vec(4, 4), vec(4, 8));
  beginFirePrep(stand, usa(stand), 4);
  advanceSim(stand, 5000);
  stand.rng.forceChance = false;
  const a = resolveShot(stand, usa(stand), ger(stand), true);

  const prone = emptyState();
  pair(prone, vec(4, 4), vec(4, 8));
  ger(prone).positionState = POSITION_DOWN;
  beginFirePrep(prone, usa(prone), 4);
  advanceSim(prone, 5000);
  prone.rng.forceChance = false;
  const b = resolveShot(prone, usa(prone), ger(prone), true);
  assert.ok(b.hitFinal < a.hitFinal);
});

test("combat scan does not emit duplicate shots in one tick", () => {
  const state = emptyState();
  pair(state);
  state.rng.forceChance = false;
  executeFireAt(
    state,
    {
      type: "fire_at_command",
      matchId: MATCH_ID,
      requestId: "dup",
      teamId: TEAM_USA,
      soldierId: 1,
      targetTeamId: TEAM_GERMANY,
      targetSoldierId: 1,
      scope: MOVE_SCOPE_SINGLE,
    },
    TEAM_USA,
  );
  advanceSim(state, 5000);
  const once = processCombatTick(state);
  assert.equal(once.shots.length, 1);
  const twice = processCombatTick(state);
  assert.equal(twice.shots.length, 0);
});
