extends Node2D

const PLAYER_SCENE := preload("res://scenes/Player.tscn")
const CHEST_SCENE := preload("res://scenes/Chest.tscn")
const ORC_SCENE := preload("res://scenes/Orc.tscn")
const MEAT_SCENE := preload("res://scenes/DroppedMeat.tscn")
const MAX_ORCS := 30
const ORC_SPAWN_INTERVAL_SEC := 2.2
const ORC_MELEE_DAMAGE := 15
const CAMERA_ZOOM := 3
const MELEE_RANGE := 60.0
const MELEE_DAMAGE := 20
const REVIVE_RANGE := 64.0
const MEAT_HEAL_LARGE := 50
## Меньше большого в 1.5 раза (50 / 1.5).
const MEAT_HEAL_SMALL := 33
const MEAT_COOLDOWN_MIN_MS := 60_000
const MEAT_COOLDOWN_MAX_MS := 120_000
const PLAYER_AUTO_RESPAWN_DELAY_MS := 15_000
const PLAYER_RESPAWN_RADIUS_TILES := 150

## Прямые дети: деревья и CharacterBody2D игроков — общий Y-sort (ниже по экрану поверх).
@onready var _players: Node2D = $DepthSort
@onready var _orcs: Node2D = $DepthSort/Orcs
@onready var _status_label: Label = $UIScore/ScoreLabel
@onready var _arena_camera: Camera2D = $ArenaCamera

var _world_rng := RandomNumberGenerator.new()
var _grid: Array = []
var _grid_w: int = 0
var _grid_h: int = 0
var _spawn_center_cell: Vector2i = Vector2i.ZERO
var _enet_log_addr_by_peer: Dictionary = {}
var _leave_arena_manual: bool = false
var _mp_signals_done: bool = false

var _ground_layer: TileMapLayer
var _water_layer: TileMapLayer
var _atlas_tex: Texture2D
var _source_id: int = 0
var _tile_origin_world: Vector2i = Vector2i.ZERO
var _tree_origins: Array[Vector2i] = []
var _water_pits: Array = []
var _chest_world_cells: Array[Vector2i] = []
## Совпадает с порядком букв в WorldSave ext_log.
var _strip_count_by_char: Dictionary = {"l": 0, "r": 0, "u": 0, "d": 0}

var _autosave_dt: float = 0.0
var _next_orc_id: int = 0
var _orc_spawn_acc: float = 0.0
var _orc_sync_acc: float = 0.0
var _orc_save_acc: float = 0.0
var _next_meat_uid: int = 0
## Сундук Chest_*: { "active_uid": int, "cooldown_until_ms": int }.
var _chest_meat_state: Dictionary = {}
var _player_auto_respawn_at_ms: Dictionary = {}
var _player_auto_respawn_death_pos: Dictionary = {}


func _mp_log(msg: String) -> void:
	print("%s %s" % [Time.get_datetime_string_from_system(), msg])


func _melee_hit_point(n: Node2D) -> Vector2:
	if n.has_method("get_combat_anchor"):
		return n.call("get_combat_anchor") as Vector2
	return n.global_position


func player_request_melee(attacker_peer_id: int) -> void:
	if multiplayer.multiplayer_peer != null:
		if multiplayer.is_server():
			_resolve_melee_strike(attacker_peer_id)
		else:
			request_melee_attack.rpc_id(1)
	else:
		_resolve_melee_strike(attacker_peer_id)


func _resolve_melee_strike(attacker_id: int) -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	var attacker_node := _players.get_node_or_null(str(attacker_id)) as Node2D
	if attacker_node == null:
		return
	if attacker_node.has_method("is_knocked_out") and attacker_node.call("is_knocked_out"):
		return
	var origin := _melee_hit_point(attacker_node)
	if multiplayer.multiplayer_peer != null:
		rpc_play_melee_visual.rpc(attacker_id)
	else:
		var ap := _players.get_node_or_null(str(attacker_id))
		if ap and ap.has_method("play_melee_visual"):
			ap.play_melee_visual()
	var r2 := MELEE_RANGE * MELEE_RANGE
	for c in _players.get_children():
		if not c is CharacterBody2D:
			continue
		if not str(c.name).is_valid_int():
			continue
		var pid := int(str(c.name))
		if pid == attacker_id:
			continue
		if c.has_method("is_knocked_out") and c.call("is_knocked_out"):
			continue
		if origin.distance_squared_to(_melee_hit_point(c as Node2D)) <= r2:
			_apply_player_damage(pid, MELEE_DAMAGE)
	for n in get_tree().get_nodes_in_group("melee_hurt_targets"):
		if not is_instance_valid(n):
			continue
		if n is CharacterBody2D:
			var nm := str(n.name)
			if nm.is_valid_int():
				continue
		if origin.distance_squared_to(_melee_hit_point(n as Node2D)) > r2:
			continue
		if n.has_method("take_melee_damage"):
			n.call("take_melee_damage", MELEE_DAMAGE, attacker_id)


func _apply_player_damage(peer_id: int, amount: int) -> void:
	var p = _players.get_node_or_null(str(peer_id))
	if p == null or not p.has_method("server_apply_damage"):
		return
	var was_ko := false
	if p.has_method("is_knocked_out"):
		was_ko = p.call("is_knocked_out")
	var nh: int = int(p.server_apply_damage(amount))
	if _should_run_orc_and_regen_logic() and not was_ko and nh == 0:
		_schedule_player_auto_respawn(peer_id, p.global_position)
	if multiplayer.multiplayer_peer != null:
		rpc_sync_player_hp.rpc(peer_id, nh)


func _schedule_player_auto_respawn(peer_id: int, death_pos: Vector2) -> void:
	_player_auto_respawn_at_ms[peer_id] = Time.get_ticks_msec() + PLAYER_AUTO_RESPAWN_DELAY_MS
	_player_auto_respawn_death_pos[peer_id] = death_pos


func _cancel_player_auto_respawn(peer_id: int) -> void:
	_player_auto_respawn_at_ms.erase(peer_id)
	_player_auto_respawn_death_pos.erase(peer_id)


