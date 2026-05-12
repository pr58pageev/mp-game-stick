class_name Player
extends CharacterBody2D

const NET_SNAP_DIST_SQ := 120000.0

## 512×256: 8×4 по 64×64. Строки листа: 0 вниз, 1 вверх, 2 вправо, 3 влево; колонки 0–3 ходьба, 4–7 удар.
const SHEET_TEXTURE := preload("res://assets/Character_SpriteSheet.png")
const SPRITE_VISUAL_SCALE := 1.0 / 1.5
const SHEET_HFRAMES := 8
const SHEET_VFRAMES := 4
const WALK_FRAME_COUNT := 4
const ATTACK_FRAME_START := 4
const ATTACK_FRAME_COUNT := 4
const ATTACK_FRAME_DUR := 0.075
const ATTACK_COOLDOWN_MS := int((ATTACK_FRAME_DUR * float(ATTACK_FRAME_COUNT) + 0.12) * 1000.0)

@export var speed: float = 240.0
@export var max_hp: int = 100

var hp: int = 100

var player_name: String = "":
	set(v):
		player_name = v
		if is_node_ready() and has_node("NameLabel"):
			$NameLabel.text = v

var _net_pos: Vector2
var _anim_time: float = 0.0
## Индекс строки листа: 0 вниз, 1 вверх, 2 вправо, 3 влево.
var _facing_row: int = 0
var _attack_unlock_ms: int = 0
var _melee_tween: Tween
var _attack_anim_active: bool = false

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _rock_sprite: Sprite2D = $KoRockSprite
@onready var _hp_bar: ProgressBar = $HPBar


func _ready() -> void:
	add_to_group("arena_players")
	motion_mode = MOTION_MODE_FLOATING
	_net_pos = global_position
	hp = max_hp
	if _sprite:
		_sprite.texture = SHEET_TEXTURE
		_sprite.hframes = SHEET_HFRAMES
		_sprite.vframes = SHEET_VFRAMES
		_sprite.centered = true
		_sprite.offset = Vector2(0.0, -10.0)
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_sprite.scale = Vector2.ONE * SPRITE_VISUAL_SCALE
	if _rock_sprite:
		_rock_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_rock_sprite.visible = false
	if has_node("NameLabel"):
		var nl: Label = $NameLabel
		nl.text = player_name
		nl.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_facing_row = 0
	if _sprite:
		_sprite.frame = 0
	_setup_hp_bar_theme()
	_update_hp_bar()
	_refresh_ko_visual()


func _setup_hp_bar_theme() -> void:
	if _hp_bar == null:
		return
	_hp_bar.min_value = 0.0
	_hp_bar.max_value = float(max_hp)
	_hp_bar.value = float(hp)
	_hp_bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.88, 0.15, 0.12, 0.98)
	_hp_bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.18, 0.06, 0.06, 0.92)
	_hp_bar.add_theme_stylebox_override("background", bg)


func _update_hp_bar() -> void:
	if _hp_bar:
		_hp_bar.max_value = float(max_hp)
		_hp_bar.value = float(hp)


func _refresh_ko_visual() -> void:
	var ko := hp <= 0
	if _sprite:
		_sprite.visible = not ko
	if _rock_sprite:
		_rock_sprite.visible = ko


func is_knocked_out() -> bool:
	return hp <= 0


## Точка для ИИ врагов: центр видимого спрайта (а не ноги CharacterBody2D).
func get_combat_anchor() -> Vector2:
	if _sprite != null and _sprite.visible:
		return _sprite.global_position
	if _rock_sprite != null and _rock_sprite.visible:
		return _rock_sprite.global_position
	return global_position


func sync_hp_from_server(new_hp: int) -> void:
	hp = clampi(new_hp, 0, max_hp)
	_update_hp_bar()
	_refresh_ko_visual()


## Только сервер арены вызывает перед rpc синхронизации.
func server_apply_damage(amount: int) -> int:
	hp = maxi(0, hp - amount)
	_update_hp_bar()
	_refresh_ko_visual()
	return hp


## Полное воскрешение (вызывает только логика Main на сервере).
func server_apply_revive() -> int:
	hp = max_hp
	_update_hp_bar()
	_refresh_ko_visual()
	return hp


## Только сервер: +HP (сундук / мясо), синхрон через Main.rpc_sync_player_hp.
func server_apply_heal(amount: int) -> int:
	if hp <= 0:
		return hp
	hp = mini(max_hp, hp + amount)
	_update_hp_bar()
	return hp


## Синхрон телепорта после авто-респавна (сервер уже применил позицию у себя).
func apply_respawn_pose(pos: Vector2) -> void:
	global_position = pos
	_net_pos = pos


func apply_network_motion(pos: Vector2) -> void:
	_net_pos = pos


