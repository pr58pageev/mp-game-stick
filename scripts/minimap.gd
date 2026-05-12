extends TextureRect

## Квадрат области мира на миникарте (тайлы).
@export var world_side_tiles: int = 100
@export var zoom_side_tiles: int = 100

## Внутреннее разрешение растрового буфера (меньше — быстрее; на экран тянется nearest).
@export var render_pixels: int = 96
## Минимальный интервал между полными перерисовками (сек).
@export var redraw_interval_sec: float = 0.22
## Не перерисовывать пока игрок в том же тайле и другие не сдвинулись (экономит CPU/GPU).
@export var skip_when_stationary: bool = true

## В редакторе / отладке: печатать время каждой отрисовки.
@export var log_every_redraw_ms: bool = false
## Логировать только если отрисовка медленнее (мс).
@export var log_slow_redraw_above_ms: float = 8.0

var _img: Image
var _tex: ImageTexture

var _accum: float = 0.0
var _last_player_cell := Vector2i(2147483647, 2147483647)
var _last_others_sig: int = -982374623
var _had_any_draw := false

func _ready() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(224, 224)
	size = custom_minimum_size
	set_process(true)
	_recreate_buffer()


func _recreate_buffer() -> void:
	var rw := clampi(render_pixels, 48, 256)
	_img = Image.create(rw, rw, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.new()
	texture = _tex


func _process(delta: float) -> void:
	if GameState.is_dedicated_server:
		return
	_accum += delta
	if _accum < redraw_interval_sec:
		return
	_accum = 0.0

	var main := get_tree().get_first_node_in_group("arena_main")
	if main == null or not main.has_method("get_minimap_snapshot"):
		return
	var snap: Dictionary = main.get_minimap_snapshot()
	if snap.is_empty():
		return

	var ts := float(WorldMapBuilder.TILE_SIZE)
	var ppos: Vector2 = snap["player_pos"]
	var pcx := int(floor(ppos.x / ts))
	var pcy := int(floor(ppos.y / ts))
	var sig := _others_signature(snap)

	if skip_when_stationary and _had_any_draw:
		if pcx == _last_player_cell.x and pcy == _last_player_cell.y and sig == _last_others_sig:
			return

	_last_player_cell = Vector2i(pcx, pcy)
	_last_others_sig = sig

	var rp := clampi(render_pixels, 48, 256)
	if _img.get_width() != rp or _img.get_height() != rp:
		_recreate_buffer()

	var t0 := Time.get_ticks_usec()
	_redraw(snap)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_had_any_draw = true

	if log_every_redraw_ms:
		print("[Minimap] redraw %.2f ms internal=%dx%d" % [ms, rp, rp])
	elif ms >= log_slow_redraw_above_ms:
		var now := Time.get_ticks_msec()
		if not has_meta("_mw_last_warn"):
			set_meta("_mw_last_warn", 0)
		var last: int = int(get_meta("_mw_last_warn"))
		if now - last > 2500:
			set_meta("_mw_last_warn", now)
			push_warning(
				"[Minimap] медленная отрисовка: %.2f ms (внутр. %d² px; интервал %.2fs). "
				+ "Уменьши render_pixels или увеличь redraw_interval_sec."
				% [ms, rp, redraw_interval_sec]
			)


func _others_signature(snap: Dictionary) -> int:
	var h: int = 913337
	if not snap.has("others"):
		return h
	var others: Array = snap["others"] as Array
	h = hash(h + others.size())
	var i := 0
	for op in others:
		if op is Vector2:
			var v: Vector2 = op
			h = hash(
				h + int(v.x / 12.0) * (17 + i) + int(v.y / 12.0) * (31 + i)
			)
			i += 1
	return h


func _redraw(snap: Dictionary) -> void:
	var grid: Array = snap["grid"]
	var gw: int = int(snap["gw"])
	var gh: int = int(snap["gh"])
	var origin: Vector2i = snap["origin"]
	var ppos: Vector2 = snap["player_pos"]
	var ts := float(WorldMapBuilder.TILE_SIZE)
	var pcx := int(floor(ppos.x / ts))
	var pcy := int(floor(ppos.y / ts))
	var cap := maxi(8, world_side_tiles)
	var side := clampi(zoom_side_tiles, 8, cap)
	var half := side / 2
	var x0 := pcx - half
	var y0 := pcy - half
	var iw := _img.get_width()
	var ih := _img.get_height()
	for py in ih:
		for px in iw:
			var tcx := x0 + int((float(px) + 0.5) * float(side) / float(iw))
			var tcy := y0 + int((float(py) + 0.5) * float(side) / float(ih))
			var k := WorldMapBuilder.cell_kind_at_world(grid, gw, gh, origin, Vector2i(tcx, tcy))
			_img.set_pixel(px, py, _color_for_kind(k))
	if snap.has("others"):
		for op in snap["others"] as Array:
			if op is Vector2:
				_plot_actor_pixel(op as Vector2, x0, y0, side, iw, ih, Color(1.0, 0.42, 0.32, 1.0), ts)
	_plot_actor_pixel(ppos, x0, y0, side, iw, ih, Color(1.0, 0.92, 0.15, 1.0), ts)
	_tex.set_image(_img)


func _plot_actor_pixel(
	world_px: Vector2,
	x0: int,
	y0: int,
	side: int,
	iw: int,
	ih: int,
	col: Color,
	ts: float
) -> void:
	var tcx := int(floor(world_px.x / ts))
	var tcy := int(floor(world_px.y / ts))
	var rel_x := (float(tcx - x0) + 0.5) / float(side)
	var rel_y := (float(tcy - y0) + 0.5) / float(side)
	if rel_x < 0.0 or rel_x > 1.0 or rel_y < 0.0 or rel_y > 1.0:
		return
	var mpx := int(rel_x * float(iw))
	var mpy := int(rel_y * float(ih))
	mpx = clampi(mpx, 1, iw - 2)
	mpy = clampi(mpy, 1, ih - 2)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var ix := mpx + dx
			var iy := mpy + dy
			if ix >= 0 and ix < iw and iy >= 0 and iy < ih:
				_img.set_pixel(ix, iy, col)


func _color_for_kind(k: int) -> Color:
	match k:
		-1:
			return Color(0.06, 0.07, 0.09, 1.0)
		WorldMapBuilder.C_GRASS:
			return Color(0.28, 0.58, 0.24, 1.0)
		WorldMapBuilder.C_TREE:
			return Color(0.14, 0.38, 0.14, 1.0)
		WorldMapBuilder.C_WATER:
			return Color(0.18, 0.4, 0.78, 1.0)
	return Color(0.35, 0.35, 0.35, 1.0)