func _pick_respawn_near_death(death_pos: Vector2) -> Vector2:
	var ts := float(WorldMapBuilder.TILE_SIZE)
	var r := float(PLAYER_RESPAWN_RADIUS_TILES) * ts
	var r2 := r * r
	var wr := GameState.world_rect
	var m := 24.0
	for _attempt in 90:
		var ang := _world_rng.randf() * TAU
		var dist := sqrt(_world_rng.randf()) * r
		var cand := death_pos + Vector2(cos(ang), sin(ang)) * dist
		cand.x = clampf(cand.x, wr.position.x + m, wr.position.x + wr.size.x - m)
		cand.y = clampf(cand.y, wr.position.y + m, wr.position.y + wr.size.y - m)
		var np := WorldMapBuilder.nearest_walkable_world_pixel(
			_grid, _grid_w, _grid_h, _tile_origin_world, cand, wr
		)
		var tcx := int(floor(np.x / ts))
		var tcy := int(floor(np.y / ts))
		if not WorldMapBuilder.is_tile_walkable_at_world(
			_grid, _grid_w, _grid_h, _tile_origin_world, Vector2i(tcx, tcy)
		):
			continue
		if death_pos.distance_squared_to(np) > r2 + 4.0:
			continue
		return np
	return WorldMapBuilder.nearest_walkable_world_pixel(
		_grid, _grid_w, _grid_h, _tile_origin_world, death_pos, wr
	)


func _execute_player_auto_respawn(peer_id: int, pos: Vector2) -> void:
	var p := _players.get_node_or_null(str(peer_id))
	if p == null or not p.has_method("server_apply_revive"):
		return
	var nh: int = int(p.server_apply_revive())
	if p.has_method("apply_respawn_pose"):
		p.apply_respawn_pose(pos)
	if multiplayer.multiplayer_peer != null:
		rpc_sync_player_hp.rpc(peer_id, nh)
		rpc_player_respawn_at.rpc(peer_id, pos)


func _server_tick_player_auto_respawn() -> void:
	if _player_auto_respawn_at_ms.is_empty():
		return
	var now := Time.get_ticks_msec()
	var due: Array[int] = []
	for k in _player_auto_respawn_at_ms.keys():
		if now >= int(_player_auto_respawn_at_ms[k]):
			due.append(int(k))
	for pid in due:
		var dpos: Vector2 = _player_auto_respawn_death_pos.get(pid, Vector2.ZERO) as Vector2
		_player_auto_respawn_at_ms.erase(pid)
		_player_auto_respawn_death_pos.erase(pid)
		var newp := _pick_respawn_near_death(dpos)
		_execute_player_auto_respawn(pid, newp)


@rpc("authority", "call_remote", "reliable")
func rpc_player_respawn_at(peer_id: int, pos: Vector2) -> void:
	if multiplayer.is_server():
		return
	var p := _players.get_node_or_null(str(peer_id))
	if p and p.has_method("apply_respawn_pose"):
		p.apply_respawn_pose(pos)


@rpc("any_peer", "call_remote", "reliable")
func request_melee_attack() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var snd_node := _players.get_node_or_null(str(sender))
	if snd_node == null:
		return
	if snd_node.has_method("is_knocked_out") and snd_node.call("is_knocked_out"):
		return
	_resolve_melee_strike(sender)


@rpc("authority", "call_local", "reliable")
func rpc_play_melee_visual(attacker_id: int) -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.get_unique_id() == attacker_id:
		return
	var p = _players.get_node_or_null(str(attacker_id))
	if p and p.has_method("play_melee_visual"):
		p.play_melee_visual()


func try_spawn_meat_for_chest(chest_name: String, chest_pos: Vector2, body: CharacterBody2D) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	if _grid.is_empty():
		return
	if not body.is_in_group("arena_players"):
		return
	if body.has_method("is_knocked_out") and body.call("is_knocked_out"):
		return
	var nm := str(body.name)
	if not nm.is_valid_int():
		return
	if chest_pos.distance_squared_to(body.global_position) > 75.0 * 75.0:
		return
	var st: Dictionary = _chest_meat_state.get(
		chest_name, {"active_uid": -1, "cooldown_until_ms": 0}
	) as Dictionary
	var active_uid := int(st.get("active_uid", -1))
	var cd_until := int(st.get("cooldown_until_ms", 0))
	var now := Time.get_ticks_msec()
	if active_uid >= 0:
		if _players != null and _players.has_node("DroppedMeat_%d" % active_uid):
			return
	if now < cd_until:
		return
	var big_piece := _world_rng.randf() < 0.5
	var atlas_col := 2 if big_piece else 1
	var heal_hp := MEAT_HEAL_LARGE if big_piece else MEAT_HEAL_SMALL
	var from_pos := chest_pos + Vector2(0.0, -16.0)
	var ang := _world_rng.randf() * TAU
	var dist := _world_rng.randf_range(18.0, 42.0)
	var to_raw := chest_pos + Vector2(cos(ang), sin(ang)) * dist
	var to_pos := WorldMapBuilder.nearest_walkable_world_pixel(
		_grid, _grid_w, _grid_h, _tile_origin_world, to_raw, GameState.world_rect
	)
	_next_meat_uid += 1
	var uid := _next_meat_uid
	_chest_meat_state[chest_name] = {"active_uid": uid, "cooldown_until_ms": 0}
	if multiplayer.multiplayer_peer == null:
		_rpc_spawn_dropped_meat_impl(from_pos, to_pos, uid, atlas_col, heal_hp, chest_name)
	else:
		rpc_spawn_dropped_meat.rpc(from_pos, to_pos, uid, atlas_col, heal_hp, chest_name)


