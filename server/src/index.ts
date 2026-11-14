import { WebSocketServer, WebSocket, type RawData } from "ws";
import {
  createServer,
  type IncomingMessage as HttpIncomingMessage,
  type ServerResponse,
} from "node:http";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve, extname, join, sep } from "node:path";
import { existsSync, realpathSync } from "node:fs";
import {
  LocalMatch,
  parseFaceIntent,
  parseFireAtIntent,
  parseFireControlIntent,
  parseGrenadeIntent,
  parseMoveIntent,
  parsePositionIntent,
  type MatchEndedInfo,
  type MatchOptions,
} from "./match";
import { getUserId } from "./supabase_auth";
import {
  type SideName,
  bothSidesAssigned,
  getAssignedClients,
  getClient,
  getClientByUserId,
  getTeamSize,
  parseSideName,
  registerClient,
  removeClient,
  requestSide,
  resetSides,
  setClientRegimentId,
  setClientUserId,
  setTeamSize,
  sideCount,
} from "./side_ownership";
import { recordMatchResult, recordPlayerResult, distributeCoPP, getPlayerFlags, setActiveMatch, clearActiveMatch, saveReplay, finishAllLobbies } from "./supabase_client";
import {
  MATCH_ID,
  sideToTeamId,
  teamIdToSide,
  TEAM_USA,
  TEAM_GERMANY,
} from "./types";
import {
  WINNER_USA,
  WINNER_GERMANY,
  WINNER_DRAW,
  END_CAUSE_TIME_GONE,
  END_CAUSE_EXTERMINATION,
  END_CAUSE_FORFEIT,
} from "./scenario_rules";
import {
  createDevLobby,
  joinDevLobby,
  leaveDevLobby,
  listDevLobbies,
  updateDevLobbyStatus,
  type DevLobby,
} from "./dev_lobbies";

const PORT = parseInt(process.env.PORT ?? "3000", 10);
let match = new LocalMatch();
wireMatchCallbacks(match);

