class_name MeleeHitbox
extends Area3D
## Melee hitbox Area3D. Stays with a disabled CollisionShape3D in the scene;
## the player controller enables the shape only during the active window of a
## swing. The opposing hurtbox reads the current damage from get_damage() and
## routes it to its Health component.

signal swing_landed(target: Area3D)

var _damage: int = 0
var _hit_this_swing: Array[Area3D] = []

@onready var _shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	area_entered.connect(_on_area_entered)


func get_damage() -> int:
	return _damage


func begin_swing(damage: int) -> void:
	_damage = damage
	_hit_this_swing.clear()
	if _shape != null:
		_shape.disabled = false


func end_swing() -> void:
	if _shape != null:
		_shape.disabled = true
	_damage = 0
	_hit_this_swing.clear()


func _on_area_entered(area: Area3D) -> void:
	if _damage <= 0 or (_shape != null and _shape.disabled):
		return
	if _hit_this_swing.has(area):
		return
	_hit_this_swing.append(area)
	swing_landed.emit(area)