func apply_meat_pickup(peer_id: int, amount: int, meat_uid: int, chest_name: String) -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	var p := _players.get_node_or_null(str(peer_id))
	if p == null or not p.has_method("server_apply_heal"):
		return
	if p.has_method("is_knocked_out") and p.call("is_knocked_out"):
		return
	var nh: int = int(p.server_apply_heal(amount))
	if not chest_name.is_empty():
		var respawn_at := Time.get_ticks_msec() + _world_rng.randi_range(
			MEAT_COOLDOWN_MIN_MS, MEAT_COOLDOWN_MAX_MS
		)
		_chest_meat_state[chest_name] = {"active_uid": -1, "cooldown_until_ms": respawn_at}
	if multiplayer.multiplayer_peer != null:
		rpc_sync_player_hp.rpc(peer_id, nh)
		rpc_despawn_dropped_meat.rpc(meat_uid)
	else:
		_despawn_dropped_meat_local(meat_uid)


@rpc("authority", "call_local", "reliable")
func rpc_spawn_dropped_meat(
	from_pos: Vector2,
	to_pos: Vector2,
	meat_uid: int,
	atlas_col: int,
	heal_hp: int,
	chest_name: String
) -> void:
	_rpc_spawn_dropped_meat_impl(from_pos, to_pos, meat_uid, atlas_col, heal_hp, chest_name)


func _rpc_spawn_dropped_meat_impl(
	from_pos: Vector2,
	to_pos: Vector2,
	meat_uid: int,
	atlas_col: int,
	heal_hp: int,
	chest_name: String
) -> void:
	if _players == null:
		return
	var nn := "DroppedMeat_%d" % meat_uid
	if _players.has_node(nn):
		return
	var m: Node2D = MEAT_SCENE.instantiate() as Node2D
	m.name = nn
	m.set_meta("chest_name", chest_name)
	_players.add_child(m)
	if m.has_method("begin_drop"):
		m.call("begin_drop", from_pos, to_pos, meat_uid, atlas_col, heal_hp, chest_name)


@rpc("authority", "call_local", "reliable")
func rpc_despawn_dropped_meat(meat_uid: int) -> void:
	_despawn_dropped_meat_local(meat_uid)


func _despawn_dropped_meat_local(meat_uid: int) -> void:
	if _players == null:
		return
	var nn := "DroppedMeat_%d" % meat_uid
	if _players.has_node(nn):
		_players.get_node(nn).queue_free()


func _clear_dropped_meat_nodes() -> void:
	if _players == null:
		return
	var i := _players.get_child_count()
	while i > 0:
		i -= 1
		var c: Node = _players.get_child(i)
		if str(c.name).begins_with("DroppedMeat_"):
			_players.remove_child(c)
			c.free()


@rpc("authority", "call_local", "reliable")
func rpc_sync_player_hp(peer_id: int, new_hp: int) -> void:
	var p = _players.get_node_or_null(str(peer_id))
	if p and p.has_method("sync_hp_from_server"):
		p.sync_hp_from_server(new_hp)


func get_nearest_knocked_peer(healer_peer_id: int, from_pos: Vector2) -> int:
	var best_id := -1
	var best_d2 := REVIVE_RANGE * REVIVE_RANGE
	for c in _players.get_children():
		if not c is CharacterBody2D:
			continue
		var nm := str(c.name)
		if not nm.is_valid_int():
			continue
		var pid := int(nm)
		if pid == healer_peer_id:
			continue
		if not c.has_method("is_knocked_out") or not c.call("is_knocked_out"):
			continue
		var d2 := from_pos.distance_squared_to(c.global_position)
		if d2 <= best_d2:
			best_d2 = d2
			best_id = pid
	return best_id


func local_can_show_revive_button() -> bool:
	if GameState.is_dedicated_server:
		return false
	var uid := 1
	if multiplayer.multiplayer_peer != null:
		uid = multiplayer.get_unique_id()
	var me := _players.get_node_or_null(str(uid))
	if me == null or not me.has_method("is_knocked_out"):
		return false
	if me.call("is_knocked_out"):
		return false
	return get_nearest_knocked_peer(uid, me.global_position) >= 0


func try_revive_nearby_from_local_player() -> void:
	if GameState.is_dedicated_server:
		return
	var uid := 1
	if multiplayer.multiplayer_peer != null:
		uid = multiplayer.get_unique_id()
	var me := _players.get_node_or_null(str(uid))
	if me == null or not me.has_method("is_knocked_out"):
		return
	if me.call("is_knocked_out"):
		return
	var tid := get_nearest_knocked_peer(uid, me.global_position)
	if tid < 0:
		return
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		_try_revive_player(uid, tid)
	else:
		request_revive_player.rpc_id(1, tid)


func _try_revive_player(healer_id: int, target_peer_id: int) -> void:
	if healer_id == target_peer_id:
		return
	var healer := _players.get_node_or_null(str(healer_id)) as Node2D
	var target := _players.get_node_or_null(str(target_peer_id)) as Node2D
	if healer == null or target == null:
		return
	if healer.has_method("is_knocked_out") and healer.call("is_knocked_out"):
		return
	if not target.has_method("is_knocked_out") or not target.call("is_knocked_out"):
		return
	var dist_sq := healer.global_position.distance_squared_to(target.global_position)
	if dist_sq > REVIVE_RANGE * REVIVE_RANGE:
		return
	if not target.has_method("server_apply_revive"):
		return
	var nh: int = int(target.server_apply_revive())
	_cancel_player_auto_respawn(target_peer_id)
	if multiplayer.multiplayer_peer != null:
		rpc_sync_player_hp.rpc(target_peer_id, nh)


