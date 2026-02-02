extends Node3D

const BlockTypes = preload("res://Data/BlockTypes.gd")

# One chunk of voxel data.
# Stores block IDs in a 1D array, addressed via (x, y, z) within chunk bounds.

const CHUNK_SIZE_X := 16
const CHUNK_SIZE_Y := 64
const CHUNK_SIZE_Z := 16

# Integer coordinates of this chunk in chunk space (not world space).
var chunk_coords: Vector3i = Vector3i.ZERO

# Flat array: CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z.
# Can be set directly by VoxelWorld with pre-generated data.
var blocks: PackedInt32Array

# Reference to VoxelWorld for cross-chunk neighbor queries.
var voxel_world: Node3D = null

# Deferred collision generation.
var collision_pending: bool = false
var cached_mesh: ArrayMesh = null

@onready var mesh_instance: MeshInstance3D = $MeshInstance
@onready var collider_shape: CollisionShape3D = $Collider/CollisionShape3D


func _ready() -> void:
	# Allocate storage only if not already set by VoxelWorld.
	if blocks.is_empty():
		_allocate_block_storage()
	# Note: update_mesh() is called by VoxelWorld after terrain generation.


func _process(_delta: float) -> void:
	# Handle deferred collision generation.
	if collision_pending and cached_mesh != null:
		_build_collision_deferred()
		collision_pending = false


func _allocate_block_storage() -> void:
	var total_blocks := CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z
	blocks = PackedInt32Array()
	blocks.resize(total_blocks)
	for i in total_blocks:
		blocks[i] = BlockTypes.BLOCK_AIR


func _get_index(x: int, y: int, z: int) -> int:
	# Layout: x varies fastest, then z, then y.
	return x + z * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z


func is_inside(x: int, y: int, z: int) -> bool:
	return (
		x >= 0 and x < CHUNK_SIZE_X and
		y >= 0 and y < CHUNK_SIZE_Y and
		z >= 0 and z < CHUNK_SIZE_Z
	)


func set_block(x: int, y: int, z: int, block_id: int) -> void:
	if not is_inside(x, y, z):
		return
	var index := _get_index(x, y, z)
	blocks[index] = block_id


func get_block(x: int, y: int, z: int) -> int:
	if not is_inside(x, y, z):
		return BlockTypes.BLOCK_AIR
	var index := _get_index(x, y, z)
	return blocks[index]


func get_neighbor_block(local_x: int, local_y: int, local_z: int) -> int:
	# For neighbor checks during meshing: if inside chunk, use local data.
	# If outside chunk bounds, query VoxelWorld for the neighboring chunk's data.
	if is_inside(local_x, local_y, local_z):
		return get_block(local_x, local_y, local_z)

	# Out of bounds vertically = air.
	if local_y < 0 or local_y >= CHUNK_SIZE_Y:
		return BlockTypes.BLOCK_AIR

	# Query VoxelWorld using world coordinates.
	if voxel_world != null:
		var world_x: int = chunk_coords.x * CHUNK_SIZE_X + local_x
		var world_z: int = chunk_coords.z * CHUNK_SIZE_Z + local_z
		return voxel_world.get_block_global(world_x, local_y, world_z)

	# Fallback if no world reference (shouldn't happen in normal use).
	return BlockTypes.BLOCK_AIR


# Simple test terrain: a flat stone layer at the bottom.
func _fill_default_test_pattern() -> void:
	_allocate_block_storage()
	var ground_height := 8
	for y in CHUNK_SIZE_Y:
		for z in CHUNK_SIZE_Z:
			for x in CHUNK_SIZE_X:
				if y < ground_height:
					blocks[_get_index(x, y, z)] = BlockTypes.BLOCK_STONE
				else:
					blocks[_get_index(x, y, z)] = BlockTypes.BLOCK_AIR


func _block_color(block_id: int) -> Color:
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


