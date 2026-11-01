extends SceneTree
## Verify that Godot's GLB importer preserved the original local rig.

func _initialize() -> void:
	var scene := load("res://assets/soma/soma.glb") as PackedScene
	var model := scene.instantiate()
	root.add_child(model)
	var skeleton := find_skeleton(model)
	var rig: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/soma/rig.json"))
	var largest_error := 0.0
	var issues: Array[String] = []
	for i: int in range(rig["joints"].size()):
		var bone := skeleton.find_bone(rig["joints"][i])
		if bone < 0:
			issues.append("Missing joint: " + rig["joints"][i])
			continue
		var values: Array = rig["rest"][i]
		var position := Vector3(values[0], values[1], values[2])
		var rotation := Quaternion(values[3], values[4], values[5], values[6]).normalized()
		var imported := skeleton.get_bone_rest(bone)
		largest_error = maxf(largest_error, imported.origin.distance_to(position))
		largest_error = maxf(largest_error, imported.basis.get_rotation_quaternion().angle_to(rotation))
		var parent: int = rig["parents"][i]
		var actual_parent := skeleton.get_bone_parent(bone)
		if (parent < 0 and actual_parent >= 0) or (parent >= 0 and skeleton.get_bone_name(actual_parent) != rig["joints"][parent]):
			issues.append("Parent mismatch: " + rig["joints"][i])
	if largest_error > 0.001:
		issues.append("Rest transform error exceeds tolerance")
	var report := {"bones": skeleton.get_bone_count(), "max_rest_error": largest_error, "issues": issues}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://logs"))
	var output := FileAccess.open("res://logs/rig_verification.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	print("RIG_VERIFICATION ", JSON.stringify(report))
	model.queue_free()
	quit(0 if issues.is_empty() else 1)


func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child: Node in node.get_children():
		var found := find_skeleton(child)
		if found:
			return found
	return null
