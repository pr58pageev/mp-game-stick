extends Node2D

const PLAYER_SCENE := preload("res://scenes/Player.tscn")

@onready var _players: Node2D = $Players


func _ready() -> void:
	if multiplayer.multiplayer_peer == null:
		_spawn_player(1, Vector2(640, 400), "Локально")
		return

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if multiplayer.is_server():
		_spawn_player(1, Vector2(420, 400), GameState.display_name)
	else:
		client_hello.rpc_id(1, GameState.display_name)


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var path := NodePath(str(id))
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
func client_hello(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var who := multiplayer.get_remote_sender_id()
	for c in _players.get_children():
		var pid: int = int(str(c.name))
		sync_spawn.rpc_id(who, pid, c.global_position, c.player_name)
	var pos := Vector2(860, 400)
	_spawn_player(who, pos, pname)
	sync_spawn.rpc_id(who, who, pos, pname)


@rpc("authority", "call_remote", "reliable")
func sync_spawn(peer_id: int, pos: Vector2, pname: String) -> void:
	_spawn_player(peer_id, pos, pname)
