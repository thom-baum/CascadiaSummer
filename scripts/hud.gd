extends CanvasLayer
## Cascadia milestone 4 HUD. Minimal soulslike layout: health and stamina bars
## bottom-left in a cold muted PNW palette and the death/respawn fade
## sequence.
## Health is pushed by Health.damaged/died signals; stamina mirrors the player's
## continuously regenerating pool every frame (no stamina signal exists). On
## Health.died the HUD fades to black, shows a short melancholic line, teleports
## the player back to SpawnPoint, restores health/stamina, and resets every node
## in the "enemies" group to home. The player node itself is never recreated, so
## the HUD binding stays valid across respawns.

@export var player_path: NodePath = ^"../Player"
@export var spawn_path: NodePath = ^"../SpawnPoint"
@export var health_bar_path: NodePath = ^"Bars/HealthBar"
@export var stamina_bar_path: NodePath = ^"Bars/StaminaBar"
@export var death_label_path: NodePath = ^"DeathText"
@export var fade_rect_path: NodePath = ^"FadeRect"

@export_group("Critical prompt")
## Label shown while a vulnerable enemy is inside the player's critical_range.
@export var critical_prompt_path: NodePath = ^"CriticalPrompt"

@export_group("Death sequence")
@export var fade_in_time: float = 0.7
@export var death_line_hold: float = 1.2
@export var fade_out_time: float = 0.9
@export var death_line_alpha: float = 0.8

@export_group("Damage numbers")
@export var damage_popup_lifetime: float = 0.85
@export var damage_popup_rise_px: float = 46.0
@export var damage_popup_font_size: int = 17
@export var damage_popup_color: Color = Color(0.8, 0.87, 0.92, 0.98)
@export var damage_popup_outline: Color = Color(0.02, 0.03, 0.04, 0.9)

const POPUP_MAX := 16

var _player: Node = null
var _health: Health = null
var _spawn: Node3D = null
var _health_bar: ProgressBar = null
var _stamina_bar: ProgressBar = null
var _death_label: Label = null
var _fade_rect: ColorRect = null
var _critical_prompt: Label = null
var _fade_tween: Tween = null
var _death_active: bool = false
var _popups: Array[Dictionary] = []
var _popup_free: Array[Label] = []


func _ready() -> void:
	_player = get_node_or_null(player_path)
	_health_bar = get_node_or_null(health_bar_path) as ProgressBar
	_stamina_bar = get_node_or_null(stamina_bar_path) as ProgressBar
	_death_label = get_node_or_null(death_label_path) as Label
	_fade_rect = get_node_or_null(fade_rect_path) as ColorRect
	_critical_prompt = get_node_or_null(critical_prompt_path) as Label
	_spawn = get_node_or_null(spawn_path) as Node3D

	if _player == null:
		return
	_health = _player.get_node_or_null("Health") as Health
	if _health != null:
		_health.damaged.connect(_on_health_damaged)
		_health.died.connect(_on_player_died)
		_update_health_bar()
	_connect_damage_popup_targets()


func _process(delta: float) -> void:
	# Stamina drains and regenerates continuously, so mirror it per frame.
	if _player != null:
		var stamina: float = float(_player.get("stamina"))
		var max_stamina: float = float(_player.get("max_stamina"))
		if _stamina_bar != null:
			if _stamina_bar.max_value != max_stamina:
				_stamina_bar.max_value = max_stamina
			_stamina_bar.value = stamina
	_update_critical_prompt()
	_update_damage_popups(delta)


## The Critical Attack prompt appears while the player is in range of a
## vulnerable enemy. The controller owns the exact eligibility rule
## (is_critical_eligible) and the HUD merely mirrors it every frame.
func _update_critical_prompt() -> void:
	if _critical_prompt == null:
		return
	var show: bool = false
	if _player != null and not _death_active and _player.has_method("is_critical_eligible"):
		show = bool(_player.call("is_critical_eligible"))
	if _critical_prompt.visible != show:
		_critical_prompt.visible = show


# --- Health bar (signal driven) ---------------------------------------------

func _on_health_damaged(_amount: int, _current: int) -> void:
	_update_health_bar()


func _update_health_bar() -> void:
	if _health_bar == null or _health == null:
		return
	_health_bar.max_value = _health.max_health
	_health_bar.value = _health.current


# --- Death and respawn loop --------------------------------------------------

func _on_player_died() -> void:
	if _death_active:
		return
	_death_active = true
	if _player != null and _player.has_method("set_dead"):
		_player.call("set_dead", true)
	_update_health_bar()
	await _fade_to(1.0, fade_in_time)
	await _show_death_line()
	_respawn_player()
	_update_health_bar()
	await _fade_to(0.0, fade_out_time)
	_death_active = false


