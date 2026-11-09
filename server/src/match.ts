/**
 * One local multiplayer match. Server owns GameState and the sim clock.
 *
 * Clock lifecycle (not a player-facing pause menu):
 * - created → running immediately (match exists before either client joins)
 * - running: consumeRealtime → fixed ticks → movement + sim timers
 * - paused: infrastructure only (tests / future host pause). Not wired to UI.
 * - ended: clock stop(); no further GameState ticks
 *
 * Connecting/disconnecting clients does not create or reset the clock.
 * setInterval is only a wake — gameplay steps come from monotonic elapsed time.
 */

import type { WebSocket } from "ws";
import {
  executeFace,
  executeFireAt,
  executeFireControl,
  executeMove,
  executePosition,
  processMovementTick,
  toFaceResultPayload,
  toFireAtResultPayload,
  toFireControlResultPayload,
  toMoveResultPayload,
  toPositionResultPayload,
} from "./action_resolver";
import { COMBAT_SCAN_TICKS } from "./perception";
import { processCombatTick } from "./combat_system";
import { GameState } from "./game_state";
import { MapData } from "./map_data";
import type { ClockPumpResult } from "./simulation_clock";
import {
  DEFAULT_MAP_ID,
  MATCH_ID,
  type FaceCommandIntent,
  type FireAtCommandIntent,
  type FireControlCommandIntent,
  type MoveCommandIntent,
  type MovementTickPayload,
  type PositionCommandIntent,
  type TargetSyncPayload,
  type Vec2i,
  type CombatShotsPayload,
  type CombatStatusPayload,
  type VisibilityUpdatePayload,
} from "./types";

export type MatchPhase = "created" | "running" | "paused" | "ended";

export interface MatchOptions {
  /** Production default true. Tests pass false and call advanceRealtime. */
  startDriver?: boolean;
}

const DIAG_INTERVAL_MSEC = 5000;

export interface MatchClient {
  clientId: string;
  ws: WebSocket;
  teamId: number | null;
}

export class LocalMatch {
  readonly matchId = MATCH_ID;
  readonly gameState: GameState;
  private readonly clients = new Map<string, MatchClient>();
  private tickTimer: NodeJS.Timeout | null = null;
  private lastPumpHrTime: bigint | null = null;
  private lastDiagMsec = 0;
  private phase: MatchPhase = "created";
  snapshotSends = 0;
  movementTickSends = 0;
  visibilitySends = 0;

  constructor(mapId = DEFAULT_MAP_ID, options: MatchOptions = {}) {
    const map = MapData.loadFromRepo(mapId);
    this.gameState = new GameState(map);
    this.phase = "running";
    if (options.startDriver !== false) {
      this.startDriver();
    }
    console.log(
      "Match %s created map=%s soldiers=%d tickHz=%d",
      this.matchId,
      map.mapId,
      this.gameState.soldiers.length,
      this.gameState.clock.tickHz,
    );
  }

  get matchPhase(): MatchPhase {
    return this.phase;
  }

  get clock() {
    return this.gameState.clock;
  }

  get clientCount(): number {
    return this.clients.size;
  }

  attachClient(clientId: string, ws: WebSocket): void {
    this.clients.set(clientId, { clientId, ws, teamId: null });
  }

  setClientTeam(clientId: string, teamId: number): void {
    const client = this.clients.get(clientId);
    if (client !== undefined) {
      client.teamId = teamId;
    }
  }

  removeClient(clientId: string): void {
    this.clients.delete(clientId);
  }

  sendSnapshot(ws: WebSocket): void {
    this.snapshotSends += 1;
    ws.send(JSON.stringify(this.gameState.getSnapshot(this.phase)));
  }

  pauseSimulation(): void {
    if (this.phase === "ended") {
      return;
    }
    this.phase = "paused";
    this.clock.pause();
  }

  resumeSimulation(): void {
    if (this.phase !== "paused") {
      return;
    }
    this.phase = "running";
    this.clock.resume();
    this.lastPumpHrTime = process.hrtime.bigint();
  }

  endMatch(): void {
    this.phase = "ended";
    this.clock.stop();
    this.gameState.timers.clear();
    this.stopDriver();
  }

  /**
   * Testable pump: feed measured real elapsed msec (not Date.now gameplay delta).
   * Production driver uses process.hrtime.bigint() the same way.
   */
  advanceRealtime(elapsedMsec: number): ClockPumpResult {
    if (this.phase !== "running" || !this.clock.isRunning()) {
      return { steps: 0, discardedMsec: 0, capped: false };
    }
    return this.clock.consumeRealtime(elapsedMsec, (tickId, tickMsec) => {
      this.simulationTick(tickId, tickMsec);
    });
  }

