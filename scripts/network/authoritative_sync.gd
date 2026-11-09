class_name AuthoritativeSync
extends RefCounted
## Apply server GameState snapshots / move results onto the local replica.
## Does not run ActionResolver — the Node server already did.

const ActionResultClass := preload("res://scripts/core/action_result.gd")
const GameStateClass := preload("res://scripts/core/game_state.gd")
const PositionStateClass := preload("res://scripts/enums/position_state.gd")
const FireControlStateClass := preload("res://scripts/enums/fire_control_state.gd")
const CombatShotResultClass := preload("res://scripts/combat/combat_shot_result.gd")

## team_id -> Dictionary of "team:soldier" -> true (authoritative enemy visibility)
static var team_visible: Dictionary = {}


static func apply_visibility(payload: Dictionary) -> void:
	var sides: Variant = payload.get("sides", payload.get("visibility", []))
	if not sides is Array:
		return
	team_visible.clear()
	for raw in sides:
		if not raw is Dictionary:
			continue
		var side: Dictionary = raw
		var team_id := int(side.get("teamId", side.get("team_id", -1)))
		var seen: Dictionary = {}
		for entry in side.get("visible", []):
			if not entry is Dictionary:
				continue
			var enemy: Dictionary = entry
			var key := "%d:%d" % [
				int(enemy.get("teamId", enemy.get("team_id", -1))),
				int(enemy.get("soldierId", enemy.get("soldier_id", -1))),
			]
			seen[key] = true
		team_visible[team_id] = seen


static func is_enemy_visible_to_team(viewer_team_id: int, enemy: SoldierState) -> bool:
	if enemy == null:
		return false
	if enemy.team_id == viewer_team_id:
		return true
	var seen: Variant = team_visible.get(viewer_team_id, {})
	if not seen is Dictionary:
		return false
	return bool((seen as Dictionary).get("%d:%d" % [enemy.team_id, enemy.soldier_id], false))


static func apply_sim_time(payload: Dictionary) -> void:
	var msec := int(payload.get("simMsec", payload.get("sim_msec", -1)))
	if msec >= 0:
		SimulationClock.reset(msec)