func _show_death_line() -> void:
	if _death_label == null:
		return
	_death_label.modulate.a = 0.0
	_death_label.visible = true
	var tw := create_tween()
	tw.tween_property(_death_label, "modulate:a", death_line_alpha, 0.4)
	await get_tree().create_timer(death_line_hold, true).timeout
	# Keep the line readable during the fade-out, then clear it.
	await get_tree().create_timer(fade_out_time * 0.25, true).timeout
	tw = create_tween()
	tw.tween_property(_death_label, "modulate:a", 0.0, fade_out_time * 0.75)
	await tw.finished
	_death_label.visible = false


func _respawn_player() -> void:
	if _player == null:
		return
	if _spawn != null:
		_player.global_position = _spawn.global_position
	_player.set("velocity", Vector3.ZERO)
	if _player.has_method("reset_for_respawn"):
		_player.call("reset_for_respawn")
	if _player.has_method("set_dead"):
		_player.call("set_dead", false)
	for node in get_tree().get_nodes_in_group("enemies"):
		if node.has_method("reset_to_home"):
			node.call("reset_to_home")


func _fade_to(alpha: float, dur: float) -> void:
	if _fade_rect == null:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_rect.color.a = 0.0 if alpha <= 0.0 else 1.0 - alpha
	_fade_tween = create_tween()
	_fade_tween.tween_property(_fade_rect, "color:a", alpha, dur)
	await _fade_tween.finished


# --- Floating damage numbers --------------------------------------------------
#
# Small desaturated numbers float up from whatever lockable target the player
# just hit (enemy or training dummy). The HUD listens to each target's Health
# damaged signal and projects a short-lived Label from the world anchor every
# frame, so popups track the target while the camera orbits. Every hit that
# lands shows its real number; no internal one-shot damage exists anymore.

func _connect_damage_popup_targets() -> void:
	for node in get_tree().get_nodes_in_group("lockable"):
		if not (node is Node3D) or not node.has_node("Health"):
			continue
		var target_health := node.get_node("Health") as Health
		if target_health != null and not target_health.damaged.is_connected(_on_target_damaged):
			target_health.damaged.connect(_on_target_damaged.bind(node))


func _on_target_damaged(amount: int, _current: int, target: Node) -> void:
	if amount <= 0:
		return
	if not (target is Node3D) or not (target as Node3D).is_inside_tree():
		return
	if _death_active:
		return
	_spawn_damage_popup(target as Node3D, amount)


func _spawn_damage_popup(target: Node3D, amount: int) -> void:
	if _popups.size() >= POPUP_MAX:
		_retire_popup(0)
	var label := _popup_label()
	label.text = str(amount)
	label.modulate.a = 1.0
	label.position = Vector2(-400, -400)
	_popups.append({
		"label": label,
		"target": target,
		"age": 0.0,
		"anchor": _target_popup_height(target),
	})


func _popup_label() -> Label:
	if not _popup_free.is_empty():
		var reuse: Label = _popup_free.pop_back()
		reuse.visible = true
		reuse.modulate.a = 1.0
		return reuse
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", damage_popup_font_size)
	label.add_theme_color_override("font_color", damage_popup_color)
	label.add_theme_color_override("font_outline_color", damage_popup_outline)
	label.add_theme_constant_override("outline_size", 3)
	add_child(label)
	return label


func _target_popup_height(target: Node3D) -> float:
	var hurtbox := target.get_node_or_null("Hurtbox") as Area3D
	if hurtbox != null:
		for child in hurtbox.get_children():
			if child is CollisionShape3D and child.shape != null:
				var cs := child as CollisionShape3D
				var top := cs.position.y
				if cs.shape is CapsuleShape3D:
					top += (cs.shape as CapsuleShape3D).height * 0.5
				elif cs.shape is BoxShape3D:
					top += (cs.shape as BoxShape3D).size.y * 0.5
				return top + 0.34
	return 2.1


func _update_damage_popups(delta: float) -> void:
	if _popups.is_empty():
		return
	var camera := get_viewport().get_camera_3d()
	var i := 0
	while i < _popups.size():
		var entry: Dictionary = _popups[i]
		entry["age"] = float(entry["age"]) + delta
		var age: float = float(entry["age"])
		var label: Label = entry["label"]
		var target: Node3D = entry["target"]
		if age >= damage_popup_lifetime or target == null or not is_instance_valid(target) or not target.is_inside_tree():
			_retire_popup(i)
			continue
		if camera != null:
			var world: Vector3 = target.global_position + Vector3(0.0, float(entry["anchor"]), 0.0)
			var screen := camera.unproject_position(world)
			screen.y -= age * damage_popup_rise_px
			var half := label.get_minimum_size() * 0.5
			label.position = screen - half
		var fade_at := damage_popup_lifetime * 0.45
		label.modulate.a = 1.0 if age < fade_at else clampf(1.0 - (age - fade_at) / maxf(damage_popup_lifetime - fade_at, 0.001), 0.0, 1.0)
		i += 1


func _retire_popup(index: int) -> void:
	var entry: Dictionary = _popups[index]
	var label: Label = entry["label"]
	label.visible = false
	label.modulate.a = 1.0
	_popup_free.append(label)
	_popups.remove_at(index)
