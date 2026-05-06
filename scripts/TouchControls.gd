extends CanvasLayer

# Maps active touch index → currently pressed action name.
var _active_touches: Dictionary = {}
var _base_modulate: Dictionary = {}

@onready var _left_button: Control = $Root/LeftButton
@onready var _right_button: Control = $Root/RightButton
@onready var _attack_button: Control = $Root/AttackButton
@onready var _jump_button: Control = $Root/JumpButton


func _ready() -> void:
	for b in [_left_button, _right_button, _attack_button, _jump_button]:
		_base_modulate[b] = b.modulate


func _process(_delta: float) -> void:
	_update_visual(_left_button, "move_left")
	_update_visual(_right_button, "move_right")
	_update_visual(_attack_button, "attack")
	_update_visual(_jump_button, "jump")


func _update_visual(btn: Control, action: String) -> void:
	var base: Color = _base_modulate[btn]
	if Input.is_action_pressed(action):
		btn.modulate = Color(base.r, base.g, base.b, minf(1.0, base.a + 0.38))
	else:
		btn.modulate = base


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			var action := _action_at(event.position)
			if action != "":
				_press(event.index, action)
		else:
			_release(event.index)
	elif event is InputEventScreenDrag:
		var current: String = _active_touches.get(event.index, "")
		var new_action := _action_at(event.position)
		if new_action != current:
			_release(event.index)
			if new_action != "":
				_press(event.index, new_action)


func _press(touch_index: int, action: String) -> void:
	_active_touches[touch_index] = action
	Input.action_press(action)


func _release(touch_index: int) -> void:
	if _active_touches.has(touch_index):
		Input.action_release(_active_touches[touch_index])
		_active_touches.erase(touch_index)


func _action_at(pos: Vector2) -> String:
	if _left_button.get_global_rect().has_point(pos):
		return "move_left"
	if _right_button.get_global_rect().has_point(pos):
		return "move_right"
	if _attack_button.get_global_rect().has_point(pos):
		return "attack"
	if _jump_button.get_global_rect().has_point(pos):
		return "jump"
	return ""
