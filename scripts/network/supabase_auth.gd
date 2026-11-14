extends Node
## Supabase authentication client for Chain Revival.
##
## Handles sign-up, sign-in (email + password), sign-out, and automatic
## token refresh via the Supabase REST auth API.  Register as an autoload
## named SupabaseAuth so other scripts can call it globally.
##
## Fill in your project credentials below (safe to commit; the anon key is
## public by design).

## ── Supabase credentials ────────────────────────────────────────────────
## Replace these with the values from  Settings > API  in your Supabase
## dashboard.  SUPABASE_URL looks like "https://xxxxx.supabase.co" and
## SUPABASE_ANON_KEY is the long JWT string labelled "anon / public".
const SUPABASE_URL := "https://tnyaqreedvdmyworvqbw.supabase.co"
const SUPABASE_ANON_KEY := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRueWFxcmVlZHZkbXl3b3J2cWJ3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI5NzA5MzQsImV4cCI6MjEwODU0NjkzNH0.z9P6-W9U-NsJYr5TXxeHsc8Z5_flrDZSOqkNNParqPQ"

## ── Signals ─────────────────────────────────────────────────────────────
signal auth_state_changed(signed_in: bool)
signal sign_in_succeeded(user: Dictionary)
signal sign_in_failed(reason: String)
signal sign_up_succeeded(user: Dictionary)
signal sign_up_failed(reason: String)
signal player_banned(reason: String)
signal profile_loaded()

## ── Public state ────────────────────────────────────────────────────────
var access_token: String = ""
var refresh_token: String = ""
var user_id: String = ""
var user_email: String = ""
var display_name: String = ""
var user_data: Dictionary = {}
var is_signed_in: bool = false
var prestige_points: int = 0
var rank: int = 0
var regiment_id: String = ""
var regiment_tag: String = ""
var is_admin: bool = false
var is_moderator: bool = false
var is_banned: bool = false
var ban_reason: String = ""
## Explicit development-only mode. It never loads or mutates the saved Supabase session.
var is_local_guest_mode: bool = false
var local_guest_name: String = ""

## ── Internals ───────────────────────────────────────────────────────────
var _http_sign_in: HTTPRequest
var _http_sign_up: HTTPRequest
var _http_refresh: HTTPRequest
var _http_sign_out: HTTPRequest
var _http_profile: HTTPRequest
var _refresh_timer: Timer

## How many seconds before token expiry we trigger a refresh.
const REFRESH_MARGIN_SEC := 60.0
const SESSION_SAVE_PATH := "user://supabase_session.json"


func _ready() -> void:
	_configure_local_guest_mode()
	_http_sign_in = _make_http("_on_sign_in_response")
	_http_sign_up = _make_http("_on_sign_up_response")
	_http_refresh = _make_http("_on_refresh_response")
	_http_sign_out = _make_http("_on_sign_out_response")
	_http_profile = _make_http("_on_profile_response")

	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.timeout.connect(_on_refresh_timer)
	add_child(_refresh_timer)

	if is_local_guest_mode:
		user_id = "local:%s" % local_guest_name
		display_name = local_guest_name
		GameLog.log_system(
			"[SupabaseAuth] Local guest mode (%s) — saved session and Supabase are disabled."
			% local_guest_name
		)
		return
	if SUPABASE_URL == "" or SUPABASE_ANON_KEY == "":
		push_warning("[SupabaseAuth] Credentials not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY in supabase_auth.gd")
	else:
		_load_saved_session()


# ─────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────

func sign_up(email: String, password: String, p_display_name: String = "") -> void:
	if not _check_config():
		sign_up_failed.emit("Supabase not configured")
		return
	var payload := {"email": email, "password": password}
	if not p_display_name.is_empty():
		payload["data"] = {"display_name": p_display_name}
	var body := JSON.stringify(payload)
	var headers := _auth_headers()
	var url := "%s/auth/v1/signup" % SUPABASE_URL
	_http_sign_up.request(url, headers, HTTPClient.METHOD_POST, body)


func sign_in(email: String, password: String) -> void:
	if not _check_config():
		sign_in_failed.emit("Supabase not configured")
		return
	var body := JSON.stringify({"email": email, "password": password})
	var headers := _auth_headers()
	var url := "%s/auth/v1/token?grant_type=password" % SUPABASE_URL
	_http_sign_in.request(url, headers, HTTPClient.METHOD_POST, body)


func sign_out() -> void:
	if not is_signed_in:
		return
	if not _check_config():
		_clear_session()
		return
	var headers := _bearer_headers()
	var url := "%s/auth/v1/logout" % SUPABASE_URL
	_http_sign_out.request(url, headers, HTTPClient.METHOD_POST)


