extends Node2D
## Сундук: спрайт chest_01.png (4 кадра по 16×16). Открывается, когда рядом игрок (слой коллизии 2).

const FRAME_CLOSED := 0
const FRAME_OPEN := 3

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D


func _ready() -> void:
	if _sprite:
		_sprite.hframes = 4
		_sprite.vframes = 1
		_sprite.frame = FRAME_CLOSED
		_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if _area:
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	if body is CharacterBody2D:
		_set_open(true)
		var main := get_tree().get_first_node_in_group("arena_main")
		if main and main.has_method("try_spawn_meat_for_chest"):
			main.try_spawn_meat_for_chest(name, global_position, body as CharacterBody2D)


func _on_body_exited(_body: Node2D) -> void:
	call_deferred("_sync_open_from_overlap")


func _sync_open_from_overlap() -> void:
	if not is_instance_valid(self) or _sprite == null or _area == null:
		return
	var any_player := false
	for b in _area.get_overlapping_bodies():
		if b is CharacterBody2D:
			any_player = true
			break
	_set_open(any_player)


func _set_open(open: bool) -> void:
	var fr := FRAME_OPEN if open else FRAME_CLOSED
	if _sprite.frame != fr:
		_sprite.frame = fr
