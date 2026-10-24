extends Node2D
## Root scene: presentation shell for the authoritative game loop.
##
## Architecture:
##   Input/UI → CommandRouter → ActionResolver → GameState (truth) → Soldier visuals
##
## Ownership: GameState + ObjectRegistry hold authoritative data. This scene owns
## Soldier node views in _soldier_views only — never store node refs in the registry.
## main.gd must not mutate SoldierState or MapData directly. Use CommandRouter for commands.

const SoldierScene := preload("res://scenes/soldier.tscn")
const GameSessionClass := preload("res://scripts/core/game_session.gd")
const GameStateClass := preload("res://scripts/core/game_state.gd")
const GameSaveClass := preload("res://scripts/core/game_save.gd")
const MapDataClass := preload("res://scripts/map/map_data.gd")
const MovementModeClass := preload("res://scripts/enums/movement_mode.gd")
const PositionStateClass := preload("res://scripts/enums/position_state.gd")
const FireControlCommandClass := preload("res://scripts/commands/fire_control_command.gd")
const FireControlStateClass := preload("res://scripts/enums/fire_control_state.gd")
const LosVisualizerClass := preload("res://scripts/effects/los_visualizer.gd")
const FireteamLoadoutClass := preload("res://scripts/soldiers/fireteam_loadout.gd")
const LOSSystemClass := preload("res://scripts/combat/los_system.gd")
const ConeOfFireClass := preload("res://scripts/combat/cone_of_fire.gd")
const ActionResolverClass := preload("res://scripts/core/action_resolver.gd")
const ActionResultClass := preload("res://scripts/core/action_result.gd")
const CommandContextClass := preload("res://scripts/core/command_context.gd")
const CommandDialogScene := preload("res://scenes/ui/command_dialog.tscn")
const AssignWeaponsDialogScene := preload("res://scenes/ui/assign_weapons_dialog.tscn")
const AdjustAmmoCommandClass := preload("res://scripts/commands/adjust_ammo_command.gd")
const MatchConfigClass := preload("res://scripts/core/match_config.gd")
const MatchConfigStoreClass := preload("res://scripts/core/match_config_store.gd")
const AiCommanderFrameworkClass := preload("res://scripts/ai/ai_commander_framework.gd")
const IssueAiOrderCommandClass := preload("res://scripts/commands/issue_ai_order_command.gd")
const PlayerSlotOwnershipClass := preload("res://scripts/core/player_slot_ownership.gd")
const ScenarioRulesClass := preload("res://scripts/core/scenario_rules.gd")
const SurvivalModeControllerClass := preload("res://scripts/core/survival_mode_controller.gd")
const ScenarioEndCauseClass := preload("res://scripts/enums/scenario_end_cause.gd")
const ScenarioWinnerClass := preload("res://scripts/enums/scenario_winner.gd")
const MissionDebriefDialogClass := preload("res://scripts/ui/mission_debrief_dialog.gd")
const SurvivalDifficultyDialogClass := preload("res://scripts/ui/survival_difficulty_dialog.gd")
const AuthoritativeSyncClass := preload("res://scripts/network/authoritative_sync.gd")

@onready var _world: MapWorldView = $World
@onready var _map_background: Node2D = $World/MapBackground
@onready var _grass_layer: GrassTerrainLayer = $World/GrassTerrainLayer
@onready var _original_ground_layer: OriginalGroundLayer = $World/OriginalGroundLayer
@onready var _floor_layer: OriginalFloorLayer = $World/OriginalFloorLayer
@onready var _underlay_layer: OriginalUnderlayLayer = $World/OriginalUnderlayLayer
@onready var _iso_map: IsometricMap = $World/IsometricMap
@onready var _depth_sorted: DepthSortedLayer = $World/DepthSorted
@onready var _label_layer: OriginalLabelLayer = $World/OriginalLabelLayer
@onready var _coc_debug_overlay: CocTileDebugOverlay = $World/CocTileDebugOverlay
@onready var _tracers_root: Node2D = $World/Tracers
@onready var _los_visualizer: LosVisualizerClass = $World/LosVisualizer
@onready var _camera: MapCamera = $Camera2D
@onready var _command_bar: CommandBar = $UI/CommandBar
@onready var _ai_plan_hud = $UI/AiPlanHud
@onready var _survival_announcement: SurvivalAnnouncementOverlay = $UI/SurvivalAnnouncementOverlay
var _return_to_editor_on_exit: bool = false
var _command_dialog: CommandDialog = null
var _assign_weapons_dialog: AssignWeaponsDialog = null
var _mission_debrief_dialog: MissionDebriefDialogClass = null
var _survival_difficulty_dialog: SurvivalDifficultyDialogClass = null

var _map_data = MapDataClass.create_default()
var _session: GameSession = GameSessionClass.new([], [])
var _game_state: GameStateClass

var _soldier_views: Dictionary = {}
var _move_targeting: bool = false
var _squad_move_targeting: bool = false
var _active_movement_mode: int = MovementModeClass.RUN
var _move_soldier_id: int = 1
var _fire_at_mode: bool = false
var _squad_fire_at_mode: bool = false
var _fire_at_soldier_id: int = 1
var _fire_at_engaged: bool = false
var _fire_at_submit_busy: bool = false
var _face_mode: bool = false
var _face_soldier_id: int = 1
var _grenade_mode: bool = false
var _grenade_soldier_id: int = 1
## Test-only: yellow run path, aim line, and LOS cone. Off by default; toggle with T.
var _debug_targeting_overlays: bool = false
var _sim_accum_sec: float = 0.0
var _combat_scan_accum_msec: int = 0
## Last whole-second remaining shown on the scenario HUD (avoids per-tick label churn).
var _last_scenario_hud_sec: int = -1
var _grass_layer_visible: bool = true
var _ai_framework: AiCommanderFrameworkClass = null
var _survival_mode: SurvivalModeControllerClass = null
var _fire_at_preview_accum_sec: float = 0.0
var _fire_at_hit_accum_sec: float = 0.0
var _last_fire_at_preview_cell: Vector2i = Vector2i(-999999, -999999)
const _FIRE_AT_PREVIEW_INTERVAL_SEC := 0.08
## After Face on empty tile: keep manual aim visuals until revert toward engaged target.
var _face_manual_aim_cell: Vector2i = Vector2i(-999999, -999999)
var _face_manual_aim_world: Vector2 = Vector2(-99999, -99999)
var _face_manual_override_until_msec: int = 0
var _face_revert_keys: Array[String] = []
var _face_committed_keys: Array[String] = []
const _FACE_REVERT_DELAY_MSEC := 3000
## Fog lookup rebuilt once per need (move/combat), not per soldier per sync.
var _fog_spotted_cache: Dictionary = {} ## Team.soldier_key -> bool
var _fog_cache_valid: bool = false
## Dev counters — verify movers sync without full-roster refresh.
var _debug_sync_calls_this_tick: int = 0
var _debug_full_refresh_calls: int = 0
var _debug_perf_accum_sec: float = 0.0
const _DEBUG_PERF_INTERVAL_SEC := 1.0
var _ai_hud_refresh_counter: int = 0
## Perception / AI / combat profiler (rolling 1s window).
var _perf_ai_think_usec: int = 0
var _perf_combat_usec: int = 0
var _perf_present_usec: int = 0
var _perf_move_usec: int = 0
var _perf_max_frame_msec: float = 0.0
var _stuck_mismatch_since: Dictionary = {} ## "team:sid" -> msec when mismatch began
var _stuck_logged: Dictionary = {} ## "team:sid" -> true once per stuck episode
const PerceptionCacheClass := preload("res://scripts/combat/perception_cache.gd")
const _FRAME_SPIKE_LOG_MSEC := 50.0
## False until staged boot finishes — keeps sim/AI off while the loading overlay paints.
var _boot_complete: bool = false
var _loading_overlay: CanvasLayer = null
var _loading_label: Label = null
var _loading_blurb_label: Label = null

const SURVIVAL_LOADING_BLURB := (
	"The U.S. holds ground deep in German lines — but the counterattack never stops. "
	+ "Hold the objective against wave after wave of reinforcements. Do you have what it takes?"
)


func _ready() -> void:
	_show_loading_overlay("Starting…")
	await get_tree().process_frame

	_bootstrap_simulation()
	_log_network_mode()
	LOSSystemClass.apply_debug_settings()
	RenderingServer.set_default_clear_color(Color(0.22, 0.38, 0.18, 1.0))
	_camera.make_current()

	_set_loading_status("Loading map…")
	await get_tree().process_frame
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		_set_loading_status("Joining match…")
		await NetworkClient.wait_for_snapshot()
		_ensure_multiplayer_result_signals()
	_load_map_data()
	_init_session_from_spawns()
	if GameModeManager.is_local_multiplayer() and not NetworkClient.last_snapshot.is_empty():
		AuthoritativeSyncClass.apply_snapshot(_game_state, NetworkClient.last_snapshot)
		_invalidate_fog_cache()
	_connect_command_bar()
	_apply_multiplayer_side_lock()

	## Staged presentation — one big apply_map_data froze on "Spawning units" while the
	## first ground/object frame painted under that label.
	await _boot_apply_map_presentation_staged()

	_set_loading_status("Loading soldier sprites…")
	await get_tree().process_frame
	UsSoldierSpriteFrames.prewarm_all(_set_loading_status)

	_set_loading_status("Spawning units…")
	await get_tree().process_frame
	_spawn_all_soldier_views()
	await get_tree().process_frame
	_log_fireteam_loadouts()
	_command_bar.set_active_team(_session.active_team_id)
	## Side default camera (FF: USA 90° / GE 270°) + center on that fireteam.
	_apply_team_default_camera(_session.active_team_id)
	if _is_survival_mode():
		_apply_survival_camera_rotation()
		_center_camera_on_team_deployment(Team.USA)
		_command_bar.set_survival_hud_visible(true)
	_sync_deployment_hud()
	_refresh_ai_plan_hud()
	_refresh_all_views()
	_show_startup_status()
	_start_ai_framework()
	if _is_survival_mode():
		_survival_mode = SurvivalModeControllerClass.new()
		_survival_mode.reset()
		_game_state.begin_running_phase()
		_on_timed_deployment_finished()
		_configure_survival_ge_commanders()
		_refresh_survival_hud()
		_command_bar.show_status("Survival Mode: choose a difficulty to begin waves.")
	else:
		_ensure_command_dialog()
	## Let the first heavy draw frames finish while the overlay still covers them.
	_set_loading_status("Almost ready…")
	await get_tree().process_frame
	await get_tree().process_frame
	_boot_complete = true
	_hide_loading_overlay()
	if _is_survival_mode():
		call_deferred("_open_survival_difficulty_dialog")
	else:
		call_deferred("_open_command_dialog_for_deployment")


## Yieldable map boot: pathfinding → ground prewarm → chunked object sprites → first draw.
func _boot_apply_map_presentation_staged() -> void:
	if _map_data == null or _world == null:
		return
	_world.map_data = _map_data
	IsometricGrid.set_original_projection_enabled(_map_data.uses_original_projection)
	IsometricGrid.set_view_pivot_for_map(_map_data.width, _map_data.height)

	_set_loading_status("Building pathfinding…")
	await get_tree().process_frame
	if _iso_map != null:
		_iso_map.apply_map_data(_map_data)

	_set_loading_status("Loading ground…")
	await get_tree().process_frame
	if _grass_layer != null:
		_grass_layer.apply_map_data(_map_data)
	if _original_ground_layer != null:
		_original_ground_layer.apply_map_data(_map_data)
		if _original_ground_layer.has_method("prewarm_textures"):
			_original_ground_layer.prewarm_textures()
	if _floor_layer != null:
		_floor_layer.apply_map_data(_map_data)
	if _underlay_layer != null:
		_underlay_layer.apply_map_data(_map_data)
	if _label_layer != null:
		_label_layer.apply_map_data(_map_data)
	## Victory / debug overlays if present on the world scene.
	if _world.victory_point_layer != null:
		_world.victory_point_layer.apply_map_data(_map_data)
	if _coc_debug_overlay != null:
		_coc_debug_overlay.apply_map_data(_map_data)
	if _world.handedness_overlay != null:
		_world.handedness_overlay.apply_map_data(_map_data)
	if _world.terrain_overlay != null:
		_world.terrain_overlay.apply_map_data(_map_data)
	_world.set_grass_visible(_grass_layer_visible)

	_set_loading_status("Placing map objects…")
	await get_tree().process_frame
	if _depth_sorted != null and _depth_sorted.has_method("begin_chunked_apply"):
		_depth_sorted.begin_chunked_apply(_map_data)
		while not _depth_sorted.process_chunked_apply(36):
			var pct := int(_depth_sorted.chunked_apply_progress() * 100.0)
			_set_loading_status("Placing map objects… %d%%" % pct)
			await get_tree().process_frame
		_set_loading_status("Placing map objects… 100%")
		await get_tree().process_frame
	elif _depth_sorted != null:
		_depth_sorted.apply_map_data(_map_data)

	## Prewarm cover-stand cache so first DEFEND think does not hitch on object scan.
	if _map_data.has_method("get_cover_stand_cells"):
		_map_data.get_cover_stand_cells()

	_set_loading_status("Drawing map…")
	await get_tree().process_frame
	await get_tree().process_frame


## Seeded RNG + sim clock for reproducible gameplay timing (not wall-clock).
func _bootstrap_simulation() -> void:
	SimulationClock.reset()
	SimulationClock.reset_tick_defaults()
	GameRandom.begin_match(GameRandom.DEFAULT_SEED)
	GameplayPolicies.reset_all_to_defaults()
	GameplayPolicies.reload_from_config()
	_sim_accum_sec = 0.0
	_combat_scan_accum_msec = 0


func _start_ai_framework() -> void:
	_ai_framework = AiCommanderFrameworkClass.new()
	var find_path := Callable()
	if _iso_map != null and _iso_map.has_method("find_path"):
		find_path = _iso_map.find_path
	## Clients never tick AI; host/offline keep authority.
	_ai_framework.set_authority(GameModeManager.is_ai_authority())
	_ai_framework.setup(_game_state, find_path)
	var declared_ai_slots := 0
	if _game_state != null and _game_state.command_hierarchy != null:
		for pid in _game_state.command_hierarchy.all_player_ids():
			if _game_state.command_hierarchy.is_ai_player(int(pid)):
				declared_ai_slots += 1
	## Hotseat / all-human matches (Offline Quick Start): no AI commanders.
	## Single Player Match Setup still declares AI slots and keeps them enabled.
	var all_human := declared_ai_slots == 0
	if GameConfig.hotseat_enabled() or all_human:
		_ai_framework.set_enabled(false)
		for commander in _ai_framework.all_commanders():
			_ai_framework.disable_commander(commander.player_id)
		if _game_state != null and _game_state.command_hierarchy != null:
			for pid in _game_state.command_hierarchy.all_player_ids():
				if _game_state.command_hierarchy.is_ai_player(int(pid)):
					PlayerSlotOwnershipClass.claim_slot_as_human(
						_game_state, _ai_framework, int(pid)
					)
	_log_ai_framework_startup(declared_ai_slots)
	_refresh_ai_plan_hud()


func _log_ai_framework_startup(declared_ai_slots: int) -> void:
	if _game_state == null or _game_state.command_hierarchy == null:
		return
	var hierarchy = _game_state.command_hierarchy
	var pids: Array = hierarchy.all_player_ids()
	pids.sort()
	for pid in pids:
		var player_id := int(pid)
		var team_name := Team.display_name(hierarchy.get_team_id(player_id)).to_upper()
		var role := "AI" if hierarchy.is_ai_player(player_id) else "Human"
		var plan := hierarchy.get_active_ai_plan(player_id)
		if plan.is_empty():
			plan = hierarchy.get_selected_ai_plan(player_id)
		if plan.is_empty():
			plan = "(none)"
		GameLog.log_system(
			"[AI] player %d / %s / %s / plan=%s" % [player_id, team_name, role, plan]
		)
	if (
		_ai_framework != null
		and not _ai_framework.has_commanders()
		and declared_ai_slots > 0
		and not GameConfig.hotseat_enabled()
	):
		var warn := (
			"[AI] WARNING: framework has zero commanders but match declared %d AI slot(s)."
			% declared_ai_slots
		)
		push_warning(warn)
		GameLog.log_system(warn)
	elif declared_ai_slots == 0 or GameConfig.hotseat_enabled():
		GameLog.log_system("[AI] All-human / hotseat — AI commanders disabled.")


func _log_network_mode() -> void:
	var mode_name := GameMode.display_name(GameModeManager.get_mode())
	GameLog.log_system("Current Mode: %s" % mode_name)
	if GameModeManager.is_local_multiplayer():
		if NetworkClient.is_connected_to_server():
			GameLog.log_system("[NetworkClient] Already connected to server.")
		else:
			NetworkClient.connect_for_local_multiplayer()
	else:
		GameLog.log_system("[NetworkClient] Offline mode — no server connection.")


func _show_loading_overlay(message: String) -> void:
	if _loading_overlay != null:
		_set_loading_status(message)
		return
	_loading_overlay = CanvasLayer.new()
	_loading_overlay.layer = 100
	_loading_overlay.name = "LoadingOverlay"
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.08, 0.1, 0.07, 0.92)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_loading_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_overlay.add_child(center)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	center.add_child(col)
	var title := Label.new()
	title.text = "Chain Revival"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.9, 0.93, 0.85, 1.0))
	col.add_child(title)
	if _is_survival_pending():
		var mode_title := Label.new()
		mode_title.text = "Survival Mode: 1 v All"
		mode_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mode_title.add_theme_font_size_override("font_size", 20)
		mode_title.add_theme_color_override("font_color", Color(0.82, 0.88, 0.72, 1.0))
		col.add_child(mode_title)
		_loading_blurb_label = Label.new()
		_loading_blurb_label.text = SURVIVAL_LOADING_BLURB
		_loading_blurb_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_loading_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_loading_blurb_label.custom_minimum_size = Vector2(520, 0)
		_loading_blurb_label.add_theme_font_size_override("font_size", 14)
		_loading_blurb_label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.66, 1.0))
		col.add_child(_loading_blurb_label)
	_loading_label = Label.new()
	_loading_label.text = message
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 16)
	_loading_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.68, 1.0))
	col.add_child(_loading_label)
	add_child(_loading_overlay)


func _is_survival_pending() -> bool:
	var cfg = MatchConfigStoreClass.peek_pending()
	return cfg != null and cfg.is_survival_1v_all()


func _set_loading_status(message: String) -> void:
	if _loading_label != null:
		_loading_label.text = message


func _hide_loading_overlay() -> void:
	if _loading_overlay != null:
		_loading_overlay.queue_free()
		_loading_overlay = null
		_loading_label = null
		_loading_blurb_label = null


