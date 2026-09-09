extends SceneTree

func _initialize() -> void:
	inspect_scene("TARGET", "res://_retarget_test/low_poly_humanoid.glb")
	inspect_scene("SOURCE", "res://_retarget_test/zombie_idle.glb")
	quit()

func inspect_scene(label: String, path: String) -> void:
	var packed := load(path) as PackedScene
	if packed == null:
		print(label + " LOAD_FAILED " + path)
		return
	var root := packed.instantiate()
	print(label + " ROOT=" + root.name)
	var skeletons := find_nodes(root, Skeleton3D)
	print(label + " SKELETON_COUNT=" + str(skeletons.size()))
	for skeleton: Skeleton3D in skeletons:
		print(label + " SKELETON path=" + str(root.get_path_to(skeleton)) + " bones=" + str(skeleton.get_bone_count()))
		for i in skeleton.get_bone_count():
			print(label + " BONE " + str(i) + " name=" + str(skeleton.get_bone_name(i)) + " parent=" + str(skeleton.get_bone_parent(i)))
	var players := find_nodes(root, AnimationPlayer)
	print(label + " PLAYER_COUNT=" + str(players.size()))
	for player: AnimationPlayer in players:
		print(label + " ANIM_PLAYER path=" + str(root.get_path_to(player)))
		for animation_name in player.get_animation_list():
			var animation := player.get_animation(animation_name)
			print(label + " ANIM name=" + str(animation_name) + " length=" + str(animation.length) + " tracks=" + str(animation.get_track_count()))
			for track in animation.get_track_count():
				print(label + " TRACK " + str(track) + " path=" + str(animation.track_get_path(track)))
	root.queue_free()

func find_nodes(root: Node, type: Variant) -> Array:
	var found: Array = []
	if is_instance_of(root, type):
		found.append(root)
	for child in root.get_children():
		found.append_array(find_nodes(child, type))
	return found
