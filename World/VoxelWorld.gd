extends Node3D

# Manages chunks in the world.
# Streams chunks around the player using FastNoiseLite for terrain.
# Uses threaded generation to prevent freezing.

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

# Chunks currently being generated in background threads.
var chunks_generating: Dictionary = {}  # Vector3i -> true

# Chunks ready to be finalized on main thread (terrain + mesh data ready).
# Each entry: {coords, blocks, vertices, normals, colors, indices}
var chunks_ready_queue: Array = []
var chunks_ready_mutex: Mutex = Mutex.new()

# Max chunks to START generating per frame.
const MAX_CHUNKS_TO_START_PER_FRAME := 4
# Max chunks to finalize (create mesh) per frame.
const MAX_CHUNKS_TO_FINALIZE_PER_FRAME := 3

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
	_start_chunk_generation()
	_finalize_ready_chunks()


func _update_chunks_around_player() -> void:
	var player_chunk := _world_to_chunk_coords(player.global_transform.origin)

	# Queue chunks within load_radius (prioritize closest chunks).
	for cx in range(player_chunk.x - load_radius, player_chunk.x + load_radius + 1):
		for cz in range(player_chunk.z - load_radius, player_chunk.z + load_radius + 1):
			var coords := Vector3i(cx, 0, cz)
			# Skip if already loaded, queued, or generating.
			if not chunks.has(coords) and coords not in chunk_queue and not chunks_generating.has(coords):
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


func _start_chunk_generation() -> void:
	# Start background generation for queued chunks.
	var started := 0
	while not chunk_queue.is_empty() and started < MAX_CHUNKS_TO_START_PER_FRAME:
		var coords: Vector3i = chunk_queue.pop_front()
		# Double-check it wasn't already created or is generating.
		if not chunks.has(coords) and not chunks_generating.has(coords):
			_start_chunk_generation_async(coords)
			started += 1


func _start_chunk_generation_async(chunk_coords: Vector3i) -> void:
	# Mark as generating.
	chunks_generating[chunk_coords] = true
	
	# Prepare data for the thread.
	var task_data := {
		"coords": chunk_coords,
		"seed": world_seed,
		"noise_frequency": noise.frequency,
		"noise_octaves": noise.fractal_octaves,
		"noise_lacunarity": noise.fractal_lacunarity,
		"noise_gain": noise.fractal_gain,
	}
	
	# Submit to worker thread pool.
	WorkerThreadPool.add_task(_generate_chunk_threaded.bind(task_data))


func _generate_chunk_threaded(task_data: Dictionary) -> void:
	# This runs on a background thread - NO Godot node access allowed!
	var coords: Vector3i = task_data["coords"]
	var seed_val: int = task_data["seed"]
	
	# Create a new noise generator for this thread (noise objects aren't thread-safe).
	var thread_noise := FastNoiseLite.new()
	thread_noise.seed = seed_val
	thread_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	thread_noise.frequency = task_data["noise_frequency"]
	thread_noise.fractal_octaves = task_data["noise_octaves"]
	thread_noise.fractal_lacunarity = task_data["noise_lacunarity"]
	thread_noise.fractal_gain = task_data["noise_gain"]
	
	# Generate terrain data.
	var blocks := _generate_terrain_data(coords, thread_noise)
	
	# Generate mesh data (vertex arrays) on this thread too.
	var mesh_data := _generate_mesh_data_threaded(blocks)
	
	# Queue result for main thread.
	var result := {
		"coords": coords,
		"blocks": blocks,
		"mesh_data": mesh_data,
	}
	
	chunks_ready_mutex.lock()
	chunks_ready_queue.append(result)
	chunks_ready_mutex.unlock()


func _generate_terrain_data(chunk_coords: Vector3i, thread_noise: FastNoiseLite) -> PackedInt32Array:
	# Generate block data for a chunk (runs on background thread).
	var total_blocks := CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z
	var blocks := PackedInt32Array()
	blocks.resize(total_blocks)
	
	var base_x: int = chunk_coords.x * CHUNK_SIZE_X
	var base_z: int = chunk_coords.z * CHUNK_SIZE_Z
	
	for lx in CHUNK_SIZE_X:
		for lz in CHUNK_SIZE_Z:
			var world_x: int = base_x + lx
			var world_z: int = base_z + lz
			
			# Sample noise to get height.
			var noise_val: float = thread_noise.get_noise_2d(float(world_x), float(world_z))
			var height: int = int(20.0 + noise_val * 5.0)
			height = clampi(height, 1, CHUNK_SIZE_Y - 1)
			
			for ly in CHUNK_SIZE_Y:
				var block_id: int = BlockTypes.BLOCK_AIR
				
				if ly < height - 4:
					block_id = BlockTypes.BLOCK_STONE
				elif ly < height - 1:
					block_id = BlockTypes.BLOCK_DIRT
				elif ly < height:
					block_id = BlockTypes.BLOCK_GRASS
				else:
					block_id = BlockTypes.BLOCK_AIR
				
				# Index: x + z * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z
				var index := lx + lz * CHUNK_SIZE_X + ly * CHUNK_SIZE_X * CHUNK_SIZE_Z
				blocks[index] = block_id
	
	return blocks


