extends Node2D
## Выпавшее из сундука мясо: дуга полёта, подбор только на сервере (+HP), деспаун через Main по RPC.

const MEAT_TEXTURE := preload(
	"res://assets/Pixel Crawler - Free Pack/Environment/Props/Static/Meat.png"
)
const ATLAS_TILE := 16
## Строка атласа Meat.png (0-based); колонка задаётся при спавне (1 — малый, 2 — большой).
const REGION_ROW := 7

var _meat_uid: int = -1
var _heal_hp: int = 0
var _from: Vector2
var _to: Vector2
var _picked: bool = false

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D


func _ready() -> void:
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_area.body_entered.connect(_on_body_entered)


func begin_drop(
	from_pos: Vector2,
	to_pos: Vector2,
	meat_uid: int,
	atlas_col: int,
	heal_hp: int,
	chest_name: String
) -> void:
	_meat_uid = meat_uid
	_heal_hp = heal_hp
	set_meta("chest_name", chest_name)
	var at := AtlasTexture.new()
	at.atlas = MEAT_TEXTURE
	at.region = Rect2(
		float(atlas_col * ATLAS_TILE),
		float(REGION_ROW * ATLAS_TILE),
		float(ATLAS_TILE),
		float(ATLAS_TILE)
	)
	_sprite.texture = at
	_from = from_pos
	_to = to_pos
	global_position = from_pos
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_method(_set_arc_position, 0.0, 1.0, 0.42)


func _set_arc_position(t: float) -> void:
	var p := _from.lerp(_to, t)
	var arc_h := 44.0 * sin(PI * t)
	global_position = p + Vector2(0.0, -arc_h)


func _on_body_entered(body: Node2D) -> void:
	if _picked:
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if not body is CharacterBody2D:
		return
	if not body.is_in_group("arena_players"):
		return
	if body.has_method("is_knocked_out") and body.call("is_knocked_out"):
		return
	var nm := str(body.name)
	if not nm.is_valid_int():
		return
	var main := get_tree().get_first_node_in_group("arena_main")
	if main == null or not main.has_method("apply_meat_pickup"):
		return
	_picked = true
	main.apply_meat_pickup(
		int(nm), _heal_hp, _meat_uid, str(get_meta("chest_name", ""))
	)
