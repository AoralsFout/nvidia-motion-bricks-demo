extends SceneTree
## Run the saved, relocated scene through the normal interaction UI fixture.

func _initialize() -> void:
	call_deferred("_start")


func _start() -> void:
	if not FileAccess.file_exists("res://logs/editor-scene/edited.tscn"):
		push_error("Run tools/check_editor_scene.gd first")
		quit(1)
		return
	var actor = load("res://logs/editor-scene/edited.tscn").instantiate()
	actor._test_station = 2
	root.add_child(actor)
