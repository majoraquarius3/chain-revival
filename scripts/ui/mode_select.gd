extends Control
## Startup screen: Single Player / Multiplayer (+ optional Dev tools).

const MAIN_SCENE := "res://scenes/main.tscn"
const MATCH_SETUP_SCENE := "res://scenes/match_setup.tscn"
const SIDE_SELECT_SCENE := "res://scenes/side_select.tscn"
const EDITOR_SCENE := "res://scenes/editor/map_editor.tscn"
const ASSET_ANIM_EDITOR_SCENE := "res://scenes/editor/asset_animation_editor.tscn"
const AUTH_SCREEN_SCENE := "res://scenes/auth_screen.tscn"
const LOBBY_BROWSER_SCENE := "res://scenes/lobby_browser.tscn"
const LEADERBOARD_SCENE := "res://scenes/leaderboard.tscn"
const LeaderboardScript := preload("res://scripts/ui/leaderboard.gd")
const MatchConfigClass := preload("res://scripts/core/match_config.gd")
const MatchConfigStoreClass := preload("res://scripts/core/match_config_store.gd")
const AutoUpdaterClass := preload("res://scripts/network/auto_updater.gd")

@onready var _single_player_button: Button = $Center/Panel/Margin/VBox/SinglePlayerButton
@onready var _multiplayer_button: Button = $Center/Panel/Margin/VBox/MultiplayerButton
@onready var _offline_quick_button: Button = $Center/Panel/Margin/VBox/DevBox/OfflineQuickButton
@onready var _offline_quick_ai_button: Button = $Center/Panel/Margin/VBox/DevBox/OfflineQuickAiButton
@onready var _survival_mode_button: Button = $Center/Panel/Margin/VBox/SurvivalModeButton
@onready var _tutorial_button: Button = $Center/Panel/Margin/VBox/TutorialButton
@onready var _how_to_play_button: Button = $Center/Panel/Margin/VBox/HowToPlayButton
@onready var _editor_button: Button = $Center/Panel/Margin/VBox/DevBox/EditorButton
@onready var _asset_anim_button: Button = $Center/Panel/Margin/VBox/DevBox/AssetAnimEditorButton

var _how_to_play_dialog: AcceptDialog
var _updater: Node
var _update_dialog: AcceptDialog
var _update_progress_label: Label


var _sign_in_label: Label

func _ready() -> void:
	CocUiTheme.apply_to(self)
	_single_player_button.pressed.connect(_on_single_player_pressed)
	_multiplayer_button.pressed.connect(_on_multiplayer_pressed)
	_offline_quick_button.pressed.connect(_on_offline_quick_pressed)
	_offline_quick_ai_button.pressed.connect(_on_offline_quick_ai_pressed)
	_survival_mode_button.pressed.connect(_on_survival_mode_pressed)
	_tutorial_button.pressed.connect(_on_tutorial_pressed)
	_how_to_play_button.pressed.connect(_on_how_to_play_pressed)
	_editor_button.pressed.connect(_on_editor_pressed)
	_asset_anim_button.pressed.connect(_on_asset_anim_editor_pressed)
	if BuildConfig.is_survival_playtest():
		_apply_survival_playtest_menu()
	_add_auth_ui()
	_hide_dev_tools_unless_signed_in()
	_add_lan_button()
	_add_leaderboard_button()
	_add_version_label()
	_add_settings_button()
	_add_quit_button()
	_show_first_launch_hint()
	_check_for_updates()


func _add_lan_button() -> void:
	var vbox := get_node_or_null("Center/Panel/Margin/VBox") as VBoxContainer
	if vbox == null:
		return
	var lan_btn := Button.new()
	lan_btn.text = "LAN Multiplayer"
	lan_btn.custom_minimum_size = Vector2(400, 36)
	lan_btn.add_theme_font_size_override("font_size", 16)
	lan_btn.pressed.connect(_on_lan_multiplayer_pressed)
	vbox.add_child(lan_btn)
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box != null:
		vbox.move_child(lan_btn, dev_box.get_index())


