extends CharacterBody2D

const ATTACK_COOLDOWN := 0.55
const MAX_HP := 100.0
const NET_SNAP_DIST_SQ := 65000.0
## Тестовая разработка: логи толчка держим включёнными (не выключать без явного решения «релиз»).
const SHOVE_LOG := true
const SHOVE_LOG_VERBOSE := false
## to_id для манекена Bot (см. Main.SHOVE_TARGET_BOT_ID).
const SHOVE_TARGET_BOT_ID := 0
## Proximity: «вплотную» по центрам (два хитбокса ~64px — касание ~64, было 62 и snug не срабатывал).
const SHOVE_PROX_MAX_DIST := 84.0
const SHOVE_PROX_SNUG_DIST := 76.0
const SHOVE_PROX_RUN_CONTACT_DIST := 76.0
const SHOVE_PROX_VEL_SNUG_MAX := 45.0
const SHOVE_PROX_MOVE_VEL_MIN := 8.0
const SHOVE_PROX_DY_MAX := 200.0
## Не слать request_player_shove каждый кадр (очередь reliable + relay).
const SHOVE_NOTIFY_CLIENT_MIN_MS := 170
## Замедление по X без ввода (px/с²); НЕ использовать `speed` как шаг move_toward — иначе толчок recv_shove съедается за 1 кадр.
const GROUND_DECEL_X := 2200.0
## Толчок игрока (PvP): было ~92/95 * 0.48/0.55 ≈ 44–52 стоя; поднято ближе к «как бота».
const SHOVE_RECV_IMPULSE_MAX := 580.0
const SHOVE_SLIDE_BASE := 128.0
const SHOVE_SLIDE_RUN_SCALE_MIN := 0.45
const SHOVE_SLIDE_RUN_SCALE_MAX := 1.42
const SHOVE_SLIDE_STILL_MUL := 0.72
const SHOVE_PROX_BASE := 132.0
const SHOVE_PROX_RUN_SCALE_MIN := 0.5
const SHOVE_PROX_RUN_SCALE_MAX := 1.42
const SHOVE_PROX_STILL_MUL := 0.76

@export var speed: float = 300.0
@export var jump_velocity: float = -500.0
## Сила второго прыжка в воздухе (доля от jump_velocity).
@export_range(0.5, 1.0, 0.01) var air_jump_velocity_scale: float = 0.9

var player_name: String = "":
	set(v):
		player_name = v
		if is_node_ready() and has_node("NameLabel"):
			$NameLabel.text = v

var hp: float = MAX_HP

var _attack_cd: float = 0.0
var _attack_tween: Tween
## Осталось прыжков в воздухе после отрыва от пола (1 = разрешён двойной: пол + воздух).
var _air_jumps_left: int = 1
## peer_id цели -> время последнего notify_player_shove (мс).
var _shove_notify_last_ms: Dictionary = {}
## Редкий лог «есть slide, но notify не ушёл» (без спама каждый кадр).
var _shove_slide_no_notify_last_ms: int = -1_000_000_000
## Редкий лог «кулдаун notify» по to_id (иначе засоряет Output).
var _shove_cd_skip_log_last_ms: Dictionary = {}
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


