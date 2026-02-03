extends Node3D

const PLAYER_SCENE := preload("res://Scenes/player.tscn")
const VOXEL_WORLD_SCENE := preload("res://World/VoxelWorld.tscn")
const INVENTORY_UI_SCENE := preload("res://Scenes/inventory_ui.tscn")
const BLOCK_BREAK_PARTICLES_SCENE := preload("res://Scenes/block_break_particles.tscn")
const BlockTypes = preload("res://Data/BlockTypes.gd")

var player: CharacterBody3D
var voxel_world: Node3D
var camera: Camera3D
var hotbar: Control
var inventory_ui: Control

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
var sky_material: ShaderMaterial
var time_of_day: float = 0.3  # 0.0 = midnight, 0.5 = noon, 1.0 = midnight again
var day_length: float = 480.0  # Seconds for a full day cycle (8 minutes)

# Voxel Clouds.
var cloud_container: Node3D
var cloud_mesh_instance: MeshInstance3D
var cloud_material: StandardMaterial3D
var cloud_noise: FastNoiseLite
var last_cloud_center: Vector2i = Vector2i(-9999, -9999)
const CLOUD_HEIGHT := 60.0
const CLOUD_VOXEL_SIZE := 4.0  # Size of each cloud voxel
const CLOUD_RADIUS := 20  # Radius in cloud voxels
const CLOUD_UPDATE_DISTANCE := 32.0  # Rebuild clouds when player moves this far


func _ready() -> void:
	print("Main scene ready.")

	# Make environment unique and set up custom sky shader.
	var env: Environment = world_env.environment.duplicate() as Environment
	world_env.environment = env
	
	# Create custom sky with shader material.
	var sky := Sky.new()
	sky_material = ShaderMaterial.new()
	var sky_shader := load("res://Shaders/sky.gdshader") as Shader
	sky_material.shader = sky_shader
	
	# Set default sky parameters.
	sky_material.set_shader_parameter("sun_intensity", 22.0)
	sky_material.set_shader_parameter("sun_size", 0.04)
	sky_material.set_shader_parameter("atmosphere_density", 1.0)
	sky_material.set_shader_parameter("rayleigh_strength", 1.0)
	sky_material.set_shader_parameter("mie_strength", 0.005)
	sky_material.set_shader_parameter("star_intensity", 2.5)
	sky_material.set_shader_parameter("star_threshold", 0.97)
	
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	print("Custom sky shader initialized")

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
	
	# Connect to hotbar.
	hotbar = $Hotbar
	if hotbar:
		hotbar.slot_selected.connect(_on_hotbar_slot_selected)
		hotbar.item_dropped_to_hotbar.connect(_on_item_dropped_to_hotbar)
		# Sync player inventory reference with hotbar.
		hotbar.inventory = player.inventory
	
	# Create inventory UI.
	inventory_ui = INVENTORY_UI_SCENE.instantiate()
	add_child(inventory_ui)
	inventory_ui.set_player(player)
	inventory_ui.inventory_opened.connect(_on_inventory_opened)
	inventory_ui.inventory_closed.connect(_on_inventory_closed)
	
	# Create cloud layer.
	_create_clouds()


func _on_hotbar_slot_selected(_slot_index: int, block_id: int) -> void:
	selected_block = block_id


func _on_inventory_opened() -> void:
	# Pause game interactions while inventory is open.
	pass


func _on_inventory_closed() -> void:
	# Resume game interactions.
	# Refresh hotbar display to show current inventory counts.
	if hotbar:
		for i in range(hotbar.SLOT_COUNT):
			hotbar._update_slot_display(i)


func _on_item_dropped_to_hotbar(block_id: int, slot_index: int) -> void:
	# Item was dragged from inventory to hotbar slot.
	# The hotbar slot is now set to this block type.
	# Update the hotbar display.
	if hotbar:
		hotbar._update_slot_display(slot_index)


