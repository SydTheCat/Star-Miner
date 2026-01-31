extends Node3D

# Manages chunks in the world.
# Streams chunks around the player using FastNoiseLite for terrain.

const CHUNK_SCENE := preload("res://World/chunk.tscn")
const BlockTypes = preload("res://Data/BlockTypes.gd")

# Chunk size constants (must match Chunk.gd).
const CHUNK_SIZE_X := 16
const CHUNK_SIZE_Y := 64
const CHUNK_SIZE_Z := 16

# How many chunks to load around the player (in each horizontal direction).
@export var load_radius: int = 4
# How far before we unload a chunk.
@export var unload_radius: int = 6

# Map from chunk coordinate (Vector3i) -> Chunk node.
var chunks: Dictionary = {}

# Queue of chunk coordinates waiting to be created.
var chunk_queue: Array[Vector3i] = []

# Max chunks to create per frame (prevents freezing).
const MAX_CHUNKS_PER_FRAME := 2

# Deterministic world seed.
var world_seed: int = 12345

# Noise generator for terrain heightmap.
var noise: FastNoiseLite

# Reference to player (set by Main).
var player: Node3D = null


func _ready() -> void:
	_setup_noise()


func _setup_noise() -> void:
	noise = FastNoiseLite.new()
	noise.seed = world_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5


func _process(_delta: float) -> void:
	if player == null:
		return
	_update_chunks_around_player()
	_process_chunk_queue()


func _update_chunks_around_player() -> void:
	var player_chunk := _world_to_chunk_coords(player.global_transform.origin)

	# Queue chunks within load_radius (prioritize closest chunks).
	for cx in range(player_chunk.x - load_radius, player_chunk.x + load_radius + 1):
		for cz in range(player_chunk.z - load_radius, player_chunk.z + load_radius + 1):
			var coords := Vector3i(cx, 0, cz)
			if not chunks.has(coords) and coords not in chunk_queue:
				chunk_queue.append(coords)

	# Sort queue by distance to player (closest first).
	chunk_queue.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var dist_a := absi(a.x - player_chunk.x) + absi(a.z - player_chunk.z)
		var dist_b := absi(b.x - player_chunk.x) + absi(b.z - player_chunk.z)
		return dist_a < dist_b
	)

	# Unload chunks outside unload_radius.
	var to_remove: Array[Vector3i] = []
	for coords: Vector3i in chunks.keys():
		var dx := absi(coords.x - player_chunk.x)
		var dz := absi(coords.z - player_chunk.z)
		if dx > unload_radius or dz > unload_radius:
			to_remove.append(coords)

	for coords in to_remove:
		_remove_chunk(coords)
		# Also remove from queue if pending.
		var queue_idx := chunk_queue.find(coords)
		if queue_idx >= 0:
			chunk_queue.remove_at(queue_idx)


func _process_chunk_queue() -> void:
	# Create a limited number of chunks per frame.
	var created := 0
	while not chunk_queue.is_empty() and created < MAX_CHUNKS_PER_FRAME:
		var coords: Vector3i = chunk_queue.pop_front()
		# Double-check it wasn't already created.
		if not chunks.has(coords):
			_create_chunk(coords)
			created += 1


func _world_to_chunk_coords(world_pos: Vector3) -> Vector3i:
	# Convert world position to chunk coordinates.
	var cx := floori(world_pos.x / float(CHUNK_SIZE_X))
	var cz := floori(world_pos.z / float(CHUNK_SIZE_Z))
	return Vector3i(cx, 0, cz)


func _create_chunk(chunk_coords: Vector3i) -> void:
	if chunks.has(chunk_coords):
		return

	var chunk := CHUNK_SCENE.instantiate()
	add_child(chunk)

	chunk.chunk_coords = chunk_coords
	chunk.voxel_world = self

	var world_position := Vector3(
		float(chunk_coords.x * CHUNK_SIZE_X),
		0.0,
		float(chunk_coords.z * CHUNK_SIZE_Z)
	)
	chunk.global_transform.origin = world_position

	# Generate terrain into chunk using noise.
	_generate_terrain(chunk)

	# Build mesh + collision.
	chunk.update_mesh()

	chunks[chunk_coords] = chunk

	# Update neighboring chunks so their boundary faces are recalculated.
	_update_neighbor_meshes(chunk_coords)


func _update_neighbor_meshes(chunk_coords: Vector3i) -> void:
	# Rebuild meshes of the 4 horizontal neighbors (if they exist).
	var neighbors := [
		Vector3i(chunk_coords.x - 1, 0, chunk_coords.z),
		Vector3i(chunk_coords.x + 1, 0, chunk_coords.z),
		Vector3i(chunk_coords.x, 0, chunk_coords.z - 1),
		Vector3i(chunk_coords.x, 0, chunk_coords.z + 1),
	]
	for neighbor_coords in neighbors:
		if chunks.has(neighbor_coords):
			var neighbor: Node3D = chunks[neighbor_coords]
			neighbor.update_mesh()


