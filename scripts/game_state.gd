extends Node
## Данные между сценами (лобби → игра).

const MAX_PLAYERS := 8

var display_name: String = ""
## true только для headless VPS (MPGAMESTICK_DEDICATED): без персонажа-сервера на сцене.
var is_dedicated_server: bool = false