func _create_clouds() -> void:
	# Container for cloud mesh.
	cloud_container = Node3D.new()
	cloud_container.name = "VoxelClouds"
	add_child(cloud_container)
	
	# Cloud mesh instance.
	cloud_mesh_instance = MeshInstance3D.new()
	cloud_mesh_instance.name = "CloudMesh"
	cloud_container.add_child(cloud_mesh_instance)
	
	# Cloud material - semi-transparent white.
	cloud_material = StandardMaterial3D.new()
	cloud_material.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	cloud_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cloud_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cloud_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	cloud_mesh_instance.material_override = cloud_material
	cloud_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	# Noise for cloud generation.
	cloud_noise = FastNoiseLite.new()
	cloud_noise.seed = 42
	cloud_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cloud_noise.frequency = 0.02
	cloud_noise.fractal_octaves = 3
	cloud_noise.fractal_lacunarity = 2.0
	cloud_noise.fractal_gain = 0.5
	
	# Initial cloud generation.
	_rebuild_clouds()


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

	# Rotate sun light around X axis.
	sun.rotation = Vector3(-sun_angle + PI / 2.0, 0, 0)
	
	# Calculate sun direction vector for sky shader.
	# The DirectionalLight3D shines in -Z direction, so the sun's position in sky is +Z.
	var sun_dir := sun.global_transform.basis.z

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

	# Update sky shader parameters.
	if sky_material == null:
		return
	
	# Pass sun direction to sky shader.
	sky_material.set_shader_parameter("sun_direction", sun_dir)
	sky_material.set_shader_parameter("time_of_day", time_of_day)
	
	# Adjust atmosphere based on sun position for more dramatic sunsets.
	var sunset_factor: float = clampf(1.0 - abs(sun_height) * 2.0, 0.0, 1.0) * clampf(sun_height + 0.3, 0.0, 1.0)
	sky_material.set_shader_parameter("mie_strength", 0.005 + sunset_factor * 0.02)
	
	# Day factor for fog.
	var day_factor: float = clampf((sun_height + 1.0) / 2.0, 0.0, 1.0)

	# Update fog color to match sky.
	var fog_night := Color(0.02, 0.02, 0.05)
	var fog_day := Color(0.7, 0.75, 0.85)
	var fog_sunset := Color(0.8, 0.5, 0.3)
	var fog_color: Color = fog_night.lerp(fog_day, day_factor).lerp(fog_sunset, sunset_factor)
	env.fog_light_color = fog_color
	env.fog_light_energy = lerpf(0.1, 1.0, day_factor)


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

	# Build inventory string.
	var inv_str := ""
	if player.inventory.size() > 0:
		inv_str = "\nInventory: "
		for block_id in player.inventory.keys():
			var count: int = player.inventory[block_id]
			var name: String = BlockTypes.get_block_name(block_id)
			inv_str += "%s x%d  " % [name, count]
	
	debug_label.text = (
		"Seed: %d\n" % voxel_world.get_world_seed() +
		"Time: %s\n" % time_str +
		"Player: (%.1f, %.1f, %.1f)\n" % [pos.x, pos.y, pos.z] +
		"Chunk: (%d, %d)\n" % [chunk_x, chunk_z] +
		"Chunks loaded: %d\n" % voxel_world.get_chunk_count() +
		"[R] Regenerate world" +
		inv_str
	)


func _update_clouds() -> void:
	if cloud_container == null or player == null or cloud_material == null:
		return
	
	# Check if we need to rebuild clouds (player moved far enough).
	var player_pos := player.global_position
	var current_center := Vector2i(int(player_pos.x / CLOUD_UPDATE_DISTANCE), int(player_pos.z / CLOUD_UPDATE_DISTANCE))
	if current_center != last_cloud_center:
		last_cloud_center = current_center
		_rebuild_clouds()
	
	# Tint clouds based on time of day.
	var hour: float = fmod(time_of_day * 24.0 + 6.0, 24.0)
	var cloud_tint := Color(1.0, 1.0, 1.0, 0.9)
	
	if hour >= 6.0 and hour < 8.0:
		# Sunrise - orange tint.
		var t := (hour - 6.0) / 2.0
		cloud_tint = Color(1.0, 0.85 + 0.15 * t, 0.7 + 0.3 * t, 0.9)
	elif hour >= 18.0 and hour < 20.0:
		# Sunset - orange/pink tint.
		var t := (hour - 18.0) / 2.0
		cloud_tint = Color(1.0, 0.85 - 0.1 * t, 0.7 - 0.1 * t, 0.9)
	elif hour >= 20.0 or hour < 6.0:
		# Night - darker, less visible.
		cloud_tint = Color(0.4, 0.4, 0.5, 0.5)
	
	cloud_material.albedo_color = cloud_tint


