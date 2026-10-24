extends Node
## Headless regression suite for the Gameplay Foundation refactor.
##
## Run:
##   Godot_v4.x_console.exe --headless --path <project> res://scripts/tests/gameplay_foundation_tests.tscn

const MapDataClass := preload("res://scripts/map/map_data.gd")
const MapLoaderClass := preload("res://scripts/map/map_loader.gd")
const GameSessionClass := preload("res://scripts/core/game_session.gd")
const ActionResolverClass := preload("res://scripts/core/action_resolver.gd")
const CommandContextClass := preload("res://scripts/core/command_context.gd")
const MoveCommandClass := preload("res://scripts/commands/move_command.gd")
const FireCommandClass := preload("res://scripts/commands/fire_command.gd")
const GrenadeCommandClass := preload("res://scripts/commands/grenade_command.gd")
const CoverSystemClass := preload("res://scripts/combat/cover_system.gd")
const LOSSystemClass := preload("res://scripts/combat/los_system.gd")
const MapObjectRegistryClass := preload("res://scripts/map/map_object_registry.gd")
const MovementModeClass := preload("res://scripts/enums/movement_mode.gd")
const CombatSystemClass := preload("res://scripts/combat/combat_system.gd")
const HitChancePolicyClass := preload("res://scripts/gameplay_policies/hit_chance_policy.gd")
const PositionStateClass := preload("res://scripts/enums/position_state.gd")
const MapAssetRegistryClass := preload("res://scripts/map/map_asset_registry.gd")

var _failed: int = 0
var _passed: int = 0