static func apply_snapshot(game_state: GameStateClass, snapshot: Dictionary) -> void:
	if game_state == null:
		return
	apply_sim_time(snapshot)
	if snapshot.has("visibility") or snapshot.has("sides"):
		apply_visibility(snapshot)
	var soldiers: Variant = snapshot.get("soldiers", [])
	if not soldiers is Array:
		return
	for raw in soldiers:
		if not raw is Dictionary:
			continue
		var entry: Dictionary = raw
		var team_id := int(entry.get("teamId", entry.get("team_id", -1)))
		var soldier_id := int(entry.get("soldierId", entry.get("soldier_id", -1)))
		var soldier: SoldierState = game_state.get_soldier(team_id, soldier_id)
		if soldier == null:
			continue
		soldier.grid_position = _cell(entry.get("gridPosition", entry.get("grid_position", {})))
		soldier.facing_direction = _cell(entry.get("facing", {}))
		if soldier.facing_direction == Vector2i.ZERO:
			soldier.facing_direction = FacingDirection.NORTH
		soldier.position_state = int(entry.get("positionState", entry.get("position_state", PositionStateClass.UP)))
		soldier.movement_mode = int(entry.get("movementMode", entry.get("movement_mode", MovementMode.RUN)))
		soldier.is_dead = bool(entry.get("isDead", entry.get("is_dead", false)))
		var path := _path(entry.get("currentPath", entry.get("current_path", [])))
		var speed := float(entry.get("moveSpeedMult", entry.get("move_speed_mult", 1.0)))
		if bool(entry.get("isMoving", entry.get("is_moving", false))) and path.size() > 1:
			soldier.assign_path(path, speed)
			soldier.path_index = int(entry.get("pathIndex", entry.get("path_index", 1)))
		else:
			soldier.clear_path()
		if entry.has("fireControlState") or entry.has("fire_control_state"):
			soldier.fire_control_state = int(
				entry.get("fireControlState", entry.get("fire_control_state", FireControlStateClass.FIRE_AT_WILL))
			)
		if entry.has("engagedTargetTeamId") or entry.has("engaged_target_team_id"):
			soldier.engaged_target_team_id = int(
				entry.get("engagedTargetTeamId", entry.get("engaged_target_team_id", -1))
			)
			soldier.engaged_target_soldier_id = int(
				entry.get("engagedTargetSoldierId", entry.get("engaged_target_soldier_id", -1))
			)
		if entry.has("sustainedFire") or entry.has("sustained_fire"):
			soldier.sustained_fire = bool(entry.get("sustainedFire", entry.get("sustained_fire", false)))
		if entry.has("weaponId") or entry.has("weapon_id"):
			var wid := str(entry.get("weaponId", entry.get("weapon_id", "")))
			if not wid.is_empty() and wid != soldier.weapon_id:
				soldier.assign_weapon(wid, false)
		if entry.has("ammoCurrent") or entry.has("ammo_current"):
			soldier.ammo_current = int(entry.get("ammoCurrent", entry.get("ammo_current", soldier.ammo_current)))
		if entry.has("fireReadyAfterMsec") or entry.has("fire_ready_after_msec"):
			soldier.fire_ready_after_msec = int(
				entry.get("fireReadyAfterMsec", entry.get("fire_ready_after_msec", 0))
			)
		if entry.has("lastShotMsec") or entry.has("last_shot_msec"):
			soldier.last_shot_msec = int(entry.get("lastShotMsec", entry.get("last_shot_msec", 0)))
		if entry.has("stress"):
			soldier.stress = float(entry.get("stress", 0.0))
		if entry.has("stunnedUntilMsec") or entry.has("stunned_until_msec"):
			soldier.stunned_until_msec = int(
				entry.get("stunnedUntilMsec", entry.get("stunned_until_msec", 0))
			)
		if entry.has("standOnStunRecovery") or entry.has("stand_on_stun_recovery"):
			soldier.stand_on_stun_recovery = bool(
				entry.get("standOnStunRecovery", entry.get("stand_on_stun_recovery", false))
			)
		if entry.has("deathSpriteFamily") or entry.has("death_sprite_family"):
			soldier.death_sprite_family = str(
				entry.get("deathSpriteFamily", entry.get("death_sprite_family", ""))
			)
		if entry.has("stanceAtDeath") or entry.has("stance_at_death"):
			soldier.stance_at_death = int(
				entry.get("stanceAtDeath", entry.get("stance_at_death", soldier.position_state))
			)


static func apply_combat_shots(game_state: GameStateClass, payload: Dictionary) -> ActionResultClass:
	apply_sim_time(payload)
	var result := ActionResultClass.new()
	result.success = true
	result.refresh_views = true
	for raw in payload.get("shots", []):
		if not raw is Dictionary:
			continue
		var shot: CombatShotResultClass = combat_shot_from_payload(raw)
		result.combat_shots.append(shot)
		if not shot.fired:
			continue
		var shooter: SoldierState = game_state.get_soldier(shot.shooter_team_id, shot.shooter_id)
		if shooter != null:
			var facing := _cell(raw.get("facing", {}))
			if facing != Vector2i.ZERO:
				shooter.facing_direction = FacingDirection.from_step(facing)
			if raw.has("ammoCurrent") or raw.has("ammo_current"):
				shooter.ammo_current = int(raw.get("ammoCurrent", raw.get("ammo_current", shooter.ammo_current)))
			shooter.last_shot_msec = SimulationClock.get_ticks_msec()
			shooter.last_fired_msec = shooter.last_shot_msec
			shooter.fire_ready_after_msec = int(
				raw.get("fireReadyAfterMsec", raw.get("fire_ready_after_msec", shooter.fire_ready_after_msec))
			)
		var target: SoldierState = game_state.get_soldier(shot.target_team_id, shot.target_id)
		if shot.killed and target != null and not target.is_dead:
			target.stance_at_death = int(
				raw.get("stanceAtDeath", raw.get("stance_at_death", target.position_state))
			)
			var family := str(raw.get("deathSpriteFamily", raw.get("death_sprite_family", "")))
			if not family.is_empty():
				target.death_sprite_family = family
			target.mark_killed()
			_clear_engagements_on_dead(game_state, target)
	return result


