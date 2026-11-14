import test from "node:test";
import assert from "node:assert/strict";
import {
  clearDevLobbies,
  createDevLobby,
  joinDevLobby,
  leaveDevLobby,
  listDevLobbies,
} from "../src/dev_lobbies";

function create(hostId = "local:host") {
  return createDevLobby({
    host_id: hostId,
    host_display_name: hostId,
    match_name: "Open Game",
    server_url: "ws://127.0.0.1:3000",
    map_id: "ff_farm",
    team_size: 1,
    room_number: 1,
    match_length_sec: 900,
  });
}

test.beforeEach(clearDevLobbies);

test("two distinct local guests fill a dev lobby", () => {
  const lobby = create();
  assert.equal(lobby.current_players, 1);
  assert.equal(lobby.status, "waiting");

  const joined = joinDevLobby(lobby.id, "local:guest");
  assert.equal(joined.current_players, 2);
  assert.equal(joined.status, "in_progress");
  assert.deepEqual(joined.player_ids, ["local:host", "local:guest"]);
});

test("joining twice with the same identity does not increment the lobby", () => {
  const lobby = create();
  joinDevLobby(lobby.id, "local:guest");
  const joinedAgain = joinDevLobby(lobby.id, "local:guest");
  assert.equal(joinedAgain.current_players, 2);
});

test("the singleton game server permits only one active dev lobby", () => {
  create();
  assert.throws(() => create("local:other-host"), /one active lobby/);
});

test("host leaving removes the lobby and guest leaving reopens it", () => {
  const lobby = create();
  joinDevLobby(lobby.id, "local:guest");
  assert.equal(leaveDevLobby(lobby.id, "local:guest"), true);
  assert.equal(listDevLobbies()[0].status, "waiting");
  assert.equal(listDevLobbies()[0].current_players, 1);

  assert.equal(leaveDevLobby(lobby.id, "local:host"), true);
  assert.deepEqual(listDevLobbies(), []);
});
