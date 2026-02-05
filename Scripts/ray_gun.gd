extends Node3D

# Simple ray gun held by the player.
# Creates a retro sci-fi style gun using basic meshes.

var is_equipped: bool = false
var is_firing: bool = false
var is_firing_alt: bool = false
var beam_particles: GPUParticles3D
var beam_light: OmniLight3D
var alt_particles: GPUParticles3D
var alt_light: OmniLight3D
var tip_position := Vector3(0, 0.01, -0.43)
var fire_sound: AudioStreamPlayer3D

# Animation variables.
var base_position := Vector3.ZERO
var anim_time: float = 0.0
var is_walking: bool = false

# Walk bob settings.
var bob_frequency: float = 10.0
var bob_amplitude_y: float = 0.02
var bob_amplitude_x: float = 0.01

# Idle sway settings.
var idle_frequency: float = 1.5
var idle_amplitude_y: float = 0.005
var idle_amplitude_x: float = 0.003
var idle_rotation_amplitude: float = 0.5

signal fired(from_global: Vector3, direction: Vector3)
signal fired_alt(from_global: Vector3, direction: Vector3)


func _ready() -> void:
	_create_gun_mesh()
	_create_beam_particles()
	_create_alt_particles()
	_create_fire_sound()
	base_position = position
	# Start unequipped.
	unequip()


func equip() -> void:
	is_equipped = true
	visible = true


func unequip() -> void:
	is_equipped = false
	visible = false
	if is_firing:
		_stop_firing()
	if is_firing_alt:
		_stop_firing_alt()


func _process(delta: float) -> void:
	if not is_equipped:
		return
	# Don't fire when mouse is not captured (inventory open, etc).
	var can_fire := Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	
	# Check for primary fire input (left mouse button).
	if can_fire and Input.is_action_pressed("break_block"):
		if not is_firing:
			_start_firing()
	else:
		if is_firing:
			_stop_firing()
	
	# Check for secondary fire input (right mouse button).
	if can_fire and Input.is_action_pressed("place_block"):
		if not is_firing_alt:
			_start_firing_alt()
	else:
		if is_firing_alt:
			_stop_firing_alt()
	
	# Update animation.
	_update_animation(delta)


func _update_animation(delta: float) -> void:
	anim_time += delta
	
	# Check if player is walking.
	var player := get_parent().get_parent().get_parent() as CharacterBody3D
	if player:
		var velocity := player.velocity
		velocity.y = 0  # Ignore vertical movement.
		is_walking = velocity.length() > 0.5
	
	var offset := Vector3.ZERO
	var rot_offset := Vector3.ZERO
	
	if is_walking:
		# Walking bob - faster, more pronounced.
		offset.y = sin(anim_time * bob_frequency) * bob_amplitude_y
		offset.x = cos(anim_time * bob_frequency * 0.5) * bob_amplitude_x
	else:
		# Idle sway - slow, subtle breathing motion.
		offset.y = sin(anim_time * idle_frequency) * idle_amplitude_y
		offset.x = sin(anim_time * idle_frequency * 0.7) * idle_amplitude_x
		rot_offset.z = sin(anim_time * idle_frequency * 0.5) * idle_rotation_amplitude
	
	# Apply animation.
	position = base_position + offset
	rotation_degrees.z = rot_offset.z


func _start_firing() -> void:
	is_firing = true
	beam_particles.emitting = true
	beam_light.visible = true
	if fire_sound and not fire_sound.playing:
		fire_sound.play()
	# Emit signal with global position and direction.
	var tip_global := global_transform * tip_position
	var direction := -global_transform.basis.z
	fired.emit(tip_global, direction)


func _stop_firing() -> void:
	is_firing = false
	beam_particles.emitting = false
	beam_light.visible = false
	if fire_sound and fire_sound.playing:
		fire_sound.stop()


func _start_firing_alt() -> void:
	is_firing_alt = true
	alt_particles.emitting = true
	alt_light.visible = true
	var tip_global := global_transform * tip_position
	var direction := -global_transform.basis.z
	fired_alt.emit(tip_global, direction)


func _stop_firing_alt() -> void:
	is_firing_alt = false
	alt_particles.emitting = false
	alt_light.visible = false


