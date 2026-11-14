extends Control
## Online lobby browser — persistent 8-room grid.
##
## Players see a fixed list of rooms and click "Join Room" to either
## host (opens a briefing dialog) or join an existing game.
## Chat is handled by the GlobalChat autoload (always visible on the right).

const MODE_SELECT_SCENE := "res://scenes/mode_select.tscn"
const LOBBY_BROWSER_SCENE := "res://scenes/lobby_browser.tscn"
const SIDE_SELECT_SCENE := "res://scenes/side_select.tscn"
const MAIN_SCENE := "res://scenes/main.tscn"
const REJOIN_WAIT_SEC := 5.0
const LEADERBOARD_SCENE := "res://scenes/leaderboard.tscn"
const REGIMENT_SCENE := "res://scenes/regiment_browser.tscn"
const ADMIN_SCENE := "res://scenes/admin_browser.tscn"
const LobbyClientClass := preload("res://scripts/network/lobby_client.gd")
const LeaderboardScript := preload("res://scripts/ui/leaderboard.gd")
const RegimentBrowserScript := preload("res://scripts/ui/regiment_browser.gd")
const AdminBrowserScript := preload("res://scripts/ui/admin_browser.gd")
const MapDataClass := preload("res://scripts/map/map_data.gd")
const RejoinStoreClass := preload("res://scripts/network/rejoin_store.gd")
const MatchConfigClass := preload("res://scripts/core/match_config.gd")
const MatchConfigStoreClass := preload("res://scripts/core/match_config_store.gd")

const ONLINE_SERVER_URL := "wss://chain-revival-ax0q1g.fly.dev"

static func _effective_server_url() -> String:
	if NetworkClient.server_url_overridden:
		return NetworkClient.server_url
	return ONLINE_SERVER_URL

const BASE_ROOM_PATTERN := [
	{"name": "Open Game", "type": "open"},
	{"name": "Open Game", "type": "open"},
	{"name": "Regimental", "type": "regimental"},
	{"name": "Regimental", "type": "regimental"},
	{"name": "Training", "type": "training"},
	{"name": "Regimental", "type": "regimental"},
	{"name": "Regimental", "type": "regimental"},
	{"name": "Open Game", "type": "open"},
]

var _room_config: Array = []
var _max_rooms: int = 8


var _lobby_client: Node
var _status_label: Label
var _refresh_button: Button
var _leaderboard_button: Button
var _regiments_button: Button
var _admin_button: Button
var _back_button: Button
var _refresh_timer: Timer

# Room grid data — keyed by room number (1-8+).
# Each entry: { desc_label, type_label, players_label, action_btn, lobby }
var _room_rows: Dictionary = {}

var _hosted_lobby_id: String = ""
var _joined_lobby_id: String = ""
var _active_room_number: int = 0
var _starting_match: bool = false
## Match this client was in before the game closed: {lobby_id, server_url}, or empty.
var _rejoin: Dictionary = {}

# Player card sidebar
var _player_card_panel: PanelContainer
var _player_card_name: Label
var _player_card_rank: Label
var _player_card_regiment: Label
var _player_card_stats: Label
var _player_card_visible: bool = false
var _center_container: CenterContainer
var _room_vbox: VBoxContainer
var _room_header: HBoxContainer
var _btn_row: HBoxContainer

# Briefing dialog
var _briefing_dialog: Window
var _briefing_room_label: Label
var _briefing_map_dropdown: OptionButton
var _briefing_size_dropdown: OptionButton
var _briefing_length_dropdown: OptionButton
var _briefing_ai_row: HBoxContainer
var _briefing_ai_dropdown: OptionButton
var _briefing_room_number: int = 0
var _briefing_room_type: String = ""


var _http_settings: HTTPRequest

func _ready() -> void:
	CocUiTheme.apply_to(self)
	_lobby_client = LobbyClientClass.new()
	add_child(_lobby_client)
	_rejoin = RejoinStoreClass.load_record()
	_generate_room_config(_max_rooms)
	_build_ui()
	_connect_signals()
	_fetch_max_rooms()
	_lobby_client.list_lobbies()

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 5.0
	_refresh_timer.timeout.connect(_on_auto_refresh)
	add_child(_refresh_timer)
	_refresh_timer.start()


func _generate_room_config(count: int) -> void:
	_room_config.clear()
	for i in range(count):
		if i < BASE_ROOM_PATTERN.size():
			var cfg: Dictionary = BASE_ROOM_PATTERN[i].duplicate()
			cfg["number"] = i + 1
			_room_config.append(cfg)
		else:
			_room_config.append({"number": i + 1, "name": "Open Game", "type": "open"})


func _fetch_max_rooms() -> void:
	if not SupabaseAuth.is_signed_in:
		return
	_http_settings = HTTPRequest.new()
	_http_settings.request_completed.connect(_on_settings_response)
	add_child(_http_settings)
	var url := "%s/rest/v1/site_settings?key=eq.max_rooms&select=value" % SupabaseAuth.SUPABASE_URL
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"apikey: %s" % SupabaseAuth.SUPABASE_ANON_KEY,
		"Authorization: Bearer %s" % SupabaseAuth.access_token,
	])
	_http_settings.request(url, headers, HTTPClient.METHOD_GET)