func _show_startup_status() -> void:
	if _is_survival_mode():
		_command_bar.show_status("Survival Mode: 1 v All — choose a difficulty.")
		return
	if _map_data != null and _map_data.is_original_visual_map():
		_command_bar.show_status(
			"%s loaded. Rotate Q/E. --test-map switches maps."
			% str(_map_data.map_name)
		)
		return
	if GameModeManager.is_local_multiplayer() and PlayerSides.has_assignment():
		_command_bar.show_status(
			"Controlling %s. Fire At: click an enemy to open fire. Right-click cancels."
			% PlayerSides.display_side_name()
		)
	else:
		_command_bar.show_status(
			"Press 1 = USA, 2 = Germany. Fire At: click an enemy to open fire. Right-click cancels."
		)


func _apply_multiplayer_side_lock() -> void:
	if not GameModeManager.is_local_multiplayer():
		return
	if not PlayerSides.has_assignment():
		push_error("Local multiplayer started without an assigned side.")
		return
	_session.bind_local_player_to_team(PlayerSides.assigned_team_id)
	if _game_state != null:
		_game_state.local_player_id = _session.local_player_id
	_session.set_active_team(PlayerSides.assigned_team_id)
	_command_bar.set_active_team(PlayerSides.assigned_team_id)
	var fireteam: Fireteam = _control_fireteam()
	_repair_fireteam_selection(fireteam)
	_command_bar.sync_selected_soldier(fireteam.selected_soldier_id)
	GameLog.log_system(
		"[PlayerSide] Locked control to %s." % PlayerSides.display_side_name()
	)


func _log_fireteam_loadouts() -> void:
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			var message := FireteamLoadoutClass.assignment_message(
				soldier_state.team_id,
				soldier_state.soldier_id,
				soldier_state.weapon_name,
			)
			GameLog.log_system(message)


func _process(delta: float) -> void:
	if not _boot_complete:
		return
	## Sim first (authoritative), then presentation so views reflect the latest tick.
	var frame_t0 := Time.get_ticks_usec()
	_step_fixed_simulation(delta)

	_update_los_preview_throttled(delta)
	_tick_face_manual_revert()
	## Hit % columns: throttle while aiming; combat-scan path covers Fire At Will.
	if _fire_at_mode:
		_fire_at_hit_accum_sec += delta
		if _fire_at_hit_accum_sec >= _FIRE_AT_PREVIEW_INTERVAL_SEC:
			_fire_at_hit_accum_sec = 0.0
			_update_command_bar_hit_columns()
	_debug_perf_accum_sec += delta
	if _debug_perf_accum_sec >= _DEBUG_PERF_INTERVAL_SEC:
		_debug_perf_accum_sec = 0.0
		_log_perception_profiler()
		_scan_stuck_movement_mismatches()
	var frame_msec := float(Time.get_ticks_usec() - frame_t0) / 1000.0
	if frame_msec > _perf_max_frame_msec:
		_perf_max_frame_msec = frame_msec
	if frame_msec >= _FRAME_SPIKE_LOG_MSEC:
		GameLog.log_system(
			"[FRAME-SPIKE] ms=%.2f ai_ms=%.2f combat_ms=%.2f move_ms=%.2f present_ms=%.2f perc_ms=%.2f"
			% [
				frame_msec,
				float(_perf_ai_think_usec) / 1000.0,
				float(_perf_combat_usec) / 1000.0,
				float(_perf_move_usec) / 1000.0,
				float(_perf_present_usec) / 1000.0,
				float(PerceptionCacheClass.perception_usec) / 1000.0,
			]
		)

func _update_los_preview_throttled(delta: float) -> void:
	if not _fire_at_mode and not _grenade_mode and not _face_mode:
		_los_visualizer.hide_preview()
		_last_fire_at_preview_cell = Vector2i(-999999, -999999)
		return
	## Skip work when there is no valid shooter selection.
	if _fire_at_mode and _get_manual_fire_at_shooters().is_empty():
		_los_visualizer.hide_preview()
		return
	if _face_mode and _get_face_scope_soldiers().is_empty():
		_los_visualizer.hide_preview()
		return
	_fire_at_preview_accum_sec += delta
	var aim_world := _get_world_mouse_local()
	var click_cell := IsometricGrid.world_to_grid(aim_world)
	var cell_changed := click_cell != _last_fire_at_preview_cell
	if not cell_changed and _fire_at_preview_accum_sec < _FIRE_AT_PREVIEW_INTERVAL_SEC:
		return
	_fire_at_preview_accum_sec = 0.0
	_last_fire_at_preview_cell = click_cell
	_update_los_preview()


## Advance SimulationClock in fixed ticks; run movement every tick and combat on policy cadence.
func _step_fixed_simulation(frame_delta: float) -> void:
	if frame_delta <= 0.0:
		return
	_sim_accum_sec += frame_delta
	var tick_sec := SimulationClock.tick_sec()
	## How many ticks are already queued? >1 means we're catching up after a hitch —
	## skip AI on catch-up ticks so one slow think cannot multiply into a death spiral.
	var queued := int(_sim_accum_sec / tick_sec)
	var steps := 0
	while _sim_accum_sec >= tick_sec and steps < SimulationClock.max_catchup_ticks:
		_sim_accum_sec -= tick_sec
		var catching_up := queued > 1 and steps < queued - 1
		_step_simulation_tick(catching_up)
		steps += 1
	## Drop excess accumulator after catch-up cap so a long hitch does not spiral.
	if steps >= SimulationClock.max_catchup_ticks and _sim_accum_sec >= tick_sec:
		_sim_accum_sec = fmod(_sim_accum_sec, tick_sec)


func _step_simulation_tick(skip_ai: bool = false) -> void:
	if GameModeManager.is_local_multiplayer():
		## Server SimulationClock owns match time. Do not advance local GameState here.
		return
	var stepped := SimulationClock.advance_tick()

	var move_t0 := Time.get_ticks_usec()
	var move_result: ActionResultClass = ActionResolverClass.process_movement_tick(_game_state)
	if (
		not move_result.movement_steps.is_empty()
		or not move_result.movement_completions.is_empty()
	):
		_present_movement_tick_result(move_result)
	_perf_move_usec += Time.get_ticks_usec() - move_t0

	var tick_sec := float(stepped) / 1000.0
	## Timed SP/MP deployment countdown (Offline Quick Start has no lock/timer).
	if _game_state != null and _game_state.locks_deployment_zone():
		var deploy_ended := ScenarioRulesClass.process_deployment_tick(_game_state, tick_sec)
		_sync_deployment_hud()
		if deploy_ended:
			_on_timed_deployment_finished()
	## Scenario clock, VP ownership poll, extermination / TIME_GONE.
	elif _game_state != null and not _game_state.is_deployment_phase():
		var just_ended := ScenarioRulesClass.process_tick(_game_state, tick_sec)
		if _game_state.vp_holders_dirty:
			_game_state.vp_holders_dirty = false
			if _world != null and _world.victory_point_layer != null:
				_world.victory_point_layer.queue_redraw()
			_refresh_scenario_hud()
		if just_ended:
			_on_scenario_ended()
		elif not _game_state.scenario_ended:
			## Throttle HUD to ~1s sim time (clock display); VP flips refresh immediately above.
			var rem_i := int(floor(_game_state.time_remaining()))
			if rem_i != _last_scenario_hud_sec:
				_last_scenario_hud_sec = rem_i
				_refresh_scenario_hud()
			_tick_survival_mode()

	## Warm dirty perception pairs every sim tick (budgeted; combat scan flushes).
	if _game_state != null and not _game_state.is_deployment_phase() and not _game_state.is_ended_phase():
		CombatSystem.process_perception_tick(_game_state)

	## AI Commanders think on the authoritative host/server only (never on thin clients).
	## Present move/fire results so movement_halts stop run anims (was the stuck-run bug).
	if (
		GameModeManager.is_ai_authority()
		and _ai_framework != null
		and _game_state != null
		and not _game_state.is_deployment_phase()
		and not _game_state.is_ended_phase()
	):
		var ai_t0 := Time.get_ticks_usec()
		var ai_results: Array = _ai_framework.tick(_game_state, skip_ai)
		_perf_ai_think_usec += Time.get_ticks_usec() - ai_t0
		var present_t0 := Time.get_ticks_usec()
		for ai_result in ai_results:
			_present_action_result(ai_result, false)
		_perf_present_usec += Time.get_ticks_usec() - present_t0

	if _game_state != null and _game_state.is_ended_phase():
		return

	_combat_scan_accum_msec += stepped
	var scan_msec := _combat_scan_interval_msec()
	if _combat_scan_accum_msec < scan_msec:
		return
	_combat_scan_accum_msec -= scan_msec
	var combat_t0 := Time.get_ticks_usec()
	var tick_result: ActionResultClass = ActionResolverClass.process_combat_tick(_game_state)
	_perf_combat_usec += Time.get_ticks_usec() - combat_t0
	var present_c0 := Time.get_ticks_usec()
	_present_action_result(tick_result, true)
	_perf_present_usec += Time.get_ticks_usec() - present_c0
	## Immediate extermination check after lethal combat this scan.
	if (
		_game_state != null
		and not _game_state.scenario_ended
		and (
			ScenarioRulesClass.living_soldier_count(_game_state, Team.USA) <= 0
			or ScenarioRulesClass.living_soldier_count(_game_state, Team.GERMANY) <= 0
		)
	):
		if ScenarioRulesClass.process_tick(_game_state, 0.0):
			_on_scenario_ended()
	## Debug HUD — every 4th combat scan (~2s) is enough while AI is active.
	_ai_hud_refresh_counter += 1
	if _ai_hud_refresh_counter >= 4:
		_ai_hud_refresh_counter = 0
		_refresh_ai_plan_hud()


func _present_movement_tick_result(result: ActionResultClass) -> void:
	if result == null:
		return
	_debug_sync_calls_this_tick = 0
	var networked := GameModeManager.is_local_multiplayer()
	## Per-tick movement: chase position only. Do NOT invalidate fog every step —
	## that forced player-visibility rebuilds while many AI units marched (late-game hitch).
	## MP: follow_path already owns the run; chasing each server tick restarts the last step.
	for step in result.movement_steps:
		var step_view: Soldier = _get_view(int(step.team_id), int(step.soldier_id))
		var step_state: SoldierState = _game_state.get_soldier(int(step.team_id), int(step.soldier_id))
		if step_view == null or step_state == null:
			continue
		if networked:
			## Replica (or a missed move_result) never started the chase — start it once.
			if not step_view.is_moving() and step_state.is_moving and step_state.current_path.size() > 1:
				step_view.sync_locomotion_mode_from_state(step_state)
				step_view.follow_path(step_state.current_path, step_state.move_speed_mult)
			_debug_sync_calls_this_tick += 1
		else:
			step_view.sync_movement_chase_from_state(step_state)
			_debug_sync_calls_this_tick += 1

	var had_completion := false
	var local_completion := false
	for done in result.movement_completions:
		had_completion = true
		var team_id := int(done.team_id)
		var soldier_id := int(done.soldier_id)
		var state: SoldierState = _game_state.get_soldier(team_id, soldier_id)
		var view: Soldier = _get_view(team_id, soldier_id)
		if view != null and state != null:
			var is_selected: bool = (
				team_id == _session.active_team_id
				and soldier_id == _control_fireteam().selected_soldier_id
			)
			## Only the soldier that finished — never the whole roster.
			_sync_soldier_view(team_id, soldier_id, is_selected)
			_debug_sync_calls_this_tick += 1
		_log_move_complete(soldier_id, state, view)
		if (
			_session != null
			and _session.can_local_control_soldier(team_id, soldier_id)
		):
			local_completion = true
		_ensure_active_selection_alive()
		_command_bar.show_status(
			"%s Soldier %d move complete." % [Team.display_name(team_id), soldier_id],
		)

	if local_completion:
		## Keep flashing destinations for everyone still en route.
		_sync_run_to_destination_overlay()

	if had_completion:
		## Fog at completion cadence (combat scan also refreshes) — not every step.
		_invalidate_fog_cache()
		_refresh_enemy_spotting_visuals()
		_refresh_command_bar()

	## Movement ticks must never full-roster refresh (refresh_views is false from resolver).
	if result.refresh_views:
		_refresh_enemy_spotting_visuals()


func _log_presentation_perf_if_moving() -> void:
	if _game_state == null or _session == null:
		return
	var movers := 0
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			if state != null and state.is_moving:
				movers += 1
	if movers <= 0:
		return
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var process_msec := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	GameLog.log_system(
		"present_perf movers=%d last_tick_syncs=%d full_refresh_total=%d fps=%.0f process_ms=%.2f" % [
			movers,
			_debug_sync_calls_this_tick,
			_debug_full_refresh_calls,
			fps,
			process_msec,
		]
	)


func _log_perception_profiler() -> void:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var process_msec := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var ai_ms := float(_perf_ai_think_usec) / 1000.0
	var combat_ms := float(_perf_combat_usec) / 1000.0
	var perc_ms := float(PerceptionCacheClass.perception_usec) / 1000.0
	var move_ms := float(_perf_move_usec) / 1000.0
	var present_ms := float(_perf_present_usec) / 1000.0
	var path_ms := 0.0
	var path_n := 0
	var last_ai := ""
	if _ai_framework != null:
		path_ms = float(_ai_framework.pathfind_usec) / 1000.0
		path_n = int(_ai_framework.pathfind_calls)
		last_ai = str(_ai_framework.last_tick_breakdown)
	GameLog.log_system(
		(
			"[Profiler] %s ai_ms=%.2f path_ms=%.2f path_n=%d combat_ms=%.2f "
			+ "move_ms=%.2f present_ms=%.2f perc_ms=%.2f max_frame_ms=%.2f fps=%.0f process_ms=%.2f"
		)
		% [
			PerceptionCacheClass.debug_summary(),
			ai_ms,
			path_ms,
			path_n,
			combat_ms,
			move_ms,
			present_ms,
			perc_ms,
			_perf_max_frame_msec,
			fps,
			process_msec,
		]
	)
	if not last_ai.is_empty() and ai_ms >= 20.0:
		GameLog.log_system("[Profiler] last_ai_tick %s" % last_ai)
	PerceptionCacheClass.reset_counters()
	_perf_ai_think_usec = 0
	_perf_combat_usec = 0
	_perf_present_usec = 0
	_perf_move_usec = 0
	_perf_max_frame_msec = 0.0
	if _ai_framework != null:
		_ai_framework.pathfind_usec = 0
		_ai_framework.pathfind_calls = 0


## Detect presentation desync: view still "moving" after sim halted (~0.5s).
## Do NOT treat normal inter-step waits as stuck — that spammed logs and crashed FPS.
func _scan_stuck_movement_mismatches() -> void:
	if _game_state == null or _session == null:
		return
	var now := SimulationClock.get_ticks_msec()
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			if state == null or state.is_dead:
				continue
			var view: Soldier = _get_view(state.team_id, state.soldier_id)
			if view == null:
				continue
			var key := "%d:%d" % [state.team_id, state.soldier_id]
			var chase: Dictionary = view.debug_chase_fingerprint()
			var view_moving := bool(chase.get("view_moving", false))
			var dist := float(chase.get("dist_to_target", 0.0))
			## Only true desync: presentation moving while sim has stopped.
			var view_desync := view_moving and not state.is_moving and dist <= 0.5
			if not view_desync:
				if _stuck_mismatch_since.has(key):
					_stuck_mismatch_since.erase(key)
					_clear_stuck_overlay(view)
				continue
			if not _stuck_mismatch_since.has(key):
				_stuck_mismatch_since[key] = now
				continue
			var age: int = now - int(_stuck_mismatch_since[key])
			if age < 500:
				continue
			## Log once per stuck episode (not every profiler second).
			if not _stuck_logged.has(key):
				_stuck_logged[key] = true
				PerceptionCacheClass.stuck_events += 1
				var cmd_info := _stuck_commander_info(state.team_id, state.soldier_id)
				GameLog.log_system(
					(
						"[StuckMove] id=%s cmd=%s view_moving=%s sim_moving=%s cell=%s "
						+ "path_len=%d age_ms=%d last_cmd=%s chase=%s"
					)
					% [
						key,
						str(cmd_info.get("state", "—")),
						view_moving,
						state.is_moving,
						state.grid_position,
						state.current_path.size(),
						age,
						str(cmd_info.get("last_command", "—")),
						chase,
					]
				)
				_show_stuck_overlay(view)
			## Self-heal presentation desync (sim already halted).
			view.stop_movement()
			view.position = IsometricGrid.grid_to_world(state.grid_position)
			_stuck_mismatch_since.erase(key)
			_stuck_logged.erase(key)
			_clear_stuck_overlay(view)


func _stuck_commander_info(team_id: int, soldier_id: int) -> Dictionary:
	var out := {
		"state": "—",
		"objective": "—",
		"last_command": "—",
		"last_path_request_msec": -1,
		"waiting_commander": false,
	}
	if _ai_framework == null or _game_state == null or _game_state.command_hierarchy == null:
		return out
	var hierarchy = _game_state.command_hierarchy
	var pid := -1
	for raw_pid in hierarchy.all_player_ids():
		if hierarchy.get_team_id(int(raw_pid)) != team_id:
			continue
		if soldier_id in hierarchy.get_soldier_ids(int(raw_pid)):
			pid = int(raw_pid)
			break
	if pid <= 0:
		return out
	var commander = _ai_framework.get_commander(pid)
	if commander == null:
		return out
	var snap: Dictionary = commander.debug_snapshot(_game_state)
	out["state"] = str(snap.get("state", "—"))
	out["objective"] = str(snap.get("objective", "—"))
	out["last_command"] = str(snap.get("last_command", snap.get("last_action", "—")))
	out["last_path_request_msec"] = int(snap.get("last_path_request_msec", -1))
	out["waiting_commander"] = hierarchy.is_ai_player(pid)
	return out


func _show_stuck_overlay(view: Soldier) -> void:
	if view == null:
		return
	var marker: Node = view.get_node_or_null("StuckMoveDebug")
	if marker == null:
		var label := Label.new()
		label.name = "StuckMoveDebug"
		label.text = "STUCK"
		label.position = Vector2(-18, -48)
		label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.15, 1.0))
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		view.add_child(label)
	else:
		(marker as CanvasItem).visible = true


func _clear_stuck_overlay(view: Soldier) -> void:
	if view == null:
		return
	var marker: Node = view.get_node_or_null("StuckMoveDebug")
	if marker != null:
		marker.queue_free()


func _combat_scan_interval_msec() -> int:
	return maxi(int(round(GameplayPolicies.hit.auto_fire_scan_interval * 1000.0)), 1)