@rpc("any_peer", "call_remote", "reliable")
func request_revive_player(target_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var healer_id := multiplayer.get_remote_sender_id()
	_try_revive_player(healer_id, target_peer_id)


@rpc("any_peer", "call_remote", "unreliable")
func relay_player_pos(peer_id: int, pos: Vector2) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if peer_id < 0:
		return
	if sender != peer_id:
		return
	var p := _players.get_node_or_null(str(peer_id))
	if p == null or not p.has_method("apply_network_motion"):
		return
	p.apply_network_motion(pos)


func _should_run_orc_and_regen_logic() -> bool:
	if GameState.is_dedicated_server:
		return true
	if multiplayer.multiplayer_peer == null:
		return true
	return multiplayer.is_server()


func _clear_all_orcs() -> void:
	if _orcs == null:
		return
	for c in _orcs.get_children():
		_orcs.remove_child(c)
		c.free()


func apply_orc_melee_to_player(peer_id: int) -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	_apply_player_damage(peer_id, ORC_MELEE_DAMAGE)


func notify_orc_dead(orc_id: int) -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc_orc_despawn.rpc(orc_id)


func notify_orc_strike_started(orc_id: int) -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc_orc_strike_visual.rpc(orc_id)


@rpc("authority", "call_remote", "reliable")
func rpc_orc_strike_visual(orc_id: int) -> void:
	if multiplayer.is_server():
		return
	var n := _orcs.get_node_or_null("Orc_%d" % orc_id)
	if n and n.has_method("play_strike_visual"):
		n.play_strike_visual()


func broadcast_orc_hp(orc_id: int, new_hp: int) -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc_orc_hp.rpc(orc_id, new_hp)


@rpc("authority", "call_remote", "unreliable")
func rpc_orc_hp(orc_id: int, new_hp: int) -> void:
	if multiplayer.is_server():
		return
	var n := _orcs.get_node_or_null("Orc_%d" % orc_id)
	if n and n.has_method("sync_hp_from_net"):
		n.sync_hp_from_net(new_hp)


@rpc("authority", "call_remote", "reliable")
func rpc_orc_despawn(orc_id: int) -> void:
	if multiplayer.is_server():
		return
	var nn := "Orc_%d" % orc_id
	if _orcs != null and _orcs.has_node(nn):
		_orcs.get_node(nn).queue_free()


@rpc("authority", "call_remote", "reliable")
func rpc_orc_spawned(orc_id: int, pos: Vector2) -> void:
	if multiplayer.is_server():
		return
	_spawn_orc_client(orc_id, pos)


@rpc("authority", "call_remote", "unreliable")
func rpc_orc_pos(orc_id: int, pos: Vector2) -> void:
	if multiplayer.is_server():
		return
	var n := _orcs.get_node_or_null("Orc_%d" % orc_id)
	if n and n.has_method("apply_network_motion"):
		n.apply_network_motion(pos)


@rpc("any_peer", "call_remote", "reliable")
func request_orc_full_state() -> void:
	if not multiplayer.is_server():
		return
	var who := multiplayer.get_remote_sender_id()
	if who <= 0:
		return
	call_deferred("_push_all_orcs_to_peer", who)


func _push_all_orcs_to_peer(peer_id: int) -> void:
	if _orcs == null:
		return
	if not multiplayer.is_server():
		return
	if peer_id <= 0:
		return
	for c in _orcs.get_children():
		var oid := int(c.get_meta("orc_id", -1))
		if oid < 0:
			continue
		var hv := int(c.get("hp"))
		if hv <= 0:
			continue
		rpc_orc_spawned.rpc_id(peer_id, oid, c.global_position)
		rpc_orc_hp.rpc_id(peer_id, oid, hv)


func _try_restore_orcs_from_save() -> void:
	if not _should_run_orc_and_regen_logic():
		return
	if _orcs == null or _grid.is_empty():
		return
	var data := WorldSave.load_orcs_snapshot(GameState.world_seed)
	if data.is_empty():
		return
	_next_orc_id = int(data.get("next_id", 0))
	var lst: Array = data.get("list", []) as Array
	var announce := multiplayer.multiplayer_peer != null
	var max_id := 0
	for item in lst:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var oid := int(d.get("id", 0))
		if oid <= 0:
			continue
		max_id = maxi(max_id, oid)
		var hpv := int(d.get("hp", 50))
		if hpv <= 0:
			continue
		var raw := Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		var np := WorldMapBuilder.nearest_walkable_world_pixel(
			_grid, _grid_w, _grid_h, _tile_origin_world, raw, GameState.world_rect
		)
		_spawn_orc_with_id_on_server(oid, np, hpv, announce)
	_next_orc_id = maxi(_next_orc_id, max_id)


func _save_orcs_snapshot_if_server() -> void:
	if not _should_run_orc_and_regen_logic():
		return
	if _orcs == null or _grid.is_empty():
		return
	var entries: Array = []
	for c in _orcs.get_children():
		var oid := int(c.get_meta("orc_id", -1))
		if oid < 0:
			continue
		var hv := int(c.get("hp"))
		if hv <= 0:
			continue
		entries.append(
			{"id": oid, "x": c.global_position.x, "y": c.global_position.y, "hp": hv}
		)
	WorldSave.save_orcs_snapshot(GameState.world_seed, _next_orc_id, entries)


func _spawn_orc_client(orc_id: int, pos: Vector2) -> void:
	if _orcs == null:
		return
	var nn := "Orc_%d" % orc_id
	if _orcs.has_node(nn):
		return
	var o: CharacterBody2D = ORC_SCENE.instantiate() as CharacterBody2D
	o.name = nn
	o.set_meta("orc_id", orc_id)
	o.set_multiplayer_authority(1)
	o.global_position = pos
	_orcs.add_child(o)


func _spawn_orc_with_id_on_server(oid: int, pos: Vector2, saved_hp: int, announce_remote: bool) -> void:
	if _orcs == null or _grid.is_empty():
		return
	var nn := "Orc_%d" % oid
	if _orcs.has_node(nn):
		return
	var o: CharacterBody2D = ORC_SCENE.instantiate() as CharacterBody2D
	o.name = nn
	o.set_meta("orc_id", oid)
	o.set_multiplayer_authority(1)
	o.global_position = pos
	if saved_hp >= 0:
		o.set("hp", clampi(saved_hp, 1, 50))
	_orcs.add_child(o)
	if announce_remote and multiplayer.multiplayer_peer != null and multiplayer.is_server():
		rpc_orc_spawned.rpc(oid, pos)
		if saved_hp >= 0:
			rpc_orc_hp.rpc(oid, int(o.get("hp")))


func _spawn_orc_server() -> void:
	if _orcs == null:
		return
	if _grid.is_empty():
		return
	if _orcs.get_child_count() >= MAX_ORCS:
		return
	var pos := _random_walkable_spawn_point()
	if pos == Vector2.ZERO:
		return
	_next_orc_id += 1
	var oid := _next_orc_id
	_spawn_orc_with_id_on_server(oid, pos, -1, true)


func _random_walkable_spawn_point() -> Vector2:
	var r := GameState.world_rect
	if _grid.is_empty():
		return Vector2.ZERO
	var m := 48.0
	for _i in range(14):
		var rx := _world_rng.randf_range(r.position.x + m, r.position.x + r.size.x - m)
		var ry := _world_rng.randf_range(r.position.y + m, r.position.y + r.size.y - m)
		var np := WorldMapBuilder.nearest_walkable_world_pixel(
			_grid, _grid_w, _grid_h, _tile_origin_world, Vector2(rx, ry), r
		)
		var ts := float(WorldMapBuilder.TILE_SIZE)
		var tcx := int(floor(np.x / ts))
		var tcy := int(floor(np.y / ts))
		if WorldMapBuilder.is_tile_walkable_at_world(
			_grid, _grid_w, _grid_h, _tile_origin_world, Vector2i(tcx, tcy)
		):
			return np
	return Vector2.ZERO


func _broadcast_orc_positions() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if not multiplayer.is_server():
		return
	if _orcs == null:
		return
	for c in _orcs.get_children():
		var oid := int(c.get_meta("orc_id", -1))
		if oid < 0:
			continue
		rpc_orc_pos.rpc(oid, c.global_position)


func _physics_process(_delta: float) -> void:
	_run_arena_camera_follow()
	if _should_run_world_expansion():
		_check_expand_world_edges()
	if _should_run_orc_and_regen_logic():
		_orc_spawn_acc += _delta
		while _orc_spawn_acc >= ORC_SPAWN_INTERVAL_SEC:
			_orc_spawn_acc -= ORC_SPAWN_INTERVAL_SEC
			_spawn_orc_server()
		_orc_sync_acc += _delta
		if _orc_sync_acc >= 0.05:
			_orc_sync_acc = 0.0
			_broadcast_orc_positions()
		_orc_save_acc += _delta
		if _orc_save_acc >= 2.5:
			_orc_save_acc = 0.0
			_save_orcs_snapshot_if_server()
		_server_tick_player_auto_respawn()
	if not GameState.is_dedicated_server and not _grid.is_empty():
		_autosave_dt += _delta
		if _autosave_dt >= 1.0:
			_autosave_dt = 0.0
			_save_local_player_position_if_any()


func _should_run_world_expansion() -> bool:
	if _ground_layer == null:
		return false
	if multiplayer.multiplayer_peer == null:
		return true
	return multiplayer.is_server()


func _run_arena_camera_follow() -> void:
	if _arena_camera == null or not _arena_camera.enabled:
		return
	var target: Node2D = null
	if multiplayer.multiplayer_peer == null:
		target = _players.get_node_or_null("1") as Node2D
	else:
		var uid := multiplayer.get_unique_id()
		target = _players.get_node_or_null(str(uid)) as Node2D
	if target == null:
		for c in _players.get_children():
			if c is CharacterBody2D:
				target = c as Node2D
				break
	if target:
		_arena_camera.global_position = target.global_position


func _setup_world_camera() -> void:
	if _arena_camera == null:
		return
	if GameState.is_dedicated_server:
		_arena_camera.enabled = false
		return
	_arena_camera.enabled = true
	_arena_camera.zoom = Vector2(CAMERA_ZOOM, CAMERA_ZOOM)
	## Сглаживание камеры даёт «шлейф»/мягкость на пиксель-арте; без него картинка чётче при движении.
	_arena_camera.position_smoothing_enabled = false
	var r := GameState.world_rect
	var pad := 120.0
	_arena_camera.limit_left = int(r.position.x - pad)
	_arena_camera.limit_right = int(r.position.x + r.size.x + pad)
	_arena_camera.limit_top = int(r.position.y - pad)
	_arena_camera.limit_bottom = int(r.position.y + r.size.y + pad)
	_arena_camera.make_current()


func _ensure_world_parent() -> Node2D:
	var wp := get_node_or_null("World") as Node2D
	if wp == null:
		wp = Node2D.new()
		wp.name = "World"
		add_child(wp)
		move_child(wp, 0)
	return wp


func _generate_world(world_parent: Node2D) -> void:
	var wm: Dictionary = WorldMapBuilder.create_tilemap(world_parent, _players, _world_rng)
	_hydrate_world_from_wm(wm, world_parent)


func _hydrate_world_from_wm(wm: Dictionary, world_parent: Node2D) -> void:
	_clear_all_orcs()
	_next_orc_id = 0
	_clear_dropped_meat_nodes()
	_next_meat_uid = 0
	_chest_meat_state.clear()
	_player_auto_respawn_at_ms.clear()
	_player_auto_respawn_death_pos.clear()
	_clear_chest_instances()
	GameState.world_rect = wm["world_rect"] as Rect2
	_grid = wm["grid"] as Array
	_grid_w = int(wm["grid_w"])
	_grid_h = int(wm["grid_h"])
	_spawn_center_cell = wm["spawn_center_cell"] as Vector2i
	_ground_layer = wm["tile_map"] as TileMapLayer
	_water_layer = world_parent.get_node("WaterTileMap") as TileMapLayer
	_atlas_tex = wm["atlas_texture"] as Texture2D
	_source_id = int(wm["source_id"])
	_tile_origin_world = wm["tile_origin_world"] as Vector2i
	_tree_origins.clear()
	for o in wm["tree_origins"] as Array:
		_tree_origins.append(o as Vector2i)
	_water_pits.clear()
	for p in wm["water_pits"] as Array:
		var pd: Dictionary = p as Dictionary
		_water_pits.append({"origin": pd["origin"], "size": pd["size"]})
	_chest_world_cells.clear()
	if wm.has("chest_world_cells"):
		for cw in wm["chest_world_cells"] as Array:
			_chest_world_cells.append(cw as Vector2i)
	_spawn_chest_instances()


func _clear_chest_instances() -> void:
	var i := _players.get_child_count()
	while i > 0:
		i -= 1
		var c: Node = _players.get_child(i)
		if str(c.name).begins_with("Chest_"):
			_players.remove_child(c)
			c.free()


func _spawn_chest_at_world_cell(wc: Vector2i) -> void:
	var pos := WorldMapBuilder.tile_center_to_world(wc)
	var ch: Node2D = CHEST_SCENE.instantiate() as Node2D
	ch.position = pos
	ch.name = "Chest_%d_%d" % [wc.x, wc.y]
	_players.add_child(ch)


func _spawn_chest_instances() -> void:
	for wc in _chest_world_cells:
		_spawn_chest_at_world_cell(wc)


func _refresh_world_rect() -> void:
	var ts := float(WorldMapBuilder.TILE_SIZE)
	GameState.world_rect = Rect2(
		float(_tile_origin_world.x) * ts,
		float(_tile_origin_world.y) * ts,
		float(_grid_w) * ts,
		float(_grid_h) * ts
	)


func _replay_extensions(ext_log: String) -> void:
	_strip_count_by_char = {"l": 0, "r": 0, "u": 0, "d": 0}
	if ext_log.is_empty():
		_refresh_world_rect()
		return
	var wp := _ensure_world_parent()
	for i in range(ext_log.length()):
		var ch := ext_log.substr(i, 1)
		if not _strip_count_by_char.has(ch):
			continue
		var dc := _char_to_dir_code(ch)
		if dc < 0:
			continue
		_strip_count_by_char[ch] = int(_strip_count_by_char[ch]) + 1
		var idx: int = int(_strip_count_by_char[ch])
		_tile_origin_world = _apply_extension_core(wp, dc, idx)
	_grid_w = (_grid[0] as Array).size()
	_grid_h = _grid.size()
	_refresh_world_rect()


func _apply_extension_core(world_parent: Node2D, dir_code: int, strip_idx: int) -> Vector2i:
	var chest_added: Array = []
	var origin := WorldMapBuilder.extend_world_strip(
		dir_code,
		_grid,
		_tile_origin_world,
		strip_idx,
		GameState.world_seed,
		_tree_origins,
		_water_pits,
		_ground_layer,
		_water_layer,
		world_parent,
		_players,
		_atlas_tex,
		_source_id,
		_chest_world_cells,
		chest_added
	)
	for wc in chest_added:
		_spawn_chest_at_world_cell(wc as Vector2i)
	return origin


func _char_to_dir_code(ch: String) -> int:
	match ch:
		"l":
			return WorldMapBuilder.DIR_LEFT
		"r":
			return WorldMapBuilder.DIR_RIGHT
		"u":
			return WorldMapBuilder.DIR_UP
		"d":
			return WorldMapBuilder.DIR_DOWN
	return -1


func _dir_code_to_char(dc: int) -> String:
	match dc:
		WorldMapBuilder.DIR_LEFT:
			return "l"
		WorldMapBuilder.DIR_RIGHT:
			return "r"
		WorldMapBuilder.DIR_UP:
			return "u"
		WorldMapBuilder.DIR_DOWN:
			return "d"
	return ""


func _check_expand_world_edges() -> void:
	var th := WorldMapBuilder.WORLD_EDGE_THRESHOLD_TILES
	var ts := float(WorldMapBuilder.TILE_SIZE)
	var need := {}
	for child in _players.get_children():
		if not child is CharacterBody2D:
			continue
		var cx := int(floor(child.global_position.x / ts))
		var cy := int(floor(child.global_position.y / ts))
		var L := _tile_origin_world.x
		var R := _tile_origin_world.x + _grid_w - 1
		var T := _tile_origin_world.y
		var B := _tile_origin_world.y + _grid_h - 1
		if cx - L < th:
			need["l"] = true
		if R - cx < th:
			need["r"] = true
		if cy - T < th:
			need["u"] = true
		if B - cy < th:
			need["d"] = true
	for dk in ["l", "r", "u", "d"]:
		if need.get(dk, false):
			_server_extend_direction(dk)


func _server_extend_direction(dk: String) -> void:
	if not _strip_count_by_char.has(dk):
		return
	var wp := _ensure_world_parent()
	_strip_count_by_char[dk] = int(_strip_count_by_char[dk]) + 1
	var idx: int = int(_strip_count_by_char[dk])
	var dc := _char_to_dir_code(dk)
	_tile_origin_world = _apply_extension_core(wp, dc, idx)
	_grid_w = (_grid[0] as Array).size()
	_grid_h = _grid.size()
	_refresh_world_rect()
	_setup_world_camera()
	WorldSave.append_extension_char(dk)
	sync_world_extend_live.rpc(dc, idx)


func _connect_leave_button() -> void:
	if has_node("UIScore/LeaveLobbyButton"):
		var leave_btn: Button = $UIScore/LeaveLobbyButton
		leave_btn.visible = (
			multiplayer.multiplayer_peer != null and not GameState.is_dedicated_server
		)
		if not leave_btn.pressed.is_connected(_on_leave_lobby_pressed):
			leave_btn.pressed.connect(_on_leave_lobby_pressed)


func _connect_mp_signals_once() -> void:
	if _mp_signals_done:
		return
	_mp_signals_done = true
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if multiplayer.is_server():
		multiplayer.peer_connected.connect(_on_peer_connected_server)
	if not multiplayer.is_server():
		multiplayer.server_disconnected.connect(_on_server_disconnected_while_in_arena)


func _apply_visibility_flags() -> void:
	if has_node("TouchControls"):
		$TouchControls.visible = not GameState.is_dedicated_server
	if has_node("UIScore"):
		$UIScore.visible = not GameState.is_dedicated_server
	if has_node("UIScore/Minimap"):
		$UIScore/Minimap.visible = not GameState.is_dedicated_server


func _ready() -> void:
	add_to_group("arena_main")

	var world_parent := _ensure_world_parent()

	if multiplayer.multiplayer_peer == null:
		var seed := WorldSave.resolve_seed(GameState.request_new_world)
		GameState.request_new_world = false
		_world_rng.seed = seed
		GameState.world_seed = seed
		_generate_world(world_parent)
		_replay_extensions(WorldSave.load_extension_log())
		_apply_visibility_flags()
		_connect_leave_button()
		var fb := WorldMapBuilder.tile_center_to_world(
			WorldMapBuilder.spawn_tile_for_slot(
				_grid, _grid_w, _grid_h, _spawn_center_cell, 0, _tile_origin_world
			)
		)
		var pos := _validated_spawn_from_saved(
			WorldSave.load_saved_player_position(GameState.world_seed),
			fb
		)
		_spawn_player(1, pos, "Локально")
		_refresh_status()
		_setup_world_camera()
		_try_restore_orcs_from_save()
		return

	set_multiplayer_authority(1)

	if multiplayer.is_server():
		var seed := WorldSave.resolve_seed(GameState.request_new_world)
		GameState.request_new_world = false
		_world_rng.seed = seed
		GameState.world_seed = seed
		_generate_world(world_parent)
		_replay_extensions(WorldSave.load_extension_log())
		_apply_visibility_flags()
		_connect_leave_button()
		_connect_mp_signals_once()

		if not GameState.is_dedicated_server:
			var fb := WorldMapBuilder.tile_center_to_world(
				WorldMapBuilder.spawn_tile_for_slot(
					_grid, _grid_w, _grid_h, _spawn_center_cell, 0, _tile_origin_world
				)
			)
			var host_pos := _validated_spawn_from_saved(
				WorldSave.load_saved_player_position(GameState.world_seed),
				fb
			)
			_spawn_player(1, host_pos, GameState.display_name)

		_refresh_status()
		_setup_world_camera()
		_try_restore_orcs_from_save()
		return

	## Клиент: мир строится только после получения того же seed, что у хоста.
	request_world_seed.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func request_world_seed() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var log := WorldSave.load_extension_log()
	_mp_log(
		"[server] request_world_seed peer=%d world_seed=%d ext_len=%d"
		% [peer_id, GameState.world_seed, log.length()]
	)
	sync_world_seed.rpc_id(peer_id, GameState.world_seed, log)


@rpc("authority", "call_remote", "reliable")
func sync_world_seed(seed: int, ext_log: String = "") -> void:
	if multiplayer.is_server():
		return
	_mp_log("[client] sync_world_seed seed=%d ext_len=%d" % [seed, ext_log.length()])
	_world_rng.seed = seed
	GameState.world_seed = seed
	var wp := _ensure_world_parent()
	_generate_world(wp)
	_replay_extensions(ext_log)

	set_multiplayer_authority(1)
	_apply_visibility_flags()
	_connect_leave_button()
	_connect_mp_signals_once()

	var resume := WorldSave.load_saved_player_position(GameState.world_seed)
	client_hello.rpc_id(
		1,
		GameState.display_name,
		resume.x,
		resume.y
	)
	_refresh_status()
	_setup_world_camera()
	if multiplayer.multiplayer_peer != null:
		request_orc_full_state.rpc_id(1)


@rpc("authority", "call_remote", "reliable")
func sync_world_extend_live(dir_code: int, strip_idx: int) -> void:
	if multiplayer.is_server():
		return
	var wp := _ensure_world_parent()
	var chest_added: Array = []
	_tile_origin_world = WorldMapBuilder.extend_world_strip(
		dir_code,
		_grid,
		_tile_origin_world,
		strip_idx,
		GameState.world_seed,
		_tree_origins,
		_water_pits,
		_ground_layer,
		_water_layer,
		wp,
		_players,
		_atlas_tex,
		_source_id,
		_chest_world_cells,
		chest_added
	)
	for wc in chest_added:
		_spawn_chest_at_world_cell(wc as Vector2i)
	_grid_w = (_grid[0] as Array).size()
	_grid_h = _grid.size()
	var dk := _dir_code_to_char(dir_code)
	if dk != "":
		_strip_count_by_char[dk] = strip_idx
	_refresh_world_rect()
	_setup_world_camera()


func _spawn_point_for_slot(slot: int) -> Vector2:
	var t := WorldMapBuilder.spawn_tile_for_slot(
		_grid, _grid_w, _grid_h, _spawn_center_cell, slot, _tile_origin_world
	)
	return WorldMapBuilder.tile_center_to_world(t)


func _validated_spawn_from_saved(saved: Vector2, fallback: Vector2) -> Vector2:
	if is_nan(saved.x) or is_nan(saved.y):
		return fallback
	var r := GameState.world_rect
	var m := 10.0
	var c := Vector2(
		clampf(saved.x, r.position.x + m, r.position.x + r.size.x - m),
		clampf(saved.y, r.position.y + m, r.position.y + r.size.y - m)
	)
	var np := WorldMapBuilder.nearest_walkable_world_pixel(
		_grid, _grid_w, _grid_h, _tile_origin_world, c, r
	)
	var ts := float(WorldMapBuilder.TILE_SIZE)
	var tcx := int(floor(np.x / ts))
	var tcy := int(floor(np.y / ts))
	if WorldMapBuilder.is_tile_walkable_at_world(
		_grid, _grid_w, _grid_h, _tile_origin_world, Vector2i(tcx, tcy)
	):
		return np
	return fallback


func get_minimap_snapshot() -> Dictionary:
	if _grid.is_empty():
		return {}
	var my_uid := 1
	if multiplayer.multiplayer_peer != null:
		my_uid = multiplayer.get_unique_id()
	var others: Array[Vector2] = []
	for c in _players.get_children():
		if not c is CharacterBody2D:
			continue
		if not str(c.name).is_valid_int():
			continue
		var pid: int = int(str(c.name))
		if pid == my_uid:
			continue
		others.append((c as Node2D).global_position)
	return {
		"grid": _grid,
		"gw": _grid_w,
		"gh": _grid_h,
		"origin": _tile_origin_world,
		"player_pos": _get_local_player_body_position(),
		"others": others,
	}


func _get_local_player_body_position() -> Vector2:
	var uid := 1
	if multiplayer.multiplayer_peer != null:
		uid = multiplayer.get_unique_id()
	var n := _players.get_node_or_null(str(uid)) as CharacterBody2D
	if n:
		return n.global_position
	return Vector2.ZERO


func _save_local_player_position_if_any() -> void:
	if GameState.is_dedicated_server:
		return
	if _grid.is_empty():
		return
	var uid := 1
	if multiplayer.multiplayer_peer != null:
		uid = multiplayer.get_unique_id()
	var node := _players.get_node_or_null(str(uid)) as CharacterBody2D
	if node == null:
		return
	WorldSave.save_player_position(node.global_position, GameState.world_seed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_local_player_position_if_any()
		_save_orcs_snapshot_if_server()
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_save_local_player_position_if_any()
		_save_orcs_snapshot_if_server()


func _exit_tree() -> void:
	_save_local_player_position_if_any()
	_save_orcs_snapshot_if_server()


func _on_leave_lobby_pressed() -> void:
	if GameState.is_dedicated_server:
		return
	_save_local_player_position_if_any()
	_save_orcs_snapshot_if_server()
	_leave_arena_manual = true
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")


func _on_server_disconnected_while_in_arena() -> void:
	if _leave_arena_manual:
		return
	multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")


func _on_peer_connected_server(id: int) -> void:
	_mp_log(
		"[server] peer_connected id=%d%s peers=%s"
		% [id, _enet_peer_addr_suffix(id), str(multiplayer.get_peers())]
	)


func _enet_refresh_peer_log_suffix(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var pkt := enet.get_peer(peer_id)
	if pkt == null:
		return
	if pkt.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return
	_enet_log_addr_by_peer[peer_id] = (
		" addr=%s:%d" % [pkt.get_remote_address(), pkt.get_remote_port()]
	)


func _enet_peer_addr_suffix(peer_id: int) -> String:
	_enet_refresh_peer_log_suffix(peer_id)
	return str(_enet_log_addr_by_peer.get(peer_id, ""))


func _enet_disconnect_log_suffix(peer_id: int) -> String:
	var s: Variant = _enet_log_addr_by_peer.get(peer_id, "")
	_enet_log_addr_by_peer.erase(peer_id)
	return str(s)


func _refresh_status() -> void:
	if _status_label == null:
		return
	var parts: Array[String] = []
	for c in _players.get_children():
		if not c is CharacterBody2D:
			continue
		var nm = c.get("player_name")
		var sid := str(c.name)
		if nm is String and not nm.is_empty():
			parts.append("%s (%s)" % [nm, sid])
		else:
			parts.append(sid)
	if parts.is_empty():
		_status_label.text = "Игроки: —"
	else:
		_status_label.text = "Игроки: " + ", ".join(parts)


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var addr := _enet_disconnect_log_suffix(id)
	_mp_log("[server] peer_disconnected id=%d%s" % [id, addr])
	_svr_remove_peer_player(id)
	_refresh_status()
	net_peer_left.rpc(id)


@rpc("authority", "call_remote", "reliable")
func net_peer_left(peer_id: int) -> void:
	var path := NodePath(str(peer_id))
	if _players.has_node(path):
		_players.get_node(path).queue_free()
	_refresh_status()


func _svr_remove_peer_player(peer_id: int) -> void:
	_cancel_player_auto_respawn(peer_id)
	var path := NodePath(str(peer_id))
	if _players.has_node(path):
		_players.get_node(path).queue_free()


func _spawn_player(peer_id: int, pos: Vector2, pname: String) -> void:
	if _players.has_node(str(peer_id)):
		return
	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	p.name = str(peer_id)
	p.set_multiplayer_authority(peer_id)
	p.player_name = pname
	_players.add_child(p, true)
	p.global_position = pos


@rpc("any_peer", "call_remote", "reliable")
func client_hello(pname: String, resume_x: float, resume_y: float) -> void:
	if not multiplayer.is_server():
		return
	var who := multiplayer.get_remote_sender_id()
	var resume := Vector2(resume_x, resume_y)
	_client_hello_impl(who, pname, 0, resume)


func _client_hello_impl(
	who: int,
	pname: String,
	wait_host_retry: int,
	resume: Vector2
) -> void:
	if not multiplayer.is_server():
		return
	if not GameState.is_dedicated_server and not _players.has_node("1"):
		if wait_host_retry < 40:
			call_deferred("_client_hello_impl", who, pname, wait_host_retry + 1, resume)
		else:
			push_error("Main: client_hello — узел хоста \"1\" не появился")
		return
	_mp_log(
		"[server] client_hello id=%d name=\"%s\"%s"
		% [who, pname, _enet_peer_addr_suffix(who)]
	)
	for c in _players.get_children():
		if not str(c.name).is_valid_int():
			continue
		var pid: int = int(str(c.name))
		if pid == who:
			continue
		sync_spawn.rpc_id(who, pid, c.global_position, c.player_name)
	var humans_before := _svr_count_human_players()
	var slot := clampi(humans_before, 0, GameState.MAX_PLAYERS - 1)
	var fb := _spawn_point_for_slot(slot)
	var pos := _validated_spawn_from_saved(resume, fb)
	_spawn_player(who, pos, pname)
	for peer_id in multiplayer.get_peers():
		if peer_id == who:
			continue
		sync_spawn.rpc_id(peer_id, who, pos, pname)
	sync_spawn.rpc_id(who, who, pos, pname)


func _svr_count_human_players() -> int:
	var n := 0
	for c in _players.get_children():
		if not c is CharacterBody2D:
			continue
		var nm := str(c.name)
		if not nm.is_valid_int():
			continue
		n += 1
	return n


@rpc("authority", "call_remote", "reliable")
func sync_spawn(peer_id: int, pos: Vector2, pname: String) -> void:
	_spawn_player(peer_id, pos, pname)
	call_deferred("_refresh_status")
