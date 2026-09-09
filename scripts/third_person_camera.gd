class_name ThirdPersonCamera
extends Node3D
## Third-person orbit camera, attached to the Player/CameraYaw pivot.
## Milestone 1 behavior preserved: horizontal-only mouse orbit on this yaw
## node (CameraPitch keeps its fixed modest downward angle in the scene),
## roll always zero, mouse-delta orbit applied per event, plus mouse capture
## and the ui_cancel (Escape) release.
## Milestone 2: optional lock-on. set_lock_target() makes the yaw smoothly
## orbit until the target sits in front of the camera; clear_lock_target()
## returns full manual orbit control.

@export var mouse_sensitivity: float = 0.003
@export var spring_arm_path: NodePath = ^"CameraPitch/SpringArm3D"
@export var lock_turn_speed: float = 8.0

@onready var _spring_arm: SpringArm3D = get_node_or_null(spring_arm_path) as SpringArm3D
@onready var _player: CharacterBody3D = get_parent() as CharacterBody3D

var _yaw: float = 0.0
var _pending_yaw: float = 0.0
var _lock_target: Node3D = null


func _ready() -> void:
	if _spring_arm != null:
		_spring_arm.collision_mask = 1 # World only, never the player layer.
		_spring_arm.margin = 0.2
		if _player != null:
			_spring_arm.add_excluded_object(_player.get_rid())
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pending_yaw += -event.relative.x * mouse_sensitivity
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_lock_target(target: Node3D) -> void:
	_lock_target = target


func clear_lock_target() -> void:
	_lock_target = null


func has_lock_target() -> bool:
	return _lock_target != null and is_instance_valid(_lock_target)


func _physics_process(delta: float) -> void:
	if _pending_yaw != 0.0:
		_yaw += _pending_yaw
		_pending_yaw = 0.0
	if has_lock_target() and _player != null:
		var desired := _desired_yaw_to_target()
		_yaw = lerp_angle(_yaw, desired, 1.0 - exp(-lock_turn_speed * delta))
	rotation.y = _yaw


func _desired_yaw_to_target() -> float:
	var delta_v: Vector3 = (_lock_target as Node3D).global_position - _player.global_position
	return atan2(-delta_v.x, -delta_v.z)
