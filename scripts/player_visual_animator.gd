extends Node3D
## Plays the placeholder character model's idle clip on ready so the rig never
## rests in its bind (T/A) pose. Owns no gameplay: the player controller keeps
## translation and facing; a later animation wiring pass drives walk/run/etc.
@export var character_root_path: NodePath = ^"DwarfVisual"

@onready var _character_root: Node = get_node_or_null(character_root_path)

func _ready() -> void:
	if _character_root == null:
		return
	var player := _find_animation_player(_character_root)
	if player == null:
		return
	var clip := _pick_idle_clip(player)
	if clip != "":
		player.play(clip)

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _pick_idle_clip(player: AnimationPlayer) -> String:
	var names := player.get_animation_list()
	if names.is_empty():
		return ""
	for name in names:
		if name.to_lower().contains("idle"):
			return name
	for name in names:
		var anim: Animation = player.get_animation(name)
		if anim != null and anim.loop_mode != Animation.LOOP_NONE:
			return name
	return names[0]