static func apply_combat_status(game_state: GameStateClass, payload: Dictionary) -> void:
	if game_state == null:
		return
	apply_sim_time(payload)
	for raw in payload.get("updates", []):
		if not raw is Dictionary:
			continue
		var update: Dictionary = raw
		var soldier: SoldierState = game_state.get_soldier(
			int(update.get("teamId", update.get("team_id", -1))),
			int(update.get("soldierId", update.get("soldier_id", -1))),
		)
		if soldier == null:
			continue
		soldier.stress = float(update.get("stress", soldier.stress))
		soldier.received_suppression_this_tick = bool(
			update.get("receivedSuppression", update.get("received_suppression", false))
		)
		soldier.stunned_until_msec = int(
			update.get("stunnedUntilMsec", update.get("stunned_until_msec", soldier.stunned_until_msec))
		)
		soldier.stand_on_stun_recovery = bool(
			update.get("standOnStunRecovery", update.get("stand_on_stun_recovery", soldier.stand_on_stun_recovery))
		)
		soldier.position_state = int(
			update.get("positionState", update.get("position_state", soldier.position_state))
		)
		soldier.movement_mode = int(
			update.get("movementMode", update.get("movement_mode", soldier.movement_mode))
		)
		soldier.engaged_target_team_id = int(
			update.get("engagedTargetTeamId", update.get("engaged_target_team_id", soldier.engaged_target_team_id))
		)
		soldier.engaged_target_soldier_id = int(
			update.get("engagedTargetSoldierId", update.get("engaged_target_soldier_id", soldier.engaged_target_soldier_id))
		)
		soldier.sustained_fire = bool(
			update.get("sustainedFire", update.get("sustained_fire", soldier.sustained_fire))
		)
		if bool(update.get("isStunned", update.get("is_stunned", false))):
			soldier.clear_pending_position()
			soldier.reset_fire_prep()
		if not bool(update.get("isMoving", update.get("is_moving", soldier.is_moving))):
			soldier.clear_path()


static func _clear_engagements_on_dead(game_state: GameStateClass, dead: SoldierState) -> void:
	if game_state == null or dead == null:
		return
	for team_id in [1, 2]:
		var ft = game_state.session.get_fireteam(team_id) if game_state.session != null else null
		if ft == null:
			continue
		for state in ft.soldiers:
			var soldier: SoldierState = state
			if (
				soldier.engaged_target_team_id == dead.team_id
				and soldier.engaged_target_soldier_id == dead.soldier_id
			):
				soldier.clear_engaged_target()
				soldier.reset_fire_prep()


