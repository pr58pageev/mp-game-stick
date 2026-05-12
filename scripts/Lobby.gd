extends Control

const PORT := 7777
const DEFAULT_HOST_FILE := "res://config/default_server_host.txt"
## Публичный тестовый VPS (UDP 7777 должен быть открыт).
const TEST_SERVER_HOST := "178.57.222.23"
const CONSOLE_MAX_LINES := 200

@onready var _name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var _address_edit: LineEdit = $VBox/AddressRow/HostAddressEdit
@onready var _status: Label = $VBox/Status
@onready var _console_panel: PanelContainer = $DebugConsole/Root/ConsolePanel
@onready var _console_log: TextEdit = $DebugConsole/Root/ConsolePanel/VBox/ConsoleLog
@onready var _console_toggle: Button = $DebugConsole/Root/ConsoleToggleButton

var _cached_default_host: String = ""
var _join_diag_timer: Timer
var _console_visible: bool = false


func _ready() -> void:
	_ensure_multiplayer_signals()
	_address_edit.text = _read_default_server_host()
	_apply_default_nickname_to_field()
	_console_panel.visible = false
	_console_toggle.text = "Показать консоль"
	_log_console("Лобби: нажми «Показать консоль», чтобы видеть лог UDP-подключения.")
	if OS.get_name() == "iOS":
		_log_console(
			"iOS: режим разработчика для выхода в интернет не нужен. "
			+ "Нет строк peer_connected на VPS — UDP до сервера не доходит (LTE/Wi‑Fi, IP, порт 7777, ufw)."
		)


func _log_console(msg: String) -> void:
	print(msg)
	if _console_log == null:
		return
	var line := "%s  %s\n" % [Time.get_time_string_from_system(), msg]
	_console_log.text += line
	var parts := _console_log.text.split("\n")
	if parts.size() > CONSOLE_MAX_LINES:
		_console_log.text = "\n".join(parts.slice(parts.size() - CONSOLE_MAX_LINES + 1))
	call_deferred("_scroll_console_to_end")


func _scroll_console_to_end() -> void:
	if _console_log == null:
		return
	var sb := _console_log.get_v_scroll_bar()
	if sb:
		sb.value = sb.max_value


func _on_console_toggle_pressed() -> void:
	_console_visible = not _console_visible
	_console_panel.visible = _console_visible
	_console_toggle.text = "Скрыть консоль" if _console_visible else "Показать консоль"


func _apply_default_nickname_to_field() -> void:
	if not GameState.display_name.strip_edges().is_empty():
		_name_edit.text = GameState.display_name
	elif _name_edit.text.strip_edges().is_empty():
		_name_edit.text = "Аноним%d" % randi_range(100, 999)
	_log_console("Ник в поле: \"%s\"" % _name_edit.text)


func _ensure_multiplayer_signals() -> void:
	var mp := multiplayer
	if not mp.connected_to_server.is_connected(_on_connected_to_server):
		mp.connected_to_server.connect(_on_connected_to_server)
	if not mp.connection_failed.is_connected(_on_connection_failed):
		mp.connection_failed.connect(_on_connection_failed)
	if not mp.server_disconnected.is_connected(_on_server_disconnected):
		mp.server_disconnected.connect(_on_server_disconnected)


func _connection_status_name(st: int) -> String:
	match st:
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			return "DISCONNECTED"
		MultiplayerPeer.CONNECTION_CONNECTING:
			return "CONNECTING"
		MultiplayerPeer.CONNECTION_CONNECTED:
			return "CONNECTED"
		_:
			return "?"


func _stop_join_diagnostics() -> void:
	if _join_diag_timer != null and is_instance_valid(_join_diag_timer):
		_join_diag_timer.queue_free()
		_join_diag_timer = null