/** Called by the match callback when a match ends. Records results in Supabase. */
function handleMatchEnded(info: MatchEndedInfo): void {
  for (const [, reconnect] of pendingReconnects) {
    clearTimeout(reconnect.timer);
  }
  pendingReconnects.clear();

  finishAllLobbies().catch(err => console.error("[MatchEnd] Lobby cleanup failed:", err));

  const usaUserIds: string[] = [];
  const germanyUserIds: string[] = [];

  for (const [clientId, teamId] of info.clientTeams) {
    const record = getClient(clientId);
    if (!record?.userId) continue;
    if (teamId === TEAM_USA) usaUserIds.push(record.userId);
    if (teamId === TEAM_GERMANY) germanyUserIds.push(record.userId);
  }

  if (usaUserIds.length === 0 || germanyUserIds.length === 0) {
    console.log("[MatchEnd] Skipping result recording: missing authenticated player(s). USA=%s GERMANY=%s",
      usaUserIds.join(",") || "(none)", germanyUserIds.join(",") || "(none)");
    return;
  }

  const isDraw = info.winner === WINNER_DRAW;
  const usaWon = info.winner === WINNER_USA;
  const germanyWon = info.winner === WINNER_GERMANY;

  const endCauseStr = info.endCause === END_CAUSE_FORFEIT ? "forfeit"
    : info.endCause === END_CAUSE_EXTERMINATION ? "extermination" : "time";

  const usaPP = isTrainingMatch ? 0 : info.usaPPEarned;
  const germanyPP = isTrainingMatch ? 0 : info.germanyPPEarned;
  const currentTeamSize = getTeamSize();
  const dbMatchId = info.dbMatchId;
  const durationSec = Math.round(info.durationMs / 1000);
  const metadata = { mapId: info.mapId, teamSize: currentTeamSize, durationSeconds: durationSec };

  console.log("[MatchEnd] id=%s cause=%s winner=%d map=%s teamSize=%d duration=%ds PP: USA=%d GERMANY=%d",
    dbMatchId, endCauseStr, info.winner, info.mapId, currentTeamSize, durationSec, usaPP, germanyPP);

  // Save replay data (non-blocking)
  if (info.replayData) {
    const rd = info.replayData;
    saveReplay({
      matchId: dbMatchId,
      mapId: info.mapId,
      mapWidth: rd.initialState.map.width,
      mapHeight: rd.initialState.map.height,
      teamSize: currentTeamSize,
      initialState: rd.initialState,
      events: rd.events,
      durationMs: rd.durationMs,
      eventCount: rd.events.length,
    }).catch(err => console.error("[MatchEnd] Replay save failed:", err));
  }

  if (currentTeamSize <= 1 && usaUserIds.length === 1 && germanyUserIds.length === 1) {
    recordMatchResult({
      matchId: dbMatchId,
      player1Id: usaUserIds[0],
      player1Team: "USA",
      player1Won: usaWon,
      player1Draw: isDraw,
      player1Kill: info.usaKillPoints,
      player1Terrain: info.usaTerrainPoints,
      player1Total: info.usaTotalPoints,
      player1Kills: info.usaKills,
      player1Pp: usaPP,
      player2Id: germanyUserIds[0],
      player2Team: "GERMANY",
      player2Won: germanyWon,
      player2Draw: isDraw,
      player2Kill: info.germanyKillPoints,
      player2Terrain: info.germanyTerrainPoints,
      player2Total: info.germanyTotalPoints,
      player2Kills: info.germanyKills,
      player2Pp: germanyPP,
      endCause: endCauseStr,
      ...metadata,
    }).then(() => {
      return Promise.all([
        distributeCoPP(dbMatchId, usaUserIds[0], usaPP),
        distributeCoPP(dbMatchId, germanyUserIds[0], germanyPP),
      ]);
    }).catch((err) => {
      console.error("[MatchEnd] Failed to record result:", err);
    });
  } else {
    const promises: Promise<void>[] = [];
    for (const uid of usaUserIds) {
      const opponentId = germanyUserIds[0] ?? null;
      promises.push(recordPlayerResult({
        matchId: dbMatchId,
        playerId: uid,
        team: "USA",
        won: usaWon,
        draw: isDraw,
        kills: info.usaKills,
        killPoints: info.usaKillPoints,
        terrainPoints: info.usaTerrainPoints,
        totalPoints: info.usaTotalPoints,
        endCause: endCauseStr,
        opponentId: opponentId,
        pp: usaPP,
        ...metadata,
      }));
      promises.push(distributeCoPP(dbMatchId, uid, usaPP));
    }
    for (const uid of germanyUserIds) {
      const opponentId = usaUserIds[0] ?? null;
      promises.push(recordPlayerResult({
        matchId: dbMatchId,
        playerId: uid,
        team: "GERMANY",
        won: germanyWon,
        draw: isDraw,
        kills: info.germanyKills,
        killPoints: info.germanyKillPoints,
        terrainPoints: info.germanyTerrainPoints,
        totalPoints: info.germanyTotalPoints,
        endCause: endCauseStr,
        opponentId: opponentId,
        pp: germanyPP,
        ...metadata,
      }));
      promises.push(distributeCoPP(dbMatchId, uid, germanyPP));
    }
    Promise.all(promises).catch((err) => {
      console.error("[MatchEnd] Failed to record team result:", err);
    });
  }
}

/** Wire the match-ended callback on a fresh match instance. */
function wireMatchCallbacks(m: LocalMatch): void {
  m.onMatchEnded = handleMatchEnded;
}

/** Reset to a fresh match when the previous one has ended. */
function ensureFreshMatch(): void {
  if (match.matchPhase === "ended") {
    for (const [userId, reconnect] of pendingReconnects) {
      clearTimeout(reconnect.timer);
      clearActiveMatch(userId);
      adminUserIds.delete(userId);
      moderatorUserIds.delete(userId);
      removeClient(reconnect.oldClientId);
    }
    pendingReconnects.clear();
    console.log("Previous match ended, creating a fresh match.");
    resetSides();
    setTeamSize(1);
    isTrainingMatch = false;
    matchLengthSec = 0;
    isRegimentalMatch = false;
    regimentTeamMap.clear();
    match = new LocalMatch();
    wireMatchCallbacks(match);
  }
}

interface IncomingMessage {
  type?: string;
  [key: string]: unknown;
}

function safeParseJson(raw: string): IncomingMessage | null {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return null;
    }
    return parsed as IncomingMessage;
  } catch {
    return null;
  }
}

