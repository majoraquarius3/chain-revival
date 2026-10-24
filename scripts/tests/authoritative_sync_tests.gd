extends Node
## Headless tests for applying server face / stance / move results on both replicas.
## Run: Godot --headless --path <project> res://scripts/tests/authoritative_sync_tests.tscn

const MapDataClass := preload("res://scripts/map/map_data.gd")
const GameSessionClass := preload("res://scripts/core/game_session.gd")
const ActionResolverClass := preload("res://scripts/core/action_resolver.gd")
const AuthoritativeSyncClass := preload("res://scripts/network/authoritative_sync.gd")
const ActionResultClass := preload("res://scripts/core/action_result.gd")
const PositionStateClass := preload("res://scripts/enums/position_state.gd")
const MovementModeClass := preload("res://scripts/enums/movement_mode.gd")

var _failed: int = 0
var _passed: int = 0


func _ready() -> void:
	SimulationClock.reset()
	GameRandom.reseed(GameRandom.DEFAULT_SEED)
	GameplayPolicies.reset_all_to_defaults()
	_test_face_result_both_replicas()
	_test_position_result_both_replicas()
	_test_move_result_stance_and_mode()
	_test_snapshot_restores_facing_stance_mode()
	_test_fire_control_and_target_both_replicas()
	_test_combat_status_both_replicas()
	print("")
	print("Authoritative sync tests: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _assert(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("[PASS] %s" % name)
	else:
		_failed += 1
		print("[FAIL] %s — %s" % [name, detail if not detail.is_empty() else "assertion failed"])


func _make_game_state() -> GameState:
	var map_data: MapDataClass = MapDataClass.create_default()
	var session := GameSessionClass.new(
		map_data.team_1_spawn_points,
		map_data.team_2_spawn_points,
	)
	var game_state := session.create_game_state(map_data)
	ActionResolverClass.apply_match_start_setup(game_state)
	return game_state


func _test_face_result_both_replicas() -> void:
	var usa := _make_game_state()
	var germany := _make_game_state()
	var payload := {
		"success": true,
		"statusMessage": "USA Soldier 1 facing EAST.",
		"faceUpdates": [
			{"teamId": Team.USA, "soldierId": 1, "facing": {"x": 1, "y": 0}},
		],
	}
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	AuthoritativeSyncClass.apply_face_result(usa, result)
	AuthoritativeSyncClass.apply_face_result(germany, result)
	var a: SoldierState = usa.get_soldier(Team.USA, 1)
	var b: SoldierState = germany.get_soldier(Team.USA, 1)
	_assert("face both replicas", a.facing_direction == Vector2i(1, 0) and a.facing_direction == b.facing_direction)


func _test_position_result_both_replicas() -> void:
	var usa := _make_game_state()
	var germany := _make_game_state()
	var payload := {
		"success": true,
		"statusMessage": "Soldier 1 changed to DOWN",
		"soldierUpdates": [
			{
				"teamId": Team.USA,
				"soldierId": 1,
				"facing": {"x": 0, "y": -1},
				"positionState": PositionStateClass.DOWN,
				"movementMode": MovementModeClass.RUN,
			},
		],
		"stanceTransitionOrders": [
			{"teamId": Team.USA, "soldierId": 1, "targetPositionState": PositionStateClass.DOWN},
		],
		"movementHalts": [],
	}
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	AuthoritativeSyncClass.apply_position_result(usa, result)
	AuthoritativeSyncClass.apply_position_result(germany, result)
	var a: SoldierState = usa.get_soldier(Team.USA, 1)
	var b: SoldierState = germany.get_soldier(Team.USA, 1)
	_assert(
		"stance both replicas",
		a.position_state == PositionStateClass.DOWN
		and b.position_state == PositionStateClass.DOWN
		and a.pending_position_state == PositionStateClass.DOWN
		and b.pending_position_state == PositionStateClass.DOWN,
	)


func _test_move_result_stance_and_mode() -> void:
	var usa := _make_game_state()
	var germany := _make_game_state()
	var start: Vector2i = usa.get_soldier(Team.USA, 1).grid_position
	var dest := start + Vector2i(1, 0)
	var payload := {
		"success": true,
		"statusMessage": "run",
		"moveOrders": [
			{
				"teamId": Team.USA,
				"soldierId": 1,
				"path": [{"x": start.x, "y": start.y}, {"x": dest.x, "y": dest.y}],
				"speedMult": 2.0,
				"movementMode": MovementModeClass.WALK,
				"positionState": PositionStateClass.UP,
			},
		],
		"movementHalts": [],
		"soldierUpdates": [
			{
				"teamId": Team.USA,
				"soldierId": 1,
				"facing": {"x": 1, "y": 0},
				"positionState": PositionStateClass.UP,
				"movementMode": MovementModeClass.WALK,
			},
		],
	}
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	AuthoritativeSyncClass.apply_move_result(usa, result)
	AuthoritativeSyncClass.apply_move_result(germany, result)
	var a: SoldierState = usa.get_soldier(Team.USA, 1)
	var b: SoldierState = germany.get_soldier(Team.USA, 1)
	_assert(
		"move mode both replicas",
		a.movement_mode == MovementModeClass.WALK
		and b.movement_mode == MovementModeClass.WALK
		and a.position_state == PositionStateClass.UP
		and a.is_moving
		and b.is_moving,
	)


func _test_snapshot_restores_facing_stance_mode() -> void:
	var game_state := _make_game_state()
	var snapshot := {
		"soldiers": [
			{
				"teamId": Team.USA,
				"soldierId": 1,
				"gridPosition": {"x": 3, "y": 4},
				"facing": {"x": -1, "y": 1},
				"positionState": PositionStateClass.DOWN,
				"movementMode": MovementModeClass.CRAWL,
				"isDead": false,
				"isMoving": false,
				"currentPath": [],
				"pathIndex": 0,
				"moveSpeedMult": 0.3,
			},
		],
	}
	AuthoritativeSyncClass.apply_snapshot(game_state, snapshot)
	var soldier: SoldierState = game_state.get_soldier(Team.USA, 1)
	_assert("snapshot facing", soldier.facing_direction == Vector2i(-1, 1))
	_assert("snapshot stance", soldier.position_state == PositionStateClass.DOWN)
	_assert("snapshot movementMode", soldier.movement_mode == MovementModeClass.CRAWL)


func _test_fire_control_and_target_both_replicas() -> void:
	var usa := _make_game_state()
	var germany := _make_game_state()
	var payload := {
		"success": true,
		"statusMessage": "Priority target Germany Soldier 1.",
		"syncFireAtUi": true,
		"targetUpdates": [
			{
				"teamId": Team.USA,
				"soldierId": 1,
				"fireControlState": FireControlState.FIRE_AT_WILL,
				"engagedTargetTeamId": Team.GERMANY,
				"engagedTargetSoldierId": 1,
				"sustainedFire": true,
			},
		],
		"faceUpdates": [],
		"movementHalts": [],
	}
	var result: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(payload)
	AuthoritativeSyncClass.apply_target_result(usa, result)
	AuthoritativeSyncClass.apply_target_result(germany, result)
	var a: SoldierState = usa.get_soldier(Team.USA, 1)
	var b: SoldierState = germany.get_soldier(Team.USA, 1)
	_assert(
		"fire-at both replicas",
		a.sustained_fire
		and b.sustained_fire
		and a.engaged_target_soldier_id == 1
		and b.engaged_target_soldier_id == 1
		and a.fire_control_state == FireControlState.FIRE_AT_WILL,
	)
	var hold_payload := {
		"success": true,
		"statusMessage": "Hold Fire",
		"syncFireAtUi": true,
		"targetUpdates": [
			{
				"teamId": Team.USA,
				"soldierId": 1,
				"fireControlState": FireControlState.HOLD_FIRE,
				"engagedTargetTeamId": -1,
				"engagedTargetSoldierId": -1,
				"sustainedFire": false,
			},
		],
	}
	var hold: ActionResultClass = AuthoritativeSyncClass.action_result_from_payload(hold_payload)
	AuthoritativeSyncClass.apply_target_result(usa, hold)
	AuthoritativeSyncClass.apply_target_result(germany, hold)
	_assert(
		"hold-fire both replicas",
		a.fire_control_state == FireControlState.HOLD_FIRE
		and b.fire_control_state == FireControlState.HOLD_FIRE
		and not a.is_engaged()
		and not b.is_engaged(),
	)


func _test_combat_status_both_replicas() -> void:
	var usa := _make_game_state()
	var germany := _make_game_state()
	var payload := {
		"simMsec": 1000,
		"updates": [
			{
				"teamId": Team.GERMANY,
				"soldierId": 1,
				"stress": 71.428571,
				"receivedSuppression": true,
				"stunnedUntilMsec": 5000,
				"standOnStunRecovery": true,
				"positionState": PositionStateClass.DOWN,
				"movementMode": MovementModeClass.CRAWL,
				"isMoving": false,
				"engagedTargetTeamId": -1,
				"engagedTargetSoldierId": -1,
				"sustainedFire": false,
			},
		],
	}
	AuthoritativeSyncClass.apply_combat_status(usa, payload)
	AuthoritativeSyncClass.apply_combat_status(germany, payload)
	var a: SoldierState = usa.get_soldier(Team.GERMANY, 1)
	var b: SoldierState = germany.get_soldier(Team.GERMANY, 1)
	_assert(
		"combat status both replicas",
		is_equal_approx(a.stress, b.stress)
		and a.received_suppression_this_tick
		and b.stunned_until_msec == 5000
		and a.position_state == PositionStateClass.DOWN
		and b.movement_mode == MovementModeClass.CRAWL
		and a.stand_on_stun_recovery,
	)