func _add_leaderboard_button() -> void:
	var vbox := get_node_or_null("Center/Panel/Margin/VBox") as VBoxContainer
	if vbox == null:
		return
	var lb_btn := Button.new()
	lb_btn.text = "Leaderboard"
	lb_btn.custom_minimum_size = Vector2(400, 44)
	lb_btn.add_theme_font_size_override("font_size", 20)
	lb_btn.pressed.connect(_on_leaderboard_pressed)
	# Insert before the DevBox (second-to-last major element)
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box != null:
		var dev_idx := dev_box.get_index()
		vbox.add_child(lb_btn)
		vbox.move_child(lb_btn, dev_idx)
	else:
		vbox.add_child(lb_btn)


func _on_leaderboard_pressed() -> void:
	if SupabaseAuth.is_signed_in and SupabaseAuth.is_banned:
		await _recheck_ban_and_proceed(LEADERBOARD_SCENE)
		return
	LeaderboardScript.return_scene = "res://scenes/mode_select.tscn"
	get_tree().change_scene_to_file(LEADERBOARD_SCENE)


func _add_auth_ui() -> void:
	var vbox := get_node_or_null("Center/Panel/Margin/VBox") as VBoxContainer
	if vbox == null:
		return
	# Add a sign-in/account label and button at the top of the menu
	var auth_box := HBoxContainer.new()
	auth_box.alignment = BoxContainer.ALIGNMENT_CENTER
	auth_box.add_theme_constant_override("separation", 8)
	vbox.add_child(auth_box)
	vbox.move_child(auth_box, 0)  # Put at the very top

	_sign_in_label = Label.new()
	_sign_in_label.add_theme_font_size_override("font_size", 16)
	auth_box.add_child(_sign_in_label)

	var auth_button := Button.new()
	auth_button.add_theme_font_size_override("font_size", 14)
	auth_box.add_child(auth_button)

	if SupabaseAuth.is_signed_in:
		if SupabaseAuth.is_banned:
			_sign_in_label.text = "BANNED: %s" % SupabaseAuth.display_name
			_sign_in_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		else:
			_sign_in_label.text = "Signed in as %s" % SupabaseAuth.display_name
		auth_button.text = "Sign Out"
		auth_button.pressed.connect(func(): SupabaseAuth.sign_out(); get_tree().reload_current_scene())
	else:
		_sign_in_label.text = "Not signed in"
		auth_button.text = "Sign In"
		auth_button.pressed.connect(func(): get_tree().change_scene_to_file(AUTH_SCREEN_SCENE))

	# If session is being restored asynchronously, refresh the UI when it completes.
	if not SupabaseAuth.auth_state_changed.is_connected(_on_auth_state_changed):
		SupabaseAuth.auth_state_changed.connect(_on_auth_state_changed)


func _on_auth_state_changed(_signed_in: bool) -> void:
	get_tree().reload_current_scene()


func _hide_dev_tools_unless_signed_in() -> void:
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box == null:
		return
	dev_box.visible = SupabaseAuth.is_signed_in and (SupabaseAuth.is_admin or SupabaseAuth.is_moderator)
	if not SupabaseAuth.profile_loaded.is_connected(_on_profile_loaded):
		SupabaseAuth.profile_loaded.connect(_on_profile_loaded)


func _on_profile_loaded() -> void:
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box == null:
		return
	dev_box.visible = SupabaseAuth.is_signed_in and (SupabaseAuth.is_admin or SupabaseAuth.is_moderator)


func _apply_survival_playtest_menu() -> void:
	## Stay on this menu. Survival is the only playable mode.
	if _single_player_button != null:
		_single_player_button.visible = false
	if _tutorial_button != null:
		_tutorial_button.visible = false
	if _multiplayer_button != null:
		_multiplayer_button.visible = false
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box != null:
		dev_box.visible = false
	if _survival_mode_button != null:
		_survival_mode_button.text = "Play Survival"
	var subtitle := get_node_or_null("Center/Panel/Margin/VBox/Subtitle") as Label
	if subtitle != null:
		subtitle.text = "Survival Playtest"


func _on_single_player_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	_open_match_setup(MatchConfigClass.GameModeKind.SINGLE_PLAYER)