func _get_manual_fire_at_shooters() -> Array[SoldierState]:
	var shooters: Array[SoldierState] = []
	var fireteam: Fireteam = _control_fireteam()
	if fireteam == null:
		return shooters
	if _squad_fire_at_mode:
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if not soldier_state.is_alive():
				continue
			if not _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id):
				continue
			shooters.append(soldier_state)
	else:
		var shooter: SoldierState = fireteam.get_soldier(_fire_at_soldier_id)
		if (
			shooter != null
			and shooter.is_alive()
			and _session.can_local_control_soldier(shooter.team_id, shooter.soldier_id)
		):
			shooters.append(shooter)
	return shooters


func _get_face_scope_soldiers() -> Array[SoldierState]:
	var soldiers: Array[SoldierState] = []
	var fireteam: Fireteam = _control_fireteam()
	if fireteam == null:
		return soldiers
	if _face_soldier_id == CommandBar.SQUAD_ID:
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if not soldier_state.is_alive():
				continue
			if not _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id):
				continue
			if soldier_state.is_stunned():
				continue
			soldiers.append(soldier_state)
	else:
		var soldier_state: SoldierState = fireteam.get_soldier(_face_soldier_id)
		if (
			soldier_state != null
			and soldier_state.is_alive()
			and not soldier_state.is_stunned()
			and _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id)
		):
			soldiers.append(soldier_state)
	return soldiers


func _get_face_preview_shooter() -> SoldierState:
	var fireteam: Fireteam = _control_fireteam()
	if _face_soldier_id == CommandBar.SQUAD_ID:
		var selected: SoldierState = fireteam.get_selected()
		if selected != null and selected.is_alive():
			return selected
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state.is_alive():
				return soldier_state
		return null
	return fireteam.get_soldier(_face_soldier_id)


func _clear_face_manual_override() -> void:
	_face_manual_aim_cell = Vector2i(-999999, -999999)
	_face_manual_aim_world = Vector2(-99999, -99999)
	_face_manual_override_until_msec = 0
	_face_revert_keys.clear()
	_face_committed_keys.clear()


func _mark_face_committed(soldiers: Array[SoldierState]) -> void:
	_face_committed_keys.clear()
	for soldier_state in soldiers:
		_face_committed_keys.append(
			Team.soldier_key(soldier_state.team_id, soldier_state.soldier_id)
		)


func _tick_face_manual_revert() -> void:
	if _face_manual_override_until_msec <= 0:
		return
	if Time.get_ticks_msec() < _face_manual_override_until_msec:
		return
	_apply_face_revert_to_engaged()


func _apply_face_revert_to_engaged() -> void:
	_face_manual_override_until_msec = 0
	_face_manual_aim_cell = Vector2i(-999999, -999999)
	_face_manual_aim_world = Vector2(-99999, -99999)
	if _face_revert_keys.is_empty():
		return
	var reverted := false
	for key in _face_revert_keys:
		var parts: PackedStringArray = str(key).split(":")
		if parts.size() < 2:
			continue
		var team_id := int(parts[0])
		var soldier_id := int(parts[1])
		var soldier_state: SoldierState = _game_state.get_soldier(team_id, soldier_id)
		if soldier_state == null or not soldier_state.is_engaged():
			continue
		var engaged_target: SoldierState = _game_state.get_soldier(
			soldier_state.engaged_target_team_id,
			soldier_state.engaged_target_soldier_id,
		)
		if engaged_target == null or not engaged_target.is_alive():
			continue
		var fireteam: Fireteam = _game_state.session.get_fireteam(team_id)
		if fireteam.face_toward_tile(soldier_id, engaged_target.grid_position):
			reverted = true
	_face_revert_keys.clear()
	_face_committed_keys.clear()
	if reverted:
		if _face_mode:
			_sync_face_soldier_views()
		else:
			_refresh_all_views()


func _update_face_preview() -> void:
	var cone_shooter: SoldierState = _get_face_preview_shooter()
	if cone_shooter == null or cone_shooter.is_dead:
		_los_visualizer.hide_preview()
		return

	var hover_soldier: SoldierState = _find_living_soldier_at_mouse()
	var aim_world := _get_world_mouse_local()
	var click_cell := IsometricGrid.world_to_grid(aim_world)
	var explicit_team_id := -1
	var explicit_soldier_id := -1
	if hover_soldier != null and hover_soldier.team_id != cone_shooter.team_id:
		explicit_team_id = hover_soldier.team_id
		explicit_soldier_id = hover_soldier.soldier_id
		click_cell = hover_soldier.grid_position
		aim_world = _get_soldier_tracer_point(hover_soldier)

	if _face_soldier_id == CommandBar.SQUAD_ID:
		_update_face_squad_los_preview(
			cone_shooter,
			aim_world,
			click_cell,
			explicit_team_id,
			explicit_soldier_id,
		)
		return

	var shooter: SoldierState = cone_shooter
	var weapon := shooter.get_weapon_data()
	var max_range := ConeOfFireClass.effective_range(weapon.range_tiles) if weapon != null else ConeOfFireClass.RANGE_BONUS
	var from_world := _get_soldier_tracer_point(shooter)
	var preview := CombatSystem.evaluate_fire_at_preview(
		_game_state,
		shooter,
		from_world,
		aim_world,
		click_cell,
		explicit_team_id,
		explicit_soldier_id,
	)
	var cone_world := ConeOfFireClass.cone_outline_world_toward(
		from_world,
		aim_world,
		shooter.grid_position,
		max_range,
	)
	## LOS cone only — soldiers face on click, not while the mouse moves.
	_los_visualizer.show_fire_at_preview(from_world, cone_world, preview)


func _update_face_squad_los_preview(
	cone_shooter: SoldierState,
	aim_world: Vector2,
	click_cell: Vector2i,
	explicit_team_id: int,
	explicit_soldier_id: int,
) -> void:
	var weapon := cone_shooter.get_weapon_data()
	var max_range := (
		ConeOfFireClass.effective_range(weapon.range_tiles)
		if weapon != null
		else ConeOfFireClass.RANGE_BONUS
	)
	var cone_from_world := _get_soldier_tracer_point(cone_shooter)
	var cone_world := ConeOfFireClass.cone_outline_world_toward(
		cone_from_world,
		aim_world,
		cone_shooter.grid_position,
		max_range,
	)

	var entries: Array = []
	var cone_has_target := false

	for shooter_state in _get_face_scope_soldiers():
		var from_world := _get_soldier_tracer_point(shooter_state)
		var preview: FireAtPreviewResult = CombatSystem.evaluate_fire_at_preview(
			_game_state,
			shooter_state,
			from_world,
			aim_world,
			click_cell,
			explicit_team_id,
			explicit_soldier_id,
		)
		if preview.target != null and preview.targetable:
			cone_has_target = true
		entries.append({"from_world": from_world, "preview": preview})

	## LOS cone only — soldiers face on click, not while the mouse moves.
	_los_visualizer.show_squad_fire_at_previews(entries, cone_world, cone_has_target)


func _sync_face_soldier_views() -> void:
	var active_fireteam: Fireteam = _control_fireteam()
	for soldier_state in _get_face_scope_soldiers():
		var is_selected: bool = soldier_state.soldier_id == active_fireteam.selected_soldier_id
		_sync_soldier_view(soldier_state.team_id, soldier_state.soldier_id, is_selected)


func _clear_manual_fire_at_targets() -> void:
	CommandRouter.cancel_sustained_fire(_game_state)


func _active_fireteam_has_engaged_soldier() -> bool:
	var fireteam: Fireteam = _control_fireteam()
	for state in fireteam.soldiers:
		var soldier_state: SoldierState = state
		if not _is_soldier_in_fire_at_scope(soldier_state):
			continue
		if soldier_state.is_sustained_fire():
			return true
	return false


func _sync_fire_at_ui_from_engagements() -> void:
	var has_engaged := _active_fireteam_has_engaged_soldier()
	_fire_at_engaged = has_engaged
	_command_bar.set_fire_at_engaged(has_engaged)


func _exit_fire_at_mode(message: String = "") -> void:
	_clear_manual_fire_at_targets()
	_fire_at_mode = false
	_squad_fire_at_mode = false
	_fire_at_engaged = false
	_los_visualizer.hide_preview()
	_last_fire_at_preview_cell = Vector2i(-999999, -999999)
	_command_bar.set_fire_at_engaged(false)
	_command_bar.clear_fire_at_mode()
	if not message.is_empty():
		_command_bar.show_status(message)


## End Fire At mouse-aim without cancelling sustained fire / locked targets.
func _leave_fire_at_targeting() -> void:
	_fire_at_mode = false
	_squad_fire_at_mode = false
	_los_visualizer.hide_preview()
	_last_fire_at_preview_cell = Vector2i(-999999, -999999)
	_command_bar.clear_fire_at_mode()
	_sync_fire_at_ui_from_engagements()


func _update_los_preview() -> void:
	## Presentation-only: reads GameState + CombatSystem queries; does not mutate gameplay data.
	if _grenade_mode:
		_update_grenade_preview()
		return
	if _face_mode:
		_update_face_preview()
		return
	if not _fire_at_mode:
		_los_visualizer.hide_preview()
		return

	var cone_shooter: SoldierState = _get_fire_at_preview_shooter()
	if cone_shooter == null or cone_shooter.is_dead:
		_los_visualizer.hide_preview()
		return

	var hover_soldier: SoldierState = _find_living_soldier_at_mouse()
	var aim_world := _get_world_mouse_local()
	var click_cell := IsometricGrid.world_to_grid(aim_world)
	var explicit_team_id := -1
	var explicit_soldier_id := -1
	if hover_soldier != null and hover_soldier.team_id != cone_shooter.team_id:
		explicit_team_id = hover_soldier.team_id
		explicit_soldier_id = hover_soldier.soldier_id
		click_cell = hover_soldier.grid_position
		aim_world = _get_soldier_tracer_point(hover_soldier)

	if _squad_fire_at_mode:
		_update_squad_los_preview(
			cone_shooter,
			aim_world,
			click_cell,
			explicit_team_id,
			explicit_soldier_id,
		)
		return

	var shooter: SoldierState = cone_shooter
	var weapon := shooter.get_weapon_data()
	var max_range := ConeOfFireClass.effective_range(weapon.range_tiles) if weapon != null else ConeOfFireClass.RANGE_BONUS
	var from_world := _get_soldier_tracer_point(shooter)
	var preview := CombatSystem.evaluate_fire_at_preview(
		_game_state,
		shooter,
		from_world,
		aim_world,
		click_cell,
		explicit_team_id,
		explicit_soldier_id,
	)
	var cone_world := ConeOfFireClass.cone_outline_world_toward(
		from_world,
		aim_world,
		shooter.grid_position,
		max_range,
	)
	## LOS cone only — soldiers face / Fire At on click, not while the mouse moves.
	_los_visualizer.show_fire_at_preview(from_world, cone_world, preview)


func _update_grenade_preview() -> void:
	var shooter: SoldierState = _grenade_preview_shooter()
	if shooter == null:
		_los_visualizer.hide_preview()
		return

	var target_cell := IsometricGrid.world_to_cell_at_point(_get_world_mouse_local())
	if _map_data != null:
		target_cell = _map_data.clamp_to_bounds(target_cell)
	var from_world := _get_soldier_tracer_point(shooter)
	var target_world := IsometricGrid.soldier_aim_point(target_cell)
	var in_bounds := _map_data != null and _map_data.is_in_bounds(target_cell)
	var in_range := (
		in_bounds
		and CombatSystem.grenade_throw_distance(shooter.grid_position, target_cell)
		<= CombatSystem.GRENADE_THROW_RANGE
	)
	var safe_for_friendlies := (
		in_range
		and not CombatSystem.grenade_would_hit_friendly(
			_game_state, shooter.team_id, target_cell
		)
	)
	_los_visualizer.show_grenade_throw_preview(from_world, target_world, safe_for_friendlies)

	if _grenade_soldier_id == CommandBar.SQUAD_ID:
		var fireteam: Fireteam = _control_fireteam()
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if (
				soldier_state == null
				or soldier_state.is_dead
				or soldier_state.grenade_count <= 0
				or soldier_state.is_stunned()
				or soldier_state.has_pending_grenade()
			):
				continue
			if ActionResolverClass.preview_grenade_facing(
				_game_state,
				soldier_state.team_id,
				soldier_state.soldier_id,
				target_cell,
			):
				_sync_soldier_view(
					soldier_state.team_id,
					soldier_state.soldier_id,
					soldier_state.soldier_id == fireteam.selected_soldier_id,
				)
	else:
		if ActionResolverClass.preview_grenade_facing(
			_game_state,
			shooter.team_id,
			shooter.soldier_id,
			target_cell,
		):
			_sync_soldier_view(shooter.team_id, shooter.soldier_id, true)


func _update_squad_los_preview(
	cone_shooter: SoldierState,
	aim_world: Vector2,
	click_cell: Vector2i,
	explicit_team_id: int,
	explicit_soldier_id: int,
) -> void:
	var weapon := cone_shooter.get_weapon_data()
	var max_range := (
		ConeOfFireClass.effective_range(weapon.range_tiles)
		if weapon != null
		else ConeOfFireClass.RANGE_BONUS
	)
	var cone_from_world := _get_soldier_tracer_point(cone_shooter)
	var cone_world := ConeOfFireClass.cone_outline_world_toward(
		cone_from_world,
		aim_world,
		cone_shooter.grid_position,
		max_range,
	)

	var entries: Array = []
	var cone_has_target := false

	for shooter_state in _get_manual_fire_at_shooters():
		var from_world := _get_soldier_tracer_point(shooter_state)
		var preview: FireAtPreviewResult
		preview = CombatSystem.evaluate_fire_at_preview(
			_game_state,
			shooter_state,
			from_world,
			aim_world,
			click_cell,
			explicit_team_id,
			explicit_soldier_id,
		)
		if preview.target != null and preview.targetable:
			cone_has_target = true
		entries.append({"from_world": from_world, "preview": preview})

	## LOS cone only — soldiers face / Fire At on click, not while the mouse moves.
	_los_visualizer.show_squad_fire_at_previews(entries, cone_world, cone_has_target)


func _get_fire_at_preview_shooter() -> SoldierState:
	var fireteam: Fireteam = _control_fireteam()
	if _squad_fire_at_mode:
		var selected: SoldierState = fireteam.get_selected()
		if selected != null and selected.is_alive():
			return selected
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state.is_alive():
				return soldier_state
		return null
	return fireteam.get_soldier(_fire_at_soldier_id)


func _load_map_data() -> void:
	## Catalog already loaded from menus/editor — avoid full manifest reparse every match.
	CocTileCatalog.ensure_loaded()
	var pending := ""
	if BuildConfig.is_survival_playtest():
		EditorPlaySession.consume_pending_map_path()
		EditorPlaySession.clear_return_flag()
		_return_to_editor_on_exit = false
	else:
		pending = EditorPlaySession.consume_pending_map_path()
		_return_to_editor_on_exit = EditorPlaySession.should_return_to_editor()
	if not pending.is_empty():
		_map_data = MapLoader.load_path(pending)
	elif GameModeManager.is_local_multiplayer():
		var map_id := str(NetworkClient.last_snapshot.get("mapId", MatchConfigClass.MAP_FARM_FIGHT))
		if map_id.is_empty():
			map_id = MatchConfigClass.MAP_FARM_FIGHT
		_map_data = MapLoader.load_path("res://maps/%s.json" % map_id)
	else:
		var match_cfg = MatchConfigStoreClass.peek_pending()
		if match_cfg != null and not str(match_cfg.map_path()).is_empty():
			_map_data = MapLoader.load_path(match_cfg.map_path())
		else:
			_map_data = MapLoader.load_path(MapDataClass.resolve_startup_map_path())
	IsometricGrid.set_original_projection_enabled(
		_map_data != null and _map_data.uses_original_projection
	)


func _init_session_from_spawns() -> void:
	var blue_spawns: Array[Vector2i] = _map_data.team_1_spawn_points.duplicate()
	var red_spawns: Array[Vector2i] = _map_data.team_2_spawn_points.duplicate()
	if blue_spawns.is_empty():
		blue_spawns = MapDataClass.default_usa_spawn_points()
	if red_spawns.is_empty():
		red_spawns = MapDataClass.default_germany_spawn_points()
	## Germans stay on authored German lines; USA deploys behind USA lines.
	var germany_anchor := Vector2i(0, 0)
	if not red_spawns.is_empty():
		var gx := 0
		var gy := 0
		for s in red_spawns:
			gx += s.x
			gy += s.y
		germany_anchor = Vector2i(gx / red_spawns.size(), gy / red_spawns.size())
	var match_cfg
	if GameModeManager.is_local_multiplayer():
		## Do not consume user:// pending config — two Godot windows share that file.
		match_cfg = MatchConfigClass.default_local_multiplayer_1v1()
		if PlayerSides.has_assignment():
			match_cfg.local_player_id = 1 if PlayerSides.assigned_team_id == Team.USA else 2
	else:
		match_cfg = MatchConfigStoreClass.consume_pending()
		if match_cfg == null:
			match_cfg = MatchConfigClass.default_offline_1v1()
	if match_cfg.is_survival_1v_all():
		blue_spawns = _map_data.team_1_spawn_points.duplicate()
		if blue_spawns.is_empty():
			blue_spawns = MapDataClass.default_usa_spawn_points()
		red_spawns = _map_data.team_2_spawn_points.duplicate()
		if red_spawns.is_empty():
			red_spawns = MapDataClass.default_germany_spawn_points()
	else:
		blue_spawns = MapDataClass.offset_spawns_behind_enemy(
			blue_spawns,
			germany_anchor,
			_map_data,
			MapDataClass.USA_DEPLOY_BEHIND_CELLS,
		)
	var validation: Dictionary = match_cfg.validate()
	if not bool(validation.get("ok", false)):
		push_warning(
			"MatchConfig invalid — falling back to offline 1v1: %s"
			% str(validation.get("errors", []))
		)
		match_cfg = MatchConfigClass.default_offline_1v1()
	_session = GameSessionClass.from_match_config(match_cfg, blue_spawns, red_spawns)
	if GameModeManager.is_local_multiplayer() and PlayerSides.has_assignment():
		_session.bind_local_player_to_team(PlayerSides.assigned_team_id)
	_game_state = _session.create_game_state(_map_data)
	if match_cfg.is_survival_1v_all():
		_game_state.survival_mode = true
	VictoryPointSystem.ensure_holders_initialized(_map_data)
	ActionResolverClass.apply_match_start_setup(_game_state)
	if match_cfg.is_survival_1v_all():
		var objective := SurvivalModeControllerClass.us_objective_cell(_map_data)
		for state in _session.red_team.soldiers:
			if objective.x > -900:
				state.facing_direction = FacingDirection.toward_cell(
					state.grid_position,
					objective,
				)
	## SP/MP: 15s deploy countdown + zone lock. Offline Quick Start skips (dialog → start).
	if match_cfg != null and bool(match_cfg.timed_deployment):
		_game_state.begin_timed_deployment(ScenarioRulesClass.DEPLOYMENT_TIME_SEC)