func refresh_session() -> void:
	if refresh_token.is_empty():
		return
	if not _check_config():
		return
	var body := JSON.stringify({"refresh_token": refresh_token})
	var headers := _auth_headers()
	var url := "%s/auth/v1/token?grant_type=refresh_token" % SUPABASE_URL
	_http_refresh.request(url, headers, HTTPClient.METHOD_POST, body)


# ─────────────────────────────────────────────────────────────────────────
# Response handlers
# ─────────────────────────────────────────────────────────────────────────

func _on_sign_in_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		sign_in_failed.emit("Network error (code %d)" % result)
		return
	var parsed := _parse_body(body)
	if parsed.is_empty():
		sign_in_failed.emit("Invalid response from server")
		return
	if response_code != 200:
		var msg: String = parsed.get("error_description", parsed.get("msg", "Sign in failed"))
		sign_in_failed.emit(msg)
		return
	_apply_session(parsed)
	GameLog.log_system("[SupabaseAuth] Signed in as %s" % user_email)
	fetch_profile()
	sign_in_succeeded.emit(user_data)


func _on_sign_up_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		sign_up_failed.emit("Network error (code %d)" % result)
		return
	var parsed := _parse_body(body)
	if parsed.is_empty():
		sign_up_failed.emit("Invalid response from server")
		return
	if response_code != 200 and response_code != 201:
		var msg: String = parsed.get("error_description", parsed.get("msg", "Sign up failed"))
		sign_up_failed.emit(msg)
		return
	# Supabase may return a session directly or require email confirmation.
	if parsed.has("access_token"):
		_apply_session(parsed)
		GameLog.log_system("[SupabaseAuth] Signed up and signed in as %s" % user_email)
	else:
		GameLog.log_system("[SupabaseAuth] Sign up succeeded; check email for confirmation.")
	var user_info: Dictionary = parsed.get("user", {})
	sign_up_succeeded.emit(user_info)


func _on_refresh_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		GameLog.log_system("[SupabaseAuth] Token refresh failed; signing out.")
		_clear_session()
		return
	var parsed := _parse_body(body)
	if parsed.is_empty() or not parsed.has("access_token"):
		GameLog.log_system("[SupabaseAuth] Token refresh returned bad data; signing out.")
		_clear_session()
		return
	_apply_session(parsed)
	GameLog.log_system("[SupabaseAuth] Token refreshed.")
	fetch_profile()