func _on_multiplayer_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	if SupabaseAuth.is_signed_in:
		if SupabaseAuth.is_banned:
			await _recheck_ban_and_proceed(LOBBY_BROWSER_SCENE)
			return
		get_tree().change_scene_to_file(LOBBY_BROWSER_SCENE)
	else:
		get_tree().change_scene_to_file(AUTH_SCREEN_SCENE)


func _on_lan_multiplayer_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	_set_buttons_enabled(false)
	GameModeManager.set_mode(GameMode.LOCAL_MULTIPLAYER)
	var connected := await NetworkClient.connect_and_wait()
	if not connected:
		GameLog.log_system("[ModeSelect] Local multiplayer server is not running.")
		_set_buttons_enabled(true)
		return
	get_tree().change_scene_to_file(SIDE_SELECT_SCENE)


func _open_match_setup(game_mode_kind: int) -> void:
	if BuildConfig.is_survival_playtest():
		return
	PlayerSides.clear()
	MatchConfigStoreClass.set_setup_game_mode(game_mode_kind)
	get_tree().change_scene_to_file(MATCH_SETUP_SCENE)


func _on_offline_quick_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	## Dev hotseat: Farm Fight 1v1, both sides human, no AI.
	PlayerSides.clear()
	GameModeManager.set_mode(GameMode.OFFLINE_DEV)
	MatchConfigStoreClass.set_pending(MatchConfigClass.default_offline_1v1())
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_offline_quick_ai_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	## Dev: same one-click start as above, but Germany is AI — the hotseat version has no
	## AI on either side, so use this one when testing commander behaviour.
	PlayerSides.clear()
	GameModeManager.set_mode(GameMode.OFFLINE_DEV)
	MatchConfigStoreClass.set_pending(MatchConfigClass.default_offline_1v1_vs_ai())
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_survival_mode_pressed() -> void:
	## Survival: US human vs recurring GE AI waves on ff_farm_survival.
	PlayerSides.clear()
	GameModeManager.set_mode(GameMode.OFFLINE_DEV)
	MatchConfigStoreClass.set_pending(MatchConfigClass.default_survival_1v_all())
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_tutorial_pressed() -> void:
	PlayerSides.clear()
	GameModeManager.set_mode(GameMode.OFFLINE_DEV)
	MatchConfigStoreClass.set_pending(MatchConfigClass.default_tutorial())
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_how_to_play_pressed() -> void:
	_ensure_how_to_play_dialog()
	if _how_to_play_dialog != null:
		_how_to_play_dialog.popup_centered()


func _ensure_how_to_play_dialog() -> void:
	if _how_to_play_dialog != null:
		return
	var dlg := AcceptDialog.new()
	dlg.title = "How to Play"
	dlg.ok_button_text = "Close"
	dlg.unresizable = true
	dlg.min_size = Vector2(780, 620)
	CocUiTheme.apply_to(dlg)
	var paper := _how_to_play_paper_style()
	dlg.add_theme_stylebox_override("panel", paper)
	dlg.add_theme_stylebox_override("embedded_border", paper)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 12)
	dlg.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(720, 500)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.custom_minimum_size.x = 700
	scroll.add_child(page)
	_fill_how_to_play_page(page)

	add_child(dlg)
	_how_to_play_dialog = dlg


func _how_to_play_paper_style() -> StyleBoxFlat:
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.94, 0.92, 0.86)
	paper.border_color = Color(0.55, 0.52, 0.46)
	paper.set_border_width_all(1)
	paper.set_content_margin_all(8)
	return paper