func _create_gun_mesh() -> void:
	# Load the Plasma Blaster model.
	var gun_scene := load("res://Assets/Plasma_Blaster.glb") as PackedScene
	if gun_scene:
		var gun_model := gun_scene.instantiate()
		add_child(gun_model)
		# Adjust scale and rotation if needed.
		gun_model.scale = Vector3(0.3, 0.3, 0.3)
		gun_model.rotation_degrees.y = 270  # Point forward (180 + 90 left).
	else:
		push_error("Failed to load Plasma_Blaster.glb")


func _create_beam_particles() -> void:
	# Create GPU particles for the beam effect.
	beam_particles = GPUParticles3D.new()
	beam_particles.position = tip_position
	beam_particles.emitting = false
	beam_particles.amount = 100
	beam_particles.lifetime = 0.3
	beam_particles.explosiveness = 0.0
	beam_particles.fixed_fps = 60
	
	# Create particle material.
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, -1)
	mat.spread = 3.0
	mat.initial_velocity_min = 30.0
	mat.initial_velocity_max = 40.0
	mat.gravity = Vector3.ZERO
	mat.scale_min = 0.5
	mat.scale_max = 1.0
	
	# Color gradient - cyan to white.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.3, 0.9, 1.0, 1.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex
	
	# Emission shape - point.
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.02
	
	beam_particles.process_material = mat
	
	# Draw pass - small sphere.
	var draw_mesh := SphereMesh.new()
	draw_mesh.radius = 0.015
	draw_mesh.height = 0.03
	
	var draw_mat := StandardMaterial3D.new()
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.albedo_color = Color(0.5, 0.9, 1.0)
	draw_mat.emission_enabled = true
	draw_mat.emission = Color(0.3, 0.8, 1.0)
	draw_mat.emission_energy_multiplier = 3.0
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mesh.material = draw_mat
	
	beam_particles.draw_pass_1 = draw_mesh
	add_child(beam_particles)
	
	# Add light at the tip for glow effect.
	beam_light = OmniLight3D.new()
	beam_light.position = tip_position
	beam_light.light_color = Color(0.3, 0.8, 1.0)
	beam_light.light_energy = 2.0
	beam_light.omni_range = 3.0
	beam_light.visible = false
	add_child(beam_light)


func _create_alt_particles() -> void:
	# Create GPU particles for secondary fire - orange plasma burst.
	alt_particles = GPUParticles3D.new()
	alt_particles.position = tip_position
	alt_particles.emitting = false
	alt_particles.amount = 50
	alt_particles.lifetime = 0.5
	alt_particles.explosiveness = 0.8
	alt_particles.fixed_fps = 60
	
	# Create particle material.
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, -1)
	mat.spread = 15.0
	mat.initial_velocity_min = 15.0
	mat.initial_velocity_max = 25.0
	mat.gravity = Vector3(0, -2, 0)
	mat.scale_min = 0.8
	mat.scale_max = 1.5
	
	# Color gradient - orange to red.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 0.6, 0.1, 1.0))
	gradient.set_color(1, Color(1.0, 0.2, 0.0, 0.0))
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex
	
	# Emission shape.
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.03
	
	alt_particles.process_material = mat
	
	# Draw pass - small box for chunky plasma look.
	var draw_mesh := BoxMesh.new()
	draw_mesh.size = Vector3(0.04, 0.04, 0.06)
	
	var draw_mat := StandardMaterial3D.new()
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.albedo_color = Color(1.0, 0.5, 0.2)
	draw_mat.emission_enabled = true
	draw_mat.emission = Color(1.0, 0.4, 0.1)
	draw_mat.emission_energy_multiplier = 4.0
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mesh.material = draw_mat
	
	alt_particles.draw_pass_1 = draw_mesh
	add_child(alt_particles)
	
	# Add orange light for glow effect.
	alt_light = OmniLight3D.new()
	alt_light.position = tip_position
	alt_light.light_color = Color(1.0, 0.5, 0.1)
	alt_light.light_energy = 3.0
	alt_light.omni_range = 4.0
	alt_light.visible = false
	add_child(alt_light)


func _create_fire_sound() -> void:
	fire_sound = AudioStreamPlayer3D.new()
	fire_sound.stream = load("res://Assets/SoundFX/laser-weld.mp3")
	fire_sound.volume_db = 0.0
	fire_sound.max_distance = 20.0
	fire_sound.position = tip_position
	add_child(fire_sound)
