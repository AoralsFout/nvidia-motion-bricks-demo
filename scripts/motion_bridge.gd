class_name MotionBridge
extends RefCounted
## Loopback protocol. Poses are absolute parent-local transforms in Y-up metres.

const PORT := 27841
var socket := PacketPeerUDP.new()
var received_frames: int = 0
var generation_count: int = 0
var inference_ms: float = 0.0
var generation_ms: float = 0.0
var response_ms: float = 0.0
var response_samples: Array[float] = []
var latest_pose := PackedFloat32Array()
var last_receive_ms: int = 0
var last_server_time: float = -1.0
var packet_interval: float = 1.0 / 60.0
var sequence: int = 0
var _pending: Dictionary = {}
var _direction := Vector3.FORWARD
var _speed: float = -1.0
var _reset: bool = false
var debug_targets_enabled: bool = false
var latest_targets := PackedFloat32Array()
var target_pose_count: int = 0
var target_generation: int = -1
var target_revision: int = 0
var received_target_packets: int = 0
var scene_status: Dictionary = {}
var scene_revision: int = 0
var auto_interact: bool = true
var debug_scene: bool = true
var _last_scene_time: float = -1.0
var _interact_sequence: int = 0
var _jump_sequence: int = 0
var _station_sequence: int = 0
var _station_id: int = 0


func open() -> Error:
	var result := socket.bind(0, "127.0.0.1")
	if result == OK:
		socket.set_dest_address("127.0.0.1", PORT)
	return result


func send_control(direction: Vector3, speed: float) -> void:
	if not direction.is_zero_approx():
		if not direction.is_equal_approx(_direction):
			_direction = direction
			_speed = -1.0
	if not is_equal_approx(speed, _speed) or _reset:
		sequence += 1
		_pending[sequence] = Time.get_ticks_usec()
		_speed = speed
		# Bound pending commands even when the backend is unavailable.
		for key: int in _pending.keys():
			if key < sequence - 120:
				_pending.erase(key)
	var command := {"direction": [_direction.x, _direction.y, _direction.z],
		"speed": speed, "seq": sequence, "reset": _reset, "debug_targets": debug_targets_enabled,
		"interact_seq": _interact_sequence, "station_seq": _station_sequence, "station_id": _station_id,
		"jump_seq": _jump_sequence,
		"auto_interact": auto_interact, "debug_scene": debug_scene}
	socket.put_packet(JSON.stringify(command).to_utf8_buffer())
	_reset = false


func poll(joint_count: int) -> bool:
	var updated := false
	while socket.get_available_packet_count() > 0:
		var packet := socket.get_packet()
		if packet.size() > 4 and packet.slice(0, 4).get_string_from_ascii() == "MBS1":
			var snapshot: Variant = JSON.parse_string(packet.slice(4).get_string_from_utf8())
			if snapshot is Dictionary and float(snapshot.get("time", -1.0)) > _last_scene_time:
				_last_scene_time = float(snapshot["time"])
				scene_status = snapshot
				scene_revision += 1
			continue
		if packet.size() >= 16 and packet.slice(0, 4).get_string_from_ascii() == "MBT1":
			_receive_targets(packet, joint_count)
			continue
		if packet.size() != 32 + joint_count * 28 or packet.slice(0, 4).get_string_from_ascii() != "MBP1":
			continue
		if packet.decode_u32(28) != joint_count:
			continue
		var server_time := packet.decode_double(8)
		if server_time <= last_server_time:
			continue
		var next_pose := packet.slice(32).to_float32_array()
		var valid := true
		for value: float in next_pose:
			if not is_finite(value):
				valid = false
				break
		if not valid:
			continue
		var now := Time.get_ticks_msec()
		if last_receive_ms > 0:
			packet_interval = clampf((now - last_receive_ms) / 1000.0, 0.008, 0.1)
		last_receive_ms = now
		last_server_time = server_time
		latest_pose = next_pose
		inference_ms = packet.decode_float(16)
		generation_ms = packet.decode_float(20)
		generation_count = packet.decode_u32(24)
		var acknowledged := packet.decode_u32(4)
		if _pending.has(acknowledged):
			response_ms = (Time.get_ticks_usec() - int(_pending[acknowledged])) / 1000.0
			response_samples.append(response_ms)
			_pending.erase(acknowledged)
		received_frames += 1
		updated = true
	return updated


func _receive_targets(packet: PackedByteArray, joint_count: int) -> void:
	if not debug_targets_enabled or packet.decode_u32(8) != joint_count:
		return
	var generation := packet.decode_u32(4)
	var count := packet.decode_u32(12)
	if count > 4 or packet.size() != 16 + count * joint_count * 28:
		return
	if generation < target_generation:
		return
	var poses := packet.slice(16).to_float32_array()
	for value: float in poses:
		if not is_finite(value):
			return
	received_target_packets += 1
	# The retransmission must not rebuild the same geometry every half second.
	if generation == target_generation and count == target_pose_count and poses == latest_targets:
		return
	latest_targets = poses
	target_pose_count = count
	target_generation = generation
	target_revision += 1


func clear_targets() -> void:
	latest_targets = PackedFloat32Array()
	target_pose_count = 0
	target_generation = -1
	target_revision += 1


func reset_character() -> void:
	_reset = true
	clear_targets()


func interact() -> void:
	_interact_sequence += 1
	_speed = -1.0


func jump() -> void:
	_jump_sequence += 1
	_speed = -1.0


func select_station(station_id: int) -> void:
	_station_id = station_id
	_station_sequence += 1
	_speed = -1.0
	clear_targets()


func is_live() -> bool:
	return last_receive_ms > 0 and Time.get_ticks_msec() - last_receive_ms < 500


func close(stop_backend: bool) -> void:
	if stop_backend:
		socket.put_packet(JSON.stringify({"direction": [0, 0, -1], "speed": 0, "seq": sequence,
			"quit": true}).to_utf8_buffer())
	socket.close()
