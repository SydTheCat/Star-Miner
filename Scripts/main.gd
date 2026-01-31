extends Node3D

const PLAYER_SCENE := preload("res://Scenes/player.tscn")
const VOXEL_WORLD_SCENE := preload("res://World/VoxelWorld.tscn")
const BlockTypes = preload("res://Data/BlockTypes.gd")

var player: CharacterBody3D
var voxel_world: Node3D
var camera: Camera3D

# Debug UI elements.
var debug_label: Label

# Block interaction.
const REACH_DISTANCE := 5.0
var target_block_pos: Vector3i
var target_normal: Vector3
var has_target: bool = false
var selected_block: int = BlockTypes.BLOCK_DIRT

# Day/night cycle.
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
var sky_material: ProceduralSkyMaterial
var time_of_day: float = 0.3  # 0.0 = midnight, 0.5 = noon, 1.0 = midnight again
var day_length: float = 480.0  # Seconds for a full day cycle (8 minutes)

# Clouds.
var cloud_mesh: MeshInstance3D
var cloud_material: ShaderMaterial


func _ready() -> void:
	print("Main scene ready.")

	# Make environment, sky, and material unique so we can modify them at runtime.
	var env: Environment = world_env.environment.duplicate() as Environment
	world_env.environment = env
	if env.sky:
		var sky: Sky = env.sky.duplicate() as Sky
		env.sky = sky
		if sky.sky_material:
			sky_material = sky.sky_material.duplicate() as ProceduralSkyMaterial
			sky.sky_material = sky_material
			print("Sky material initialized: ", sky_material)

	# Create voxel world.
	voxel_world = VOXEL_WORLD_SCENE.instantiate()
	add_child(voxel_world)

	# Create player.
	player = PLAYER_SCENE.instantiate()
	add_child(player)

	# Spawn player above terrain (noise height ~20, so spawn at 40 to be safe).
	player.global_transform.origin = Vector3(8.0, 40.0, 8.0)

	# Tell VoxelWorld about the player so it can stream chunks around them.
	voxel_world.player = player
	
	# Get camera reference for raycasting.
	camera = player.get_node("Head/Camera3D")

	# Create debug UI.
	_create_debug_ui()
	
	# Create cloud layer.
	_create_clouds()


func _create_clouds() -> void:
	cloud_mesh = MeshInstance3D.new()
	cloud_mesh.name = "Clouds"
	add_child(cloud_mesh)
	
	# Create a large plane for clouds.
	var plane := PlaneMesh.new()
	plane.size = Vector2(500, 500)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1
	cloud_mesh.mesh = plane
	
	# Create cloud shader material.
	cloud_material = ShaderMaterial.new()
	var shader := load("res://Shaders/clouds.gdshader") as Shader
	cloud_material.shader = shader
	cloud_material.set_shader_parameter("cloud_speed", 0.005)
	cloud_material.set_shader_parameter("cloud_scale", 20.0)
	cloud_material.set_shader_parameter("cloud_coverage", 0.45)
	cloud_material.set_shader_parameter("cloud_softness", 0.25)
	cloud_material.set_shader_parameter("cloud_color", Color(1.0, 1.0, 1.0, 0.85))
	cloud_mesh.material_override = cloud_material
	
	# Position clouds high in sky.
	cloud_mesh.position.y = 80.0
	
	# Disable shadows from clouds.
	cloud_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _create_debug_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "DebugUI"
	add_child(canvas)

	debug_label = Label.new()
	debug_label.name = "DebugLabel"
	debug_label.position = Vector2(10, 10)
	debug_label.add_theme_font_size_override("font_size", 16)
	debug_label.add_theme_color_override("font_color", Color.WHITE)
	debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	debug_label.add_theme_constant_override("shadow_offset_x", 1)
	debug_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(debug_label)


func _process(delta: float) -> void:
	_update_day_night_cycle(delta)
	_update_debug_ui()
	_update_target_block()
	_update_clouds()


