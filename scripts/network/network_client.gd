extends Node
## WebSocket client for LOCAL_MULTIPLAYER.
##
## Godot does NOT start the Node server. Run it manually first:
##   cd server && npm run dev
## Then choose Multiplayer — this client connects to ws://localhost:3000.

const SERVER_URL := "ws://localhost:3000"
const CLIENT_NAME := "Godot Client"
const DEFAULT_CONNECT_TIMEOUT_SEC := 5.0
const DEFAULT_SIDE_REQUEST_TIMEOUT_SEC := 5.0
const DEFAULT_SNAPSHOT_TIMEOUT_SEC := 5.0
const DEFAULT_MOVE_TIMEOUT_SEC := 3.0
const ActionResultClass := preload("res://scripts/core/action_result.gd")
const MoveCommandClass := preload("res://scripts/commands/move_command.gd")
const FaceCommandClass := preload("res://scripts/commands/face_command.gd")
const PositionCommandClass := preload("res://scripts/commands/position_command.gd")
const FireControlCommandClass := preload("res://scripts/commands/fire_control_command.gd")
const FireCommandClass := preload("res://scripts/commands/fire_command.gd")
const AuthoritativeSyncClass := preload("res://scripts/network/authoritative_sync.gd")

signal connection_changed(connected: bool)
signal status_changed(status_text: String)
signal side_assigned(side_name: String)
signal side_denied(reason: String)
signal match_snapshot_received(snapshot: Dictionary)
signal move_result_received(result: ActionResultClass, request_id: String)
signal face_result_received(result: ActionResultClass, request_id: String)
signal position_result_received(result: ActionResultClass, request_id: String)
signal fire_control_result_received(result: ActionResultClass, request_id: String)
signal fire_at_result_received(result: ActionResultClass, request_id: String)
signal movement_tick_received(payload: Dictionary)
signal visibility_update_received(payload: Dictionary)
signal target_sync_received(payload: Dictionary)
signal combat_shots_received(payload: Dictionary)
signal combat_status_received(payload: Dictionary)

var _socket := WebSocketPeer.new()
var _connected := false
var _connecting := false
var _connect_failed := false
var _side_request_pending := false
var _side_request_resolved := false
var _side_request_success := false
var client_id: String = ""
var match_id: String = ""
var last_snapshot: Dictionary = {}
var _pending_waits: Dictionary = {}
var _request_seq := 0


func _ready() -> void:
	set_process(false)


func connect_for_local_multiplayer() -> void:
	if not GameModeManager.is_local_multiplayer():
		GameLog.log_system("[NetworkClient] Skipped — not in LOCAL_MULTIPLAYER mode.")
		return
	if _connected or _connecting:
		return

	_connect_failed = false
	_connecting = true
	_emit_status()
	var err := _socket.connect_to_url(SERVER_URL)
	if err != OK:
		_connecting = false
		_connect_failed = true
		_emit_status()
		GameLog.log_system(
			"[NetworkClient] Connection failed to start: %s" % error_string(err)
		)
		return

	set_process(true)
	GameLog.log_system("[NetworkClient] Connecting to %s..." % SERVER_URL)


func connect_and_wait(timeout_sec: float = DEFAULT_CONNECT_TIMEOUT_SEC) -> bool:
	if not GameModeManager.is_local_multiplayer():
		return false
	if _connected:
		return true

	connect_for_local_multiplayer()
	var deadline_msec := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		await get_tree().process_frame
		if _connected:
			return true
		if _connect_failed or (not _connecting and not _connected):
			break

	if _connected:
		return true

	_reset_socket()
	GameLog.log_system(
		"[NetworkClient] Connection failed — start the server first: cd server && npm run dev"
	)
	return false


func request_side_and_wait(
	side_name: String,
	timeout_sec: float = DEFAULT_SIDE_REQUEST_TIMEOUT_SEC,
) -> bool:
	if not _connected:
		return false

	_side_request_pending = true
	_side_request_resolved = false
	_side_request_success = false
	GameLog.log_system("[NetworkClient] Requested side: %s" % side_name)
	send_json({"type": "request_side", "side": side_name.to_upper()})

	var deadline_msec := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		await get_tree().process_frame
		if _side_request_resolved:
			return _side_request_success

	_side_request_pending = false
	GameLog.log_system("[NetworkClient] Side request timed out for %s." % side_name)
	return false


