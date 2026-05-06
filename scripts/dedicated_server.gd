extends Node
## Выделенный сервер без отдельной «главной сцены» в CLI: официальный экспорт Godot
## не поддерживает `binary res://...` (path overrides выключены в шаблоне).
## VPS:  MPGAMESTICK_DEDICATED=1  ./MPGameStick.x86_64 --headless
## Локально:  ./MPGameStick.x86_64 --headless --dedicated

const PORT := 7777


func _ready() -> void:
	print(
		"DedicatedServer: _ready env MPGAMESTICK_DEDICATED=%s args=%s"
		% [OS.get_environment("MPGAMESTICK_DEDICATED"), str(OS.get_cmdline_args())]
	)
	if _want_dedicated():
		call_deferred("_begin")
	else:
		print("DedicatedServer: normal client build — лобби, без ENet-сервера.")


func _goto_main() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _want_dedicated() -> bool:
	var e := OS.get_environment("MPGAMESTICK_DEDICATED").strip_edges().to_lower()
	if e in ["1", "true", "yes", "on"]:
		return true
	for a in OS.get_cmdline_args():
		if a.strip_edges() == "--dedicated":
			return true
	return false


## Вызов из `Dedicated.tscn`, если эту сцену запускаешь как главную в редакторе.
func run_from_dedicated_scene() -> void:
	var mp := get_tree().get_multiplayer()
	if mp.multiplayer_peer is ENetMultiplayerPeer:
		return
	_begin()


func _begin() -> void:
	# Нельзя проверять `!= null`: по умолчанию может быть OfflineMultiplayerPeer — не null,
	# и сервер бы никогда не поднялся.
	var mp := get_tree().get_multiplayer()
	if mp.multiplayer_peer is ENetMultiplayerPeer:
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, GameState.MAX_PLAYERS)
	if err != OK:
		push_error("DedicatedServer: create_server failed: %s" % err)
		get_tree().quit(1)
		return
	mp.multiplayer_peer = peer
	GameState.is_dedicated_server = true
	GameState.display_name = "Сервер"
	print("Dedicated ENet server on UDP %d (max %d clients)" % [PORT, GameState.MAX_PLAYERS])
	print(
		"DedicatedServer: проверка порта на Ubuntu — "
		+ "sudo ss -ulpn | grep 7777 ; sudo ufw status ; sudo ufw allow 7777/udp"
	)
	call_deferred("_goto_main")
