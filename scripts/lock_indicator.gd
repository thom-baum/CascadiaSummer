extends Node3D
## Cascadia milestone 5: quiet world-space lock-on marker. Polls the player
## controller's active lock target each frame and floats a small cold ring
## just above the target's head. Deliberately understated: a faint guide in
## the fog, not a HUD reticle. Hides when the lock clears or target leaves.

@export var player_path: NodePath = ^"../Player"
@export var hover_clearance: float = 0.34
@export var fallback_height: float = 2.1
@export var bob_amplitude: float = 0.04
@export var fade_in_time: float = 0.18
@export var fade_out_time: float = 0.24

var _player: Node = null
var _active: bool = false
var _tween: Tween = null


func _ready() -> void:
	_player = get_node_or_null(player_path)
	visible = false
	scale = Vector3.ONE * 0.45


func _process(delta: float) -> void:
	var target := _current_target()
	if target == null:
		if _active:
			_set_active(false)
		return
	if not _active:
		_set_active(true)
	var t := Time.get_ticks_msec() * 0.001
	var bob := sin(t * 1.7) * bob_amplitude
	global_position = target.global_position + Vector3(0.0, _head_height(target) + hover_clearance + bob, 0.0)


func _current_target() -> Node3D:
	if _player == null or not is_instance_valid(_player):
		return null
	var t = _player.get("_lock_target")
	if t is Node3D and is_instance_valid(t) and (t as Node3D).is_inside_tree():
		return t as Node3D
	return null


func _head_height(target: Node3D) -> float:
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
				return top
	return fallback_height


func _set_active(on: bool) -> void:
	_active = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	if on:
		visible = true
		_tween.tween_property(self, "scale", Vector3.ONE, fade_in_time)
	else:
		_tween.tween_property(self, "scale", Vector3.ONE * 0.4, fade_out_time)
		_tween.tween_callback(func() -> void: visible = false)
