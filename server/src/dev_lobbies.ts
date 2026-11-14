import { randomUUID } from "node:crypto";

export interface DevLobby {
  id: string;
  host_id: string;
  host_display_name: string;
  match_name: string;
  status: "waiting" | "in_progress" | "finished";
  current_players: number;
  max_players: number;
  team_size: number;
  server_url: string;
  map_id: string;
  room_number: number;
  match_length_sec: number;
  created_at: string;
  player_ids: string[];
}

const lobbies = new Map<string, DevLobby>();

export function listDevLobbies(): DevLobby[] {
  return [...lobbies.values()]
    .filter(lobby => lobby.status !== "finished")
    .sort((a, b) => a.room_number - b.room_number);
}

export function createDevLobby(input: {
  host_id: string;
  host_display_name: string;
  match_name: string;
  server_url: string;
  map_id: string;
  team_size: number;
  room_number: number;
  match_length_sec: number;
}): DevLobby {
  if (input.host_id === "") throw new Error("Missing host identity");
  if (input.room_number < 1 || input.room_number > 16) throw new Error("Invalid room number");

  for (const [id, lobby] of lobbies) {
    if (lobby.host_id === input.host_id) lobbies.delete(id);
    else if (lobby.status !== "finished") {
      throw new Error("This dev server supports one active lobby at a time");
    }
  }

  const teamSize = Math.max(1, Math.min(4, Math.trunc(input.team_size)));
  const lobby: DevLobby = {
    id: randomUUID(),
    host_id: input.host_id,
    host_display_name: input.host_display_name || input.host_id,
    match_name: input.match_name || "Dev Game",
    status: "waiting",
    current_players: 1,
    max_players: teamSize * 2,
    team_size: teamSize,
    server_url: input.server_url,
    map_id: input.map_id || "ff_farm",
    room_number: input.room_number,
    match_length_sec: input.match_length_sec || 900,
    created_at: new Date().toISOString(),
    player_ids: [input.host_id],
  };
  lobbies.set(lobby.id, lobby);
  return lobby;
}

export function joinDevLobby(lobbyId: string, playerId: string): DevLobby {
  const lobby = lobbies.get(lobbyId);
  if (!lobby || lobby.status === "finished") throw new Error("Lobby not found");
  if (playerId === "") throw new Error("Missing player identity");
  if (lobby.player_ids.includes(playerId)) return lobby;
  if (lobby.current_players >= lobby.max_players) throw new Error("Lobby is full");

  lobby.player_ids.push(playerId);
  lobby.current_players = lobby.player_ids.length;
  if (lobby.current_players >= lobby.max_players) lobby.status = "in_progress";
  return lobby;
}

export function leaveDevLobby(lobbyId: string, playerId: string): boolean {
  const lobby = lobbies.get(lobbyId);
  if (!lobby) return false;
  if (lobby.host_id === playerId) {
    lobbies.delete(lobbyId);
    return true;
  }

  const index = lobby.player_ids.indexOf(playerId);
  if (index !== -1) lobby.player_ids.splice(index, 1);
  lobby.current_players = lobby.player_ids.length;
  if (lobby.status === "in_progress") lobby.status = "waiting";
  return true;
}

export function updateDevLobbyStatus(lobbyId: string, status: DevLobby["status"]): DevLobby {
  const lobby = lobbies.get(lobbyId);
  if (!lobby) throw new Error("Lobby not found");
  lobby.status = status;
  if (status === "finished") lobbies.delete(lobbyId);
  return lobby;
}

export function clearDevLobbies(): void {
  lobbies.clear();
}