func _ready() -> void:
	_bootstrap()
	_test_fortress_map_loads()
	_test_soldier_movement()
	_test_human_move_ignores_fireteam_cohesion()
	_test_prone_walk_stands_instead_of_reject()
	_test_stunned_soldier_cannot_move()
	_test_off_grid_move_clamps_onto_map()
	_test_squad_run_to_redirect_keeps_formation()
	_test_firing()
	_test_grenade_throwing()
	_test_grenade_rejects_friendly_blast()
	_test_grenade_skips_friendly_stun()
	_test_grenade_halt_and_throw_while_moving()
	_test_los_fixture()
	_test_climb_short_wall_fire_over()
	_test_wall_cover_fixture()
	_test_corner_peek_around_wall_end()
	_test_corner_idle_at_wall_end()
	_test_directional_cover()
	_test_rng_seed_reproducibility()
	_test_firing_sequence_reproducibility()
	_test_grenade_sequence_reproducibility()
	_test_grenade_inverse_distance_model()
	_test_grenade_blast_blocked_by_wall()
	_test_grenade_stun_aborts_pending_throw()
	_test_policy_defaults_unchanged()
	_test_lethality_multiplier()
	_test_lethality_time_to_casualty_band()
	_test_min_hit_chance_not_after_modifiers()
	_test_point_blank_prone_cover_lethal()
	_test_recovered_weapon_stats()
	_test_fire_cadence_cycle()
	_test_hit_polynomial_anchors()
	_test_cover_curve_and_slot()
	_test_movement_angle_hit()
	_test_smg_vs_rifle_range_falloff()
	_test_grenade_range_cap()
	_test_stress_model()
	_test_phase7_shared_parity_fixtures()
	_test_fixed_simulation_tick()
	_test_movement_frame_rate_independence()
	_test_object_id_and_registry()
	_test_map_object_registry()
	_test_grenade_object_registry()
	_test_team_soldier_key_consistent()
	_test_perception_cache_incremental()
	_test_scenario_clock_and_scoring()
	_test_timed_deployment_zone_lock()
	_test_build_config_editor_is_development()

	print("")
	print("Gameplay foundation tests: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _test_phase7_shared_parity_fixtures() -> void:
	var path := "res://assets/data/combat_phase7_parity.json"
	var file := FileAccess.open(path, FileAccess.READ)
	_assert("Phase 7 parity fixture opens", file != null)
	if file == null:
		return
	var fixture: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	_assert("Phase 7 parity fixture parses", fixture is Dictionary)
	if not fixture is Dictionary:
		return
	for raw in fixture.get("base_accuracy", []):
		var entry: Dictionary = raw
		var weapon = GameplayPolicies.weapons.create_weapon(str(entry.weapon_id))
		var actual := CombatSystemClass.hit_chance(
			Vector2i.ZERO,
			Vector2i(int(entry.range), 0),
			weapon,
		)
		_assert(
			"Phase 7 base parity %s@%s" % [entry.weapon_id, entry.range],
			is_equal_approx(actual, float(entry.expected)),
		)
	for raw in fixture.get("stress_accuracy", []):
		var entry: Dictionary = raw
		var actual := GameplayPolicies.suppression.accuracy_modifier_for(
			float(entry.stress),
			int(entry.range),
			float(entry.aim_factor),
		)
		_assert(
			"Phase 7 stress parity %s/%s" % [entry.stress, entry.aim_factor],
			is_equal_approx(actual, float(entry.expected)),
		)
	for raw in fixture.get("suppression_gain", []):
		var entry: Dictionary = raw
		var actual := GameplayPolicies.suppression.range_suppression_gain_runtime(
			float(entry.stress_factor),
			float(entry.limit),
			int(entry.range),
		)
		_assert(
			"Phase 7 suppression parity %s@%s" % [entry.stress_factor, entry.range],
			is_equal_approx(actual, float(entry.expected)),
		)
	for raw in fixture.get("decay", []):
		var entry: Dictionary = raw
		var actual := GameplayPolicies.suppression.apply_stress_decay(
			float(entry.stress),
			bool(entry.prone),
			float(entry.delta_sec),
		)
		_assert(
			"Phase 7 decay parity prone=%s" % entry.prone,
			is_equal_approx(actual, float(entry.expected)),
		)


func _bootstrap() -> void:
	SimulationClock.reset()
	GameRandom.reseed(GameRandom.DEFAULT_SEED)
	GameplayPolicies.reset_all_to_defaults()


func _pass(name: String) -> void:
	_passed += 1
	print("[PASS] %s" % name)


func _fail(name: String, detail: String) -> void:
	_failed += 1
	print("[FAIL] %s — %s" % [name, detail])


func _assert(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass(name)
	else:
		_fail(name, detail if not detail.is_empty() else "assertion failed")


func _make_session(map_data: MapDataClass) -> GameSessionClass:
	var blue: Array[Vector2i] = map_data.team_1_spawn_points
	var red: Array[Vector2i] = map_data.team_2_spawn_points
	if blue.is_empty():
		blue = MapDataClass.default_usa_spawn_points()
	if red.is_empty():
		red = MapDataClass.default_germany_spawn_points()
	return GameSessionClass.new(blue, red)


func _make_game_state(map_data: MapDataClass = null) -> GameState:
	if map_data == null:
		map_data = MapDataClass.create_default()
	var session := _make_session(map_data)
	var game_state := session.create_game_state(map_data)
	ActionResolverClass.apply_match_start_setup(game_state)
	return game_state


func _bfs_path(map_data: MapDataClass, from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if map_data == null or not map_data.is_walkable(from_cell) or not map_data.is_walkable(to_cell):
		return empty
	if from_cell == to_cell:
		return [from_cell]

	var offsets: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	var queue: Array[Vector2i] = [from_cell]
	var came_from: Dictionary = {}
	came_from[from_cell] = from_cell
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		if current == to_cell:
			break
		for offset in offsets:
			var next_cell: Vector2i = current + offset
			if came_from.has(next_cell):
				continue
			if not map_data.is_walkable(next_cell):
				continue
			came_from[next_cell] = current
			queue.append(next_cell)

	if not came_from.has(to_cell):
		return empty

	var path: Array[Vector2i] = []
	var cursor := to_cell
	while true:
		path.push_front(cursor)
		if cursor == from_cell:
			break
		cursor = came_from[cursor]
	return path


func _path_context(map_data: MapDataClass) -> CommandContextClass:
	var ctx := CommandContextClass.new()
	ctx.find_path = func(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
		return _bfs_path(map_data, from_cell, to_cell)
	return ctx


func _test_fortress_map_loads() -> void:
	var map_data := MapLoaderClass.load_fortress()
	_assert(
		"Fortress map loads successfully",
		map_data != null and map_data.width > 0 and map_data.height > 0,
		"width=%s height=%s name=%s"
		% [
			str(map_data.width if map_data else null),
			str(map_data.height if map_data else null),
			str(map_data.map_name if map_data else null),
		],
	)
	if map_data != null:
		_assert(
			"Fortress map has spawn points",
			not map_data.team_1_spawn_points.is_empty()
			and not map_data.team_2_spawn_points.is_empty(),
			"usa=%d germany=%d"
			% [map_data.team_1_spawn_points.size(), map_data.team_2_spawn_points.size()],
		)


func _test_soldier_movement() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var soldier := game_state.get_soldier(Team.USA, 1)
	var start := soldier.grid_position
	var target := start + Vector2i(2, 0)
	if not game_state.map_data.is_walkable(target):
		target = start + Vector2i(0, 2)

	var cmd := MoveCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = target
	cmd.movement_mode = MovementModeClass.RUN
	cmd.scope = MoveCommandClass.Scope.SINGLE

	var result := ActionResolverClass.execute_move(
		game_state,
		cmd,
		_path_context(game_state.map_data),
	)
	_assert("Soldier movement order succeeds", result.success, result.status_message)
	_assert(
		"Soldier movement sets path",
		soldier.is_moving and soldier.current_path.size() >= 2,
		"is_moving=%s path_len=%d" % [soldier.is_moving, soldier.current_path.size()],
	)

	## Advance via simulation ticks until arrival (not presentation lerp).
	var guard := 0
	while soldier.is_moving and guard < 10000:
		SimulationClock.advance_tick()
		ActionResolverClass.process_movement_tick(game_state)
		guard += 1
	_assert("Soldier movement completes via sim ticks", not soldier.is_moving, "guard=%d" % guard)
	_assert(
		"Soldier movement ends on target cell",
		soldier.grid_position == target,
		"expected %s got %s" % [target, soldier.grid_position],
	)


func _test_human_move_ignores_fireteam_cohesion() -> void:
	## A stretched fireteam used to fail every Run To with "Cannot move that far from fireteam".
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var fireteam := game_state.session.get_fireteam(Team.USA)
	_assert("cohesion fixture has a fireteam", fireteam != null and fireteam.soldiers.size() >= 2)
	var mover: SoldierState = fireteam.soldiers[0]
	var peer: SoldierState = fireteam.soldiers[1]
	mover.grid_position = Vector2i(8, 20)
	peer.grid_position = Vector2i(40, 20)
	mover.clear_path()
	peer.clear_path()
	var target := Vector2i(6, 20)
	var cmd := MoveCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = mover.soldier_id
	cmd.target_cell = target
	cmd.movement_mode = MovementModeClass.RUN
	cmd.scope = MoveCommandClass.Scope.SINGLE
	var result := ActionResolverClass.execute_move(game_state, cmd, _path_context(map_data))
	_assert(
		"Human move succeeds even when fireteam span exceeds cohesion",
		result.success,
		result.status_message,
	)
	_assert(
		"Human move is not rolled back by cohesion",
		mover.is_moving and not mover.current_path.is_empty(),
		"is_moving=%s path_len=%d" % [mover.is_moving, mover.current_path.size()],
	)


func _test_prone_walk_stands_instead_of_reject() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var soldier := game_state.get_soldier(Team.USA, 1)
	soldier.position_state = PositionStateClass.DOWN
	soldier.clear_pending_position()
	var validation := ActionResolverClass.validate_move(soldier, MovementModeClass.WALK)
	_assert("Prone WALK is accepted", validation.is_empty(), validation)
	_assert(
		"Prone WALK stands the soldier",
		soldier.position_state == PositionStateClass.UP,
		"position_state=%d" % soldier.position_state,
	)


func _test_stunned_soldier_cannot_move() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var soldier := game_state.get_soldier(Team.USA, 1)
	soldier.apply_stun(4.0)
	var start := soldier.grid_position
	var target := start + Vector2i(2, 0)
	if not game_state.map_data.is_walkable(target):
		target = start + Vector2i(0, 2)
	var cmd := MoveCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = target
	cmd.movement_mode = MovementModeClass.RUN
	cmd.scope = MoveCommandClass.Scope.SINGLE
	var result := ActionResolverClass.execute_move(
		game_state, cmd, _path_context(game_state.map_data)
	)
	_assert("Stunned soldier cannot be ordered to move", not result.success, result.status_message)
	_assert(
		"Stun is the move rejection reason",
		result.status_message.contains("stunned"),
		result.status_message,
	)


func _test_off_grid_move_clamps_onto_map() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var soldier := game_state.get_soldier(Team.USA, 1)
	soldier.grid_position = Vector2i(5, 5)
	soldier.clear_path()
	var cmd := MoveCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = Vector2i(-8, 5)
	cmd.movement_mode = MovementModeClass.RUN
	cmd.scope = MoveCommandClass.Scope.SINGLE
	var result := ActionResolverClass.execute_move(game_state, cmd, _path_context(map_data))
	_assert("Off-grid click is accepted as an on-map move", result.success, result.status_message)
	_assert(
		"Off-grid click snaps to the map rim",
		cmd.target_cell == Vector2i(0, 5),
		"clamped=%s" % cmd.target_cell,
	)
	_assert(
		"Path ends on the map rim",
		not soldier.current_path.is_empty()
		and soldier.current_path[soldier.current_path.size() - 1] == Vector2i(0, 5),
	)


func _test_squad_run_to_redirect_keeps_formation() -> void:
	## Mid-run squad redirect must keep the prior destination shape, not mid-path cells.
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var fireteam := game_state.session.get_fireteam(Team.USA)
	var line_origin := Vector2i(10, 20)
	var first_click := Vector2i(20, 20)
	var second_click := Vector2i(30, 20)
	var soldiers: Array[SoldierState] = []
	for i in range(mini(4, fireteam.soldiers.size())):
		var soldier: SoldierState = fireteam.soldiers[i]
		soldier.grid_position = line_origin + Vector2i(i, 0)
		soldier.clear_path()
		soldiers.append(soldier)
	_assert("squad formation test has 4 soldiers", soldiers.size() == 4, "got %d" % soldiers.size())

	var cmd1 := MoveCommandClass.new()
	cmd1.team_id = Team.USA
	cmd1.target_cell = first_click
	cmd1.movement_mode = MovementModeClass.RUN
	cmd1.scope = MoveCommandClass.Scope.SQUAD
	var result1 := ActionResolverClass.execute_move(game_state, cmd1, _path_context(map_data))
	_assert("first squad Run To succeeds", result1.success, result1.status_message)

	var first_ends: Dictionary = {}
	for soldier in soldiers:
		_assert(
			"soldier %d moving after first Run To" % soldier.soldier_id,
			soldier.is_moving and not soldier.current_path.is_empty(),
		)
		first_ends[soldier.soldier_id] = soldier.current_path[soldier.current_path.size() - 1]

	## Drift mid-path cells so a bug using grid_position would collapse the line.
	soldiers[0].grid_position = Vector2i(14, 20)
	soldiers[1].grid_position = Vector2i(14, 20)
	soldiers[2].grid_position = Vector2i(15, 21)
	soldiers[3].grid_position = Vector2i(13, 19)

	var cmd2 := MoveCommandClass.new()
	cmd2.team_id = Team.USA
	cmd2.target_cell = second_click
	cmd2.movement_mode = MovementModeClass.RUN
	cmd2.scope = MoveCommandClass.Scope.SQUAD
	var result2 := ActionResolverClass.execute_move(game_state, cmd2, _path_context(map_data))
	_assert("redirect squad Run To succeeds", result2.success, result2.status_message)

	var anchor_id: int = soldiers[0].soldier_id
	var first_anchor: Vector2i = first_ends[anchor_id]
	for soldier in soldiers:
		var expected_offset: Vector2i = first_ends[soldier.soldier_id] - first_anchor
		var expected_end := second_click + expected_offset
		var got_end := soldier.current_path[soldier.current_path.size() - 1]
		_assert(
			"redirect keeps formation for soldier %d" % soldier.soldier_id,
			got_end == expected_end,
			"expected %s got %s (offset %s)" % [expected_end, got_end, expected_offset],
		)


func _test_firing() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	## Clear default cover between teams so LOS is clear for the shot.
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	## Place close with clear LOS and facing for spotting/fire.
	shooter.grid_position = Vector2i(20, 30)
	target.grid_position = Vector2i(24, 30)
	shooter.clear_path()
	target.clear_path()
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)
	CombatSystemClass.update_spotting(game_state)
	shooter.record_last_seen_enemy(target)

	var ammo_before := shooter.ammo_current
	var fire_cmd := FireCommandClass.new()
	fire_cmd.team_id = Team.USA
	fire_cmd.soldier_id = 1
	fire_cmd.target_team_id = Team.GERMANY
	fire_cmd.target_soldier_id = 1
	fire_cmd.aim_world = IsometricGrid.grid_to_world(target.grid_position)
	fire_cmd.scope = FireCommandClass.Scope.SINGLE

	var fire_ctx := CommandContextClass.new()
	fire_ctx.shooter_ids = [1]
	var fire_result := ActionResolverClass.execute_fire(game_state, fire_cmd, fire_ctx)
	_assert("Firing engagement succeeds", fire_result.success, fire_result.status_message)
	_assert("Firing engagement marks sustained fire", shooter.is_sustained_fire())

	var fired := false
	for _attempt in range(4):
		SimulationClock.advance_msec(int(GameplayPolicies.hit.fire_prep_delay_sec * 1000.0) + 50)
		var tick := ActionResolverClass.process_combat_tick(game_state)
		if tick.combat_shots.size() >= 1 and shooter.ammo_current < ammo_before:
			fired = true
			break
	_assert(
		"Firing combat tick discharges a shot",
		fired,
		"ammo %d -> %d sustained=%s engaged=%d:%d"
		% [
			ammo_before,
			shooter.ammo_current,
			shooter.is_sustained_fire(),
			shooter.engaged_target_team_id,
			shooter.engaged_target_soldier_id,
		],
	)


func _park_friendlies_away(game_state: GameState, thrower_team: int, thrower_id: int) -> void:
	for fireteam in game_state.session.all_fireteams():
		if fireteam.team_id != thrower_team:
			continue
		for state in fireteam.soldiers:
			if state == null or state.soldier_id == thrower_id:
				continue
			state.grid_position = Vector2i(2, 2)
			state.clear_path()


func _test_grenade_throwing() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var thrower := game_state.get_soldier(Team.USA, 1)
	thrower.grid_position = Vector2i(20, 30)
	thrower.clear_path()
	_park_friendlies_away(game_state, Team.USA, 1)
	## Far enough that blast (radius 3) cannot reach the thrower.
	var target_cell := Vector2i(24, 30)
	var count_before := thrower.grenade_count

	var cmd := GrenadeCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = target_cell
	var result := ActionResolverClass.execute_grenade(
		game_state,
		cmd,
		CommandContextClass.new(),
	)
	_assert("Grenade throw succeeds", result.success, result.status_message)
	_assert(
		"Grenade throw consumes inventory and arms fuse",
		thrower.grenade_count == count_before - 1
		and thrower.has_pending_grenade()
		and thrower.pending_grenade_target == target_cell,
		"count=%d pending=%s target=%s"
		% [thrower.grenade_count, thrower.has_pending_grenade(), thrower.pending_grenade_target],
	)

	SimulationClock.advance_msec(GameplayPolicies.grenade.fuse_msec + 1)
	var tick := ActionResolverClass.process_combat_tick(game_state)
	_assert(
		"Grenade fuse detonates on simulation clock",
		tick.grenade_explosions.size() == 1 and not thrower.has_pending_grenade(),
		"explosions=%d pending=%s"
		% [tick.grenade_explosions.size(), thrower.has_pending_grenade()],
	)


func _test_grenade_rejects_friendly_blast() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var thrower := game_state.get_soldier(Team.USA, 1)
	var buddy := game_state.get_soldier(Team.USA, 2)
	thrower.grid_position = Vector2i(20, 30)
	buddy.grid_position = Vector2i(24, 30)
	thrower.clear_path()
	buddy.clear_path()
	_park_friendlies_away(game_state, Team.USA, 1)
	## Put buddy back inside the intended blast after parking others.
	buddy.grid_position = Vector2i(24, 30)
	var cmd := GrenadeCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = Vector2i(24, 30)
	var result := ActionResolverClass.execute_grenade(
		game_state, cmd, CommandContextClass.new()
	)
	_assert(
		"Grenade throw rejected when friendly in blast",
		not result.success,
		result.status_message,
	)
	_assert(
		"Friendly-blast helper detects buddy",
		CombatSystemClass.grenade_would_hit_friendly(game_state, Team.USA, Vector2i(24, 30)),
	)


func _test_grenade_skips_friendly_stun() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var thrower := game_state.get_soldier(Team.USA, 1)
	var buddy := game_state.get_soldier(Team.USA, 2)
	var enemy := game_state.get_soldier(Team.GERMANY, 1)
	thrower.grid_position = Vector2i(10, 10)
	buddy.grid_position = Vector2i(21, 30)
	enemy.grid_position = Vector2i(22, 30)
	thrower.clear_path()
	buddy.clear_path()
	enemy.clear_path()
	var explosion := CombatSystemClass.resolve_grenade(game_state, thrower, Vector2i(22, 30))
	var buddy_hit := false
	for entry in explosion.stunned:
		if int(entry.get("team_id", -1)) == Team.USA:
			buddy_hit = true
	for entry in explosion.killed:
		if int(entry.get("team_id", -1)) == Team.USA:
			buddy_hit = true
	_assert("Grenade blast does not stun/kill friendlies", not buddy_hit)
	_assert("Buddy remains unstunned", not buddy.is_stunned())
	_assert(
		"Enemy still affected by blast",
		not explosion.stunned.is_empty() or not explosion.killed.is_empty(),
	)


func _test_grenade_halt_and_throw_while_moving() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var thrower := game_state.get_soldier(Team.USA, 1)
	thrower.grid_position = Vector2i(20, 30)
	_park_friendlies_away(game_state, Team.USA, 1)
	var path: Array[Vector2i] = [
		Vector2i(20, 30),
		Vector2i(21, 30),
		Vector2i(22, 30),
		Vector2i(23, 30),
	]
	thrower.assign_path(path, 1.0)
	_assert("Thrower starts moving", thrower.is_moving)
	var cmd := GrenadeCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = Vector2i(24, 30)
	var result := ActionResolverClass.execute_grenade(
		game_state, cmd, CommandContextClass.new()
	)
	_assert("Moving soldier can halt and throw in range", result.success, result.status_message)
	_assert("Thrower stopped moving after grenade", not thrower.is_moving)
	_assert("Grenade armed after drain-and-throw", thrower.has_pending_grenade())
	_assert(
		"Movement halt recorded for presentation",
		not result.movement_halts.is_empty(),
	)


func _test_los_fixture() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var from_cell := Vector2i(10, 10)
	var to_cell := Vector2i(14, 10)
	var clear_los := LOSSystemClass.evaluate(from_cell, to_cell, map_data, null)
	_assert(
		"LOS fixture clear open ground",
		clear_los.status == LOSSystemClass.Status.CLEAR,
		"status=%s" % LOSSystemClass.status_name(clear_los.status),
	)

	var blocker := Vector2i(12, 10)
	map_data.set_object(blocker, MapObjectRegistryClass.TYPE_TREE)
	var blocked_los := LOSSystemClass.evaluate(from_cell, to_cell, map_data, null)
	_assert(
		"LOS fixture tree blocks line of fire",
		blocked_los.status == LOSSystemClass.Status.BLOCKED,
		"status=%s type=%s" % [LOSSystemClass.status_name(blocked_los.status), blocked_los.blocking_type],
	)


func _test_climb_short_wall_fire_over() -> void:
	## Climb / height-1 short walls (WH00): standing shooters fire over them, even at prone targets.
	_bootstrap()
	MapAssetRegistryClass.ensure_loaded()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var wall := Vector2i(22, 30)
	map_data.place_family_object(wall, "WH00", 0)
	_assert("WH00 is climb terrain", map_data.is_climb(wall))
	_assert("WH00 height is 1", map_data.obstruction_height(wall) == 1)
	_assert(
		"WH00 does not block standing vision",
		not map_data.blocks_vision(wall, false, false),
	)
	_assert(
		"WH00 does not block standing→prone vision",
		not map_data.blocks_vision(wall, false, true),
	)
	_assert(
		"WH00 blocks prone observer vision",
		map_data.blocks_vision(wall, true, false),
	)

	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	## Shooter immediately behind the short wall; target beyond it (prone, as in Farm Fight).
	shooter.grid_position = Vector2i(21, 30)
	target.grid_position = Vector2i(24, 30)
	target.position_state = PositionStateClass.DOWN
	shooter.clear_path()
	target.clear_path()
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)
	CombatSystemClass.update_spotting(game_state)
	shooter.record_last_seen_enemy(target)

	var los := LOSSystemClass.evaluate(
		shooter.grid_position,
		target.grid_position,
		map_data,
		game_state,
	)
	_assert(
		"Standing over WH00 at prone target is not BLOCKED",
		los.status != LOSSystemClass.Status.BLOCKED,
		"status=%s type=%s" % [LOSSystemClass.status_name(los.status), los.blocking_type],
	)

	var ammo_before := shooter.ammo_current
	var fire_cmd := FireCommandClass.new()
	fire_cmd.team_id = Team.USA
	fire_cmd.soldier_id = 1
	fire_cmd.target_team_id = Team.GERMANY
	fire_cmd.target_soldier_id = 1
	fire_cmd.aim_world = IsometricGrid.grid_to_world(target.grid_position)
	fire_cmd.scope = FireCommandClass.Scope.SINGLE
	var fire_ctx := CommandContextClass.new()
	fire_ctx.shooter_ids = [1]
	var fire_result := ActionResolverClass.execute_fire(game_state, fire_cmd, fire_ctx)
	_assert("Fire At over short wall engages", fire_result.success, fire_result.status_message)

	var fired := false
	for _attempt in range(4):
		SimulationClock.advance_msec(int(GameplayPolicies.hit.fire_prep_delay_sec * 1000.0) + 50)
		var tick := ActionResolverClass.process_combat_tick(game_state)
		if tick.combat_shots.size() >= 1 and shooter.ammo_current < ammo_before:
			fired = true
			break
	_assert(
		"Fire At over short wall discharges a shot",
		fired,
		"ammo %d -> %d status=%s"
		% [ammo_before, shooter.ammo_current, fire_result.status_message],
	)

	## Prone shooter without adjacent peek cannot see over mid-line climb cover.
	shooter.position_state = PositionStateClass.DOWN
	shooter.grid_position = Vector2i(20, 30) ## wall at 22 is not adjacent
	var prone_los := LOSSystemClass.evaluate(
		shooter.grid_position,
		target.grid_position,
		map_data,
		game_state,
	)
	_assert(
		"Prone shooter mid-line WH00 is BLOCKED",
		prone_los.status == LOSSystemClass.Status.BLOCKED,
		"status=%s type=%s" % [LOSSystemClass.status_name(prone_los.status), prone_los.blocking_type],
	)


func _test_wall_cover_fixture() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var shooter := Vector2i(10, 10)
	var wall := Vector2i(11, 10)
	var target := Vector2i(13, 10)
	map_data.set_object(wall, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)

	var usage := CoverSystemClass.evaluate_wall_cover_usage(shooter, target, map_data)
	_assert(
		"Wall cover fixture detects shooter wall usage",
		usage.shooter_using_wall_cover and usage.shooter_cover_cell == wall,
		"shooter_using=%s cell=%s"
		% [usage.shooter_using_wall_cover, usage.shooter_cover_cell],
	)

	var los := LOSSystemClass.evaluate(shooter, target, map_data, null)
	_assert(
		"Wall cover fixture allows peek LOS over adjacent wall",
		los.status != LOSSystemClass.Status.BLOCKED,
		"status=%s shooter_cover=%s target_cover=%s"
		% [
			LOSSystemClass.status_name(los.status),
			los.shooter_using_wall_cover,
			los.target_using_wall_cover,
		],
	)

	## Mid-line wall (neither side adjacent): hard BLOCKED — cannot shoot through a solid wall.
	## Adjacent wall-end peek is allowed separately (corner peek / adjacent fixture above).
	var far_shooter := Vector2i(8, 10)
	var far_target := Vector2i(14, 10)
	var mid_wall := Vector2i(11, 10)
	map_data.clear_object(wall)
	map_data.set_object(mid_wall, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var mid_line := LOSSystemClass.evaluate(far_shooter, far_target, map_data, null)
	_assert(
		"Wall cover fixture mid-line wall is BLOCKED",
		mid_line.status == LOSSystemClass.Status.BLOCKED,
		"status=%s type=%s"
		% [LOSSystemClass.status_name(mid_line.status), mid_line.blocking_type],
	)


func _test_corner_peek_around_wall_end() -> void:
	## Offensive corner peek: shooter adjacent to a wall END can fire around it.
	## A second hard wall further down the Bresenham line still hard-blocks.
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	## Wall end adjacent to shooter; target around the corner (line hits only that end).
	##   S # .
	##   . . T
	var shooter := Vector2i(10, 10)
	var wall_end := Vector2i(11, 10)
	var target_around := Vector2i(12, 11)
	map_data.set_object(wall_end, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)

	var peek_los := LOSSystemClass.evaluate(shooter, target_around, map_data, null)
	_assert(
		"Corner peek allows shot around wall end",
		peek_los.status != LOSSystemClass.Status.BLOCKED,
		"status=%s peek=%s side=%s"
		% [
			LOSSystemClass.status_name(peek_los.status),
			peek_los.corner_peek,
			CoverSystemClass.peek_side_name(peek_los.peek_side),
		],
	)
	_assert(
		"Corner peek sets peek_side for animation",
		peek_los.corner_peek and peek_los.peek_side != CoverSystemClass.PeekSide.NONE,
		"peek=%s side=%s" % [peek_los.corner_peek, peek_los.peek_side],
	)
	_assert(
		"Corner peek defeats hard wall protection on the peeked cell",
		not peek_los.target_using_wall_cover,
		"target_using_wall_cover=%s" % peek_los.target_using_wall_cover,
	)
	_assert(
		"Corner peek around wall end is a clear shot",
		peek_los.status == LOSSystemClass.Status.CLEAR,
		"status=%s cover=%s" % [LOSSystemClass.status_name(peek_los.status), peek_los.cover_type],
	)

	## Second wall further along the line — not adjacent to shooter or target.
	## Line (10,10)->(14,12) visits (11,10)/(12,11)/(13,11); deeper wall at (12,11) blocks.
	var wall_deeper := Vector2i(12, 11)
	var target_behind := Vector2i(14, 12)
	map_data.set_object(wall_deeper, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var blocked_los := LOSSystemClass.evaluate(shooter, target_behind, map_data, null)
	_assert(
		"Corner peek does not pierce continuous wall",
		blocked_los.status == LOSSystemClass.Status.BLOCKED,
		"status=%s type=%s"
		% [LOSSystemClass.status_name(blocked_los.status), blocked_los.blocking_type],
	)

	## Bresenham diagonal cut: line misses the corner cell the shooter leans on, then
	## hits the next tiles of the wall run — still a corner peek, not a mid-wall block.
	## Mirrors ff_farm Stables SW: S(42,50)→T(46,48) past WCOR(43,49).
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var cut_shooter := Vector2i(10, 11)
	var cut_corner := Vector2i(11, 10)
	var cut_run_a := Vector2i(12, 10)
	var cut_run_b := Vector2i(13, 10)
	var cut_target := Vector2i(14, 9)
	map_data.set_object(cut_corner, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	map_data.set_object(cut_run_a, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	map_data.set_object(cut_run_b, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var cut_los := LOSSystemClass.evaluate(cut_shooter, cut_target, map_data, null)
	_assert(
		"Corner peek survives Bresenham diagonal cut past wall end",
		cut_los.status != LOSSystemClass.Status.BLOCKED,
		"status=%s peek=%s block_line=%s"
		% [
			LOSSystemClass.status_name(cut_los.status),
			cut_los.corner_peek,
			CoverSystemClass.line_cells_between(cut_shooter, cut_target),
		],
	)
	_assert(
		"Diagonal-cut corner peek sets lean side",
		cut_los.corner_peek and cut_los.peek_side != CoverSystemClass.PeekSide.NONE,
		"peek=%s side=%s" % [cut_los.corner_peek, cut_los.peek_side],
	)

	## Target of a peek shot still receives cover eval (PseudoCover / corner when geometry fits).
	var cover := CoverSystemClass.evaluate_target_cover(shooter, target_around, map_data)
	_assert(
		"Peek target cover eval still runs",
		cover != null,
		"cover_type=%s qualifier=%s" % [cover.cover_type, cover.qualifier],
	)


func _test_corner_idle_at_wall_end() -> void:
	## Cover-relative corner idle: standing at a wall tip/corner is enough (no aim required).
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var soldier := Vector2i(10, 10)
	var wall_end := Vector2i(11, 10)
	map_data.set_object(wall_end, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var target_around := Vector2i(12, 11)
	var face_toward := FacingDirection.toward_cell(soldier, target_around)

	## No aim cell — still lean when cover-relative geometry says BehindCorner.
	var no_aim := CoverSystemClass.corner_idle_at_cell(soldier, face_toward, map_data)
	_assert(
		"Corner idle without aim uses cover-relative corner",
		no_aim.is_corner and no_aim.peek_side != CoverSystemClass.PeekSide.NONE,
		"corner=%s side=%s cell=%s" % [no_aim.is_corner, no_aim.peek_side, no_aim.corner_cell],
	)

	var aim_peek := CoverSystemClass.corner_idle_at_cell(
		soldier, face_toward, map_data, target_around
	)
	_assert(
		"Corner idle with aim still resolves a corner",
		aim_peek.is_corner and aim_peek.peek_side != CoverSystemClass.PeekSide.NONE,
		"corner=%s side=%s face=%s" % [aim_peek.is_corner, aim_peek.peek_side, face_toward],
	)

	## Along-wall face (no wall on the shot line) — cover-relative still triggers.
	var along_wall_target := Vector2i(10, 12)
	var face_along := FacingDirection.toward_cell(soldier, along_wall_target)
	var along_peek := CoverSystemClass.corner_idle_at_cell(
		soldier, face_along, map_data, along_wall_target
	)
	_assert(
		"Corner idle along wall face still uses cover-relative corner",
		along_peek.is_corner,
		"corner=%s side=%s" % [along_peek.is_corner, along_peek.peek_side],
	)

	## Mid-run wall face (not tip/corner) should not trigger cover-relative lean.
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	map_data.set_object(Vector2i(11, 9), MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	map_data.set_object(Vector2i(11, 10), MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	map_data.set_object(Vector2i(11, 11), MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var mid_face := CoverSystemClass.cover_relative_corner_at_cell(
		Vector2i(10, 10), Vector2i(0, 1), map_data
	)
	_assert(
		"Cover-relative ignores mid-run wall face",
		not mid_face.is_corner,
		"corner=%s side=%s" % [mid_face.is_corner, mid_face.peek_side],
	)

	## Teammate further back: not adjacent to the wall tip.
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	map_data.set_object(wall_end, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var behind := Vector2i(9, 10)
	var behind_face := FacingDirection.toward_cell(behind, target_around)
	var behind_idle := CoverSystemClass.corner_idle_at_cell(
		behind, behind_face, map_data, target_around
	)
	_assert(
		"Corner idle ignores shooter not adjacent to the corner",
		not behind_idle.is_corner,
		"corner=%s side=%s" % [behind_idle.is_corner, behind_idle.peek_side],
	)


func _test_directional_cover() -> void:
	_bootstrap()
	var CoverPolicyClass := preload("res://scripts/gameplay_policies/cover_policy.gd")
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var target := Vector2i(20, 20)
	var wall := Vector2i(19, 20) ## west of target
	map_data.set_object(wall, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)

	## Shooter west of wall: wall is between shooter and target → cover.
	var west_shooter := Vector2i(16, 20)
	var covered := CoverSystemClass.evaluate_target_cover(west_shooter, target, map_data)
	_assert(
		"Directional cover: wall on shooter-facing side grants cover",
		covered.cover_type != CoverSystemClass.CoverType.NONE
		and covered.source_cell == wall,
		"type=%s cell=%s" % [covered.cover_type, covered.source_cell],
	)

	## Flank from the east: same wall is behind the target relative to the shot → no cover.
	var east_shooter := Vector2i(24, 20)
	var flanked := CoverSystemClass.evaluate_target_cover(east_shooter, target, map_data)
	_assert(
		"Directional cover: flanking defeats the same wall",
		flanked.cover_type == CoverSystemClass.CoverType.NONE,
		"type=%s cell=%s" % [flanked.cover_type, flanked.source_cell],
	)

	## Obstruction beside target but off the shot vector grants no cover.
	map_data.clear_object(wall)
	var side_wall := Vector2i(20, 19) ## north of target; shot is east-west
	map_data.set_object(side_wall, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var side_check := CoverSystemClass.evaluate_target_cover(west_shooter, target, map_data)
	_assert(
		"Directional cover: off-axis adjacent wall grants no cover",
		side_check.cover_type == CoverSystemClass.CoverType.NONE,
		"type=%s cells=%s" % [side_check.cover_type, str(side_check.qualifying_cells)],
	)

	## Only the adjacent compass slot counts — a wall two tiles out is ignored.
	map_data.clear_object(side_wall)
	var far_wall := Vector2i(18, 20) ## two tiles west of target
	map_data.set_object(far_wall, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var far_check := GameplayPolicies.cover.cover_check(west_shooter, target, map_data)
	_assert(
		"Directional cover: non-adjacent wall grants no cover",
		not far_check.in_cover,
		"cells=%s offset=%s" % [str(far_check.qualifying_cells), far_check.cover_offset],
	)

	## Height 1 (haybail) and height 2 (wall) both grant cover when on the facing side.
	map_data.clear_object(far_wall)
	var low_cover := Vector2i(19, 20)
	map_data.set_object(low_cover, MapObjectRegistryClass.TYPE_HAYBAIL)
	_assert(
		"Directional cover: height-1 tile can grant cover",
		map_data.obstruction_height(low_cover) >= 1
		and CoverSystemClass.evaluate_target_cover(west_shooter, target, map_data).cover_type
		!= CoverSystemClass.CoverType.NONE,
		"height=%d" % map_data.obstruction_height(low_cover),
	)
	map_data.clear_object(low_cover)
	var high_cover := Vector2i(19, 20)
	map_data.set_object(high_cover, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	_assert(
		"Directional cover: height-2 tile can grant cover",
		map_data.obstruction_height(high_cover) >= 2
		and CoverSystemClass.evaluate_target_cover(west_shooter, target, map_data).cover_type
		!= CoverSystemClass.CoverType.NONE,
		"height=%d" % map_data.obstruction_height(high_cover),
	)

	## Diagonal shot snaps to a diagonal slot → PseudoCover / CORNER qualifier.
	map_data.clear_object(high_cover)
	var corner := Vector2i(19, 19) ## NW of target
	map_data.set_object(corner, MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var nw_shooter := Vector2i(16, 16)
	var corner_check := GameplayPolicies.cover.cover_check(nw_shooter, target, map_data)
	_assert(
		"Directional cover: diagonal facing tile is CORNER qualifier",
		corner_check.in_cover and corner_check.qualifier == CoverPolicyClass.Qualifier.CORNER,
		"in_cover=%s qualifier=%s offset=%s"
		% [corner_check.in_cover, corner_check.qualifier, corner_check.cover_offset],
	)


func _test_rng_seed_reproducibility() -> void:
	GameRandom.reseed(42)
	var a: Array[float] = []
	for i in range(8):
		a.append(GameRandom.randf())

	GameRandom.reseed(42)
	var b: Array[float] = []
	for i in range(8):
		b.append(GameRandom.randf())

	_assert("Same RNG seed produces identical sequence", a == b, "a=%s b=%s" % [str(a), str(b)])

	GameRandom.reseed(99)
	var c: Array[float] = []
	for i in range(8):
		c.append(GameRandom.randf())
	_assert("Different RNG seed diverges", a != c)

	## Snapshot/restore for replay debugging.
	GameRandom.reseed(7)
	GameRandom.randf()
	GameRandom.randf()
	var snap := GameRandom.get_snapshot()
	var next_a := GameRandom.randf()
	GameRandom.restore_snapshot(snap)
	var next_b := GameRandom.randf()
	_assert(
		"RNG snapshot restore continues the same stream",
		is_equal_approx(next_a, next_b),
		"a=%s b=%s" % [next_a, next_b],
	)
	## Bounded probability helpers (isolated seed so they cannot pollute later tests).
	GameRandom.reseed(1)
	_assert("chance(1.0) always true", GameRandom.chance(1.0))
	GameRandom.reseed(1)
	_assert("chance(0.0) always false", not GameRandom.chance(0.0))


func _capture_shot_outcomes(seed_value: int) -> Array[bool]:
	_bootstrap()
	GameRandom.reseed(seed_value)
	SimulationClock.reset()

	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	shooter.grid_position = Vector2i(20, 30)
	target.grid_position = Vector2i(23, 30)
	shooter.clear_path()
	target.clear_path()

	var hits: Array[bool] = []
	for i in range(6):
		target.is_dead = false
		target.position_state = 0
		shooter.ammo_current = maxi(shooter.ammo_current, 30)
		game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)
		CombatSystemClass.begin_fire_prep(shooter)
		SimulationClock.advance_msec(int(GameplayPolicies.hit.fire_prep_delay_sec * 1000.0) + 50)
		var shot := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
		hits.append(shot.fired and shot.hit)
		SimulationClock.advance_msec(2000)
	return hits


func _test_firing_sequence_reproducibility() -> void:
	var first := _capture_shot_outcomes(777)
	var second := _capture_shot_outcomes(777)
	_assert(
		"Same firing sequence produces identical outcomes",
		first == second and first.size() == 6,
		"first=%s second=%s" % [str(first), str(second)],
	)


func _capture_grenade_outcomes(seed_value: int) -> Array[String]:
	_bootstrap()
	GameRandom.reseed(seed_value)
	SimulationClock.reset()

	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var thrower := game_state.get_soldier(Team.USA, 1)
	var victim := game_state.get_soldier(Team.GERMANY, 1)
	thrower.grid_position = Vector2i(20, 30)
	victim.grid_position = Vector2i(21, 30)
	thrower.clear_path()
	victim.clear_path()

	var outcomes: Array[String] = []
	for i in range(5):
		thrower.is_dead = false
		victim.is_dead = false
		victim.stunned_until_msec = 0
		victim.stand_on_stun_recovery = false
		victim.position_state = 0
		var explosion := CombatSystemClass.resolve_grenade(game_state, thrower, victim.grid_position)
		if not explosion.killed.is_empty():
			outcomes.append("kill")
		elif not explosion.stunned.is_empty():
			outcomes.append("stun")
		else:
			outcomes.append("none")
	return outcomes


func _test_grenade_sequence_reproducibility() -> void:
	var first := _capture_grenade_outcomes(12345)
	var second := _capture_grenade_outcomes(12345)
	_assert(
		"Same grenade sequence produces identical outcomes",
		first == second and first.size() == 5,
		"first=%s second=%s" % [str(first), str(second)],
	)


func _test_grenade_inverse_distance_model() -> void:
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	var g = GameplayPolicies.grenade
	_assert(
		"Direct-hit casualty capped at 60% (TUNED denom min 0.5)",
		is_equal_approx(g.casualty_chance_at_distance(0.0), 0.60),
		"got=%s" % g.casualty_chance_at_distance(0.0),
	)
	_assert(
		"Distance 1 casualty is 30%",
		is_equal_approx(g.casualty_chance_at_distance(1.0), 0.30),
	)
	_assert(
		"Distance 2 casualty is 15%",
		is_equal_approx(g.casualty_chance_at_distance(2.0), 0.15),
	)
	_assert(
		"Stun at distance 0 is 6.0s",
		is_equal_approx(g.stun_duration_at_distance(0.0), 6.0),
	)
	_assert(
		"Stun at distance 1 is 5.0s",
		is_equal_approx(g.stun_duration_at_distance(1.0), 5.0),
	)
	_assert(
		"Stun at distance 2 is ~4.286s",
		is_equal_approx(g.stun_duration_at_distance(2.0), 30.0 / 7.0),
	)

	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var thrower := game_state.get_soldier(Team.USA, 1)
	var near := game_state.get_soldier(Team.GERMANY, 1)
	var far := game_state.get_soldier(Team.GERMANY, 2)
	thrower.grid_position = Vector2i(20, 30)
	near.grid_position = Vector2i(21, 30)
	far.grid_position = Vector2i(24, 30) ## Euclidean 4 > hit_distance 2
	thrower.clear_path()
	near.clear_path()
	far.clear_path()
	GameplayPolicies.hit.lethality_multiplier = 0.0
	GameRandom.reseed(7)
	var explosion := CombatSystemClass.resolve_grenade(game_state, thrower, Vector2i(20, 30))
	var near_stunned := false
	var far_hit := false
	for entry in explosion.stunned:
		if int(entry.get("soldier_id", -1)) == near.soldier_id:
			near_stunned = true
		if int(entry.get("soldier_id", -1)) == far.soldier_id:
			far_hit = true
	for entry in explosion.killed:
		if int(entry.get("soldier_id", -1)) == far.soldier_id:
			far_hit = true
	_assert("Near soldier stunned when lethality 0", near_stunned and near.is_stunned())
	_assert("Near soldier is DOWN after grenade stun", near.position_state == PositionStateClass.DOWN)
	_assert(
		"Near soldier movement mode forced to CRAWL",
		near.movement_mode == MovementModeClass.CRAWL,
	)
	_assert("Far soldier outside hit_distance unaffected", not far_hit and not far.is_stunned())
	_assert("Near needs cover recheck after stun", near.needs_cover_recheck)
	GameplayPolicies.reset_all_to_defaults()


func _test_grenade_blast_blocked_by_wall() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	map_data.set_object(Vector2i(22, 30), MapObjectRegistryClass.TYPE_WALL_STRAIGHT)
	var game_state := _make_game_state(map_data)
	var thrower := game_state.get_soldier(Team.USA, 1)
	var behind := game_state.get_soldier(Team.GERMANY, 1)
	thrower.grid_position = Vector2i(20, 30)
	behind.grid_position = Vector2i(23, 30)
	thrower.clear_path()
	behind.clear_path()
	GameRandom.reseed(99)
	var explosion := CombatSystemClass.resolve_grenade(game_state, thrower, Vector2i(21, 30))
	_assert(
		"Wall blocks grenade blast to soldier behind it",
		explosion.killed.is_empty() and explosion.stunned.is_empty(),
		"killed=%d stunned=%d" % [explosion.killed.size(), explosion.stunned.size()],
	)
	_assert("Soldier behind wall remains unstunned", not behind.is_stunned())


func _test_grenade_stun_aborts_pending_throw() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var thrower := game_state.get_soldier(Team.USA, 1)
	var victim := game_state.get_soldier(Team.GERMANY, 1)
	## Victim is mid-throw when USA grenade lands on them.
	victim.grid_position = Vector2i(21, 30)
	thrower.grid_position = Vector2i(20, 30)
	victim.grenade_count = 2
	victim.pending_grenade_target = Vector2i(18, 30)
	victim.grenade_explode_at_msec = SimulationClock.get_ticks_msec() + 5000
	game_state.objects.register_grenade_from_soldier(victim)
	_assert("Victim starts with pending grenade", victim.has_pending_grenade())
	GameplayPolicies.hit.lethality_multiplier = 0.0
	GameRandom.reseed(3)
	CombatSystemClass.resolve_grenade(game_state, thrower, victim.grid_position)
	_assert("Stun aborts pending grenade throw", not victim.has_pending_grenade())
	_assert(
		"Aborted grenade unregistered from objects",
		game_state.objects.get_grenade(ObjectId.grenade(Team.GERMANY, victim.soldier_id)) == null,
	)
	GameplayPolicies.reset_all_to_defaults()


func _test_policy_defaults_unchanged() -> void:
	GameplayPolicies.reset_all_to_defaults()
	_assert(
		"Hit scale calibrated for OG rifle≈9% at 11 tiles",
		is_equal_approx(GameplayPolicies.hit.hit_scale, 0.060),
	)
	_assert(
		"Hit lethality multiplier is tuned 0.90",
		is_equal_approx(GameplayPolicies.hit.lethality_multiplier, 0.90),
	)
	_assert("Grenade policy range is recovered 5", GameplayPolicies.grenade.throw_range == 5)
	_assert(
		"Grenade hit distance is recovered 2",
		is_equal_approx(GameplayPolicies.grenade.hit_distance, 2.0),
	)
	_assert("Grenade VarA is recovered 30", is_equal_approx(GameplayPolicies.grenade.var_a, 30.0))
	_assert("Grenade VarB is recovered 0", is_equal_approx(GameplayPolicies.grenade.var_b, 0.0))
	_assert("Grenade VarC is recovered 30", is_equal_approx(GameplayPolicies.grenade.var_c, 30.0))
	_assert("Grenade VarD is recovered 5", is_equal_approx(GameplayPolicies.grenade.var_d, 5.0))
	_assert("Suppression pinned threshold unchanged", is_equal_approx(GameplayPolicies.suppression.pinned_threshold, 45.0))
	_assert("Movement run speed unchanged", is_equal_approx(GameplayPolicies.movement.speed_run, 2.0))
	_assert("Vision cone range bonus unchanged", GameplayPolicies.vision.cone_range_bonus == 8)
	_assert(
		"Cover hit multiplier is recovered 0.005",
		is_equal_approx(GameplayPolicies.cover.cover_hit_multiplier, 0.005),
	)
	_assert("Cover range limit is 5", GameplayPolicies.cover.cover_range_limit == 5)
	_assert("LOS peek adjacency unchanged", GameplayPolicies.los.peek_adjacency_chebyshev == 1)
	_assert(
		"Base fire cycle is 5.0s",
		is_equal_approx(GameplayPolicies.hit.base_fire_cycle_sec, 5.0),
		"cycle=%s" % GameplayPolicies.hit.base_fire_cycle_sec,
	)
	_assert(
		"First fire cycle is 5.0s",
		is_equal_approx(GameplayPolicies.hit.first_fire_cycle_sec, 5.0),
		"first=%s" % GameplayPolicies.hit.first_fire_cycle_sec,
	)
	_assert(
		"Open-ground hit mult is tuned 1.15",
		is_equal_approx(GameplayPolicies.hit.open_ground_hit_mult, 1.15),
	)
	_assert(
		"Burst round interval default 0.04s",
		is_equal_approx(GameplayPolicies.hit.burst_round_interval_sec, 0.04),
	)
	var garand := GameplayPolicies.weapons.create_weapon("m1_garand")
	_assert(
		"Weapon policy M1 Garand uses global fire cycle (override 0)",
		garand != null and is_equal_approx(garand.fire_interval_sec, 0.0),
		"interval=%s" % [garand.fire_interval_sec if garand else "null"],
	)
	_assert(
		"Weapon policy M1 Garand engagement envelope is generous",
		garand != null and garand.range_tiles == 40,
		"range=%s" % [garand.range_tiles if garand else "null"],
	)
	GameplayPolicies.reload_from_config()
	_assert(
		"Config reload preserves effective M1 Garand cycle",
		is_equal_approx(GameplayPolicies.weapons.fire_interval_sec("m1_garand"), 5.0),
	)
	_assert("Simulation tick hz default 20", SimulationClock.tick_hz == 20)
	_assert("Simulation tick msec is 50", SimulationClock.tick_msec() == 50)


func _advance_past_fire_prep(shooter: SoldierState) -> void:
	var delay_msec := int(ceil(CombatSystemClass.get_aim_delay_sec(shooter) * 1000.0)) + 50
	SimulationClock.advance_msec(delay_msec)


func _test_lethality_multiplier() -> void:
	## HitFinal numbers stay untouched; lethality only scales the kill roll.
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	_assert(
		"Default lethality is TUNED 0.90 (not recovered 0.20)",
		is_equal_approx(GameplayPolicies.hit.lethality_multiplier, 0.90),
		"got=%s" % GameplayPolicies.hit.lethality_multiplier,
	)
	_assert(
		"Recovered INITKilledProbability constant is 0.20",
		is_equal_approx(HitChancePolicyClass.RECOVERED_LETHALITY_MULTIPLIER, 0.20),
	)

	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	shooter.grid_position = Vector2i(20, 30)
	target.grid_position = Vector2i(22, 30)
	shooter.clear_path()
	target.clear_path()
	shooter.stress = 0.0
	target.stress = 0.0
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)

	## lethality 0 → never kills even when shots fire.
	GameplayPolicies.hit.lethality_multiplier = 0.0
	GameRandom.reseed(11)
	var never_killed := true
	var zero_lethality_fired := 0
	for _i in range(12):
		target.is_dead = false
		target.position_state = PositionStateClass.UP
		target.death_sprite_family = ""
		shooter.ammo_current = maxi(shooter.ammo_current, 30)
		CombatSystemClass.begin_fire_prep(shooter)
		_advance_past_fire_prep(shooter)
		var miss_shot := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
		if miss_shot.fired:
			zero_lethality_fired += 1
		if miss_shot.killed or target.is_dead:
			never_killed = false
			break
		SimulationClock.advance_msec(2000)
	_assert("lethality 0.0 still fires shots", zero_lethality_fired >= 1)
	_assert("lethality 0.0 never kills", never_killed)

	## lethality 1.0 → kill rate matches HitFinal (pre-fold behavior).
	GameplayPolicies.hit.lethality_multiplier = 1.0
	GameRandom.reseed(42)
	var kills_at_full := 0
	var full_lethality_fired := 0
	for _i in range(20):
		target.is_dead = false
		target.position_state = PositionStateClass.UP
		target.death_sprite_family = ""
		target.stress = 0.0
		shooter.stress = 0.0
		shooter.ammo_current = maxi(shooter.ammo_current, 30)
		CombatSystemClass.begin_fire_prep(shooter)
		_advance_past_fire_prep(shooter)
		var full_shot := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
		if full_shot.fired:
			full_lethality_fired += 1
		if full_shot.killed:
			kills_at_full += 1
		SimulationClock.advance_msec(2000)
	_assert("lethality 1.0 fires shots", full_lethality_fired >= 1)
	_assert(
		"lethality 1.0 can kill at close range",
		kills_at_full >= 1,
		"kills=%d fired=%d/20" % [kills_at_full, full_lethality_fired],
	)

	## Lethality must leave hit_chance() itself unchanged.
	GameplayPolicies.hit.lethality_multiplier = 0.90
	var rifle := GameplayPolicies.weapons.create_weapon("m1_garand")
	var chance_a := CombatSystemClass.hit_chance(Vector2i(0, 0), Vector2i(8, 0), rifle)
	GameplayPolicies.hit.lethality_multiplier = 0.0
	var chance_b := CombatSystemClass.hit_chance(Vector2i(0, 0), Vector2i(8, 0), rifle)
	_assert(
		"hit_chance() ignores lethality_multiplier",
		is_equal_approx(chance_a, chance_b),
		"a=%.4f b=%.4f" % [chance_a, chance_b],
	)
	GameplayPolicies.reload_from_config()


func _test_lethality_time_to_casualty_band() -> void:
	## Stage 2: close range decisive; ~11 tiles stays a slow grind (OG rifle ≈9%).
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	var rifle := GameplayPolicies.weapons.create_weapon("m1_garand")
	var lethality := GameplayPolicies.hit.lethality_multiplier
	var cycle := GameplayPolicies.hit.base_fire_cycle_sec
	var close_hit := CombatSystemClass.hit_chance(Vector2i(20, 30), Vector2i(22, 30), rifle)
	var mid_hit := CombatSystemClass.hit_chance(Vector2i(20, 30), Vector2i(31, 30), rifle)
	_assert("Close-range rifle HitFinal is near certain", close_hit >= 0.85, "hit=%.4f" % close_hit)
	_assert(
		"Rifle HitFinal ≈9% at 11 tiles",
		mid_hit >= 0.08 and mid_hit <= 0.105,
		"hit=%.4f" % mid_hit,
	)
	var close_ttk := cycle / maxf(close_hit * lethality, 0.001)
	var mid_ttk := cycle / maxf(mid_hit * lethality, 0.001)
	_assert(
		"Close-range expected TTK is decisive (<20s)",
		close_ttk < 20.0,
		"ttk=%.1fs hit=%.4f L=%.2f" % [close_ttk, close_hit, lethality],
	)
	_assert(
		"Mid-range expected TTK stays a grind (>=45s)",
		mid_ttk >= 45.0,
		"ttk=%.1fs hit=%.4f L=%.2f" % [mid_ttk, mid_hit, lethality],
	)
	## Grenade path shares the same lethality fold.
	var casualty := GameplayPolicies.grenade.casualty_chance_at_distance(1.0)
	var grenade_kill := casualty * lethality
	_assert(
		"Grenade kill chance at d=1 folds lethality",
		is_equal_approx(grenade_kill, 0.30 * lethality),
		"got=%.4f" % grenade_kill,
	)


func _test_min_hit_chance_not_after_modifiers() -> void:
	## Stage 2: situational multipliers apply after base; no re-floor to the old 10%.
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)

	var shooter_cell := Vector2i(10, 20)
	var target_cell := Vector2i(28, 20) ## Euclidean 18 — long range
	var cover_cell := Vector2i(27, 20) ## moderate cover on shooter-facing side
	map_data.set_object(cover_cell, MapObjectRegistryClass.TYPE_HAYBAIL)

	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	shooter.grid_position = shooter_cell
	target.grid_position = target_cell
	shooter.clear_path()
	target.clear_path()
	shooter.stress = 0.0
	target.stress = 0.0
	target.position_state = PositionStateClass.DOWN
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)

	var weapon := shooter.get_weapon_data()
	var base := CombatSystemClass.hit_chance(shooter_cell, target_cell, weapon)
	_assert(
		"Base hit_chance is positive but low at long range",
		base > 0.0 and base < 0.05,
		"base=%.4f" % base,
	)

	var los := LOSSystemClass.evaluate(shooter_cell, target_cell, map_data, game_state)
	_assert(
		"Long-range haybail setup grants moderate cover (not blocked)",
		los.status != LOSSystemClass.Status.BLOCKED
		and los.cover_type == CoverSystemClass.CoverType.MODERATE,
		"status=%s cover=%s" % [los.status, los.cover_type],
	)

	var final_chance: float = CombatSystemClass._final_hit_chance(shooter, target, weapon, los)
	var cover_range := CombatSystemClass._combat_range(shooter_cell, target_cell)
	var cover_mult := GameplayPolicies.cover.cover_multiplier_for_range(cover_range)
	var expected_ceiling := base * cover_mult * GameplayPolicies.hit.target_prone_hit_mult
	_assert(
		"Cover+prone final chance is below clear base",
		final_chance < base,
		"final=%.4f base=%.4f expected~%.4f" % [final_chance, base, expected_ceiling],
	)
	_assert(
		"Final chance stays in [0, 1]",
		final_chance >= 0.0 and final_chance <= 1.0,
		"final=%.4f" % final_chance,
	)
	_assert(
		"Final chance roughly matches base × cover × prone",
		is_equal_approx(final_chance, expected_ceiling),
		"final=%.4f expected=%.4f" % [final_chance, expected_ceiling],
	)


func _test_point_blank_prone_cover_lethal() -> void:
	## 1-tile rifle vs prone target in moderate cover must still be near-lethal.
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var shooter_cell := Vector2i(20, 30)
	var target_cell := Vector2i(21, 30)
	var cover_cell := Vector2i(20, 30)
	map_data.set_object(cover_cell, MapObjectRegistryClass.TYPE_HAYBAIL)
	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	shooter.grid_position = shooter_cell
	target.grid_position = target_cell
	shooter.clear_path()
	target.clear_path()
	shooter.stress = 0.0
	target.stress = 0.0
	target.position_state = PositionStateClass.DOWN
	shooter.assign_weapon("m1_garand", false)
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)

	var weapon := shooter.get_weapon_data()
	var los := LOSSystemClass.evaluate(shooter_cell, target_cell, map_data, game_state)
	_assert(
		"Point-blank haybail is moderate cover, not blocked",
		los.status != LOSSystemClass.Status.BLOCKED
		and los.cover_type == CoverSystemClass.CoverType.MODERATE,
		"status=%s cover=%s" % [los.status, los.cover_type],
	)
	var bd: Dictionary = {}
	var final_chance: float = CombatSystemClass._final_hit_chance(shooter, target, weapon, los, bd)
	_assert(
		"Point-blank floor is recorded and applied",
		is_equal_approx(float(bd.get("point_blank_floor", 0.0)), 0.92)
		and final_chance >= 0.92,
		"floor=%s final=%.4f" % [bd.get("point_blank_floor"), final_chance],
	)
	var per_round := clampf(final_chance * GameplayPolicies.hit.lethality_multiplier, 0.0, 1.0)
	var rounds := weapon.ammo_cost(shooter.ammo_current)
	var kill_chance := 1.0 - pow(1.0 - per_round, float(maxi(rounds, 1)))
	_assert(
		"Point-blank prone+cover rifle kill_chance >= 0.8",
		kill_chance >= 0.8,
		"kill=%.4f final=%.4f rounds=%d" % [kill_chance, final_chance, rounds],
	)
	CombatSystemClass.begin_fire_prep(shooter)
	SimulationClock.advance_msec(int(GameplayPolicies.hit.fire_prep_delay_sec * 1000.0) + 50)
	var shot := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
	_assert(
		"resolve_shot reports effective attack kill_chance >= 0.8",
		shot.fired and shot.kill_chance >= 0.8,
		"fired=%s kill=%.4f" % [shot.fired, shot.kill_chance],
	)


func _test_recovered_weapon_stats() -> void:
	GameplayPolicies.reset_all_to_defaults()
	var WeaponPolicyClass := preload("res://scripts/gameplay_policies/weapon_policy.gd")
	var expected := {
		"m1_garand": {"rpa": 1, "ammo": 70, "speed": 6, "supp": 0.25, "slt": 25.0, "saf": 0.5, "afs": 2000.0, "cub": 1.0, "pent": 0.0},
		"kar98k": {"rpa": 1, "ammo": 70, "speed": 6, "supp": 0.25, "slt": 25.0, "saf": 0.5, "afs": 2000.0, "cub": 1.0, "pent": 0.0},
		"thompson": {"rpa": 4, "ammo": 200, "speed": 6, "supp": 2.0, "slt": 13.0, "saf": 1.5, "afs": 2000.0, "cub": 0.0, "pent": 0.02},
		"mp40": {"rpa": 5, "ammo": 200, "speed": 6, "supp": 2.0, "slt": 13.0, "saf": 1.5, "afs": 2000.0, "cub": 0.0, "pent": 0.02},
		"bar": {"rpa": 7, "ammo": 900, "speed": 6, "supp": 0.6, "slt": 25.0, "saf": 2.0, "afs": 8000.0, "cub": 1.0, "pent": 0.0},
		"mg42": {"rpa": 6, "ammo": 900, "speed": 7, "supp": 0.6, "slt": 25.0, "saf": 2.0, "afs": 8000.0, "cub": 1.0, "pent": 0.0},
	}
	for weapon_id in expected.keys():
		var w := GameplayPolicies.weapons.create_weapon(weapon_id)
		var e: Dictionary = expected[weapon_id]
		_assert(
			"%s recovered stats" % weapon_id,
			w != null
			and w.rounds_per_attack == int(e.rpa)
			and w.ammo_capacity == int(e.ammo)
			and w.bullet_speed == int(e.speed)
			and is_equal_approx(w.suppression_generated, float(e.supp))
			and is_equal_approx(w.stress_limit_tiles, float(e.slt))
			and is_equal_approx(w.stress_aim_factor, float(e.saf))
			and is_equal_approx(w.aim_factor_sqr, float(e.afs))
			and is_equal_approx(w.range_const_cub, float(e.cub))
			and is_equal_approx(w.range_const_pent, float(e.pent))
			and is_equal_approx(w.fire_interval_sec, 0.0)
			and is_equal_approx(w.aim_delay_sec, 0.0),
			"weapon=%s" % [w.weapon_id if w else "null"],
		)
	var bar := GameplayPolicies.weapons.create_weapon("bar")
	var mg42 := GameplayPolicies.weapons.create_weapon("mg42")
	var garand := GameplayPolicies.weapons.create_weapon("m1_garand")
	var thompson := GameplayPolicies.weapons.create_weapon("thompson")
	var cycle := GameplayPolicies.hit.base_fire_cycle_sec
	_assert(
		"All weapon types share the global fire cycle",
		is_equal_approx(CombatSystemClass.effective_fire_cycle_sec(garand), cycle)
		and is_equal_approx(CombatSystemClass.effective_fire_cycle_sec(thompson), cycle)
		and is_equal_approx(CombatSystemClass.effective_fire_cycle_sec(bar), cycle)
		and is_equal_approx(CombatSystemClass.effective_fire_cycle_sec(mg42), cycle),
		"cycle=%.2f" % cycle,
	)
	_assert(
		"LMG aim_factor_sqr is 4× rifle (hit numerator)",
		is_equal_approx(bar.aim_factor_sqr, garand.aim_factor_sqr * 4.0)
		and is_equal_approx(mg42.aim_factor_sqr, bar.aim_factor_sqr),
	)
	_assert("squad limit BAR is 1", WeaponPolicyClass.squad_limit("bar") == 1)
	_assert("squad limit Thompson is 2", WeaponPolicyClass.squad_limit("thompson") == 2)
	_assert("squad limit MG42 is 1", WeaponPolicyClass.squad_limit("mg42") == 1)
	_assert("squad limit MP40 is 2", WeaponPolicyClass.squad_limit("mp40") == 2)
	_assert("squad limit rifle unlimited", WeaponPolicyClass.squad_limit("m1_garand") == -1)


func _test_fire_cadence_cycle() -> void:
	## Stage 4: single aim/fire cycle; not stacked aim + short interval.
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	## Cadence only — keep target alive at point-blank (Stage 2 lethality ≈ removes on hit).
	GameplayPolicies.hit.lethality_multiplier = 0.0
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	shooter.grid_position = Vector2i(20, 30)
	target.grid_position = Vector2i(22, 30)
	shooter.clear_path()
	target.clear_path()
	shooter.stress = 0.0
	target.stress = 0.0
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)

	var first_msec := int(GameplayPolicies.hit.first_fire_cycle_sec * 1000.0)
	var cycle_msec := int(GameplayPolicies.hit.base_fire_cycle_sec * 1000.0)
	CombatSystemClass.begin_fire_prep(shooter)
	_assert(
		"Aiming blocks fire until cycle elapses",
		not CombatSystemClass._is_fire_prep_complete(shooter),
	)
	SimulationClock.advance_msec(first_msec - 100)
	_assert(
		"Still aiming just before first-shot cycle end",
		not CombatSystemClass._is_fire_prep_complete(shooter),
	)
	SimulationClock.advance_msec(200)
	_assert("Fire prep complete after first-shot cycle", CombatSystemClass._is_fire_prep_complete(shooter))

	GameRandom.reseed(7)
	var first := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
	_assert("First shot after cycle fires", first.fired)
	_assert(
		"Shot restarts aim/fire cycle",
		not CombatSystemClass._is_fire_prep_complete(shooter),
	)
	var early := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
	_assert("Immediate second shot is on cooldown", early.on_cooldown and not early.fired)

	SimulationClock.advance_msec(cycle_msec + 50)
	GameRandom.reseed(8)
	var second := CombatSystemClass.resolve_shot(game_state, shooter, target, false)
	_assert("Second shot fires after full cycle", second.fired)


func _test_movement_angle_hit() -> void:
	## Stage 7: open-ground TypeMultipler + running sine crossing term.
	_bootstrap()
	GameplayPolicies.reset_all_to_defaults()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var shooter := game_state.get_soldier(Team.USA, 1)
	var target := game_state.get_soldier(Team.GERMANY, 1)
	shooter.grid_position = Vector2i(10, 20)
	target.grid_position = Vector2i(20, 20)
	shooter.clear_path()
	target.clear_path()
	shooter.stress = 0.0
	target.stress = 0.0
	shooter.facing_direction = FacingDirection.EAST
	game_state.session.get_fireteam(Team.USA).face_toward_tile(1, target.grid_position)

	var weapon := shooter.get_weapon_data()
	var los := LOSSystemClass.evaluate(
		shooter.grid_position, target.grid_position, map_data, game_state
	)
	_assert("Open ground LOS for angle test", los.cover_type == CoverSystemClass.CoverType.NONE)

	var stationary := CombatSystemClass._final_hit_chance(shooter, target, weapon, los)
	## Charge straight at the shooter (west) while running — angle ≈ 1.0, approach 1.35, type 1.05.
	target.assign_path([target.grid_position, Vector2i(19, 20), Vector2i(18, 20)])
	target.movement_mode = MovementModeClass.RUN
	target.facing_direction = FacingDirection.WEST
	var charge_bd: Dictionary = {}
	var charging := CombatSystemClass._final_hit_chance(shooter, target, weapon, los, charge_bd)
	var expected_charge := (
		stationary
		* GameplayPolicies.movement.type_mult_run
		* GameplayPolicies.movement.approach_hit_bonus
	)
	_assert(
		"Head-on running rush is deadlier than standing still",
		charging > stationary,
		"stationary=%.4f charging=%.4f" % [stationary, charging],
	)
	_assert(
		"Head-on rush applies type × approach (angle ≈ 1)",
		absf(charging - expected_charge) < 0.01,
		"charging=%.4f expected≈%.4f approach=%s angle=%s"
		% [
			charging,
			expected_charge,
			charge_bd.get("move_approach_mult"),
			charge_bd.get("move_angle_mult"),
		],
	)

	## Cross the front (north) — abs(sin) ≈ 1 → ×(1 − 0.8) = 0.2; no approach bonus.
	target.assign_path([target.grid_position, Vector2i(20, 19), Vector2i(20, 18)])
	target.movement_mode = MovementModeClass.RUN
	target.facing_direction = FacingDirection.NORTH
	var crossing := CombatSystemClass._final_hit_chance(shooter, target, weapon, los)
	_assert(
		"Perpendicular running crossing is much harder to hit",
		crossing < charging * 0.35,
		"crossing=%.4f charging=%.4f" % [crossing, charging],
	)
	var expected_cross := stationary * GameplayPolicies.movement.type_mult_run * 0.2
	_assert(
		"Crossing multiplier ≈ type × 0.20 of stationary",
		absf(crossing - expected_cross) < 0.01,
		"crossing=%.4f expected≈%.4f" % [crossing, expected_cross],
	)

	## Crawl type mult 0.4; no sine term.
	target.assign_path([target.grid_position, Vector2i(20, 19)])
	target.movement_mode = MovementModeClass.CRAWL
	var crawling := CombatSystemClass._final_hit_chance(shooter, target, weapon, los)
	_assert(
		"Crawling open-ground type mult is 0.4",
		absf(crawling - stationary * 0.4) < 0.01,
		"crawling=%.4f expected≈%.4f" % [crawling, stationary * 0.4],
	)

	## Cover suppresses the movement/angle path.
	map_data.set_object(Vector2i(19, 20), MapObjectRegistryClass.TYPE_HAYBAIL)
	var los_cover := LOSSystemClass.evaluate(
		shooter.grid_position, target.grid_position, map_data, game_state
	)
	target.assign_path([target.grid_position, Vector2i(20, 19)])
	target.movement_mode = MovementModeClass.RUN
	var bd_cover: Dictionary = {}
	var under_cover_moving := CombatSystemClass._final_hit_chance(
		shooter, target, weapon, los_cover, bd_cover
	)
	_assert(
		"Under cover move_angle_mult stays 1.0",
		is_equal_approx(float(bd_cover.get("move_angle_mult", 0.0)), 1.0),
		"angle=%s type=%s" % [bd_cover.get("move_angle_mult"), bd_cover.get("move_type_mult")],
	)
	_assert(
		"Under cover still applies cover mult",
		float(bd_cover.get("cover_mult", 1.0)) < 0.01,
		"cover=%s" % bd_cover.get("cover_mult"),
	)
	_assert("Covered moving chance is non-negative", under_cover_moving >= 0.0)


func _test_cover_curve_and_slot() -> void:
	## Stage 6: recovered cover curve + single 8-dir slot lookup.
	GameplayPolicies.reset_all_to_defaults()
	var policy := GameplayPolicies.cover
	_assert(
		"Cover mult at range 1 is ~1.0 (point-blank cover useless)",
		is_equal_approx(policy.cover_multiplier_for_range(1.0), 1.0),
		"got=%.4f" % policy.cover_multiplier_for_range(1.0),
	)
	_assert(
		"Cover mult at range 2 stays useful (~0.80)",
		absf(policy.cover_multiplier_for_range(2.0) - 0.801) < 0.02,
		"got=%.4f" % policy.cover_multiplier_for_range(2.0),
	)
	_assert(
		"Cover mult at range 3 is above the 0.5 near-floor",
		policy.cover_multiplier_for_range(3.0) >= 0.5
		and policy.cover_multiplier_for_range(3.0) < 0.7,
		"r3=%.4f" % policy.cover_multiplier_for_range(3.0),
	)
	_assert(
		"Cover mult at range 4 is floored at 0.5",
		is_equal_approx(policy.cover_multiplier_for_range(4.0), 0.5),
		"r4=%.4f" % policy.cover_multiplier_for_range(4.0),
	)
	_assert(
		"Cover mult at range >= 5 is 0.005",
		is_equal_approx(policy.cover_multiplier_for_range(5.0), 0.005)
		and is_equal_approx(policy.cover_multiplier_for_range(12.0), 0.005),
		"r5=%.4f r12=%.4f"
		% [policy.cover_multiplier_for_range(5.0), policy.cover_multiplier_for_range(12.0)],
	)

	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var target := Vector2i(20, 20)
	var wall := Vector2i(19, 20)
	map_data.set_object(wall, MapObjectRegistryClass.TYPE_HAYBAIL)
	var shooter := Vector2i(10, 20)
	var check := policy.cover_check(shooter, target, map_data)
	_assert(
		"8-dir slot selects west-adjacent cover",
		check.in_cover and check.source_cell == wall and check.cover_offset == Vector2i(-1, 0),
		"cell=%s offset=%s" % [check.source_cell, check.cover_offset],
	)

	## HitFinal under cover at long range collapses to ~0.5% of clear.
	var weapon := GameplayPolicies.weapons.create_weapon("m1_garand")
	var clear := CombatSystemClass.hit_chance(shooter, target, weapon)
	var covered := clear * policy.cover_multiplier_for_range(
		CombatSystemClass._combat_range(shooter, target)
	)
	_assert(
		"Long-range cover reduces hit to ~0.5% of clear",
		covered < clear * 0.01 and covered > 0.0,
		"clear=%.4f covered=%.6f" % [clear, covered],
	)


func _test_smg_vs_rifle_range_falloff() -> void:
	GameplayPolicies.reset_all_to_defaults()
	var from_cell := Vector2i(0, 0)
	var to_cell := Vector2i(12, 0)
	var rifle := GameplayPolicies.weapons.create_weapon("m1_garand")
	var smg := GameplayPolicies.weapons.create_weapon("thompson")
	var rifle_chance := CombatSystemClass.hit_chance(from_cell, to_cell, rifle)
	var smg_chance := CombatSystemClass.hit_chance(from_cell, to_cell, smg)
	_assert(
		"SMG hit chance at range 12 < rifle hit chance at range 12",
		smg_chance < rifle_chance,
		"smg=%.3f rifle=%.3f" % [smg_chance, rifle_chance],
	)


func _test_hit_polynomial_anchors() -> void:
	## Stage 2: HUD Hit% anchors at 11 tiles, Stress 0, MarksMan 0 (OG rifle≈9%).
	GameplayPolicies.reset_all_to_defaults()
	var from_cell := Vector2i(0, 0)
	var to_cell := Vector2i(11, 0)
	var rifle := GameplayPolicies.weapons.create_weapon("m1_garand")
	var smg := GameplayPolicies.weapons.create_weapon("thompson")
	var mg := GameplayPolicies.weapons.create_weapon("mg42")
	var rifle_p := CombatSystemClass.hit_chance(from_cell, to_cell, rifle)
	var smg_p := CombatSystemClass.hit_chance(from_cell, to_cell, smg)
	var mg_p := CombatSystemClass.hit_chance(from_cell, to_cell, mg)
	_assert(
		"Rifle HitFinal near 0.09 at range 11",
		absf(rifle_p - 0.09) < 0.005,
		"rifle=%.4f" % rifle_p,
	)
	_assert(
		"SMG HitFinal near 0.037 at range 11",
		absf(smg_p - 0.037) < 0.005,
		"smg=%.4f" % smg_p,
	)
	_assert(
		"Heavy MG / rifle ratio is 4.0 at identical range",
		is_equal_approx(mg_p / rifle_p, 4.0),
		"mg=%.4f rifle=%.4f ratio=%.3f" % [mg_p, rifle_p, mg_p / maxf(rifle_p, 0.0001)],
	)
	_assert(
		"Rifle / SMG ratio near 2.4 at range 11",
		absf(rifle_p / smg_p - 2.4) < 0.2,
		"ratio=%.3f" % (rifle_p / maxf(smg_p, 0.0001)),
	)
	## Relative shape vs Garand@10 (pre-scale ratios from the recovered formula).
	var g10 := CombatSystemClass.hit_chance(from_cell, Vector2i(10, 0), rifle)
	var g20 := CombatSystemClass.hit_chance(from_cell, Vector2i(20, 0), rifle)
	var t20 := CombatSystemClass.hit_chance(from_cell, Vector2i(20, 0), smg)
	var b10 := CombatSystemClass.hit_chance(from_cell, Vector2i(10, 0), mg)
	_assert(
		"Garand@20 is ~0.125× Garand@10",
		absf(g20 / g10 - 0.125) < 0.02,
		"g10=%.4f g20=%.4f" % [g10, g20],
	)
	_assert(
		"Thompson@20 falls off a cliff vs rifle",
		t20 < g20 * 0.35,
		"t20=%.4f g20=%.4f" % [t20, g20],
	)
	_assert(
		"MG42 dominates at range 10 (4× rifle)",
		is_equal_approx(b10 / g10, 4.0),
		"b10=%.4f g10=%.4f" % [b10, g10],
	)
	## No hard SMG range gate: still returns a (tiny) chance at long range.
	var smg_far := CombatSystemClass.hit_chance(from_cell, Vector2i(25, 0), smg)
	_assert("SMG at range 25 still has a positive tiny chance", smg_far > 0.0 and smg_far < 0.01)


func _test_grenade_range_cap() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var thrower := game_state.get_soldier(Team.USA, 1)
	thrower.grid_position = Vector2i(20, 30)
	thrower.clear_path()
	_park_friendlies_away(game_state, Team.USA, 1)
	var cmd := GrenadeCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = Vector2i(26, 30) ## manhattan 6 > recovered throw_range 5
	var result := ActionResolverClass.execute_grenade(
		game_state,
		cmd,
		CommandContextClass.new(),
	)
	_assert(
		"Grenade throws beyond 5 tiles are refused",
		not result.success,
		result.status_message,
	)
	cmd.target_cell = Vector2i(25, 30) ## manhattan 5 == max
	result = ActionResolverClass.execute_grenade(
		game_state,
		cmd,
		CommandContextClass.new(),
	)
	_assert("Grenade throw at exactly 5 tiles succeeds", result.success, result.status_message)


func _test_stress_model() -> void:
	GameplayPolicies.reset_all_to_defaults()
	var SuppressionPolicyClass := preload("res://scripts/gameplay_policies/suppression_policy.gd")
	var policy := GameplayPolicies.suppression
	_assert(
		"STRESS_SCALE is single conversion constant",
		is_equal_approx(SuppressionPolicyClass.STRESS_SCALE, 100.0 / 7.0),
	)
	_assert(
		"Exp-Str table includes fifth +8 tier",
		policy._tier_keys.size() == 5
		and is_equal_approx(policy._tier_keys[0], -8.0)
		and is_equal_approx(policy._tier_keys[4], 8.0),
		"keys=%s" % str(policy._tier_keys),
	)

	var thompson := GameplayPolicies.weapons.create_weapon("thompson")
	var garand := GameplayPolicies.weapons.create_weapon("m1_garand")
	var bar := GameplayPolicies.weapons.create_weapon("bar")
	## Stage 3 expected original magnitudes: (limit − range) × StressFactor.
	var cases: Array[Dictionary] = [
		{"w": garand, "r": 5, "orig": 5.0},
		{"w": garand, "r": 12, "orig": 3.25},
		{"w": garand, "r": 20, "orig": 1.25},
		{"w": thompson, "r": 5, "orig": 16.0},
		{"w": thompson, "r": 12, "orig": 2.0},
		{"w": thompson, "r": 20, "orig": 0.0},
		{"w": bar, "r": 5, "orig": 12.0},
		{"w": bar, "r": 12, "orig": 7.8},
		{"w": bar, "r": 20, "orig": 3.0},
	]
	for case in cases:
		var weapon: WeaponData = case.w
		var range_tiles: int = int(case.r)
		var expected_orig: float = float(case.orig)
		var runtime := policy.range_suppression_gain_runtime(
			weapon.suppression_generated,
			weapon.stress_limit_tiles,
			range_tiles,
		)
		var expected_runtime := expected_orig * SuppressionPolicyClass.STRESS_SCALE
		_assert(
			"%s suppression at range %d" % [weapon.weapon_id, range_tiles],
			is_equal_approx(runtime, expected_runtime),
			"got=%.4f expected=%.4f (orig %.2f)" % [runtime, expected_runtime, expected_orig],
		)
	var smg_close := policy.range_suppression_gain_runtime(
		thompson.suppression_generated, thompson.stress_limit_tiles, 5
	)
	var rifle_close := policy.range_suppression_gain_runtime(
		garand.suppression_generated, garand.stress_limit_tiles, 5
	)
	_assert(
		"SMG fire generates more suppression than rifle fire at close range",
		smg_close > rifle_close,
		"smg=%.3f rifle=%.3f" % [smg_close, rifle_close],
	)
	_assert(
		"SMG suppression cuts off at stress_limit_tiles",
		is_equal_approx(
			policy.range_suppression_gain_runtime(
				thompson.suppression_generated, thompson.stress_limit_tiles, 13
			),
			0.0,
		),
	)
	var smg_cap := policy.weapon_stress_cap_runtime(thompson.stress_limit)
	var lmg_cap := policy.weapon_stress_cap_runtime(bar.stress_limit)
	_assert(
		"LMG stress cap is higher than SMG cap",
		lmg_cap > smg_cap,
		"lmg=%.1f smg=%.1f" % [lmg_cap, smg_cap],
	)

	## Calm vs stressed: long-range accuracy falls harder than point-blank.
	var calm_near := policy.accuracy_modifier_for(0.0, 0, 1.0)
	var stressed_near := policy.accuracy_modifier_for(100.0, 0, 1.0)
	var calm_far := policy.accuracy_modifier_for(0.0, 6, 1.0)
	var stressed_far := policy.accuracy_modifier_for(100.0, 6, 1.0)
	var near_ratio := stressed_near / maxf(calm_near, 0.0001)
	var far_ratio := stressed_far / maxf(calm_far, 0.0001)
	_assert(
		"Stress hurts long-range accuracy more than point-blank",
		far_ratio < near_ratio,
		"near_ratio=%.3f far_ratio=%.3f" % [near_ratio, far_ratio],
	)

	## Decay: retain 0.3 over one reference period; short scans only apply a fraction.
	var one_period := policy.apply_stress_decay(50.0, false, policy.decay_reference_sec)
	_assert(
		"One reference period retains INITStressFallMultiplier",
		is_equal_approx(one_period, 50.0 * policy.stress_fall_multiplier),
		"got=%.3f" % one_period,
	)
	var half_scan := policy.apply_stress_decay(50.0, false, 0.5)
	_assert(
		"0.5s scan decays far less than a full period",
		half_scan > one_period and half_scan < 50.0,
		"scan=%.3f period=%.3f" % [half_scan, one_period],
	)
	var fully := 50.0
	## ~60s of idle scans (0.5s) should drain to ~0.
	for _i in 120:
		fully = policy.apply_stress_decay(fully, false, 0.5)
	_assert("Stress decays to 0 when idle long enough", fully < 0.5, "fully=%.5f" % fully)

	## Scale: OG break at 7 ↔ runtime 100; HUD % is runtime directly.
	_assert(
		"OG 7 maps to runtime 100",
		is_equal_approx(policy.to_runtime(7.0), 100.0),
	)
	_assert(
		"Runtime 100 maps back to OG 7",
		is_equal_approx(policy.to_original(100.0), 7.0),
	)

	## Squad-pace accrual: two rifle gains per cycle with scan decay stays in mid band.
	var stress := 0.0
	var rifle_gain := policy.range_suppression_gain_runtime(
		garand.suppression_generated, garand.stress_limit_tiles, 10
	)
	for _cycle in 12: ## ~66s of two-rifle exchange
		stress = minf(policy.max_stress, stress + rifle_gain)
		for _scan in 5: ## ~2.5s until next overlapping shot
			stress = policy.apply_stress_decay(stress, false, 0.5)
	var og_band := policy.to_original(stress)
	_assert(
		"Sustained two-rifle fire reaches OG stress band 3–7",
		og_band >= 3.0 and og_band <= 7.0,
		"stress=%.1f og=%.2f gain=%.1f" % [stress, og_band, rifle_gain],
	)
	var smg_gain := policy.range_suppression_gain_runtime(
		thompson.suppression_generated, thompson.stress_limit_tiles, 8
	)
	## Without a per-weapon accumulation cap, one close SMG shot reaches break (OG 7).
	_assert(
		"Close SMG gain is at least max_stress (can pin in one shot)",
		smg_gain >= policy.max_stress,
		"smg_gain=%.1f" % smg_gain,
	)
	_assert(
		"SMG accumulation is not clipped by StressLimit cap mapping",
		is_equal_approx(minf(policy.max_stress, smg_gain), policy.max_stress),
	)

	## Tier mapping is one documented function.
	var tier_calm := policy.effective_tier_from_stress(0.0)
	var tier_max := policy.effective_tier_from_stress(100.0)
	_assert(
		"effective_tier falls as stress rises",
		tier_calm > tier_max,
		"calm=%.2f max=%.2f" % [tier_calm, tier_max],
	)


func _test_fixed_simulation_tick() -> void:
	_bootstrap()
	SimulationClock.reset()
	SimulationClock.reset_tick_defaults()
	_assert("Tick hz is 20", SimulationClock.tick_hz == SimulationClock.DEFAULT_TICK_HZ)
	_assert("Tick msec is 50", SimulationClock.tick_msec() == 50)
	## 10 ticks = 500 ms = one combat scan interval at default policy.
	for _i in 10:
		SimulationClock.advance_tick()
	_assert(
		"10 ticks advance exactly 500 msec",
		SimulationClock.get_ticks_msec() == 500,
		"msec=%d" % SimulationClock.get_ticks_msec(),
	)
	## Combat scan cadence stays 0.5s of sim time (not every tick).
	var scan_msec := int(round(GameplayPolicies.hit.auto_fire_scan_interval * 1000.0))
	_assert("Combat scan interval still 500 msec", scan_msec == 500)
	_assert(
		"Combat scans per second unchanged at 2 Hz",
		scan_msec / SimulationClock.tick_msec() == 10,
		"ticks_per_scan=%d" % (scan_msec / SimulationClock.tick_msec()),
	)


func _test_movement_frame_rate_independence() -> void:
	## Same seed + same sim time ⇒ identical movement tiles regardless of render FPS.
	var fps_list: Array[int] = [30, 60, 120, 240]
	var timelines: Array[Dictionary] = []
	for fps in fps_list:
		timelines.append(_simulate_move_timeline_at_fps(fps))

	var reference: Dictionary = timelines[0]
	_assert(
		"Frame-rate move timelines are non-empty",
		not (reference.get("tiles", []) as Array).is_empty(),
	)
	for i in range(1, timelines.size()):
		var other: Dictionary = timelines[i]
		_assert(
			"Movement tiles identical at %d FPS vs 30 FPS" % fps_list[i],
			reference.get("tiles", []) == other.get("tiles", []),
			"ref=%s other=%s" % [reference.get("tiles", []), other.get("tiles", [])],
		)
		_assert(
			"Final cell identical at %d FPS vs 30 FPS" % fps_list[i],
			reference.get("final_cell", Vector2i(-1, -1)) == other.get("final_cell", Vector2i(-1, -1)),
		)
		_assert(
			"Completion sim msec identical at %d FPS vs 30 FPS" % fps_list[i],
			int(reference.get("complete_msec", -1)) == int(other.get("complete_msec", -2)),
			"ref=%s other=%s" % [reference.get("complete_msec", -1), other.get("complete_msec", -2)],
		)
		_assert(
			"RNG snapshot identical at %d FPS after move" % fps_list[i],
			reference.get("rng_snapshot", {}) == other.get("rng_snapshot", {}),
		)


func _simulate_move_timeline_at_fps(fps: int) -> Dictionary:
	_bootstrap()
	SimulationClock.reset()
	GameRandom.begin_match(GameRandom.DEFAULT_SEED)
	var game_state := _make_game_state()
	var soldier := game_state.get_soldier(Team.USA, 1)
	var start := soldier.grid_position
	var target := start + Vector2i(3, 0)
	if not game_state.map_data.is_walkable(target):
		target = start + Vector2i(0, 3)

	var cmd := MoveCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = target
	cmd.movement_mode = MovementModeClass.RUN
	cmd.scope = MoveCommandClass.Scope.SINGLE
	var order := ActionResolverClass.execute_move(game_state, cmd, _path_context(game_state.map_data))
	if not order.success:
		return {"tiles": [], "final_cell": Vector2i(-1, -1), "complete_msec": -1, "rng_snapshot": {}}

	var frame_delta := 1.0 / float(fps)
	var accum := 0.0
	var tick_sec := SimulationClock.tick_sec()
	var tiles: Array[Vector2i] = [soldier.grid_position]
	var complete_msec := -1
	var guard := 0
	while soldier.is_moving and guard < 200000:
		guard += 1
		accum += frame_delta
		while accum >= tick_sec:
			accum -= tick_sec
			SimulationClock.advance_tick()
			var move_result := ActionResolverClass.process_movement_tick(game_state)
			for step in move_result.movement_steps:
				tiles.append(step.tile)
			if not move_result.movement_completions.is_empty() and complete_msec < 0:
				complete_msec = SimulationClock.get_ticks_msec()

	return {
		"tiles": tiles,
		"final_cell": soldier.grid_position,
		"complete_msec": complete_msec,
		"rng_snapshot": GameRandom.get_snapshot(),
	}


func _test_object_id_and_registry() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var soldier := game_state.get_soldier(Team.USA, 1)
	var expected_id := ObjectId.soldier(Team.USA, 1)
	_assert(
		"Soldier object_id is stable",
		soldier.object_id == expected_id and expected_id == "soldier:1:1",
		"object_id=%s expected=%s" % [soldier.object_id, expected_id],
	)
	var via_registry := game_state.objects.get_soldier(expected_id)
	var via_game_state := game_state.get_soldier_by_id(expected_id)
	_assert(
		"Soldier resolves via GameState.objects",
		via_registry == soldier and via_game_state == soldier,
		"registry=%s game_state=%s" % [via_registry != null, via_game_state != null],
	)


func _test_map_object_registry() -> void:
	_bootstrap()
	var map_data := MapDataClass.create_default()
	for cell in map_data.get_object_cells():
		map_data.clear_object(cell)
	var game_state := _make_game_state(map_data)
	var cell := Vector2i(12, 14)
	map_data.set_object(cell, MapObjectRegistryClass.TYPE_TREE)
	game_state.objects.register_map_object(cell, MapObjectRegistryClass.TYPE_TREE)
	var oid := ObjectId.map_object(cell)
	var entry := game_state.objects.get_map_object(oid)
	var at_cell := game_state.objects.get_map_object_at(cell)
	_assert(
		"Map object registers at cell",
		game_state.objects.has(oid)
		and entry.get("type_id", "") == MapObjectRegistryClass.TYPE_TREE
		and at_cell.get("cell", Vector2i(-1, -1)) == cell,
		"oid=%s entry=%s" % [oid, str(entry)],
	)


func _test_grenade_object_registry() -> void:
	_bootstrap()
	var game_state := _make_game_state()
	var thrower := game_state.get_soldier(Team.USA, 1)
	thrower.grid_position = Vector2i(20, 30)
	thrower.clear_path()
	_park_friendlies_away(game_state, Team.USA, 1)
	var target_cell := Vector2i(24, 30)
	var grenade_id := ObjectId.grenade(Team.USA, 1)

	var cmd := GrenadeCommandClass.new()
	cmd.team_id = Team.USA
	cmd.soldier_id = 1
	cmd.target_cell = target_cell
	var result := ActionResolverClass.execute_grenade(
		game_state,
		cmd,
		CommandContextClass.new(),
	)
	_assert("Grenade registry registers on throw", result.success, result.status_message)
	var pending := game_state.objects.get_grenade(grenade_id)
	_assert(
		"Grenade object present while fuse armed",
		pending != null
		and pending.target_cell == target_cell
		and game_state.objects.kind_of(grenade_id) == ObjectRegistry.KIND_GRENADE,
		"pending=%s" % [pending != null],
	)

	SimulationClock.advance_msec(GameplayPolicies.grenade.fuse_msec + 1)
	ActionResolverClass.process_combat_tick(game_state)
	_assert(
		"Grenade object clears on detonation",
		game_state.objects.get_grenade(grenade_id) == null
		and not game_state.objects.has(grenade_id),
		"still_registered=%s" % game_state.objects.has(grenade_id),
	)


func _test_team_soldier_key_consistent() -> void:
	_assert(
		"team_soldier_key matches Team.soldier_key",
		ObjectId.team_soldier_key(Team.USA, 2) == Team.soldier_key(Team.USA, 2)
		and ObjectId.team_soldier_key(Team.USA, 2) == "1:2"
		and SoldierState.enemy_tracking_key(Team.GERMANY, 3) == "2:3",
		"keys diverge",
	)


func _test_perception_cache_incremental() -> void:
	_bootstrap()
	const PerceptionCacheClass := preload("res://scripts/combat/perception_cache.gd")
	PerceptionCacheClass.clear_all()
	PerceptionCacheClass.reset_counters()
	var game_state := _make_game_state()
	var usa := game_state.get_soldier(Team.USA, 1)
	var ger := game_state.get_soldier(Team.GERMANY, 1)
	## Place within close-force distance on open ground.
	usa.grid_position = Vector2i(20, 30)
	ger.grid_position = Vector2i(24, 30)
	usa.facing_direction = Vector2i(1, 0)
	ger.facing_direction = Vector2i(-1, 0)

	var score1 := CombatSystemClass.get_visibility_score(usa, ger, game_state)
	var misses_after_first := PerceptionCacheClass.spot_cache_misses
	var los_after_first := PerceptionCacheClass.los_evals
	var score2 := CombatSystemClass.get_visibility_score(usa, ger, game_state)
	_assert(
		"Perception cache hit on unchanged pair",
		score1 == score2 and PerceptionCacheClass.spot_cache_hits >= 1,
		"score1=%s score2=%s hits=%d" % [score1, score2, PerceptionCacheClass.spot_cache_hits],
	)
	_assert(
		"Perception cache avoids second LOS",
		PerceptionCacheClass.los_evals == los_after_first,
		"los grew from %d to %d" % [los_after_first, PerceptionCacheClass.los_evals],
	)

	## Moving one soldier dirties only pairs involving that soldier.
	PerceptionCacheClass.reset_counters()
	usa.grid_position = Vector2i(21, 30)
	CombatSystemClass.notify_soldier_perception_dirty(game_state, usa)
	var dirty_after_move := PerceptionCacheClass.dirty_count()
	_assert(
		"Dirty queue enqueues affected pairs only",
		dirty_after_move > 0 and dirty_after_move <= 64,
		"dirty=%d misses_first=%d" % [dirty_after_move, misses_after_first],
	)
	CombatSystemClass.process_perception_tick(game_state)
	_assert(
		"Dirty budget processes pairs",
		PerceptionCacheClass.dirty_processed > 0,
		"processed=%d remaining=%d" % [
			PerceptionCacheClass.dirty_processed,
			PerceptionCacheClass.dirty_count(),
		],
	)
	print(
		"[Profiler baseline] perception incremental: dirty_enqueued=%d dirty_done=%d los=%d spotHit=%d"
		% [
			PerceptionCacheClass.dirty_enqueued,
			PerceptionCacheClass.dirty_processed,
			PerceptionCacheClass.los_evals,
			PerceptionCacheClass.spot_cache_hits,
		]
	)


func _test_timed_deployment_zone_lock() -> void:
	_bootstrap()
	const ScenarioRulesClass := preload("res://scripts/core/scenario_rules.gd")
	const MatchConfigClass := preload("res://scripts/core/match_config.gd")
	var game_state := _make_game_state()
	game_state.begin_timed_deployment(ScenarioRulesClass.DEPLOYMENT_TIME_SEC)
	_assert("Timed deploy locks zone", game_state.locks_deployment_zone())
	_assert(
		"Timed deploy countdown is 15s",
		is_equal_approx(game_state.deployment_time_remaining_sec, 15.0),
		"remaining=%s" % game_state.deployment_time_remaining_sec,
	)

	var soldier := game_state.get_soldier(Team.USA, 1)
	var start := soldier.grid_position
	_assert(
		"Soldier starts in USA deploy zone",
		game_state.map_data.is_deployment_cell(Team.USA, start),
		"cell=%s" % start,
	)

	## Find a walkable cell outside the USA spawn zone.
	var outside := Vector2i(-999, -999)
	for y in range(game_state.map_data.height):
		for x in range(game_state.map_data.width):
			var cell := Vector2i(x, y)
			if (
				game_state.map_data.is_walkable(cell)
				and not game_state.map_data.is_deployment_cell(Team.USA, cell)
			):
				outside = cell
				break
		if outside.x > -900:
			break
	_assert("Found walkable cell outside deploy zone", outside.x > -900, "cell=%s" % outside)

	var leave_cmd := MoveCommandClass.new()
	leave_cmd.team_id = Team.USA
	leave_cmd.soldier_id = 1
	leave_cmd.target_cell = outside
	leave_cmd.movement_mode = MovementModeClass.RUN
	leave_cmd.scope = MoveCommandClass.Scope.SINGLE
	var leave_result := ActionResolverClass.execute_move(
		game_state, leave_cmd, _path_context(game_state.map_data)
	)
	_assert(
		"Cannot leave deploy zone during countdown",
		not leave_result.success,
		leave_result.status_message,
	)

	## In-zone reposition still allowed.
	var in_zone := start
	for cell in game_state.map_data.team_1_spawn_points:
		if cell != start and game_state.map_data.is_walkable(cell):
			in_zone = cell
			break
	if in_zone != start:
		var stay_cmd := MoveCommandClass.new()
		stay_cmd.team_id = Team.USA
		stay_cmd.soldier_id = 1
		stay_cmd.target_cell = in_zone
		stay_cmd.movement_mode = MovementModeClass.RUN
		stay_cmd.scope = MoveCommandClass.Scope.SINGLE
		var stay_result := ActionResolverClass.execute_move(
			game_state, stay_cmd, _path_context(game_state.map_data)
		)
		_assert(
			"Can move inside deploy zone during countdown",
			stay_result.success,
			stay_result.status_message,
		)

	## Countdown ending starts Scenario Running.
	var ended := ScenarioRulesClass.process_deployment_tick(game_state, 15.0)
	_assert("Deploy countdown ends scenario start", ended)
	_assert("Match is running after deploy", not game_state.is_deployment_phase())
	_assert("Zone lock clears after deploy", not game_state.locks_deployment_zone())

	var offline_cfg: MatchConfigClass = MatchConfigClass.default_offline_1v1() as MatchConfigClass
	_assert("Offline 1v1 skips timed deployment", not offline_cfg.timed_deployment)
	var sp_cfg: MatchConfigClass = MatchConfigClass.default_single_player_1v1() as MatchConfigClass
	_assert("Single Player uses timed deployment", sp_cfg.timed_deployment)
	var ger_ai_name := ""
	for slot in sp_cfg.slots:
		if int(slot.get("team_id", -1)) == Team.GERMANY:
			ger_ai_name = str(slot.get("display_name", ""))
			break
	_assert("SP Germany AI is GE Player 1", ger_ai_name == "GE Player 1", ger_ai_name)
	var two_v_two: MatchConfigClass = MatchConfigClass.new(
		MatchConfigClass.GameModeKind.SINGLE_PLAYER,
		MatchConfigClass.MatchType.TWO_V_TWO,
	) as MatchConfigClass
	var usa_ai := ""
	var ge_p2 := ""
	for slot in two_v_two.slots:
		if (
			int(slot.get("team_id", -1)) == Team.USA
			and int(slot.get("controller", -1)) == MatchConfigClass.ControllerType.AI
		):
			usa_ai = str(slot.get("display_name", ""))
		if (
			int(slot.get("team_id", -1)) == Team.GERMANY
			and int(slot.get("slot_index", -1)) == 1
		):
			ge_p2 = str(slot.get("display_name", ""))
	_assert("2v2 USA AI is USA AI Player 2", usa_ai == "USA AI Player 2", usa_ai)
	_assert("2v2 GER slot 2 is GE Player 2", ge_p2 == "GE Player 2", ge_p2)


func _test_scenario_clock_and_scoring() -> void:
	_bootstrap()
	const ScenarioRulesClass := preload("res://scripts/core/scenario_rules.gd")
	const ScenarioEndCauseClass := preload("res://scripts/enums/scenario_end_cause.gd")
	const ScenarioWinnerClass := preload("res://scripts/enums/scenario_winner.gd")
	var game_state := _make_game_state()
	game_state.map_data.victory_points = [
		{
			"name": "Test VP",
			"x": 20,
			"y": 30,
			"us_points": 100.0,
			"gm_points": 50.0,
			"initial_holder": "Germany",
		},
	]
	game_state.begin_running_phase()
	_assert(
		"Scenario clock starts at 15:00",
		is_equal_approx(game_state.time_remaining(), float(ScenarioRulesClass.SCENARIO_TIME_SEC)),
		"remaining=%s" % game_state.time_remaining(),
	)

	## Advance 2 sim seconds via ScenarioRules ticks.
	var tick := SimulationClock.tick_sec()
	for _i in range(int(round(2.0 / tick))):
		ScenarioRulesClass.process_tick(game_state, tick)
	_assert(
		"Scenario clock decrements via sim ticks",
		game_state.time_remaining() < float(ScenarioRulesClass.SCENARIO_TIME_SEC) - 1.5,
		"remaining=%s" % game_state.time_remaining(),
	)

	var victim := game_state.get_soldier(Team.GERMANY, 1)
	ScenarioRulesClass.on_soldier_killed(game_state, Team.USA, victim)
	_assert(
		"Kill awards +4 to killer team",
		int(game_state.team_kill_points.get(Team.USA, 0)) == ScenarioRulesClass.KILL_POINTS,
		"usa_kills=%s" % game_state.team_kill_points.get(Team.USA, 0),
	)
	_assert(
		"Victim team loses 1 point",
		int(game_state.team_kill_points.get(Team.GERMANY, 0)) == -ScenarioRulesClass.PP_LOST_PER_SOLDIER,
		"ger_kills=%s" % game_state.team_kill_points.get(Team.GERMANY, 0),
	)

	## Early capture locks a higher decay multiplier than late capture.
	var early := ScenarioRulesClass.effective_vp_award(100.0, 0.0)
	var late := ScenarioRulesClass.effective_vp_award(100.0, float(ScenarioRulesClass.SCENARIO_TIME_SEC))
	_assert(
		"VP decay makes early capture worth more",
		early > late,
		"early=%d late=%d" % [early, late],
	)

	## Extermination: wipe Germany.
	for state in game_state.session.get_fireteam(Team.GERMANY).soldiers:
		var s: SoldierState = state
		if s != null and not s.is_dead:
			s.mark_killed()
	var ended := ScenarioRulesClass.process_tick(game_state, 0.0)
	_assert("Extermination ends scenario", ended and game_state.scenario_ended, "ended=%s" % ended)
	_assert(
		"Extermination winner is USA",
		game_state.winner == ScenarioWinnerClass.USA,
		"winner=%s" % game_state.winner,
	)
	_assert(
		"Extermination cause is EXTERMINATION",
		game_state.end_cause == ScenarioEndCauseClass.EXTERMINATION,
		"cause=%s" % game_state.end_cause,
	)

	## Fresh state for TIME_GONE.
	var timed := _make_game_state()
	timed.map_data.victory_points = game_state.map_data.victory_points.duplicate(true)
	timed.begin_running_phase()
	timed.scenario_elapsed_sec = float(ScenarioRulesClass.SCENARIO_TIME_SEC)
	timed.scenario_time_remaining_sec = 0.0
	var time_ended := ScenarioRulesClass.process_tick(timed, 0.0)
	_assert("TIME_GONE ends scenario", time_ended and timed.scenario_ended, "ended=%s" % time_ended)
	_assert(
		"TIME_GONE cause recorded separately from winner",
		timed.end_cause == ScenarioEndCauseClass.TIME_GONE,
		"cause=%s" % timed.end_cause,
	)


func _test_build_config_editor_is_development() -> void:
	## Custom feature `survival_playtest` is only set on the playtest export preset.
	_assert("Editor / F5 run is development", BuildConfig.is_development())
	_assert("Editor / F5 run is not survival playtest", not BuildConfig.is_survival_playtest())
