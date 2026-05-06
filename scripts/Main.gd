extends Node2D

const PLAYER_SCENE := preload("res://scenes/Player.tscn")
const TEST_DUMMY_SCENE := preload("res://scenes/TestDummy.tscn")
const ATTACK_RADIUS := 100.0
const ATTACK_DAMAGE := 35.0
const PLAYER_MAX_HP := 100.0
const SHOVE_RANGE := 380.0
const SHOVE_COOLDOWN_MS := 100
## to_id==0 в notify_player_shove = толкать манекена «Bot».
const SHOVE_TARGET_BOT_ID := 0
const BOT_SPAWN_POS := Vector2(900, 400)

@onready var _players: Node2D = $Players
@onready var _score_label: Label = $UIScore/ScoreLabel

var _scores: Dictionary = {}
var _shove_last_ms: Dictionary = {}


func _ready() -> void:
	add_to_group("arena_main")
	if multiplayer.multiplayer_peer != null:
		set_multiplayer_authority(1)

	if has_node("TouchControls"):
		$TouchControls.visible = not GameState.is_dedicated_server
	if has_node("UIScore"):
		$UIScore.visible = not GameState.is_dedicated_server

	if multiplayer.multiplayer_peer == null:
		_spawn_player(1, Vector2(640, 400), "Локально")
		_spawn_bot_at(BOT_SPAWN_POS)
		_refresh_scoreboard()
		return

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if multiplayer.is_server():
		if not GameState.is_dedicated_server:
			_spawn_player(1, Vector2(420, 400), GameState.display_name)
	else:
		client_hello.rpc_id(1, GameState.display_name)

	_refresh_scoreboard()
	if multiplayer.is_server() and not GameState.is_dedicated_server:
		call_deferred("_server_spawn_bot_if_needed")


func player_request_attack(attacker_id: int) -> void:
	if multiplayer.multiplayer_peer == null:
		_process_attack(attacker_id)
		return
	if multiplayer.is_server():
		_process_attack(attacker_id)
	else:
		server_request_attack.rpc_id(1, attacker_id)


## Позиция через Main (один аргумент — меньше рассинхрона checksum с разными билдами).
@rpc("any_peer", "call_remote", "unreliable_ordered")
func relay_player_pos(payload: Dictionary) -> void:
	var peer_id := int(payload.get("i", -1))
	var pos: Vector2 = payload.get("p", Vector2.ZERO)
	if peer_id < 0 or multiplayer.get_remote_sender_id() != peer_id:
		return
	var p := _players.get_node_or_null(str(peer_id))
	if p and p.has_method("apply_network_motion"):
		p.apply_network_motion(pos)


func notify_player_shove(from_id: int, to_id: int, impulse_x: float) -> void:
	if multiplayer.multiplayer_peer == null:
		_apply_shove_server(from_id, to_id, impulse_x)
		return
	print(
		"[SHOVE] Main.notify from=%d to=%d imp=%.1f is_server=%s unique=%d"
		% [from_id, to_id, impulse_x, multiplayer.is_server(), multiplayer.get_unique_id()]
	)
	if multiplayer.is_server():
		_apply_shove_server(from_id, to_id, impulse_x)
	else:
		print("[SHOVE] Main.notify -> request_player_shove.rpc_id(1, ...)")
		request_player_shove.rpc_id(1, from_id, to_id, impulse_x)


@rpc("any_peer", "call_remote", "reliable")
func request_player_shove(from_id: int, to_id: int, impulse_x: float) -> void:
	if not multiplayer.is_server():
		print("[SHOVE] Main.request_player_shove drop: not server")
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != from_id:
		print("[SHOVE] Main.request reject sender=%d from_id=%d" % [sender, from_id])
		return
	print("[SHOVE] Main.request ok -> _apply from=%d to=%d" % [from_id, to_id])
	_apply_shove_server(from_id, to_id, impulse_x)


func _apply_shove_server(from_id: int, to_id: int, impulse_x: float) -> void:
	if from_id == to_id:
		print("[SHOVE] Main._apply skip: from==to")
		return
	if to_id == SHOVE_TARGET_BOT_ID:
		_apply_shove_to_bot(from_id, impulse_x)
		return
	var a := _players.get_node_or_null(str(from_id)) as Node2D
	var b := _players.get_node_or_null(str(to_id)) as Node2D
	if a == null or b == null:
		print("[SHOVE] Main._apply skip: missing node a=%s b=%s" % [a, b])
		return
	var dist: float = a.global_position.distance_to(b.global_position)
	print("[SHOVE] Main._apply dist=%.1f range=%.1f from=%d to=%d" % [dist, SHOVE_RANGE, from_id, to_id])
	if dist > SHOVE_RANGE:
		print("[SHOVE] Main._apply skip: dist > range (сервер видит кукол дальше — увеличь SHOVE_RANGE если мимо)")
		return
	var key := "%d>%d" % [from_id, to_id]
	var now := Time.get_ticks_msec()
	var last: int = int(_shove_last_ms.get(key, -1_000_000_000))
	if now - last < SHOVE_COOLDOWN_MS:
		print("[SHOVE] Main._apply skip: cooldown key=%s dt=%dms" % [key, now - last])
		return
	_shove_last_ms[key] = now
	impulse_x = clampf(impulse_x, -520.0, 520.0)
	var target := _players.get_node_or_null(str(to_id))
	if target and target.has_method("recv_shove_impulse"):
		print("[SHOVE] Main._apply OK -> recv_shove imp=%.1f to_id=%d" % [impulse_x, to_id])
		if multiplayer.is_server() and to_id == multiplayer.get_unique_id():
			print("[SHOVE] Main._apply local call (host shoves self / rpc_id self)")
			target.recv_shove_impulse(impulse_x)
		else:
			target.recv_shove_impulse.rpc_id(to_id, impulse_x)
	else:
		var tp := "null"
		if target:
			tp = str(target.get_path())
		print("[SHOVE] Main._apply skip: no recv_shove on target path=%s" % tp)