func is_connected_to_server() -> bool:
	return _connected


func get_multiplayer_status_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("Mode: LOCAL_MULTIPLAYER")
	lines.append("Connected: %s" % ("Yes" if _connected else "No"))
	if not match_id.is_empty():
		lines.append("Match: %s" % match_id)
	if PlayerSides.has_assignment():
		lines.append("Assigned Side: %s" % PlayerSides.display_side_name())
	return lines


func wait_for_snapshot(timeout_sec: float = DEFAULT_SNAPSHOT_TIMEOUT_SEC) -> Dictionary:
	if not last_snapshot.is_empty():
		return last_snapshot
	var deadline_msec := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		await get_tree().process_frame
		if not last_snapshot.is_empty():
			return last_snapshot
	return {}


func submit_move_and_wait(
	cmd: MoveCommandClass,
	timeout_sec: float = DEFAULT_MOVE_TIMEOUT_SEC,
) -> ActionResultClass:
	if not _connected or cmd == null:
		return ActionResultClass.fail("Not connected to the match server.")
	var request_id := _begin_command_wait()
	send_json({
		"type": "move_command",
		"matchId": match_id,
		"requestId": request_id,
		"teamId": cmd.team_id,
		"soldierId": cmd.soldier_id,
		"targetCell": {"x": cmd.target_cell.x, "y": cmd.target_cell.y},
		"scope": int(cmd.scope),
		"movementMode": cmd.movement_mode,
	})
	return await _wait_for_command_result(timeout_sec, "Move", request_id)


func submit_face_and_wait(
	cmd: FaceCommandClass,
	timeout_sec: float = DEFAULT_MOVE_TIMEOUT_SEC,
) -> ActionResultClass:
	if not _connected or cmd == null:
		return ActionResultClass.fail("Not connected to the match server.")
	var request_id := _begin_command_wait()
	var payload := {
		"type": "face_command",
		"matchId": match_id,
		"requestId": request_id,
		"teamId": cmd.team_id,
		"soldierId": cmd.soldier_id,
		"targetCell": {"x": cmd.target_cell.x, "y": cmd.target_cell.y},
		"scope": int(cmd.scope),
	}
	if cmd.aim_world.x > -90000.0:
		payload["aimWorld"] = {"x": cmd.aim_world.x, "y": cmd.aim_world.y}
	send_json(payload)
	return await _wait_for_command_result(timeout_sec, "Face", request_id)


func submit_position_and_wait(
	cmd: PositionCommandClass,
	timeout_sec: float = DEFAULT_MOVE_TIMEOUT_SEC,
) -> ActionResultClass:
	if not _connected or cmd == null:
		return ActionResultClass.fail("Not connected to the match server.")
	var request_id := _begin_command_wait()
	send_json({
		"type": "position_command",
		"matchId": match_id,
		"requestId": request_id,
		"teamId": cmd.team_id,
		"soldierId": cmd.soldier_id,
		"positionState": cmd.position_state,
	})
	return await _wait_for_command_result(timeout_sec, "Position", request_id)


func submit_fire_control_and_wait(
	cmd: FireControlCommandClass,
	timeout_sec: float = DEFAULT_MOVE_TIMEOUT_SEC,
) -> ActionResultClass:
	if not _connected or cmd == null:
		return ActionResultClass.fail("Not connected to the match server.")
	var request_id := _begin_command_wait()
	send_json({
		"type": "fire_control_command",
		"matchId": match_id,
		"requestId": request_id,
		"teamId": cmd.team_id,
		"soldierId": cmd.soldier_id,
		"fireControlState": cmd.fire_control_state,
	})
	return await _wait_for_command_result(timeout_sec, "FireControl", request_id)


func submit_fire_at_and_wait(
	cmd: FireCommandClass,
	timeout_sec: float = DEFAULT_MOVE_TIMEOUT_SEC,
) -> ActionResultClass:
	if not _connected or cmd == null:
		return ActionResultClass.fail("Not connected to the match server.")
	var request_id := _begin_command_wait()
	var payload := {
		"type": "fire_at_command",
		"matchId": match_id,
		"requestId": request_id,
		"teamId": cmd.team_id,
		"soldierId": cmd.soldier_id,
		"targetTeamId": cmd.target_team_id,
		"targetSoldierId": cmd.target_soldier_id,
		"scope": int(cmd.scope),
	}
	if cmd.target_cell.x > -900:
		payload["targetCell"] = {"x": cmd.target_cell.x, "y": cmd.target_cell.y}
	if cmd.aim_world.x > -90000.0:
		payload["aimWorld"] = {"x": cmd.aim_world.x, "y": cmd.aim_world.y}
	send_json(payload)
	return await _wait_for_command_result(timeout_sec, "FireAt", request_id)