static func combat_shot_from_payload(raw: Dictionary) -> CombatShotResultClass:
	var shot := CombatShotResultClass.new()
	shot.fired = bool(raw.get("fired", false))
	shot.hit = bool(raw.get("hit", false))
	shot.killed = bool(raw.get("killed", false))
	shot.blocked = bool(raw.get("blocked", false))
	shot.no_ammo = bool(raw.get("noAmmo", raw.get("no_ammo", false)))
	shot.out_of_range = bool(raw.get("outOfRange", raw.get("out_of_range", false)))
	shot.on_cooldown = bool(raw.get("onCooldown", raw.get("on_cooldown", false)))
	shot.had_cover = bool(raw.get("hadCover", raw.get("had_cover", false)))
	shot.cover_type = int(raw.get("coverType", raw.get("cover_type", 0)))
	shot.weapon_name = str(raw.get("weaponName", raw.get("weapon_name", "")))
	shot.tracer_count = int(raw.get("tracerCount", raw.get("tracer_count", 0)))
	shot.shooter_team_id = int(raw.get("shooterTeamId", raw.get("shooter_team_id", 1)))
	shot.shooter_id = int(raw.get("shooterId", raw.get("shooter_id", 1)))
	shot.target_team_id = int(raw.get("targetTeamId", raw.get("target_team_id", 2)))
	shot.target_id = int(raw.get("targetId", raw.get("target_id", 1)))
	shot.corner_peek = bool(raw.get("cornerPeek", raw.get("corner_peek", false)))
	shot.peek_side = int(raw.get("peekSide", raw.get("peek_side", 0)))
	shot.corner_cell = _cell(raw.get("cornerCell", raw.get("corner_cell", {})))
	shot.hit_final = float(raw.get("hitFinal", raw.get("hit_final", 0.0)))
	shot.kill_chance = float(raw.get("killChance", raw.get("kill_chance", 0.0)))
	return shot


static func action_result_from_payload(payload: Dictionary) -> ActionResultClass:
	if not bool(payload.get("success", false)):
		return ActionResultClass.fail(str(payload.get("statusMessage", payload.get("status_message", "Command rejected."))))
	var result := ActionResultClass.new()
	result.success = true
	result.status_message = str(payload.get("statusMessage", payload.get("status_message", "")))
	result.refresh_views = false
	for raw in payload.get("moveOrders", payload.get("move_orders", [])):
		if not raw is Dictionary:
			continue
		var order: Dictionary = raw
		result.move_orders.append({
			"team_id": int(order.get("teamId", order.get("team_id", -1))),
			"soldier_id": int(order.get("soldierId", order.get("soldier_id", -1))),
			"path": _path(order.get("path", [])),
			"speed_mult": float(order.get("speedMult", order.get("speed_mult", 1.0))),
			"movement_mode": int(order.get("movementMode", order.get("movement_mode", MovementMode.RUN))),
			"position_state": int(order.get("positionState", order.get("position_state", PositionStateClass.UP))),
		})
	for raw in payload.get("movementHalts", payload.get("movement_halts", [])):
		if not raw is Dictionary:
			continue
		var halt: Dictionary = raw
		result.movement_halts.append({
			"team_id": int(halt.get("teamId", halt.get("team_id", -1))),
			"soldier_id": int(halt.get("soldierId", halt.get("soldier_id", -1))),
			"snap_cell": _cell(halt.get("snapCell", halt.get("snap_cell", {}))),
		})
	_append_stance_orders(result, payload)
	_apply_soldier_updates_to_result(result, payload)
	_append_target_updates(result, payload)
	result.sync_fire_at_ui = bool(payload.get("syncFireAtUi", payload.get("sync_fire_at_ui", false)))
	for raw in payload.get("faceUpdates", payload.get("face_updates", [])):
		if not raw is Dictionary:
			continue
		var face: Dictionary = raw
		result.face_updates.append({
			"team_id": int(face.get("teamId", face.get("team_id", -1))),
			"soldier_id": int(face.get("soldierId", face.get("soldier_id", -1))),
			"facing": _cell(face.get("facing", {})),
		})
	return result


static func apply_move_result(game_state: GameStateClass, result: ActionResultClass) -> void:
	if game_state == null or result == null:
		return
	for halt in result.movement_halts:
		var soldier: SoldierState = game_state.get_soldier(int(halt.team_id), int(halt.soldier_id))
		if soldier == null:
			continue
		soldier.clear_path()
		var snap: Variant = halt.get("snap_cell", null)
		if snap is Vector2i:
			soldier.grid_position = snap
	if not result.success:
		return
	for order in result.move_orders:
		var soldier: SoldierState = game_state.get_soldier(int(order.team_id), int(order.soldier_id))
		if soldier == null:
			continue
		var path: Array = order.get("path", [])
		var typed: Array[Vector2i] = []
		for cell in path:
			if cell is Vector2i:
				typed.append(cell)
		if order.has("movement_mode"):
			soldier.movement_mode = int(order.movement_mode)
		if order.has("position_state"):
			soldier.position_state = int(order.position_state)
			soldier.clear_pending_position()
		soldier.assign_path(typed, float(order.get("speed_mult", 1.0)))
	_apply_soldier_update_dicts(game_state, result.soldier_updates)