# Build a mesh from voxel data, only adding faces exposed to air.
func update_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Get texture manager.
	var tex_manager = get_node_or_null("/root/BlockTextures")
	if tex_manager == null:
		push_error("BlockTextures autoload not found!")
		return
	
	# Pre-cache block data for faster access.
	var local_blocks := blocks
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
				var block_id: int = local_blocks[index]
				if block_id == BlockTypes.BLOCK_AIR:
					continue

				# Neighbor checks – add face only if neighbor is air.
				# Inline neighbor checks for interior blocks (faster).
				
				# -X (west) - side
				if x > 0:
					if local_blocks[index - 1] == BlockTypes.BLOCK_AIR:
						_add_face_x_uv(st, x, y, z, false, tex_manager.get_uv_rect(block_id, "side"))
				elif get_neighbor_block(x - 1, y, z) == BlockTypes.BLOCK_AIR:
					_add_face_x_uv(st, x, y, z, false, tex_manager.get_uv_rect(block_id, "side"))
				
				# +X (east) - side
				if x < size_x - 1:
					if local_blocks[index + 1] == BlockTypes.BLOCK_AIR:
						_add_face_x_uv(st, x, y, z, true, tex_manager.get_uv_rect(block_id, "side"))
				elif get_neighbor_block(x + 1, y, z) == BlockTypes.BLOCK_AIR:
					_add_face_x_uv(st, x, y, z, true, tex_manager.get_uv_rect(block_id, "side"))

				# -Y (down) - bottom
				if y > 0:
					if local_blocks[index - size_xz] == BlockTypes.BLOCK_AIR:
						_add_face_y_uv(st, x, y, z, false, tex_manager.get_uv_rect(block_id, "bottom"))
				elif get_neighbor_block(x, y - 1, z) == BlockTypes.BLOCK_AIR:
					_add_face_y_uv(st, x, y, z, false, tex_manager.get_uv_rect(block_id, "bottom"))
				
				# +Y (up) - top
				if y < size_y - 1:
					if local_blocks[index + size_xz] == BlockTypes.BLOCK_AIR:
						_add_face_y_uv(st, x, y, z, true, tex_manager.get_uv_rect(block_id, "top"))
				elif get_neighbor_block(x, y + 1, z) == BlockTypes.BLOCK_AIR:
					_add_face_y_uv(st, x, y, z, true, tex_manager.get_uv_rect(block_id, "top"))

				# -Z (north) - side
				if z > 0:
					if local_blocks[index - size_x] == BlockTypes.BLOCK_AIR:
						_add_face_z_uv(st, x, y, z, false, tex_manager.get_uv_rect(block_id, "side"))
				elif get_neighbor_block(x, y, z - 1) == BlockTypes.BLOCK_AIR:
					_add_face_z_uv(st, x, y, z, false, tex_manager.get_uv_rect(block_id, "side"))
				
				# +Z (south) - side
				if z < size_z - 1:
					if local_blocks[index + size_x] == BlockTypes.BLOCK_AIR:
						_add_face_z_uv(st, x, y, z, true, tex_manager.get_uv_rect(block_id, "side"))
				elif get_neighbor_block(x, y, z + 1) == BlockTypes.BLOCK_AIR:
					_add_face_z_uv(st, x, y, z, true, tex_manager.get_uv_rect(block_id, "side"))

	# Index the mesh and generate proper normals.
	st.index()
	var mesh: ArrayMesh = st.commit()

	# Create material with texture atlas.
	var material := StandardMaterial3D.new()
	material.albedo_texture = tex_manager.get_atlas()
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	mesh_instance.mesh = mesh
	mesh_instance.material_override = material

	# Defer collision generation to next frame to spread load.
	cached_mesh = mesh
	collision_pending = true


func _build_collision_deferred() -> void:
	# Build collision from cached mesh (called from _process).
	if cached_mesh != null and cached_mesh.get_surface_count() > 0:
		var shape := cached_mesh.create_trimesh_shape()
		if shape != null:
			collider_shape.shape = shape
		else:
			collider_shape.shape = null
	else:
		collider_shape.shape = null
	cached_mesh = null


