extends CharacterBody2D
## Враг: только сервер двигает и бьёт; клиенты интерполируют позицию и получают визуал удара по RPC.

const MAX_HP := 50
const MOVE_SPEED := 55.0
const ATTACK_COOLDOWN_MS := 950

const HFRAMES := 8
const RUN_ROW := 1
const RUN_FRAME0 := RUN_ROW * HFRAMES
const IDLE_ROW := 0
const STRIKE_ROW := 2
const STRIKE_FRAME0 := STRIKE_ROW * HFRAMES
const STRIKE_FRAME_COUNT := 6
const STRIKE_VISUAL_DURATION := 0.42
## Макс. расстояние центр спрайта орка — центр спрайта игрока для удара (не ноги CharacterBody2D).
const MELEE_ANCHOR_RANGE := 58.0
const MELEE_RANGE_SQ := MELEE_ANCHOR_RANGE * MELEE_ANCHOR_RANGE
## Преследование только если игрок в радиусе (в тайлах 16×16) по ногам CharacterBody2D.
const CHASE_RADIUS_TILES := 50.0
## Слой WorldMapBuilder.PROP_COLLISION_LAYER — деревья и вода (не земля тайлмапа).
const OBSTACLE_RAY_MASK := 4
const AVOID_PROBE_LEN := 68.0
const AVOID_RAY_LATERAL := 16.0


var hp: int = MAX_HP
var _net_pos: Vector2
var _anim_t: float = 0.0
var _attack_unlock_ms: int = 0
var _strike_visual_left: float = 0.0
var _chase_range_sq: float = 0.0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _hp_bar: ProgressBar = $HPBar


func _orc_sprite_world() -> Vector2:
	if _sprite:
		return _sprite.global_position
	return global_position


func get_combat_anchor() -> Vector2:
	return _orc_sprite_world()


## Центр круга коллизии (ноги CharacterBody2D выше — лучи от ног «пролетают» мимо узкого ствола).
func _phys_probe_origin() -> Vector2:
	return global_position + Vector2(0.0, -20.0)


func _player_combat_anchor(p: Node2D) -> Vector2:
	if p.has_method("get_combat_anchor"):
		return p.call("get_combat_anchor") as Vector2
	return p.global_position


func _obstacle_ray_clear(from: Vector2, dir: Vector2, dist: float) -> bool:
	if dir.length_squared() < 1e-10:
		return false
	var to := from + dir.normalized() * dist
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.collision_mask = OBSTACLE_RAY_MASK
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()


func _obstacle_dir_clear_for_move(from: Vector2, dir: Vector2, dist: float) -> bool:
	if dir.length_squared() < 1e-10:
		return false
	var lateral := Vector2(-dir.y, dir.x)
	for k in [-1, 0, 1]:
		var o := from + lateral * (AVOID_RAY_LATERAL * float(k))
		if not _obstacle_ray_clear(o, dir, dist):
			return false
	return true


## Выбор направления к цели без краткосрочного столкновения с деревом/водой (лучи по маске препятствий).
func _pick_steering_dir(want_norm: Vector2, from: Vector2) -> Vector2:
	var best := want_norm
	var best_dot := -10.0
	for i in 9:
		var a := (float(i) - 4.0) * 0.35
		var d := want_norm.rotated(a)
		if _obstacle_dir_clear_for_move(from, d, AVOID_PROBE_LEN):
			var sc := d.dot(want_norm)
			if sc > best_dot:
				best_dot = sc
				best = d
	if best_dot < -0.5:
		return want_norm
	return best


func _ready() -> void:
	var ts := float(WorldMapBuilder.TILE_SIZE)
	var chase_r := CHASE_RADIUS_TILES * ts
	_chase_range_sq = chase_r * chase_r
	_net_pos = global_position
	add_to_group("melee_hurt_targets")
	motion_mode = MOTION_MODE_FLOATING
	if _sprite:
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_sprite.scale = Vector2(1.4, 1.4)
	_setup_hp_bar()
	_update_hp_bar()


func apply_network_motion(pos: Vector2) -> void:
	_net_pos = pos


func _setup_hp_bar() -> void:
	if _hp_bar == null:
		return
	_hp_bar.min_value = 0.0
	_hp_bar.max_value = float(MAX_HP)
	_hp_bar.value = float(hp)
	_hp_bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.25, 0.72, 0.28, 0.98)
	_hp_bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.12, 0.08, 0.92)
	_hp_bar.add_theme_stylebox_override("background", bg)


func _update_hp_bar() -> void:
	if _hp_bar:
		_hp_bar.max_value = float(MAX_HP)
		_hp_bar.value = float(hp)


func sync_hp_from_net(new_hp: int) -> void:
	hp = clampi(new_hp, 0, MAX_HP)
	_update_hp_bar()


func play_strike_visual() -> void:
	_strike_visual_left = STRIKE_VISUAL_DURATION


