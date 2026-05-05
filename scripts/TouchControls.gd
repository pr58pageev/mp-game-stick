extends CanvasLayer


func _ready() -> void:
	_wire("Root/LeftButton", "move_left")
	_wire("Root/RightButton", "move_right")
	_wire("Root/JumpButton", "jump")


func _wire(path: String, action: String) -> void:
	var button := get_node(path) as Button
	button.button_down.connect(func() -> void: Input.action_press(action))
	button.button_up.connect(func() -> void: Input.action_release(action))
