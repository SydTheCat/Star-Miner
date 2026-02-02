extends Node3D

# Block interaction system: raycasting, highlighting, breaking, and placing blocks.

const BlockTypes = preload("res://Data/BlockTypes.gd")

# How far the player can reach to interact with blocks.
@export var reach_distance: float = 5.0

# References set by main scene.
var camera: Camera3D
var voxel_world: Node3D
var hotbar: Control

# Current target block info.
var target_block_pos: Vector3i = Vector3i(-9999, -9999, -9999)
var target_normal: Vector3 = Vector3.ZERO
var has_target: bool = false

# Block highlight mesh.
var highlight_mesh: MeshInstance3D
var highlight_material: StandardMaterial3D

# Currently selected block type to place (updated by hotbar).
var selected_block: int = BlockTypes.BLOCK_DIRT


func _ready() -> void:
	_create_highlight_mesh()
	# Connect to hotbar if available.
	await get_tree().process_frame
	_connect_hotbar()


func _connect_hotbar() -> void:
	hotbar = get_node_or_null("/root/Main/Hotbar")
	if hotbar:
		print("Hotbar connected!")
		hotbar.slot_selected.connect(_on_hotbar_slot_selected)
		selected_block = hotbar.get_selected_block()
	else:
		print("WARNING: Hotbar not found at /root/Main/Hotbar")


func _on_hotbar_slot_selected(_slot_index: int, block_id: int) -> void:
	selected_block = block_id


func _create_highlight_mesh() -> void:
	highlight_mesh = MeshInstance3D.new()
	add_child(highlight_mesh)
	
	# Create wireframe cube mesh.
	var im := ImmediateMesh.new()
	highlight_mesh.mesh = im
	
	# Create material for highlight.
	highlight_material = StandardMaterial3D.new()
	highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	highlight_material.albedo_color = Color(0.1, 0.1, 0.1, 0.8)
	highlight_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	highlight_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	highlight_mesh.material_override = highlight_material
	
	highlight_mesh.visible = false


func _process(_delta: float) -> void:
	_update_target_block()
	_update_highlight()


func _update_target_block() -> void:
	has_target = false
	
	if camera == null or voxel_world == null:
		return
	
	# Cast ray from camera center.
	var space_state := camera.get_world_3d().direct_space_state
	if space_state == null:
		return
	
	var from := camera.global_position
	var to := from + (-camera.global_transform.basis.z) * reach_distance
	
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	
	var result := space_state.intersect_ray(query)
	
	if result.is_empty():
		return
	
	# Get the hit position and normal.
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	
	# Calculate block position (move slightly into the block from hit point).
	var block_pos := Vector3(
		floor(hit_pos.x - hit_normal.x * 0.01),
		floor(hit_pos.y - hit_normal.y * 0.01),
		floor(hit_pos.z - hit_normal.z * 0.01)
	)
	
	target_block_pos = Vector3i(int(block_pos.x), int(block_pos.y), int(block_pos.z))
	target_normal = hit_normal
	has_target = true


func _update_highlight() -> void:
	if not has_target:
		highlight_mesh.visible = false
		return
	
	highlight_mesh.visible = true
	
	# Position highlight at target block.
	highlight_mesh.global_position = Vector3(target_block_pos) + Vector3(0.5, 0.5, 0.5)
	
	# Rebuild wireframe mesh.
	var im: ImmediateMesh = highlight_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	
	im.surface_begin(Mesh.PRIMITIVE_LINES, highlight_material)
	
	# Draw cube edges (slightly larger than 1x1x1 to avoid z-fighting).
	var s := 0.502
	var corners := [
		Vector3(-s, -s, -s), Vector3(s, -s, -s), Vector3(s, -s, s), Vector3(-s, -s, s),
		Vector3(-s, s, -s), Vector3(s, s, -s), Vector3(s, s, s), Vector3(-s, s, s)
	]
	
	# Bottom face edges.
	_add_line(im, corners[0], corners[1])
	_add_line(im, corners[1], corners[2])
	_add_line(im, corners[2], corners[3])
	_add_line(im, corners[3], corners[0])
	
	# Top face edges.
	_add_line(im, corners[4], corners[5])
	_add_line(im, corners[5], corners[6])
	_add_line(im, corners[6], corners[7])
	_add_line(im, corners[7], corners[4])
	
	# Vertical edges.
	_add_line(im, corners[0], corners[4])
	_add_line(im, corners[1], corners[5])
	_add_line(im, corners[2], corners[6])
	_add_line(im, corners[3], corners[7])
	
	im.surface_end()


func _add_line(im: ImmediateMesh, from: Vector3, to: Vector3) -> void:
	im.surface_add_vertex(from)
	im.surface_add_vertex(to)


func _unhandled_input(event: InputEvent) -> void:
	# Only handle block interactions when mouse is captured (playing).
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	
	if event.is_action_pressed("break_block") and has_target:
		print("Breaking block at: ", target_block_pos)
		_break_block()
	elif event.is_action_pressed("place_block") and has_target:
		print("Placing block near: ", target_block_pos)
		_place_block()


func _break_block() -> void:
	if voxel_world == null:
		return
	
	# Get the block type before breaking.
	var block_id: int = voxel_world.get_block_global(target_block_pos.x, target_block_pos.y, target_block_pos.z)
	
	# Set block to air.
	voxel_world.set_block_global(target_block_pos.x, target_block_pos.y, target_block_pos.z, BlockTypes.BLOCK_AIR)
	
	# Add to inventory.
	if hotbar and block_id != BlockTypes.BLOCK_AIR:
		print("Adding block to inventory: ", block_id)
		hotbar.add_block(block_id)
	elif hotbar == null:
		print("WARNING: hotbar is null, cannot add block")


func _place_block() -> void:
	if voxel_world == null:
		return
	
	# Check if we have blocks to place.
	if hotbar == null:
		return
	if not hotbar.can_place_block():
		return
	
	# Calculate position for new block (adjacent to target in direction of normal).
	var place_pos := target_block_pos + Vector3i(
		int(round(target_normal.x)),
		int(round(target_normal.y)),
		int(round(target_normal.z))
	)
	
	# Don't place if it would be inside the player.
	# Simple check: if within 2 blocks of camera vertically and 1 block horizontally.
	if camera != null:
		var cam_pos := camera.global_position
		var dx := absf(cam_pos.x - (float(place_pos.x) + 0.5))
		var dy := absf(cam_pos.y - (float(place_pos.y) + 0.5))
		var dz := absf(cam_pos.z - (float(place_pos.z) + 0.5))
		if dx < 0.8 and dz < 0.8 and dy < 1.8:
			return  # Would place inside player.
	
	# Remove from inventory and place the selected block.
	if hotbar:
		hotbar.remove_block(selected_block)
	voxel_world.set_block_global(place_pos.x, place_pos.y, place_pos.z, selected_block)
