extends Node3D
## Authored official scene geometry plus optional live interaction-box outlines.

const TITLES := {2: "低箱跨越", 5: "高墙跨越", 10: "坐下 / 站起", 12: "低杆躲避"}
var metadata: Dictionary
var trigger_visible: bool = true
var _wire := ImmediateMesh.new()
var _wire_instance := MeshInstance3D.new()
var _wire_material := StandardMaterial3D.new()
var _entries_ready: bool = false
var _labels: Array[Label3D] = []


func show_station_labels(enabled: bool) -> void:
	for label: Label3D in _labels:
		label.visible = enabled


func configure(data: Dictionary) -> void:
	metadata = data
	for item: Dictionary in data["objects"]:
		var instance := MeshInstance3D.new()
		instance.name = item["name"]
		var mesh := BoxMesh.new()
		mesh.size = vector(item["size"])
		instance.mesh = mesh
		instance.transform = transform_from(item)
		var material := StandardMaterial3D.new()
		var color: Array = item["color"]
		material.albedo_color = Color(color[0], color[1], color[2])
		material.roughness = 0.8
		instance.material_override = material
		add_child(instance)
	for item: Dictionary in data["stations"]:
		var label := Label3D.new()
		label.text = "%d  %s\n%s" % [int(item["number"]), item["name"], item["english"]]
		label.position = vector(item["position"]) + Vector3(0, 2.9, 0)
		label.font_size = 42
		label.pixel_size = 0.006
		label.outline_size = 8
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.visible = false
		add_child(label)
		_labels.append(label)
	_wire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wire_material.vertex_color_use_as_albedo = true
	_wire_material.no_depth_test = true
	_wire_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wire_instance.mesh = _wire
	_wire_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_wire_instance)


static func vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])


static func transform_from(item: Dictionary) -> Transform3D:
	var q: Array = item["rotation"]
	return Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized()), vector(item["position"]))


func update_status(status: Dictionary) -> void:
	_wire_instance.visible = trigger_visible
	if not _entries_ready and status.has("entries"):
		_make_entries(status["entries"])
		_entries_ready = true
	if not trigger_visible or not status.has("boxes"):
		return
	_wire.clear_surfaces()
	if status["boxes"].is_empty():
		return
	_wire.surface_begin(Mesh.PRIMITIVE_LINES, _wire_material)
	for item: Dictionary in status["boxes"]:
		var half_size := vector(item["size"]) * 0.5
		var placement := transform_from(item)
		var vertices: Array[Vector3] = []
		for x: int in [-1, 1]:
			for y: int in [-1, 1]:
				for z: int in [-1, 1]:
					vertices.append(placement * (half_size * Vector3(x, y, z)))
		var color := Color(0.95, 0.25, 0.65, 0.8)
		if int(status.get("active", 0)) == int(item["id"]):
			color = Color(1.0, 0.7, 0.2, 0.95)
		elif int(status.get("near", 0)) == int(item["id"]):
			color = Color(0.6, 1.0, 0.3, 0.95)
		for index: int in range(8):
			for bit: int in [1, 2, 4]:
				var neighbor := index ^ bit
				if index < neighbor:
					_wire.surface_set_color(color)
					_wire.surface_add_vertex(vertices[index])
					_wire.surface_set_color(color)
					_wire.surface_add_vertex(vertices[neighbor])
	_wire.surface_end()


func _make_entries(entries: Array) -> void:
	var mesh := ImmediateMesh.new()
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("b6f260")
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for item: Dictionary in entries:
		var start := vector(item["position"])
		start.y = 0.025
		var forward := vector(item["facing"]).normalized()
		var right := forward.cross(Vector3.UP).normalized()
		var tip := start + forward * 1.1
		for segment: Vector3 in [start, tip, tip, tip - forward * 0.25 + right * 0.2,
				tip, tip - forward * 0.25 - right * 0.2]:
			mesh.surface_add_vertex(segment)
	mesh.surface_end()
	add_child(instance)