func _update_day_night_cycle(delta: float) -> void:
	# Advance time.
	time_of_day += delta / day_length
	if time_of_day >= 1.0:
		time_of_day -= 1.0

	# Calculate hour of day (0-24). time_of_day 0.0 = 6:00 AM.
	var hour: float = fmod(time_of_day * 24.0 + 6.0, 24.0)

	# Sunrise at 6:00, sunset at 21:00.
	const SUNRISE_HOUR := 6.0
	const SUNSET_HOUR := 21.0
	const DAY_DURATION := SUNSET_HOUR - SUNRISE_HOUR  # 15 hours
	const NIGHT_DURATION := 24.0 - DAY_DURATION  # 9 hours

	var sun_height: float
	var sun_angle: float

	if hour >= SUNRISE_HOUR and hour < SUNSET_HOUR:
		# Daytime: sun rises from 0 to 1 (noon) back to 0.
		var day_progress: float = (hour - SUNRISE_HOUR) / DAY_DURATION
		sun_height = sin(day_progress * PI)
		sun_angle = day_progress * PI  # 0 at sunrise, PI at sunset
	else:
		# Nighttime: sun goes below horizon.
		var night_progress: float
		if hour >= SUNSET_HOUR:
			night_progress = (hour - SUNSET_HOUR) / NIGHT_DURATION
		else:
			night_progress = (hour + 24.0 - SUNSET_HOUR) / NIGHT_DURATION
		sun_height = -sin(night_progress * PI)  # Goes from 0 to -1 to 0
		sun_angle = PI + night_progress * PI  # PI at sunset, 2*PI at sunrise

	# Rotate sun around X axis.
	sun.rotation = Vector3(-sun_angle + PI / 2.0, 0, 0)

	# Adjust sun energy and visibility based on height.
	if sun_height > -0.1:
		sun.light_energy = clampf(sun_height + 0.1, 0.0, 1.0) * 1.2
		sun.visible = true
	else:
		sun.light_energy = 0.0
		sun.visible = false

	# Adjust sun color (warmer at sunrise/sunset).
	var horizon_factor: float = 1.0 - clampf(sun_height, 0.0, 1.0)
	sun.light_color = Color(1.0, 0.9 - 0.2 * horizon_factor, 0.8 - 0.4 * horizon_factor)

	# Update environment and sky.
	var env: Environment = world_env.environment
	if env == null:
		return

	# Ambient light: darker at night.
	var ambient: float = clampf(sun_height + 0.3, 0.05, 0.5)
	env.ambient_light_energy = ambient

	# Update sky colors based on time.
	if sky_material == null:
		return

	# Daytime vs nighttime sky colors.
	# sun_height: -1 at midnight, +1 at noon
	var day_factor: float = clampf((sun_height + 1.0) / 2.0, 0.0, 1.0)  # 0 at midnight, 1 at noon

	# Sky top: blue during day, nearly black at night.
	var night_top := Color(0.01, 0.01, 0.03)
	var day_top := Color(0.3, 0.5, 0.9)
	sky_material.sky_top_color = night_top.lerp(day_top, day_factor)

	# Sky horizon: orange at sunrise/sunset, light blue during day, dark at night.
	var sunset_factor: float = clampf(1.0 - abs(sun_height) * 2.0, 0.0, 1.0) * clampf(sun_height + 0.3, 0.0, 1.0)
	var horizon_day := Color(0.7, 0.8, 0.95)
	var horizon_sunset := Color(1.0, 0.4, 0.1)
	var horizon_night := Color(0.02, 0.02, 0.05)
	sky_material.sky_horizon_color = horizon_night.lerp(horizon_day, day_factor).lerp(horizon_sunset, sunset_factor)

	# Ground colors.
	sky_material.ground_horizon_color = Color(0.02, 0.02, 0.02).lerp(Color(0.4, 0.35, 0.3), day_factor)
	sky_material.ground_bottom_color = Color(0.01, 0.01, 0.01).lerp(Color(0.15, 0.12, 0.1), day_factor)

	# Update fog color to match sky horizon (prevents visible line at horizon).
	var fog_night := Color(0.02, 0.02, 0.05)
	var fog_day := Color(0.7, 0.75, 0.85)
	var fog_sunset := Color(0.8, 0.5, 0.3)
	var fog_color: Color = fog_night.lerp(fog_day, day_factor).lerp(fog_sunset, sunset_factor)
	env.fog_light_color = fog_color
	env.fog_light_energy = lerp(0.1, 1.0, day_factor)


