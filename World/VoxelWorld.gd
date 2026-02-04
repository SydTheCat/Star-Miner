extends Node3D

# Manages chunks in the world.
# Streams chunks around the player using FastNoiseLite for terrain.
# Uses threaded generation to prevent freezing.

const CHUNK_SCENE := preload("res://World/chunk.tscn")
const FALLING_BLOCK_SCENE := preload("res://Scenes/falling_block.tscn")
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

# Random world seed (generated on start).
var world_seed: int = randi()

# Noise generator for terrain heightmap.
var noise: FastNoiseLite

# Reference to player (set by Main).
var player: Node3D = null

# Tree fall sound.
var tree_fall_sound: AudioStreamPlayer

# Dirt to grass conversion tracking.
var dirt_blocks_timer: Dictionary = {}  # Vector3i -> float (time elapsed)
const DIRT_TO_GRASS_TIME := 10.0  # Seconds before dirt becomes grass
var dirt_update_timer: float = 0.0
const DIRT_UPDATE_INTERVAL := 0.5  # Only check every 0.5 seconds


func _ready() -> void:
	_setup_noise()
	_setup_sounds()
	set_process(true)


func _setup_noise() -> void:
	noise = FastNoiseLite.new()
	noise.seed = world_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5


func _setup_sounds() -> void:
	tree_fall_sound = AudioStreamPlayer.new()
	tree_fall_sound.stream = load("res://Assets/SoundFX/breaking-wood.mp3")
	tree_fall_sound.volume_db = 0.0
	add_child(tree_fall_sound)


func _process(delta: float) -> void:
	if player == null:
		return
	_update_chunks_around_player()
	_start_chunk_generation()
	_finalize_ready_chunks()
	_update_dirt_to_grass_conversion(delta)


func _update_dirt_to_grass_conversion(delta: float) -> void:
	# Only update every DIRT_UPDATE_INTERVAL seconds to avoid performance issues.
	dirt_update_timer += delta
	if dirt_update_timer < DIRT_UPDATE_INTERVAL:
		return
	
	var elapsed := dirt_update_timer
	dirt_update_timer = 0.0
	
	# Update timers for dirt blocks and convert to grass when ready.
	var blocks_to_convert: Array[Vector3i] = []
	
	for pos in dirt_blocks_timer.keys():
		dirt_blocks_timer[pos] += elapsed
		
		if dirt_blocks_timer[pos] >= DIRT_TO_GRASS_TIME:
			# Check if block is still dirt and has air above.
			var block := get_block_global(pos.x, pos.y, pos.z)
			if block == BlockTypes.BLOCK_DIRT:
				var above := get_block_global(pos.x, pos.y + 1, pos.z)
				if above == BlockTypes.BLOCK_AIR:
					blocks_to_convert.append(pos)
			else:
				# Block changed, remove from tracking.
				blocks_to_convert.append(pos)
	
	# Convert blocks and remove from tracking.
	for pos in blocks_to_convert:
		var block := get_block_global(pos.x, pos.y, pos.z)
		if block == BlockTypes.BLOCK_DIRT:
			set_block_global(pos.x, pos.y, pos.z, BlockTypes.BLOCK_GRASS)
		dirt_blocks_timer.erase(pos)


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
	
	# First pass: generate basic terrain.
	var heights := PackedInt32Array()
	heights.resize(CHUNK_SIZE_X * CHUNK_SIZE_Z)
	
	for lx in CHUNK_SIZE_X:
		for lz in CHUNK_SIZE_Z:
			var world_x: int = base_x + lx
			var world_z: int = base_z + lz
			
			# Sample noise to get height.
			var noise_val: float = thread_noise.get_noise_2d(float(world_x), float(world_z))
			var height: int = int(20.0 + noise_val * 5.0)
			height = clampi(height, 1, CHUNK_SIZE_Y - 1)
			heights[lx + lz * CHUNK_SIZE_X] = height
			
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
	
	# Second pass: place trees.
	for lx in range(2, CHUNK_SIZE_X - 2):
		for lz in range(2, CHUNK_SIZE_Z - 2):
			var world_x: int = base_x + lx
			var world_z: int = base_z + lz
			
			# Use hash to determine if tree spawns here.
			if _should_place_tree(world_x, world_z):
				var height: int = heights[lx + lz * CHUNK_SIZE_X]
				_place_tree(blocks, lx, height, lz)
	
	return blocks


func _should_place_tree(world_x: int, world_z: int) -> bool:
	# Deterministic hash to decide tree placement.
	var hash_val := _hash_coords(world_x, world_z)
	return hash_val % 47 == 0  # Roughly 1 in 47 chance per valid position.


func _hash_coords(x: int, z: int) -> int:
	# Simple hash for deterministic placement.
	var h := x * 374761393 + z * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return absi(h)