func _fill_how_to_play_page(page: VBoxContainer) -> void:
	_howto_heading(page, "Survival")
	_howto_body(
		page,
		"You command a U.S. fireteam on the farm. German squads keep arriving. Hold the field as long as you can.",
	)
	_howto_body(
		page,
		"After you start, pick a difficulty. That only changes how often a new enemy fireteam deploys:",
	)
	_howto_row(page, "Normal", "New squad every 60 seconds")
	_howto_row(page, "Hard", "New squad every 30 seconds")
	_howto_row(page, "A-town", "New squad every 15 seconds")

	_howto_heading(page, "Camera")
	_howto_row(page, "WASD / arrows", "Pan the map")
	_howto_row(page, "Mouse wheel", "Zoom")
	_howto_row(page, "Right-drag or middle-drag", "Pan")
	_howto_row(page, "Q / E", "Rotate the view (or use Rotate Left / Right)")
	_howto_row(page, "Center", "Jump the camera back to your fireteam")

	_howto_heading(page, "Giving Orders")
	_howto_body(
		page,
		"Click a soldier’s row on the bottom bar to select him. The top row issues orders to the whole fireteam.",
	)
	_howto_body(page, "Click a command, then click the map:")
	_howto_row(page, "Fire at", "Click an enemy or tile to shoot")
	_howto_row(page, "Run To / Crawl To", "Click a tile to move")
	_howto_row(page, "Face…", "Click a tile or enemy to turn that way (no shot)")
	_howto_row(page, "Down / Up", "Drop prone or stand up")
	_howto_row(page, "Grenade", "Click a tile within 7 tiles")
	_howto_row(page, "Fire at Will", "Shoot visible enemies automatically")
	_howto_row(page, "Hold Fire", "Stop automatic fire; use Fire at for aimed shots")
	_howto_row(page, "Right-click", "Cancel Fire at, Face, or Grenade targeting")
	_howto_spacer(page)
	_howto_body(page, "Retreat ends the match and concedes the field.")
	_howto_body(
		page,
		"Tips: crawling and going prone help you survive incoming fire. Use cover, and watch ammo on each soldier’s row.",
	)


func _howto_heading(page: VBoxContainer, title: String) -> void:
	if page.get_child_count() > 0:
		_howto_spacer(page)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(0.18, 0.16, 0.12))
	page.add_child(label)
	var rule := ColorRect.new()
	rule.color = Color(0.62, 0.58, 0.50)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(rule)


func _howto_body(page: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", Color(0.16, 0.15, 0.12))
	page.add_child(label)


func _howto_row(page: VBoxContainer, action: String, detail: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var key := Label.new()
	key.text = action
	key.custom_minimum_size = Vector2(230, 0)
	key.add_theme_font_size_override("font_size", 19)
	key.add_theme_color_override("font_color", Color(0.22, 0.20, 0.14))
	row.add_child(key)

	var value := Label.new()
	value.text = detail
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.add_theme_font_size_override("font_size", 19)
	value.add_theme_color_override("font_color", Color(0.16, 0.15, 0.12))
	row.add_child(value)
	page.add_child(row)


func _howto_spacer(page: VBoxContainer) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	page.add_child(spacer)


var _settings_dialog: AcceptDialog
var _master_slider: HSlider
var _sfx_slider: HSlider
var _ambient_slider: HSlider
var _fullscreen_check: CheckButton
var _vsync_check: CheckButton
var _resolution_option: OptionButton
var _keybind_buttons: Dictionary = {}
var _rebinding_action: String = ""
var _rebinding_slot: int = -1
var _rebinding_button: Button

func _add_settings_button() -> void:
	var vbox := get_node_or_null("Center/Panel/Margin/VBox") as VBoxContainer
	if vbox == null:
		return
	var btn := Button.new()
	btn.text = "Settings"
	btn.custom_minimum_size = Vector2(400, 44)
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(_on_settings_pressed)
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box != null:
		var dev_idx := dev_box.get_index()
		vbox.add_child(btn)
		vbox.move_child(btn, dev_idx)
	else:
		vbox.add_child(btn)


func _add_quit_button() -> void:
	var vbox := get_node_or_null("Center/Panel/Margin/VBox") as VBoxContainer
	if vbox == null:
		return
	var btn := Button.new()
	btn.text = "Quit"
	btn.custom_minimum_size = Vector2(400, 44)
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(func(): get_tree().quit())
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box != null:
		var dev_idx := dev_box.get_index()
		vbox.add_child(btn)
		vbox.move_child(btn, dev_idx)
	else:
		vbox.add_child(btn)


func _on_settings_pressed() -> void:
	if _settings_dialog != null:
		_sync_settings_ui()
		_settings_dialog.popup_centered()
		return
	var dlg := AcceptDialog.new()
	dlg.title = "Settings"
	dlg.ok_button_text = "Close"
	dlg.min_size = Vector2(680, 520)
	CocUiTheme.apply_to(dlg)

	var tabs := TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 20)
	dlg.add_child(tabs)

	_build_audio_tab(tabs)
	_build_graphics_tab(tabs)
	_build_controls_tab(tabs)

	add_child(dlg)
	_settings_dialog = dlg
	dlg.popup_centered()


func _build_audio_tab(tabs: TabContainer) -> void:
	var margin := MarginContainer.new()
	margin.name = "Audio"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 8)
	tabs.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var heading := Label.new()
	heading.text = "Volume"
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", Color(0.18, 0.16, 0.12))
	vbox.add_child(heading)

	_master_slider = _add_volume_row(vbox, "Master", AudioManager.master_volume)
	_master_slider.value_changed.connect(func(v: float):
		AudioManager.master_volume = v
		AudioManager.save_settings()
	)
	_sfx_slider = _add_volume_row(vbox, "SFX", AudioManager.sfx_volume)
	_sfx_slider.value_changed.connect(func(v: float):
		AudioManager.sfx_volume = v
		AudioManager.save_settings()
	)
	_ambient_slider = _add_volume_row(vbox, "Ambient", AudioManager.ambient_volume)
	_ambient_slider.value_changed.connect(func(v: float):
		AudioManager.ambient_volume = v
		AudioManager.save_settings()
	)


