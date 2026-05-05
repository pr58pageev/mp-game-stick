extends Node
## Запуск из редактора: открой сцену Dedicated.tscn и F6 — поднимется сервер.
## На VPS используй переменную окружения (см. dedicated_server.gd).


func _ready() -> void:
	get_node("/root/DedicatedServer").run_from_dedicated_scene()
