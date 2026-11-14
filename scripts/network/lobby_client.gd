extends Node
## Lobby client for Chain Revival online matchmaking.
##
## Uses Supabase PostgREST API to create, list, join, and manage lobbies.
## NOT an autoload; instantiate it where needed and add_child it.

signal lobbies_listed(lobbies: Array)
signal lobby_created(lobby: Dictionary)
signal lobby_joined(lobby: Dictionary)
signal lobby_deleted()
signal lobby_error(msg: String)
signal chat_messages_received(messages: Array)
signal player_profile_fetched(profile: Dictionary)

var _http_list: HTTPRequest
var _http_create: HTTPRequest
var _http_join: HTTPRequest
var _http_delete: HTTPRequest
var _http_update: HTTPRequest
var _http_cleanup: HTTPRequest
var _http_chat_send: HTTPRequest
var _http_chat_fetch: HTTPRequest
var _http_profile: HTTPRequest

## Stashed create args while we clean up old lobbies first.
var _pending_match_name: String = ""
var _pending_server_url: String = ""
var _pending_map_id: String = "ff_farm"
var _pending_team_size: int = 1
var _pending_room_number: int = 0
var _pending_match_length_sec: int = 900
var _pending_host_regiment_id: String = ""


func _ready() -> void:
	_http_list = _make_http("_on_list_response")
	_http_create = _make_http("_on_create_response")
	_http_join = _make_http("_on_join_response")
	_http_delete = _make_http("_on_delete_response")
	_http_update = _make_http("_on_update_response")
	_http_cleanup = _make_http("_on_cleanup_response")
	_http_chat_send = _make_http("_on_chat_send_response")
	_http_chat_fetch = _make_http("_on_chat_fetch_response")
	_http_profile = _make_http("_on_profile_response")


# ─────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────

## List lobbies: only active (waiting/in_progress) ones.
func list_lobbies() -> void:
	if not _check_auth():
		return
	if _is_dev_lobby_mode():
		_http_list.request("%s/dev/lobbies" % _dev_http_base())
		return
	var url := "%s/rest/v1/lobbies?or=(status.eq.waiting,status.eq.in_progress)&order=room_number.asc.nullslast" % SupabaseAuth.SUPABASE_URL
	_http_list.request(url, _bearer_headers(), HTTPClient.METHOD_GET)


## Create a new lobby. First deletes any existing lobbies by this host.
func create_lobby(match_name: String, server_url: String = "", map_id: String = "ff_farm", team_size: int = 1, room_number: int = 0, match_length_sec: int = 900, host_regiment_id: String = "") -> void:
	if not _check_auth():
		return
	_pending_match_name = match_name
	_pending_server_url = server_url
	_pending_map_id = map_id
	_pending_team_size = team_size
	_pending_room_number = room_number
	_pending_match_length_sec = match_length_sec
	_pending_host_regiment_id = host_regiment_id
	if _is_dev_lobby_mode():
		var payload := _pending_create_payload()
		var url := "%s/dev/lobbies" % _dev_http_base()
		_http_create.request(
			url,
			PackedStringArray(["Content-Type: application/json"]),
			HTTPClient.METHOD_POST,
			JSON.stringify(payload)
		)
		return
	# Delete any stale lobbies by this host first.
	var url := "%s/rest/v1/lobbies?host_id=eq.%s" % [SupabaseAuth.SUPABASE_URL, SupabaseAuth.user_id]
	_http_cleanup.request(url, _bearer_headers(), HTTPClient.METHOD_DELETE)


## Join an existing lobby via atomic RPC (increments players, sets in_progress when full).
func join_lobby(lobby_id: String) -> void:
	if not _check_auth():
		return
	if _is_dev_lobby_mode():
		var dev_body := JSON.stringify({"player_id": SupabaseAuth.user_id})
		var dev_url := "%s/dev/lobbies/%s/join" % [_dev_http_base(), lobby_id.uri_encode()]
		_http_join.request(
			dev_url,
			PackedStringArray(["Content-Type: application/json"]),
			HTTPClient.METHOD_POST,
			dev_body
		)
		return
	var body := JSON.stringify({"p_lobby_id": lobby_id})
	var headers := _bearer_headers()
	var url := "%s/rest/v1/rpc/join_lobby" % SupabaseAuth.SUPABASE_URL
	_http_join.request(url, headers, HTTPClient.METHOD_POST, body)