func _on_settings_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var text := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var data: Variant = json.data
	if data is Array and data.size() > 0:
		var val: Variant = data[0].get("value", "8")
		var new_max := clampi(int(str(val)), 1, 16)
		if new_max != _max_rooms:
			_max_rooms = new_max
			_rebuild_room_grid()


func _rebuild_room_grid() -> void:
	# Remove old room row panels
	for rn: int in _room_rows:
		var row_data: Dictionary = _room_rows[rn]
		var panel: PanelContainer = row_data.get("panel")
		if panel != null:
			panel.queue_free()
	_room_rows.clear()

	_generate_room_config(_max_rooms)
	# Insert new room rows between the header and button row
	var header_idx := _room_header.get_index()
	for i in range(_room_config.size()):
		var row_panel := _build_room_row(_room_config[i])
		_room_vbox.add_child(row_panel)
		_room_vbox.move_child(row_panel, header_idx + 1 + i)
	_lobby_client.list_lobbies()


func _exit_tree() -> void:
	if not _hosted_lobby_id.is_empty():
		_lobby_client.delete_lobby(_hosted_lobby_id)
	_joined_lobby_id = ""




# ─────────────────────────────────────────────────────────────────────────
# UI construction
# ─────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_build_player_card()

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.offset_right = -280
	_center_container = center
	add_child(center)

	var outer_panel := PanelContainer.new()
	outer_panel.custom_minimum_size = Vector2(860, 600)
	center.add_child(outer_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 16)
	outer_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_room_vbox = vbox
	margin.add_child(vbox)

	# Title
	var title := Label.new()
	var url := _effective_server_url()
	if url != ONLINE_SERVER_URL:
		title.text = "Game Rooms [LOCAL: %s]" % url
		title.add_theme_color_override("font_color", Color(1.0, 1.0, 0.4))
	else:
		title.text = "Game Rooms"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	# Status
	_status_label = Label.new()
	_status_label.text = "Loading rooms..."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_status_label)

	# Room grid header
	_room_header = _build_grid_header()
	vbox.add_child(_room_header)

	# Room rows
	for room_cfg in _room_config:
		var row_panel := _build_room_row(room_cfg)
		vbox.add_child(row_panel)

	# Bottom buttons
	_btn_row = HBoxContainer.new()
	_btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(_btn_row)
	var btn_row := _btn_row

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refresh_button.custom_minimum_size = Vector2(0, 42)
	_refresh_button.add_theme_font_size_override("font_size", 18)
	btn_row.add_child(_refresh_button)

	_leaderboard_button = Button.new()
	_leaderboard_button.text = "Leaderboard"
	_leaderboard_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_leaderboard_button.custom_minimum_size = Vector2(0, 42)
	_leaderboard_button.add_theme_font_size_override("font_size", 18)
	btn_row.add_child(_leaderboard_button)

	_regiments_button = Button.new()
	_regiments_button.text = "Regiments"
	_regiments_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_regiments_button.custom_minimum_size = Vector2(0, 42)
	_regiments_button.add_theme_font_size_override("font_size", 18)
	btn_row.add_child(_regiments_button)

	if SupabaseAuth.is_admin or SupabaseAuth.is_moderator:
		_admin_button = Button.new()
		_admin_button.text = "Admin"
		_admin_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_admin_button.custom_minimum_size = Vector2(0, 42)
		_admin_button.add_theme_font_size_override("font_size", 18)
		btn_row.add_child(_admin_button)

	_back_button = Button.new()
	_back_button.text = "Back"
	_back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_back_button.custom_minimum_size = Vector2(0, 42)
	_back_button.add_theme_font_size_override("font_size", 18)
	btn_row.add_child(_back_button)

	# Build briefing dialog (hidden until needed)
	_build_briefing_dialog()


func _build_grid_header() -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)

	var hdr_color := Color(0.85, 0.85, 0.85)

	var col_num := Label.new()
	col_num.text = "Room"
	col_num.custom_minimum_size = Vector2(50, 0)
	col_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col_num.add_theme_font_size_override("font_size", 15)
	col_num.add_theme_color_override("font_color", hdr_color)
	header.add_child(col_num)

	var col_desc := Label.new()
	col_desc.text = "Description"
	col_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_desc.add_theme_font_size_override("font_size", 15)
	col_desc.add_theme_color_override("font_color", hdr_color)
	header.add_child(col_desc)

	var col_type := Label.new()
	col_type.text = "Type"
	col_type.custom_minimum_size = Vector2(100, 0)
	col_type.add_theme_font_size_override("font_size", 15)
	col_type.add_theme_color_override("font_color", hdr_color)
	header.add_child(col_type)

	var col_players := Label.new()
	col_players.text = "Players"
	col_players.custom_minimum_size = Vector2(65, 0)
	col_players.add_theme_font_size_override("font_size", 15)
	col_players.add_theme_color_override("font_color", hdr_color)
	header.add_child(col_players)

	var col_action := Label.new()
	col_action.text = ""
	col_action.custom_minimum_size = Vector2(110, 0)
	header.add_child(col_action)

	return header