static func apply_face_result(game_state: GameStateClass, result: ActionResultClass) -> void:
	if game_state == null or result == null or not result.success:
		return
	for update in result.face_updates:
		var soldier: SoldierState = game_state.get_soldier(int(update.team_id), int(update.soldier_id))
		if soldier == null:
			continue
		var facing: Vector2i = update.get("facing", Vector2i.ZERO)
		if facing == Vector2i.ZERO:
			continue
		soldier.facing_direction = FacingDirection.from_step(facing)


static func apply_position_result(game_state: GameStateClass, result: ActionResultClass) -> void:
	if game_state == null or result == null:
		return
	for halt in result.movement_halts:
		var soldier: SoldierState = game_state.get_soldier(int(halt.team_id), int(halt.soldier_id))
		if soldier == null:
			continue
		soldier.clear_path()
		var snap: Variant = halt.get("snap_cell", null)
		if snap is Vector2i:
			soldier.grid_position = snap
	if not result.success:
		return
	_apply_soldier_update_dicts(game_state, result.soldier_updates)
	for order in result.stance_transition_orders:
		var soldier: SoldierState = game_state.get_soldier(int(order.team_id), int(order.soldier_id))
		if soldier == null:
			continue
		var target := int(order.target_position_state)
		soldier.position_state = target
		soldier.pending_position_state = target


static func apply_target_result(game_state: GameStateClass, result: ActionResultClass) -> void:
	if game_state == null or result == null:
		return
	for halt in result.movement_halts:
		var halted: SoldierState = game_state.get_soldier(int(halt.team_id), int(halt.soldier_id))
		if halted == null:
			continue
		halted.clear_path()
		var snap: Variant = halt.get("snap_cell", null)
		if snap is Vector2i:
			halted.grid_position = snap
	if not result.success:
		return
	apply_face_result(game_state, result)
	for update in result.target_updates:
		if not update is Dictionary:
			continue
		var soldier: SoldierState = game_state.get_soldier(int(update.team_id), int(update.soldier_id))
		if soldier == null:
			continue
		soldier.fire_control_state = int(
			update.get("fire_control_state", soldier.fire_control_state)
		)
		soldier.engaged_target_team_id = int(update.get("engaged_target_team_id", -1))
		soldier.engaged_target_soldier_id = int(update.get("engaged_target_soldier_id", -1))
		soldier.sustained_fire = bool(update.get("sustained_fire", false))
		if not soldier.sustained_fire and not soldier.is_engaged():
			soldier.reset_fire_prep()


static func apply_movement_tick(game_state: GameStateClass, payload: Dictionary) -> ActionResultClass:
	var result := ActionResultClass.new()
	result.success = true
	result.refresh_views = false
	if game_state == null:
		return result
	for raw in payload.get("movementSteps", payload.get("movement_steps", [])):
		if not raw is Dictionary:
			continue
		var step: Dictionary = raw
		var team_id := int(step.get("teamId", step.get("team_id", -1)))
		var soldier_id := int(step.get("soldierId", step.get("soldier_id", -1)))
		var tile := _cell(step.get("tile", {}))
		var delta := _cell(step.get("stepDelta", step.get("step_delta", {})))
		var soldier: SoldierState = game_state.get_soldier(team_id, soldier_id)
		if soldier != null:
			soldier.grid_position = tile
			if delta != Vector2i.ZERO:
				soldier.facing_direction = FacingDirection.from_step(delta)
			if soldier.is_moving:
				soldier.path_index = mini(soldier.path_index + 1, maxi(soldier.current_path.size() - 1, 0))
		result.movement_steps.append({
			"team_id": team_id,
			"soldier_id": soldier_id,
			"tile": tile,
			"step_delta": delta,
		})
	for raw in payload.get("movementCompletions", payload.get("movement_completions", [])):
		if not raw is Dictionary:
			continue
		var done: Dictionary = raw
		var team_id := int(done.get("teamId", done.get("team_id", -1)))
		var soldier_id := int(done.get("soldierId", done.get("soldier_id", -1)))
		var soldier: SoldierState = game_state.get_soldier(team_id, soldier_id)
		if soldier != null:
			soldier.clear_path()
		result.movement_completions.append({
			"team_id": team_id,
			"soldier_id": soldier_id,
		})
	return result


