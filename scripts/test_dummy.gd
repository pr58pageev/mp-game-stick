extends CharacterBody2D
## Бот: те же HP/полоса и откат по X, что у игрока (без ввода и сети).

const MAX_HP := 100.0
const SHOVE_IMPULSE_MAX := 580.0

@export var speed: float = 300.0

var player_name: String = "Бот":
	set(v):
		player_name = v
		if is_node_ready() and has_node("NameLabel"):
			$NameLabel.text = v

var hp: float = MAX_HP

@onready var _sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	add_to_group("pushable_dummy")
	if has_node("NameLabel"):
		$NameLabel.text = player_name
	if has_node("HPBar"):
		$HPBar.max_value = MAX_HP
	_refresh_hp_bar()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	velocity.x = move_toward(velocity.x, 0.0, speed * delta)
	move_and_slide()
	global_position.x = clampf(global_position.x, GameState.ARENA_X_MIN, GameState.ARENA_X_MAX)


func apply_shove_impulse(impulse_x: float) -> void:
	velocity.x += clampf(impulse_x, -SHOVE_IMPULSE_MAX, SHOVE_IMPULSE_MAX)


func play_attack_vfx() -> void:
	pass


func _refresh_hp_bar() -> void:
	if has_node("HPBar"):
		$HPBar.value = hp


func force_hp(new_hp: float) -> void:
	hp = clampf(new_hp, 0.0, MAX_HP)
	_refresh_hp_bar()


func force_respawn(pos: Vector2, full_hp: float) -> void:
	global_position = pos
	velocity = Vector2.ZERO
	hp = clampf(full_hp, 0.0, MAX_HP)
	_refresh_hp_bar()