func _generate_mesh_data_threaded(blocks: PackedInt32Array) -> Dictionary:
	# Generate mesh vertex data on background thread.
	# Returns arrays that can be used to build ArrayMesh on main thread.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	
	var size_x := CHUNK_SIZE_X
	var size_y := CHUNK_SIZE_Y
	var size_z := CHUNK_SIZE_Z
	var size_xz := size_x * size_z
	
	for y in size_y:
		var y_offset := y * size_xz
		for z in size_z:
			var z_offset := z * size_x
			for x in size_x:
				var index := x + z_offset + y_offset
				var block_id: int = blocks[index]
				if block_id == BlockTypes.BLOCK_AIR:
					continue
				
				var color := _get_block_color(block_id)
				
				# Check neighbors and add faces.
				# -X
				if x == 0 or blocks[index - 1] == BlockTypes.BLOCK_AIR:
					_add_face_x_data(vertices, normals, colors, x, y, z, false, color)
				# +X
				if x == size_x - 1 or blocks[index + 1] == BlockTypes.BLOCK_AIR:
					_add_face_x_data(vertices, normals, colors, x, y, z, true, color)
				# -Y
				if y == 0 or blocks[index - size_xz] == BlockTypes.BLOCK_AIR:
					_add_face_y_data(vertices, normals, colors, x, y, z, false, color)
				# +Y
				if y == size_y - 1 or blocks[index + size_xz] == BlockTypes.BLOCK_AIR:
					_add_face_y_data(vertices, normals, colors, x, y, z, true, color)
				# -Z
				if z == 0 or blocks[index - size_x] == BlockTypes.BLOCK_AIR:
					_add_face_z_data(vertices, normals, colors, x, y, z, false, color)
				# +Z
				if z == size_z - 1 or blocks[index + size_x] == BlockTypes.BLOCK_AIR:
					_add_face_z_data(vertices, normals, colors, x, y, z, true, color)
	
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
	}


func _get_block_color(block_id: int) -> Color:
	match block_id:
		BlockTypes.BLOCK_GRASS:
			return Color(0.2, 0.8, 0.2)
		BlockTypes.BLOCK_DIRT:
			return Color(0.5, 0.3, 0.1)
		BlockTypes.BLOCK_STONE:
			return Color(0.5, 0.5, 0.5)
		BlockTypes.BLOCK_WATER:
			return Color(0.2, 0.4, 0.9, 0.7)
		_:
			return Color(1, 1, 1)


func _add_face_x_data(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, x: int, y: int, z: int, positive: bool, color: Color) -> void:
	var px := float(x)
	var py := float(y)
	var pz := float(z)
	
	if positive:
		var x0 := px + 1.0
		var v0 := Vector3(x0, py, pz)
		var v1 := Vector3(x0, py, pz + 1.0)
		var v2 := Vector3(x0, py + 1.0, pz + 1.0)
		var v3 := Vector3(x0, py + 1.0, pz)
		var normal := Vector3(1, 0, 0)
		_push_quad_data(vertices, normals, colors, v0, v1, v2, v3, normal, color)
	else:
		var x0 := px
		var v0 := Vector3(x0, py, pz + 1.0)
		var v1 := Vector3(x0, py, pz)
		var v2 := Vector3(x0, py + 1.0, pz)
		var v3 := Vector3(x0, py + 1.0, pz + 1.0)
		var normal := Vector3(-1, 0, 0)
		_push_quad_data(vertices, normals, colors, v0, v1, v2, v3, normal, color)


func _add_face_y_data(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, x: int, y: int, z: int, positive: bool, color: Color) -> void:
	var px := float(x)
	var py := float(y)
	var pz := float(z)
	
	if positive:
		var y0 := py + 1.0
		var v0 := Vector3(px, y0, pz)
		var v1 := Vector3(px + 1.0, y0, pz)
		var v2 := Vector3(px + 1.0, y0, pz + 1.0)
		var v3 := Vector3(px, y0, pz + 1.0)
		var normal := Vector3(0, 1, 0)
		_push_quad_data(vertices, normals, colors, v0, v1, v2, v3, normal, color)
	else:
		var y0 := py
		var v0 := Vector3(px, y0, pz + 1.0)
		var v1 := Vector3(px + 1.0, y0, pz + 1.0)
		var v2 := Vector3(px + 1.0, y0, pz)
		var v3 := Vector3(px, y0, pz)
		var normal := Vector3(0, -1, 0)
		_push_quad_data(vertices, normals, colors, v0, v1, v2, v3, normal, color)