func _build_graphics_tab(tabs: TabContainer) -> void:
	var margin := MarginContainer.new()
	margin.name = "Graphics"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 8)
	tabs.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	_fullscreen_check = CheckButton.new()
	_fullscreen_check.text = "Fullscreen"
	_fullscreen_check.add_theme_font_size_override("font_size", 20)
	_fullscreen_check.button_pressed = SettingsManager.fullscreen
	_fullscreen_check.toggled.connect(func(on: bool):
		SettingsManager.set_fullscreen(on)
		_resolution_option.disabled = on
	)
	vbox.add_child(_fullscreen_check)

	_vsync_check = CheckButton.new()
	_vsync_check.text = "VSync"
	_vsync_check.add_theme_font_size_override("font_size", 20)
	_vsync_check.button_pressed = SettingsManager.vsync
	_vsync_check.toggled.connect(func(on: bool):
		SettingsManager.set_vsync(on)
	)
	vbox.add_child(_vsync_check)

	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 8)
	var res_label := Label.new()
	res_label.text = "Resolution"
	res_label.custom_minimum_size = Vector2(80, 0)
	res_label.add_theme_font_size_override("font_size", 20)
	res_row.add_child(res_label)
	_resolution_option = OptionButton.new()
	_resolution_option.custom_minimum_size = Vector2(200, 0)
	_resolution_option.add_theme_font_size_override("font_size", 20)
	for res in SettingsManager.RESOLUTIONS:
		_resolution_option.add_item("%d x %d" % [res.x, res.y])
	_resolution_option.selected = SettingsManager.resolution_index
	_resolution_option.disabled = SettingsManager.fullscreen
	_resolution_option.item_selected.connect(func(idx: int):
		SettingsManager.set_resolution_index(idx)
	)
	res_row.add_child(_resolution_option)
	vbox.add_child(res_row)