func _build_room_row(room_cfg: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 40)

	var margin_wrap := MarginContainer.new()
	margin_wrap.add_theme_constant_override("margin_left", 4)
	margin_wrap.add_theme_constant_override("margin_right", 4)
	margin_wrap.add_theme_constant_override("margin_top", 4)
	margin_wrap.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin_wrap)

	var inner_row := HBoxContainer.new()
	inner_row.add_theme_constant_override("separation", 4)
	margin_wrap.add_child(inner_row)

	# Room number
	var num_label := Label.new()
	num_label.text = str(room_cfg["number"])
	num_label.custom_minimum_size = Vector2(50, 0)
	num_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num_label.add_theme_font_size_override("font_size", 18)
	inner_row.add_child(num_label)

	# Description (clickable to show player card)
	var desc_label := Button.new()
	desc_label.text = room_cfg["name"]
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.add_theme_font_size_override("font_size", 18)
	desc_label.flat = true
	desc_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	desc_label.pressed.connect(_on_desc_clicked.bind(room_cfg["number"]))
	inner_row.add_child(desc_label)

	# Type
	var type_label := Label.new()
	type_label.text = room_cfg["name"]
	type_label.custom_minimum_size = Vector2(100, 0)
	type_label.add_theme_font_size_override("font_size", 16)
	inner_row.add_child(type_label)

	# Players
	var players_label := Label.new()
	players_label.text = "--"
	players_label.custom_minimum_size = Vector2(65, 0)
	players_label.add_theme_font_size_override("font_size", 18)
	inner_row.add_child(players_label)

	# Action button
	var action_btn := Button.new()
	action_btn.text = "Join Room"
	action_btn.custom_minimum_size = Vector2(110, 36)
	action_btn.add_theme_font_size_override("font_size", 16)
	action_btn.pressed.connect(_on_room_action.bind(room_cfg["number"]))
	inner_row.add_child(action_btn)

	var rn: int = room_cfg["number"]
	_room_rows[rn] = {
		"panel": panel,
		"desc_label": desc_label,
		"type_label": type_label,
		"players_label": players_label,
		"action_btn": action_btn,
		"lobby": {},
		"config": room_cfg,
	}

	return panel


# ─────────────────────────────────────────────────────────────────────────
# Player card sidebar
# ─────────────────────────────────────────────────────────────────────────

func _build_player_card() -> void:
	_player_card_panel = PanelContainer.new()
	_player_card_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_player_card_panel.offset_right = 240
	_player_card_panel.visible = false
	add_child(_player_card_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_player_card_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Player Card"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 15)
	vbox.add_child(title)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	_player_card_name = Label.new()
	_player_card_name.text = ""
	_player_card_name.add_theme_font_size_override("font_size", 14)
	_player_card_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_player_card_name)

	_player_card_rank = Label.new()
	_player_card_rank.text = ""
	_player_card_rank.add_theme_font_size_override("font_size", 12)
	_player_card_rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_player_card_rank.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(_player_card_rank)

	_player_card_regiment = Label.new()
	_player_card_regiment.text = ""
	_player_card_regiment.add_theme_font_size_override("font_size", 12)
	_player_card_regiment.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_player_card_regiment.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
	vbox.add_child(_player_card_regiment)

	var sep2 := HSeparator.new()
	vbox.add_child(sep2)

	_player_card_stats = Label.new()
	_player_card_stats.text = ""
	_player_card_stats.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_player_card_stats)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(0, 30)
	close_btn.pressed.connect(_close_player_card)
	vbox.add_child(close_btn)


func _on_desc_clicked(room_number: int) -> void:
	var room_data: Dictionary = _room_rows.get(room_number, {})
	var lobby: Dictionary = room_data.get("lobby", {})
	if lobby.is_empty():
		return
	var host_id: String = lobby.get("host_id", "")
	if host_id.is_empty():
		return
	_lobby_client.fetch_player_profile(host_id)


func _on_player_profile_fetched(profile: Dictionary) -> void:
	if profile.is_empty():
		return
	var display_name: String = profile.get("display_name", "Unknown")
	var rank_idx: int = clampi(profile.get("rank", 0), 0, RANK_LABELS.size() - 1)
	var pp: int = profile.get("prestige_points", 0)
	var games: int = profile.get("games_played", 0)
	var wins: int = profile.get("games_won", 0)
	var kills: int = profile.get("total_kills", 0)
	var win_pct := 0.0
	if games > 0:
		win_pct = float(wins) / float(games) * 100.0

	_player_card_name.text = "%s %s" % [RANK_LABELS[rank_idx], display_name]

	_player_card_rank.text = "Rank: %s  |  PP: %s" % [RANK_LABELS[rank_idx], _format_number(pp)]

	var regiment_data: Variant = profile.get("regiments", null)
	if regiment_data is Dictionary and regiment_data.get("name", "") != "":
		_player_card_regiment.text = "[%s] %s" % [regiment_data.get("tag", ""), regiment_data.get("name", "")]
		_player_card_regiment.visible = true
	else:
		_player_card_regiment.text = ""
		_player_card_regiment.visible = false

	_player_card_stats.text = "Games: %d\nWins: %d (%.0f%%)\nKills: %d" % [games, wins, win_pct, kills]

	_show_player_card()


