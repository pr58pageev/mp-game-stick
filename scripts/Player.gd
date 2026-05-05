extends CharacterBody2D

@export var speed: float = 300.0
@export var jump_velocity: float = -500.0

var player_name: String = "":
	set(v):
		player_name = v
		if is_node_ready() and has_node("NameLabel"):
			$NameLabel.text = v


func _ready() -> void:
	if has_node("NameLabel"):
		$NameLabel.text = player_name


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null and not is_multiplayer_authority():
		return

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

	if multiplayer.multiplayer_peer != null and is_multiplayer_authority():
		_sync_transform.rpc(global_position)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _sync_transform(pos: Vector2) -> void:
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	global_position = pos
