extends Node3D

# Particle effect for block destruction - particles get sucked toward player.

@export var particle_count: int = 12
@export var initial_burst_speed: float = 3.0
@export var suction_delay: float = 0.15
@export var suction_speed: float = 8.0
@export var lifetime: float = 0.6

var player: Node3D = null
var block_color: Color = Color.WHITE
var particles: Array[MeshInstance3D] = []
var velocities: Array[Vector3] = []
var time_alive: float = 0.0


func _ready() -> void:
	pass


func setup(pos: Vector3, color: Color, player_ref: Node3D) -> void:
	global_position = pos + Vector3(0.5, 0.5, 0.5)
	block_color = color
	player = player_ref
	_spawn_particles()


func _spawn_particles() -> void:
	for i in particle_count:
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.12, 0.12, 0.12)
		mesh_instance.mesh = box
		
		var mat := StandardMaterial3D.new()
		mat.albedo_color = block_color
		mat.emission_enabled = true
		mat.emission = block_color * 0.3
		mesh_instance.material_override = mat
		
		add_child(mesh_instance)
		particles.append(mesh_instance)
		
		# Random initial position within block.
		mesh_instance.position = Vector3(
			randf_range(-0.3, 0.3),
			randf_range(-0.3, 0.3),
			randf_range(-0.3, 0.3)
		)
		
		# Random outward burst velocity.
		var dir := Vector3(
			randf_range(-1, 1),
			randf_range(0.2, 1),
			randf_range(-1, 1)
		).normalized()
		velocities.append(dir * initial_burst_speed * randf_range(0.7, 1.3))


func _process(delta: float) -> void:
	time_alive += delta
	
	if time_alive >= lifetime:
		queue_free()
		return
	
	var player_pos := player.global_position + Vector3(0, 0.8, 0) if player else global_position
	
	for i in particles.size():
		var particle := particles[i]
		var vel := velocities[i]
		
		if time_alive > suction_delay:
			# Attract toward player.
			var to_player := player_pos - particle.global_position
			var dist := to_player.length()
			if dist > 0.3:
				var suction_strength := suction_speed * (1.0 + (time_alive - suction_delay) * 3.0)
				vel = vel.lerp(to_player.normalized() * suction_strength, delta * 8.0)
				velocities[i] = vel
			else:
				# Close enough - hide and stop.
				particle.visible = false
				continue
		else:
			# Apply gravity during burst.
			vel.y -= 9.8 * delta
			velocities[i] = vel
		
		particle.position += vel * delta
		
		# Shrink as they approach end of life.
		var life_ratio := time_alive / lifetime
		var scale_factor := 1.0 - (life_ratio * 0.5)
		particle.scale = Vector3.ONE * scale_factor