func _remove_chunk(chunk_coords: Vector3i) -> void:
	if not chunks.has(chunk_coords):
		return
	var chunk: Node3D = chunks[chunk_coords]
	chunk.queue_free()
	chunks.erase(chunk_coords)


func _generate_terrain(chunk: Node3D) -> void:
	# Fill chunk voxels based on noise heightmap.
	var base_x: int = chunk.chunk_coords.x * CHUNK_SIZE_X
	var base_z: int = chunk.chunk_coords.z * CHUNK_SIZE_Z

	for lx in CHUNK_SIZE_X:
		for lz in CHUNK_SIZE_Z:
			var world_x: int = base_x + lx
			var world_z: int = base_z + lz

			# Sample noise to get height (range roughly -1 to 1, scale to usable height).
			var noise_val: float = noise.get_noise_2d(float(world_x), float(world_z))
			# Map noise to height: base height 20, variation +/- 15.
			var height: int = int(20.0 + noise_val * 15.0)
			height = clampi(height, 1, CHUNK_SIZE_Y - 1)

			for ly in CHUNK_SIZE_Y:
				var block_id: int = BlockTypes.BLOCK_AIR

				if ly < height - 4:
					# Deep = stone.
					block_id = BlockTypes.BLOCK_STONE
				elif ly < height - 1:
					# Below surface = dirt.
					block_id = BlockTypes.BLOCK_DIRT
				elif ly < height:
					# Surface = grass.
					block_id = BlockTypes.BLOCK_GRASS
				else:
					# Above surface = air.
					block_id = BlockTypes.BLOCK_AIR

				chunk.set_block(lx, ly, lz, block_id)


func regenerate_world(new_seed: int) -> void:
	# Remove all existing chunks.
	for coords: Vector3i in chunks.keys():
		var chunk: Node3D = chunks[coords]
		chunk.queue_free()
	chunks.clear()

	# Set new seed and reinitialize noise.
	world_seed = new_seed
	_setup_noise()

	# Chunks will be regenerated in _process via streaming.
	print("World regenerated with seed:", world_seed)


func get_chunk_count() -> int:
	return chunks.size()


func get_world_seed() -> int:
	return world_seed


func get_block_global(world_x: int, world_y: int, world_z: int) -> int:
	# Get block at world coordinates by finding the right chunk.
	if world_y < 0 or world_y >= CHUNK_SIZE_Y:
		return BlockTypes.BLOCK_AIR

	var chunk_x := floori(float(world_x) / float(CHUNK_SIZE_X))
	var chunk_z := floori(float(world_z) / float(CHUNK_SIZE_Z))
	var coords := Vector3i(chunk_x, 0, chunk_z)

	if not chunks.has(coords):
		# Chunk not loaded; treat as air (or could treat as solid to hide faces).
		return BlockTypes.BLOCK_AIR

	var chunk: Node3D = chunks[coords]

	# Convert world coords to local chunk coords.
	var local_x := world_x - chunk_x * CHUNK_SIZE_X
	var local_z := world_z - chunk_z * CHUNK_SIZE_Z

	return chunk.get_block(local_x, world_y, local_z)


func set_block_global(world_x: int, world_y: int, world_z: int, block_id: int) -> void:
	# Set block at world coordinates and update affected chunk meshes.
	if world_y < 0 or world_y >= CHUNK_SIZE_Y:
		return

	var chunk_x := floori(float(world_x) / float(CHUNK_SIZE_X))
	var chunk_z := floori(float(world_z) / float(CHUNK_SIZE_Z))
	var coords := Vector3i(chunk_x, 0, chunk_z)

	if not chunks.has(coords):
		return

	var chunk: Node3D = chunks[coords]

	# Convert world coords to local chunk coords.
	var local_x := world_x - chunk_x * CHUNK_SIZE_X
	var local_z := world_z - chunk_z * CHUNK_SIZE_Z

	# Set the block.
	chunk.set_block(local_x, world_y, local_z, block_id)

	# Rebuild this chunk's mesh.
	chunk.update_mesh()

	# If block is at chunk edge, also update neighbor chunk.
	if local_x == 0:
		_update_chunk_mesh_at(Vector3i(chunk_x - 1, 0, chunk_z))
	elif local_x == CHUNK_SIZE_X - 1:
		_update_chunk_mesh_at(Vector3i(chunk_x + 1, 0, chunk_z))
	if local_z == 0:
		_update_chunk_mesh_at(Vector3i(chunk_x, 0, chunk_z - 1))
	elif local_z == CHUNK_SIZE_Z - 1:
		_update_chunk_mesh_at(Vector3i(chunk_x, 0, chunk_z + 1))


func _update_chunk_mesh_at(coords: Vector3i) -> void:
	if chunks.has(coords):
		var chunk: Node3D = chunks[coords]
		chunk.update_mesh()