func _build_controls_tab(tabs: TabContainer) -> void:
	var margin := MarginContainer.new()
	margin.name = "Controls"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 8)
	tabs.add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	margin.add_child(outer)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 180)
	outer.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	for action in SettingsManager.REMAPPABLE_ACTIONS:
		var label := Label.new()
		label.text = SettingsManager.ACTION_LABELS.get(action, action)
		label.custom_minimum_size = Vector2(130, 0)
		label.add_theme_font_size_override("font_size", 18)
		grid.add_child(label)

		var binds: Array = SettingsManager.get_bindings(action)
		var btn_primary := Button.new()
		btn_primary.custom_minimum_size = Vector2(120, 34)
		btn_primary.text = SettingsManager.key_name(binds[0] if binds.size() > 0 else 0)
		btn_primary.add_theme_font_size_override("font_size", 16)
		btn_primary.pressed.connect(_start_rebind.bind(action, 0, btn_primary))
		grid.add_child(btn_primary)

		var btn_secondary := Button.new()
		btn_secondary.custom_minimum_size = Vector2(120, 34)
		btn_secondary.text = SettingsManager.key_name(binds[1] if binds.size() > 1 else 0)
		btn_secondary.add_theme_font_size_override("font_size", 16)
		btn_secondary.pressed.connect(_start_rebind.bind(action, 1, btn_secondary))
		grid.add_child(btn_secondary)

		_keybind_buttons[action] = [btn_primary, btn_secondary]

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	var reset_btn := Button.new()
	reset_btn.text = "Reset Defaults"
	reset_btn.add_theme_font_size_override("font_size", 16)
	reset_btn.pressed.connect(_on_reset_keybinds)
	btn_row.add_child(reset_btn)
	outer.add_child(btn_row)


func _start_rebind(action: String, slot: int, btn: Button) -> void:
	if _rebinding_button != null:
		_cancel_rebind()
	_rebinding_action = action
	_rebinding_slot = slot
	_rebinding_button = btn
	btn.text = "..."


func _cancel_rebind() -> void:
	if _rebinding_button == null:
		return
	var binds: Array = SettingsManager.get_bindings(_rebinding_action)
	var keycode: int = binds[_rebinding_slot] if _rebinding_slot < binds.size() else 0
	_rebinding_button.text = SettingsManager.key_name(keycode)
	_rebinding_action = ""
	_rebinding_slot = -1
	_rebinding_button = null


func _input(event: InputEvent) -> void:
	if _rebinding_action == "":
		return
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed:
		return
	get_viewport().set_input_as_handled()
	if key_event.keycode == KEY_ESCAPE:
		_cancel_rebind()
		return
	var keycode := int(key_event.physical_keycode) if key_event.physical_keycode != KEY_NONE else int(key_event.keycode)
	SettingsManager.set_binding(_rebinding_action, _rebinding_slot, keycode)
	_rebinding_button.text = SettingsManager.key_name(keycode)
	_rebinding_action = ""
	_rebinding_slot = -1
	_rebinding_button = null


func _on_reset_keybinds() -> void:
	SettingsManager.reset_keybinds()
	_refresh_keybind_buttons()


func _refresh_keybind_buttons() -> void:
	for action in SettingsManager.REMAPPABLE_ACTIONS:
		if not _keybind_buttons.has(action):
			continue
		var btns: Array = _keybind_buttons[action]
		var binds: Array = SettingsManager.get_bindings(action)
		if btns.size() > 0 and btns[0] is Button:
			(btns[0] as Button).text = SettingsManager.key_name(binds[0] if binds.size() > 0 else 0)
		if btns.size() > 1 and btns[1] is Button:
			(btns[1] as Button).text = SettingsManager.key_name(binds[1] if binds.size() > 1 else 0)


func _sync_settings_ui() -> void:
	if _master_slider != null:
		_master_slider.set_value_no_signal(AudioManager.master_volume)
	if _sfx_slider != null:
		_sfx_slider.set_value_no_signal(AudioManager.sfx_volume)
	if _ambient_slider != null:
		_ambient_slider.set_value_no_signal(AudioManager.ambient_volume)
	if _fullscreen_check != null:
		_fullscreen_check.set_pressed_no_signal(SettingsManager.fullscreen)
	if _vsync_check != null:
		_vsync_check.set_pressed_no_signal(SettingsManager.vsync)
	if _resolution_option != null:
		_resolution_option.selected = SettingsManager.resolution_index
		_resolution_option.disabled = SettingsManager.fullscreen
	_refresh_keybind_buttons()


