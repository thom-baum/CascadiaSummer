extends SceneTree

const REPORT_PATH := "res://_retarget_test/inspection_report.txt"

func _initialize() -> void:
	write_line("INSPECTION_STARTED")
	inspect_scene("TARGET", "res://_retarget_test/low_poly_humanoid.glb")
	inspect_scene("SOURCE", "res://_retarget_test/zombie_idle.glb")
	write_line("INSPECTION_FINISHED")
	quit()

func write_line(message: String) -> void:
	var file := FileAccess.open(REPORT_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file != null:
		file.seek_end()
		file.store_line(message)
		file.close()

func inspect_scene(label: String, path: String) -> void:
	var packed := load(path) as PackedScene
	if packed == null:
		write_line(label + " LOAD_FAILED " + path)
		return
	var root := packed.instantiate()
	write_line(label + " ROOT=" + root.name)
	var skeletons: Array[Node] = []
	collect_skeletons(root, skeletons)
	write_line(label + " SKELETON_COUNT=" + str(skeletons.size()))
	for node in skeletons:
		var skeleton := node as Skeleton3D
		write_line(label + " SKELETON path=" + str(root.get_path_to(skeleton)) + " bones=" + str(skeleton.get_bone_count()))
		for i in range(skeleton.get_bone_count()):
			write_line(label + " BONE " + str(i) + " name=" + str(skeleton.get_bone_name(i)) + " parent=" + str(skeleton.get_bone_parent(i)))
	var players: Array[Node] = []
	collect_animation_players(root, players)
	write_line(label + " PLAYER_COUNT=" + str(players.size()))
	for node in players:
		var player := node as AnimationPlayer
		write_line(label + " ANIM_PLAYER path=" + str(root.get_path_to(player)))
		for animation_name in player.get_animation_list():
			var animation := player.get_animation(animation_name)
			write_line(label + " ANIM name=" + str(animation_name) + " length=" + str(animation.length) + " tracks=" + str(animation.get_track_count()))
			for track in range(animation.get_track_count()):
				write_line(label + " TRACK " + str(track) + " path=" + str(animation.track_get_path(track)))
	root.queue_free()

func collect_skeletons(node: Node, found: Array[Node]) -> void:
	if node is Skeleton3D:
		found.append(node)
	for child in node.get_children():
		collect_skeletons(child, found)

func collect_animation_players(node: Node, found: Array[Node]) -> void:
	if node is AnimationPlayer:
		found.append(node)
	for child in node.get_children():
		collect_animation_players(child, found)
