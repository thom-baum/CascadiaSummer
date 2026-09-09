@tool
extends Node3D
## Temporary editor probe: prints the imported animation names of UAL1/UAL2
## and the node/bone structure of the Superhero Male base so the animation
## layer can be mapped by discovered names. Tool scripts run _ready in the
## editor when this scene is opened; output lands in the editor Output.

func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	print("=== ANIM_PROBE_BEGIN ===")
	_dump_animations("res://assets/Universal Animation Library[Standard]/Unreal-Godot/UAL1_Standard.glb", "UAL1")
	_dump_animations("res://assets/Universal Animation Library 2[Standard]/Unreal-Godot/UAL2_Standard.glb", "UAL2")
	_dump_character("res://assets/Universal Base Characters[Standard]/Base Characters/Godot - UE/Superhero_Male_FullBody.gltf")
	print("=== ANIM_PROBE_END ===")


func _dump_animations(path: String, label: String) -> void:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		print(label, ": LOAD FAILED ", path)
		return
	var root := packed.instantiate()
	if root == null:
		print(label, ": INSTANTIATE FAILED")
		return
	print(label, ": ROOT=", root.name, " CLASS=", root.get_class())
	var player := _find_animation_player(root)
	if player == null:
		print(label, ": NO AnimationPlayer found")
		root.free()
		return
	var names := player.get_animation_list()
	print(label, ": ANIMATION_COUNT=", names.size())
	for name in names:
		print(label, ": CLIP [", name, "]")
	root.free()


func _dump_character(path: String) -> void:
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		print("CHARACTER: LOAD FAILED ", path)
		return
	var root := packed.instantiate()
	if root == null:
		print("CHARACTER: INSTANTIATE FAILED")
		return
	print("CHARACTER: ROOT=", root.name, " CLASS=", root.get_class())
	_dump_tree(root, 0)
	var skeleton := _find_skeleton(root)
	if skeleton != null:
		var bones: PackedStringArray = skeleton.get_bones()
		print("CHARACTER: BONE_COUNT=", bones.size())
		for bone in bones:
			print("CHARACTER: BONE [", bone, "]")
	root.free()


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _dump_tree(node: Node, depth: int) -> void:
	var pad := ""
	for i in depth:
		pad += "  "
	print("CHARACTER: TREE ", pad, node.name, " (", node.get_class(), ")")
	for child in node.get_children():
		_dump_tree(child, depth + 1)
