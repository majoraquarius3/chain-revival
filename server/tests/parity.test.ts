// Shared parity fixtures (scripts/tests/parity/*.json), server side. The GDScript client is
// the reference: `expect` values come from it, so a failure here is server drift.
// Fixtures with `knownDrift` are reported as TODO until the matching sim-parity fix lands.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { applySuppressionFromShot } from "../src/combat_system";
import { GameState } from "../src/game_state";
import { resolveGrenade } from "../src/grenade_system";
import { finalHitChance } from "../src/hit_resolution";
import { coverCheck, cornerWatchFacing, evaluate } from "../src/los";
import { MapData } from "../src/map_data";
import { scoreAutoTarget } from "../src/perception";
import type { SoldierState } from "../src/soldier_state";
import { applyStressDecay } from "../src/stress_accuracy";
import { POSITION_DOWN, POSITION_UP, TEAM_GERMANY, TEAM_USA, vec, type Vec2i } from "../src/types";
import { getWeapon } from "../src/weapons";

const FIXTURE_DIR = join(__dirname, "..", "..", "scripts", "tests", "parity");

type Pair = [number, number];
interface SoldierSpec {
  team: number;
  id: number;
  cell: Pair;
  facing?: Pair;
  stance?: "up" | "down";
  stress?: number;
  weapon?: string;
  marksman?: number;
  sustainedFire?: boolean;
  engagedTarget?: Pair;
}
interface ObjectSpec {
  type: string;
  at?: Pair;
  from?: Pair;
  to?: Pair;
}
interface Fixture {
  name: string;
  map: { width: number; height: number; objects: ObjectSpec[] };
  soldiers: SoldierSpec[];
  query: Record<string, unknown> & { kind: string };
  expect: Record<string, unknown>;
  knownDrift?: string;
}

const MISSING = -999;
const cell = (p: Pair): Vec2i => vec(p[0], p[1]);
const outCell = (c: Vec2i): Pair | null => (c.x === MISSING && c.y === MISSING ? null : [c.x, c.y]);
const round = (x: number, places: number): number => Math.round(x * 10 ** places) / 10 ** places;

function objectCells(obj: ObjectSpec): Vec2i[] {
  if (obj.at) return [cell(obj.at)];
  const a = cell(obj.from!);
  const b = cell(obj.to!);
  const out: Vec2i[] = [];
  for (let x = Math.min(a.x, b.x); x <= Math.max(a.x, b.x); x++) {
    for (let y = Math.min(a.y, b.y); y <= Math.max(a.y, b.y); y++) out.push(vec(x, y));
  }
  return out;
}

function buildState(f: Fixture): GameState {
  const map = MapData.empty(f.map.width, f.map.height);
  for (const obj of f.map.objects) {
    for (const c of objectCells(obj)) map.placeObject(c, obj.type);
  }
  const state = new GameState(map);
  const listed = new Set<SoldierState>();
  for (const spec of f.soldiers) {
    const s = state.getSoldier(spec.team, spec.id)!;
    listed.add(s);
    s.clearPath();
    s.gridPosition = cell(spec.cell);
    s.facing = cell(spec.facing ?? [0, 1]);
    s.positionState = spec.stance === "down" ? POSITION_DOWN : POSITION_UP;
    s.clearPendingPosition();
    if (spec.weapon) s.assignWeapon(spec.weapon, true);
    s.stress = spec.stress ?? 0;
    s.marksman = spec.marksman ?? 0;
    s.sustainedFire = spec.sustainedFire ?? false;
    const [engagedTeam, engagedId] = spec.engagedTarget ?? [-1, -1];
    s.engagedTargetTeamId = engagedTeam;
    s.engagedTargetSoldierId = engagedId;
  }
  for (const s of state.soldiers) {
    if (!listed.has(s)) s.isDead = true;
  }
  return state;
}

function soldier(state: GameState, ref: unknown): SoldierState {
  const [team, id] = ref as Pair;
  return state.getSoldier(team, id)!;
}

