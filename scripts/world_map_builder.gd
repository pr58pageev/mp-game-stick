extends RefCounted
class_name WorldMapBuilder
## Трава — TileMap; деревья — Sprite2D с region (как персонаж), иначе у тайлмапа часто ломается альфа на атласе.

const TILE_SIZE := 16

const GRASS_ATLAS_VARIANTS: Array[Vector2i] = [
	Vector2i(1, 4),
	Vector2i(7, 3),
	Vector2i(8, 3),
	Vector2i(9, 3),
	Vector2i(10, 3),
]

const MAP_W_MIN := 80
const MAP_W_MAX := 140
const MAP_H_MIN := 56
const MAP_H_MAX := 96

const C_GRASS := 0
const C_TREE := 1
const C_WATER := 2

## Дерево на атласе: блок 3×4, левый верх (0,20) … правый низ (2,23).
const TREE_W := 3
const TREE_H := 4
## Верхний ряд и боковые столбцы под кроной — проходимые в сетке; коллизия ствола — средняя колонка, нижние ряды.
const TREE_COLLISION_ROWS := 3
## Уводим коллизию от визуального края: CircleShape2D игрока не должен зацеплять границу тайла.
## Слой коллизии только для деревьев и воды (не земля тайлмапа) — лучи обхода орков и т.п.
const PROP_COLLISION_LAYER := 4

## У дерева — только с севера по высоте ствола; у воды — со всех сторон (см. _spawn_water_collision).
const COLLISION_EDGE_INSET_PX := 14.0
const TREE_ATLAS_TOP_LEFT := Vector2i(0, 20)

const TREES_MIN := 90
const TREES_MAX := 180

## Со всех сторон у резервированной под яму области снят по 1 ряду: трава, без воды и без коллайдера — можно подойти вплотную сверху и с боков (и снизу).
const WATER_APPROACH_MARGIN_TILES := 1

## Резервируемый под яму прямоугольник на карте (тайлы): минимум 5×5, максимум 20×20 (внутри после полей для подхода меньше).
const WATER_PIT_MIN := 5
const WATER_PIT_MAX := 20

const CHEST_COUNT_MIN := 6
const CHEST_COUNT_MAX := 18
const CHEST_STRIP_COUNT_MIN := 2
const CHEST_STRIP_COUNT_MAX := 14

## Подход к краю сетки — сервер добавляет полосу (синхронно у всех клиентов).
const WORLD_EDGE_THRESHOLD_TILES := 20
## Ширина/высота одной полосы расширения (тайлы).
const STRIP_EXTEND_TILES := 150

const DIR_LEFT := 0
const DIR_RIGHT := 1
const DIR_UP := 2
const DIR_DOWN := 3

const ATLAS_IMAGE_PATH := "res://assets/topDown_baseTiles.png"


## Импортированная CompressedTexture2D (как у спрайта игрока). Raw Image→ImageTexture обходил .import
## и на части GPU давал непрозрачный чёрный bbox; альфа исправляется параметрами импорта (fix_alpha_border и т.д.).
static func _load_atlas_texture() -> Texture2D:
	var t: Texture2D = load(ATLAS_IMAGE_PATH) as Texture2D
	if t == null:
		push_error("WorldMapBuilder: не удалось загрузить %s" % ATLAS_IMAGE_PATH)
	return t


static func _ensure_tile(atlas: TileSetAtlasSource, coord: Vector2i) -> void:
	if not atlas.has_tile(coord):
		atlas.create_tile(coord)


static func _register_floor_only(atlas: TileSetAtlasSource, coord: Vector2i) -> void:
	_ensure_tile(atlas, coord)


static func build_tile_set(tile_tex: Texture2D) -> Dictionary:
	var tile_set := TileSet.new()
	tile_set.add_physics_layer(0)
	tile_set.set_physics_layer_collision_layer(0, 1)
	tile_set.set_physics_layer_collision_mask(0, 0)

	var atlas := TileSetAtlasSource.new()
	atlas.texture = tile_tex
	atlas.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
	var source_id: int = tile_set.add_source(atlas)

	for c in GRASS_ATLAS_VARIANTS:
		_register_floor_only(atlas, c)
	for wy in range(7, 10):
		for wx in range(6, 9):
			_register_floor_only(atlas, Vector2i(wx, wy))

	return {"tile_set": tile_set, "source_id": source_id}


static func _pick_random_grass(rng: RandomNumberGenerator) -> Vector2i:
	var i := rng.randi() % GRASS_ATLAS_VARIANTS.size()
	return GRASS_ATLAS_VARIANTS[i]


static func _is_walkable(cell: int) -> bool:
	return cell == C_GRASS


## Клетка в мировых координатах тайла (как у TileMap после сдвига origin).
static func is_tile_walkable_at_world(
	grid: Array,
	grid_w: int,
	grid_h: int,
	tile_origin_world: Vector2i,
	world_cell: Vector2i
) -> bool:
	var ix := world_cell.x - tile_origin_world.x
	var iy := world_cell.y - tile_origin_world.y
	if ix < 0 or iy < 0 or ix >= grid_w or iy >= grid_h:
		return false
	var row: Array = grid[iy] as Array
	return _is_walkable(int(row[ix]))