func _on_sign_out_response(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_clear_session()
	GameLog.log_system("[SupabaseAuth] Signed out.")


## Fetch rank and PP from the player_profiles table after sign-in.
func fetch_profile() -> void:
	if user_id.is_empty() or not _check_config():
		return
	var url := "%s/rest/v1/player_profiles?id=eq.%s&select=prestige_points,rank,regiment_id,is_admin,is_moderator,is_banned,ban_reason,regiments(tag)" % [SUPABASE_URL, user_id]
	var hdrs := _bearer_headers()
	_http_profile.request(url, hdrs, HTTPClient.METHOD_GET)


func _on_profile_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var text := body.get_string_from_utf8()
	if text.is_empty():
		return
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var arr = json.data
	if not arr is Array or arr.is_empty():
		return
	var row: Dictionary = arr[0]
	prestige_points = int(row.get("prestige_points", 0))
	rank = int(row.get("rank", 0))
	var rid = row.get("regiment_id", "")
	regiment_id = str(rid) if rid != null else ""
	is_admin = bool(row.get("is_admin", false))
	is_moderator = bool(row.get("is_moderator", false))
	is_banned = bool(row.get("is_banned", false))
	var br = row.get("ban_reason", "")
	ban_reason = str(br) if br != null else ""
	# Extract regiment tag from the joined regiments object
	var reg_data = row.get("regiments", null)
	if reg_data is Dictionary:
		regiment_tag = str(reg_data.get("tag", ""))
	else:
		regiment_tag = ""
	GameLog.log_system("[SupabaseAuth] Profile loaded: rank=%d pp=%d regiment=%s tag=%s admin=%s mod=%s banned=%s" % [rank, prestige_points, regiment_id, regiment_tag, str(is_admin), str(is_moderator), str(is_banned)])
	if is_banned:
		player_banned.emit(ban_reason)
	profile_loaded.emit()


# ─────────────────────────────────────────────────────────────────────────
# Session helpers
# ─────────────────────────────────────────────────────────────────────────

func _apply_session(data: Dictionary) -> void:
	access_token = data.get("access_token", "")
	refresh_token = data.get("refresh_token", "")
	var user_dict: Dictionary = data.get("user", {})
	user_id = user_dict.get("id", "")
	user_email = user_dict.get("email", "")
	var meta: Dictionary = user_dict.get("user_metadata", {})
	display_name = meta.get("display_name", "")
	if display_name.is_empty():
		display_name = user_email.split("@")[0]
	user_data = user_dict
	is_signed_in = true
	auth_state_changed.emit(true)

	# Schedule a refresh before the token expires.
	var expires_in: float = float(data.get("expires_in", 3600))
	var refresh_after := maxf(expires_in - REFRESH_MARGIN_SEC, 10.0)
	_refresh_timer.start(refresh_after)

	# Persist session to disk so the user stays signed in between launches.
	_save_session()


func _clear_session() -> void:
	access_token = ""
	refresh_token = ""
	user_id = ""
	user_email = ""
	display_name = ""
	user_data = {}
	prestige_points = 0
	rank = 0
	regiment_id = ""
	regiment_tag = ""
	is_admin = false
	is_moderator = false
	is_banned = false
	ban_reason = ""
	_refresh_timer.stop()
	var was_signed_in := is_signed_in
	is_signed_in = false
	if was_signed_in:
		auth_state_changed.emit(false)
	_delete_saved_session()


func _save_session() -> void:
	var data := {
		"access_token": access_token,
		"refresh_token": refresh_token,
		"user_id": user_id,
		"user_email": user_email,
		"display_name": display_name,
	}
	var file := FileAccess.open(SESSION_SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load_saved_session() -> void:
	if not FileAccess.file_exists(SESSION_SAVE_PATH):
		return
	var file := FileAccess.open(SESSION_SAVE_PATH, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var data = json.data
	if not data is Dictionary:
		return
	refresh_token = data.get("refresh_token", "")
	user_email = data.get("user_email", "")
	display_name = data.get("display_name", "")
	user_id = data.get("user_id", "")
	if refresh_token.is_empty():
		return
	# Try refreshing the token to restore the session.
	GameLog.log_system("[SupabaseAuth] Restoring saved session for %s..." % display_name)
	refresh_session()


func _delete_saved_session() -> void:
	if FileAccess.file_exists(SESSION_SAVE_PATH):
		DirAccess.remove_absolute(SESSION_SAVE_PATH)


# ─────────────────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────────────────

func _check_config() -> bool:
	return not is_local_guest_mode and SUPABASE_URL != "" and SUPABASE_ANON_KEY != ""


func _configure_local_guest_mode() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var allow_supabase_local := false
	for arg in args:
		if arg == "--local-guest":
			is_local_guest_mode = true
		elif arg.begins_with("--local-guest="):
			is_local_guest_mode = true
			local_guest_name = arg.substr("--local-guest=".length()).strip_edges()
		elif arg == "--allow-supabase-local":
			allow_supabase_local = true
	if not is_local_guest_mode and not allow_supabase_local:
		var local_server_url := _local_server_override(args)
		is_local_guest_mode = _is_loopback_server_url(local_server_url)
	if is_local_guest_mode and local_guest_name.is_empty():
		local_guest_name = "LocalGuest-%d" % OS.get_process_id()


func _local_server_override(args: Array[String]) -> String:
	for arg in args:
		if arg.begins_with("--server="):
			return arg.substr("--server=".length()).strip_edges()
	if not FileAccess.file_exists("res://dev_server.txt"):
		return ""
	for line in FileAccess.get_file_as_string("res://dev_server.txt").split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.is_empty() and not trimmed.begins_with("#"):
			return trimmed
	return ""


func _is_loopback_server_url(url: String) -> bool:
	var normalized := url.to_lower().trim_suffix("/")
	return (
		normalized == "ws://localhost"
		or normalized.begins_with("ws://localhost:")
		or normalized == "ws://127.0.0.1"
		or normalized.begins_with("ws://127.0.0.1:")
		or normalized == "ws://[::1]"
		or normalized.begins_with("ws://[::1]:")
	)


func _auth_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % SUPABASE_ANON_KEY,
	])


func _bearer_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % SUPABASE_ANON_KEY,
		"Authorization: Bearer %s" % access_token,
	])


func _make_http(callback: String) -> HTTPRequest:
	var req := HTTPRequest.new()
	req.request_completed.connect(Callable(self, callback))
	add_child(req)
	return req


func _parse_body(body: PackedByteArray) -> Dictionary:
	var text := body.get_string_from_utf8()
	if text.is_empty():
		return {}
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return {}
	var result = json.data
	if result is Dictionary:
		return result
	return {}


func _on_refresh_timer() -> void:
	refresh_session()