func _connect_command_bar() -> void:
	_command_bar.soldier_selected.connect(_on_soldier_selected)
	_command_bar.move_targeting_changed.connect(_on_move_targeting_changed)
	_command_bar.fire_at_mode_changed.connect(_on_fire_at_mode_changed)
	_command_bar.face_mode_changed.connect(_on_face_mode_changed)
	_command_bar.grenade_mode_changed.connect(_on_grenade_mode_changed)
	_command_bar.position_change_requested.connect(_on_position_change_requested)
	_command_bar.fire_control_change_requested.connect(_on_fire_control_change_requested)
	_command_bar.save_requested.connect(_on_save_requested)
	_command_bar.load_requested.connect(_on_load_requested)
	_command_bar.map_save_requested.connect(_on_map_save_requested)
	_command_bar.map_load_requested.connect(_on_map_load_requested)
	_command_bar.center_camera_requested.connect(_on_center_camera_requested)
	_command_bar.rotate_view_left_requested.connect(_on_rotate_view_left_requested)
	_command_bar.rotate_view_right_requested.connect(_on_rotate_view_right_requested)
	_command_bar.set_commanders_requested.connect(_on_set_commanders_requested)
	_command_bar.assign_weapons_requested.connect(_on_assign_weapons_requested)
	_command_bar.ammo_adjust_requested.connect(_on_ammo_adjust_requested)
	_command_bar.retreat_requested.connect(_on_retreat_requested)


func _ensure_command_dialog() -> void:
	if _command_dialog != null:
		return
	_command_dialog = CommandDialogScene.instantiate() as CommandDialog
	$UI.add_child(_command_dialog)
	_command_dialog.briefing_requested.connect(_on_command_briefing_requested)
	_command_dialog.dialog_closed.connect(_on_command_dialog_closed)


func _ensure_assign_weapons_dialog() -> void:
	if _assign_weapons_dialog != null:
		return
	_assign_weapons_dialog = AssignWeaponsDialogScene.instantiate() as AssignWeaponsDialog
	$UI.add_child(_assign_weapons_dialog)
	_assign_weapons_dialog.briefing_requested.connect(_on_assign_weapons_briefing_requested)
	_assign_weapons_dialog.dialog_closed.connect(_on_assign_weapons_dialog_closed)


func _open_command_dialog_for_deployment() -> void:
	if _game_state == null or not _game_state.is_deployment_phase():
		return
	_open_command_dialog()


func _open_survival_difficulty_dialog() -> void:
	if not _is_survival_mode() or _survival_mode == null:
		return
	if _survival_difficulty_dialog == null:
		_survival_difficulty_dialog = SurvivalDifficultyDialogClass.new()
		$UI.add_child(_survival_difficulty_dialog)
		_survival_difficulty_dialog.difficulty_chosen.connect(_on_survival_difficulty_chosen)
	_survival_difficulty_dialog.popup_centered()


func _on_survival_difficulty_chosen(difficulty: int) -> void:
	if _survival_mode == null:
		return
	_survival_mode.apply_difficulty(difficulty)
	_refresh_survival_hud()
	var name := SurvivalModeControllerClass.difficulty_display_name(difficulty)
	var interval := SurvivalModeControllerClass.difficulty_interval_label(difficulty)
	_command_bar.show_status(
		"Survival Mode: %s — new enemy fireteam every %s. Hold the objective."
		% [name, interval]
	)


func _on_set_commanders_requested() -> void:
	_open_command_dialog()


func _on_assign_weapons_requested() -> void:
	_open_assign_weapons_dialog()


func _open_command_dialog() -> void:
	_ensure_command_dialog()
	if _command_dialog == null or _game_state == null:
		return
	_command_dialog.bind_game_state(_game_state)
	_command_dialog.popup_centered()


func _open_assign_weapons_dialog() -> void:
	_ensure_assign_weapons_dialog()
	if _assign_weapons_dialog == null or _game_state == null:
		return
	_assign_weapons_dialog.bind_game_state(_game_state, _game_state.local_player_id)
	_assign_weapons_dialog.popup_centered()


func _on_command_briefing_requested() -> void:
	_command_bar.show_status("View Briefing: set commanders, then hold your objectives.")


func _on_assign_weapons_briefing_requested() -> void:
	_command_bar.show_status("View Briefing: assign weapons from your cache to soldiers.")


func _on_command_dialog_closed() -> void:
	## Offline / untimed: closing Command starts the scenario immediately.
	## SP/MP timed deployment: stay in deploy until the 15s countdown ends.
	if _game_state != null and _game_state.is_deployment_phase():
		if _game_state.locks_deployment_zone():
			_sync_deployment_hud()
			var secs := int(ceil(_game_state.deployment_time_remaining_sec))
			_command_bar.show_status(
				"Deploy in your zone. Scenario starts in %d second%s."
				% [secs, "" if secs == 1 else "s"]
			)
			_refresh_ai_plan_hud()
			return
		_game_state.begin_running_phase()
	_on_timed_deployment_finished()


func _on_timed_deployment_finished() -> void:
	if _command_bar != null:
		_command_bar.set_deployment_phase(false)
		_command_bar.append_chat_system("ATTENTION: Scenario Running")
		_refresh_scenario_hud()
		_command_bar.show_status("Deployment complete. Chain of command ready.")
	_invalidate_fog_cache()
	_refresh_enemy_spotting_visuals()
	_refresh_ai_plan_hud()


func _sync_deployment_hud() -> void:
	if _command_bar == null or _game_state == null:
		return
	if _game_state.locks_deployment_zone():
		_command_bar.set_deployment_phase(true, _game_state.deployment_time_remaining_sec)
	else:
		_command_bar.set_deployment_phase(_game_state.is_deployment_phase())


func _refresh_scenario_hud() -> void:
	if _command_bar == null or _game_state == null:
		return
	_command_bar.set_scenario_clock(_game_state.time_remaining())
	_command_bar.set_scenario_scores(
		ScenarioRulesClass.total_points(_game_state, Team.USA),
		ScenarioRulesClass.total_points(_game_state, Team.GERMANY),
		_game_state.team_kill_points,
		_game_state.team_terrain_points,
		_vp_holder_summary(),
	)
	_refresh_survival_hud()


func _refresh_survival_hud() -> void:
	if _command_bar == null or _game_state == null or not _is_survival_mode():
		return
	if _survival_mode == null:
		return
	var fireteams := SurvivalModeControllerClass.count_deployed_enemy_fireteams(_session)
	var next_sec := _survival_mode.time_until_next_wave()
	var kills := _game_state.survival_enemies_killed
	_command_bar.set_survival_stats(fireteams, next_sec, kills)


func _vp_holder_summary() -> String:
	if _game_state == null or _game_state.map_data == null:
		return ""
	var bits: Array[String] = []
	for entry in _game_state.map_data.victory_points:
		if not entry is Dictionary:
			continue
		var name := str(entry.get("name", "VP"))
		var holder := str(entry.get("holder", entry.get("initial_holder", "?")))
		var short := "USA" if VictoryPointSystem.holder_is_usa(holder) else "GER"
		bits.append("%s:%s" % [name, short])
	return ", ".join(bits)


func _on_scenario_ended() -> void:
	if _game_state == null:
		return
	_refresh_scenario_hud()
	var cause_text := ScenarioEndCauseClass.display_name(_game_state.end_cause)
	if _command_bar != null:
		_command_bar.append_chat_system("ATTENTION: %s" % cause_text)
		_command_bar.show_status(ScenarioWinnerClass.display_name(_game_state.winner))
	## Brief beat before debrief so the end state is visible on the map.
	get_tree().create_timer(3.0).timeout.connect(_open_mission_debrief_dialog)


func _ensure_mission_debrief_dialog() -> void:
	if _mission_debrief_dialog != null:
		return
	_mission_debrief_dialog = MissionDebriefDialogClass.new()
	_mission_debrief_dialog.finished.connect(_on_mission_debrief_finished)
	$UI.add_child(_mission_debrief_dialog)


func _open_mission_debrief_dialog() -> void:
	_ensure_mission_debrief_dialog()
	if _mission_debrief_dialog == null or _game_state == null:
		return
	if not _game_state.scenario_ended:
		return
	_mission_debrief_dialog.bind_game_state(_game_state)
	_mission_debrief_dialog.popup_centered()


func _on_mission_debrief_finished() -> void:
	## End the match and leave the battlefield after debrief Close / countdown.
	if _return_to_editor_on_exit and BuildConfig.is_development():
		EditorPlaySession.clear_return_flag()
		get_tree().change_scene_to_file("res://scenes/editor/map_editor.tscn")
		return
	get_tree().change_scene_to_file("res://scenes/mode_select.tscn")


func _on_retreat_requested() -> void:
	if _game_state == null or _game_state.scenario_ended or _game_state.is_deployment_phase():
		return
	var team_id := _game_state.local_team_id()
	if ScenarioRulesClass.request_retreat(_game_state, team_id):
		_on_scenario_ended()


func _refresh_ai_plan_hud() -> void:
	if _ai_plan_hud == null:
		return
	if BuildConfig.is_survival_playtest():
		_ai_plan_hud.visible = false
		return
	if _ai_plan_hud.has_method("bind_framework"):
		_ai_plan_hud.bind_framework(_ai_framework, _game_state)
	elif _ai_plan_hud.has_method("bind_game_state"):
		_ai_plan_hud.bind_game_state(_game_state)


func _on_assign_weapons_dialog_closed() -> void:
	_refresh_all_views()
	_command_bar.show_status("Weapon assignment updated.")


