extends CharacterBody3D
## Passive training dummy: solid body with a Hurtbox (Area3D) and a Health
## component. When the player lands a hit the dummy flashes white, triggers a
## small global hitstop, and is knocked back by a decaying impulse. It can be
## downed but never stays dead: after down_time it resets to home and fully
## regenerates so testing can continue.

@export var knockback_force: float = 5.0
@export var knockback_drag: float = 10.0
@export var down_time: float = 2.2
@export var flash_duration: float = 0.16

@onready var _health: Health = $Health
@onready var _hurtbox: Area3D = $Hurtbox
@onready var _body_mesh: MeshInstance3D = $VisualRoot/Body
@onready var _head_mesh: MeshInstance3D = $VisualRoot/Head
@onready var _hit_fx: GPUParticles3D = $HitFx

var _home: Vector3 = Vector3.ZERO
var _down_remaining: float = 0.0
var _flash_tween: Tween = null
var _body_mat: StandardMaterial3D = null
var _head_mat: StandardMaterial3D = null
var _base_color: Color = Color.WHITE
var _hitstop_active: bool = false


func _ready() -> void:
	_home = global_position
	floor_snap_length = 0.3
	_body_mat = _own_material(_body_mesh)
	_head_mat = _own_material(_head_mesh)
	if _body_mat != null:
		_base_color = _body_mat.albedo_color
	_health.damaged.connect(_on_damaged)
	_health.died.connect(_on_died)


func _own_material(mesh: MeshInstance3D) -> StandardMaterial3D:
	var mat := mesh.material_override as StandardMaterial3D
	if mat == null:
		mat = mesh.get_active_material(0) as StandardMaterial3D
	if mat == null:
		return null
	var copy: StandardMaterial3D = mat.duplicate() as StandardMaterial3D
	mesh.material_override = copy
	return copy


func _physics_process(delta: float) -> void:
	# Constant downward push keeps the dummy planted on the floor.
	velocity.y = -6.0
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if horizontal.length_squared() > 0.0001:
		horizontal = horizontal.move_toward(Vector3.ZERO, knockback_drag * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()
	if _down_remaining > 0.0:
		_down_remaining -= delta
		if _down_remaining <= 0.0:
			_reset_after_down()


func _on_damaged(amount: int, _current: int) -> void:
	_flash()
	_trigger_hitstop()
	_play_hit_fx()
	var dir := _knockback_dir()
	var force := minf(knockback_force + float(amount) * 0.05, 8.5)
	velocity.x = dir.x * force
	velocity.z = dir.z * force


func _on_died() -> void:
	_down_remaining = down_time
	_hurtbox.monitoring = false
	var dir := _knockback_dir()
	velocity.x = dir.x * 7.5
	velocity.z = dir.z * 7.5
	_set_down_tint()


func _knockback_dir() -> Vector3:
	var source := _health.last_hit_source
	if source is Node3D:
		var to := global_position - (source as Node3D).global_position
		to.y = 0.0
		if to.length_squared() > 0.0001:
			return to.normalized()
	return Vector3.FORWARD


func _flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	if _body_mat != null:
		_body_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	if _head_mat != null:
		_head_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	_flash_tween = create_tween().set_parallel(true)
	if _body_mat != null:
		_flash_tween.tween_property(_body_mat, "albedo_color", _base_color, flash_duration)
	if _head_mat != null:
		_flash_tween.tween_property(_head_mat, "albedo_color", _base_color, flash_duration)


func _set_down_tint() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	if _body_mat != null:
		_body_mat.albedo_color = Color(0.22, 0.2, 0.2, 1.0)
	if _head_mat != null:
		_head_mat.albedo_color = Color(0.22, 0.2, 0.2, 1.0)


func _reset_after_down() -> void:
	global_position = _home
	velocity = Vector3.ZERO
	_hurtbox.monitoring = true
	_health.reset()
	if _body_mat != null:
		_body_mat.albedo_color = _base_color
	if _head_mat != null:
		_head_mat.albedo_color = _base_color


func _trigger_hitstop() -> void:
	if _hitstop_active:
		return
	_hitstop_active = true
	Engine.time_scale = 0.05
	var timer := get_tree().create_timer(0.06, true, false, true)
	timer.timeout.connect(_end_hitstop)


func _end_hitstop() -> void:
	Engine.time_scale = 1.0
	_hitstop_active = false


func _play_hit_fx() -> void:
	if _hit_fx == null:
		return
	var pos := global_position + Vector3(0, 1.0, 0)
	var source := _health.last_hit_source
	if source is Node3D and is_instance_valid(source):
		var dir: Vector3 = global_position - (source as Node3D).global_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			pos = global_position + dir.normalized() * 0.62 + Vector3(0, 0.95, 0)
	_hit_fx.global_position = pos
	_hit_fx.restart()


func _exit_tree() -> void:
	Engine.time_scale = 1.0