func _show_player_card() -> void:
	_player_card_panel.visible = true
	_player_card_visible = true
	_center_container.offset_left = 240


func _close_player_card() -> void:
	_player_card_panel.visible = false
	_player_card_visible = false
	_center_container.offset_left = 0


func _format_number(n: int) -> String:
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)


const RANK_LABELS := ["PVT", "PFC", "CPL", "SGT", "SSG", "SFC", "MSG", "2LT", "1LT", "CPT"]


# ─────────────────────────────────────────────────────────────────────────
# Briefing dialog
# ─────────────────────────────────────────────────────────────────────────

func _build_briefing_dialog() -> void:
	_briefing_dialog = Window.new()
	_briefing_dialog.title = "Skirmish Briefing"
	_briefing_dialog.size = Vector2i(440, 320)
	_briefing_dialog.unresizable = true
	_briefing_dialog.visible = false
	_briefing_dialog.exclusive = true
	_briefing_dialog.transient = true
	_briefing_dialog.close_requested.connect(_close_briefing)
	add_child(_briefing_dialog)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_briefing_dialog.add_child(panel)
	CocUiTheme.apply_to(panel)

	var outer_margin := MarginContainer.new()
	outer_margin.add_theme_constant_override("margin_left", 20)
	outer_margin.add_theme_constant_override("margin_top", 16)
	outer_margin.add_theme_constant_override("margin_right", 20)
	outer_margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(outer_margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	outer_margin.add_child(vbox)

	# Room label
	_briefing_room_label = Label.new()
	_briefing_room_label.text = "Room 1 — Open Game"
	_briefing_room_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_briefing_room_label.add_theme_font_size_override("font_size", 15)
	vbox.add_child(_briefing_room_label)

	var subtitle := Label.new()
	subtitle.text = "Choose your battlefield and deploy."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	vbox.add_child(subtitle)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	# Battlefield row
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 8)
	vbox.add_child(map_row)
	var map_label := Label.new()
	map_label.text = "Battlefield:"
	map_label.custom_minimum_size = Vector2(100, 0)
	map_label.add_theme_font_size_override("font_size", 13)
	map_row.add_child(map_label)
	_briefing_map_dropdown = OptionButton.new()
	_briefing_map_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_briefing_map_dropdown.custom_minimum_size = Vector2(0, 30)
	for entry in MapDataClass.MULTIPLAYER_MAPS:
		_briefing_map_dropdown.add_item("%s (%s)" % [entry["display_name"], entry["team_sizes"]])
	_briefing_map_dropdown.item_selected.connect(_on_briefing_map_selected)
	map_row.add_child(_briefing_map_dropdown)

	# Team size row
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	vbox.add_child(size_row)
	var size_label := Label.new()
	size_label.text = "Team Size:"
	size_label.custom_minimum_size = Vector2(100, 0)
	size_label.add_theme_font_size_override("font_size", 13)
	size_row.add_child(size_label)
	_briefing_size_dropdown = OptionButton.new()
	_briefing_size_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_briefing_size_dropdown.custom_minimum_size = Vector2(0, 30)
	size_row.add_child(_briefing_size_dropdown)
	_populate_briefing_team_sizes()

	# Match length row
	var length_row := HBoxContainer.new()
	length_row.add_theme_constant_override("separation", 8)
	vbox.add_child(length_row)
	var length_label := Label.new()
	length_label.text = "Match Length:"
	length_label.custom_minimum_size = Vector2(100, 0)
	length_label.add_theme_font_size_override("font_size", 13)
	length_row.add_child(length_label)
	_briefing_length_dropdown = OptionButton.new()
	_briefing_length_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_briefing_length_dropdown.custom_minimum_size = Vector2(0, 30)
	_briefing_length_dropdown.add_item("10 minutes")
	_briefing_length_dropdown.add_item("15 minutes")
	_briefing_length_dropdown.add_item("20 minutes")
	_briefing_length_dropdown.select(1)
	length_row.add_child(_briefing_length_dropdown)

	# AI difficulty row (Training rooms only)
	_briefing_ai_row = HBoxContainer.new()
	_briefing_ai_row.add_theme_constant_override("separation", 8)
	_briefing_ai_row.visible = false
	vbox.add_child(_briefing_ai_row)
	var ai_label := Label.new()
	ai_label.text = "AI Difficulty:"
	ai_label.custom_minimum_size = Vector2(100, 0)
	ai_label.add_theme_font_size_override("font_size", 13)
	_briefing_ai_row.add_child(ai_label)
	_briefing_ai_dropdown = OptionButton.new()
	_briefing_ai_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_briefing_ai_dropdown.custom_minimum_size = Vector2(0, 30)
	_briefing_ai_dropdown.add_item("Easy")
	_briefing_ai_dropdown.add_item("Normal")
	_briefing_ai_dropdown.add_item("Hard")
	_briefing_ai_dropdown.select(1)
	_briefing_ai_row.add_child(_briefing_ai_dropdown)

	var sep2 := HSeparator.new()
	vbox.add_child(sep2)

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var enter_btn := Button.new()
	enter_btn.text = "Enter Battlefield"
	enter_btn.custom_minimum_size = Vector2(140, 34)
	enter_btn.pressed.connect(_on_briefing_confirm)
	btn_row.add_child(enter_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(80, 34)
	cancel_btn.pressed.connect(_close_briefing)
	btn_row.add_child(cancel_btn)


func _open_briefing(room_number: int) -> void:
	_briefing_room_number = room_number
	var room_cfg: Dictionary = {}
	for cfg in _room_config:
		if cfg["number"] == room_number:
			room_cfg = cfg
			break
	_briefing_room_type = room_cfg.get("type", "open")
	_briefing_room_label.text = "Room %d — %s" % [room_number, room_cfg.get("name", "Game")]
	_briefing_map_dropdown.select(0)
	_populate_briefing_team_sizes()
	_briefing_length_dropdown.select(1)
	_briefing_ai_row.visible = _briefing_room_type == "training"
	if _briefing_ai_row.visible:
		_briefing_ai_dropdown.select(1)
	_briefing_dialog.popup_centered()


func _close_briefing() -> void:
	_briefing_dialog.visible = false
	_briefing_room_number = 0


func _on_briefing_map_selected(_idx: int) -> void:
	_populate_briefing_team_sizes()


func _populate_briefing_team_sizes() -> void:
	_briefing_size_dropdown.clear()
	var map_idx := _briefing_map_dropdown.selected
	if map_idx < 0 or map_idx >= MapDataClass.MULTIPLAYER_MAPS.size():
		_briefing_size_dropdown.add_item("1v1")
		return
	var sizes: Array = MapDataClass.MULTIPLAYER_MAPS[map_idx].get("supported_sizes", [1])
	for s: int in sizes:
		_briefing_size_dropdown.add_item("%dv%d" % [s, s])


func _get_briefing_team_size() -> int:
	var map_idx := _briefing_map_dropdown.selected
	if map_idx < 0 or map_idx >= MapDataClass.MULTIPLAYER_MAPS.size():
		return 1
	var sizes: Array = MapDataClass.MULTIPLAYER_MAPS[map_idx].get("supported_sizes", [1])
	var size_idx := _briefing_size_dropdown.selected
	if size_idx < 0 or size_idx >= sizes.size():
		return 1
	return sizes[size_idx]


const MATCH_LENGTH_OPTIONS: Array[int] = [600, 900, 1200]

func _on_briefing_confirm() -> void:
	var room_number := _briefing_room_number
	var map_idx := _briefing_map_dropdown.selected
	var map_id := "ff_farm"
	if map_idx >= 0 and map_idx < MapDataClass.MULTIPLAYER_MAPS.size():
		map_id = MapDataClass.MULTIPLAYER_MAPS[map_idx]["id"]
	var team_size := _get_briefing_team_size()
	var match_name := "%s's Game" % SupabaseAuth.display_name
	var length_idx := _briefing_length_dropdown.selected
	var match_length_sec: int = MATCH_LENGTH_OPTIONS[clampi(length_idx, 0, MATCH_LENGTH_OPTIONS.size() - 1)]
	var host_regiment_id := SupabaseAuth.regiment_id if _briefing_room_type == "regimental" else ""
	_active_room_number = room_number
	_close_briefing()
	_set_status("Creating game in Room %d..." % room_number, Color.WHITE)
	_lobby_client.create_lobby(match_name, _effective_server_url(), map_id, team_size, room_number, match_length_sec, host_regiment_id)


# ─────────────────────────────────────────────────────────────────────────
# Signal wiring
# ─────────────────────────────────────────────────────────────────────────

func _connect_signals() -> void:
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_leaderboard_button.pressed.connect(_on_leaderboard_pressed)
	_regiments_button.pressed.connect(_on_regiments_pressed)
	if _admin_button != null:
		_admin_button.pressed.connect(_on_admin_pressed)
	_back_button.pressed.connect(_on_back_pressed)

	_lobby_client.lobbies_listed.connect(_on_lobbies_listed)
	_lobby_client.lobby_created.connect(_on_lobby_created)
	_lobby_client.lobby_joined.connect(_on_lobby_joined)
	_lobby_client.lobby_error.connect(_on_lobby_error)
	_lobby_client.lobby_deleted.connect(_on_lobby_deleted)
	_lobby_client.player_profile_fetched.connect(_on_player_profile_fetched)


# ─────────────────────────────────────────────────────────────────────────
# Room action handler
# ─────────────────────────────────────────────────────────────────────────

func _on_room_action(room_number: int) -> void:
	var room_data: Dictionary = _room_rows.get(room_number, {})
	var lobby: Dictionary = room_data.get("lobby", {})

	if _is_rejoinable(lobby):
		_rejoin_match()
		return

	# Check if this is the player's own room — "Leave" action
	if not lobby.is_empty():
		var host_id: String = lobby.get("host_id", "")
		var lobby_id: String = lobby.get("id", "")
		var is_mine := host_id == SupabaseAuth.user_id or lobby_id == _joined_lobby_id
		if is_mine:
			_on_cancel_hosted()
			return

	# Guard: can't join another room while in one
	if not _hosted_lobby_id.is_empty() or not _joined_lobby_id.is_empty():
		_set_status("Leave your current room first.", Color.ORANGE)
		return

	var room_type := _get_room_type(room_number)
	if room_type == "regimental" and SupabaseAuth.regiment_id.is_empty():
		_set_status("You must be in a regiment to use Regimental rooms.", Color.ORANGE)
		return

	if lobby.is_empty():
		_open_briefing(room_number)
	else:
		var status: String = lobby.get("status", "")
		if status == "waiting":
			var lobby_id: String = lobby.get("id", "")
			_active_room_number = room_number
			_set_status("Joining Room %d..." % room_number, Color.WHITE)
			_lobby_client.join_lobby(lobby_id)
		else:
			_set_status("That room has a match in progress.", Color.ORANGE)


# ─────────────────────────────────────────────────────────────────────────
# Button handlers
# ─────────────────────────────────────────────────────────────────────────

func _on_refresh_pressed() -> void:
	_set_status("Refreshing...", Color.WHITE)
	_lobby_client.list_lobbies()


func _on_leaderboard_pressed() -> void:
	LeaderboardScript.return_scene = LOBBY_BROWSER_SCENE
	get_tree().change_scene_to_file(LEADERBOARD_SCENE)


func _on_regiments_pressed() -> void:
	RegimentBrowserScript.return_scene = LOBBY_BROWSER_SCENE
	get_tree().change_scene_to_file(REGIMENT_SCENE)


func _on_admin_pressed() -> void:
	AdminBrowserScript.return_scene = LOBBY_BROWSER_SCENE
	get_tree().change_scene_to_file(ADMIN_SCENE)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MODE_SELECT_SCENE)


