extends Node3D
## One-shot green plasma burst + beam for the Cascadia Critical Attack.
## The player controller spawns this scene and calls setup(hand_world,
## chest_world): the burst fires at the raised hand and a thin green beam
## grows from the hand toward the enemy chest, then the whole effect cleans
## itself up.

@export var fx_lifetime: float = 1.1
@export var beam_lifetime: float = 0.32
## Seconds the beam takes to grow from the hand to the enemy chest, so the
## blast visibly travels instead of popping in fully formed.
@export var beam_grow_time: float = 0.12

var _burst: GPUParticles3D = null
var _beam: MeshInstance3D = null
var _beam_hidden: bool = false
var _beam_tween: Tween = null
var _delta: Vector3 = Vector3.ZERO


func _ready() -> void:
	_burst = get_node_or_null("Burst") as GPUParticles3D
	_beam = get_node_or_null("Beam") as MeshInstance3D
	var free_timer := get_tree().create_timer(fx_lifetime)
	free_timer.timeout.connect(queue_free)


## Places the burst at the hand and stretches the beam from hand to chest.
## Call after the node is inside the scene tree.
func setup(hand_world: Vector3, chest_world: Vector3) -> void:
	global_position = hand_world
	_delta = chest_world - hand_world
	if _burst != null:
		# The scene keeps the one-shot burst inert (emitting = false) until the
		# shoot moment arms it; without this the blast would never appear.
		_burst.emitting = true
		_burst.restart()
	if _beam == null:
		return
	var dist := _delta.length()
	if dist < 0.001:
		_beam.visible = false
		_beam_hidden = true
		return
	# Grow the beam from the hand to the chest so the plasma visibly travels.
	_apply_beam_progress(0.0)
	if _beam_tween != null and _beam_tween.is_valid():
		_beam_tween.kill()
	_beam_tween = create_tween()
	_beam_tween.tween_method(_apply_beam_progress, 0.0, 1.0, beam_grow_time)
	var hide_timer := get_tree().create_timer(beam_lifetime)
	hide_timer.timeout.connect(_hide_beam)


## Orients the beam along the hand -> chest delta and scales its length to
## `t` (0 = at the hand, 1 = full reach). CylinderMesh spans mesh Y in
## [-0.5, 0.5], so scaling the Y basis column to the grown length and centering
## at its midpoint spans exactly hand -> hand + delta * t.
func _apply_beam_progress(t: float) -> void:
	if _beam == null or _beam_hidden:
		return
	var dist := _delta.length()
	if dist < 0.001:
		return
	var dir := _delta / dist
	var side := dir.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	else:
		side = side.normalized()
	var up := side.cross(dir)
	var grown := dir * (dist * clampf(t, 0.0, 1.0))
	_beam.transform = Transform3D(Basis(side, grown, up), grown * 0.5)


func _hide_beam() -> void:
	if _beam == null or _beam_hidden:
		return
	_beam_hidden = true
	if _beam_tween != null and _beam_tween.is_valid():
		_beam_tween.kill()
	_beam.visible = false
