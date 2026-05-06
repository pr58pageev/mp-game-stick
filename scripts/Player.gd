extends CharacterBody2D

const ATTACK_COOLDOWN := 0.55
const MAX_HP := 100.0
const ARENA_X_MIN := 40.0
const ARENA_X_MAX := 1240.0
const NET_SNAP_DIST_SQ := 65000.0
## Логи толчка — оставляем включёнными по запросу.
const SHOVE_LOG := true
const SHOVE_LOG_VERBOSE := false
## to_id для манекена Bot (см. Main.SHOVE_TARGET_BOT_ID).
const SHOVE_TARGET_BOT_ID := 0
## Proximity-толчок только вплотную: бег в цель не с дистанции «на весь экран».
const SHOVE_PROX_MAX_DIST := 78.0
## Стоишь рядом и почти не движешься — можно оттолкнуть.
const SHOVE_PROX_SNUG_DIST := 62.0
## Бежишь в противника — только если уже почти касаетесь (px между центрами).
const SHOVE_PROX_RUN_CONTACT_DIST := 62.0
const SHOVE_PROX_VEL_SNUG_MAX := 45.0
const SHOVE_PROX_MOVE_VEL_MIN := 8.0
const SHOVE_PROX_DY_MAX := 200.0

@export var speed: float = 300.0
@export var jump_velocity: float = -500.0

var player_name: String = "":
	set(v):
		player_name = v
		if is_node_ready() and has_node("NameLabel"):
			$NameLabel.text = v

var hp: float = MAX_HP

var _attack_cd: float = 0.0
var _attack_tween: Tween
## Целевая позиция с машины владельца (только для чужих персонажей).
var _net_pos: Vector2

@onready var _sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	_net_pos = global_position
	if has_node("NameLabel"):
		$NameLabel.text = player_name
	if has_node("HPBar"):
		$HPBar.max_value = MAX_HP
	_refresh_hp_bar()


func apply_network_motion(pos: Vector2) -> void:
	_net_pos = pos


@rpc("any_peer", "call_remote", "reliable")
func recv_shove_impulse(impulse_x: float) -> void:
	print(
		"[SHOVE] recv_shove impulse=%.1f unique=%d authority=%d is_auth=%s"
		% [impulse_x, multiplayer.get_unique_id(), get_multiplayer_authority(), is_multiplayer_authority()]
	)
	if not is_multiplayer_authority():
		print("[SHOVE] recv_shove IGNORED (not authority)")
		return
	velocity.x += clampf(impulse_x, -520.0, 520.0)
	print("[SHOVE] recv_shove APPLIED velocity.x=%.1f" % velocity.x)


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null and not is_multiplayer_authority():
		_run_puppet_physics(delta)
		return

	if _attack_cd > 0.0:
		_attack_cd -= delta

	if not is_on_floor():
		velocity += get_gravity() * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var direction := Input.get_axis("move_left", "move_right")
	if direction != 0.0:
		velocity.x = direction * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)

	move_and_slide()
	global_position.x = clampf(global_position.x, ARENA_X_MIN, ARENA_X_MAX)

	if multiplayer.multiplayer_peer == null or is_multiplayer_authority():
		_try_report_player_shove()

	if Input.is_action_just_pressed("attack") and _attack_cd <= 0.0:
		_attack_cd = ATTACK_COOLDOWN
		_send_attack_request()

	if multiplayer.multiplayer_peer != null and is_multiplayer_authority():
		var main := get_tree().get_first_node_in_group("arena_main")
		if main and main.has_method("relay_player_pos"):
			main.relay_player_pos.rpc({"i": get_multiplayer_authority(), "p": global_position})


func _try_report_player_shove() -> void:
	if multiplayer.multiplayer_peer != null and not is_multiplayer_authority():
		return
	if _try_shove_from_slide_collisions():
		return
	_try_shove_from_proximity()


func _try_shove_from_slide_collisions() -> bool:
	var n := get_slide_collision_count()
	if SHOVE_LOG and n > 0:
		print("[SHOVE] peer=%d slides=%d vel.x=%.1f" % [get_multiplayer_authority(), n, velocity.x])
	for i in n:
		var c := get_slide_collision(i)
		var col := c.get_collider()
		if not col is CharacterBody2D:
			if SHOVE_LOG_VERBOSE:
				print("[SHOVE]   slide[%d] not Body: %s" % [i, col])
			continue
		var other := col as CharacterBody2D
		if other.get_parent() != get_parent():
			if SHOVE_LOG:
				print("[SHOVE]   slide[%d] wrong parent: %s" % [i, col.get_parent()])
			continue
		var to_id: int = (
			SHOVE_TARGET_BOT_ID
			if other.is_in_group("pushable_dummy")
			else other.get_multiplayer_authority()
		)
		if to_id != SHOVE_TARGET_BOT_ID and to_id == get_multiplayer_authority():
			continue
		var dx := global_position.x - other.global_position.x
		if absf(dx) < 1.5:
			continue
		var impulse := -signf(dx) * 92.0
		if absf(velocity.x) > 18.0:
			impulse *= clampf(absf(velocity.x) / speed, 0.4, 1.25)
		else:
			impulse *= 0.48
		var main := get_tree().get_first_node_in_group("arena_main")
		if main == null or not main.has_method("notify_player_shove"):
			break
		if SHOVE_LOG:
			print(
				"[SHOVE] slide -> notify from=%d to=%d impulse=%.1f"
				% [get_multiplayer_authority(), to_id, impulse]
			)
		main.notify_player_shove(get_multiplayer_authority(), to_id, impulse)
		return true
	return false


