extends Node
## Данные между сценами (лобби → игра).

const MAX_PLAYERS := 8
## Задаётся Main после генерации карты (пиксели мира).
var world_rect: Rect2 = Rect2(0.0, 0.0, 1024.0, 640.0)

var display_name: String = ""
## true только для headless VPS (MPGAMESTICK_DEDICATED): без персонажа-сервера на сцене.
var is_dedicated_server: bool = false

## Текущий сид процедурного мира (хост задаёт; клиенты получают по RPC).
var world_seed: int = 0
## Лобби: «Новый мир» — при следующей генерации Main создаётся другой сид и перезаписывается сохранение.
var request_new_world: bool = false