func _rebuild_clouds() -> void:
	if player == null or cloud_noise == null:
		return
	
	var player_pos := player.global_position
	var center_x := snappedf(player_pos.x, CLOUD_VOXEL_SIZE)
	var center_z := snappedf(player_pos.z, CLOUD_VOXEL_SIZE)
	
	# Build cloud mesh using SurfaceTool.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Generate cloud voxels in a radius around player.
	for cx in range(-CLOUD_RADIUS, CLOUD_RADIUS + 1):
		for cz in range(-CLOUD_RADIUS, CLOUD_RADIUS + 1):
			# Skip corners for more circular shape.
			if cx * cx + cz * cz > CLOUD_RADIUS * CLOUD_RADIUS:
				continue
			
			var world_x := center_x + cx * CLOUD_VOXEL_SIZE
			var world_z := center_z + cz * CLOUD_VOXEL_SIZE
			
			# Sample noise to determine if cloud exists here.
			var noise_val := cloud_noise.get_noise_2d(world_x, world_z)
			
			# Only create cloud voxel if noise is above threshold.
			if noise_val > 0.1:
				# Vary height based on noise for puffy look.
				var height_variation := (noise_val - 0.1) * 3.0
				var num_layers := int(1 + height_variation * 2)
				
				for layer in num_layers:
					var y_offset := layer * CLOUD_VOXEL_SIZE * 0.7
					_add_cloud_voxel(st, world_x, CLOUD_HEIGHT + y_offset, world_z, CLOUD_VOXEL_SIZE)
	
	st.generate_normals()
	var mesh := st.commit()
	cloud_mesh_instance.mesh = mesh


func _add_cloud_voxel(st: SurfaceTool, x: float, y: float, z: float, size: float) -> void:
	# Add a cube at the given position.
	var half := size * 0.5
	
	# Define the 8 corners.
	var corners := [
		Vector3(x - half, y - half, z - half),  # 0: bottom-left-back
		Vector3(x + half, y - half, z - half),  # 1: bottom-right-back
		Vector3(x + half, y - half, z + half),  # 2: bottom-right-front
		Vector3(x - half, y - half, z + half),  # 3: bottom-left-front
		Vector3(x - half, y + half, z - half),  # 4: top-left-back
		Vector3(x + half, y + half, z - half),  # 5: top-right-back
		Vector3(x + half, y + half, z + half),  # 6: top-right-front
		Vector3(x - half, y + half, z + half),  # 7: top-left-front
	]
	
	# Top face (+Y).
	_add_quad(st, corners[4], corners[5], corners[6], corners[7], Vector3(0, 1, 0))
	# Bottom face (-Y).
	_add_quad(st, corners[3], corners[2], corners[1], corners[0], Vector3(0, -1, 0))
	# Front face (+Z).
	_add_quad(st, corners[3], corners[7], corners[6], corners[2], Vector3(0, 0, 1))
	# Back face (-Z).
	_add_quad(st, corners[1], corners[5], corners[4], corners[0], Vector3(0, 0, -1))
	# Right face (+X).
	_add_quad(st, corners[2], corners[6], corners[5], corners[1], Vector3(1, 0, 0))
	# Left face (-X).
	_add_quad(st, corners[0], corners[4], corners[7], corners[3], Vector3(-1, 0, 0))


func _add_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, normal: Vector3) -> void:
	st.set_normal(normal)
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	
	st.set_normal(normal)
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v3)


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
	
	# Get the block type before breaking.
	var block_id: int = voxel_world.get_block_global(target_block_pos.x, target_block_pos.y, target_block_pos.z)
	
	if block_id == BlockTypes.BLOCK_AIR:
		return
	
	# Spawn particle effect.
	_spawn_break_particles(Vector3(target_block_pos), block_id)
	
	# Set block to air.
	voxel_world.set_block_global(target_block_pos.x, target_block_pos.y, target_block_pos.z, BlockTypes.BLOCK_AIR)
	
	# Add to inventory.
	if hotbar:
		hotbar.add_block(block_id)


func _spawn_break_particles(pos: Vector3, block_id: int) -> void:
	var particles := BLOCK_BREAK_PARTICLES_SCENE.instantiate()
	add_child(particles)
	particles.setup(pos, _get_block_color(block_id), player)


func _get_block_color(block_id: int) -> Color:
	match block_id:
		BlockTypes.BLOCK_GRASS:
			return Color(0.42, 0.65, 0.31)  # Bright grass green.
		BlockTypes.BLOCK_DIRT:
			return Color(0.55, 0.36, 0.24)  # Earthy brown.
		BlockTypes.BLOCK_STONE:
			return Color(0.55, 0.55, 0.55)  # Medium gray.
		BlockTypes.BLOCK_WATER:
			return Color(0.2, 0.5, 0.9, 0.8)  # Transparent blue.
		BlockTypes.BLOCK_WOOD:
			return Color(0.45, 0.32, 0.18)  # Log bark brown.
		BlockTypes.BLOCK_LEAVES:
			return Color(0.25, 0.55, 0.18)  # Dark foliage green.
		_:
			return Color(0.6, 0.6, 0.6)  # Default gray.


func _place_block() -> void:
	if voxel_world == null:
		return
	
	# Check if we have blocks to place.
	if hotbar == null:
		return
	if not hotbar.can_place_block():
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
	
	# Remove from inventory and place the block.
	hotbar.remove_block(selected_block)
	voxel_world.set_block_global(place_pos.x, place_pos.y, place_pos.z, selected_block)