func _update_debug_ui() -> void:
	if debug_label == null or player == null or voxel_world == null:
		return

	var pos := player.global_transform.origin
	var chunk_x := floori(pos.x / 16.0)
	var chunk_z := floori(pos.z / 16.0)

	# Convert time_of_day to hours (0.0 = 6:00 AM sunrise, 0.5 = 6:00 PM sunset).
	var hours: int = int(fmod(time_of_day * 24.0 + 6.0, 24.0))
	var minutes: int = int(fmod(time_of_day * 24.0 * 60.0, 60.0))
	var time_str: String = "%02d:%02d" % [hours, minutes]

	debug_label.text = (
		"Seed: %d\n" % voxel_world.get_world_seed() +
		"Time: %s\n" % time_str +
		"Player: (%.1f, %.1f, %.1f)\n" % [pos.x, pos.y, pos.z] +
		"Chunk: (%d, %d)\n" % [chunk_x, chunk_z] +
		"Chunks loaded: %d\n" % voxel_world.get_chunk_count() +
		"[R] Regenerate world"
	)


func _update_clouds() -> void:
	if cloud_mesh == null or player == null or cloud_material == null:
		return
	
	# Follow player horizontally.
	cloud_mesh.position.x = player.global_position.x
	cloud_mesh.position.z = player.global_position.z
	
	# Tint clouds based on time of day.
	var hour: float = fmod(time_of_day * 24.0 + 6.0, 24.0)
	var cloud_tint := Color(1.0, 1.0, 1.0, 0.85)
	
	if hour >= 6.0 and hour < 8.0:
		# Sunrise - orange tint.
		var t := (hour - 6.0) / 2.0
		cloud_tint = Color(1.0, 0.85 + 0.15 * t, 0.7 + 0.3 * t, 0.85)
	elif hour >= 18.0 and hour < 20.0:
		# Sunset - orange/pink tint.
		var t := (hour - 18.0) / 2.0
		cloud_tint = Color(1.0, 0.85 - 0.1 * t, 0.7 - 0.1 * t, 0.85)
	elif hour >= 20.0 or hour < 6.0:
		# Night - darker, less visible.
		cloud_tint = Color(0.3, 0.3, 0.4, 0.4)
	
	cloud_material.set_shader_parameter("cloud_color", cloud_tint)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("regenerate_world"):
		var new_seed := randi()
		voxel_world.regenerate_world(new_seed)
		# Teleport player back to spawn height.
		player.global_transform.origin = Vector3(8.0, 40.0, 8.0)
		player.velocity = Vector3.ZERO
	
	# Block interaction (only when mouse captured).
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and has_target:
		if event.is_action_pressed("break_block"):
			_break_block()
		elif event.is_action_pressed("place_block"):
			_place_block()


func _update_target_block() -> void:
	has_target = false
	
	if camera == null or voxel_world == null:
		return
	
	var space_state := camera.get_world_3d().direct_space_state
	if space_state == null:
		return
	
	var from := camera.global_position
	var to := from + (-camera.global_transform.basis.z) * REACH_DISTANCE
	
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	
	var result := space_state.intersect_ray(query)
	
	if result.is_empty():
		return
	
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	
	# Step into the block slightly to get the correct block position.
	var inside_block := hit_pos - hit_normal * 0.5
	target_block_pos = Vector3i(floori(inside_block.x), floori(inside_block.y), floori(inside_block.z))
	target_normal = hit_normal
	has_target = true


func _break_block() -> void:
	if voxel_world == null:
		return
	voxel_world.set_block_global(target_block_pos.x, target_block_pos.y, target_block_pos.z, BlockTypes.BLOCK_AIR)


func _place_block() -> void:
	if voxel_world == null:
		return
	
	var place_pos := target_block_pos + Vector3i(
		int(round(target_normal.x)),
		int(round(target_normal.y)),
		int(round(target_normal.z))
	)
	
	# Don't place inside player.
	var cam_pos := camera.global_position
	var dx := absf(cam_pos.x - (float(place_pos.x) + 0.5))
	var dy := absf(cam_pos.y - (float(place_pos.y) + 0.5))
	var dz := absf(cam_pos.z - (float(place_pos.z) + 0.5))
	if dx < 0.8 and dz < 0.8 and dy < 1.8:
		return
	
	voxel_world.set_block_global(place_pos.x, place_pos.y, place_pos.z, selected_block)