## Update lobby status (e.g. 'finished').
func update_lobby_status(lobby_id: String, new_status: String) -> void:
	if not _check_auth():
		return
	var body := JSON.stringify({"status": new_status})
	if _is_dev_lobby_mode():
		var dev_url := "%s/dev/lobbies/%s" % [_dev_http_base(), lobby_id.uri_encode()]
		_http_update.request(
			dev_url,
			PackedStringArray(["Content-Type: application/json"]),
			HTTPClient.METHOD_PATCH,
			body
		)
		return
	var headers := _bearer_headers_prefer_return()
	var url := "%s/rest/v1/lobbies?id=eq.%s" % [SupabaseAuth.SUPABASE_URL, lobby_id]
	_http_update.request(url, headers, HTTPClient.METHOD_PATCH, body)


## Delete a lobby (host only, enforced by RLS).
func delete_lobby(lobby_id: String) -> void:
	if not _check_auth():
		return
	if _is_dev_lobby_mode():
		var dev_url := "%s/dev/lobbies/%s?player_id=%s" % [
			_dev_http_base(),
			lobby_id.uri_encode(),
			SupabaseAuth.user_id.uri_encode(),
		]
		_http_delete.request(dev_url, PackedStringArray(), HTTPClient.METHOD_DELETE)
		return
	var url := "%s/rest/v1/lobbies?id=eq.%s" % [SupabaseAuth.SUPABASE_URL, lobby_id]
	_http_delete.request(url, _bearer_headers(), HTTPClient.METHOD_DELETE)


## Send a chat message to the global lobby chat.
func send_chat_message(msg: String) -> void:
	if not _check_auth():
		return
	if _is_dev_lobby_mode():
		return
	var body := JSON.stringify({
		"user_id": SupabaseAuth.user_id,
		"display_name": SupabaseAuth.display_name,
		"message": msg,
	})
	var url := "%s/rest/v1/chat_messages" % SupabaseAuth.SUPABASE_URL
	_http_chat_send.request(url, _bearer_headers(), HTTPClient.METHOD_POST, body)


## Fetch a player's profile by user ID (for the player card sidebar).
func fetch_player_profile(user_id: String) -> void:
	if not _check_auth():
		return
	if _is_dev_lobby_mode():
		player_profile_fetched.emit({
			"id": user_id,
			"display_name": user_id.trim_prefix("local:"),
			"rank": 0,
			"prestige_points": 0,
			"games_played": 0,
			"games_won": 0,
			"total_kills": 0,
		})
		return
	var url := "%s/rest/v1/player_profiles?id=eq.%s&select=id,display_name,rank,prestige_points,games_played,games_won,total_kills,regiment_id,regiments(name,tag)" % [SupabaseAuth.SUPABASE_URL, user_id]
	_http_profile.request(url, _bearer_headers(), HTTPClient.METHOD_GET)


## Fetch the last 50 chat messages. The UI deduplicates by ID.
func fetch_chat_messages(_since_iso: String = "") -> void:
	if not _check_auth():
		return
	if _is_dev_lobby_mode():
		chat_messages_received.emit([])
		return
	var url := "%s/rest/v1/chat_messages?order=created_at.asc&limit=50" % SupabaseAuth.SUPABASE_URL
	_http_chat_fetch.request(url, _bearer_headers(), HTTPClient.METHOD_GET)


# ─────────────────────────────────────────────────────────────────────────
# Response handlers
# ─────────────────────────────────────────────────────────────────────────

func _on_list_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		lobby_error.emit("Failed to fetch lobbies (HTTP %d)" % response_code)
		return
	var parsed := _parse_body_array(body)
	lobbies_listed.emit(parsed)


func _on_create_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 201):
		lobby_error.emit("Failed to create lobby (HTTP %d)" % response_code)
		return
	var parsed := _parse_body_array(body)
	if parsed.size() > 0:
		lobby_created.emit(parsed[0])
	else:
		lobby_error.emit("Lobby created but no data returned")