func _place_tree(blocks: PackedInt32Array, lx: int, ground_y: int, lz: int) -> void:
	# Place a simple tree: trunk + leaves.
	var trunk_height := 4 + (_hash_coords(lx, lz) % 3)  # 4-6 blocks tall.
	
	# Place trunk.
	for ty in trunk_height:
		var y := ground_y + ty
		if y < CHUNK_SIZE_Y:
			var index := lx + lz * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z
			blocks[index] = BlockTypes.BLOCK_WOOD
	
	# Place leaves (sphere-ish shape at top).
	var leaf_y := ground_y + trunk_height - 1
	for dy in range(-1, 3):
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				var nx := lx + dx
				var ny := leaf_y + dy
				var nz := lz + dz
				
				# Skip if out of chunk bounds.
				if nx < 0 or nx >= CHUNK_SIZE_X or nz < 0 or nz >= CHUNK_SIZE_Z or ny >= CHUNK_SIZE_Y:
					continue
				
				# Skip corners for rounder shape.
				if absi(dx) == 2 and absi(dz) == 2:
					continue
				if dy == 2 and (absi(dx) > 1 or absi(dz) > 1):
					continue
				
				var index := nx + nz * CHUNK_SIZE_X + ny * CHUNK_SIZE_X * CHUNK_SIZE_Z
				# Only place leaves in air.
				if blocks[index] == BlockTypes.BLOCK_AIR:
					blocks[index] = BlockTypes.BLOCK_LEAVES


func _generate_mesh_data_threaded(blocks: PackedInt32Array) -> Dictionary:
	# Generate mesh vertex data on background thread.
	# Returns arrays that can be used to build ArrayMesh on main thread.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var block_ids := PackedInt32Array()  # Store block IDs for UV lookup on main thread
	var face_types := PackedByteArray()  # 0=side, 1=top, 2=bottom
	
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
				
				# Check neighbors and add faces.
				# -X (side)
				if x == 0 or blocks[index - 1] == BlockTypes.BLOCK_AIR:
					_add_face_x_data(vertices, normals, x, y, z, false)
					for i in 6: block_ids.append(block_id); face_types.append(0)
				# +X (side)
				if x == size_x - 1 or blocks[index + 1] == BlockTypes.BLOCK_AIR:
					_add_face_x_data(vertices, normals, x, y, z, true)
					for i in 6: block_ids.append(block_id); face_types.append(0)
				# -Y (bottom)
				if y == 0 or blocks[index - size_xz] == BlockTypes.BLOCK_AIR:
					_add_face_y_data(vertices, normals, x, y, z, false)
					for i in 6: block_ids.append(block_id); face_types.append(2)
				# +Y (top)
				if y == size_y - 1 or blocks[index + size_xz] == BlockTypes.BLOCK_AIR:
					_add_face_y_data(vertices, normals, x, y, z, true)
					for i in 6: block_ids.append(block_id); face_types.append(1)
				# -Z (side)
				if z == 0 or blocks[index - size_x] == BlockTypes.BLOCK_AIR:
					_add_face_z_data(vertices, normals, x, y, z, false)
					for i in 6: block_ids.append(block_id); face_types.append(0)
				# +Z (side)
				if z == size_z - 1 or blocks[index + size_x] == BlockTypes.BLOCK_AIR:
					_add_face_z_data(vertices, normals, x, y, z, true)
					for i in 6: block_ids.append(block_id); face_types.append(0)
	
	return {
		"vertices": vertices,
		"normals": normals,
		"block_ids": block_ids,
		"face_types": face_types,
	}


func _add_face_x_data(vertices: PackedVector3Array, normals: PackedVector3Array, x: int, y: int, z: int, positive: bool) -> void:
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
		_push_quad_verts(vertices, normals, v0, v1, v2, v3, normal)
	else:
		var x0 := px
		var v0 := Vector3(x0, py, pz + 1.0)
		var v1 := Vector3(x0, py, pz)
		var v2 := Vector3(x0, py + 1.0, pz)
		var v3 := Vector3(x0, py + 1.0, pz + 1.0)
		var normal := Vector3(-1, 0, 0)
		_push_quad_verts(vertices, normals, v0, v1, v2, v3, normal)


func _add_face_y_data(vertices: PackedVector3Array, normals: PackedVector3Array, x: int, y: int, z: int, positive: bool) -> void:
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
		_push_quad_verts(vertices, normals, v0, v1, v2, v3, normal)
	else:
		var y0 := py
		var v0 := Vector3(px, y0, pz + 1.0)
		var v1 := Vector3(px + 1.0, y0, pz + 1.0)
		var v2 := Vector3(px + 1.0, y0, pz)
		var v3 := Vector3(px, y0, pz)
		var normal := Vector3(0, -1, 0)
		_push_quad_verts(vertices, normals, v0, v1, v2, v3, normal)


