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
var blocks: PackedInt32Array

# Reference to VoxelWorld for cross-chunk neighbor queries.
var voxel_world: Node3D = null

@onready var mesh_instance: MeshInstance3D = $MeshInstance
@onready var collider_shape: CollisionShape3D = $Collider/CollisionShape3D


func _ready() -> void:
	# Allocate storage if not already done by VoxelWorld.
	if blocks.is_empty():
		_allocate_block_storage()
	# Note: update_mesh() is called by VoxelWorld after terrain generation.


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

	for y in CHUNK_SIZE_Y:
		for z in CHUNK_SIZE_Z:
			for x in CHUNK_SIZE_X:
				var block_id := get_block(x, y, z)
				if block_id == BlockTypes.BLOCK_AIR:
					continue

				var color := _block_color(block_id)

				# Neighbor checks – add face only if neighbor is air.
				# Use get_neighbor_block for cross-chunk boundary awareness.

				# -X (west)
				if get_neighbor_block(x - 1, y, z) == BlockTypes.BLOCK_AIR:
					_add_face_x(st, x, y, z, false, color)
				# +X (east)
				if get_neighbor_block(x + 1, y, z) == BlockTypes.BLOCK_AIR:
					_add_face_x(st, x, y, z, true, color)

				# -Y (down)
				if get_neighbor_block(x, y - 1, z) == BlockTypes.BLOCK_AIR:
					_add_face_y(st, x, y, z, false, color)
				# +Y (up)
				if get_neighbor_block(x, y + 1, z) == BlockTypes.BLOCK_AIR:
					_add_face_y(st, x, y, z, true, color)

				# -Z (north)
				if get_neighbor_block(x, y, z - 1) == BlockTypes.BLOCK_AIR:
					_add_face_z(st, x, y, z, false, color)
				# +Z (south)
				if get_neighbor_block(x, y, z + 1) == BlockTypes.BLOCK_AIR:
					_add_face_z(st, x, y, z, true, color)

	# Index the mesh and generate proper normals.
	st.index()
	var mesh: ArrayMesh = st.commit()

	# Create a material that uses vertex colors.
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Disable culling to show both sides

	mesh_instance.mesh = mesh
	mesh_instance.material_override = material

	# Build collision from the same mesh.
	if mesh != null and mesh.get_surface_count() > 0:
		var shape := mesh.create_trimesh_shape()
		if shape != null:
			collider_shape.shape = shape
		else:
			collider_shape.shape = null
	else:
		collider_shape.shape = null


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