func _on_join_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		lobby_error.emit("Failed to join lobby (HTTP %d)" % response_code)
		return
	var parsed := _parse_body_array(body)
	if parsed.size() > 0:
		lobby_joined.emit(parsed[0])
	else:
		lobby_error.emit("Lobby may have been taken or removed")


func _on_delete_response(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 204):
		lobby_error.emit("Failed to delete lobby (HTTP %d)" % response_code)
		return
	lobby_deleted.emit()


const RANK_LABELS := ["PVT", "PFC", "CPL", "SGT", "SSG", "SFC", "MSG", "2LT", "1LT", "CPT"]

func _on_cleanup_response(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	# Old lobbies cleaned up (or none existed). Now create the new one.
	var payload := _pending_create_payload()
	var body := JSON.stringify(payload)
	var headers := _bearer_headers_prefer_return()
	var url := "%s/rest/v1/lobbies" % SupabaseAuth.SUPABASE_URL
	_http_create.request(url, headers, HTTPClient.METHOD_POST, body)


func _pending_create_payload() -> Dictionary:
	var rank_idx: int = clampi(SupabaseAuth.rank, 0, RANK_LABELS.size() - 1)
	var tag_prefix := "[%s] " % SupabaseAuth.regiment_tag if SupabaseAuth.regiment_tag != "" else ""
	var ranked_name := (
		SupabaseAuth.display_name
		if _is_dev_lobby_mode()
		else "%s%s %s" % [tag_prefix, RANK_LABELS[rank_idx], SupabaseAuth.display_name]
	)
	var payload := {
		"host_id": SupabaseAuth.user_id,
		"host_display_name": ranked_name,
		"match_name": _pending_match_name,
		"status": "waiting",
		"current_players": 1,
		"team_size": _pending_team_size,
		"max_players": _pending_team_size * 2,
	}
	if not _pending_server_url.is_empty():
		payload["server_url"] = _pending_server_url
	if not _pending_map_id.is_empty():
		payload["map_id"] = _pending_map_id
	if _pending_room_number > 0:
		payload["room_number"] = _pending_room_number
	if _pending_match_length_sec > 0 and _pending_match_length_sec != 900:
		payload["match_length_sec"] = _pending_match_length_sec
	if not _pending_host_regiment_id.is_empty():
		payload["host_regiment_id"] = _pending_host_regiment_id
	return payload


func _on_update_response(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	pass


func _on_profile_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed := _parse_body_array(body)
	if parsed.size() > 0:
		player_profile_fetched.emit(parsed[0])


func _on_chat_send_response(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	pass


func _on_chat_fetch_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed := _parse_body_array(body)
	chat_messages_received.emit(parsed)


# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────

func _check_auth() -> bool:
	if _is_dev_lobby_mode():
		return true
	if not SupabaseAuth.is_signed_in:
		lobby_error.emit("Not signed in")
		return false
	return true


func _is_dev_lobby_mode() -> bool:
	return SupabaseAuth.is_local_guest_mode


func _dev_http_base() -> String:
	var url := NetworkClient.server_url.strip_edges().trim_suffix("/")
	if url.begins_with("wss://"):
		return "https://%s" % url.substr("wss://".length())
	if url.begins_with("ws://"):
		return "http://%s" % url.substr("ws://".length())
	return url


func _bearer_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % SupabaseAuth.SUPABASE_ANON_KEY,
		"Authorization: Bearer %s" % SupabaseAuth.access_token,
	])


func _bearer_headers_prefer_return() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % SupabaseAuth.SUPABASE_ANON_KEY,
		"Authorization: Bearer %s" % SupabaseAuth.access_token,
		"Prefer: return=representation",
	])


func _make_http(callback: String) -> HTTPRequest:
	var req := HTTPRequest.new()
	req.request_completed.connect(Callable(self, callback))
	add_child(req)
	return req


func _parse_body_array(body: PackedByteArray) -> Array:
	var text := body.get_string_from_utf8()
	if text.is_empty():
		return []
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return []
	var data = json.data
	if data is Array:
		return data
	if data is Dictionary:
		return [data]
	return []