func take_melee_damage(amount: int, _attacker_peer_id: int) -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	hp = maxi(0, hp - amount)
	_update_hp_bar()
	var m := get_tree().get_first_node_in_group("arena_main")
	if m and m.has_method("broadcast_orc_hp"):
		m.broadcast_orc_hp(int(get_meta("orc_id", 0)), hp)
	if hp <= 0:
		if m and m.has_method("notify_orc_dead"):
			m.notify_orc_dead(int(get_meta("orc_id", 0)))
		queue_free()


func _advance_strike_visual(delta: float) -> void:
	if _strike_visual_left <= 0.0:
		return
	_strike_visual_left = maxf(0.0, _strike_visual_left - delta)
	if _sprite == null:
		return
	var u := 1.0 if STRIKE_VISUAL_DURATION <= 0.00001 else clampf(1.0 - _strike_visual_left / STRIKE_VISUAL_DURATION, 0.0, 1.0)
	var fi := mini(STRIKE_FRAME_COUNT - 1, int(u * float(STRIKE_FRAME_COUNT)))
	_sprite.frame = STRIKE_FRAME0 + fi


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		_advance_strike_visual(delta)
		var prev := global_position
		var a := clampf(48.0 * delta, 0.0, 1.0)
		global_position = global_position.lerp(_net_pos, a)
		if _sprite:
			var dx := global_position.x - prev.x
			if absf(dx) > 0.05:
				_sprite.flip_h = dx < 0.0
		if _strike_visual_left <= 0.0 and _sprite:
			_anim_t += delta * 10.0
			_sprite.frame = RUN_FRAME0 + (int(_anim_t) % HFRAMES)
		return

	_advance_strike_visual(delta)

	var target := _nearest_alive_player()
	if target == null:
		velocity = Vector2.ZERO
		if _sprite and _strike_visual_left <= 0.0:
			_anim_t += delta * 6.0
			_sprite.frame = IDLE_ROW * HFRAMES + (int(_anim_t) % 6)
		move_and_slide()
		_clamp_world()
		return

	var p_anchor := _player_combat_anchor(target as Node2D)
	var to_sprite := p_anchor - _orc_sprite_world()
	var d2 := to_sprite.length_squared()
	if d2 <= MELEE_RANGE_SQ:
		velocity = Vector2.ZERO
		_try_hit_player(target, d2)
		if _sprite and _strike_visual_left <= 0.0:
			var ax := p_anchor.x - _orc_sprite_world().x
			if absf(ax) > 2.0:
				_sprite.flip_h = ax < 0.0
			_anim_t += delta * 6.0
			_sprite.frame = IDLE_ROW * HFRAMES + (int(_anim_t) % 6)
		move_and_slide()
		_clamp_world()
		return

	if d2 > 0.0001:
		var want := to_sprite.normalized()
		var steer := _pick_steering_dir(want, _phys_probe_origin())
		velocity = steer * MOVE_SPEED
	else:
		velocity = Vector2.ZERO
	if _sprite and absf(velocity.x) > 1.0:
		_sprite.flip_h = velocity.x < 0.0
	if _strike_visual_left <= 0.0 and _sprite:
		_anim_t += delta * 10.0
		_sprite.frame = RUN_FRAME0 + (int(_anim_t) % HFRAMES)
	move_and_slide()
	_clamp_world()


func _nearest_alive_player() -> Node:
	var best: Node = null
	var best_d2 := 1.0e20
	var feet := global_position
	for n in get_tree().get_nodes_in_group("arena_players"):
		if not n is CharacterBody2D:
			continue
		if not n.has_method("is_knocked_out"):
			continue
		if n.call("is_knocked_out"):
			continue
		if feet.distance_squared_to((n as Node2D).global_position) > _chase_range_sq:
			continue
		var d2 := _orc_sprite_world().distance_squared_to(_player_combat_anchor(n as Node2D))
		if d2 < best_d2:
			best_d2 = d2
			best = n
	return best


func _try_hit_player(target: Node, dist_sq: float) -> void:
	if dist_sq > MELEE_RANGE_SQ:
		return
	if Time.get_ticks_msec() < _attack_unlock_ms:
		return
	_attack_unlock_ms = Time.get_ticks_msec() + ATTACK_COOLDOWN_MS
	_strike_visual_left = STRIKE_VISUAL_DURATION
	var main := get_tree().get_first_node_in_group("arena_main")
	if main and main.has_method("notify_orc_strike_started"):
		main.notify_orc_strike_started(int(get_meta("orc_id", 0)))
	if main == null or not main.has_method("apply_orc_melee_to_player"):
		return
	var nm := str(target.name)
	if not nm.is_valid_int():
		return
	main.apply_orc_melee_to_player(int(nm))


func _clamp_world() -> void:
	var r := GameState.world_rect
	var m := 10.0
	global_position.x = clampf(global_position.x, r.position.x + m, r.position.x + r.size.x - m)
	global_position.y = clampf(global_position.y, r.position.y + m, r.position.y + r.size.y - m)