func _on_auto_refresh() -> void:
	_lobby_client.list_lobbies()


# ─────────────────────────────────────────────────────────────────────────
# Lobby client callbacks
# ─────────────────────────────────────────────────────────────────────────

func _on_lobbies_listed(lobbies: Array) -> void:
	# Recover hosted lobby ID if we lost track (e.g., scene reload, quit while hosting)
	if _hosted_lobby_id.is_empty() and _joined_lobby_id.is_empty():
		for lobby_dict in lobbies:
			var lobby: Dictionary = lobby_dict
			var lobby_status: String = lobby.get("status", "")
			if lobby.get("host_id", "") == SupabaseAuth.user_id:
				if lobby_status == "waiting":
					_hosted_lobby_id = lobby.get("id", "")
					var rn_val = lobby.get("room_number", 0)
					_active_room_number = int(rn_val) if rn_val != null else 0
				elif lobby_status == "in_progress" and not _is_rejoinable(lobby):
					_lobby_client.delete_lobby(lobby.get("id", ""))
				break

	## Forget the rejoin record once its lobby is no longer running.
	if not _rejoin.is_empty():
		var still_running := false
		for lobby_dict in lobbies:
			if _is_rejoinable(lobby_dict as Dictionary):
				still_running = true
				break
		if not still_running:
			RejoinStoreClass.clear()
			_rejoin = {}

	# Build room_number -> lobby lookup
	var room_to_lobby: Dictionary = {}
	for lobby_dict in lobbies:
		var lobby: Dictionary = lobby_dict
		var rn_val = lobby.get("room_number", 0)
		var rn: int = int(rn_val) if rn_val != null else 0
		if rn >= 1 and rn <= _max_rooms:
			room_to_lobby[rn] = lobby

	# Update each room row
	for room_cfg in _room_config:
		var rn: int = room_cfg["number"]
		var lobby: Dictionary = room_to_lobby.get(rn, {})
		_update_room_row(rn, lobby)

	# Check if our hosted/joined lobby transitioned to in_progress
	var my_lobby_id := _hosted_lobby_id if not _hosted_lobby_id.is_empty() else _joined_lobby_id
	if not my_lobby_id.is_empty():
		var found := false
		for lobby_dict in lobbies:
			var lobby: Dictionary = lobby_dict
			if lobby.get("id", "") == my_lobby_id:
				found = true
				var current: int = lobby.get("current_players", 1)
				var max_p: int = lobby.get("max_players", 2)
				if lobby.get("status", "") == "in_progress":
					_set_status("All players joined! Starting match...", Color.GREEN)
					var host_url: String = lobby.get("server_url", "")
					if host_url.is_empty():
						host_url = _effective_server_url()
					var lobby_map: String = lobby.get("map_id", "")
					var lobby_team_size: int = lobby.get("team_size", 1)
					var lobby_length: int = lobby.get("match_length_sec", 900)
					_start_multiplayer(host_url, lobby_map, lobby_team_size, lobby_length, my_lobby_id)
					return
				else:
					_set_status("Waiting for players (%d/%d)..." % [current, max_p], Color.GREEN)
				break
		if not found and not _joined_lobby_id.is_empty():
			_joined_lobby_id = ""
			_set_status("The lobby was cancelled by the host.", Color.ORANGE)

	if not _rejoin.is_empty() and not _starting_match:
		_set_status("Your match is still running. Click Rejoin to get back in.", Color.GREEN)
		return

	# Update status for empty state
	if _hosted_lobby_id.is_empty() and _joined_lobby_id.is_empty():
		var waiting_count := 0
		for rn: int in _room_rows:
			var lobby: Dictionary = _room_rows[rn].get("lobby", {})
			if not lobby.is_empty() and lobby.get("status", "") == "waiting":
				var host_id: String = lobby.get("host_id", "")
				if host_id != SupabaseAuth.user_id:
					waiting_count += 1
		if waiting_count > 0:
			_set_status("%d room(s) with games waiting" % waiting_count, Color.WHITE)
		else:
			_set_status("All rooms open. Pick a room to start a game.", Color.WHITE)


