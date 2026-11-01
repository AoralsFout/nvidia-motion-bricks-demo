shader_type spatial;

varying vec3 world_position;

float grid_line(vec2 position, float width) {
	vec2 distance_to_line = abs(fract(position - 0.5) - 0.5);
	vec2 pixels = distance_to_line / max(fwidth(position), vec2(0.0001));
	vec2 footprint = fwidth(position);
	float lod_fade = 1.0 - smoothstep(0.2, 1.0, max(footprint.x, footprint.y));
	return (1.0 - smoothstep(width * 0.5, width * 0.5 + 1.0, min(pixels.x, pixels.y))) * lod_fade;
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 ground = world_position.xz;
	float fade = 1.0 - smoothstep(18.0, 65.0, distance(ground, CAMERA_POSITION_WORLD.xz));
	float minor_grid = grid_line(ground, 0.7) * fade;
	float major_grid = grid_line(ground / 5.0, 1.5) * fade;
	vec2 axis_pixels = abs(ground) / max(fwidth(ground), vec2(0.0001));
	float x_axis = (1.0 - smoothstep(0.8, 1.8, axis_pixels.y)) * fade;
	float z_axis = (1.0 - smoothstep(0.8, 1.8, axis_pixels.x)) * fade;
	ALBEDO = vec3(0.045, 0.06, 0.065);
	EMISSION = vec3(0.085, 0.13, 0.14) * minor_grid + vec3(0.14, 0.20, 0.21) * major_grid;
	EMISSION = mix(EMISSION, vec3(0.45, 0.08, 0.065), x_axis);
	EMISSION = mix(EMISSION, vec3(0.07, 0.20, 0.50), z_axis);
	ROUGHNESS = 0.96;
}
