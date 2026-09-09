class_name Health
extends Node
## Canonical Cascadia health component.
## Contract: take_damage(amount, source) -> bool returns true when the damage
## was applied (owner alive, positive amount, and not negated by
## invulnerability). When the owner implements is_invulnerable() the component
## honors it so dodge iframes can gate incoming damage.

signal damaged(amount: int, current: int)
signal died

@export var max_health: int = 100

var current: int = 0
var last_hit_source: Node = null


func _ready() -> void:
	current = max_health


func take_damage(amount: int, source: Node = null) -> bool:
	if current <= 0 or amount <= 0:
		return false
	var owner := get_parent()
	if owner != null and owner.has_method("is_invulnerable") and owner.is_invulnerable():
		return false
	current = maxi(0, current - amount)
	last_hit_source = source
	damaged.emit(amount, current)
	if current == 0:
		died.emit()
	return true


func heal(amount: int) -> void:
	current = mini(max_health, current + amount)


func reset() -> void:
	current = max_health
	last_hit_source = null
