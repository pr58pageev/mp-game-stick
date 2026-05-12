extends RefCounted
class_name WorldSave
## Сохранение seed мира в user:// — один и тот же ландшафт при каждом входе (как сид в Minecraft).

const CFG_REL := "persistent_world.cfg"


static func _path() -> String:
	return "user://%s" % CFG_REL


static func load_seed() -> int:
	var cf := ConfigFile.new()
	if cf.load(_path()) != OK:
		return -1
	return int(cf.get_value("world", "seed", -1))


static func save_seed(seed: int) -> void:
	var cf := ConfigFile.new()
	var _e := cf.load(_path())
	cf.set_value("world", "seed", seed)
	var err := cf.save(_path())
	if err != OK:
		push_warning("WorldSave: сохранение не удалось err=%s" % err)


static func delete_save() -> void:
	var dir := DirAccess.open("user://")
	if dir and dir.file_exists(CFG_REL):
		dir.remove(CFG_REL)


## Порядок расширений мира: "l","r","u","d" — нужен для детерминированного воспроизведения (мультиплеер / загрузка).
static func load_extension_log() -> String:
	var cf := ConfigFile.new()
	if cf.load(_path()) != OK:
		return ""
	return str(cf.get_value("world", "ext_log", ""))


static func append_extension_char(ch: String) -> void:
	var cf := ConfigFile.new()
	cf.load(_path())
	var cur := str(cf.get_value("world", "ext_log", ""))
	cf.set_value("world", "ext_log", cur + ch)
	var err := cf.save(_path())
	if err != OK:
		push_warning("WorldSave: не удалось сохранить ext_log err=%s" % err)


## Последняя позиция локального игрока (пиксели мира), привязана к сиду мира.
## Всегда дублируем world/seed в файл — иначе при первом сохранении без загрузки cfg теряется сид.
static func save_player_position(pos: Vector2, world_seed: int) -> void:
	var cf := ConfigFile.new()
	cf.load(_path())
	cf.set_value("world", "seed", world_seed)
	cf.set_value("player", "x", pos.x)
	cf.set_value("player", "y", pos.y)
	cf.set_value("player", "last_seed", world_seed)
	var err := cf.save(_path())
	if err != OK:
		push_warning("WorldSave: позиция игрока не сохранена err=%s" % err)


## Если нет данных или сид не совпадает — Vector2(NAN, NAN).
static func load_saved_player_position(world_seed: int) -> Vector2:
	var cf := ConfigFile.new()
	if cf.load(_path()) != OK:
		return Vector2(NAN, NAN)
	if int(cf.get_value("player", "last_seed", -999999)) != world_seed:
		return Vector2(NAN, NAN)
	if not cf.has_section_key("player", "x"):
		return Vector2(NAN, NAN)
	return Vector2(
		float(cf.get_value("player", "x", 0.0)),
		float(cf.get_value("player", "y", 0.0))
	)


## Снимок орков для текущего сида (только сервер пишет; все клиенты получают состояние по RPC).
static func save_orcs_snapshot(world_seed: int, next_orc_id: int, entries: Array) -> void:
	var cf := ConfigFile.new()
	cf.load(_path())
	cf.set_value("world", "seed", world_seed)
	cf.set_value("orcs", "for_seed", world_seed)
	cf.set_value("orcs", "next_id", next_orc_id)
	cf.set_value("orcs", "json", JSON.stringify(entries))
	var err := cf.save(_path())
	if err != OK:
		push_warning("WorldSave: орки не сохранены err=%s" % err)


## Пустой Dictionary, если нет данных для этого сида.
static func load_orcs_snapshot(world_seed: int) -> Dictionary:
	var cf := ConfigFile.new()
	if cf.load(_path()) != OK:
		return {}
	if int(cf.get_value("orcs", "for_seed", -999999)) != world_seed:
		return {}
	var js := str(cf.get_value("orcs", "json", "[]"))
	var parsed: Variant = JSON.parse_string(js)
	if parsed == null or typeof(parsed) != TYPE_ARRAY:
		return {}
	return {"next_id": int(cf.get_value("orcs", "next_id", 0)), "list": parsed as Array}


## Новый сид только если force_new или файла ещё не было.
static func resolve_seed(force_new: bool) -> int:
	if force_new:
		delete_save()
	var s := load_seed()
	if s >= 0:
		return s
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var ns: int = rng.randi()
	save_seed(ns)
	return ns