  handleMove(clientId: string, intent: MoveCommandIntent): void {
    if (this.phase === "ended") {
      this.sendTo(clientId, {
        type: "move_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Match has ended.",
        moveOrders: [],
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    const client = this.clients.get(clientId);
    if (client === undefined || client.teamId === null) {
      this.sendTo(clientId, {
        type: "move_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Join a side before issuing orders.",
        moveOrders: [],
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    if (intent.matchId && intent.matchId !== this.matchId) {
      this.sendTo(clientId, {
        type: "move_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Unknown match.",
        moveOrders: [],
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }

    const result = executeMove(this.gameState, intent, client.teamId);
    const payload = toMoveResultPayload(this.matchId, intent.requestId, result);
    this.broadcast(payload);
    console.log(
      "Move %s team=%d soldier=%d success=%s",
      intent.requestId,
      intent.teamId,
      intent.soldierId,
      result.success,
    );
  }

  handleFace(clientId: string, intent: FaceCommandIntent): void {
    if (this.phase === "ended") {
      this.sendTo(clientId, {
        type: "face_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Match has ended.",
        faceUpdates: [],
      });
      return;
    }
    const client = this.clients.get(clientId);
    if (client === undefined || client.teamId === null) {
      this.sendTo(clientId, {
        type: "face_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Join a side before issuing orders.",
        faceUpdates: [],
      });
      return;
    }
    if (intent.matchId && intent.matchId !== this.matchId) {
      this.sendTo(clientId, {
        type: "face_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Unknown match.",
        faceUpdates: [],
      });
      return;
    }
    const result = executeFace(this.gameState, intent, client.teamId);
    this.broadcast(toFaceResultPayload(this.matchId, intent.requestId, result));
    console.log(
      "Face %s team=%d soldier=%d success=%s",
      intent.requestId,
      client.teamId,
      intent.soldierId,
      result.success,
    );
  }

  handlePosition(clientId: string, intent: PositionCommandIntent): void {
    if (this.phase === "ended") {
      this.sendTo(clientId, {
        type: "position_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Match has ended.",
        positionState: 0,
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    const client = this.clients.get(clientId);
    if (client === undefined || client.teamId === null) {
      this.sendTo(clientId, {
        type: "position_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Join a side before issuing orders.",
        positionState: 0,
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    if (intent.matchId && intent.matchId !== this.matchId) {
      this.sendTo(clientId, {
        type: "position_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Unknown match.",
        positionState: 0,
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    const result = executePosition(this.gameState, intent, client.teamId);
    this.broadcast(toPositionResultPayload(this.matchId, intent.requestId, result));
    console.log(
      "Position %s team=%d soldier=%d success=%s",
      intent.requestId,
      client.teamId,
      intent.soldierId,
      result.success,
    );
  }

  handleFireControl(clientId: string, intent: FireControlCommandIntent): void {
    if (this.phase === "ended") {
      this.sendTo(clientId, {
        type: "fire_control_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Match has ended.",
        syncFireAtUi: false,
        targetUpdates: [],
      });
      return;
    }
    const client = this.clients.get(clientId);
    if (client === undefined || client.teamId === null) {
      this.sendTo(clientId, {
        type: "fire_control_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Join a side before issuing orders.",
        syncFireAtUi: false,
        targetUpdates: [],
      });
      return;
    }
    if (intent.matchId && intent.matchId !== this.matchId) {
      this.sendTo(clientId, {
        type: "fire_control_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Unknown match.",
        syncFireAtUi: false,
        targetUpdates: [],
      });
      return;
    }
    const result = executeFireControl(this.gameState, intent, client.teamId);
    this.broadcast(toFireControlResultPayload(this.matchId, intent.requestId, result));
  }

  handleFireAt(clientId: string, intent: FireAtCommandIntent): void {
    if (this.phase === "ended") {
      this.sendTo(clientId, {
        type: "fire_at_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Match has ended.",
        syncFireAtUi: false,
        movementHalts: [],
        faceUpdates: [],
        targetUpdates: [],
      });
      return;
    }
    const client = this.clients.get(clientId);
    if (client === undefined || client.teamId === null) {
      this.sendTo(clientId, {
        type: "fire_at_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Join a side before issuing orders.",
        syncFireAtUi: false,
        movementHalts: [],
        faceUpdates: [],
        targetUpdates: [],
      });
      return;
    }
    if (intent.matchId && intent.matchId !== this.matchId) {
      this.sendTo(clientId, {
        type: "fire_at_result",
        matchId: this.matchId,
        requestId: intent.requestId,
        success: false,
        statusMessage: "Unknown match.",
        syncFireAtUi: false,
        movementHalts: [],
        faceUpdates: [],
        targetUpdates: [],
      });
      return;
    }
    const result = executeFireAt(this.gameState, intent, client.teamId);
    this.broadcast(toFireAtResultPayload(this.matchId, intent.requestId, result));
  }

  /**
   * One authoritative sim step. Movement (and later combat/AI) plug in here.
   * Does not broadcast the full GameState.
   */
  simulationTick(tickId: number, _tickMsec: number): void {
    const movement = processMovementTick(this.gameState);
    this.gameState.timers.pollDue(this.clock);
    if (movement.movementSteps.length > 0 || movement.movementCompletions.length > 0) {
      this.movementTickSends += 1;
      const payload: MovementTickPayload = {
        type: "movement_tick",
        matchId: this.matchId,
        simMsec: this.clock.getTicksMsec(),
        tickId,
        movementSteps: movement.movementSteps,
        movementCompletions: movement.movementCompletions,
      };
      this.broadcast(payload);
    }
    const perception = this.gameState.perception.processTick(this.gameState, tickId);
    if (perception.visibilityChanged) {
      this.visibilitySends += 1;
      const vis: VisibilityUpdatePayload = {
        type: "visibility_update",
        matchId: this.matchId,
        simMsec: this.clock.getTicksMsec(),
        tickId,
        sides: this.gameState.perception.visibilityPayload(),
      };
      this.broadcast(vis);
    }
    if (perception.targetUpdates.length > 0) {
      const targets: TargetSyncPayload = {
        type: "target_sync",
        matchId: this.matchId,
        simMsec: this.clock.getTicksMsec(),
        tickId,
        targetUpdates: perception.targetUpdates,
      };
      this.broadcast(targets);
    }
    if (tickId % COMBAT_SCAN_TICKS === 0) {
      const combat = processCombatTick(this.gameState);
      if (combat.shots.length > 0) {
        const payload: CombatShotsPayload = {
          type: "combat_shots",
          matchId: this.matchId,
          simMsec: this.clock.getTicksMsec(),
          tickId,
          shots: combat.shots,
        };
        this.broadcast(payload);
      }
      if (combat.statusUpdates.length > 0) {
        const payload: CombatStatusPayload = {
          type: "combat_status",
          matchId: this.matchId,
          simMsec: this.clock.getTicksMsec(),
          tickId,
          updates: combat.statusUpdates,
        };
        this.broadcast(payload);
      }
    }
  }

  private startDriver(): void {
    const period = this.clock.tickMsec();
    this.lastPumpHrTime = process.hrtime.bigint();
    this.tickTimer = setInterval(() => {
      this.pumpRealtime();
    }, period);
    this.tickTimer.unref?.();
  }

  private stopDriver(): void {
    if (this.tickTimer !== null) {
      clearInterval(this.tickTimer);
      this.tickTimer = null;
    }
  }

  private pumpRealtime(): void {
    const now = process.hrtime.bigint();
    if (this.lastPumpHrTime === null) {
      this.lastPumpHrTime = now;
      return;
    }
    const elapsedMsec = Number(now - this.lastPumpHrTime) / 1_000_000;
    this.lastPumpHrTime = now;
    const pump = this.advanceRealtime(elapsedMsec);
    this.maybeLogDiagnostics(pump);
  }

  private maybeLogDiagnostics(pump: ClockPumpResult): void {
    const simMsec = this.clock.getTicksMsec();
    if (pump.capped) {
      console.warn(
        "[SimClock] catch-up cap match=%s tickId=%d discardedMsec=%d maxCatchup=%d",
        this.matchId,
        this.clock.getTickId(),
        pump.discardedMsec,
        this.clock.maxCatchupTicks,
      );
    }
    if (simMsec - this.lastDiagMsec < DIAG_INTERVAL_MSEC) {
      return;
    }
    this.lastDiagMsec = simMsec;
    console.log(
      "[SimClock] match=%s tickId=%d simMsec=%d phase=%s clients=%d running=%s",
      this.matchId,
      this.clock.getTickId(),
      simMsec,
      this.phase,
      this.clients.size,
      this.clock.isRunning(),
    );
  }

  private sendTo(clientId: string, payload: unknown): void {
    const client = this.clients.get(clientId);
    if (client !== undefined && client.ws.readyState === client.ws.OPEN) {
      client.ws.send(JSON.stringify(payload));
    }
  }

  private broadcast(payload: unknown): void {
    const text = JSON.stringify(payload);
    for (const client of this.clients.values()) {
      if (client.ws.readyState === client.ws.OPEN) {
        client.ws.send(text);
      }
    }
  }
}

export function parseMoveIntent(message: Record<string, unknown>): MoveCommandIntent | null {
  const requestId = typeof message.requestId === "string" ? message.requestId : "";
  if (requestId.length === 0) {
    return null;
  }
  const target = message.targetCell;
  if (typeof target !== "object" || target === null) {
    return null;
  }
  const cell = target as Record<string, unknown>;
  const targetCell: Vec2i = {
    x: Number(cell.x ?? 0),
    y: Number(cell.y ?? 0),
  };
  return {
    type: "move_command",
    matchId: typeof message.matchId === "string" ? message.matchId : MATCH_ID,
    requestId,
    teamId: Number(message.teamId ?? 0),
    soldierId: Number(message.soldierId ?? 0),
    targetCell,
    scope: Number(message.scope ?? 0),
    movementMode: Number(message.movementMode ?? 0),
  };
}

function parseCell(value: unknown): Vec2i | null {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const cell = value as Record<string, unknown>;
  return {
    x: Number(cell.x ?? 0),
    y: Number(cell.y ?? 0),
  };
}

export function parseFaceIntent(message: Record<string, unknown>): FaceCommandIntent | null {
  const requestId = typeof message.requestId === "string" ? message.requestId : "";
  if (requestId.length === 0) {
    return null;
  }
  const targetCell = parseCell(message.targetCell);
  if (targetCell === null) {
    return null;
  }
  let aimWorld: Vec2i | null = null;
  if (message.aimWorld !== undefined && message.aimWorld !== null) {
    aimWorld = parseCell(message.aimWorld);
  }
  return {
    type: "face_command",
    matchId: typeof message.matchId === "string" ? message.matchId : MATCH_ID,
    requestId,
    teamId: Number(message.teamId ?? 0),
    soldierId: Number(message.soldierId ?? 0),
    targetCell,
    scope: Number(message.scope ?? 0),
    aimWorld,
  };
}

export function parsePositionIntent(message: Record<string, unknown>): PositionCommandIntent | null {
  const requestId = typeof message.requestId === "string" ? message.requestId : "";
  if (requestId.length === 0) {
    return null;
  }
  return {
    type: "position_command",
    matchId: typeof message.matchId === "string" ? message.matchId : MATCH_ID,
    requestId,
    teamId: Number(message.teamId ?? 0),
    soldierId: Number(message.soldierId ?? 0),
    positionState: Number(message.positionState ?? 0),
  };
}

export function parseFireControlIntent(
  message: Record<string, unknown>,
): FireControlCommandIntent | null {
  const requestId = typeof message.requestId === "string" ? message.requestId : "";
  if (requestId.length === 0) {
    return null;
  }
  return {
    type: "fire_control_command",
    matchId: typeof message.matchId === "string" ? message.matchId : MATCH_ID,
    requestId,
    teamId: Number(message.teamId ?? 0),
    soldierId: Number(message.soldierId ?? 0),
    fireControlState: Number(message.fireControlState ?? 0),
  };
}

export function parseFireAtIntent(message: Record<string, unknown>): FireAtCommandIntent | null {
  const requestId = typeof message.requestId === "string" ? message.requestId : "";
  if (requestId.length === 0) {
    return null;
  }
  return {
    type: "fire_at_command",
    matchId: typeof message.matchId === "string" ? message.matchId : MATCH_ID,
    requestId,
    teamId: Number(message.teamId ?? 0),
    soldierId: Number(message.soldierId ?? 0),
    targetTeamId: Number(message.targetTeamId ?? -1),
    targetSoldierId: Number(message.targetSoldierId ?? -1),
    scope: Number(message.scope ?? 0),
    targetCell: parseCell(message.targetCell) ?? undefined,
    aimWorld:
      message.aimWorld !== undefined && message.aimWorld !== null
        ? parseCell(message.aimWorld)
        : null,
  };
}