function sendJson(ws: WebSocket, payload: unknown): void {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

// Track which userIds are admins or moderators (set on hello, used for kick validation)
const adminUserIds = new Set<string>();
const moderatorUserIds = new Set<string>();

// Training match flag — set from client hello, suppresses PP awards
let isTrainingMatch = false;
// Match length override — set from client hello (600/900/1200 seconds)
let matchLengthSec = 0;
// Regimental match — regiment IDs mapped to teams for auto-assignment
let isRegimentalMatch = false;
const regimentTeamMap = new Map<string, number>();

const RECONNECT_WINDOW_SEC = 90;

interface PendingReconnect {
  userId: string;
  side: SideName;
  teamId: number;
  oldClientId: string;
  timer: NodeJS.Timeout;
  disconnectedAt: number;
}

const pendingReconnects = new Map<string, PendingReconnect>();

function broadcastToAssigned(payload: unknown, excludeClientId?: string): void {
  for (const rec of getAssignedClients()) {
    if (rec.clientId !== excludeClientId) {
      sendJson(rec.ws, payload);
    }
  }
}

async function handleMessage(ws: WebSocket, clientId: string, raw: string): Promise<void> {
  const message = safeParseJson(raw);
  if (message === null) {
    console.log("Message is not valid JSON object");
    return;
  }

  if (message.type === "ping") {
    sendJson(ws, { type: "pong", serverTime: Date.now() });
    return;
  }

  if (message.type === "hello") {
    ensureFreshMatch();
    const clientName =
      typeof message.clientName === "string" ? message.clientName : "Unknown client";
    console.log("Hello from %s (%s)", clientName, clientId);

    // Optional Supabase auth: if the client sends an authToken, verify it
    // and associate the user ID with this connection.  LAN play works
    // without a token.
    let userId: string | null = null;
    let takeover: { side: SideName; teamId: number } | null = null;
    if (typeof message.authToken === "string" && message.authToken !== "") {
      userId = getUserId(message.authToken);
      if (userId !== null) {
        const flags = await getPlayerFlags(userId);

        if (flags?.is_banned) {
          const banReason = flags.ban_reason ?? "No reason provided";
          console.log("Banned user %s (%s) rejected: %s", userId, clientName, banReason);
          sendJson(ws, { type: "banned", reason: banReason });
          ws.close();
          return;
        }

        // Kick any existing connection with the same userId (prevents one
        // account from holding both sides). Skip if there's a pending
        // reconnect - that path is handled below.
        if (!pendingReconnects.has(userId)) {
          const existing = getClientByUserId(userId);
          if (existing && existing.clientId !== clientId) {
            // No server heartbeat, so after a network drop the old socket can
            // still look open when the client reconnects. Keep the side.
            if (existing.assignedSide !== null && match.matchPhase === "running") {
              takeover = { side: existing.assignedSide, teamId: sideToTeamId(existing.assignedSide) };
              console.log("[Hello] User %s reconnected while old client %s still open; taking over %s",
                userId, existing.clientId, existing.assignedSide);
            } else {
              console.log("[Hello] Duplicate connection for user %s, kicking old client %s", userId, existing.clientId);
            }
            sendJson(existing.ws, { type: "kicked", reason: "Connected from another session" });
            removeClient(existing.clientId);
            match.removeClient(existing.clientId);
            existing.ws.close();
          }
        }

        setClientUserId(clientId, userId);
        console.log("Authenticated user %s (%s)", userId, clientName);

        setActiveMatch(userId, MATCH_ID);

        if (flags?.is_admin) adminUserIds.add(userId);
        if (flags?.is_moderator) moderatorUserIds.add(userId);
      } else {
        console.log("Auth token invalid for %s; continuing as guest.", clientName);
      }
    }

    if (message.isTraining === true && match.matchPhase === "created"
        && sideCount("USA") === 0 && sideCount("GERMANY") === 0) {
      isTrainingMatch = true;
      console.log("[Hello] Training match - PP awards disabled.");
    }

    if (message.isRegimental === true) {
      isRegimentalMatch = true;
      const regId = typeof message.regimentId === "string" ? message.regimentId : "";
      if (regId !== "") {
        setClientRegimentId(clientId, regId);
        if (!regimentTeamMap.has(regId)) {
          const team = regimentTeamMap.size === 0 ? TEAM_USA : TEAM_GERMANY;
          regimentTeamMap.set(regId, team);
          console.log("[Hello] Regiment %s assigned to team %d.", regId, team);
        }
      }
    }

    const VALID_MATCH_LENGTHS = [600, 900, 1200];
    const reqLength = typeof message.matchLengthSec === "number" ? message.matchLengthSec : 0;
    if (reqLength > 0 && VALID_MATCH_LENGTHS.includes(reqLength) && match.matchPhase === "created") {
      matchLengthSec = reqLength;
      console.log("[Hello] Match length set to %d seconds.", matchLengthSec);
    }

    // --- Reconnect detection ---
    let resume: { side: SideName; teamId: number } | null = takeover;
    const fromPending = userId !== null && pendingReconnects.has(userId);
    if (fromPending) {
      const reconnect = pendingReconnects.get(userId!)!;
      clearTimeout(reconnect.timer);
      pendingReconnects.delete(userId!);

      // Remove ghost client, reassign side/team to new connection
      match.removeClient(reconnect.oldClientId);
      removeClient(reconnect.oldClientId);
      resume = { side: reconnect.side, teamId: reconnect.teamId };
    }

    if (resume !== null) {
      const sideResult = requestSide(clientId, resume.side);
      if (sideResult.ok) {
        // Nothing else attaches a reconnecting socket to the match: without this it gets
        // no match messages, its orders are refused, and (fog of war) its snapshot has
        // no team to filter for.
        match.attachClient(clientId, ws);
        match.setClientTeam(clientId, resume.teamId);
        console.log("[Reconnect] Player %s reconnected as %s (new clientId=%s)", userId, resume.side, clientId);

        sendJson(ws, {
          type: "welcome",
          message: "Reconnected to match",
          clientId,
          matchId: MATCH_ID,
          userId,
          teamSize: getTeamSize(),
          reconnected: true,
        });
        sendJson(ws, {
          type: "side_assigned",
          side: resume.side,
          matchId: MATCH_ID,
          teamId: resume.teamId,
          usaCount: sideCount("USA"),
          germanyCount: sideCount("GERMANY"),
          teamSize: getTeamSize(),
        });
        sendJson(ws, { type: "match_ready" });
        match.sendSnapshot(ws);

        if (fromPending) {
          broadcastToAssigned({ type: "player_reconnected", side: resume.side }, clientId);
        }
      } else {
        console.error("[Reconnect] Failed to reassign side %s for %s: %s", resume.side, userId, sideResult.reason);
      }
      return;
    }

    const requestedMap = typeof message.mapId === "string" ? message.mapId : "";
    if (requestedMap !== "" && !/^[a-zA-Z0-9_-]+$/.test(requestedMap)) {
      console.log("Rejected invalid mapId: %s", requestedMap.slice(0, 60));
    } else if (requestedMap !== "" && match.matchPhase === "created" && requestedMap !== match.gameState.map.mapId) {
      try {
        resetSides();
        const opts: MatchOptions = {};
        if (matchLengthSec > 0) opts.scenarioTimeSec = matchLengthSec;
        match = new LocalMatch(requestedMap, opts);
        wireMatchCallbacks(match);
        console.log("Map changed to %s by client request", requestedMap);
      } catch (err) {
        console.error("Failed to load requested map %s, keeping %s: %s", requestedMap, match.gameState.map.mapId, (err as Error).message);
      }
    }

    // Team size: first client to connect with a teamSize sets it.
    const requestedTeamSize = typeof message.teamSize === "number" ? message.teamSize : 0;
    if (requestedTeamSize > 0 && match.matchPhase === "created") {
      const supported = match.gameState.map.metadata.supportedTeamSizes;
      if (supported.includes(requestedTeamSize)) {
        setTeamSize(requestedTeamSize);
        console.log("Team size set to %d by client request", requestedTeamSize);
      } else {
        console.log("Requested team size %d not supported by map %s (supported: %s)",
          requestedTeamSize, match.gameState.map.mapId, supported.join(","));
      }
    }

    if (matchLengthSec > 0 && match.matchPhase === "created") {
      match.setScenarioTime(matchLengthSec);
    }

    match.attachClient(clientId, ws);
    sendJson(ws, {
      type: "welcome",
      message: "Hello Godot client",
      clientId,
      matchId: MATCH_ID,
      userId,
      teamSize: getTeamSize(),
    });
    return;
  }

  // Admin: kick a player from the active game
  if (message.type === "kick_player") {
    const record = getClient(clientId);
    if (!record?.userId || (!adminUserIds.has(record.userId) && !moderatorUserIds.has(record.userId))) {
      sendJson(ws, { type: "kick_result", success: false, reason: "Not authorized" });
      return;
    }

    const targetUserId = typeof message.targetUserId === "string" ? message.targetUserId : "";
    const kickReason = typeof message.reason === "string" ? message.reason : "Kicked by admin";

    if (targetUserId === "") {
      sendJson(ws, { type: "kick_result", success: false, reason: "No target specified" });
      return;
    }

    const target = getClientByUserId(targetUserId);
    if (!target) {
      sendJson(ws, { type: "kick_result", success: false, reason: "Player not connected" });
      return;
    }

    // Moderators cannot kick admins; admins can kick anyone
    const kickerIsAdmin = adminUserIds.has(record.userId);
    if (!kickerIsAdmin && adminUserIds.has(targetUserId)) {
      sendJson(ws, { type: "kick_result", success: false, reason: "Cannot kick an admin" });
      return;
    }

    const kickerRole = kickerIsAdmin ? "Admin" : "Moderator";
    console.log("%s %s kicking player %s: %s", kickerRole, record.userId, targetUserId, kickReason);
    sendJson(target.ws, { type: "kicked", reason: kickReason });

    // Trigger forfeit BEFORE removing records so handleMatchEnded can look up
    // both players' userIds for PP recording.
    const kickedSide = target.assignedSide;
    const kickedWs = target.ws;
    if (kickedSide !== null && match.matchPhase === "running") {
      const kickedTeamId = sideToTeamId(kickedSide);
      console.log("Kicked player was on %s, ending match as forfeit.", kickedSide);
      match.forceEndMatchForfeit(kickedTeamId);
    }
    // Now clean up
    if (target.userId) {
      clearActiveMatch(target.userId);
      adminUserIds.delete(target.userId);
      moderatorUserIds.delete(target.userId);
    }
    match.removeClient(target.clientId);
    removeClient(target.clientId);

    // Delay socket close to let the kicked message arrive before the close frame
    setTimeout(() => { kickedWs.close(); }, 500);

    sendJson(ws, { type: "kick_result", success: true });
    return;
  }

  if (message.type === "leave_match") {
    const record = getClient(clientId);
    if (!record) return;

    // Cancel any pending reconnect for this player
    if (record.userId && pendingReconnects.has(record.userId)) {
      const reconnect = pendingReconnects.get(record.userId)!;
      clearTimeout(reconnect.timer);
      pendingReconnects.delete(record.userId);
    }

    // Intentional quit — immediate forfeit, no reconnect window
    const leaveSide = record.assignedSide;
    if (leaveSide !== null && match.matchPhase === "running") {
      const leaveTeamId = sideToTeamId(leaveSide);
      console.log("[LeaveMatch] Player %s (%s) intentionally left, ending as forfeit.", record.userId ?? clientId, leaveSide);
      match.forceEndMatchForfeit(leaveTeamId);
    }

    if (record.userId) {
      clearActiveMatch(record.userId);
      adminUserIds.delete(record.userId);
      moderatorUserIds.delete(record.userId);
    }
    removeClient(clientId);
    match.removeClient(clientId);

    sendJson(ws, { type: "leave_confirmed" });
    setTimeout(() => { ws.close(); }, 500);
    return;
  }

  if (message.type === "request_side") {
    let side = parseSideName(message.side);
    if (side === null) {
      sendJson(ws, { type: "side_denied", reason: "Invalid side" });
      return;
    }

    const record = getClient(clientId);
    if (record?.userId) {
      const existing = getClientByUserId(record.userId);
      if (existing && existing.clientId !== clientId && existing.assignedSide !== null) {
        sendJson(ws, { type: "side_denied", reason: "Account already has a side assigned" });
        return;
      }
    }

    if (isRegimentalMatch) {
      const regId = record?.regimentId ?? "";
      const assignedTeam = regId !== "" ? regimentTeamMap.get(regId) : undefined;
      if (assignedTeam !== undefined) {
        side = assignedTeam === TEAM_USA ? "USA" : "GERMANY";
        console.log("Regimental match: forcing %s to %s (regiment %s)", clientId, side, regId);
      }
    }

    console.log("Client requested %s (%s)", side, clientId);
    const result = requestSide(clientId, side);
    if (!result.ok) {
      sendJson(ws, { type: "side_denied", reason: result.reason });
      return;
    }

    const teamId = sideToTeamId(result.side);
    match.setClientTeam(clientId, teamId);
    sendJson(ws, {
      type: "side_assigned",
      side: result.side,
      matchId: MATCH_ID,
      teamId,
      usaCount: sideCount("USA"),
      germanyCount: sideCount("GERMANY"),
      teamSize: getTeamSize(),
    });

    // Wait until both sides are assigned before starting.
    if (bothSidesAssigned()) {
      for (const rec of getAssignedClients()) {
        sendJson(rec.ws, { type: "match_ready" });
        match.sendSnapshot(rec.ws);
      }
    }
    return;
  }

  if (message.type === "join_match") {
    match.attachClient(clientId, ws);
    match.sendSnapshot(ws);
    return;
  }

  if (message.type === "move_command") {
    const intent = parseMoveIntent(message);
    if (intent === null) {
      sendJson(ws, {
        type: "move_result",
        matchId: MATCH_ID,
        requestId: typeof message.requestId === "string" ? message.requestId : "",
        success: false,
        statusMessage: "Invalid move command.",
        moveOrders: [],
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    match.handleMove(clientId, intent);
    return;
  }

  if (message.type === "face_command") {
    const intent = parseFaceIntent(message);
    if (intent === null) {
      sendJson(ws, {
        type: "face_result",
        matchId: MATCH_ID,
        requestId: typeof message.requestId === "string" ? message.requestId : "",
        success: false,
        statusMessage: "Invalid face command.",
        faceUpdates: [],
      });
      return;
    }
    match.handleFace(clientId, intent);
    return;
  }

  if (message.type === "position_command") {
    const intent = parsePositionIntent(message);
    if (intent === null) {
      sendJson(ws, {
        type: "position_result",
        matchId: MATCH_ID,
        requestId: typeof message.requestId === "string" ? message.requestId : "",
        success: false,
        statusMessage: "Invalid position command.",
        positionState: 0,
        movementHalts: [],
        stanceTransitionOrders: [],
        soldierUpdates: [],
      });
      return;
    }
    match.handlePosition(clientId, intent);
    return;
  }

  if (message.type === "fire_control_command") {
    const intent = parseFireControlIntent(message);
    if (intent === null) {
      sendJson(ws, {
        type: "fire_control_result",
        matchId: MATCH_ID,
        requestId: typeof message.requestId === "string" ? message.requestId : "",
        success: false,
        statusMessage: "Invalid fire-control command.",
        syncFireAtUi: false,
        targetUpdates: [],
      });
      return;
    }
    match.handleFireControl(clientId, intent);
    return;
  }

  if (message.type === "fire_at_command") {
    const intent = parseFireAtIntent(message);
    if (intent === null) {
      sendJson(ws, {
        type: "fire_at_result",
        matchId: MATCH_ID,
        requestId: typeof message.requestId === "string" ? message.requestId : "",
        success: false,
        statusMessage: "Invalid Fire At command.",
        syncFireAtUi: false,
        movementHalts: [],
        faceUpdates: [],
        targetUpdates: [],
      });
      return;
    }
    match.handleFireAt(clientId, intent);
    return;
  }

  if (message.type === "grenade_command") {
    const intent = parseGrenadeIntent(message);
    if (intent === null) {
      sendJson(ws, {
        type: "grenade_thrown",
        matchId: MATCH_ID,
        requestId: typeof message.requestId === "string" ? message.requestId : "",
        success: false,
        statusMessage: "Invalid grenade command.",
        throwerTeamId: 0,
        throwerId: 0,
        targetCell: { x: 0, y: 0 },
        grenadeCount: 0,
        facing: { x: 0, y: 0 },
      });
      return;
    }
    match.handleGrenade(clientId, intent);
    return;
  }

  if (message.type === "client_ready") {
    match.handleClientReady(clientId);
  }
}

const HOST = process.env.BIND_HOST ?? "0.0.0.0";

// ── Static file serving ─────────────────────────────────────────────
const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css",
  ".js": "application/javascript",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".webp": "image/webp",
  ".zip": "application/zip",
  ".exe": "application/octet-stream",
  ".pck": "application/octet-stream",
};

const WEBSITE_DIR = resolve(__dirname, "../../website/dist");
const BUILDS_DIR = resolve(__dirname, "../../builds");
const hasWebsite = existsSync(WEBSITE_DIR);
const hasBuilds = existsSync(BUILDS_DIR);
if (hasWebsite) {
  console.log(`Serving website from ${WEBSITE_DIR}`);
} else {
  console.log(`No website directory at ${WEBSITE_DIR} — HTTP serves health check only`);
}
if (hasBuilds) {
  console.log(`Serving game builds from ${BUILDS_DIR}`);
}

function isLoopbackRequest(req: HttpIncomingMessage): boolean {
  const address = req.socket.remoteAddress ?? "";
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

async function readJsonBody(req: HttpIncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > 64 * 1024) throw new Error("Request body too large");
    chunks.push(buffer);
  }
  if (chunks.length === 0) return {};
  const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("JSON object required");
  }
  return parsed as Record<string, unknown>;
}

function sendHttpJson(res: ServerResponse, status: number, value: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(value));
}