func _add_volume_row(parent: VBoxContainer, label_text: String, initial: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(80, 0)
	label.add_theme_font_size_override("font_size", 20)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(160, 0)
	row.add_child(slider)

	parent.add_child(row)
	return slider


func _on_editor_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	PlayerSides.clear()
	GameModeManager.set_mode(GameMode.OFFLINE_DEV)
	MatchConfigStoreClass.clear_pending()
	get_tree().change_scene_to_file(EDITOR_SCENE)


func _on_asset_anim_editor_pressed() -> void:
	if BuildConfig.is_survival_playtest():
		return
	PlayerSides.clear()
	GameModeManager.set_mode(GameMode.OFFLINE_DEV)
	get_tree().change_scene_to_file(ASSET_ANIM_EDITOR_SCENE)


func _set_buttons_enabled(enabled: bool) -> void:
	_single_player_button.disabled = not enabled
	_multiplayer_button.disabled = not enabled
	_offline_quick_button.disabled = not enabled
	_offline_quick_ai_button.disabled = not enabled
	_survival_mode_button.disabled = not enabled
	if _tutorial_button != null:
		_tutorial_button.disabled = not enabled
	if _how_to_play_button != null:
		_how_to_play_button.disabled = not enabled
	_editor_button.disabled = not enabled
	_asset_anim_button.disabled = not enabled


## Re-fetch profile to check if ban was lifted. If unbanned, proceed to the target scene.
## If still banned, show the ban notice.
func _recheck_ban_and_proceed(target_scene: String) -> void:
	_set_buttons_enabled(false)
	if _sign_in_label != null:
		_sign_in_label.text = "Checking ban status..."
	SupabaseAuth.fetch_profile()
	# Wait a moment for the HTTP response to update SupabaseAuth state
	await get_tree().create_timer(1.0).timeout
	_set_buttons_enabled(true)
	if SupabaseAuth.is_banned:
		_show_ban_notice()
	else:
		# Ban was lifted; update the menu label and proceed
		if _sign_in_label != null:
			_sign_in_label.text = "Signed in as %s" % SupabaseAuth.display_name
			_sign_in_label.remove_theme_color_override("font_color")
		if target_scene == LEADERBOARD_SCENE:
			LeaderboardScript.return_scene = "res://scenes/mode_select.tscn"
		get_tree().change_scene_to_file(target_scene)


func _show_ban_notice() -> void:
	var reason := SupabaseAuth.ban_reason
	if reason.is_empty():
		reason = "No reason provided"
	var dlg := AcceptDialog.new()
	dlg.title = "Account Banned"
	dlg.dialog_text = "Your account has been banned from online play.\n\nReason: %s\n\nYou can still play single player." % reason
	dlg.ok_button_text = "OK"
	add_child(dlg)
	dlg.popup_centered()


func _add_version_label() -> void:
	var ver := Label.new()
	ver.text = "v%s" % BuildConfig.VERSION
	ver.add_theme_font_size_override("font_size", 14)
	ver.add_theme_color_override("font_color", Color(0.5, 0.55, 0.5, 0.7))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ver.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	ver.anchors_preset = Control.PRESET_BOTTOM_RIGHT
	ver.anchor_left = 1.0
	ver.anchor_top = 1.0
	ver.anchor_right = 1.0
	ver.anchor_bottom = 1.0
	ver.offset_left = -120
	ver.offset_top = -28
	ver.offset_right = -8
	ver.offset_bottom = -6
	add_child(ver)


var _known_issues_dialog: AcceptDialog

func _add_known_issues_button() -> void:
	var vbox := get_node_or_null("Center/Panel/Margin/VBox") as VBoxContainer
	if vbox == null:
		return
	var btn := Button.new()
	btn.text = "Known Issues"
	btn.custom_minimum_size = Vector2(400, 44)
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(_on_known_issues_pressed)
	var dev_box := get_node_or_null("Center/Panel/Margin/VBox/DevBox") as Control
	if dev_box != null:
		var dev_idx := dev_box.get_index()
		vbox.add_child(btn)
		vbox.move_child(btn, dev_idx)
	else:
		vbox.add_child(btn)


func _on_known_issues_pressed() -> void:
	if _known_issues_dialog != null:
		_known_issues_dialog.popup_centered()
		return
	var dlg := AcceptDialog.new()
	dlg.title = "Known Issues"
	dlg.ok_button_text = "Close"
	dlg.min_size = Vector2(600, 480)
	CocUiTheme.apply_to(dlg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 12)
	dlg.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(540, 370)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 6)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(page)
	_fill_known_issues(page)

	add_child(dlg)
	_known_issues_dialog = dlg
	dlg.popup_centered()