func _begin_command_wait() -> String:
	_request_seq += 1
	var request_id := "%s-%d" % [client_id if not client_id.is_empty() else "client", _request_seq]
	_pending_waits[request_id] = {"resolved": false, "result": null}
	return request_id


func _wait_for_command_result(
	timeout_sec: float,
	label: String,
	request_id: String,
) -> ActionResultClass:
	var deadline_msec := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		await get_tree().process_frame
		if not _pending_waits.has(request_id):
			return ActionResultClass.fail("%s request cancelled." % label)
		var entry: Dictionary = _pending_waits[request_id]
		if bool(entry.get("resolved", false)):
			var result: ActionResultClass = entry.get("result") as ActionResultClass
			_pending_waits.erase(request_id)
			return result if result != null else ActionResultClass.fail("Empty %s result." % label)
	_pending_waits.erase(request_id)
	return ActionResultClass.fail("%s request timed out." % label)


func send_json(data: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_socket.send_text(JSON.stringify(data))


func disconnect_from_server() -> void:
	_reset_socket()
	PlayerSides.clear()
	_emit_status()


func _reset_socket() -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close()
	_socket = WebSocketPeer.new()
	_connected = false
	_connecting = false
	_connect_failed = false
	_side_request_pending = false
	_side_request_resolved = false
	_side_request_success = false
	client_id = ""
	match_id = ""
	last_snapshot.clear()
	_pending_waits.clear()
	set_process(false)


func _process(_delta: float) -> void:
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_on_connected()
			_receive_packets()
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			if _connected or _connecting:
				_on_disconnected()
			set_process(false)


func _on_connected() -> void:
	_connected = true
	_connecting = false
	GameLog.log_system("[NetworkClient] Connected to server.")
	_emit_status()
	_send_hello()


func _on_disconnected() -> void:
	var was_connected := _connected
	var was_connecting := _connecting
	_connected = false
	_connecting = false
	PlayerSides.clear()
	if was_connected:
		GameLog.log_system("[NetworkClient] Disconnected from server.")
	elif was_connecting:
		_connect_failed = true
		GameLog.log_system(
			"[NetworkClient] Could not reach server at %s — is it running?" % SERVER_URL
		)
	_emit_status()
	connection_changed.emit(false)


func _send_hello() -> void:
	send_json({"type": "hello", "clientName": CLIENT_NAME})
	GameLog.log_system("[NetworkClient] Sent hello to server.")


func _receive_packets() -> void:
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		var text := packet.get_string_from_utf8()
		GameLog.log_system("[NetworkClient] Received: %s" % text)
		var parsed: Variant = _parse_json_object(text)
		if parsed == null:
			GameLog.log_system("[NetworkClient] Message is not valid JSON object.")
			continue
		_handle_message(parsed as Dictionary)


func _parse_json_object(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	if typeof(json.data) != TYPE_DICTIONARY:
		return null
	return json.data


func _handle_message(message: Dictionary) -> void:
	var msg_type: String = str(message.get("type", ""))
	match msg_type:
		"welcome":
			client_id = str(message.get("clientId", ""))
			match_id = str(message.get("matchId", match_id))
			GameLog.log_system(
				"[NetworkClient] Welcome: %s (clientId=%s matchId=%s)"
				% [str(message.get("message", "")), client_id, match_id]
			)
		"match_snapshot":
			_on_match_snapshot(message)
		"pong":
			GameLog.log_system(
				"[NetworkClient] Pong serverTime=%s" % str(message.get("serverTime", ""))
			)
		"side_assigned":
			if message.has("matchId"):
				match_id = str(message.get("matchId", match_id))
			_on_side_assigned(str(message.get("side", "")))
		"side_denied":
			_on_side_denied(str(message.get("reason", "Side denied")))
		"move_result":
			_on_move_result(message)
		"face_result":
			_on_face_result(message)
		"position_result":
			_on_position_result(message)
		"fire_control_result":
			_on_fire_control_result(message)
		"fire_at_result":
			_on_fire_at_result(message)
		"movement_tick":
			movement_tick_received.emit(message)
		"visibility_update":
			visibility_update_received.emit(message)
		"target_sync":
			target_sync_received.emit(message)
		"combat_shots":
			combat_shots_received.emit(message)
		"combat_status":
			combat_status_received.emit(message)
		_:
			GameLog.log_system("[NetworkClient] Unhandled message type: %s" % msg_type)


func _on_side_assigned(side_name: String) -> void:
	PlayerSides.assign_from_side_name(side_name)
	GameLog.log_system("[NetworkClient] Side assigned: %s" % side_name)
	_side_request_pending = false
	_side_request_resolved = true
	_side_request_success = true
	side_assigned.emit(side_name)
	_emit_status()


func _on_side_denied(reason: String) -> void:
	GameLog.log_system("[NetworkClient] Side denied: %s" % reason)
	_side_request_pending = false
	_side_request_resolved = true
	_side_request_success = false
	side_denied.emit(reason)
	_emit_status()


func _on_match_snapshot(snapshot: Dictionary) -> void:
	last_snapshot = snapshot.duplicate(true)
	if snapshot.has("matchId"):
		match_id = str(snapshot.get("matchId", match_id))
	GameLog.log_system(
		"[NetworkClient] Match snapshot matchId=%s mapId=%s tickId=%s simMsec=%s soldiers=%d"
		% [
			str(snapshot.get("matchId", "")),
			str(snapshot.get("mapId", "")),
			str(snapshot.get("tickId", snapshot.get("tick_id", "?"))),
			str(snapshot.get("simMsec", snapshot.get("sim_msec", "?"))),
			(snapshot.get("soldiers", []) as Array).size() if snapshot.get("soldiers", []) is Array else 0,
		]
	)
	match_snapshot_received.emit(last_snapshot)


func _on_move_result(payload: Dictionary) -> void:
	var request_id := str(payload.get("requestId", payload.get("request_id", "")))
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	var waiting := _is_waiting_for(request_id)
	_resolve_command_wait(request_id, result)
	## Issuer applies after wait; the other window applies from this signal.
	if not waiting:
		move_result_received.emit(result, request_id)


func _on_face_result(payload: Dictionary) -> void:
	var request_id := str(payload.get("requestId", payload.get("request_id", "")))
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	result.refresh_views = result.success
	var waiting := _is_waiting_for(request_id)
	_resolve_command_wait(request_id, result)
	if not waiting:
		face_result_received.emit(result, request_id)


func _on_position_result(payload: Dictionary) -> void:
	var request_id := str(payload.get("requestId", payload.get("request_id", "")))
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	result.refresh_views = result.success
	var waiting := _is_waiting_for(request_id)
	_resolve_command_wait(request_id, result)
	if not waiting:
		position_result_received.emit(result, request_id)


func _on_fire_control_result(payload: Dictionary) -> void:
	var request_id := str(payload.get("requestId", payload.get("request_id", "")))
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	result.refresh_views = result.success
	result.sync_fire_at_ui = bool(payload.get("syncFireAtUi", payload.get("sync_fire_at_ui", false)))
	var waiting := _is_waiting_for(request_id)
	_resolve_command_wait(request_id, result)
	if not waiting:
		fire_control_result_received.emit(result, request_id)


func _on_fire_at_result(payload: Dictionary) -> void:
	var request_id := str(payload.get("requestId", payload.get("request_id", "")))
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	result.refresh_views = result.success
	result.sync_fire_at_ui = bool(payload.get("syncFireAtUi", payload.get("sync_fire_at_ui", result.success)))
	var waiting := _is_waiting_for(request_id)
	_resolve_command_wait(request_id, result)
	if not waiting:
		fire_at_result_received.emit(result, request_id)


func _is_waiting_for(request_id: String) -> bool:
	if request_id.is_empty() or not _pending_waits.has(request_id):
		return false
	return not bool((_pending_waits[request_id] as Dictionary).get("resolved", false))


func _resolve_command_wait(request_id: String, result: ActionResultClass) -> void:
	if request_id.is_empty() or not _pending_waits.has(request_id):
		return
	var entry: Dictionary = _pending_waits[request_id]
	entry["resolved"] = true
	entry["result"] = result


func _emit_status() -> void:
	status_changed.emit("")
	if _connected:
		connection_changed.emit(true)