func apply_mesh_data(mesh_data: Dictionary) -> void:
	# Apply pre-built mesh data from background thread (fast path).
	# This only does the GPU upload, all vertex computation was done on worker thread.
	var vertices: PackedVector3Array = mesh_data["vertices"]
	var normals: PackedVector3Array = mesh_data["normals"]
	var block_ids: PackedInt32Array = mesh_data["block_ids"]
	var face_types: PackedByteArray = mesh_data["face_types"]
	
	if vertices.is_empty():
		mesh_instance.mesh = null
		collider_shape.shape = null
		return
	
	# Get texture manager.
	var tex_manager = get_node_or_null("/root/BlockTextures")
	if tex_manager == null:
		push_error("BlockTextures autoload not found!")
		return
	
	# Generate UVs based on block IDs and face types.
	var uvs := PackedVector2Array()
	uvs.resize(vertices.size())
	
	var face_names := ["side", "top", "bottom"]
	var i := 0
	while i < block_ids.size():
		var block_id: int = block_ids[i]
		var face_type: int = face_types[i]
		var face_name: String = face_names[face_type]
		var uv_rect: Rect2 = tex_manager.get_uv_rect(block_id, face_name)
		
		# Each face has 6 vertices (2 triangles).
		# UV corners - flipped vertically to correct orientation
		var uv0 := uv_rect.position + Vector2(0, uv_rect.size.y)
		var uv1 := uv_rect.position + uv_rect.size
		var uv2 := uv_rect.position + Vector2(uv_rect.size.x, 0)
		var uv3 := uv_rect.position
		uvs[i] = uv0
		uvs[i + 1] = uv1
		uvs[i + 2] = uv2
		uvs[i + 3] = uv0
		uvs[i + 4] = uv2
		uvs[i + 5] = uv3
		i += 6
	
	# Build ArrayMesh directly from arrays (faster than SurfaceTool).
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	# Create material with texture atlas.
	var material := StandardMaterial3D.new()
	material.albedo_texture = tex_manager.get_atlas()
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	
	# Defer collision to next frame.
	cached_mesh = mesh
	collision_pending = true


# Helper: add a quad facing +/-X.
func _add_face_x(st: SurfaceTool, x: int, y: int, z: int, positive: bool, color: Color) -> void:
	var px := float(x)
	var py := float(y)
	var pz := float(z)
	var size := 1.0

	if positive:
		# Face at x+1, normal +X
		var x0 := px + size
		var v0 := Vector3(x0, py, pz)
		var v1 := Vector3(x0, py, pz + size)
		var v2 := Vector3(x0, py + size, pz + size)
		var v3 := Vector3(x0, py + size, pz)
		var normal := Vector3(1, 0, 0)
		_push_quad(st, v0, v1, v2, v3, normal, color)
	else:
		# Face at x, normal -X
		var x0 := px
		var v0 := Vector3(x0, py, pz + size)
		var v1 := Vector3(x0, py, pz)
		var v2 := Vector3(x0, py + size, pz)
		var v3 := Vector3(x0, py + size, pz + size)
		var normal := Vector3(-1, 0, 0)
		_push_quad(st, v0, v1, v2, v3, normal, color)


# Helper: add a quad facing +/-Y.
func _add_face_y(st: SurfaceTool, x: int, y: int, z: int, positive: bool, color: Color) -> void:
	var px := float(x)
	var py := float(y)
	var pz := float(z)
	var size := 1.0

	if positive:
		# Top face (y+1), normal +Y
		var y0 := py + size
		var v0 := Vector3(px, y0, pz)
		var v1 := Vector3(px + size, y0, pz)
		var v2 := Vector3(px + size, y0, pz + size)
		var v3 := Vector3(px, y0, pz + size)
		var normal := Vector3(0, 1, 0)
		_push_quad(st, v0, v1, v2, v3, normal, color)
	else:
		# Bottom face (y), normal -Y
		var y0 := py
		var v0 := Vector3(px, y0, pz + size)
		var v1 := Vector3(px + size, y0, pz + size)
		var v2 := Vector3(px + size, y0, pz)
		var v3 := Vector3(px, y0, pz)
		var normal := Vector3(0, -1, 0)
		_push_quad(st, v0, v1, v2, v3, normal, color)


