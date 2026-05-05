extends Node
## Запуск: Godot --headless --path . res://scenes/Dedicated.tscn
## Или собранный бинарник: ./MPGameStick --headless res://scenes/Dedicated.tscn

const PORT := 7777
const MAX_CLIENTS := 64


func _ready() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("Dedicated server: create_server failed: %s" % err)
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = "Сервер"
	print("Dedicated ENet server listening on UDP %d (max %d clients)" % [PORT, MAX_CLIENTS])
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