func _on_ammo_adjust_requested(soldier_id: int, delta: int) -> void:
	if _game_state == null or _session == null:
		return
	if not _session.can_local_control_soldier(_session.active_team_id, soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return
	var cmd := AdjustAmmoCommandClass.new()
	cmd.team_id = _session.active_team_id
	cmd.soldier_id = soldier_id
	cmd.delta = delta
	var result: ActionResultClass = CommandRouter.submit_command(_game_state, cmd)
	_present_action_result(result)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if BuildConfig.is_development():
			if event.keycode == KEY_1:
				_switch_active_team(Team.USA)
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_2:
				_switch_active_team(Team.GERMANY)
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_B:
				_toggle_grass_layer()
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_T:
				_toggle_debug_targeting_overlays()
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_F3:
				_world.toggle_debug_overlay()
				_command_bar.show_status(
					"CoC tile debug %s" % ("ON" if _coc_debug_overlay.enabled else "OFF")
				)
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_F4:
				_world.toggle_handedness_overlay()
				_command_bar.show_status("Handedness overlay toggled (F5 cycles candidates)")
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_F5:
				var cand := _world.cycle_handedness_candidate()
				_command_bar.show_status("Handedness candidate: %s" % cand)
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_F6:
				_world.toggle_terrain_overlay()
				_command_bar.show_status(
					"Terrain overlay %s (green=Even yellow=Climb red=NoPass)"
					% ("ON" if _world.is_terrain_overlay_enabled() else "OFF")
				)
				get_viewport().set_input_as_handled()
				return
			if event.keycode == KEY_ESCAPE and _return_to_editor_on_exit:
				EditorPlaySession.clear_return_flag()
				get_tree().change_scene_to_file("res://scenes/editor/map_editor.tscn")
				get_viewport().set_input_as_handled()
				return
		if event.is_action_pressed("rotate_view_left"):
			_apply_view_rotation_left()
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("rotate_view_right"):
			_apply_view_rotation_right()
			get_viewport().set_input_as_handled()
			return

	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed:
		return

	var target_cell := IsometricGrid.world_to_cell_at_point(_get_world_mouse_local())
	if _map_data != null:
		target_cell = _map_data.clamp_to_bounds(target_cell)

	if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
		if _fire_at_mode:
			_exit_fire_at_mode("Targeting cancelled.")
			get_viewport().set_input_as_handled()
			return
		if _face_mode:
			_face_mode = false
			_command_bar.clear_face_mode()
			_clear_face_manual_override()
			_los_visualizer.hide_preview()
			_command_bar.show_status("Facing cancelled.")
			get_viewport().set_input_as_handled()
			return
		if _grenade_mode:
			_grenade_mode = false
			_command_bar.clear_grenade_mode()
			_los_visualizer.hide_preview()
			_command_bar.show_status("Grenade targeting cancelled.")
			get_viewport().set_input_as_handled()
		return

	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return

	if _fire_at_mode:
		var clicked_soldier: SoldierState = _find_living_soldier_at_mouse()
		if clicked_soldier != null and clicked_soldier.team_id == _session.active_team_id:
			_command_bar.show_status("Cannot shoot friendlies.")
			get_viewport().set_input_as_handled()
			return

		var aim_world: Vector2
		if clicked_soldier != null:
			aim_world = _get_soldier_tracer_point(clicked_soldier)
		else:
			aim_world = IsometricGrid.soldier_aim_point(target_cell)
		_apply_fire_at_aim(aim_world, clicked_soldier, target_cell)
		get_viewport().set_input_as_handled()
		return

	if _face_mode:
		var clicked_soldier: SoldierState = _find_living_soldier_at_mouse()
		if clicked_soldier != null and clicked_soldier.team_id == _session.active_team_id:
			_command_bar.show_status("Cannot face onto friendlies.")
			get_viewport().set_input_as_handled()
			return

		var aim_world: Vector2
		if clicked_soldier != null:
			aim_world = _get_soldier_tracer_point(clicked_soldier)
			_apply_face_enemy_fire(aim_world, clicked_soldier)
		else:
			aim_world = IsometricGrid.soldier_aim_point(target_cell)
			_apply_face_at_tile(target_cell, aim_world)
		get_viewport().set_input_as_handled()
		return

	if _grenade_mode:
		_apply_grenade_command(target_cell)
		get_viewport().set_input_as_handled()
		return

	if not _move_targeting:
		return

	var move_cmd := MoveCommand.new()
	move_cmd.team_id = _session.active_team_id
	move_cmd.target_cell = target_cell
	move_cmd.movement_mode = _active_movement_mode
	if _squad_move_targeting:
		move_cmd.scope = MoveCommand.Scope.SQUAD
	else:
		move_cmd.scope = MoveCommand.Scope.SINGLE
		move_cmd.soldier_id = _move_soldier_id
	_apply_move_command(move_cmd)
	get_viewport().set_input_as_handled()


func _switch_active_team(team_id: int) -> void:
	if not PlayerSides.can_control_team(team_id):
		_command_bar.show_status(
			"You control %s only." % PlayerSides.display_side_name()
		)
		return
	## Offline / SP: 1=USA, 2=Germany hands local control to that side.
	if GameModeManager.is_offline_dev():
		if not _offline_dev_take_team_control(team_id):
			return
	elif _session != null and not _session.local_owned_fireteams().is_empty():
		var owns_side := false
		for ft in _session.local_owned_fireteams():
			if ft.team_id == team_id:
				owns_side = true
				break
		if not owns_side:
			_command_bar.show_status("You do not own a fireteam on that side.")
			return
	if team_id == _session.active_team_id and _session.get_local_control_fireteam() != null \
			and _session.get_local_control_fireteam().team_id == team_id:
		return
	_invalidate_fog_cache()
	_session.set_active_team(team_id)
	_move_targeting = false
	_squad_move_targeting = false
	_fire_at_mode = false
	_squad_fire_at_mode = false
	_fire_at_engaged = false
	_face_mode = false
	_grenade_mode = false
	_command_bar.set_active_team(team_id)
	var fireteam: Fireteam = _control_fireteam()
	_repair_fireteam_selection(fireteam)
	_command_bar.sync_selected_soldier(fireteam.selected_soldier_id)
	_apply_team_default_camera(team_id)
	_refresh_all_views()
	var status := "Controlling %s team." % Team.display_name(team_id)
	if GameModeManager.is_offline_dev():
		status += " Hotseat — press 1/2 to switch sides."
	_command_bar.show_status(status)


## Offline Quick Start: claim target side as human. Both sides stay human (no AI).
func _offline_dev_take_team_control(team_id: int) -> bool:
	if _session == null or _game_state == null:
		return false
	if team_id != Team.USA and team_id != Team.GERMANY:
		return false
	var target_ft: Fireteam = null
	for ft in _session.owned_fireteams:
		if ft.team_id == team_id:
			target_ft = ft
			break
	if target_ft == null:
		_command_bar.show_status("No fireteam on that side.")
		return false
	var target_pid := target_ft.owner_player_id
	var current_pid := _session.local_player_id
	if current_pid == target_pid:
		return true
	var hierarchy = _game_state.command_hierarchy
	if hierarchy != null and hierarchy.has_player(target_pid) and hierarchy.is_ai_player(target_pid):
		PlayerSlotOwnershipClass.claim_slot_as_human(_game_state, _ai_framework, target_pid)
	elif _ai_framework != null:
		_ai_framework.disable_commander(target_pid)
	## Offline 1v1 is human-only — never hand the previous side back to AI.
	if _ai_framework != null:
		_ai_framework.disable_commander(current_pid)
		_ai_framework.disable_commander(target_pid)
	_session.local_player_id = target_pid
	if _session.match_config != null:
		_session.match_config.local_player_id = target_pid
	if _game_state != null:
		_game_state.local_player_id = target_pid
	return true


func _apply_map_presentation() -> void:
	_world.apply_map_data(_map_data)
	_world.set_grass_visible(_grass_layer_visible)


func _toggle_grass_layer() -> void:
	_grass_layer_visible = not _grass_layer_visible
	_world.set_grass_visible(_grass_layer_visible)
	if _grass_layer_visible:
		_command_bar.show_status("Ground Layer Visible")
	else:
		_command_bar.show_status("Ground Layer Hidden")


func _toggle_debug_targeting_overlays() -> void:
	_debug_targeting_overlays = not _debug_targeting_overlays
	_iso_map.set_path_overlay_debug_visible(_debug_targeting_overlays)
	_los_visualizer.set_debug_visible(_debug_targeting_overlays)
	_command_bar.show_status(
		"Targeting overlays %s (path / aim / LOS)"
		% ("ON" if _debug_targeting_overlays else "OFF")
	)


func _spawn_all_soldier_views() -> void:
	var t0 := Time.get_ticks_usec()
	var spawned := 0
	var movers_root: Node2D = _depth_sorted
	if _depth_sorted != null and _depth_sorted.has_method("get_movers_root"):
		movers_root = _depth_sorted.get_movers_root()
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			spawned += _spawn_soldier_view(state, movers_root)
	GameLog.log_system(
		"[Load] spawned %d soldier views in %.0fms"
		% [spawned, float(Time.get_ticks_usec() - t0) / 1000.0]
	)


func _spawn_soldier_view(soldier_state: SoldierState, movers_root: Node2D) -> int:
	if soldier_state == null or movers_root == null:
		return 0
	var key := Team.soldier_key(soldier_state.team_id, soldier_state.soldier_id)
	if _soldier_views.has(key):
		return 0
	var view: Soldier = SoldierScene.instantiate()
	view.soldier_id = soldier_state.soldier_id
	view.team_id = soldier_state.team_id
	view.movement_step_reached.connect(_on_soldier_step_reached)
	view.movement_finished.connect(_on_soldier_movement_finished)
	view.stance_transition_finished.connect(_on_soldier_stance_transition_finished)
	view.stance_transition_cancelled.connect(_on_soldier_stance_transition_cancelled)
	view.exposed_engagement_prone_requested.connect(_on_soldier_exposed_engagement_prone_requested)
	movers_root.add_child(view)
	_soldier_views[key] = view
	return 1


func _spawn_soldier_views_for_fireteam(fireteam: Fireteam) -> void:
	if fireteam == null:
		return
	var movers_root: Node2D = _depth_sorted
	if _depth_sorted != null and _depth_sorted.has_method("get_movers_root"):
		movers_root = _depth_sorted.get_movers_root()
	var spawned := 0
	for state in fireteam.soldiers:
		spawned += _spawn_soldier_view(state, movers_root)
	if spawned > 0:
		_refresh_all_views()


func _is_survival_mode() -> bool:
	return _game_state != null and _game_state.survival_mode


func _apply_survival_camera_rotation() -> void:
	## Survival uses the map default, then two extra quarter-turns vs other modes.
	IsometricGrid.rotate_view_right()
	IsometricGrid.rotate_view_right()
	_refresh_view_rotation()


func _tick_survival_mode() -> void:
	if _survival_mode == null or _game_state == null or _session == null:
		return
	if _game_state.scenario_ended or _game_state.is_deployment_phase():
		return
	var wave_line := _survival_mode.process_tick(
		_game_state,
		_session,
		Callable(self, "_enable_survival_ai_commander"),
	)
	if not wave_line.is_empty():
		if _survival_mode.last_spawned_fireteam != null:
			_spawn_soldier_views_for_fireteam(_survival_mode.last_spawned_fireteam)
		_refresh_ai_plan_hud()
		if _survival_announcement != null:
			_survival_announcement.show_deployment_announcement()
		GameLog.log_system("[Survival] %s" % wave_line)
		_command_bar.show_status(wave_line)
	_refresh_survival_hud()


func _enable_survival_ai_commander(player_id: int) -> void:
	if _ai_framework == null or player_id <= 0:
		return
	if _game_state != null:
		_ai_framework.sync_from_hierarchy(_game_state)
	_ai_framework.enable_commander(player_id)
	var commander = _ai_framework.get_commander(player_id)
	if commander != null:
		commander.aggression = 2.0
		commander.request_replan("survival_wave")


func _configure_survival_ge_commanders() -> void:
	if _ai_framework == null or _game_state == null or _game_state.command_hierarchy == null:
		return
	for pid in _game_state.command_hierarchy.all_player_ids():
		var player_id := int(pid)
		if not _game_state.command_hierarchy.is_ai_player(player_id):
			continue
		if _game_state.command_hierarchy.get_team_id(player_id) != Team.GERMANY:
			continue
		_enable_survival_ai_commander(player_id)


func _refresh_all_views() -> void:
	_debug_full_refresh_calls += 1
	_invalidate_fog_cache()
	_apply_spotting_cell_overrides()
	var active_team: int = _session.active_team_id
	var active_fireteam: Fireteam = _control_fireteam()
	_rebuild_fog_cache_if_needed()
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			var is_selected: bool = (
				soldier_state.team_id == active_team
				and soldier_state.soldier_id == active_fireteam.selected_soldier_id
			)
			_sync_soldier_view(soldier_state.team_id, soldier_state.soldier_id, is_selected)
	_clear_spotting_cell_overrides()

	_ensure_active_selection_alive()
	_refresh_command_bar()


## Cheap stress/hold-fire crouch pose refresh for living soldiers.
func _refresh_idle_pose_visuals() -> void:
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state == null or not soldier_state.is_alive():
				continue
			var view: Soldier = _get_view(soldier_state.team_id, soldier_state.soldier_id)
			if view == null:
				continue
			view.apply_idle_pose_inputs(
				soldier_state.stress,
				soldier_state.fire_control_state,
				soldier_state,
				_corner_aim_cell_for_soldier(soldier_state),
			)


## Cheap fog-of-war update: only enemy modulate/selection, no full anim/facing resync.
func _refresh_enemy_spotting_visuals() -> void:
	_rebuild_fog_cache_if_needed()
	var active_team: int = _session.active_team_id
	var active_fireteam: Fireteam = _control_fireteam()
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state.team_id == active_team or not soldier_state.is_alive():
				continue
			var view: Soldier = _get_view(soldier_state.team_id, soldier_state.soldier_id)
			if view == null:
				continue
			var is_selected: bool = (
				soldier_state.team_id == active_team
				and soldier_state.soldier_id == active_fireteam.selected_soldier_id
			)
			view.apply_spotting_only(is_selected, _fog_visual_for_enemy(soldier_state))


func _refresh_selection_marks() -> void:
	var active_team: int = _session.active_team_id
	var active_fireteam: Fireteam = _control_fireteam()
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			var view: Soldier = _get_view(soldier_state.team_id, soldier_state.soldier_id)
			if view == null:
				continue
			var is_selected: bool = (
				soldier_state.team_id == active_team
				and soldier_state.soldier_id == active_fireteam.selected_soldier_id
			)
			view.set_selected(is_selected)


func _sync_soldier_view(team_id: int, soldier_id: int, is_selected: bool = false) -> void:
	var soldier_state: SoldierState = _get_fireteam(team_id).get_soldier(soldier_id)
	if soldier_state == null:
		return
	var view: Soldier = _get_view(team_id, soldier_id)
	if view == null:
		return
	view.set_presentation_map_data(_map_data)
	var fog_visual: int = Soldier.FogVisual.REVEALED
	if soldier_state.team_id != _session.active_team_id and soldier_state.is_alive():
		fog_visual = _fog_visual_for_enemy(soldier_state)
	var local_control := _session.can_local_control_soldier(
		soldier_state.team_id, soldier_state.soldier_id
	)
	## Local human fireteam keeps DOT markers; everyone else gets a name label.
	var show_id := soldier_state.is_alive() and local_control
	var id_label := ""
	if soldier_state.is_alive() and not local_control:
		id_label = _overhead_name_for_soldier(soldier_state)
	var idle_peek := CoverSystem.PeekSide.NONE
	var idle_corner_cell := Vector2i(-999, -999)
	var fire_aim_cell := _corner_aim_cell_for_soldier(soldier_state)
	if (
		soldier_state.is_alive()
		and soldier_state.position_state != PositionState.DOWN
		and _map_data != null
		and fog_visual == Soldier.FogVisual.REVEALED
	):
		var corner := CoverSystem.corner_idle_at_cell(
			soldier_state.grid_position,
			soldier_state.facing_direction,
			_map_data,
			fire_aim_cell,
		)
		idle_peek = corner.peek_side
		idle_corner_cell = corner.corner_cell
	view.sync_from_state(
		soldier_state,
		is_selected,
		fog_visual,
		show_id,
		idle_peek,
		idle_corner_cell,
		id_label,
		fire_aim_cell,
	)


## Owner player display name for overhead labels (AI: "GE Player 1", etc.).
func _overhead_name_for_soldier(soldier_state: SoldierState) -> String:
	if soldier_state == null or _session == null:
		return ""
	for ft in _session.owned_fireteams:
		if ft == null or ft.team_id != soldier_state.team_id:
			continue
		if not ft.owns_soldier(soldier_state.soldier_id):
			continue
		var pid := int(ft.owner_player_id)
		if _game_state != null and _game_state.command_hierarchy != null:
			var hierarchy_name := _game_state.command_hierarchy.get_display_name(pid)
			if not hierarchy_name.is_empty() and hierarchy_name != "YOU":
				return hierarchy_name
		if _session.match_config != null:
			for slot in _session.match_config.slots:
				if int(slot.get("player_id", -1)) == pid:
					return str(slot.get("display_name", ""))
		return "Player %d" % pid
	return ""


## 1v1: always show the other side as ghosts when out of LOS. 2v2: hide until spotted.
func _is_one_v_one_match() -> bool:
	if _session != null and _session.match_config != null:
		return (
			_session.match_config.match_type
			== MatchConfigClass.MatchType.ONE_V_ONE
		)
	## Offline quick-start / legacy sessions without config — treat two owned FTs as 1v1.
	return _session != null and _session.owned_fireteams.size() <= 2


func _fog_visual_for_enemy(enemy: SoldierState) -> int:
	if enemy == null or not enemy.is_alive():
		return Soldier.FogVisual.HIDDEN
	if _cached_enemy_spotted(enemy):
		return Soldier.FogVisual.REVEALED
	if _is_one_v_one_match():
		return Soldier.FogVisual.GHOST
	return Soldier.FogVisual.HIDDEN


## Aim cell for corner idle — committed face override, engaged target, else Fire At preview.
func _corner_aim_cell_for_soldier(soldier_state: SoldierState) -> Vector2i:
	if soldier_state == null:
		return Vector2i(-999, -999)
	var soldier_key := Team.soldier_key(soldier_state.team_id, soldier_state.soldier_id)
	if _face_manual_aim_cell.x > -99999:
		if _face_committed_keys.has(soldier_key):
			return _face_manual_aim_cell
		if (
			_face_manual_override_until_msec > Time.get_ticks_msec()
			and _face_revert_keys.has(soldier_key)
		):
			return _face_manual_aim_cell
	if soldier_state.is_engaged() and _game_state != null:
		var engaged: SoldierState = _game_state.get_soldier(
			soldier_state.engaged_target_team_id,
			soldier_state.engaged_target_soldier_id,
		)
		if engaged != null and engaged.is_alive():
			return engaged.grid_position
	if _fire_at_mode and _is_soldier_in_fire_at_scope(soldier_state):
		if _last_fire_at_preview_cell.x > -99999:
			return _last_fire_at_preview_cell
	return Vector2i(-999, -999)


func _invalidate_fog_cache() -> void:
	_fog_cache_valid = false
	_fog_spotted_cache.clear()


func _rebuild_fog_cache_if_needed() -> void:
	if _fog_cache_valid:
		return
	_fog_spotted_cache.clear()
	if _session == null or _game_state == null:
		_fog_cache_valid = true
		return
	var viewer_player_id := _fog_viewer_player_id()
	var active_team: int = _session.active_team_id
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state.team_id == active_team or not soldier_state.is_alive():
				continue
			var key := Team.soldier_key(soldier_state.team_id, soldier_state.soldier_id)
			_fog_spotted_cache[key] = _is_enemy_spotted_for_viewer(
				viewer_player_id,
				active_team,
				soldier_state,
			)
	_fog_cache_valid = true


func _cached_enemy_spotted(enemy: SoldierState) -> bool:
	if enemy == null:
		return false
	if _session != null and enemy.team_id == _session.active_team_id:
		return true
	_rebuild_fog_cache_if_needed()
	var key := Team.soldier_key(enemy.team_id, enemy.soldier_id)
	return bool(_fog_spotted_cache.get(key, false))


## Fog viewer: local player when on the active team; else first hierarchy player on that team.
func _fog_viewer_player_id() -> int:
	if _game_state == null or _game_state.command_hierarchy == null:
		return -1
	var hierarchy = _game_state.command_hierarchy
	var team_id := _session.active_team_id
	var local_id := _game_state.local_player_id
	if hierarchy.has_player(local_id) and hierarchy.get_team_id(local_id) == team_id:
		return local_id
	for pid in hierarchy.all_player_ids():
		if hierarchy.get_team_id(pid) == team_id:
			return pid
	return -1


## Command-chain fog filter for the active viewer; falls back to flat team visibility.
func _is_enemy_spotted_for_viewer(
	viewer_player_id: int,
	active_team: int,
	enemy: SoldierState,
) -> bool:
	if GameModeManager.is_local_multiplayer():
		return AuthoritativeSyncClass.is_enemy_visible_to_team(active_team, enemy)
	if viewer_player_id > 0:
		return CombatSystem.is_enemy_visible_to_player(_game_state, viewer_player_id, enemy)
	return CombatSystem.is_enemy_visible_to_team(_game_state, active_team, enemy)


func _refresh_armed_movement_views(soldier_id: int) -> void:
	var fireteam: Fireteam = _control_fireteam()
	var active_team: int = _session.active_team_id
	if soldier_id == CommandBar.SQUAD_ID:
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if not soldier_state.is_alive():
				continue
			var is_selected := soldier_state.soldier_id == fireteam.selected_soldier_id
			_sync_soldier_view(active_team, soldier_state.soldier_id, is_selected)
		_refresh_command_bar()
	elif soldier_id > 0:
		var is_selected := soldier_id == fireteam.selected_soldier_id
		_sync_soldier_view(active_team, soldier_id, is_selected)
		_refresh_command_bar()


func _refresh_command_bar() -> void:
	var fireteam: Fireteam = _control_fireteam()
	for i in range(fireteam.soldiers.size()):
		var soldier_state: SoldierState = fireteam.soldiers[i]
		var hit_pct := _hit_pct_for_command_row(soldier_state)
		_command_bar.sync_soldier_row(i, soldier_state, hit_pct)
		## Human only interacts with locally owned fireteam soldiers.
		var owned := _session.can_local_control_soldier(
			soldier_state.team_id,
			soldier_state.soldier_id,
		)
		_command_bar.set_soldier_row_interactive(
			i,
			owned and soldier_state.is_alive(),
		)


## Combat-scan path: ammo/stress/status only — skip expensive hit% LOS unless needed.
func _refresh_command_bar_light() -> void:
	var fireteam: Fireteam = _control_fireteam()
	var need_hit := _should_update_hit_columns()
	for i in range(fireteam.soldiers.size()):
		var soldier_state: SoldierState = fireteam.soldiers[i]
		var hit_pct := _hit_pct_for_command_row(soldier_state) if need_hit else -1.0
		_command_bar.sync_soldier_row(i, soldier_state, hit_pct)
		var owned := _session.can_local_control_soldier(
			soldier_state.team_id,
			soldier_state.soldier_id,
		)
		_command_bar.set_soldier_row_interactive(
			i,
			owned and soldier_state.is_alive(),
		)


func _update_command_bar_hit_columns() -> void:
	if not _should_update_hit_columns():
		return
	var fireteam: Fireteam = _control_fireteam()
	var hit_pcts: Array = []
	for state in fireteam.soldiers:
		var soldier_state: SoldierState = state
		hit_pcts.append(_hit_pct_for_command_row(soldier_state))
	_command_bar.update_hit_columns(hit_pcts)


func _should_update_hit_columns() -> bool:
	if _fire_at_mode:
		return true
	for state in _control_fireteam().soldiers:
		var soldier_state: SoldierState = state
		if soldier_state.is_alive() and soldier_state.fire_control_state == FireControlStateClass.FIRE_AT_WILL:
			return true
	return false


func _hit_pct_for_command_row(soldier_state: SoldierState) -> float:
	## Presentation-only read of CombatSystem; does not mutate state.
	if not _should_show_hit_pct(soldier_state):
		return -1.0
	return CombatSystem.hit_pct_vs_faced_enemy(_game_state, soldier_state)


func _should_show_hit_pct(soldier_state: SoldierState) -> bool:
	if soldier_state.is_dead:
		return false
	if soldier_state.fire_control_state == FireControlStateClass.FIRE_AT_WILL:
		return true
	return _is_soldier_in_fire_at_scope(soldier_state)


func _is_soldier_in_fire_at_scope(soldier_state: SoldierState) -> bool:
	if not _fire_at_mode or soldier_state.team_id != _session.active_team_id:
		return false
	if _squad_fire_at_mode:
		return true
	return soldier_state.soldier_id == _fire_at_soldier_id


func _center_camera_on_team_deployment(team_id: int) -> void:
	if _map_data == null:
		return
	var center_cell := _deployment_zone_center_cell(team_id)
	_world.set_center_cell(center_cell)
	_map_background.set_center_cell(center_cell)
	_camera.reset_to_default_view(IsometricGrid.grid_to_world(center_cell))


func _on_center_camera_requested() -> void:
	_center_camera_on_active_fireteam()


## Apply map-authored default camera for a side (e.g. FF USA=90°, GE=270°) and center.
func _apply_team_default_camera(team_id: int) -> void:
	if _map_data == null:
		_center_camera_on_map()
		return
	if _map_data.has_team_camera_degrees(team_id):
		IsometricGrid.set_camera_direction_degrees(_map_data.get_team_camera_degrees(team_id))
		_refresh_view_rotation()
	_center_camera_on_active_fireteam()


func _on_rotate_view_left_requested() -> void:
	_apply_view_rotation_left()


func _on_rotate_view_right_requested() -> void:
	_apply_view_rotation_right()


func _apply_view_rotation_left() -> void:
	_rotate_view_preserving_viewport(true)


func _apply_view_rotation_right() -> void:
	_rotate_view_preserving_viewport(false)


## Rotate projection while keeping the battlefield point under the viewport center.
func _rotate_view_preserving_viewport(rotate_left: bool) -> void:
	var focus_logical := IsometricGrid.world_to_logical_point(_camera.get_viewport_center_world())
	if rotate_left:
		IsometricGrid.rotate_view_left()
	else:
		IsometricGrid.rotate_view_right()
	_refresh_view_rotation()
	_camera.center_on_world(IsometricGrid.logical_point_to_world(focus_logical))


func _refresh_view_rotation() -> void:
	if _map_data == null:
		return
	_camera.set_map_size(_map_data.width, _map_data.height)
	_world.set_center_cell(_get_camera_focus_cell())
	_world.refresh_view_rotation()
	## Sync first (snap settle, latch open aim), then remap in-flight oneshots.
	_refresh_all_views()
	for view in _soldier_views.values():
		var soldier_view: Soldier = view
		soldier_view.refresh_movement_visual()
		soldier_view.refresh_action_visual_for_camera()
	_command_bar.show_status(
		"Camera %d° — Q/E or Rotate. Simulation grid unchanged."
		% IsometricGrid.camera_direction_degrees(),
	)


func _center_camera_on_active_fireteam() -> void:
	var fireteam: Fireteam = _control_fireteam()
	var sum := Vector2i.ZERO
	var count := 0
	for state in fireteam.soldiers:
		var soldier_state: SoldierState = state
		if not soldier_state.is_alive():
			continue
		sum += soldier_state.grid_position
		count += 1
	if count == 0:
		_command_bar.show_status("No living soldiers to center on.")
		return
	var center_cell := Vector2i(floori(float(sum.x) / count), floori(float(sum.y) / count))
	_map_background.set_center_cell(center_cell)
	_camera.reset_to_default_view(IsometricGrid.grid_to_world(center_cell))
	_command_bar.show_status("Camera centered on %s fireteam." % Team.display_name(_session.active_team_id))


func _repair_fireteam_selection(fireteam: Fireteam) -> bool:
	var selected: SoldierState = fireteam.get_selected()
	if (
		selected != null
		and selected.is_alive()
		and _session.can_local_control_soldier(selected.team_id, selected.soldier_id)
	):
		return false
	var previous_id := fireteam.selected_soldier_id
	## Prefer a locally owned living soldier on this side.
	for state in fireteam.soldiers:
		var soldier_state: SoldierState = state
		if not soldier_state.is_alive():
			continue
		if not _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id):
			continue
		fireteam.selected_soldier_id = soldier_state.soldier_id
		return fireteam.selected_soldier_id != previous_id
	fireteam.select_first_alive()
	return fireteam.selected_soldier_id != previous_id


