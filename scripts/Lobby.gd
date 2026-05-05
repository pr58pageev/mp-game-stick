extends Control

const PORT := 7777
const DEFAULT_HOST_FILE := "res://config/default_server_host.txt"

@onready var _name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var _address_edit: LineEdit = $VBox/AddressRow/HostAddressEdit
@onready var _status: Label = $VBox/Status

var _cached_default_host: String = ""


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	_address_edit.text = _read_default_server_host()


func _read_default_server_host() -> String:
	if not _cached_default_host.is_empty():
		return _cached_default_host
	if FileAccess.file_exists(DEFAULT_HOST_FILE):
		var f := FileAccess.open(DEFAULT_HOST_FILE, FileAccess.READ)
		if f:
			while not f.eof_reached():
				var line := f.get_line().strip_edges()
				if line.is_empty() or line.begins_with("#"):
					continue
				_cached_default_host = line
				break
	if _cached_default_host.is_empty():
		_cached_default_host = "127.0.0.1"
	return _cached_default_host


func _on_host_pressed() -> void:
	var n := _name_edit.text.strip_edges()
	if n.is_empty():
		_status.text = "Введите имя."
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 2)
	if err != OK:
		_status.text = "Не удалось создать сервер: %s" % err
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = n
	_status.text = "Сервер запущен. Ожидайте второго игрока…"
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_join_pressed() -> void:
	var n := _name_edit.text.strip_edges()
	if n.is_empty():
		_status.text = "Введите имя."
		return
	var host := _address_edit.text.strip_edges()
	if host.is_empty():
		host = _read_default_server_host()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, PORT)
	if err != OK:
		_status.text = "Не удалось подключиться: %s" % err
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = n
	_status.text = "Подключение…"


func _on_connected_to_server() -> void:
	_status.text = "В игре."
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_connection_failed() -> void:
	_status.text = "Ошибка: не удалось достучаться до хоста. Проверьте IP и Wi‑Fi."