func _try_shove_from_proximity() -> void:
	var pid := get_multiplayer_authority()
	var players := get_parent()
	if players == null:
		if SHOVE_LOG:
			print("[SHOVE] proximity abort: no parent Players")
		return
	for node in players.get_children():
		if node == self or not node is CharacterBody2D:
			continue
		var other := node as CharacterBody2D
		var to_id: int = (
			SHOVE_TARGET_BOT_ID
			if other.is_in_group("pushable_dummy")
			else other.get_multiplayer_authority()
		)
		if to_id != SHOVE_TARGET_BOT_ID and to_id == pid:
			continue
		var dist := global_position.distance_to(other.global_position)
		if dist > SHOVE_PROX_MAX_DIST:
			if SHOVE_LOG_VERBOSE:
				print("[SHOVE] prox skip to=%d dist=%.1f too far" % [to_id, dist])
			continue
		var dx := global_position.x - other.global_position.x
		if absf(dx) < 1.0:
			if SHOVE_LOG_VERBOSE:
				print("[SHOVE] prox skip to=%d dx tiny %.2f" % [to_id, dx])
			continue
		var dy := absf(global_position.y - other.global_position.y)
		if dy > SHOVE_PROX_DY_MAX:
			if SHOVE_LOG_VERBOSE:
				print("[SHOVE] prox skip to=%d dy=%.1f" % [to_id, dy])
			continue
		var to_other_x := signf(other.global_position.x - global_position.x)
		var moving_toward := (
			absf(velocity.x) > SHOVE_PROX_MOVE_VEL_MIN
			and signf(velocity.x) == to_other_x
			and dist < SHOVE_PROX_RUN_CONTACT_DIST
		)
		var snug := dist < SHOVE_PROX_SNUG_DIST and absf(velocity.x) < SHOVE_PROX_VEL_SNUG_MAX
		if not (moving_toward or snug):
			if SHOVE_LOG_VERBOSE:
				print(
					"[SHOVE] prox skip to=%d dist=%.1f vel.x=%.1f toward=%s snug=%s"
					% [to_id, dist, velocity.x, moving_toward, snug]
				)
			continue
		var impulse := -signf(dx) * 95.0
		if absf(velocity.x) > 18.0:
			impulse *= clampf(absf(velocity.x) / speed, 0.45, 1.25)
		else:
			impulse *= 0.55
		var main := get_tree().get_first_node_in_group("arena_main")
		if main and main.has_method("notify_player_shove"):
			print(
				"[SHOVE] proximity -> notify from=%d to=%d imp=%.1f dist=%.1f vel.x=%.1f"
				% [pid, to_id, impulse, dist, velocity.x]
			)
			main.notify_player_shove(pid, to_id, impulse)
		elif SHOVE_LOG:
			print("[SHOVE] proximity fail: no Main.notify_player_shove")
		break


func _run_puppet_physics(delta: float) -> void:
	if global_position.distance_squared_to(_net_pos) > NET_SNAP_DIST_SQ:
		global_position = _net_pos
		velocity = Vector2.ZERO
		return
	var dt := maxf(delta, 0.00001)
	var desired_vel := (_net_pos - global_position) / dt
	desired_vel.x = clampf(desired_vel.x, -speed * 1.35, speed * 1.35)
	desired_vel.y = clampf(desired_vel.y, jump_velocity * 1.2, 1600.0)
	velocity = desired_vel
	move_and_slide()
	global_position.x = clampf(global_position.x, ARENA_X_MIN, ARENA_X_MAX)


func _send_attack_request() -> void:
	var main := get_tree().get_first_node_in_group("arena_main")
	if main and main.has_method("player_request_attack"):
		main.player_request_attack(get_multiplayer_authority())


func play_attack_vfx() -> void:
	if _sprite == null:
		return
	if _attack_tween != null and is_instance_valid(_attack_tween):
		_attack_tween.kill()
	var base := Vector2(0.5, 0.5)
	_attack_tween = create_tween()
	_attack_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_attack_tween.tween_property(_sprite, "scale", base * 1.3, 0.09)
	_attack_tween.tween_property(_sprite, "scale", base, 0.12)
	_attack_tween.set_trans(Tween.TRANS_QUAD)
	_attack_tween.tween_property(_sprite, "modulate", Color(1.28, 1.1, 0.82), 0.06)
	_attack_tween.tween_property(_sprite, "modulate", Color.WHITE, 0.1)


func _refresh_hp_bar() -> void:
	if has_node("HPBar"):
		$HPBar.value = hp


func force_hp(new_hp: float) -> void:
	hp = clampf(new_hp, 0.0, MAX_HP)
	_refresh_hp_bar()


func force_respawn(pos: Vector2, full_hp: float) -> void:
	global_position = pos
	_net_pos = pos
	velocity = Vector2.ZERO
	hp = clampf(full_hp, 0.0, MAX_HP)
	_refresh_hp_bar()