func _add_face_z_data(vertices: PackedVector3Array, normals: PackedVector3Array, x: int, y: int, z: int, positive: bool) -> void:
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
		_push_quad_verts(vertices, normals, v0, v1, v2, v3, normal)
	else:
		var z0 := pz
		var v0 := Vector3(px + 1.0, py, z0)
		var v1 := Vector3(px, py, z0)
		var v2 := Vector3(px, py + 1.0, z0)
		var v3 := Vector3(px + 1.0, py + 1.0, z0)
		var normal := Vector3(0, 0, -1)
		_push_quad_verts(vertices, normals, v0, v1, v2, v3, normal)


func _push_quad_verts(vertices: PackedVector3Array, normals: PackedVector3Array, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, normal: Vector3) -> void:
	# Triangle 1: v0, v1, v2
	vertices.append(v0)
	vertices.append(v1)
	vertices.append(v2)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	
	# Triangle 2: v0, v2, v3
	vertices.append(v0)
	vertices.append(v2)
	vertices.append(v3)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)


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


func _scan_all_loaded_chunks() -> void:
	# Scan all currently loaded chunks for exposed dirt blocks.
	print("Scanning ", chunks.size(), " loaded chunks for exposed dirt blocks...")
	var total_found := 0
	
	for coords in chunks.keys():
		var chunk = chunks[coords]
		if chunk and chunk.blocks:
			_scan_chunk_for_dirt(coords, chunk.blocks)
			# Count how many we found.
			for pos in dirt_blocks_timer.keys():
				if pos.x >= coords.x * CHUNK_SIZE_X and pos.x < (coords.x + 1) * CHUNK_SIZE_X:
					if pos.z >= coords.z * CHUNK_SIZE_Z and pos.z < (coords.z + 1) * CHUNK_SIZE_Z:
						total_found += 1
	
	print("Total exposed dirt blocks found: ", total_found)


func _scan_chunk_for_dirt(chunk_coords: Vector3i, blocks: PackedInt32Array) -> void:
	# Scan chunk for exposed dirt blocks and add to tracking.
	var base_x := chunk_coords.x * CHUNK_SIZE_X
	var base_z := chunk_coords.z * CHUNK_SIZE_Z
	var size_xz := CHUNK_SIZE_X * CHUNK_SIZE_Z
	var found_count := 0
	
	for y in CHUNK_SIZE_Y:
		for z in CHUNK_SIZE_Z:
			for x in CHUNK_SIZE_X:
				var index := x + z * CHUNK_SIZE_X + y * size_xz
				var block_id: int = blocks[index]
				
				if block_id == BlockTypes.BLOCK_DIRT:
					# Check if it has air above.
					var world_x := base_x + x
					var world_z := base_z + z
					var above := get_block_global(world_x, y + 1, world_z)
					if above == BlockTypes.BLOCK_AIR:
						var pos := Vector3i(world_x, y, world_z)
						dirt_blocks_timer[pos] = 0.0
						found_count += 1
	
	if found_count > 0:
		print("Chunk ", chunk_coords, " found ", found_count, " exposed dirt blocks")


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

	# Check if we're breaking a tree block (wood/leaves).
	var old_block: int = chunk.get_block(local_x, world_y, local_z)
	var breaking_tree_block := (block_id == BlockTypes.BLOCK_AIR and 
		(old_block == BlockTypes.BLOCK_WOOD or old_block == BlockTypes.BLOCK_LEAVES))

	# Set the block.
	chunk.set_block(local_x, world_y, local_z, block_id)
	
	# Track dirt blocks for grass conversion only when breaking grass above them.
	var pos := Vector3i(world_x, world_y, world_z)
	if block_id == BlockTypes.BLOCK_AIR and old_block == BlockTypes.BLOCK_GRASS:
		# Grass was broken - check if there's dirt below.
		var below := get_block_global(world_x, world_y - 1, world_z)
		if below == BlockTypes.BLOCK_DIRT:
			var below_pos := Vector3i(world_x, world_y - 1, world_z)
			dirt_blocks_timer[below_pos] = 0.0  # Start timer for exposed dirt.
	elif block_id == BlockTypes.BLOCK_DIRT:
		# Dirt placed - check if it has air above.
		var above := get_block_global(world_x, world_y + 1, world_z)
		if above == BlockTypes.BLOCK_AIR:
			dirt_blocks_timer[pos] = 0.0  # Start timer.
	elif block_id != BlockTypes.BLOCK_AIR:
		# Block placed - stop tracking dirt at this position or below.
		dirt_blocks_timer.erase(pos)
		var below_pos := Vector3i(world_x, world_y - 1, world_z)
		dirt_blocks_timer.erase(below_pos)

	# If we broke a tree block, check for unsupported blocks above.
	if breaking_tree_block:
		_check_falling_blocks(world_x, world_y, world_z)

	# Rebuild this chunk's mesh.
	chunk.update_mesh()
	chunk.force_collision_update()

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
		chunk.force_collision_update()