func _server_spawn_bot_if_needed() -> void:
	if not multiplayer.is_server() or GameState.is_dedicated_server:
		return
	if _players.has_node("Bot"):
		return
	_spawn_bot_at(BOT_SPAWN_POS)
	sync_bot_spawn.rpc(BOT_SPAWN_POS)


@rpc("authority", "call_remote", "reliable")
func sync_bot_spawn(pos: Vector2) -> void:
	if _players.has_node("Bot"):
		return
	_spawn_bot_at(pos)


@rpc("authority", "call_local", "reliable")
func sync_bot_impulse(impulse_x: float) -> void:
	var bot := _players.get_node_or_null("Bot")
	if bot and bot.has_method("apply_shove_impulse"):
		bot.apply_shove_impulse(impulse_x)


func _spawn_bot_at(pos: Vector2) -> void:
	if _players.has_node("Bot"):
		return
	var bot: CharacterBody2D = TEST_DUMMY_SCENE.instantiate()
	bot.name = "Bot"
	_players.add_child(bot, true)
	bot.global_position = pos


func _apply_shove_to_bot(from_id: int, impulse_x: float) -> void:
	var a := _players.get_node_or_null(str(from_id)) as Node2D
	var bot := _players.get_node_or_null("Bot") as Node2D
	if a == null or bot == null:
		print("[SHOVE] bot apply skip: missing a=%s bot=%s" % [a, bot])
		return
	var dist: float = a.global_position.distance_to(bot.global_position)
	print("[SHOVE] bot apply dist=%.1f from=%d" % [dist, from_id])
	if dist > SHOVE_RANGE:
		print("[SHOVE] bot apply skip: dist > range")
		return
	var key := "%d>Bot" % from_id
	var now := Time.get_ticks_msec()
	var last: int = int(_shove_last_ms.get(key, -1_000_000_000))
	if now - last < SHOVE_COOLDOWN_MS:
		return
	_shove_last_ms[key] = now
	impulse_x = clampf(impulse_x, -520.0, 520.0)
	if multiplayer.multiplayer_peer == null:
		if bot is CharacterBody2D and bot.has_method("apply_shove_impulse"):
			bot.apply_shove_impulse(impulse_x)
	else:
		sync_bot_impulse.rpc(impulse_x)


@rpc("authority", "call_local", "reliable")
func sync_attack_fx(attacker_id: int) -> void:
	var p := _players.get_node_or_null(str(attacker_id))
	if p and p.has_method("play_attack_vfx"):
		p.play_attack_vfx()