func _update_room_row(room_number: int, lobby: Dictionary) -> void:
	var row_data: Dictionary = _room_rows.get(room_number, {})
	if row_data.is_empty():
		return

	row_data["lobby"] = lobby
	var desc_label: Button = row_data["desc_label"]
	var type_label: Label = row_data["type_label"]
	var players_label: Label = row_data["players_label"]
	var action_btn: Button = row_data["action_btn"]
	var room_cfg: Dictionary = row_data["config"]

	if lobby.is_empty() or lobby.get("status", "") == "finished":
		# Empty or finished room
		desc_label.text = room_cfg["name"]
		type_label.text = room_cfg["name"]
		players_label.text = "--"
		action_btn.text = "Join Room"
		action_btn.disabled = false
	else:
		var status: String = lobby.get("status", "waiting")
		var host_id: String = lobby.get("host_id", "")
		var lobby_id: String = lobby.get("id", "")
		var is_mine: bool = host_id == SupabaseAuth.user_id or lobby_id == _joined_lobby_id
		var current: int = lobby.get("current_players", 1)
		var max_p: int = lobby.get("max_players", 2)
		var ts: int = lobby.get("team_size", 1)

		if _is_rejoinable(lobby):
			desc_label.text = "Your match in progress"
			type_label.text = "%dv%d" % [ts, ts]
			players_label.text = "%d/%d" % [current, max_p]
			action_btn.text = "Rejoin"
			action_btn.disabled = _starting_match
			return

		# Description
		if status == "in_progress":
			desc_label.text = "Match in progress"
		elif is_mine:
			desc_label.text = "%s — %s" % [room_cfg["name"], lobby.get("match_name", "My Game")]
		else:
			desc_label.text = "%s — %s" % [room_cfg["name"], lobby.get("host_display_name", "Waiting")]

		# Type column — show team size format
		type_label.text = "%dv%d" % [ts, ts]

		# Players
		players_label.text = "%d/%d" % [current, max_p]

		# Action button
		if is_mine:
			action_btn.text = "Leave"
			action_btn.disabled = false
		elif status == "waiting":
			action_btn.text = "Join Room"
			action_btn.disabled = false
		else:
			action_btn.text = "In Game"
			action_btn.disabled = true