static func _append_stance_orders(result: ActionResultClass, payload: Dictionary) -> void:
	for raw in payload.get("stanceTransitionOrders", payload.get("stance_transition_orders", [])):
		if not raw is Dictionary:
			continue
		var order: Dictionary = raw
		result.stance_transition_orders.append({
			"team_id": int(order.get("teamId", order.get("team_id", -1))),
			"soldier_id": int(order.get("soldierId", order.get("soldier_id", -1))),
			"target_position_state": int(
				order.get("targetPositionState", order.get("target_position_state", PositionStateClass.UP))
			),
		})


static func _append_target_updates(result: ActionResultClass, payload: Dictionary) -> void:
	for raw in payload.get("targetUpdates", payload.get("target_updates", [])):
		if not raw is Dictionary:
			continue
		var update: Dictionary = raw
		result.target_updates.append({
			"team_id": int(update.get("teamId", update.get("team_id", -1))),
			"soldier_id": int(update.get("soldierId", update.get("soldier_id", -1))),
			"fire_control_state": int(
				update.get("fireControlState", update.get("fire_control_state", FireControlStateClass.FIRE_AT_WILL))
			),
			"engaged_target_team_id": int(
				update.get("engagedTargetTeamId", update.get("engaged_target_team_id", -1))
			),
			"engaged_target_soldier_id": int(
				update.get("engagedTargetSoldierId", update.get("engaged_target_soldier_id", -1))
			),
			"sustained_fire": bool(update.get("sustainedFire", update.get("sustained_fire", false))),
		})


static func _apply_soldier_updates_to_result(result: ActionResultClass, payload: Dictionary) -> void:
	for raw in payload.get("soldierUpdates", payload.get("soldier_updates", [])):
		if not raw is Dictionary:
			continue
		var update: Dictionary = raw
		result.soldier_updates.append({
			"team_id": int(update.get("teamId", update.get("team_id", -1))),
			"soldier_id": int(update.get("soldierId", update.get("soldier_id", -1))),
			"facing": _cell(update.get("facing", {})),
			"position_state": int(update.get("positionState", update.get("position_state", PositionStateClass.UP))),
			"movement_mode": int(update.get("movementMode", update.get("movement_mode", MovementMode.RUN))),
		})


static func _apply_soldier_update_dicts(game_state: GameStateClass, updates: Array) -> void:
	for update in updates:
		if not update is Dictionary:
			continue
		var soldier: SoldierState = game_state.get_soldier(int(update.team_id), int(update.soldier_id))
		if soldier == null:
			continue
		if update.has("facing"):
			var facing: Vector2i = update.facing
			if facing != Vector2i.ZERO:
				soldier.facing_direction = FacingDirection.from_step(facing)
		if update.has("position_state"):
			soldier.position_state = int(update.position_state)
		if update.has("movement_mode"):
			soldier.movement_mode = int(update.movement_mode)


static func _cell(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Dictionary:
		return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
	return Vector2i.ZERO


static func _path(value: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not value is Array:
		return out
	for entry in value:
		out.append(_cell(entry))
	return out