func _start_join_diagnostics(host: String) -> void:
	_stop_join_diagnostics()
	_join_diag_timer = Timer.new()
	_join_diag_timer.wait_time = 0.35
	_join_diag_timer.one_shot = false
	add_child(_join_diag_timer)
	var ticks := { "i": 0 }
	_join_diag_timer.timeout.connect(
		func() -> void:
			var p := multiplayer.multiplayer_peer as ENetMultiplayerPeer
			if p == null:
				_stop_join_diagnostics()
				return
			var st: int = p.get_connection_status()
			_log_console(
				"join_diag #%d → %s  status=%d (%s)"
				% [ticks.i, host, st, _connection_status_name(st)]
			)
			ticks.i += 1
			if st == MultiplayerPeer.CONNECTION_CONNECTED:
				_stop_join_diagnostics()
				return
			if ticks.i >= 48:
				_log_console(
					"Долго CONNECTING: проверь сеть, IP, UDP %d, ufw на VPS; второй телефон на LTE часто хуже того же Wi‑Fi."
					% PORT
				)
				_stop_join_diagnostics()
	)
	_join_diag_timer.start()


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
	_stop_join_diagnostics()
	var n := _name_edit.text.strip_edges()
	if n.is_empty():
		_status.text = "Введите имя."
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, GameState.MAX_PLAYERS)
	if err != OK:
		_status.text = "Не удалось создать сервер: %s" % err
		_log_console("create_server err=%s" % err)
		push_error("Lobby: create_server err=%s" % err)
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = n
	_log_console("host OK nick=\"%s\" port=%d max=%d" % [n, PORT, GameState.MAX_PLAYERS])
	_status.text = "Сервер запущен. Ожидайте игроков (до %d)…" % GameState.MAX_PLAYERS
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_join_pressed() -> void:
	var host := _address_edit.text.strip_edges()
	if host.is_empty():
		host = _read_default_server_host()
	_join_to_host(host)


func _on_join_test_server_pressed() -> void:
	_join_to_host(TEST_SERVER_HOST)


func _on_new_world_pressed() -> void:
	## Следующий запуск сценой Main у хоста/сервера пересоздаст сид и перезапишет user://persistent_world.cfg.
	GameState.request_new_world = true
	_status.text = (
		"Следующий вход как хост или одиночная игра создаст новую карту и сохранит новый сид."
	)
	_log_console("Новый мир: request_new_world=true (сохранение карты сбросится при следующей генерации у хоста)")


func _join_to_host(host: String) -> void:
	var n := _name_edit.text.strip_edges()
	if n.is_empty():
		_status.text = "Введите имя."
		return
	_stop_join_diagnostics()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, PORT)
	if err != OK:
		_status.text = "Ошибка create_client: %s" % err
		_log_console("create_client FAILED err=%s host=%s:%d" % [err, host, PORT])
		push_error("Lobby: create_client failed err=%s host=%s" % [err, host])
		return
	multiplayer.multiplayer_peer = peer
	GameState.display_name = n
	_log_console(
		"Подключение nick=\"%s\" → %s:%d  (после create: %d %s)"
		% [n, host, PORT, peer.get_connection_status(), _connection_status_name(peer.get_connection_status())]
	)
	_status.text = "Подключение к %s:%d…" % [host, PORT]
	_start_join_diagnostics(host)


func _on_connected_to_server() -> void:
	_stop_join_diagnostics()
	_log_console(
		"Успех: connected_to_server unique_id=%d nick=\"%s\""
		% [multiplayer.get_unique_id(), GameState.display_name]
	)
	_status.text = "В игре."
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_connection_failed() -> void:
	_stop_join_diagnostics()
	var raw := -1
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		raw = peer.get_connection_status()
	_log_console(
		"connection_failed nick=\"%s\" status=%d (%s) — UDP не прошёл или неверный IP/порт; сравни с journalctl peer_connected на VPS."
		% [GameState.display_name, raw, _connection_status_name(raw)]
	)
	push_error(
		"Lobby: connection_failed nick=\"%s\" status=%d host UDP %d (см. логи сервера peer_connected)"
		% [GameState.display_name, raw, PORT]
	)
	multiplayer.multiplayer_peer = null
	_status.text = (
		"Нет связи с хостом (статус %d). Проверьте IP, UDP-порт %d, фаервол на VPS и Wi‑Fi."
		% [raw, PORT]
	)


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_status.text = "Сервер завершил работу (хост вышел или сеть оборвалась)."
	_log_console("server_disconnected")