## Ближайший центр проходимого тайла к точке (у кромки воды центр спрайта часто попадает на C_WATER).
static func nearest_walkable_world_pixel(
	grid: Array,
	grid_w: int,
	grid_h: int,
	tile_origin_world: Vector2i,
	world_px: Vector2,
	world_rect: Rect2,
	max_ring: int = 64
) -> Vector2:
	var ts := float(TILE_SIZE)
	var m := 10.0
	var cx := clampf(world_px.x, world_rect.position.x + m, world_rect.position.x + world_rect.size.x - m)
	var cy := clampf(world_px.y, world_rect.position.y + m, world_rect.position.y + world_rect.size.y - m)
	var tcx := int(floor(cx / ts))
	var tcy := int(floor(cy / ts))
	var origin_cell := Vector2i(tcx, tcy)
	if is_tile_walkable_at_world(grid, grid_w, grid_h, tile_origin_world, origin_cell):
		return Vector2((float(tcx) + 0.5) * ts, (float(tcy) + 0.5) * ts)
	for r in range(1, max_ring + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var wx := tcx + dx
				var wy := tcy + dy
				var wc := Vector2i(wx, wy)
				if is_tile_walkable_at_world(grid, grid_w, grid_h, tile_origin_world, wc):
					return Vector2((float(wx) + 0.5) * ts, (float(wy) + 0.5) * ts)
	return Vector2((float(tcx) + 0.5) * ts, (float(tcy) + 0.5) * ts)


static func cell_kind_at_world(
	grid: Array,
	grid_w: int,
	grid_h: int,
	tile_origin_world: Vector2i,
	world_cell: Vector2i
) -> int:
	var ix := world_cell.x - tile_origin_world.x
	var iy := world_cell.y - tile_origin_world.y
	if ix < 0 or iy < 0 or ix >= grid_w or iy >= grid_h:
		return -1
	var row: Array = grid[iy] as Array
	return int(row[ix])


static func _generate_flat_grass(w: int, h: int) -> Array:
	var grid: Array = []
	for _y in h:
		var row: Array = []
		for _x in w:
			row.append(C_GRASS)
		grid.append(row)
	return grid


static func _tree_footprint_intersects_inflated(
	origins: Array[Vector2i], ox: int, oy: int
) -> bool:
	var new_r := Rect2i(ox, oy, TREE_W, TREE_H)
	for prev in origins:
		var inflated := Rect2i(
			prev.x - 1,
			prev.y - 1,
			TREE_W + 2,
			TREE_H + 2
		)
		if inflated.intersects(new_r):
			return true
	return false


static func _rect_hits_trees(r: Rect2i, tree_origins: Array[Vector2i]) -> bool:
	for o in tree_origins:
		var tr := Rect2i(o.x, o.y, TREE_W, TREE_H)
		if r.intersects(tr):
			return true
	return false


static func _rect_hits_pits(r: Rect2i, pits: Array) -> bool:
	for p in pits:
		var po: Vector2i = p["origin"]
		var psz: Vector2i = p["size"]
		if r.intersects(Rect2i(po.x, po.y, psz.x, psz.y)):
			return true
	return false


static func _grid_cell_under_tree(tree_origins: Array[Vector2i], ix: int, iy: int) -> bool:
	for o in tree_origins:
		if ix >= o.x and ix < o.x + TREE_W and iy >= o.y and iy < o.y + TREE_H:
			return true
	return false


static func _pick_chest_spawn_cells(
	grid: Array,
	w: int,
	h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	want: int
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var margin := 4
	var min_sep := 6
	var attempts := 0
	var max_attempts := maxi(want * 500, 8000)
	while out.size() < want and attempts < max_attempts:
		attempts += 1
		var cx := rng.randi_range(margin, w - 1 - margin)
		var cy := rng.randi_range(margin, h - 1 - margin)
		var row: Array = grid[cy] as Array
		if int(row[cx]) != C_GRASS:
			continue
		if _grid_cell_under_tree(tree_origins, cx, cy):
			continue
		var one := Rect2i(cx, cy, 1, 1)
		if _rect_hits_pits(one, water_pits):
			continue
		var ok := true
		for prev in out:
			if absi(cx - prev.x) + absi(cy - prev.y) < min_sep:
				ok = false
				break
		if ok:
			out.append(Vector2i(cx, cy))
	return out


static func _pick_chest_cells_in_strip(
	grid: Array,
	w: int,
	h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	strip: Rect2i,
	existing_world_cells: Array,
	tile_origin_world: Vector2i,
	want: int
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var inner := 2
	var sx0 := strip.position.x + inner
	var sy0 := strip.position.y + inner
	var sx1 := strip.position.x + strip.size.x - 1 - inner
	var sy1 := strip.position.y + strip.size.y - 1 - inner
	if sx0 > sx1 or sy0 > sy1:
		inner = 1
		sx0 = strip.position.x + inner
		sy0 = strip.position.y + inner
		sx1 = strip.position.x + strip.size.x - 1 - inner
		sy1 = strip.position.y + strip.size.y - 1 - inner
	if sx0 > sx1 or sy0 > sy1:
		return out
	var min_sep := 6
	var attempts := 0
	var max_attempts := maxi(want * 450, 5000)
	while out.size() < want and attempts < max_attempts:
		attempts += 1
		var cx := rng.randi_range(sx0, sx1)
		var cy := rng.randi_range(sy0, sy1)
		var row: Array = grid[cy] as Array
		if int(row[cx]) != C_GRASS:
			continue
		if _grid_cell_under_tree(tree_origins, cx, cy):
			continue
		if _rect_hits_pits(Rect2i(cx, cy, 1, 1), water_pits):
			continue
		var wc := Vector2i(tile_origin_world.x + cx, tile_origin_world.y + cy)
		var ok := true
		for ew in existing_world_cells:
			var ewv: Vector2i = ew as Vector2i
			if absi(wc.x - ewv.x) + absi(wc.y - ewv.y) < min_sep:
				ok = false
				break
		if not ok:
			continue
		for prev in out:
			if absi(cx - prev.x) + absi(cy - prev.y) < min_sep:
				ok = false
				break
		if ok:
			out.append(Vector2i(cx, cy))
	return out


static func _append_chest_spawns_for_strip(
	grid: Array,
	w: int,
	h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	strip: Rect2i,
	tile_origin_for_cells: Vector2i,
	chest_world_accum: Array,
	added_out: Array
) -> void:
	var area := strip.size.x * strip.size.y
	var want_lo := maxi(1, area / 750)
	var want_hi := maxi(3, area / 280)
	var want := rng.randi_range(want_lo, want_hi)
	want = clampi(want, CHEST_STRIP_COUNT_MIN, CHEST_STRIP_COUNT_MAX)
	var locals := _pick_chest_cells_in_strip(
		grid,
		w,
		h,
		rng,
		tree_origins,
		water_pits,
		strip,
		chest_world_accum,
		tile_origin_for_cells,
		want
	)
	for lc in locals:
		var wc := Vector2i(tile_origin_for_cells.x + lc.x, tile_origin_for_cells.y + lc.y)
		chest_world_accum.append(wc)
		added_out.append(wc)


static func _place_water_pits(
	grid: Array, w: int, h: int, rng: RandomNumberGenerator, tree_origins: Array[Vector2i]
) -> Array:
	var pits: Array = []
	for _round in 6:
		for _slot in 6:
			var pw := rng.randi_range(WATER_PIT_MIN, WATER_PIT_MAX)
			var ph := rng.randi_range(WATER_PIT_MIN, WATER_PIT_MAX)
			if w < pw + 2 or h < ph + 2:
				continue
			for _try in 500:
				var px := rng.randi_range(1, w - pw - 1)
				var py := rng.randi_range(1, h - ph - 1)
				var r := Rect2i(px, py, pw, ph)
				if _rect_hits_trees(r, tree_origins):
					continue
				if _rect_hits_pits(r, pits):
					continue
				var m := WATER_APPROACH_MARGIN_TILES
				var pw_w := pw - 2 * m
				var ph_w := ph - 2 * m
				if pw_w < 1 or ph_w < 1:
					continue
				for dy in ph_w:
					for dx in pw_w:
						var row_p: Array = grid[py + m + dy] as Array
						row_p[px + m + dx] = C_WATER
				pits.append({"origin": Vector2i(px, py), "size": Vector2i(pw, ph)})
				break
	return pits


static func _pit_atlas_coord(dx: int, dy: int, pw: int, ph: int) -> Vector2i:
	var xi: int
	var yi: int
	if dy == 0:
		yi = 7
	elif dy == ph - 1:
		yi = 9
	else:
		yi = 8
	if dx == 0:
		xi = 6
	elif dx == pw - 1:
		xi = 8
	else:
		xi = 7
	return Vector2i(xi, yi)


static func _paint_water_pits(
	layer: TileMapLayer, pits: Array, source_id: int, tile_origin: Vector2i = Vector2i.ZERO
) -> void:
	var m := WATER_APPROACH_MARGIN_TILES
	for p in pits:
		var po: Vector2i = p["origin"]
		var psz: Vector2i = p["size"]
		var pw_w := psz.x - 2 * m
		var ph_w := psz.y - 2 * m
		if pw_w < 1 or ph_w < 1:
			continue
		for dy in ph_w:
			for dx in pw_w:
				var ac := _pit_atlas_coord(dx, dy, pw_w, ph_w)
				var wc := Vector2i(
					tile_origin.x + po.x + m + dx,
					tile_origin.y + po.y + m + dy
				)
				layer.set_cell(wc, source_id, ac)


static func _spawn_water_collision(
	world_parent: Node2D, pits: Array, tile_origin: Vector2i = Vector2i.ZERO
) -> void:
	var m := WATER_APPROACH_MARGIN_TILES
	for p in pits:
		var po: Vector2i = p["origin"]
		var psz: Vector2i = p["size"]
		var pw_w := psz.x - 2 * m
		var ph_w := psz.y - 2 * m
		if pw_w < 1 or ph_w < 1:
			continue
		var wx := tile_origin.x + po.x
		var wy := tile_origin.y + po.y
		## Ровно по нарисованным ячейкам воды (_paint_water_pits), без инсета — иначе по краям
		## остаётся «мёртвая» зона без коллайдера и орки заезжают на текстуру.
		var inner_left := float((wx + m) * TILE_SIZE)
		var inner_top := float((wy + m) * TILE_SIZE)
		var body_w := float(pw_w * TILE_SIZE)
		var body_h := float(ph_w * TILE_SIZE)
		## Нижний край декора воды часто ниже сетки тайлов — чуть удлиняем коллайдер вниз.
		var extra_bottom := 12.0
		var coll_h := body_h + extra_bottom
		var body := StaticBody2D.new()
		body.name = "Water_%d_%d" % [wx, wy]
		body.collision_layer = PROP_COLLISION_LAYER
		body.collision_mask = 0
		body.position = Vector2(inner_left + body_w * 0.5, inner_top + coll_h * 0.5)
		var cs := CollisionShape2D.new()
		var rs := RectangleShape2D.new()
		rs.size = Vector2(body_w, coll_h)
		cs.shape = rs
		body.add_child(cs)
		world_parent.add_child(body)


static func _place_trees(grid: Array, w: int, h: int, rng: RandomNumberGenerator) -> Array[Vector2i]:
	var want := rng.randi_range(TREES_MIN, TREES_MAX)
	var origins: Array[Vector2i] = []
	var max_attempts := maxi(8000, want * 250)
	for _attempt in max_attempts:
		if origins.size() >= want:
			break
		## ox >= 1 и правый край с запасом — чтобы слева/справа от силуэта была клетка травы для подхода.
		if w < TREE_W + 2 or h < TREE_H + 1:
			break
		var ox := rng.randi_range(1, w - TREE_W - 1)
		## oy >= 1: верхний проходимый ряд дерева не должен быть строкой 0 карты — иначе с севера некуда подойти.
		var oy := rng.randi_range(1, h - TREE_H)
		if _tree_footprint_intersects_inflated(origins, ox, oy):
			continue
		origins.append(Vector2i(ox, oy))
		for dy in TREE_H:
			for dx in TREE_W:
				var row: Array = grid[oy + dy] as Array
				row[ox + dx] = C_TREE
		for dx in TREE_W:
			var row_top: Array = grid[oy] as Array
			row_top[ox + dx] = C_GRASS
		for dy in range(1, TREE_H):
			var row_mid: Array = grid[oy + dy] as Array
			row_mid[ox + 0] = C_GRASS
			row_mid[ox + TREE_W - 1] = C_GRASS
	return origins


## Деревья как прямые дети depth_parent — общий Y-sort с игроками (без контейнера «Trees»).
## origins — координаты левого верхнего угла силуэта в **локальной сетке**; tile_origin — смещение мира (тайлы).
static func _spawn_trees(
	depth_parent: Node2D,
	tree_origins: Array[Vector2i],
	atlas_full: Texture2D,
	tile_origin: Vector2i = Vector2i.ZERO
) -> void:
	var reg := Rect2(
		float(TREE_ATLAS_TOP_LEFT.x * TILE_SIZE),
		float(TREE_ATLAS_TOP_LEFT.y * TILE_SIZE),
		float(TREE_W * TILE_SIZE),
		float(TREE_H * TILE_SIZE)
	)
	var fw := float(TREE_W * TILE_SIZE)
	var fh := float(TREE_H * TILE_SIZE)
	var coll_h := float(TREE_COLLISION_ROWS * TILE_SIZE) - COLLISION_EDGE_INSET_PX
	## Узже, чем крона: меньше застреваний игрока в коридорах между деревьями.
	var coll_w := minf(fw - 6.0, 22.0)

	var tree_tex := AtlasTexture.new()
	tree_tex.atlas = atlas_full
	tree_tex.region = reg
	tree_tex.filter_clip = true

	for origin in tree_origins:
		var wx: int = tile_origin.x + origin.x
		var wy: int = tile_origin.y + origin.y
		var tr := Node2D.new()
		tr.name = "Tree_%d_%d" % [wx, wy]
		## Якорь — нижний центр спрайта (подножие): Y-sort по global_position.y без y_sort_origin у Node2D.
		tr.position = Vector2(
			float(wx * TILE_SIZE) + fw * 0.5,
			float(wy * TILE_SIZE) + fh
		)

		var spr := Sprite2D.new()
		spr.texture = tree_tex
		spr.centered = false
		spr.position = Vector2(-fw * 0.5, -fh)
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.add_child(spr)

		var body := StaticBody2D.new()
		body.collision_layer = PROP_COLLISION_LAYER
		body.collision_mask = 0
		## Нижний край коллизии у подножия (local y=0); верх на coll_h ниже верха спрайта — с инсетом от севера.
		body.position = Vector2(0.0, -coll_h * 0.5)
		var cs := CollisionShape2D.new()
		var rs := RectangleShape2D.new()
		rs.size = Vector2(coll_w, coll_h)
		cs.shape = rs
		body.add_child(cs)
		tr.add_child(body)

		depth_parent.add_child(tr)


static func spawn_tile_for_slot(
	grid: Array,
	w: int,
	h: int,
	center: Vector2i,
	slot: int,
	tile_origin: Vector2i = Vector2i.ZERO
) -> Vector2i:
	var offsets: Array[Vector2i] = [
		Vector2i(0, 0),
		Vector2i(4, 0),
		Vector2i(-4, 0),
		Vector2i(0, 4),
		Vector2i(0, -4),
		Vector2i(7, 2),
		Vector2i(-7, -2),
		Vector2i(9, -3),
	]
	var o: Vector2i = offsets[slot % offsets.size()]
	var p := center + o
	p.x = clampi(p.x, 1, w - 2)
	p.y = clampi(p.y, 1, h - 2)
	var rowp: Array = grid[p.y] as Array
	if _is_walkable(int(rowp[p.x])):
		return Vector2i(tile_origin.x + p.x, tile_origin.y + p.y)
	var max_r := maxi(w, h)
	for radius in range(1, max_r):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dy) != radius:
					continue
				var t := Vector2i(center.x + dx + o.x, center.y + dy + o.y)
				t.x = clampi(t.x, 1, w - 2)
				t.y = clampi(t.y, 1, h - 2)
				var rowt: Array = grid[t.y] as Array
				if _is_walkable(int(rowt[t.x])):
					return Vector2i(tile_origin.x + t.x, tile_origin.y + t.y)
	var ix := clampi(center.x + o.x, 1, w - 2)
	var iy := clampi(center.y + o.y, 1, h - 2)
	return Vector2i(tile_origin.x + ix, tile_origin.y + iy)


static func tile_center_to_world(tile: Vector2i) -> Vector2:
	return Vector2(
		(float(tile.x) + 0.5) * float(TILE_SIZE), (float(tile.y) + 0.5) * float(TILE_SIZE)
	)


static func strip_rng_seed(world_seed: int, dir_code: int, strip_idx: int) -> int:
	var z := world_seed ^ int(dir_code * 73856093) ^ int(strip_idx * 19349663)
	if z == 0:
		z = 920389237
	return z


static func paint_grass_rect(
	layer: TileMapLayer,
	grid: Array,
	rng: RandomNumberGenerator,
	source_id: int,
	tile_origin_world: Vector2i,
	rect_internal: Rect2i
) -> void:
	var x1 := rect_internal.position.x
	var y1 := rect_internal.position.y
	var x2 := rect_internal.position.x + rect_internal.size.x
	var y2 := rect_internal.position.y + rect_internal.size.y
	for y in range(y1, y2):
		if y < 0 or y >= grid.size():
			continue
		var row: Array = grid[y] as Array
		for x in range(x1, x2):
			if x < 0 or x >= row.size():
				continue
			var cell := int(row[x])
			if cell == C_WATER:
				continue
			if cell != C_GRASS and cell != C_TREE:
				continue
			layer.set_cell(
				Vector2i(tile_origin_world.x + x, tile_origin_world.y + y),
				source_id,
				_pick_random_grass(rng)
			)


static func _rect_fully_inside(outer: Rect2i, inner: Rect2i) -> bool:
	var o_end := outer.position + outer.size
	var i_end := inner.position + inner.size
	return (
		inner.position.x >= outer.position.x
		and inner.position.y >= outer.position.y
		and i_end.x <= o_end.x
		and i_end.y <= o_end.y
	)


static func _place_trees_in_strip(
	grid: Array,
	w: int,
	h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	strip: Rect2i
) -> Array[Vector2i]:
	var new_o: Array[Vector2i] = []
	if w < TREE_W + 2 or h < TREE_H + 1:
		return new_o
	var sx0 := strip.position.x
	var sy0 := strip.position.y
	var sx1 := strip.position.x + strip.size.x
	var sy1 := strip.position.y + strip.size.y
	var min_ox := maxi(sx0 + 1, 1)
	var max_ox := mini(sx1 - TREE_W - 1, w - TREE_W - 1)
	var min_oy := maxi(sy0 + 1, 1)
	var max_oy := mini(sy1 - TREE_H, h - TREE_H)
	if min_ox > max_ox or min_oy > max_oy:
		return new_o
	var area := strip.size.x * strip.size.y
	var want := rng.randi_range(maxi(4, area / 700), maxi(25, area / 90))
	var max_attempts := maxi(6000, want * 200)
	for _attempt in max_attempts:
		if new_o.size() >= want:
			break
		var ox := rng.randi_range(min_ox, max_ox)
		var oy := rng.randi_range(min_oy, max_oy)
		var footprint := Rect2i(ox, oy, TREE_W, TREE_H)
		if not _rect_fully_inside(strip, footprint):
			continue
		if _tree_footprint_intersects_inflated(tree_origins, ox, oy):
			continue
		if _tree_footprint_intersects_inflated(new_o, ox, oy):
			continue
		tree_origins.append(Vector2i(ox, oy))
		new_o.append(Vector2i(ox, oy))
		for dy in TREE_H:
			for dx in TREE_W:
				var row: Array = grid[oy + dy] as Array
				row[ox + dx] = C_TREE
		for dx in TREE_W:
			var row_top: Array = grid[oy] as Array
			row_top[ox + dx] = C_GRASS
		for dy in range(1, TREE_H):
			var row_mid: Array = grid[oy + dy] as Array
			row_mid[ox + 0] = C_GRASS
			row_mid[ox + TREE_W - 1] = C_GRASS
	return new_o


static func _place_water_pits_in_strip(
	grid: Array,
	w: int,
	h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	pits_accum: Array,
	strip: Rect2i
) -> Array:
	var pits: Array = []
	for _round in 3:
		for _slot in 4:
			var pw := rng.randi_range(WATER_PIT_MIN, WATER_PIT_MAX)
			var ph := rng.randi_range(WATER_PIT_MIN, WATER_PIT_MAX)
			if w < pw + 2 or h < ph + 2:
				continue
			for _try in 400:
				var px := rng.randi_range(1, w - pw - 1)
				var py := rng.randi_range(1, h - ph - 1)
				var r := Rect2i(px, py, pw, ph)
				if not _rect_fully_inside(strip, r):
					continue
				if _rect_hits_trees(r, tree_origins):
					continue
				if _rect_hits_pits(r, pits_accum):
					continue
				if _rect_hits_pits(r, pits):
					continue
				var m := WATER_APPROACH_MARGIN_TILES
				var pw_w := pw - 2 * m
				var ph_w := ph - 2 * m
				if pw_w < 1 or ph_w < 1:
					continue
				for dy in ph_w:
					for dx in pw_w:
						var row_p: Array = grid[py + m + dy] as Array
						row_p[px + m + dx] = C_WATER
				var pd := {"origin": Vector2i(px, py), "size": Vector2i(pw, ph)}
				pits.append(pd)
				pits_accum.append(pd)
				break
	return pits


static func extend_strip_right(
	grid: Array,
	tile_origin_world: Vector2i,
	add_w: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	ground: TileMapLayer,
	water_layer: TileMapLayer,
	world_parent: Node2D,
	depth_parent: Node2D,
	atlas_tex: Texture2D,
	source_id: int,
	chest_world_accum: Array,
	chest_added_out: Array
) -> Vector2i:
	var old_h := grid.size()
	if old_h == 0:
		return tile_origin_world
	var old_w := (grid[0] as Array).size()
	for iy in old_h:
		var row: Array = grid[iy] as Array
		for _i in add_w:
			row.append(C_GRASS)
	var strip := Rect2i(old_w, 0, add_w, old_h)
	var new_trees := _place_trees_in_strip(grid, old_w + add_w, old_h, rng, tree_origins, strip)
	var new_pits := _place_water_pits_in_strip(
		grid, old_w + add_w, old_h, rng, tree_origins, water_pits, strip
	)
	paint_grass_rect(ground, grid, rng, source_id, tile_origin_world, strip)
	_paint_water_pits(water_layer, new_pits, source_id, tile_origin_world)
	_spawn_water_collision(world_parent, new_pits, tile_origin_world)
	_spawn_trees(depth_parent, new_trees, atlas_tex, tile_origin_world)
	_append_chest_spawns_for_strip(
		grid,
		old_w + add_w,
		old_h,
		rng,
		tree_origins,
		water_pits,
		strip,
		tile_origin_world,
		chest_world_accum,
		chest_added_out
	)
	return tile_origin_world


static func extend_strip_left(
	grid: Array,
	tile_origin_world: Vector2i,
	add_w: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	ground: TileMapLayer,
	water_layer: TileMapLayer,
	world_parent: Node2D,
	depth_parent: Node2D,
	atlas_tex: Texture2D,
	source_id: int,
	chest_world_accum: Array,
	chest_added_out: Array
) -> Vector2i:
	var old_h := grid.size()
	if old_h == 0:
		return tile_origin_world
	var old_w := (grid[0] as Array).size()
	for iy in old_h:
		var row: Array = grid[iy] as Array
		var prefix: Array = []
		for _i in add_w:
			prefix.append(C_GRASS)
		var new_row: Array = []
		new_row.append_array(prefix)
		new_row.append_array(row)
		grid[iy] = new_row
	for i in tree_origins.size():
		var o: Vector2i = tree_origins[i]
		tree_origins[i] = Vector2i(o.x + add_w, o.y)
	for p in water_pits:
		var po: Vector2i = p["origin"]
		p["origin"] = Vector2i(po.x + add_w, po.y)
	var new_origin := Vector2i(tile_origin_world.x - add_w, tile_origin_world.y)
	var strip := Rect2i(0, 0, add_w, old_h)
	var gw := old_w + add_w
	var new_trees := _place_trees_in_strip(grid, gw, old_h, rng, tree_origins, strip)
	var new_pits := _place_water_pits_in_strip(grid, gw, old_h, rng, tree_origins, water_pits, strip)
	paint_grass_rect(ground, grid, rng, source_id, new_origin, strip)
	_paint_water_pits(water_layer, new_pits, source_id, new_origin)
	_spawn_water_collision(world_parent, new_pits, new_origin)
	_spawn_trees(depth_parent, new_trees, atlas_tex, new_origin)
	_append_chest_spawns_for_strip(
		grid,
		gw,
		old_h,
		rng,
		tree_origins,
		water_pits,
		strip,
		new_origin,
		chest_world_accum,
		chest_added_out
	)
	return new_origin


static func extend_strip_down(
	grid: Array,
	tile_origin_world: Vector2i,
	add_h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	ground: TileMapLayer,
	water_layer: TileMapLayer,
	world_parent: Node2D,
	depth_parent: Node2D,
	atlas_tex: Texture2D,
	source_id: int,
	chest_world_accum: Array,
	chest_added_out: Array
) -> Vector2i:
	var old_h := grid.size()
	if old_h == 0:
		return tile_origin_world
	var old_w := (grid[0] as Array).size()
	for _i in add_h:
		var row: Array = []
		row.resize(old_w)
		for x in old_w:
			row[x] = C_GRASS
		grid.append(row)
	var strip := Rect2i(0, old_h, old_w, add_h)
	var gh := old_h + add_h
	var new_trees := _place_trees_in_strip(grid, old_w, gh, rng, tree_origins, strip)
	var new_pits := _place_water_pits_in_strip(grid, old_w, gh, rng, tree_origins, water_pits, strip)
	paint_grass_rect(ground, grid, rng, source_id, tile_origin_world, strip)
	_paint_water_pits(water_layer, new_pits, source_id, tile_origin_world)
	_spawn_water_collision(world_parent, new_pits, tile_origin_world)
	_spawn_trees(depth_parent, new_trees, atlas_tex, tile_origin_world)
	_append_chest_spawns_for_strip(
		grid,
		old_w,
		gh,
		rng,
		tree_origins,
		water_pits,
		strip,
		tile_origin_world,
		chest_world_accum,
		chest_added_out
	)
	return tile_origin_world


static func extend_strip_up(
	grid: Array,
	tile_origin_world: Vector2i,
	add_h: int,
	rng: RandomNumberGenerator,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	ground: TileMapLayer,
	water_layer: TileMapLayer,
	world_parent: Node2D,
	depth_parent: Node2D,
	atlas_tex: Texture2D,
	source_id: int,
	chest_world_accum: Array,
	chest_added_out: Array
) -> Vector2i:
	var old_h := grid.size()
	if old_h == 0:
		return tile_origin_world
	var old_w := (grid[0] as Array).size()
	for _i in add_h:
		var row: Array = []
		row.resize(old_w)
		for x in old_w:
			row[x] = C_GRASS
		grid.insert(0, row)
	for i in tree_origins.size():
		var o: Vector2i = tree_origins[i]
		tree_origins[i] = Vector2i(o.x, o.y + add_h)
	for p in water_pits:
		var po: Vector2i = p["origin"]
		p["origin"] = Vector2i(po.x, po.y + add_h)
	var new_origin := Vector2i(tile_origin_world.x, tile_origin_world.y - add_h)
	var strip := Rect2i(0, 0, old_w, add_h)
	var gh := old_h + add_h
	var new_trees := _place_trees_in_strip(grid, old_w, gh, rng, tree_origins, strip)
	var new_pits := _place_water_pits_in_strip(grid, old_w, gh, rng, tree_origins, water_pits, strip)
	paint_grass_rect(ground, grid, rng, source_id, new_origin, strip)
	_paint_water_pits(water_layer, new_pits, source_id, new_origin)
	_spawn_water_collision(world_parent, new_pits, new_origin)
	_spawn_trees(depth_parent, new_trees, atlas_tex, new_origin)
	_append_chest_spawns_for_strip(
		grid,
		old_w,
		gh,
		rng,
		tree_origins,
		water_pits,
		strip,
		new_origin,
		chest_world_accum,
		chest_added_out
	)
	return new_origin


## Одна полоса расширения; strip_idx и world_seed задают детерминированный RNG (мультиплеер + сохранение).
static func extend_world_strip(
	dir_code: int,
	grid: Array,
	tile_origin_world: Vector2i,
	strip_idx: int,
	world_seed: int,
	tree_origins: Array[Vector2i],
	water_pits: Array,
	ground: TileMapLayer,
	water_layer: TileMapLayer,
	world_parent: Node2D,
	depth_parent: Node2D,
	atlas_tex: Texture2D,
	source_id: int,
	chest_world_accum: Array,
	chest_added_out: Array
) -> Vector2i:
	chest_added_out.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = strip_rng_seed(world_seed, dir_code, strip_idx)
	var add := STRIP_EXTEND_TILES
	match dir_code:
		DIR_RIGHT:
			return extend_strip_right(
				grid,
				tile_origin_world,
				add,
				rng,
				tree_origins,
				water_pits,
				ground,
				water_layer,
				world_parent,
				depth_parent,
				atlas_tex,
				source_id,
				chest_world_accum,
				chest_added_out
			)
		DIR_LEFT:
			return extend_strip_left(
				grid,
				tile_origin_world,
				add,
				rng,
				tree_origins,
				water_pits,
				ground,
				water_layer,
				world_parent,
				depth_parent,
				atlas_tex,
				source_id,
				chest_world_accum,
				chest_added_out
			)
		DIR_UP:
			return extend_strip_up(
				grid,
				tile_origin_world,
				add,
				rng,
				tree_origins,
				water_pits,
				ground,
				water_layer,
				world_parent,
				depth_parent,
				atlas_tex,
				source_id,
				chest_world_accum,
				chest_added_out
			)
		DIR_DOWN:
			return extend_strip_down(
				grid,
				tile_origin_world,
				add,
				rng,
				tree_origins,
				water_pits,
				ground,
				water_layer,
				world_parent,
				depth_parent,
				atlas_tex,
				source_id,
				chest_world_accum,
				chest_added_out
			)
	return tile_origin_world


## Травяной пол под всем миром, в том числе под клетками дерева — иначе под полупрозрачными
## пикселями спрайта дерева проступает цвет фона viewport (тайлы там не рисовались).
## Воду рисует отдельный слой; ячейки C_WATER здесь пропускаем.
static func paint_grass_only(
	layer: TileMapLayer,
	grid: Array,
	rng: RandomNumberGenerator,
	source_id: int,
	tile_origin: Vector2i = Vector2i.ZERO
) -> void:
	var hh := grid.size()
	if hh == 0:
		return
	var ww: int = (grid[0] as Array).size()
	for y in hh:
		var row: Array = grid[y] as Array
		for x in ww:
			var cell := int(row[x])
			if cell == C_WATER:
				continue
			if cell != C_GRASS and cell != C_TREE:
				continue
			layer.set_cell(
				Vector2i(tile_origin.x + x, tile_origin.y + y),
				source_id,
				_pick_random_grass(rng)
			)


static func create_tilemap(world_parent: Node2D, depth_parent: Node2D, rng: RandomNumberGenerator) -> Dictionary:
	var tex: Texture2D = _load_atlas_texture()
	var built: Dictionary = build_tile_set(tex)
	var tile_set: TileSet = built["tile_set"] as TileSet
	var source_id: int = int(built["source_id"])

	var map_w := rng.randi_range(MAP_W_MIN, MAP_W_MAX)
	var map_h := rng.randi_range(MAP_H_MIN, MAP_H_MAX)
	var grid := _generate_flat_grass(map_w, map_h)
	var tree_origins := _place_trees(grid, map_w, map_h, rng)
	var water_pits := _place_water_pits(grid, map_w, map_h, rng, tree_origins)

	var ground := TileMapLayer.new()
	ground.name = "GroundTileMap"
	ground.tile_set = tile_set
	world_parent.add_child(ground)
	paint_grass_only(ground, grid, rng, source_id)

	var water_layer := TileMapLayer.new()
	water_layer.name = "WaterTileMap"
	water_layer.tile_set = tile_set
	water_layer.z_index = 1
	world_parent.add_child(water_layer)
	_paint_water_pits(water_layer, water_pits, source_id)

	_spawn_water_collision(world_parent, water_pits)

	_spawn_trees(depth_parent, tree_origins, tex)

	var want_chests := rng.randi_range(CHEST_COUNT_MIN, CHEST_COUNT_MAX)
	var chest_locals := _pick_chest_spawn_cells(
		grid, map_w, map_h, rng, tree_origins, water_pits, want_chests
	)
	var chest_world_cells: Array = []
	var tile_origin_gen := Vector2i.ZERO
	for cl in chest_locals:
		chest_world_cells.append(Vector2i(tile_origin_gen.x + cl.x, tile_origin_gen.y + cl.y))

	var pixel_w := float(map_w * TILE_SIZE)
	var pixel_h := float(map_h * TILE_SIZE)
	var center_cell := Vector2i(map_w / 2, map_h / 2)
	return {
		"tile_map": ground,
		"grid": grid,
		"grid_w": map_w,
		"grid_h": map_h,
		"world_rect": Rect2(0.0, 0.0, pixel_w, pixel_h),
		"spawn_center_cell": center_cell,
		"water_pits": water_pits,
		"tree_origins": tree_origins,
		"chest_world_cells": chest_world_cells,
		"atlas_texture": tex,
		"source_id": source_id,
		"tile_origin_world": Vector2i.ZERO,
	}
