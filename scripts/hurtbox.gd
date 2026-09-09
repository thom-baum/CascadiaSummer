class_name HurtboxArea
extends Area3D
## Hurtbox Area3D. Overlap with a melee hitbox is reported into the Health
## component at health_path using the canonical damage contract. Layer rules
## (a hitbox only ever overlaps the opposing hurtbox) keep friendlies safe.

@export var health_path: NodePath = ^"../Health"

@onready var health = get_node_or_null(health_path)


func _ready() -> void:
	area_entered.connect(_on_area_entered)


## Only an enemy strike may enter the deflect pathway. A strike is a hitbox
## whose owning body exposes notify_strike_deflected (enemy.gd) or carries
## the explicit "enemy_strike" marker group. The player's own AttackArea is a
## MeleeHitbox with get_damage too, but its owner (the weapon attach / player)
## exposes neither, so it can never be accepted as a deflect source. Layer
## routing already keeps the player's AttackArea (layer 8, mask 16) off the
## player's own Hurtbox (layer 4, mask 32); this gate is defense in depth.
func _is_enemy_strike(hitbox: Area3D) -> bool:
	var root := hitbox.get_parent()
	if root != null and root.has_method("notify_strike_deflected"):
		return true
	if hitbox.is_in_group("enemy_strike"):
		return true
	return root != null and root.is_in_group("enemy_strike")


func _on_area_entered(hitbox: Area3D) -> void:
	if health == null:
		return
	if hitbox == null or not hitbox.has_method("get_damage"):
		return
	var owner := get_parent()
	if _is_enemy_strike(hitbox) and owner != null and owner.has_method("on_deflect_opportunity"):
		var result: int = owner.on_deflect_opportunity(hitbox)
		if result == 2:
			# Perfect parry consumed the strike; no damage applies.
			return
		if result == 1:
			# Normal held block: the strike is interrupted but reduced damage
			# still lands through the owner's block multiplier.
			if owner.has_method("get_blocked_damage"):
				health.take_damage(owner.get_blocked_damage(hitbox.get_damage()), hitbox)
				return
	health.take_damage(hitbox.get_damage(), hitbox)