func _on_lobby_created(lobby: Dictionary) -> void:
	_hosted_lobby_id = lobby.get("id", "")
	var max_p: int = lobby.get("max_players", 2)
	_set_status("Game created! Waiting for players (1/%d)..." % max_p, Color.GREEN)
	_lobby_client.list_lobbies()


func _on_lobby_joined(lobby: Dictionary) -> void:
	var status: String = lobby.get("status", "waiting")
	if status == "in_progress":
		_set_status("Joined! Starting match...", Color.GREEN)
		var server_url: String = lobby.get("server_url", "")
		if server_url.is_empty():
			server_url = _effective_server_url()
		var lobby_map: String = lobby.get("map_id", "")
		var lobby_team_size: int = lobby.get("team_size", 1)
		var lobby_length: int = lobby.get("match_length_sec", 900)
		_start_multiplayer(server_url, lobby_map, lobby_team_size, lobby_length, str(lobby.get("id", "")))
	else:
		_joined_lobby_id = lobby.get("id", "")
		var current: int = lobby.get("current_players", 1)
		var max_p: int = lobby.get("max_players", 2)
		_set_status("Joined! Waiting for players (%d/%d)..." % [current, max_p], Color.GREEN)
		_lobby_client.list_lobbies()


func _on_lobby_error(msg: String) -> void:
	if "409" in msg:
		_set_status("Room already taken! Pick another room.", Color.ORANGE)
	else:
		_set_status(msg, Color.RED)


