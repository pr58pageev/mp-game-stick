extends Control

const PORT := 7777
const DEFAULT_HOST_FILE := "res://config/default_server_host.txt"
## Публичный тестовый VPS (UDP 7777 должен быть открыт).
const TEST_SERVER_HOST := "178.57.222.23"

@onready var _name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var _address_edit: LineEdit = $VBox/AddressRow/HostAddressEdit
@onready var _status: Label = $VBox/Status

var _cached_default_host: String = ""


func _ready() -> void:
	_ensure_multiplayer_signals()
	_address_edit.text = _read_default_server_host()
	_apply_default_nickname_to_field()


func _apply_default_nickname_to_field() -> void:
	if not GameState.display_name.strip_edges().is_empty():
		_name_edit.text = GameState.display_name
	elif _name_edit.text.strip_edges().is_empty():
		_name_edit.text = "Аноним%d" % randi_range(100, 999)
	print("[Lobby] ник в поле: \"%s\"" % _name_edit.text)


func _ensure_multiplayer_signals() -> void:
	var mp := multiplayer
	if not mp.connected_to_server.is_connected(_on_connected_to_server):
		mp.connected_to_server.connect(_on_connected_to_server)
	if not mp.connection_failed.is_connected(_on_connection_failed):
		mp.connection_failed.connect(_on_connection_failed)
	if not mp.server_disconnected.is_connected(_on_server_disconnected):
		mp.server_disconnected.connect(_on_server_disconnected)


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
	var err := peer.create_server(PORT, GameState.MAX_PLAYERS)
	if err != OK:
		_status.text = "Не удалось создать сервер: %s" % err
		push_error("Lobby: create_server err=%s" % err)
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = n
	print("[Lobby] host OK nick=\"%s\" port=%d max=%d" % [n, PORT, GameState.MAX_PLAYERS])
	_status.text = "Сервер запущен. Ожидайте игроков (до %d)…" % GameState.MAX_PLAYERS
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_join_pressed() -> void:
	var host := _address_edit.text.strip_edges()
	if host.is_empty():
		host = _read_default_server_host()
	_join_to_host(host)


func _on_join_test_server_pressed() -> void:
	_join_to_host(TEST_SERVER_HOST)


func _join_to_host(host: String) -> void:
	var n := _name_edit.text.strip_edges()
	if n.is_empty():
		_status.text = "Введите имя."
		return
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, PORT)
	if err != OK:
		_status.text = "Ошибка create_client: %s" % err
		push_error("Lobby: create_client failed err=%s host=%s" % [err, host])
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = n
	print("[Lobby] подключение nick=\"%s\" -> %s:%d" % [n, host, PORT])
	_status.text = "Подключение к %s:%d…" % [host, PORT]


func _on_connected_to_server() -> void:
	print(
		"[Lobby] connected_to_server unique_id=%d nick=\"%s\""
		% [multiplayer.get_unique_id(), GameState.display_name]
	)
	_status.text = "В игре."
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_connection_failed() -> void:
	var st := "—"
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		st = str(peer.get_connection_status())
	push_error(
		"Lobby: connection_failed nick=\"%s\" status=%s host UDP %d (см. логи сервера peer_connected)"
		% [GameState.display_name, st, PORT]
	)
	multiplayer.multiplayer_peer = null
	_status.text = (
		"Нет связи с хостом (статус %s). Проверьте IP, UDP-порт %d, фаервол на VPS и Wi‑Fi."
		% [st, PORT]
	)


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_status.text = "Сервер завершил работу (хост вышел или сеть оборвалась)."
	print("[Lobby] server_disconnected")