func _add_face_z_data(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, x: int, y: int, z: int, positive: bool, color: Color) -> void:
	var px := float(x)
	var py := float(y)
	var pz := float(z)
	
	if positive:
		var z0 := pz + 1.0
		var v0 := Vector3(px, py, z0)
		var v1 := Vector3(px + 1.0, py, z0)
		var v2 := Vector3(px + 1.0, py + 1.0, z0)
		var v3 := Vector3(px, py + 1.0, z0)
		var normal := Vector3(0, 0, 1)
		_push_quad_data(vertices, normals, colors, v0, v1, v2, v3, normal, color)
	else:
		var z0 := pz
		var v0 := Vector3(px + 1.0, py, z0)
		var v1 := Vector3(px, py, z0)
		var v2 := Vector3(px, py + 1.0, z0)
		var v3 := Vector3(px + 1.0, py + 1.0, z0)
		var normal := Vector3(0, 0, -1)
		_push_quad_data(vertices, normals, colors, v0, v1, v2, v3, normal, color)


func _push_quad_data(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, normal: Vector3, color: Color) -> void:
	# Triangle 1: v0, v1, v2
	vertices.append(v0)
	vertices.append(v1)
	vertices.append(v2)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colors.append(color)
	colors.append(color)
	colors.append(color)
	
	# Triangle 2: v0, v2, v3
	vertices.append(v0)
	vertices.append(v2)
	vertices.append(v3)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colors.append(color)
	colors.append(color)
	colors.append(color)


func _finalize_ready_chunks() -> void:
	# Finalize chunks that have finished generating (main thread only).
	chunks_ready_mutex.lock()
	var ready_chunks := chunks_ready_queue.duplicate()
	chunks_ready_queue.clear()
	chunks_ready_mutex.unlock()
	
	var finalized := 0
	for result in ready_chunks:
		if finalized >= MAX_CHUNKS_TO_FINALIZE_PER_FRAME:
			# Put remaining back in queue for next frame.
			chunks_ready_mutex.lock()
			for i in range(ready_chunks.find(result), ready_chunks.size()):
				chunks_ready_queue.push_front(ready_chunks[i])
			chunks_ready_mutex.unlock()
			break
		
		var coords: Vector3i = result["coords"]
		var blocks: PackedInt32Array = result["blocks"]
		var mesh_data: Dictionary = result["mesh_data"]
		
		# Remove from generating set.
		chunks_generating.erase(coords)
		
		# Skip if chunk was unloaded while generating.
		if chunks.has(coords):
			continue
		
		# Check if player moved too far away.
		if player != null:
			var player_chunk := _world_to_chunk_coords(player.global_transform.origin)
			var dx := absi(coords.x - player_chunk.x)
			var dz := absi(coords.z - player_chunk.z)
			if dx > unload_radius or dz > unload_radius:
				continue  # Don't create chunk, player moved away.
		
		# Create and finalize the chunk.
		_finalize_chunk(coords, blocks, mesh_data)
		finalized += 1


func _finalize_chunk(chunk_coords: Vector3i, blocks: PackedInt32Array, mesh_data: Dictionary) -> void:
	# Create chunk node and assign pre-generated data (main thread).
	var chunk := CHUNK_SCENE.instantiate()
	add_child(chunk)
	
	chunk.chunk_coords = chunk_coords
	chunk.voxel_world = self
	chunk.blocks = blocks
	
	var world_position := Vector3(
		float(chunk_coords.x * CHUNK_SIZE_X),
		0.0,
		float(chunk_coords.z * CHUNK_SIZE_Z)
	)
	chunk.global_transform.origin = world_position
	
	# Apply pre-built mesh data (fast - just uploads to GPU).
	chunk.apply_mesh_data(mesh_data)
	
	chunks[chunk_coords] = chunk
	
	# Defer neighbor updates to spread load.
	call_deferred("_update_neighbor_meshes", chunk_coords)


func _world_to_chunk_coords(world_pos: Vector3) -> Vector3i:
	# Convert world position to chunk coordinates.
	var cx := floori(world_pos.x / float(CHUNK_SIZE_X))
	var cz := floori(world_pos.z / float(CHUNK_SIZE_Z))
	return Vector3i(cx, 0, cz)




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




func regenerate_world(new_seed: int) -> void:
	# Remove all existing chunks.
	for coords: Vector3i in chunks.keys():
		var chunk: Node3D = chunks[coords]
		chunk.queue_free()
	chunks.clear()
	
	# Clear generation state.
	chunk_queue.clear()
	chunks_generating.clear()
	chunks_ready_mutex.lock()
	chunks_ready_queue.clear()
	chunks_ready_mutex.unlock()

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
