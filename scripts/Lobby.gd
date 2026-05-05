extends Control

const PORT := 7777

@onready var _name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var _address_edit: LineEdit = $VBox/AddressRow/HostAddressEdit
@onready var _status: Label = $VBox/Status


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)


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
		host = "127.0.0.1"
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