func play_melee_visual() -> void:
	if hp <= 0:
		return
	if _sprite == null:
		return
	if _melee_tween != null and _melee_tween.is_valid():
		_melee_tween.kill()
	_attack_anim_active = true
	var row_base := _facing_row * SHEET_HFRAMES
	var tw := create_tween()
	tw.set_parallel(false)
	_melee_tween = tw
	tw.finished.connect(func() -> void:
		_attack_anim_active = false
		if _sprite:
			_sprite.scale = Vector2.ONE * SPRITE_VISUAL_SCALE
			_sprite.frame = row_base
	)
	for i in range(ATTACK_FRAME_COUNT):
		var fi := i
		tw.tween_callback(func() -> void:
			if _sprite:
				_sprite.frame = row_base + ATTACK_FRAME_START + fi
		)
		tw.tween_interval(ATTACK_FRAME_DUR)


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null and not is_multiplayer_authority():
		_run_puppet_physics(delta)
		return

	if hp <= 0:
		velocity = Vector2.ZERO
		move_and_slide()
		_clamp_to_world()
		if multiplayer.multiplayer_peer != null and is_multiplayer_authority():
			var main := get_tree().get_first_node_in_group("arena_main")
			if main and main.has_method("relay_player_pos"):
				main.relay_player_pos.rpc(get_multiplayer_authority(), global_position)
		return

	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var tc := get_tree().get_first_node_in_group("touch_analog")
	if tc and tc.has_method("get_virtual_axis"):
		input_dir += tc.get_virtual_axis()
	var touch_attack := false
	if tc and tc.has_method("consume_attack_pressed"):
		touch_attack = tc.consume_attack_pressed()
	if input_dir.length_squared() > 0.0001:
		input_dir = input_dir.normalized()
		velocity = input_dir * speed
		if not _attack_anim_active:
			_anim_time += delta * 9.0
			_update_facing_and_frame(input_dir, true)
	else:
		velocity = Vector2.ZERO
		if _sprite and not _attack_anim_active:
			_sprite.frame = _facing_row * SHEET_HFRAMES

	move_and_slide()
	_clamp_to_world()

	if Input.is_action_just_pressed("attack") or touch_attack:
		_try_request_melee()

	if Input.is_action_just_pressed("revive"):
		_try_revive_nearby()

	if multiplayer.multiplayer_peer != null and is_multiplayer_authority():
		var main := get_tree().get_first_node_in_group("arena_main")
		if main and main.has_method("relay_player_pos"):
			main.relay_player_pos.rpc(get_multiplayer_authority(), global_position)


func _try_revive_nearby() -> void:
	var main := get_tree().get_first_node_in_group("arena_main")
	if main and main.has_method("try_revive_nearby_from_local_player"):
		main.try_revive_nearby_from_local_player()


func _try_request_melee() -> void:
	if hp <= 0:
		return
	if Time.get_ticks_msec() < _attack_unlock_ms:
		return
	_attack_unlock_ms = Time.get_ticks_msec() + ATTACK_COOLDOWN_MS
	if multiplayer.multiplayer_peer != null and is_multiplayer_authority():
		play_melee_visual()
	var main := get_tree().get_first_node_in_group("arena_main")
	if main == null or not main.has_method("player_request_melee"):
		return
	main.player_request_melee(get_multiplayer_authority())


func _update_facing_and_frame(input_dir: Vector2, walking: bool) -> void:
	if _sprite == null:
		return
	if absf(input_dir.y) >= absf(input_dir.x):
		if input_dir.y < 0.0:
			_facing_row = 1
		else:
			_facing_row = 0
	else:
		if input_dir.x < 0.0:
			_facing_row = 3
		else:
			_facing_row = 2
	if walking:
		_sprite.frame = _facing_row * SHEET_HFRAMES + (int(_anim_time) % WALK_FRAME_COUNT)
	else:
		_sprite.frame = _facing_row * SHEET_HFRAMES


func _run_puppet_physics(delta: float) -> void:
	var dt := maxf(delta, 0.00001)
	if global_position.distance_squared_to(_net_pos) > NET_SNAP_DIST_SQ:
		global_position = _net_pos
		velocity = Vector2.ZERO
		move_and_slide()
		_clamp_to_world()
		return
	if hp <= 0:
		global_position = _net_pos
		velocity = Vector2.ZERO
		move_and_slide()
		_clamp_to_world()
		return
	var desired_vel := (_net_pos - global_position) / dt
	var len := desired_vel.length()
	var cap := speed * 2.0
	if len > cap:
		desired_vel = desired_vel / len * cap
	velocity = desired_vel
	if velocity.length_squared() > 400.0:
		if not _attack_anim_active:
			_anim_time += delta * 9.0
			_update_facing_and_frame(velocity.normalized(), true)
	else:
		if _sprite and not _attack_anim_active:
			_sprite.frame = _facing_row * SHEET_HFRAMES
	move_and_slide()
	_clamp_to_world()


func _clamp_to_world() -> void:
	var r := GameState.world_rect
	var m := 10.0
	global_position.x = clampf(global_position.x, r.position.x + m, r.position.x + r.size.x - m)
	global_position.y = clampf(global_position.y, r.position.y + m, r.position.y + r.size.y - m)
