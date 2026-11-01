extends Node3D
## Four actual conditioning poses. Coordinates are source-local, root in Y-up world.

const COLORS := [Color("59dcff"), Color("b999ff"), Color("ffbe72"), Color("ff83b7")]
var bone_count: int = 0
var pose_count: int = 0
var _parents := PackedInt32Array()
var _bones: MultiMeshInstance3D
var _joints: MultiMeshInstance3D


func configure(parents: Array) -> void:
	_parents = PackedInt32Array(parents)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	material.render_priority = 10
	var bone_mesh := CylinderMesh.new()
	bone_mesh.top_radius = 0.007
	bone_mesh.bottom_radius = 0.007
	bone_mesh.height = 1.0
	bone_mesh.radial_segments = 6
	bone_mesh.material = material
	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = 0.014
	joint_mesh.height = 0.028
	joint_mesh.radial_segments = 6
	joint_mesh.rings = 4
	joint_mesh.material = material
	_bones = _instances(bone_mesh)
	_joints = _instances(joint_mesh)
	add_child(_bones)
	add_child(_joints)


func _instances(mesh: Mesh) -> MultiMeshInstance3D:
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = MultiMesh.new()
	instance.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	instance.multimesh.use_colors = true
	instance.multimesh.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func show_targets(poses: PackedFloat32Array, count: int) -> void:
	pose_count = count
	bone_count = 0
	var joint_count := _parents.size()
	if poses.size() != count * joint_count * 7:
		clear()
		return
	var segments: Array[Transform3D] = []
	var colors: Array[Color] = []
	_joints.multimesh.instance_count = count * joint_count
	for frame: int in range(count):
		var world: Array[Transform3D] = []
		world.resize(joint_count)
		for joint: int in range(joint_count):
			var offset := (frame * joint_count + joint) * 7
			var position := Vector3(poses[offset], poses[offset + 1], poses[offset + 2])
			var rotation := Quaternion(poses[offset + 3], poses[offset + 4], poses[offset + 5], poses[offset + 6]).normalized()
			var local := Transform3D(Basis(rotation), position)
			var parent := _parents[joint]
			world[joint] = world[parent] * local if parent >= 0 else local
			var endpoint := world[joint].origin
			var instance_index := frame * joint_count + joint
			_joints.multimesh.set_instance_transform(instance_index, Transform3D(Basis.IDENTITY, endpoint))
			_joints.multimesh.set_instance_color(instance_index, COLORS[frame])
			if parent < 0:
				continue
			var start := world[parent].origin
			var distance := start.distance_to(endpoint)
			if distance < 0.003:
				continue
			var y := (endpoint - start) / distance
			var helper := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.98 else Vector3.UP
			var x := helper.cross(y).normalized()
			var z := x.cross(y).normalized()
			segments.append(Transform3D(Basis(x, y * distance, z), (start + endpoint) * 0.5))
			colors.append(COLORS[frame])
	bone_count = segments.size()
	_bones.multimesh.instance_count = bone_count
	for index: int in range(bone_count):
		_bones.multimesh.set_instance_transform(index, segments[index])
		_bones.multimesh.set_instance_color(index, colors[index])


func clear() -> void:
	bone_count = 0
	pose_count = 0
	if _bones != null:
		_bones.multimesh.instance_count = 0
		_joints.multimesh.instance_count = 0