async function serveDevLobbies(
  req: HttpIncomingMessage,
  res: ServerResponse,
  parsedUrl: URL,
): Promise<boolean> {
  if (!parsedUrl.pathname.startsWith("/dev/lobbies")) return false;
  if (!isLoopbackRequest(req)) {
    res.writeHead(404);
    res.end("Not Found");
    return true;
  }

  try {
    if (parsedUrl.pathname === "/dev/lobbies" && req.method === "GET") {
      sendHttpJson(res, 200, listDevLobbies());
      return true;
    }

    if (parsedUrl.pathname === "/dev/lobbies" && req.method === "POST") {
      const body = await readJsonBody(req);
      const lobby = createDevLobby({
        host_id: String(body.host_id ?? ""),
        host_display_name: String(body.host_display_name ?? ""),
        match_name: String(body.match_name ?? ""),
        server_url: String(body.server_url ?? ""),
        map_id: String(body.map_id ?? "ff_farm"),
        team_size: Number(body.team_size ?? 1),
        room_number: Number(body.room_number ?? 0),
        match_length_sec: Number(body.match_length_sec ?? 900),
      });
      sendHttpJson(res, 201, [lobby]);
      return true;
    }

    const joinMatch = parsedUrl.pathname.match(/^\/dev\/lobbies\/([^/]+)\/join$/);
    if (joinMatch && req.method === "POST") {
      const body = await readJsonBody(req);
      const lobby = joinDevLobby(decodeURIComponent(joinMatch[1]), String(body.player_id ?? ""));
      sendHttpJson(res, 200, [lobby]);
      return true;
    }

    const lobbyMatch = parsedUrl.pathname.match(/^\/dev\/lobbies\/([^/]+)$/);
    if (lobbyMatch && req.method === "DELETE") {
      const playerId = parsedUrl.searchParams.get("player_id") ?? "";
      leaveDevLobby(decodeURIComponent(lobbyMatch[1]), playerId);
      res.writeHead(204, { "Cache-Control": "no-store" });
      res.end();
      return true;
    }
    if (lobbyMatch && req.method === "PATCH") {
      const body = await readJsonBody(req);
      const status = String(body.status ?? "") as DevLobby["status"];
      if (!["waiting", "in_progress", "finished"].includes(status)) {
        throw new Error("Invalid lobby status");
      }
      sendHttpJson(res, 200, [updateDevLobbyStatus(decodeURIComponent(lobbyMatch[1]), status)]);
      return true;
    }

    res.writeHead(405, { Allow: "GET, POST, PATCH, DELETE" });
    res.end("Method Not Allowed");
    return true;
  } catch (error) {
    sendHttpJson(res, 409, { error: error instanceof Error ? error.message : "Dev lobby request failed" });
    return true;
  }
}

