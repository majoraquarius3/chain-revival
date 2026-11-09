extends Node
## Shared parity fixtures (scripts/tests/parity/*.json), client side. Single-player is the
## reference: these must pass. server/tests/parity.test.ts runs the same fixtures.
## Run: Godot --headless --path <project> res://scripts/tests/parity_tests.tscn
## Add `-- --print` to print every case's actual result (for writing new fixtures).

const MapDataClass := preload("res://scripts/map/map_data.gd")
const GameSessionClass := preload("res://scripts/core/game_session.gd")
const PositionStateClass := preload("res://scripts/enums/position_state.gd")

const FIXTURE_DIR := "res://scripts/tests/parity"
const MISSING := Vector2i(-999, -999)

var _failed: int = 0
var _passed: int = 0
var _print_mode := false


func _ready() -> void:
	_print_mode = OS.get_cmdline_user_args().has("--print")
	for file_name in _fixture_files():
		var cases: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_DIR.path_join(file_name)))
		if not cases is Array:
			_fail(file_name, "not a JSON array")
			continue
		for raw in cases:
			_run_case(raw as Dictionary)
	print("")
	print("Parity tests: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _fixture_files() -> Array[String]:
	var out: Array[String] = []
	for name in DirAccess.get_files_at(FIXTURE_DIR):
		if name.ends_with(".json"):
			out.append(name)
	out.sort()
	return out


func _run_case(fixture: Dictionary) -> void:
	SimulationClock.reset()
	GameRandom.reseed(GameRandom.DEFAULT_SEED)
	GameplayPolicies.reset_all_to_defaults()
	PerceptionCache.clear_all()
	var name := str(fixture.get("name", "?"))
	var game_state := _build_state(fixture)
	var actual := _evaluate(game_state, fixture.get("query", {}) as Dictionary)
	GameplayPolicies.reset_all_to_defaults()
	if _print_mode:
		print("ACTUAL %s %s" % [name, JSON.stringify(actual)])
	var expect: Dictionary = fixture.get("expect", {})
	if expect.is_empty():
		_fail(name, "no expect values; actual %s" % JSON.stringify(actual))
		return
	var mismatch := _compare(expect, actual)
	if mismatch.is_empty():
		_passed += 1
		print("[PASS] %s" % name)
	else:
		_fail(name, "%s (actual %s)" % [mismatch, JSON.stringify(actual)])


func _fail(name: String, detail: String) -> void:
	_failed += 1
	print("[FAIL] %s - %s" % [name, detail])


func _build_state(fixture: Dictionary) -> GameState:
	var spec: Dictionary = fixture.get("map", {})
	var map: MapData = MapDataClass.new()
	map.width = int(spec.get("width", 30))
	map.height = int(spec.get("height", 30))
	for raw in spec.get("objects", []):
		var obj: Dictionary = raw
		for cell in _object_cells(obj):
			map.set_object(cell, str(obj.get("type", "")))
	var blue: Array[Vector2i] = []
	var red: Array[Vector2i] = []
	for i in range(4):
		blue.append(Vector2i(i, map.height - 1))
		red.append(Vector2i(map.width - 1 - i, map.height - 1))
	map.team_1_spawn_points = blue
	map.team_2_spawn_points = red
	var session := GameSessionClass.new(blue, red)
	var game_state: GameState = session.create_game_state(map)

	var listed := {}
	for raw in fixture.get("soldiers", []):
		var entry: Dictionary = raw
		var soldier: SoldierState = game_state.get_soldier(int(entry.team), int(entry.id))
		listed[soldier] = true
		soldier.clear_path()
		soldier.grid_position = _cell(entry.get("cell"))
		soldier.facing_direction = _cell(entry.get("facing", [0, 1]))
		soldier.position_state = (
			PositionStateClass.DOWN if str(entry.get("stance", "up")) == "down" else PositionStateClass.UP
		)
		soldier.clear_pending_position()
		if entry.has("weapon"):
			soldier.assign_weapon(str(entry.weapon), true)
		soldier.stress = float(entry.get("stress", 0.0))
		soldier.marksman = float(entry.get("marksman", 0.0))
		soldier.sustained_fire = bool(entry.get("sustainedFire", false))
		var engaged: Array = entry.get("engagedTarget", [-1, -1])
		soldier.engaged_target_team_id = int(engaged[0])
		soldier.engaged_target_soldier_id = int(engaged[1])
	for team_id in [Team.USA, Team.GERMANY]:
		for soldier_id in range(1, 5):
			var soldier: SoldierState = game_state.get_soldier(team_id, soldier_id)
			if soldier != null and not listed.has(soldier):
				soldier.mark_killed()
	PerceptionCache.clear_all()
	return game_state


func _evaluate(game_state: GameState, query: Dictionary) -> Dictionary:
	var map: MapData = game_state.map_data
	match str(query.get("kind", "")):
		"los":
			var shooter := _soldier(game_state, query.shooter)
			var target := _soldier(game_state, query.target)
			var los := LOSSystem.evaluate(shooter.grid_position, target.grid_position, map, game_state)
			return {
				"status": los.status,
				"blockingCell": _out_cell(los.blocking_cell),
				"coverType": los.cover_type,
				"cornerPeek": los.corner_peek,
				"peekSide": los.peek_side,
				"cornerCell": _out_cell(los.corner_cell),
				"targetUsingWallCover": los.target_using_wall_cover,
			}
		"cover":
			var shooter := _soldier(game_state, query.shooter)
			var target := _soldier(game_state, query.target)
			var cover = CoverSystem.evaluate_target_cover(shooter.grid_position, target.grid_position, map)
			return {"coverType": int(cover.cover_type)}
		"hit_chance":
			var shooter := _soldier(game_state, query.shooter)
			var target := _soldier(game_state, query.target)
			var los := LOSSystem.evaluate(shooter.grid_position, target.grid_position, map, game_state)
			var chance := CombatSystem._final_hit_chance(
				shooter, target, WeaponRegistry.get_weapon(shooter.weapon_id), los
			)
			return {"chance": snappedf(chance, 0.0001)}
		"suppression":
			var shooter := _soldier(game_state, query.shooter)
			var target := _soldier(game_state, query.target)
			var los := LOSSystem.evaluate(shooter.grid_position, target.grid_position, map, game_state)
			var before := target.stress
			CombatSystem.apply_suppression_from_shot(
				game_state, shooter, target, WeaponRegistry.get_weapon(shooter.weapon_id), los
			)
			return {"gain": snappedf(target.stress - before, 0.01)}
		"stress_decay":
			return {
				"stress": snappedf(
					GameplayPolicies.suppression.apply_stress_decay(
						float(query.get("stress", 0.0)),
						bool(query.get("prone", false)),
						float(query.get("deltaSec", 0.0)),
					),
					0.0001,
				),
			}
		"grenade":
			## Kills use different RNGs on each side; force every hit to a stun.
			GameplayPolicies.hit.lethality_multiplier = 0.0
			var thrower := _soldier(game_state, query.thrower)
			var result = CombatSystem.resolve_grenade(game_state, thrower, _cell(query.cell))
			var stunned: Array = []
			for raw in result.stunned:
				stunned.append([int(raw.team_id), int(raw.soldier_id), snappedf(float(raw.duration_sec), 0.01)])
			stunned.sort_custom(func(a, b): return a[0] * 10 + a[1] < b[0] * 10 + b[1])
			var killed: Array = []
			for raw in result.killed:
				killed.append([int(raw.team_id), int(raw.soldier_id)])
			return {"stunned": stunned, "killed": killed}
		"auto_target":
			var shooter := _soldier(game_state, query.shooter)
			var best: SoldierState = null
			var best_score := -1.0
			for soldier_id in range(1, 5):
				var enemy_team := Team.GERMANY if shooter.team_id == Team.USA else Team.USA
				var enemy: SoldierState = game_state.get_soldier(enemy_team, soldier_id)
				if enemy == null or enemy.is_dead:
					continue
				var score := CombatSystem.score_auto_target(shooter, enemy, game_state)
				if score >= 0.0 and score > best_score:
					best_score = score
					best = enemy
			return {"target": null if best == null else [best.team_id, best.soldier_id]}
		"arrival_facing":
			var facing := CoverSystem.corner_watch_facing(_cell(query.cell), map)
			return {"facing": null if facing == Vector2i.ZERO else [facing.x, facing.y]}
	return {"error": "unknown query kind %s" % str(query.get("kind", ""))}


## Returns "" when equal, else a description. Floats compare with a small tolerance.
func _compare(expect: Variant, actual: Variant, path: String = "") -> String:
	if expect is Dictionary:
		if not actual is Dictionary:
			return "%s: expected object" % path
		for key in expect:
			if not (actual as Dictionary).has(key):
				return "%s.%s missing" % [path, key]
			var diff := _compare(expect[key], actual[key], "%s.%s" % [path, key])
			if not diff.is_empty():
				return diff
		return ""
	if expect is Array:
		if not actual is Array or (actual as Array).size() != (expect as Array).size():
			return "%s: expected %s" % [path, JSON.stringify(expect)]
		for i in range((expect as Array).size()):
			var diff := _compare(expect[i], actual[i], "%s[%d]" % [path, i])
			if not diff.is_empty():
				return diff
		return ""
	if (expect is float or expect is int) and (actual is float or actual is int):
		if absf(float(expect) - float(actual)) > 0.0005:
			return "%s: expected %s" % [path, str(expect)]
		return ""
	if expect != actual:
		return "%s: expected %s" % [path, JSON.stringify(expect)]
	return ""


func _soldier(game_state: GameState, ref: Variant) -> SoldierState:
	var pair: Array = ref
	return game_state.get_soldier(int(pair[0]), int(pair[1]))


func _object_cells(obj: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if obj.has("at"):
		out.append(_cell(obj.at))
		return out
	var a := _cell(obj.get("from"))
	var b := _cell(obj.get("to"))
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			out.append(Vector2i(x, y))
	return out


func _cell(value: Variant) -> Vector2i:
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return MISSING


func _out_cell(cell: Vector2i) -> Variant:
	return null if cell == MISSING else [cell.x, cell.y]