func _allow_shove_notify(to_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return true
	var now := Time.get_ticks_msec()
	var prev: int = int(_shove_notify_last_ms.get(to_id, -1_000_000_000))
	if now - prev < SHOVE_NOTIFY_CLIENT_MIN_MS:
		return false
	_shove_notify_last_ms[to_id] = now
	return true


@rpc("any_peer", "call_remote", "reliable")
func recv_shove_impulse(impulse_x: float) -> void:
	print(
		"[SHOVE] recv_shove path=%s impulse=%.1f unique=%d authority=%d is_auth=%s"
		% [
			str(get_path()),
			impulse_x,
			multiplayer.get_unique_id(),
			get_multiplayer_authority(),
			is_multiplayer_authority(),
		]
	)
	if not is_multiplayer_authority():
		print("[SHOVE] recv_shove IGNORED (not authority)")
		return
	velocity.x += clampf(impulse_x, -SHOVE_RECV_IMPULSE_MAX, SHOVE_RECV_IMPULSE_MAX)
	print("[SHOVE] recv_shove APPLIED velocity.x=%.1f" % velocity.x)


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null and not is_multiplayer_authority():
		_run_puppet_physics(delta)
		return

	if _attack_cd > 0.0:
		_attack_cd -= delta

	if is_on_floor():
		_air_jumps_left = 1

	if not is_on_floor():
		velocity += get_gravity() * delta

	if Input.is_action_just_pressed("jump"):
		if is_on_floor():
			velocity.y = jump_velocity
		elif _air_jumps_left > 0:
			velocity.y = jump_velocity * air_jump_velocity_scale
			_air_jumps_left -= 1

	var direction := Input.get_axis("move_left", "move_right")
	if direction != 0.0:
		velocity.x = direction * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, GROUND_DECEL_X * delta)

	move_and_slide()
	global_position.x = clampf(global_position.x, GameState.ARENA_X_MIN, GameState.ARENA_X_MAX)

	if multiplayer.multiplayer_peer == null or is_multiplayer_authority():
		_try_report_player_shove()

	if Input.is_action_just_pressed("attack") and _attack_cd <= 0.0:
		_attack_cd = ATTACK_COOLDOWN
		_send_attack_request()

	if multiplayer.multiplayer_peer != null and is_multiplayer_authority():
		var main := get_tree().get_first_node_in_group("arena_main")
		if main and main.has_method("relay_player_pos"):
			main.relay_player_pos.rpc(get_multiplayer_authority(), global_position)


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
			if SHOVE_LOG:
				print("[SHOVE] slide skip: other is self (auth=%d)" % get_multiplayer_authority())
			continue
		## Частый кейс: стоите в линию по X — |dx| малый, раньше толчок с slide никогда не уходил.
		var dx := global_position.x - other.global_position.x
		if absf(dx) < 1.5:
			var nx := c.get_normal().x
			if absf(nx) > 0.1:
				dx = -nx * 40.0
			elif absf(velocity.x) > 6.0:
				dx = velocity.x
			else:
				if SHOVE_LOG:
					print(
						"[SHOVE] slide skip: |dx|=%.3f stacked, normal.x=%.3f vel.x=%.1f to_id=%s"
						% [absf(global_position.x - other.global_position.x), nx, velocity.x, str(to_id)]
					)
				continue
		var impulse := -signf(dx) * SHOVE_SLIDE_BASE
		if absf(velocity.x) > 18.0:
			impulse *= clampf(absf(velocity.x) / speed, SHOVE_SLIDE_RUN_SCALE_MIN, SHOVE_SLIDE_RUN_SCALE_MAX)
		else:
			impulse *= SHOVE_SLIDE_STILL_MUL
		var main := get_tree().get_first_node_in_group("arena_main")
		if main == null or not main.has_method("notify_player_shove"):
			if SHOVE_LOG:
				print("[SHOVE] slide skip: no Main.notify (main=%s)" % main)
			break
		if not _allow_shove_notify(to_id):
			if SHOVE_LOG:
				var tlog := Time.get_ticks_msec()
				var prev_cd := int(_shove_cd_skip_log_last_ms.get(to_id, -1_000_000_000))
				if tlog - prev_cd > 400:
					_shove_cd_skip_log_last_ms[to_id] = tlog
					print(
						"[SHOVE] slide skip: client notify cooldown to_id=%d (~%d ms)"
						% [to_id, SHOVE_NOTIFY_CLIENT_MIN_MS]
					)
			continue
		if SHOVE_LOG:
			print(
				"[SHOVE] slide -> notify from=%d to=%d impulse=%.1f"
				% [get_multiplayer_authority(), to_id, impulse]
			)
		main.notify_player_shove(get_multiplayer_authority(), to_id, impulse)
		return true
	var now_ms := Time.get_ticks_msec()
	if n > 0 and SHOVE_LOG and now_ms - _shove_slide_no_notify_last_ms > 500:
		_shove_slide_no_notify_last_ms = now_ms
		print(
			"[SHOVE] slide: %d collision(s), notify not sent (parent/self/stacked+calm/cooldown/no Main)"
			% n
		)
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
			if absf(velocity.x) > 6.0:
				dx = velocity.x
			else:
				var gapx := other.global_position.x - global_position.x
				if absf(gapx) > 0.0001:
					dx = gapx
				else:
					dx = 1.2 if get_instance_id() > other.get_instance_id() else -1.2
		var dy := absf(global_position.y - other.global_position.y)
		if dy > SHOVE_PROX_DY_MAX:
			if SHOVE_LOG_VERBOSE:
				print("[SHOVE] prox skip to=%d dy=%.1f" % [to_id, dy])
			continue
		var to_other_x := signf(other.global_position.x - global_position.x)
		if to_other_x == 0.0:
			to_other_x = signf(dx) if absf(dx) > 0.0001 else 1.0
		var input_x := Input.get_axis("move_left", "move_right")
		## В упор скорость часто 0 (столкновение съело), но ось «в противника» есть.
		var walk_into := absf(input_x) > 0.12 and signf(input_x) == to_other_x
		var moving_toward := (
			(
				absf(velocity.x) > SHOVE_PROX_MOVE_VEL_MIN
				and signf(velocity.x) == to_other_x
				and dist < SHOVE_PROX_RUN_CONTACT_DIST
			)
			or (walk_into and dist < SHOVE_PROX_RUN_CONTACT_DIST + 10.0)
		)
		var snug := dist < SHOVE_PROX_SNUG_DIST and absf(velocity.x) < SHOVE_PROX_VEL_SNUG_MAX
		if not (moving_toward or snug):
			if SHOVE_LOG_VERBOSE:
				print(
					"[SHOVE] prox skip to=%d dist=%.1f vel.x=%.1f toward=%s snug=%s"
					% [to_id, dist, velocity.x, moving_toward, snug]
				)
			continue
		var impulse := -signf(dx) * SHOVE_PROX_BASE
		if absf(velocity.x) > 18.0:
			impulse *= clampf(absf(velocity.x) / speed, SHOVE_PROX_RUN_SCALE_MIN, SHOVE_PROX_RUN_SCALE_MAX)
		else:
			impulse *= SHOVE_PROX_STILL_MUL
		var main := get_tree().get_first_node_in_group("arena_main")
		if main and main.has_method("notify_player_shove"):
			if not _allow_shove_notify(to_id):
				if SHOVE_LOG:
					var tlog2 := Time.get_ticks_msec()
					var prev2 := int(_shove_cd_skip_log_last_ms.get(to_id, -1_000_000_000))
					if tlog2 - prev2 > 400:
						_shove_cd_skip_log_last_ms[to_id] = tlog2
						print("[SHOVE] proximity skip: client notify cooldown to_id=%d" % to_id)
				break
			print(
				"[SHOVE] proximity -> notify from=%d to=%d imp=%.1f dist=%.1f vel.x=%.1f input=%.2f walk_into=%s snug=%s"
				% [pid, to_id, impulse, dist, velocity.x, input_x, walk_into, snug]
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
	global_position.x = clampf(global_position.x, GameState.ARENA_X_MIN, GameState.ARENA_X_MAX)


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
	_air_jumps_left = 1
	hp = clampf(full_hp, 0.0, MAX_HP)
	_refresh_hp_bar()