async function serveStatic(req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse) {
  const url = req.url ?? "/";
  const parsedUrl = new URL(url, "http://localhost");

  if (await serveDevLobbies(req, res, parsedUrl)) return;

  if (url === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
    return;
  }

  if (hasBuilds && url.startsWith("/builds/")) {
    const buildFile = join(BUILDS_DIR, url.slice("/builds/".length));
    try {
      const realPath = realpathSync(buildFile);
      if (!realPath.startsWith(realpathSync(BUILDS_DIR) + sep)) {
        res.writeHead(403);
        res.end("Forbidden");
        return;
      }
      const data = await readFile(buildFile);
      const ext = extname(buildFile);
      const contentType = MIME_TYPES[ext] ?? "application/octet-stream";
      const filename = buildFile.split(/[\\/]/).pop() ?? "download";
      res.writeHead(200, {
        "Content-Type": contentType,
        "Content-Disposition": `attachment; filename="${filename}"`,
        "Content-Length": data.byteLength.toString(),
        "Cache-Control": "public, max-age=3600",
      });
      res.end(data);
    } catch {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not Found");
    }
    return;
  }

  if (!hasWebsite) {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
    return;
  }

  let filePath: string;
  if (url === "/" || url === "/index.html") {
    filePath = join(WEBSITE_DIR, "index.html");
  } else {
    filePath = join(WEBSITE_DIR, url);
  }

  try {
    const realPath = realpathSync(filePath);
    if (!realPath.startsWith(realpathSync(WEBSITE_DIR) + sep)) {
      res.writeHead(403);
      res.end("Forbidden");
      return;
    }
  } catch {
    // File doesn't exist — fall through to SPA fallback
  }

  try {
    const data = await readFile(filePath);
    const ext = extname(filePath);
    const contentType = MIME_TYPES[ext] ?? "application/octet-stream";
    const cacheControl = ext === ".html" || ext === ""
      ? "no-cache"
      : "public, max-age=31536000, immutable";
    res.writeHead(200, { "Content-Type": contentType, "Cache-Control": cacheControl });
    res.end(data);
  } catch {
    // SPA fallback: serve index.html for client-side routing
    try {
      const indexData = await readFile(join(WEBSITE_DIR, "index.html"));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" });
      res.end(indexData);
    } catch {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not Found");
    }
  }
}

