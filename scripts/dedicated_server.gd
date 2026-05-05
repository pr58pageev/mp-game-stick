extends Node
## Выделенный сервер без отдельной «главной сцены» в CLI: официальный экспорт Godot
## не поддерживает `binary res://...` (path overrides выключены в шаблоне).
## VPS:  MPGAMESTICK_DEDICATED=1  ./MPGameStick.x86_64 --headless
## Локально:  ./MPGameStick.x86_64 --headless --dedicated

const PORT := 7777
const MAX_CLIENTS := 64


func _ready() -> void:
	if _want_dedicated():
		_begin()


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
	if multiplayer.multiplayer_peer != null:
		return
	_begin()


func _begin() -> void:
	if multiplayer.multiplayer_peer != null:
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("DedicatedServer: create_server failed: %s" % err)
		get_tree().quit(1)
		return
	get_tree().multiplayer.multiplayer_peer = peer
	GameState.display_name = "Сервер"
	print("Dedicated ENet server on UDP %d (max %d clients)" % [PORT, MAX_CLIENTS])
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
