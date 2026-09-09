extends Node
## Temporary runtime probe: loads UAL1/UAL2 glb animation libraries, writes the
## exact imported clip names to a text file, then quits. Deleted after use.

const OUTPUT_PATH := "res://scenes/_anim_clips.txt"

func _ready() -> void:
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file == null:
		print("ANIM_LIST_PROBE FILE_OPEN_FAILED")
		get_tree().quit()
		return
	file.store_line("=== ANIM_LIST_PROBE_BEGIN ===")
	_dump(file, "res://assets/Universal Animation Library[Standard]/Unreal-Godot/UAL1_Standard.glb", "UAL1")
	_dump(file, "res://assets/Universal Animation Library 2[Standard]/Unreal-Godot/UAL2_Standard.glb", "UAL2")
	file.store_line("=== ANIM_LIST_PROBE_END ===")
	file.close()
	print("ANIM_LIST_PROBE_DONE")
	get_tree().quit()

func _dump(file: FileAccess, path: String, label: String) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		file.store_line(label + " LOAD_FAILED " + path)
		return
	var inst := packed.instantiate()
	var ap := _find_animation_player(inst)
	if ap == null:
		file.store_line(label + " NO_ANIMATION_PLAYER")
		inst.free()
		return
	var names := ap.get_animation_list()
	names.sort()
	file.store_line(label + " CLIP_COUNT=" + str(names.size()))
	for name in names:
		file.store_line(label + "|" + name)
	inst.free()

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null