function evaluateQuery(state: GameState, q: Fixture["query"]): Record<string, unknown> {
  const map = state.map;
  switch (q.kind) {
    case "los": {
      const s = soldier(state, q.shooter);
      const t = soldier(state, q.target);
      const los = evaluate(s.gridPosition, t.gridPosition, map, state.losOccupants());
      return {
        status: los.status,
        blockingCell: outCell(los.blockingCell),
        coverType: los.coverType,
        cornerPeek: los.cornerPeek,
        peekSide: los.peekSide,
        cornerCell: outCell(los.cornerCell),
        targetUsingWallCover: los.targetUsingWallCover,
      };
    }
    case "cover": {
      const s = soldier(state, q.shooter);
      const t = soldier(state, q.target);
      return { coverType: coverCheck(s.gridPosition, t.gridPosition, map).coverType };
    }
    case "hit_chance": {
      const s = soldier(state, q.shooter);
      const t = soldier(state, q.target);
      const los = evaluate(s.gridPosition, t.gridPosition, map, state.losOccupants());
      return { chance: round(finalHitChance(s, t, getWeapon(s.weaponId)!, los).chance, 4) };
    }
    case "suppression": {
      const s = soldier(state, q.shooter);
      const t = soldier(state, q.target);
      const los = evaluate(s.gridPosition, t.gridPosition, map, state.losOccupants());
      const before = t.stress;
      applySuppressionFromShot(state, s, t, los);
      return { gain: round(t.stress - before, 2) };
    }
    case "stress_decay":
      return {
        stress: round(
          applyStressDecay(Number(q.stress), Boolean(q.prone), Number(q.deltaSec)),
          4,
        ),
      };
    case "grenade": {
      // Kills use different RNGs on each side; force every hit to a stun.
      state.rng.forceChance = false;
      const result = resolveGrenade(state, soldier(state, q.thrower), cell(q.cell as Pair));
      const stunned = result.stunned
        .map((e) => [e.teamId, e.soldierId, round(e.durationSec, 2)])
        .sort((a, b) => a[0] * 10 + a[1] - (b[0] * 10 + b[1]));
      return { stunned, killed: result.killed.map((e) => [e.teamId, e.soldierId]) };
    }
    case "auto_target": {
      const s = soldier(state, q.shooter);
      const enemyTeam = s.teamId === TEAM_USA ? TEAM_GERMANY : TEAM_USA;
      let best: SoldierState | null = null;
      let bestScore = -1;
      for (let id = 1; id <= 4; id++) {
        const e = state.getSoldier(enemyTeam, id);
        if (!e || e.isDead) continue;
        const score = scoreAutoTarget(s, e, state);
        if (score >= 0 && score > bestScore) {
          bestScore = score;
          best = e;
        }
      }
      return { target: best ? [best.teamId, best.soldierId] : null };
    }
    case "arrival_facing": {
      const facing = cornerWatchFacing(cell(q.cell as Pair), map);
      return { facing: facing ? [facing.x, facing.y] : null };
    }
  }
  throw new Error(`unknown query kind ${q.kind}`);
}

// Same rules as the client runner: only keys in `expect` are checked, numbers within 0.0005.
function compare(expect: unknown, actual: unknown, path = ""): string {
  if (Array.isArray(expect)) {
    if (!Array.isArray(actual) || actual.length !== expect.length) return `${path}: expected ${JSON.stringify(expect)}`;
    for (let i = 0; i < expect.length; i++) {
      const d = compare(expect[i], actual[i], `${path}[${i}]`);
      if (d) return d;
    }
    return "";
  }
  if (expect !== null && typeof expect === "object") {
    if (actual === null || typeof actual !== "object") return `${path}: expected object`;
    for (const [k, v] of Object.entries(expect)) {
      if (!(k in (actual as object))) return `${path}.${k} missing`;
      const d = compare(v, (actual as Record<string, unknown>)[k], `${path}.${k}`);
      if (d) return d;
    }
    return "";
  }
  if (typeof expect === "number" && typeof actual === "number") {
    return Math.abs(expect - actual) > 0.0005 ? `${path}: expected ${expect}` : "";
  }
  return expect === actual ? "" : `${path}: expected ${JSON.stringify(expect)}`;
}

for (const file of readdirSync(FIXTURE_DIR).filter((n) => n.endsWith(".json")).sort()) {
  const cases = JSON.parse(readFileSync(join(FIXTURE_DIR, file), "utf8")) as Fixture[];
  for (const f of cases) {
    test(`parity ${f.name}`, { todo: f.knownDrift }, () => {
      assert.ok(Object.keys(f.expect).length > 0, "fixture has no expect values");
      const actual = evaluateQuery(buildState(f), f.query);
      const diff = compare(f.expect, actual);
      assert.equal(diff, "", `${diff} (actual ${JSON.stringify(actual)})`);
    });
  }
}
