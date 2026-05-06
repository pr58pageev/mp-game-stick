extends Node
## Данные между сценами (лобби → игра).

const MAX_PLAYERS := 8
## Границы уровня по X (широкая арена в Main + камера).
const ARENA_X_MIN := 80.0
const ARENA_X_MAX := 3920.0

var display_name: String = ""
## true только для headless VPS (MPGAMESTICK_DEDICATED): без персонажа-сервера на сцене.
var is_dedicated_server: bool = false