func _ensure_active_selection_alive() -> void:
	var fireteam: Fireteam = _control_fireteam()
	if _repair_fireteam_selection(fireteam):
		_command_bar.sync_selected_soldier(fireteam.selected_soldier_id)


func _get_view(team_id: int, soldier_id: int) -> Soldier:
	return _soldier_views.get(Team.soldier_key(team_id, soldier_id)) as Soldier


func _get_fireteam(team_id: int) -> Fireteam:
	return _session.get_fireteam(team_id)


func _any_active_team_soldier_moving() -> bool:
	for state in _control_fireteam().soldiers:
		var soldier_state: SoldierState = state
		if _is_soldier_moving(soldier_state):
			return true
	return false


func _any_soldier_moving() -> bool:
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if _is_soldier_moving(soldier_state):
				return true
	return false


func _is_soldier_moving(state: SoldierState) -> bool:
	if state == null or state.is_dead:
		return false
	## Authoritative only — presentation lerp must not keep gameplay "moving".
	return state.is_moving


func _build_spotting_cell_overrides() -> Dictionary:
	## Deprecated: spotting uses SoldierState.grid_position only.
	return {}


func _apply_spotting_cell_overrides() -> void:
	CombatSystem.clear_spotting_cell_overrides()


func _clear_spotting_cell_overrides() -> void:
	CombatSystem.clear_spotting_cell_overrides()