// HTTP server handles website + health checks; WebSocket upgrades attach to it.
const httpServer = createServer(serveStatic);

const wss = new WebSocketServer({ server: httpServer, maxPayload: 64 * 1024 });

httpServer.listen(PORT, HOST, () => {
  console.log(`Chain Revival multiplayer server running on ws://${HOST}:${PORT}`);
  console.log(`Authoritative match ${MATCH_ID} ready`);
  if (HOST === "0.0.0.0") {
    console.log("LAN enabled — other machines can connect using this PC's IP address.");
  }
  finishAllLobbies().catch(err => console.error("[Startup] Lobby cleanup failed:", err));
});

wss.on("connection", (ws: WebSocket) => {
  const clientId = randomUUID();
  registerClient(ws, clientId);
  console.log("Client connected (%s)", clientId);

  ws.on("message", (data: RawData) => {
    handleMessage(ws, clientId, data.toString());
  });

  ws.on("close", () => {
    const record = getClient(clientId);
    const disconnectedSide = record?.assignedSide ?? null;
    const disconnectedUserId = record?.userId ?? null;
    console.log("[Disconnect] clientId=%s userId=%s side=%s matchPhase=%s",
      clientId, disconnectedUserId ?? "null", disconnectedSide ?? "null", match.matchPhase);

    // Authenticated player disconnects during a running match → reconnect window
    if (disconnectedUserId && disconnectedSide !== null && match.matchPhase === "running") {
      const disconnectedTeamId = sideToTeamId(disconnectedSide);
      console.log("[Disconnect] Player %s (%s) disconnected during match. Holding slot for %ds.",
        disconnectedUserId, disconnectedSide, RECONNECT_WINDOW_SEC);

      // Detach from match broadcasts but keep side_ownership record (ghost blocks slot)
      // and the team, so a forfeit after the window still records both players.
      match.holdClientTeam(clientId);

      // Notify remaining players
      broadcastToAssigned({
        type: "player_disconnected",
        side: disconnectedSide,
        reconnectWindowSec: RECONNECT_WINDOW_SEC,
      });

      const timer = setTimeout(() => {
        pendingReconnects.delete(disconnectedUserId);
        console.log("[Reconnect] Window expired for %s (%s). Forfeiting.", disconnectedUserId, disconnectedSide);

        if (match.matchPhase === "running") {
          match.forceEndMatchForfeit(disconnectedTeamId);
        }

        clearActiveMatch(disconnectedUserId);
        adminUserIds.delete(disconnectedUserId);
        moderatorUserIds.delete(disconnectedUserId);
        removeClient(clientId);
      }, RECONNECT_WINDOW_SEC * 1000);

      pendingReconnects.set(disconnectedUserId, {
        userId: disconnectedUserId,
        side: disconnectedSide as SideName,
        teamId: disconnectedTeamId,
        oldClientId: clientId,
        timer,
        disconnectedAt: Date.now(),
      });
      return;
    }

    // Unauthenticated player or non-running match: immediate cleanup
    if (disconnectedSide !== null && match.matchPhase === "running") {
      const disconnectedTeamId = sideToTeamId(disconnectedSide);
      console.log("[Disconnect] IMMEDIATE FORFEIT: side=%s userId=%s matchPhase=%s (no reconnect window - player was %s)",
        disconnectedSide, disconnectedUserId ?? "null", match.matchPhase,
        disconnectedUserId ? "authenticated but condition failed" : "unauthenticated");
      match.forceEndMatchForfeit(disconnectedTeamId);
    }

    if (record?.userId) {
      clearActiveMatch(record.userId);
      adminUserIds.delete(record.userId);
      moderatorUserIds.delete(record.userId);
    }
    removeClient(clientId);
    match.removeClient(clientId);
    console.log("Client disconnected (%s)", clientId);
  });

  ws.on("error", (error: Error) => {
    console.error("WebSocket error (%s): %s", clientId, error.message);
  });
});

wss.on("error", (error: Error) => {
  console.error("Server error:", error.message);
});