@rpc("any_peer", "call_remote", "reliable")
func server_request_attack(attacker_id: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != attacker_id:
		return
	_process_attack(attacker_id)


func _process_attack(attacker_id: int) -> void:
	var attacker := _players.get_node_or_null(str(attacker_id))
	if attacker == null:
		return
	if multiplayer.multiplayer_peer != null:
		sync_attack_fx.rpc(attacker_id)
	elif attacker.has_method("play_attack_vfx"):
		attacker.play_attack_vfx()
	var center: Vector2 = attacker.global_position
	for c in _players.get_children():
		if c == attacker:
			continue
		if not c is CharacterBody2D:
			continue
		if c.get("hp") == null:
			continue
		if center.distance_to(c.global_position) > ATTACK_RADIUS:
			continue
		var is_bot: bool = c.is_in_group("pushable_dummy")
		var victim_id: int
		if is_bot:
			victim_id = SHOVE_TARGET_BOT_ID
		else:
			victim_id = int(str(c.name))
			if victim_id == attacker_id:
				continue
		var cur_hp: float = float(c.get("hp"))
		var new_hp: float = cur_hp - ATTACK_DAMAGE
		if new_hp <= 0.0:
			_scores[attacker_id] = int(_scores.get(attacker_id, 0)) + 1
			if is_bot:
				_broadcast_bot_respawn()
			else:
				var pos := _spawn_point_for_peer(victim_id)
				_broadcast_respawn(victim_id, pos, PLAYER_MAX_HP)
			_broadcast_scores()
		else:
			if is_bot:
				_broadcast_bot_hp(new_hp)
			else:
				_broadcast_hp(victim_id, new_hp)


func _broadcast_hp(peer_id: int, new_hp: float) -> void:
	if multiplayer.multiplayer_peer == null:
		var p := _players.get_node_or_null(str(peer_id))
		if p:
			p.force_hp(new_hp)
	else:
		net_hp_changed.rpc(peer_id, new_hp)


func _broadcast_bot_hp(new_hp: float) -> void:
	if multiplayer.multiplayer_peer == null:
		var b := _players.get_node_or_null("Bot")
		if b:
			b.force_hp(new_hp)
	else:
		net_bot_hp.rpc(new_hp)


func _broadcast_bot_respawn() -> void:
	if multiplayer.multiplayer_peer == null:
		var b := _players.get_node_or_null("Bot")
		if b:
			b.force_respawn(BOT_SPAWN_POS, PLAYER_MAX_HP)
	else:
		net_bot_respawn.rpc(BOT_SPAWN_POS, PLAYER_MAX_HP)


func _broadcast_respawn(peer_id: int, pos: Vector2, full_hp: float) -> void:
	if multiplayer.multiplayer_peer == null:
		var p := _players.get_node_or_null(str(peer_id))
		if p:
			p.force_respawn(pos, full_hp)
	else:
		net_respawn.rpc(peer_id, pos, full_hp)


func _broadcast_scores() -> void:
	if multiplayer.multiplayer_peer == null:
		_refresh_scoreboard()
	else:
		net_scores_updated.rpc(_scores.duplicate())


@rpc("authority", "call_local", "reliable")
func net_hp_changed(peer_id: int, new_hp: float) -> void:
	var p := _players.get_node_or_null(str(peer_id))
	if p:
		p.force_hp(new_hp)


@rpc("authority", "call_local", "reliable")
func net_bot_hp(new_hp: float) -> void:
	var b := _players.get_node_or_null("Bot")
	if b:
		b.force_hp(new_hp)


@rpc("authority", "call_local", "reliable")
func net_bot_respawn(pos: Vector2, full_hp: float) -> void:
	var b := _players.get_node_or_null("Bot")
	if b:
		b.force_respawn(pos, full_hp)


@rpc("authority", "call_local", "reliable")
func net_respawn(peer_id: int, pos: Vector2, full_hp: float) -> void:
	var p := _players.get_node_or_null(str(peer_id))
	if p:
		p.force_respawn(pos, full_hp)


@rpc("authority", "call_local", "reliable")
func net_scores_updated(scores: Dictionary) -> void:
	_scores = scores
	_refresh_scoreboard()


func _refresh_scoreboard() -> void:
	if _score_label == null:
		return
	if _scores.is_empty():
		_score_label.text = "Очки: —"
		return
	var parts: Array[String] = []
	var keys := _scores.keys()
	keys.sort_custom(func(a, b): return int(_scores[a]) > int(_scores[b]))
	for k in keys:
		var pid: int = int(k)
		var pname := str(pid)
		var node := _players.get_node_or_null(str(pid))
		if node:
			var pn = node.get("player_name")
			if pn is String and not pn.is_empty():
				pname = pn
		parts.append("%s: %d" % [pname, int(_scores[k])])
	_score_label.text = "Очки: " + ", ".join(parts)


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var path := NodePath(str(id))
	if _players.has_node(path):
		_players.get_node(path).queue_free()
	_scores.erase(id)
	_broadcast_scores()


func _spawn_player(peer_id: int, pos: Vector2, pname: String) -> void:
	if _players.has_node(str(peer_id)):
		return
	var p: CharacterBody2D = PLAYER_SCENE.instantiate()
	p.name = str(peer_id)
	p.set_multiplayer_authority(peer_id)
	p.player_name = pname
	_players.add_child(p, true)
	p.global_position = pos


func _spawn_point_for_peer(peer_id: int) -> Vector2:
	var slot := absi(peer_id * 31 + 7) % GameState.MAX_PLAYERS
	return Vector2(200.0 + float(slot) * 140.0, 400.0)


@rpc("any_peer", "call_remote", "reliable")
func client_hello(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var who := multiplayer.get_remote_sender_id()
	for c in _players.get_children():
		if c.is_in_group("pushable_dummy") or str(c.name) == "Bot":
			continue
		var pid: int = int(str(c.name))
		sync_spawn.rpc_id(who, pid, c.global_position, c.player_name)
	var bot_node := _players.get_node_or_null("Bot")
	if bot_node:
		sync_bot_spawn.rpc_id(who, bot_node.global_position)
	var slot := clampi(_players.get_child_count(), 0, GameState.MAX_PLAYERS - 1)
	var pos := Vector2(200.0 + float(slot) * 140.0, 400.0)
	_spawn_player(who, pos, pname)
	sync_spawn.rpc_id(who, who, pos, pname)
	if not _scores.is_empty():
		net_scores_updated.rpc_id(who, _scores.duplicate())


@rpc("authority", "call_remote", "reliable")
func sync_spawn(peer_id: int, pos: Vector2, pname: String) -> void:
	_spawn_player(peer_id, pos, pname)