func _on_soldier_selected(soldier_id: int) -> void:
	## UI-local selection only (client-side; not an authoritative gameplay command).
	if not _session.can_local_control_soldier(_session.active_team_id, soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return
	_control_fireteam().select_soldier(soldier_id)
	_refresh_all_views()


## Apply ActionResult to views, overlays, and status (presentation only).
func _present_action_result(result: ActionResultClass, combat_tick: bool = false) -> void:
	if result == null:
		return

	## Halts must apply even when success=false (failed fire/move after clear_path).
	var had_movement_halts := not result.movement_halts.is_empty()
	for halt in result.movement_halts:
		var halt_view: Soldier = _get_view(halt.team_id, halt.soldier_id)
		if halt_view != null:
			halt_view.stop_movement()
			var snap: Variant = halt.get("snap_cell", null)
			if snap is Vector2i:
				halt_view.position = IsometricGrid.grid_to_world(snap as Vector2i)

	if not result.success:
		## Down/Halt (and failed orders that cleared a path) must drop red diamonds.
		if had_movement_halts or result.clear_path_overlay:
			_sync_run_to_destination_overlay()
		if not result.status_message.is_empty():
			_command_bar.show_status(result.status_message)
			if result.status_message == ActionResolverClass.FIRETEAM_COHESION_FAIL_MSG:
				_command_bar.append_chat_system(result.status_message)
		return

	for order in result.move_orders:
		var order_view: Soldier = _get_view(order.team_id, order.soldier_id)
		if order_view != null:
			var mover: SoldierState = _game_state.get_soldier(int(order.team_id), int(order.soldier_id))
			if mover != null:
				order_view.sync_locomotion_mode_from_state(mover)
			order_view.follow_path(order.path, order.speed_mult)

	if result.refresh_map_data:
		_apply_map_presentation()

	## Red run-to diamonds: rebuild from every local soldier still moving (never replace
	## one mover's tile with only the latest order). Stance Down / Halt clear paths —
	## refresh so those soldiers' diamonds disappear immediately.
	var refresh_dest_overlay := result.clear_path_overlay or had_movement_halts
	if (
		(result.path_overlay.has("target") or result.path_overlay.has("markers"))
		and _path_overlay_is_for_local_human(result)
	):
		refresh_dest_overlay = true
	elif not result.move_orders.is_empty() and _path_overlay_is_for_local_human(result):
		refresh_dest_overlay = true
	elif not result.move_orders.is_empty():
		## MP move_result has no path_overlay payload — still show red dest tiles.
		refresh_dest_overlay = true
	if refresh_dest_overlay:
		_sync_run_to_destination_overlay()

	if result.clear_move_targeting:
		_command_bar.clear_move_targeting()
		_move_targeting = false
		_squad_move_targeting = false

	var combat_lines: Array[String] = []
	for shot in result.combat_shots:
		var shooter: SoldierState = _game_state.get_soldier(shot.shooter_team_id, shot.shooter_id)
		var target: SoldierState = _game_state.get_soldier(shot.target_team_id, shot.target_id)
		if shot.fired:
			combat_lines.append_array(_finalize_shot_result(shot, shooter, target))
		else:
			for line in shot.messages:
				GameLog.log_combat(line)
				combat_lines.append(line)

	if not result.grenade_explosions.is_empty():
		_spawn_grenade_explosions(result.grenade_explosions)
		_trigger_grenade_death_animations(result.grenade_explosions)

	## Stance clips must start before refresh_views / sync_from_state snaps the pose.
	for order in result.stance_transition_orders:
		var stance_view: Soldier = _get_view(int(order.team_id), int(order.soldier_id))
		var stance_soldier: SoldierState = _game_state.get_soldier(int(order.team_id), int(order.soldier_id))
		if stance_view != null and stance_soldier != null:
			stance_view.play_stance_transition(
				int(order.target_position_state),
				stance_soldier.facing_direction,
			)

	if not result.move_orders.is_empty():
		## Move orders: sync only affected soldiers (chase), not the whole roster.
		_invalidate_fog_cache()
		for order in result.move_orders:
			var tid := int(order.get("team_id", -1))
			var sid := int(order.get("soldier_id", -1))
			var state: SoldierState = _game_state.get_soldier(tid, sid)
			var view: Soldier = _get_view(tid, sid)
			if view != null and state != null:
				view.sync_movement_chase_from_state(state)
		_refresh_enemy_spotting_visuals()
		_refresh_command_bar_light()
	elif result.refresh_views:
		_ensure_active_selection_alive()
		_refresh_all_views()
		_refresh_command_bar()
	elif combat_tick:
		## Spotting + light UI at combat-scan cadence without full sync_from_state
		## or duplicate hit% LOS work (_refresh_command_bar already fills hit%).
		## Skip fog visuals when the viewer's visible-enemy set did not change.
		CombatSystem.ensure_visibility_readable(_game_state)
		var viewer_pid := _fog_viewer_player_id()
		var vis_changed: Array[int] = CombatSystem.players_with_visibility_changes()
		if vis_changed.has(viewer_pid):
			_invalidate_fog_cache()
			_refresh_enemy_spotting_visuals()
		## Stress / hold-fire crouch poses without a full roster sync.
		_refresh_idle_pose_visuals()
		_refresh_command_bar_light()
	else:
		for update in result.face_updates:
			_sync_soldier_view(int(update.get("team_id", -1)), int(update.get("soldier_id", -1)), false)
		for update in result.target_updates:
			_sync_soldier_view(int(update.get("team_id", -1)), int(update.get("soldier_id", -1)), false)

	for order in result.throw_orders:
		var throw_view: Soldier = _get_view(int(order.team_id), int(order.soldier_id))
		var thrower: SoldierState = _game_state.get_soldier(int(order.team_id), int(order.soldier_id))
		if throw_view != null and thrower != null:
			throw_view.play_throw_grenade(thrower.position_state, thrower.facing_direction)

	if result.sync_fire_at_ui:
		_sync_fire_at_ui_from_engagements()

	if result.begin_fire_engagement:
		_begin_fire_at_engagement()

	## Grenade stun/kill lines must reach the on-screen combat log even on a busy tick.
	var status_lines: Array[String] = []
	status_lines.append_array(combat_lines)
	if not result.grenade_explosions.is_empty():
		status_lines.append_array(_collect_grenade_explosion_messages(result.grenade_explosions))
	if not status_lines.is_empty():
		_command_bar.show_status("\n".join(status_lines.slice(-3)))
	elif not result.status_message.is_empty():
		_command_bar.show_status(result.status_message)


func _collect_grenade_explosion_messages(explosions: Array) -> Array[String]:
	var lines: Array[String] = []
	for explosion in explosions:
		for line in explosion.messages:
			GameLog.log_combat(line)
			lines.append(str(line))
	return lines


func _spawn_grenade_explosions(explosions: Array) -> void:
	for explosion in explosions:
		var cell: Vector2i = explosion.explosion_cell
		var world_pos := IsometricGrid.grid_to_world(cell)
		GrenadeExplosion.spawn(_tracers_root, world_pos)
		AudioManager.play_grenade_explosion()


func _trigger_grenade_death_animations(explosions: Array) -> void:
	var any_killed := false
	for explosion in explosions:
		var blast_cell: Vector2i = explosion.explosion_cell
		for entry in explosion.killed:
			var team_id := int(entry.get("team_id", -1))
			var soldier_id := int(entry.get("soldier_id", -1))
			var victim: SoldierState = _game_state.get_soldier(team_id, soldier_id)
			if victim == null:
				continue
			any_killed = true
			# Vector from victim toward blast; fall plays away from the explosion.
			var threat_step := blast_cell - victim.grid_position
			AudioManager.play_death(team_id)
			var view: Soldier = _get_view(team_id, soldier_id)
			if view != null:
				view.play_death_sequence(threat_step, victim.stance_at_death, victim.death_sprite_family)
	## mark_killed clears paths; drop red run-to diamonds for dead movers.
	if any_killed:
		_sync_run_to_destination_overlay()


func _snap_cell_for_soldier(state: SoldierState) -> Vector2i:
	## Authoritative grid only — presentation interpolation is never queried for gameplay.
	return state.grid_position


func _make_move_context(cmd: MoveCommand) -> CommandContextClass:
	var ctx := CommandContextClass.new()
	## Keep pathfinding grid synced to the authoritative map (shared reference).
	if _iso_map != null and _game_state != null and _game_state.map_data != null:
		if _iso_map.map_data != _game_state.map_data:
			_iso_map.apply_map_data(_game_state.map_data)
	ctx.find_path = _iso_map.find_path
	if _session != null:
		ctx.acting_player_id = _session.local_player_id
	return ctx


func _add_snap_cell_if_animating(_ctx: CommandContextClass, _state: SoldierState) -> void:
	## No-op: mid-move gameplay uses SoldierState.grid_position.
	pass


func _make_fire_context(shooters: Array[SoldierState]) -> CommandContextClass:
	var ctx := CommandContextClass.new()
	for shooter in shooters:
		ctx.shooter_ids.append(shooter.soldier_id)
	if _session != null:
		ctx.acting_player_id = _session.local_player_id
	return ctx


func _make_grenade_context(soldier_state: SoldierState) -> CommandContextClass:
	var ctx := CommandContextClass.new()
	ctx.shooter_ids.append(soldier_state.soldier_id)
	if _session != null:
		ctx.acting_player_id = _session.local_player_id
	return ctx


## Local human's owned fireteam (4 soldiers). Not the side aggregate in 2v2.
func _control_fireteam() -> Fireteam:
	if _session == null:
		return null
	if GameModeManager.is_local_multiplayer() and PlayerSides.has_assignment():
		return _session.get_fireteam(PlayerSides.assigned_team_id)
	return _session.get_local_control_fireteam()


## True when path overlay / move orders belong to the local human's owned soldiers.
func _path_overlay_is_for_local_human(result: ActionResultClass) -> bool:
	if _session == null or result == null:
		return false
	var markers: Array = result.path_overlay.get("markers", [])
	var team_id := int(result.path_overlay.get("team_id", _session.active_team_id))
	for entry in markers:
		if entry is Dictionary:
			var sid := int(entry.get("soldier_id", -1))
			if sid > 0 and _session.can_local_control_soldier(team_id, sid):
				return true
	## Fall back to move_orders when overlay payload omitted markers.
	for order in result.move_orders:
		if order is Dictionary:
			var sid := int(order.get("soldier_id", -1))
			var oid := int(order.get("team_id", team_id))
			if sid > 0 and _session.can_local_control_soldier(oid, sid):
				return true
	if markers.is_empty() and result.move_orders.is_empty():
		## Single-target overlay without markers — only accept local active team moves.
		return (
			result.path_overlay.has("target")
			and PlayerSides.can_control_team(team_id)
		)
	return false


## Flash red destination tiles for every locally owned soldier still moving.
func _sync_run_to_destination_overlay() -> void:
	if _iso_map == null or _session == null:
		return
	var markers: Array = []
	for fireteam in _session.all_fireteams():
		for state_v in fireteam.soldiers:
			var state: SoldierState = state_v
			if state == null or state.is_dead:
				continue
			if not _session.can_local_control_soldier(state.team_id, state.soldier_id):
				if not (
					GameModeManager.is_local_multiplayer()
					and PlayerSides.can_control_team(state.team_id)
				):
					continue
			var dest := Vector2i(-999, -999)
			var view: Soldier = _get_view(state.team_id, state.soldier_id)
			if view != null:
				## Hide the diamond when the sprite has arrived, even if sim is still catching up.
				dest = view.presentation_destination_cell()
			elif state.is_moving and not state.current_path.is_empty():
				dest = state.current_path[state.current_path.size() - 1]
			if dest.x <= -900:
				continue
			markers.append({
				"cell": dest,
				"soldier_id": state.soldier_id,
			})
	if markers.is_empty():
		_iso_map.clear_path()
		return
	_iso_map.show_path([] as Array[Vector2i], Vector2i(-999, -999), markers)


func _apply_grenade_command(target_cell: Vector2i) -> void:
	if _grenade_soldier_id == CommandBar.SQUAD_ID:
		_apply_squad_grenade_command(target_cell)
		return

	if not _session.can_local_control_soldier(_session.active_team_id, _grenade_soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return

	var soldier_state: SoldierState = _game_state.get_soldier(
		_session.active_team_id,
		_grenade_soldier_id,
	)
	if soldier_state == null or soldier_state.is_dead:
		_command_bar.show_status("Soldier unavailable.")
		return

	var cmd := GrenadeCommand.new()
	cmd.team_id = _session.active_team_id
	cmd.soldier_id = _grenade_soldier_id
	cmd.target_cell = target_cell

	var result: ActionResultClass = CommandRouter.submit_command(
		_game_state,
		cmd,
		_make_grenade_context(soldier_state),
	)
	_present_action_result(result)


func _apply_squad_grenade_command(target_cell: Vector2i) -> void:
	var thrown := 0
	var last_result: ActionResultClass = null
	var fireteam: Fireteam = _control_fireteam()
	for state in fireteam.soldiers:
		var soldier_state: SoldierState = state
		if (
			soldier_state == null
			or soldier_state.is_dead
			or soldier_state.grenade_count <= 0
			or soldier_state.is_stunned()
			or soldier_state.has_pending_grenade()
		):
			continue
		if not _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id):
			continue
		## Movers may halt-and-throw when the target is in range (resolver enforces).
		var cmd := GrenadeCommand.new()
		cmd.team_id = _session.active_team_id
		cmd.soldier_id = soldier_state.soldier_id
		cmd.target_cell = target_cell
		var result: ActionResultClass = CommandRouter.submit_command(
			_game_state,
			cmd,
			_make_grenade_context(soldier_state),
		)
		last_result = result
		if result.success:
			thrown += 1
			## Play each thrower anim even when only the last ActionResult is presented.
			for order in result.throw_orders:
				var throw_view: Soldier = _get_view(int(order.team_id), int(order.soldier_id))
				if throw_view != null:
					throw_view.play_throw_grenade(
						soldier_state.position_state,
						soldier_state.facing_direction,
					)
	if thrown > 0:
		if last_result != null:
			## Avoid replaying throw anims already started above.
			last_result.throw_orders.clear()
			_present_action_result(last_result)
		_command_bar.show_status("Fireteam grenade — %d thrown." % thrown)
	elif last_result != null:
		_present_action_result(last_result)
	else:
		_command_bar.show_status("No soldiers available to throw grenades.")


func _grenade_preview_shooter() -> SoldierState:
	if _grenade_soldier_id == CommandBar.SQUAD_ID:
		var fireteam: Fireteam = _control_fireteam()
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if (
				soldier_state != null
				and soldier_state.is_alive()
				and soldier_state.grenade_count > 0
				and not soldier_state.is_stunned()
				and not soldier_state.has_pending_grenade()
			):
				return soldier_state
		return null
	var shooter: SoldierState = _game_state.get_soldier(
		_session.active_team_id,
		_grenade_soldier_id,
	)
	if shooter == null or shooter.is_dead:
		return null
	return shooter


func _apply_move_command(cmd: MoveCommand) -> void:
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		var net_result: ActionResultClass = await NetworkClient.submit_move_and_wait(cmd)
		_on_network_move_result(net_result, "")
		return
	var result: ActionResultClass = CommandRouter.submit_command(
		_game_state,
		cmd,
		_make_move_context(cmd),
	)
	if (
		result.success
		and cmd.scope == MoveCommand.Scope.SINGLE
		and not result.move_orders.is_empty()
	):
		var order: Dictionary = result.move_orders[0]
		var soldier_state: SoldierState = _game_state.get_soldier(order.team_id, order.soldier_id)
		_log_move_order(cmd.target_cell, order.path, soldier_state)
	_present_action_result(result)


func _on_network_move_result(result: ActionResultClass, _request_id: String) -> void:
	AuthoritativeSyncClass.apply_move_result(_game_state, result)
	_present_action_result(result)


func _on_network_face_result(result: ActionResultClass, _request_id: String) -> void:
	_apply_network_face_result(result)


func _on_network_position_result(result: ActionResultClass, _request_id: String) -> void:
	_apply_network_position_result(result)


func _on_network_fire_control_result(result: ActionResultClass, _request_id: String) -> void:
	_apply_network_target_result(result)


func _on_network_fire_at_result(result: ActionResultClass, _request_id: String) -> void:
	_apply_network_target_result(result)


func _apply_network_target_result(result: ActionResultClass) -> void:
	if result == null:
		return
	AuthoritativeSyncClass.apply_target_result(_game_state, result)
	if result.success:
		for update in result.face_updates:
			_sync_soldier_view(int(update.get("team_id", -1)), int(update.get("soldier_id", -1)), false)
		for update in result.target_updates:
			_sync_soldier_view(int(update.get("team_id", -1)), int(update.get("soldier_id", -1)), false)
		_refresh_command_bar()
	_present_action_result(result)


func _ensure_multiplayer_result_signals() -> void:
	if not GameModeManager.is_local_multiplayer():
		return
	if not NetworkClient.move_result_received.is_connected(_on_network_move_result):
		NetworkClient.move_result_received.connect(_on_network_move_result)
	if not NetworkClient.face_result_received.is_connected(_on_network_face_result):
		NetworkClient.face_result_received.connect(_on_network_face_result)
	if not NetworkClient.position_result_received.is_connected(_on_network_position_result):
		NetworkClient.position_result_received.connect(_on_network_position_result)
	if not NetworkClient.movement_tick_received.is_connected(_on_network_movement_tick):
		NetworkClient.movement_tick_received.connect(_on_network_movement_tick)
	if not NetworkClient.fire_control_result_received.is_connected(_on_network_fire_control_result):
		NetworkClient.fire_control_result_received.connect(_on_network_fire_control_result)
	if not NetworkClient.fire_at_result_received.is_connected(_on_network_fire_at_result):
		NetworkClient.fire_at_result_received.connect(_on_network_fire_at_result)
	if not NetworkClient.visibility_update_received.is_connected(_on_network_visibility_update):
		NetworkClient.visibility_update_received.connect(_on_network_visibility_update)
	if not NetworkClient.target_sync_received.is_connected(_on_network_target_sync):
		NetworkClient.target_sync_received.connect(_on_network_target_sync)
	if not NetworkClient.combat_shots_received.is_connected(_on_network_combat_shots):
		NetworkClient.combat_shots_received.connect(_on_network_combat_shots)
	if not NetworkClient.combat_status_received.is_connected(_on_network_combat_status):
		NetworkClient.combat_status_received.connect(_on_network_combat_status)


func _apply_network_face_result(result: ActionResultClass) -> void:
	if result == null:
		return
	AuthoritativeSyncClass.apply_face_result(_game_state, result)
	if result.success:
		for update in result.face_updates:
			var tid := int(update.get("team_id", -1))
			var sid := int(update.get("soldier_id", -1))
			_sync_soldier_view(tid, sid, false)
		_sync_face_soldier_views()
	_present_action_result(result)


func _apply_network_position_result(result: ActionResultClass) -> void:
	if result == null:
		return
	AuthoritativeSyncClass.apply_position_result(_game_state, result)
	if result.success:
		_maybe_clear_move_targeting_after_prone(result)
	_present_action_result(result)


func _maybe_clear_move_targeting_after_prone(result: ActionResultClass) -> void:
	if not _move_targeting:
		return
	if MovementModeClass.is_allowed(PositionStateClass.DOWN, _active_movement_mode):
		return
	for update in result.soldier_updates:
		if int(update.get("position_state", PositionStateClass.UP)) != PositionStateClass.DOWN:
			continue
		var sid := int(update.get("soldier_id", -1))
		if _squad_move_targeting or _move_soldier_id == sid:
			_command_bar.clear_move_targeting()
			_move_targeting = false
			_squad_move_targeting = false
			return
	for order in result.stance_transition_orders:
		if int(order.get("target_position_state", -1)) != PositionStateClass.DOWN:
			continue
		var sid := int(order.get("soldier_id", -1))
		if _squad_move_targeting or _move_soldier_id == sid:
			_command_bar.clear_move_targeting()
			_move_targeting = false
			_squad_move_targeting = false
			return


func _on_network_movement_tick(payload: Dictionary) -> void:
	AuthoritativeSyncClass.apply_sim_time(payload)
	var tick_result: ActionResultClass = AuthoritativeSyncClass.apply_movement_tick(
		_game_state,
		payload,
	)
	_present_movement_tick_result(tick_result)


func _on_network_visibility_update(payload: Dictionary) -> void:
	AuthoritativeSyncClass.apply_visibility(payload)
	_invalidate_fog_cache()
	_refresh_enemy_spotting_visuals()


func _on_network_combat_shots(payload: Dictionary) -> void:
	var result: ActionResultClass = AuthoritativeSyncClass.apply_combat_shots(_game_state, payload)
	_present_action_result(result)
	_invalidate_fog_cache()
	_refresh_enemy_spotting_visuals()
	_refresh_command_bar()


func _on_network_combat_status(payload: Dictionary) -> void:
	AuthoritativeSyncClass.apply_combat_status(_game_state, payload)
	for raw in payload.get("updates", []):
		if not raw is Dictionary:
			continue
		var update: Dictionary = raw
		_sync_soldier_view(
			int(update.get("teamId", update.get("team_id", -1))),
			int(update.get("soldierId", update.get("soldier_id", -1))),
			false,
		)
	_refresh_command_bar()


func _on_network_target_sync(payload: Dictionary) -> void:
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(
		{
			"success": true,
			"targetUpdates": payload.get("targetUpdates", payload.get("target_updates", [])),
		}
	)
	AuthoritativeSyncClass.apply_target_result(_game_state, result)
	for update in result.target_updates:
		_sync_soldier_view(int(update.get("team_id", -1)), int(update.get("soldier_id", -1)), false)
	_refresh_command_bar()


func _apply_face_command(cmd: FaceCommand) -> void:
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		var net_result: ActionResultClass = await NetworkClient.submit_face_and_wait(cmd)
		_apply_network_face_result(net_result)
		return
	var result: ActionResultClass = CommandRouter.submit_command(_game_state, cmd)
	if result.success:
		_sync_face_soldier_views()
	_present_action_result(result)


func _apply_face_at_tile(target_cell: Vector2i, aim_world: Vector2) -> void:
	var soldiers: Array[SoldierState] = _get_face_scope_soldiers()
	if soldiers.is_empty():
		_command_bar.show_status("No soldiers available to face.")
		return

	var lead: SoldierState = soldiers[0]
	var click_cell := IsometricGrid.world_to_grid(aim_world)
	var preview := CombatSystem.evaluate_fire_at_preview(
		_game_state,
		lead,
		_get_soldier_tracer_point(lead),
		aim_world,
		click_cell,
		-1,
		-1,
	)
	var face_cell := preview.click_cell if preview.click_cell.x > -900 else target_cell

	var face_cmd := FaceCommand.new()
	face_cmd.team_id = _session.active_team_id
	face_cmd.target_cell = face_cell
	face_cmd.aim_world = aim_world
	if _face_soldier_id == CommandBar.SQUAD_ID:
		face_cmd.scope = FaceCommand.Scope.SQUAD
	else:
		face_cmd.scope = FaceCommand.Scope.SINGLE
		face_cmd.soldier_id = _face_soldier_id

	_face_revert_keys.clear()
	for soldier_state in soldiers:
		if soldier_state.is_engaged():
			_face_revert_keys.append(
				Team.soldier_key(soldier_state.team_id, soldier_state.soldier_id)
			)

	var result: ActionResultClass
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		result = await NetworkClient.submit_face_and_wait(face_cmd)
		_apply_network_face_result(result)
	else:
		result = CommandRouter.submit_command(_game_state, face_cmd)
		if result.success:
			_sync_face_soldier_views()
		_present_action_result(result)
	if result != null and result.success:
		_mark_face_committed(soldiers)
		_face_manual_aim_cell = face_cell
		_face_manual_aim_world = aim_world
		if not _face_revert_keys.is_empty():
			_face_manual_override_until_msec = Time.get_ticks_msec() + _FACE_REVERT_DELAY_MSEC
		else:
			_clear_face_manual_override()
			_face_manual_aim_cell = face_cell
			_face_manual_aim_world = aim_world
		if GameModeManager.is_local_multiplayer():
			_sync_face_soldier_views()


func _apply_face_enemy_fire(aim_world: Vector2, clicked_soldier: SoldierState) -> void:
	var soldiers: Array[SoldierState] = _get_face_scope_soldiers()
	if soldiers.is_empty():
		_command_bar.show_status("No available soldiers to face.")
		return

	_clear_face_manual_override()

	var face_cmd := FaceCommand.new()
	face_cmd.team_id = _session.active_team_id
	face_cmd.target_cell = clicked_soldier.grid_position
	face_cmd.aim_world = aim_world
	if _face_soldier_id == CommandBar.SQUAD_ID:
		face_cmd.scope = FaceCommand.Scope.SQUAD
	else:
		face_cmd.scope = FaceCommand.Scope.SINGLE
		face_cmd.soldier_id = _face_soldier_id

	var face_result: ActionResultClass
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		face_result = await NetworkClient.submit_face_and_wait(face_cmd)
		_apply_network_face_result(face_result)
	else:
		face_result = CommandRouter.submit_command(_game_state, face_cmd)
	if face_result.success:
		_mark_face_committed(soldiers)
		_face_manual_aim_cell = clicked_soldier.grid_position
		_face_manual_aim_world = aim_world
		_sync_face_soldier_views()

	var fire_shooters: Array[SoldierState] = []
	for soldier_state in soldiers:
		var from_world := _get_soldier_tracer_point(soldier_state)
		var preview := CombatSystem.evaluate_fire_at_preview(
			_game_state,
			soldier_state,
			from_world,
			aim_world,
			clicked_soldier.grid_position,
			clicked_soldier.team_id,
			clicked_soldier.soldier_id,
		)
		if preview.targetable:
			fire_shooters.append(soldier_state)

	if fire_shooters.is_empty():
		if not face_result.status_message.is_empty():
			_command_bar.show_status(face_result.status_message)
		else:
			_command_bar.show_status("Facing enemy — no line of sight to fire.")
		if face_result.success and not GameModeManager.is_local_multiplayer():
			_present_action_result(face_result)
		return

	var cmd := FireCommand.new()
	cmd.team_id = _session.active_team_id
	cmd.aim_world = aim_world
	cmd.target_team_id = clicked_soldier.team_id
	cmd.target_soldier_id = clicked_soldier.soldier_id
	if _face_soldier_id == CommandBar.SQUAD_ID:
		cmd.scope = FireCommand.Scope.SQUAD
	else:
		cmd.scope = FireCommand.Scope.SINGLE
		cmd.soldier_id = _face_soldier_id

	var fire_result: ActionResultClass
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		fire_result = await NetworkClient.submit_fire_at_and_wait(cmd)
		_apply_network_target_result(fire_result)
	else:
		fire_result = CommandRouter.submit_command(
			_game_state,
			cmd,
			_make_fire_context(fire_shooters),
		)
		if fire_result.success:
			_sync_face_soldier_views()
		_present_action_result(fire_result)
	if fire_result != null and not fire_result.status_message.is_empty():
		_command_bar.show_status(fire_result.status_message)


func _apply_position_command(cmd: PositionCommand) -> void:
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		var net_result: ActionResultClass = await NetworkClient.submit_position_and_wait(cmd)
		_apply_network_position_result(net_result)
		return
	var result: ActionResultClass = CommandRouter.submit_command(_game_state, cmd)
	if (
		result.success
		and cmd.position_state == PositionStateClass.DOWN
		and _move_targeting
		and not MovementModeClass.is_allowed(PositionStateClass.DOWN, _active_movement_mode)
	):
		if _squad_move_targeting or _move_soldier_id == cmd.soldier_id:
			_command_bar.clear_move_targeting()
			_move_targeting = false
			_squad_move_targeting = false
	_present_action_result(result)


func _on_fire_control_change_requested(soldier_id: int, fire_control_state: int) -> void:
	if GameModeManager.is_local_multiplayer():
		_submit_mp_fire_control(soldier_id, fire_control_state)
		return
	if soldier_id == CommandBar.SQUAD_ID:
		var last_result: ActionResultClass = null
		var fireteam: Fireteam = _control_fireteam()
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state == null or soldier_state.is_dead:
				continue
			if not _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id):
				continue
			var cmd := FireControlCommandClass.new()
			cmd.team_id = _session.active_team_id
			cmd.soldier_id = soldier_state.soldier_id
			cmd.fire_control_state = fire_control_state
			last_result = CommandRouter.submit_command(_game_state, cmd)
		if last_result != null:
			_present_action_result(last_result)
		else:
			_command_bar.show_status("No soldiers available.")
		return

	if not _session.can_local_control_soldier(_session.active_team_id, soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return
	var cmd := FireControlCommandClass.new()
	cmd.team_id = _session.active_team_id
	cmd.soldier_id = soldier_id
	cmd.fire_control_state = fire_control_state
	_apply_fire_control_command(cmd)


func _submit_mp_fire_control(soldier_id: int, fire_control_state: int) -> void:
	var issued := 0
	if soldier_id == CommandBar.SQUAD_ID:
		var fireteam_mp: Fireteam = _control_fireteam()
		if fireteam_mp == null:
			_command_bar.show_status("No soldiers available.")
			return
		for state in fireteam_mp.soldiers:
			var soldier_mp: SoldierState = state
			if soldier_mp == null or soldier_mp.is_dead:
				continue
			if not _session.can_local_control_soldier(soldier_mp.team_id, soldier_mp.soldier_id):
				continue
			var cmd_mp := FireControlCommandClass.new()
			cmd_mp.team_id = _session.active_team_id
			cmd_mp.soldier_id = soldier_mp.soldier_id
			cmd_mp.fire_control_state = fire_control_state
			issued += 1
			await _apply_fire_control_command(cmd_mp)
		if issued == 0:
			_command_bar.show_status("No soldiers available.")
		return
	if not _session.can_local_control_soldier(_session.active_team_id, soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return
	var cmd := FireControlCommandClass.new()
	cmd.team_id = _session.active_team_id
	cmd.soldier_id = soldier_id
	cmd.fire_control_state = fire_control_state
	await _apply_fire_control_command(cmd)


func _apply_fire_control_command(cmd: FireControlCommandClass) -> void:
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		var net_result: ActionResultClass = await NetworkClient.submit_fire_control_and_wait(cmd)
		_apply_network_target_result(net_result)
		return
	var result: ActionResultClass = CommandRouter.submit_command(_game_state, cmd)
	_present_action_result(result)


func _on_position_change_requested(soldier_id: int, position_state: int) -> void:
	if GameModeManager.is_local_multiplayer():
		_submit_mp_position_change(soldier_id, position_state)
		return
	if soldier_id == CommandBar.SQUAD_ID:
		var last_result: ActionResultClass = null
		var combined_transitions: Array[Dictionary] = []
		var combined_halts: Array[Dictionary] = []
		var any_success := false
		var fireteam: Fireteam = _control_fireteam()
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state == null or soldier_state.is_dead or soldier_state.is_stunned():
				continue
			if not _session.can_local_control_soldier(soldier_state.team_id, soldier_state.soldier_id):
				continue
			var cmd := PositionCommand.new()
			cmd.team_id = _session.active_team_id
			cmd.soldier_id = soldier_state.soldier_id
			cmd.position_state = position_state
			last_result = CommandRouter.submit_command(_game_state, cmd)
			if last_result != null and last_result.success:
				any_success = true
				for order in last_result.stance_transition_orders:
					combined_transitions.append(order)
				for halt in last_result.movement_halts:
					combined_halts.append(halt)
		if (
			any_success
			and position_state == PositionStateClass.DOWN
			and _move_targeting
			and not MovementModeClass.is_allowed(PositionStateClass.DOWN, _active_movement_mode)
		):
			_command_bar.clear_move_targeting()
			_move_targeting = false
			_squad_move_targeting = false
		## Gameplay stance already committed; present all halts + drop/stand anims.
		if last_result != null and any_success:
			last_result.success = true
			last_result.refresh_views = true
			last_result.stance_transition_orders = combined_transitions
			last_result.movement_halts = combined_halts
			_present_action_result(last_result)
		else:
			_command_bar.show_status("No soldiers available.")
		return

	if not _session.can_local_control_soldier(_session.active_team_id, soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return
	var cmd := PositionCommand.new()
	cmd.team_id = _session.active_team_id
	cmd.soldier_id = soldier_id
	cmd.position_state = position_state
	_apply_position_command(cmd)


func _submit_mp_position_change(soldier_id: int, position_state: int) -> void:
	var issued := 0
	if soldier_id == CommandBar.SQUAD_ID:
		var fireteam_mp: Fireteam = _control_fireteam()
		if fireteam_mp == null:
			_command_bar.show_status("No soldiers available.")
			return
		for state in fireteam_mp.soldiers:
			var soldier_mp: SoldierState = state
			if soldier_mp == null or soldier_mp.is_dead or soldier_mp.is_stunned():
				continue
			if not _session.can_local_control_soldier(soldier_mp.team_id, soldier_mp.soldier_id):
				continue
			var cmd_mp := PositionCommand.new()
			cmd_mp.team_id = _session.active_team_id
			cmd_mp.soldier_id = soldier_mp.soldier_id
			cmd_mp.position_state = position_state
			issued += 1
			await _apply_position_command(cmd_mp)
		if issued == 0:
			_command_bar.show_status("No soldiers available.")
		return
	if not _session.can_local_control_soldier(_session.active_team_id, soldier_id):
		_command_bar.show_status("That soldier is not under your control.")
		return
	var cmd := PositionCommand.new()
	cmd.team_id = _session.active_team_id
	cmd.soldier_id = soldier_id
	cmd.position_state = position_state
	await _apply_position_command(cmd)


func _arm_movement_mode(soldier_id: int, movement_mode: int) -> String:
	if GameModeManager.is_local_multiplayer():
		## Targeting UI only — authoritative movementMode commits on accepted MoveCommand.
		return "Soldier movement mode = %s" % MovementModeClass.display_name(movement_mode)
	var result: ActionResultClass = CommandRouter.arm_movement_mode(
		_game_state,
		_session.active_team_id,
		soldier_id,
		movement_mode,
	)
	return result.status_message if result.success else ""


func _apply_fire_at_aim(
	aim_world: Vector2,
	clicked_soldier: SoldierState = null,
	click_cell: Vector2i = Vector2i(-999, -999),
) -> void:
	if _fire_at_submit_busy:
		return
	var shooters: Array[SoldierState] = _get_manual_fire_at_shooters()
	if shooters.is_empty():
		_command_bar.show_status("No available soldiers to fire.")
		return
	_fire_at_submit_busy = true

	var enemy := _resolve_fire_at_click_enemy(clicked_soldier, click_cell, aim_world)
	var cmd := FireCommand.new()
	cmd.team_id = _session.active_team_id
	cmd.aim_world = aim_world
	cmd.target_cell = click_cell
	if enemy != null:
		cmd.target_team_id = enemy.team_id
		cmd.target_soldier_id = enemy.soldier_id
	if _squad_fire_at_mode:
		cmd.scope = FireCommand.Scope.SQUAD
	else:
		cmd.scope = FireCommand.Scope.SINGLE
		cmd.soldier_id = _fire_at_soldier_id

	var result: ActionResultClass
	if GameModeManager.is_local_multiplayer():
		_ensure_multiplayer_result_signals()
		result = await NetworkClient.submit_fire_at_and_wait(cmd)
		_apply_network_target_result(result)
	else:
		result = CommandRouter.submit_command(
			_game_state,
			cmd,
			_make_fire_context(shooters),
		)
		_present_action_result(result)
	_fire_at_submit_busy = false
	## Stay in Fire At until another command — further tile clicks retarget / re-face.
	if result != null and result.success:
		_keep_fire_at_targeting()
		if not result.status_message.is_empty():
			_command_bar.show_status(result.status_message)


func _keep_fire_at_targeting() -> void:
	_command_bar.affirm_fire_at_pressed(_squad_fire_at_mode, _fire_at_soldier_id)
	_sync_fire_at_ui_from_engagements()


func _finalize_shot_result(
	result: CombatShotResult,
	shooter: SoldierState,
	target: SoldierState,
) -> Array[String]:
	if result.fired:
		GameplayPolicies.fire_anim.note_authoritative_shot()
		if shooter != null:
			var shooter_view: Soldier = _get_view(shooter.team_id, shooter.soldier_id)
			if shooter_view != null:
				var fire_aim := (
					target.grid_position
					if target != null
					else Vector2i(-999, -999)
				)
				var fire_corner := CoverSystem.presentation_corner_result(
					shooter.grid_position,
					shooter.facing_direction,
					result.corner_peek,
					result.peek_side,
					result.corner_cell,
					fire_aim,
					_map_data,
				)
				shooter_view.play_fire(
					shooter.position_state,
					shooter.facing_direction,
					fire_corner.peek_side,
					fire_aim,
					fire_corner.corner_cell,
				)
		if target != null:
			_spawn_shot_tracers(shooter, target, maxi(result.tracer_count, 1))
			result.messages.append("Tracer created")

	if result.killed and target != null:
		var threat_step := shooter.grid_position - target.grid_position
		var target_view: Soldier = _get_view(target.team_id, target.soldier_id)
		if target_view != null:
			## Use stance_at_death — mark_killed already forced position_state DOWN.
			target_view.play_death_sequence(threat_step, target.stance_at_death, target.death_sprite_family)
		## mark_killed clears the path; drop that soldier's red run-to diamond.
		_sync_run_to_destination_overlay()
	elif result.hit and target != null and not result.killed:
		var threat_step := shooter.grid_position - target.grid_position
		var target_view: Soldier = _get_view(target.team_id, target.soldier_id)
		if target_view != null:
			target_view.play_hit_reaction(threat_step, target.position_state)

	var lines: Array[String] = []
	for line in result.messages:
		GameLog.log_combat(line)
		lines.append(line)
	return lines


func _spawn_shot_tracers(shooter: SoldierState, target: SoldierState, count: int) -> void:
	## Visual/audio only: stagger rounds within a burst (~0.04s). Hit resolution is one roll.
	var from_world := _get_soldier_tracer_point(shooter)
	var to_world := _get_soldier_tracer_point(target)
	var interval := GameplayPolicies.hit.burst_round_interval_sec
	for i in range(count):
		var jitter := Vector2(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0))
		var from_pt := from_world + jitter
		var to_pt := to_world + jitter
		if i == 0 or interval <= 0.0:
			ShotTracer.spawn(_tracers_root, from_pt, to_pt)
		else:
			var delay := interval * float(i)
			var tree := get_tree()
			if tree != null:
				tree.create_timer(delay).timeout.connect(
					func() -> void: ShotTracer.spawn(_tracers_root, from_pt, to_pt)
				)
			else:
				ShotTracer.spawn(_tracers_root, from_pt, to_pt)


func _get_soldier_tracer_point(soldier_state: SoldierState) -> Vector2:
	## Presentation-only: prefers animated view position for tracers and LOS preview.
	var view: Soldier = _get_view(soldier_state.team_id, soldier_state.soldier_id)
	if view != null:
		return view.position + TileSizeConfig.tracer_aim_offset()
	return IsometricGrid.soldier_aim_point(soldier_state.grid_position)


func _on_soldier_step_reached(_team_id: int, _soldier_id: int, _tile: Vector2i, _step_delta: Vector2i) -> void:
	## Legacy presentation signal — authoritative steps come from process_movement_tick.
	pass


func _on_soldier_movement_finished(_team_id: int, _soldier_id: int) -> void:
	## Presentation reached the dest (MP sim may have finished earlier). Drop that diamond.
	_sync_run_to_destination_overlay()


func _on_soldier_stance_transition_finished(
	team_id: int,
	soldier_id: int,
	target_position_state: int,
) -> void:
	var result: ActionResultClass = ActionResolverClass.commit_stance_transition(
		_game_state,
		team_id,
		soldier_id,
		target_position_state,
	)
	_present_action_result(result)


func _on_soldier_stance_transition_cancelled(team_id: int, soldier_id: int) -> void:
	var soldier: SoldierState = _game_state.get_soldier(team_id, soldier_id)
	if soldier != null:
		soldier.clear_pending_position()


func _on_soldier_exposed_engagement_prone_requested(team_id: int, soldier_id: int) -> void:
	var soldier_state: SoldierState = _game_state.get_soldier(team_id, soldier_id)
	if soldier_state == null or soldier_state.is_dead:
		return
	if soldier_state.position_state == PositionStateClass.DOWN:
		return
	if soldier_state.pending_position_state >= 0:
		return
	var cmd := PositionCommand.new()
	cmd.team_id = team_id
	cmd.soldier_id = soldier_id
	cmd.position_state = PositionStateClass.DOWN
	_apply_position_command(cmd)


func _log_move_order(clicked_tile: Vector2i, path: Array[Vector2i], state: SoldierState) -> void:
	var path_final := path[path.size() - 1] if not path.is_empty() else Vector2i(-1, -1)
	call_deferred(
		"_emit_move_order_log",
		clicked_tile,
		path_final,
		state.grid_position,
		_soldier_world_pos(state),
	)


func _emit_move_order_log(
	clicked_tile: Vector2i,
	path_final: Vector2i,
	soldier_grid: Vector2i,
	soldier_world: Vector2,
) -> void:
	GameLog.log_system(
		"Move order: clicked=%s path_final=%s soldier_grid=%s soldier_world=%s"
		% [clicked_tile, path_final, soldier_grid, soldier_world],
	)


func _log_move_complete(soldier_id: int, state: SoldierState, view: Soldier) -> void:
	if state == null:
		return
	var world_pos := view.position if view != null else _soldier_world_pos(state)
	call_deferred(
		"_emit_move_complete_log",
		state.team_id,
		soldier_id,
		state.grid_position,
		world_pos,
	)


func _emit_move_complete_log(
	team_id: int,
	soldier_id: int,
	grid_pos: Vector2i,
	world_pos: Vector2,
) -> void:
	GameLog.log_system(
		"Move complete: team=%s soldier=%d grid=%s world=%s cell_at_world=%s"
		% [
			Team.display_name(team_id),
			soldier_id,
			grid_pos,
			world_pos,
			IsometricGrid.world_to_cell_at_point(world_pos),
		],
	)


func _soldier_world_pos(state: SoldierState) -> Vector2:
	var view: Soldier = _get_view(state.team_id, state.soldier_id)
	if view != null:
		return view.position
	return IsometricGrid.grid_to_world(state.grid_position)


func _on_move_targeting_changed(is_active: bool, soldier_id: int, movement_mode: int) -> void:
	_move_targeting = is_active
	_squad_move_targeting = is_active and soldier_id == CommandBar.SQUAD_ID
	_active_movement_mode = movement_mode
	_move_soldier_id = soldier_id if soldier_id > 0 else _control_fireteam().selected_soldier_id
	if is_active:
		_fire_at_mode = false
		_squad_fire_at_mode = false
		_fire_at_engaged = false
		_face_mode = false
		_grenade_mode = false
		if soldier_id > 0:
			_control_fireteam().select_soldier(soldier_id)
		var arm_message := _arm_movement_mode(soldier_id, movement_mode)
		_refresh_selection_marks()
		_refresh_armed_movement_views(soldier_id)
		if not arm_message.is_empty():
			_command_bar.show_status(arm_message)


func _begin_fire_at_engagement() -> void:
	## Arm an immediate combat scan on the next simulation tick (preserve prior kick behavior).
	_combat_scan_accum_msec = _combat_scan_interval_msec()
	_sync_fire_at_ui_from_engagements()


func _on_fire_at_mode_changed(is_active: bool, soldier_id: int) -> void:
	_fire_at_mode = is_active
	_squad_fire_at_mode = is_active and soldier_id == CommandBar.SQUAD_ID
	_fire_at_soldier_id = soldier_id if is_active else 1
	if is_active:
		_move_targeting = false
		_squad_move_targeting = false
		_face_mode = false
		_grenade_mode = false
		if soldier_id > 0:
			_control_fireteam().select_soldier(soldier_id)
			_refresh_all_views()
	else:
		_los_visualizer.hide_preview()
		_sync_fire_at_ui_from_engagements()


func _on_grenade_mode_changed(is_active: bool, soldier_id: int) -> void:
	_grenade_mode = is_active
	_grenade_soldier_id = soldier_id if is_active else 1
	if is_active:
		_move_targeting = false
		_squad_move_targeting = false
		_fire_at_mode = false
		_squad_fire_at_mode = false
		_face_mode = false
		_los_visualizer.hide_preview()
		if soldier_id > 0:
			_control_fireteam().select_soldier(soldier_id)
			_refresh_all_views()


func _on_face_mode_changed(is_active: bool, soldier_id: int) -> void:
	_face_mode = is_active
	_face_soldier_id = soldier_id if is_active else 1
	if is_active:
		_clear_face_manual_override()
		_move_targeting = false
		_squad_move_targeting = false
		_fire_at_mode = false
		_squad_fire_at_mode = false
		_grenade_mode = false
		if soldier_id > 0:
			_control_fireteam().select_soldier(soldier_id)
			_refresh_all_views()


func _on_save_requested() -> void:
	if GameSaveClass.save_game_state(_game_state):
		_command_bar.show_status("Game saved.")
	else:
		_command_bar.show_status("Save failed.")


func _on_load_requested() -> void:
	var result: ActionResultClass = CommandRouter.load_saved_session(_game_state)
	if not result.success:
		_command_bar.show_status(result.status_message)
		return
	_sync_views_after_load()
	_present_action_result(result)


func _on_map_save_requested() -> void:
	if MapDataClass.save_to_file(_map_data):
		_command_bar.show_status("Map saved to res://maps/test_map.json")
	else:
		_command_bar.show_status("Map save failed.")


func _on_map_load_requested() -> void:
	var result: ActionResultClass = CommandRouter.reload_map_from_file(_game_state)
	_map_data = _game_state.map_data
	IsometricGrid.reset_view_rotation()
	_apply_map_presentation()
	_camera.set_map_size(_map_data.width, _map_data.height)
	_apply_team_default_camera(_session.active_team_id)
	_sync_views_after_load()
	_present_action_result(result)


func _sync_views_after_load() -> void:
	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			var view: Soldier = _get_view(soldier_state.team_id, soldier_state.soldier_id)
			if view == null:
				continue
			view.stop_movement()
			var is_selected: bool = (
				soldier_state.team_id == _session.active_team_id
				and soldier_state.soldier_id == _control_fireteam().selected_soldier_id
			)
			## One path with idle_peek_side — do not call sync_from_state with PeekSide.NONE default.
			_sync_soldier_view(soldier_state.team_id, soldier_state.soldier_id, is_selected)

	_iso_map.clear_path()
	_command_bar.clear_move_targeting()
	_command_bar.clear_fire_at_mode()
	_command_bar.clear_face_mode()
	_command_bar.set_active_team(_session.active_team_id)
	_refresh_all_views()
	_command_bar.sync_selected_soldier(_control_fireteam().selected_soldier_id)


func _get_world_mouse_local() -> Vector2:
	return _world.to_local(get_global_mouse_position())


## Fire At commits on click: sprite, occupied tile, or enemy in the aim cone (no hover assign).
func _resolve_fire_at_click_enemy(
	clicked_soldier: SoldierState,
	click_cell: Vector2i,
	aim_world: Vector2,
) -> SoldierState:
	if _is_enemy_fire_at_target(clicked_soldier):
		return clicked_soldier
	if click_cell.x > -900 and _game_state != null:
		var on_cell: SoldierState = _game_state.find_living_soldier_at_cell(click_cell)
		if _is_enemy_fire_at_target(on_cell):
			return on_cell
	return _find_enemy_in_fire_at_aim_cone(aim_world, click_cell)


func _is_enemy_fire_at_target(soldier_state: SoldierState) -> bool:
	if soldier_state == null or soldier_state.is_dead or _session == null:
		return false
	return soldier_state.team_id != _session.active_team_id


## Click-time UI pick only — cone geometry, not authoritative LOS/spotting.
func _find_enemy_in_fire_at_aim_cone(aim_world: Vector2, click_cell: Vector2i) -> SoldierState:
	var shooters: Array[SoldierState] = _get_manual_fire_at_shooters()
	if shooters.is_empty() or _game_state == null:
		return null
	var best: SoldierState = null
	var best_dist := INF
	for shooter in shooters:
		var weapon := shooter.get_weapon_data()
		var max_range := (
			ConeOfFireClass.effective_range(weapon.range_tiles)
			if weapon != null
			else ConeOfFireClass.RANGE_BONUS
		)
		var from_world := _get_soldier_tracer_point(shooter)
		var enemy_team_id := _game_state.enemy_team_id(shooter.team_id)
		var enemies: Fireteam = _game_state.session.get_fireteam(enemy_team_id)
		if enemies == null:
			continue
		for state in enemies.soldiers:
			var enemy: SoldierState = state
			if enemy == null or enemy.is_dead:
				continue
			var enemy_world := IsometricGrid.soldier_aim_point(enemy.grid_position)
			if not ConeOfFireClass.is_world_point_in_aim_cone(
				from_world,
				aim_world,
				enemy_world,
				shooter.grid_position,
				max_range,
			):
				continue
			var click_dist := 0.0
			if click_cell.x > -900:
				click_dist = float(
					absi(click_cell.x - enemy.grid_position.x)
					+ absi(click_cell.y - enemy.grid_position.y)
				)
			var shooter_dist := float(
				absi(shooter.grid_position.x - enemy.grid_position.x)
				+ absi(shooter.grid_position.y - enemy.grid_position.y)
			)
			## Prefer the enemy nearest the clicked tile so a new aim direction retargets.
			var dist := click_dist * 100.0 + shooter_dist
			if dist < best_dist:
				best_dist = dist
				best = enemy
	return best


## Resolve a soldier under the cursor (grid cell + sprite proximity for isometric picking).
func _find_living_soldier_at_mouse() -> SoldierState:
	var world := _get_world_mouse_local()
	var clicked_cell := IsometricGrid.world_to_cell_at_point(world)

	var exact: SoldierState = _game_state.find_living_soldier_at_cell(clicked_cell)
	if exact != null:
		return exact

	const PICK_RADIUS := TileSizeConfig.SOLDIER_PICK_RADIUS
	const PICK_RADIUS_SQ := PICK_RADIUS * PICK_RADIUS
	var best: SoldierState = null
	var best_dist := PICK_RADIUS_SQ

	for fireteam in _session.all_fireteams():
		for state in fireteam.soldiers:
			var soldier_state: SoldierState = state
			if soldier_state.is_dead:
				continue
			var view: Soldier = _get_view(soldier_state.team_id, soldier_state.soldier_id)
			var pick_center := IsometricGrid.soldier_aim_point(soldier_state.grid_position)
			if view != null:
				pick_center = view.position + TileSizeConfig.tracer_aim_offset()
			var dist_sq := world.distance_squared_to(pick_center)
			if dist_sq < best_dist:
				best_dist = dist_sq
				best = soldier_state

	return best


func _center_camera_on_map() -> void:
	if _map_data == null:
		return
	IsometricGrid.set_view_pivot_for_map(_map_data.width, _map_data.height)
	_camera.set_map_size(_map_data.width, _map_data.height)
	var focus_cell: Vector2i = _get_camera_focus_cell()
	_map_background.set_center_cell(focus_cell)
	_camera.reset_to_default_view(IsometricGrid.grid_to_world(focus_cell))


func _get_camera_focus_cell() -> Vector2i:
	return _deployment_zone_center_cell(Team.USA)


func _deployment_zone_center_cell(team_id: int) -> Vector2i:
	var spawns: Array[Vector2i] = (
		_map_data.team_1_spawn_points if team_id == Team.USA else _map_data.team_2_spawn_points
	)
	if spawns.is_empty():
		return Vector2i(floori(_map_data.width / 2.0), floori(_map_data.height / 2.0))
	var sum := Vector2i.ZERO
	for cell in spawns:
		sum += cell
	return Vector2i(floori(float(sum.x) / spawns.size()), floori(float(sum.y) / spawns.size()))


## Temporary debug: kill several soldiers per faction, rotate camera, confirm corpse stability.
func debug_validate_dead_static_corpses(per_faction: int = 3) -> Array:
	var report: Array = []
	if _game_state == null:
		return [{"error": "no game state"}]
	var killed: Array[SoldierState] = []
	for team_id in [Team.USA, Team.GERMANY]:
		var count := 0
		for fireteam in _session.all_fireteams():
			for state_v in fireteam.soldiers:
				var state: SoldierState = state_v
				if state.team_id != team_id or state.is_dead:
					continue
				state.mark_killed()
				var view: Soldier = _get_view(state.team_id, state.soldier_id)
				if view != null:
					view.play_death_sequence(Vector2i(0, 1), state.stance_at_death, state.death_sprite_family)
					## Skip straight to static corpse for validation (do not wait for fall).
					view.debug_force_dead_static()
				killed.append(state)
				count += 1
				if count >= per_faction:
					break
			if count >= per_faction:
				break
	_refresh_all_views()
	var families_seen := {}
	for state in killed:
		families_seen[state.death_sprite_family] = true
		var view2: Soldier = _get_view(state.team_id, state.soldier_id)
		var snap: Dictionary = view2.dump_dead_static_validation() if view2 != null else {}
		report.append({
			"phase": "initial",
			"soldier_id": state.soldier_id,
			"team_id": state.team_id,
			"family": state.death_sprite_family,
			"view": snap,
		})
	## Rotate through all four camera views; family + world facing must stay stable.
	for _i in 4:
		IsometricGrid.rotate_view_right()
		_refresh_view_rotation()
		for state in killed:
			var view3: Soldier = _get_view(state.team_id, state.soldier_id)
			var snap2: Dictionary = view3.dump_dead_static_validation() if view3 != null else {}
			report.append({
				"phase": "camera_%d" % IsometricGrid.camera_direction_degrees(),
				"soldier_id": state.soldier_id,
				"family": state.death_sprite_family,
				"family_unchanged": snap2.get("death_sprite_family", "") == state.death_sprite_family,
				"view": snap2,
			})
	GameLog.log_system(
		"dead_static debug | killed=%d unique_families=%d entries=%d"
		% [killed.size(), families_seen.size(), report.size()]
	)
	return report