# Helper: add a quad facing +/-Z.
func _add_face_z(st: SurfaceTool, x: int, y: int, z: int, positive: bool, color: Color) -> void:
	var px := float(x)
	var py := float(y)
	var pz := float(z)
	var size := 1.0

	if positive:
		# Face at z+1, normal +Z
		var z0 := pz + size
		var v0 := Vector3(px, py, z0)
		var v1 := Vector3(px + size, py, z0)
		var v2 := Vector3(px + size, py + size, z0)
		var v3 := Vector3(px, py + size, z0)
		var normal := Vector3(0, 0, 1)
		_push_quad(st, v0, v1, v2, v3, normal, color)
	else:
		# Face at z, normal -Z
		var z0 := pz
		var v0 := Vector3(px + size, py, z0)
		var v1 := Vector3(px, py, z0)
		var v2 := Vector3(px, py + size, z0)
		var v3 := Vector3(px + size, py + size, z0)
		var normal := Vector3(0, 0, -1)
		_push_quad(st, v0, v1, v2, v3, normal, color)


# Push a quad (two triangles) with normals and color.
func _push_quad(
		st: SurfaceTool,
		v0: Vector3,
		v1: Vector3,
		v2: Vector3,
		v3: Vector3,
		normal: Vector3,
		color: Color
	) -> void:
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(v0)

	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(v1)

	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(v2)

	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(v0)

	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(v2)

	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(v3)


# UV-based face functions for textured rendering.
func _add_face_x_uv(st: SurfaceTool, x: int, y: int, z: int, positive: bool, uv_rect: Rect2) -> void:
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
		_push_quad_uv(st, v0, v1, v2, v3, normal, uv_rect)
	else:
		var x0 := px
		var v0 := Vector3(x0, py, pz + 1.0)
		var v1 := Vector3(x0, py, pz)
		var v2 := Vector3(x0, py + 1.0, pz)
		var v3 := Vector3(x0, py + 1.0, pz + 1.0)
		var normal := Vector3(-1, 0, 0)
		_push_quad_uv(st, v0, v1, v2, v3, normal, uv_rect)


func _add_face_y_uv(st: SurfaceTool, x: int, y: int, z: int, positive: bool, uv_rect: Rect2) -> void:
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
		_push_quad_uv(st, v0, v1, v2, v3, normal, uv_rect)
	else:
		var y0 := py
		var v0 := Vector3(px, y0, pz + 1.0)
		var v1 := Vector3(px + 1.0, y0, pz + 1.0)
		var v2 := Vector3(px + 1.0, y0, pz)
		var v3 := Vector3(px, y0, pz)
		var normal := Vector3(0, -1, 0)
		_push_quad_uv(st, v0, v1, v2, v3, normal, uv_rect)


func _add_face_z_uv(st: SurfaceTool, x: int, y: int, z: int, positive: bool, uv_rect: Rect2) -> void:
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
		_push_quad_uv(st, v0, v1, v2, v3, normal, uv_rect)
	else:
		var z0 := pz
		var v0 := Vector3(px + 1.0, py, z0)
		var v1 := Vector3(px, py, z0)
		var v2 := Vector3(px, py + 1.0, z0)
		var v3 := Vector3(px + 1.0, py + 1.0, z0)
		var normal := Vector3(0, 0, -1)
		_push_quad_uv(st, v0, v1, v2, v3, normal, uv_rect)


func _push_quad_uv(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, normal: Vector3, uv_rect: Rect2) -> void:
	# UV coordinates - flipped vertically to correct orientation
	var uv0 := uv_rect.position + Vector2(0, uv_rect.size.y)
	var uv1 := uv_rect.position + uv_rect.size
	var uv2 := uv_rect.position + Vector2(uv_rect.size.x, 0)
	var uv3 := uv_rect.position
	
	st.set_normal(normal)
	st.set_uv(uv0)
	st.add_vertex(v0)

	st.set_normal(normal)
	st.set_uv(uv1)
	st.add_vertex(v1)

	st.set_normal(normal)
	st.set_uv(uv2)
	st.add_vertex(v2)

	st.set_normal(normal)
	st.set_uv(uv0)
	st.add_vertex(v0)

	st.set_normal(normal)
	st.set_uv(uv2)
	st.add_vertex(v2)

	st.set_normal(normal)
	st.set_uv(uv3)
	st.add_vertex(v3)