func _check_falling_blocks(broken_x: int, broken_y: int, broken_z: int) -> void:
	# Find all connected tree blocks (wood/leaves) that lost support.
	# Use flood fill to find connected tree blocks, then check if any are grounded.
	var to_check: Array[Vector3i] = []
	var checked: Dictionary = {}
	var tree_blocks: Array[Vector3i] = []
	
	# Start checking neighbors of the broken block.
	var neighbors := [
		Vector3i(broken_x, broken_y + 1, broken_z),  # Above.
		Vector3i(broken_x + 1, broken_y, broken_z),
		Vector3i(broken_x - 1, broken_y, broken_z),
		Vector3i(broken_x, broken_y, broken_z + 1),
		Vector3i(broken_x, broken_y, broken_z - 1),
	]
	
	for n in neighbors:
		var block := get_block_global(n.x, n.y, n.z)
		if block == BlockTypes.BLOCK_WOOD or block == BlockTypes.BLOCK_LEAVES:
			to_check.append(n)
	
	# Flood fill to find all connected tree blocks.
	while not to_check.is_empty():
		var pos: Vector3i = to_check.pop_back()
		var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
		
		if checked.has(key):
			continue
		checked[key] = true
		
		var block := get_block_global(pos.x, pos.y, pos.z)
		if block != BlockTypes.BLOCK_WOOD and block != BlockTypes.BLOCK_LEAVES:
			continue
		
		tree_blocks.append(pos)
		
		# Add neighbors to check.
		var next_neighbors := [
			Vector3i(pos.x, pos.y + 1, pos.z),
			Vector3i(pos.x, pos.y - 1, pos.z),
			Vector3i(pos.x + 1, pos.y, pos.z),
			Vector3i(pos.x - 1, pos.y, pos.z),
			Vector3i(pos.x, pos.y, pos.z + 1),
			Vector3i(pos.x, pos.y, pos.z - 1),
		]
		for nn in next_neighbors:
			var nn_key := "%d,%d,%d" % [nn.x, nn.y, nn.z]
			if not checked.has(nn_key):
				to_check.append(nn)
	
	# Check if any tree block is supported by non-tree solid block.
	var is_supported := false
	for pos in tree_blocks:
		var below := get_block_global(pos.x, pos.y - 1, pos.z)
		if below != BlockTypes.BLOCK_AIR and below != BlockTypes.BLOCK_WOOD and below != BlockTypes.BLOCK_LEAVES and below != BlockTypes.BLOCK_WATER:
			is_supported = true
			break
	
	# If not supported, make all tree blocks fall.
	if not is_supported and tree_blocks.size() > 0:
		# Play tree fall sound once (only for actual trees, not single stray blocks).
		if tree_blocks.size() >= 3 and tree_fall_sound and not tree_fall_sound.playing:
			tree_fall_sound.play()
		
		var affected_chunks: Dictionary = {}
		for pos in tree_blocks:
			var block := get_block_global(pos.x, pos.y, pos.z)
			_spawn_falling_block(pos, block)
			# Remove block from world (without recursively checking).
			_set_block_no_physics(pos.x, pos.y, pos.z, BlockTypes.BLOCK_AIR)
			# Track affected chunk.
			var cx := floori(float(pos.x) / float(CHUNK_SIZE_X))
			var cz := floori(float(pos.z) / float(CHUNK_SIZE_Z))
			affected_chunks[Vector3i(cx, 0, cz)] = true
		
		# Rebuild affected chunk meshes.
		for coords in affected_chunks.keys():
			_update_chunk_mesh_at(coords)


func _spawn_falling_block(pos: Vector3i, block_type: int) -> void:
	var falling := FALLING_BLOCK_SCENE.instantiate()
	falling.block_type = block_type
	falling.global_position = Vector3(pos.x + 0.5, pos.y + 0.5, pos.z + 0.5)
	get_tree().current_scene.add_child(falling)


func _set_block_no_physics(world_x: int, world_y: int, world_z: int, block_id: int) -> void:
	# Set block without triggering falling block check.
	if world_y < 0 or world_y >= CHUNK_SIZE_Y:
		return

	var chunk_x := floori(float(world_x) / float(CHUNK_SIZE_X))
	var chunk_z := floori(float(world_z) / float(CHUNK_SIZE_Z))
	var coords := Vector3i(chunk_x, 0, chunk_z)

	if not chunks.has(coords):
		return

	var chunk: Node3D = chunks[coords]
	var local_x := world_x - chunk_x * CHUNK_SIZE_X
	var local_z := world_z - chunk_z * CHUNK_SIZE_Z

	chunk.set_block(local_x, world_y, local_z, block_id)