func _on_lobby_deleted() -> void:
	_hosted_lobby_id = ""
	_active_room_number = 0
	_set_status("Left the room.", Color.WHITE)
	_lobby_client.list_lobbies()


func _on_cancel_hosted() -> void:
	if not _joined_lobby_id.is_empty():
		if SupabaseAuth.is_local_guest_mode:
			_lobby_client.delete_lobby(_joined_lobby_id)
		_joined_lobby_id = ""
		_active_room_number = 0
		_set_status("Left the room.", Color.WHITE)
		if not SupabaseAuth.is_local_guest_mode:
			_lobby_client.list_lobbies()
		return
	if _hosted_lobby_id.is_empty():
		return
	_lobby_client.delete_lobby(_hosted_lobby_id)


# ─────────────────────────────────────────────────────────────────────────
# Game transition
# ─────────────────────────────────────────────────────────────────────────

func _start_multiplayer(server_url: String, map_id: String = "", team_size: int = 1, match_length_sec: int = 900, lobby_id: String = "") -> void:
	if _starting_match:
		return
	_starting_match = true
	_refresh_timer.stop()
	RejoinStoreClass.save(lobby_id, server_url)
	GameModeManager.set_mode(GameMode.LOCAL_MULTIPLAYER)
	NetworkClient.disconnect_from_server()
	NetworkClient.server_url = server_url
	NetworkClient.selected_map_id = map_id
	NetworkClient.selected_team_size = team_size
	NetworkClient.match_length_sec = match_length_sec
	var room_type := _get_room_type(_active_room_number)
	NetworkClient.is_training = room_type == "training"
	NetworkClient.is_regimental = room_type == "regimental"
	var connected := await NetworkClient.connect_and_wait()
	if not connected:
		_starting_match = false
		_set_status("Could not connect to game server.", Color.RED)
		_refresh_timer.start()
		return
	get_tree().change_scene_to_file(SIDE_SELECT_SCENE)


func _is_rejoinable(lobby: Dictionary) -> bool:
	return (
		not _rejoin.is_empty()
		and not lobby.is_empty()
		and lobby.get("status", "") == "in_progress"
		and str(lobby.get("id", "")) == str(_rejoin.get("lobby_id", ""))
	)


func _rejoin_match() -> void:
	if _starting_match:
		return
	_starting_match = true
	_refresh_timer.stop()
	_set_status("Rejoining your match...", Color.GREEN)
	GameModeManager.set_mode(GameMode.LOCAL_MULTIPLAYER)
	NetworkClient.disconnect_from_server()
	var url := str(_rejoin.get("server_url", ""))
	NetworkClient.server_url = url if not url.is_empty() else _effective_server_url()
	## Bare hello: map/size/training fields would reconfigure a fresh match if our slot is gone.
	NetworkClient.selected_map_id = ""
	NetworkClient.selected_team_size = 1
	NetworkClient.match_length_sec = 0
	NetworkClient.is_training = false
	NetworkClient.is_regimental = false
	if await NetworkClient.connect_and_wait():
		var deadline_msec := Time.get_ticks_msec() + int(REJOIN_WAIT_SEC * 1000.0)
		while Time.get_ticks_msec() < deadline_msec:
			if _rejoin_confirmed():
				break
			## Welcome without the reconnected flag: the server no longer holds our slot.
			if not NetworkClient.client_id.is_empty() and not NetworkClient.welcome_reconnected:
				break
			await get_tree().process_frame
	if _rejoin_confirmed():
		var cfg = MatchConfigClass.default_local_multiplayer_1v1()
		cfg.local_player_id = 1 if PlayerSides.assigned_team_id == Team.USA else 2
		MatchConfigStoreClass.set_pending(cfg)
		get_tree().change_scene_to_file(MAIN_SCENE)
		return
	NetworkClient.disconnect_from_server()
	RejoinStoreClass.clear()
	_rejoin = {}
	_starting_match = false
	_set_status("Could not rejoin - that match has ended.", Color.ORANGE)
	_refresh_timer.start()
	_lobby_client.list_lobbies()


func _rejoin_confirmed() -> bool:
	return (
		NetworkClient.welcome_reconnected
		and NetworkClient.match_ready_received
		and PlayerSides.has_assignment()
	)


# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────

func _get_room_type(room_number: int) -> String:
	for cfg in _room_config:
		if cfg["number"] == room_number:
			return cfg["type"]
	return "open"


func _get_lan_ip() -> String:
	var candidates: Array[String] = []
	for addr in IP.get_local_addresses():
		if ":" in addr:
			continue
		if addr.begins_with("127."):
			continue
		if addr.begins_with("172."):
			continue
		if addr.begins_with("192.168.188.") or addr.begins_with("192.168.228."):
			continue
		if addr.begins_with("192.168.") or addr.begins_with("10."):
			candidates.append(addr)
	if not candidates.is_empty():
		return candidates[0]
	return "127.0.0.1"


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)
