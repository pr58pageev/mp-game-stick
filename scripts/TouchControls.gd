extends CanvasLayer
## Виртуальный джойстик: отдаёт аналоговый вектор в группе `touch_analog`.

const MAX_OFFSET := 52.0

var virtual_axis: Vector2 = Vector2.ZERO
var _attack_armed: bool = false

@onready var _base: Panel = $Root/Joystick/JoystickBase
@onready var _knob: Panel = $Root/Joystick/JoystickBase/Knob
@onready var _attack_btn: Button = $Root/AttackButton
@onready var _revive_btn: Button = $Root/ReviveButton

var _grabbed: bool = false
var _grab_touch_index: int = -1


func _ready() -> void:
	add_to_group("touch_analog")
	_style_circle_panel(_base, 80.0, Color(1.0, 1.0, 1.0, 0.22))
	_style_circle_panel(_knob, 22.0, Color(1.0, 1.0, 1.0, 0.55))
	call_deferred("_reset_knob")
	if _attack_btn:
		_style_round_attack_button()
		_attack_btn.pressed.connect(_on_attack_pressed)
	if _revive_btn:
		_revive_btn.pressed.connect(_on_revive_pressed)


func _process(_delta: float) -> void:
	if _revive_btn == null:
		return
	var main := get_tree().get_first_node_in_group("arena_main")
	var show_r := false
	if main and main.has_method("local_can_show_revive_button"):
		show_r = main.local_can_show_revive_button()
	_revive_btn.visible = show_r


func _on_revive_pressed() -> void:
	var main := get_tree().get_first_node_in_group("arena_main")
	if main and main.has_method("try_revive_nearby_from_local_player"):
		main.try_revive_nearby_from_local_player()


func consume_attack_pressed() -> bool:
	var v := _attack_armed
	_attack_armed = false
	return v


func _on_attack_pressed() -> void:
	_attack_armed = true


func get_virtual_axis() -> Vector2:
	return virtual_axis


func _style_circle_panel(p: Panel, corner_radius: float, color: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(int(corner_radius))
	p.add_theme_stylebox_override("panel", sb)


func _style_round_attack_button() -> void:
	if _attack_btn == null:
		return
	var d := 112.0 * 1.5
	var r := int(round(d * 0.5))
	_attack_btn.text = ""
	# flat=true скрывает фон по состояниям — кнопка остаётся невидимой без текста/иконки.
	_attack_btn.flat = false
	_attack_btn.custom_minimum_size = Vector2(d, d)
	var col_n := Color(0.52, 0.52, 0.55, 0.48)
	var col_h := Color(0.6, 0.6, 0.63, 0.58)
	var col_p := Color(0.4, 0.4, 0.43, 0.62)
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color = col_n
	sb_n.set_corner_radius_all(r)
	_attack_btn.add_theme_stylebox_override("normal", sb_n)
	var sb_h := StyleBoxFlat.new()
	sb_h.bg_color = col_h
	sb_h.set_corner_radius_all(r)
	_attack_btn.add_theme_stylebox_override("hover", sb_h)
	var sb_p := StyleBoxFlat.new()
	sb_p.bg_color = col_p
	sb_p.set_corner_radius_all(r)
	_attack_btn.add_theme_stylebox_override("pressed", sb_p)
	var sb_f := StyleBoxFlat.new()
	sb_f.bg_color = Color(0.65, 0.65, 0.68, 0.22)
	sb_f.set_corner_radius_all(r)
	sb_f.set_border_width_all(2)
	sb_f.border_color = Color(0.9, 0.9, 0.92, 0.45)
	_attack_btn.add_theme_stylebox_override("focus", sb_f)


func _reset_knob() -> void:
	virtual_axis = Vector2.ZERO
	if _knob and _base:
		_knob.position = _base.size * 0.5 - _knob.size * 0.5


func _apply_stick_from_global(global_pos: Vector2) -> void:
	if _base == null or _knob == null:
		return
	var origin := _base.global_position
	var lp := global_pos - origin
	var center := _base.size * 0.5
	var delta := lp - center
	var len := delta.length()
	if len > MAX_OFFSET and len > 0.0001:
		delta = delta / len * MAX_OFFSET
	virtual_axis = delta / MAX_OFFSET
	_knob.position = center + delta - _knob.size * 0.5


func _input(event: InputEvent) -> void:
	var rect := _base.get_global_rect() if _base else Rect2()
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			if rect.has_point(st.position):
				_grabbed = true
				_grab_touch_index = st.index
				_apply_stick_from_global(st.position)
		else:
			if st.index == _grab_touch_index:
				_grabbed = false
				_grab_touch_index = -1
				_reset_knob()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if _grabbed and sd.index == _grab_touch_index:
			_apply_stick_from_global(sd.position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if rect.has_point(mb.position):
					_grabbed = true
					_grab_touch_index = -9
					_apply_stick_from_global(mb.position)
			elif _grab_touch_index == -9:
				_grabbed = false
				_grab_touch_index = -1
				_reset_knob()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _grabbed and _grab_touch_index == -9:
			_apply_stick_from_global(mm.position)