func _fill_known_issues(page: VBoxContainer) -> void:
	var issues := [
		"Team games (2v2+) are new and lightly tested — expect rough edges.",
		"Reconnection: if you disconnect mid-match, you have 90 seconds to reconnect.",
		"Leaderboard ranks update after the match ends, not in real time.",
		"Map editor saves are local only — no cloud sync.",
	]
	for issue in issues:
		var label := Label.new()
		label.text = "• " + issue
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 16)
		page.add_child(label)


const _FIRST_LAUNCH_PATH := "user://first_launch_seen.flag"

func _show_first_launch_hint() -> void:
	if FileAccess.file_exists(_FIRST_LAUNCH_PATH):
		return
	# Delay so auth session restore doesn't reload the scene and kill the dialog.
	await get_tree().create_timer(1.5).timeout
	if not is_inside_tree():
		return
	var dlg := AcceptDialog.new()
	dlg.title = "Welcome to Chain Revival!"
	dlg.ok_button_text = "Got it"
	dlg.min_size = Vector2(520, 280)
	CocUiTheme.apply_to(dlg)
	dlg.dialog_text = "Welcome, Commander!\n\nIf this is your first time, hit \"How to Play\" on the main menu for controls and tips.\n\nFor multiplayer, sign in first, then hit \"Multiplayer\" to find or host a game.\n\nGood luck out there."
	add_child(dlg)
	dlg.popup_centered()
	# Write the flag only after the user dismisses the dialog.
	dlg.confirmed.connect(func():
		var f := FileAccess.open(_FIRST_LAUNCH_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string("1")
			f.close()
	)


func _check_for_updates() -> void:
	_updater = AutoUpdaterClass.new()
	add_child(_updater)
	_updater.update_check_complete.connect(_on_update_check_complete)
	_updater.update_progress.connect(_on_update_progress)
	_updater.update_failed.connect(_on_update_failed)


func _on_update_check_complete(update_available: bool) -> void:
	if not update_available:
		return
	_update_dialog = AcceptDialog.new()
	_update_dialog.title = "Update Available"
	_update_dialog.ok_button_text = "Update Now"
	_update_dialog.min_size = Vector2(520, 260)
	_update_dialog.max_size = Vector2(600, 320)
	_update_dialog.unresizable = true
	CocUiTheme.apply_to(_update_dialog)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)

	var msg := Label.new()
	msg.text = "A new version of Chain Revival is available!\n\nCurrent: v%s\nLatest: v%s" % [BuildConfig.VERSION, _updater.remote_version]
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", 20)
	vbox.add_child(msg)

	_update_progress_label = Label.new()
	_update_progress_label.text = ""
	_update_progress_label.add_theme_font_size_override("font_size", 16)
	_update_progress_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	vbox.add_child(_update_progress_label)

	_update_dialog.add_child(vbox)
	_update_dialog.add_cancel_button("Skip")
	add_child(_update_dialog)
	_update_dialog.confirmed.connect(_on_update_confirmed)
	_update_dialog.popup_centered()


func _on_update_confirmed() -> void:
	if _updater == null:
		return
	_update_dialog.get_ok_button().disabled = true
	_update_progress_label.text = "Downloading update..."
	# Reshow dialog since confirmed auto-hides it
	_update_dialog.popup_centered()
	_updater.start_download()


func _on_update_progress(percent: float) -> void:
	if _update_progress_label != null:
		_update_progress_label.text = "Downloading... %d%%" % int(percent)


func _on_update_failed(reason: String) -> void:
	if _update_progress_label != null:
		_update_progress_label.text = "Update failed: %s" % reason
		_update_progress_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	if _update_dialog != null:
		_update_dialog.get_ok_button().disabled = false
