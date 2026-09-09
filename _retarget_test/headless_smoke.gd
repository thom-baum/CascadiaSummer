extends SceneTree

func _initialize() -> void:
	var file := FileAccess.open("res://_retarget_test/smoke_result.txt", FileAccess.WRITE)
	if file != null:
		file.store_string("RETARGET_SMOKE_OK")
		file.close()
	print("RETARGET_SMOKE_OK")
	quit()
