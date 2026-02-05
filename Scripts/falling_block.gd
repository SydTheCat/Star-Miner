extends RigidBody3D

# A falling block that was part of a tree.
# Falls with physics, can be collected by player on touch.

const BlockTypes = preload("res://Data/BlockTypes.gd")
const BlockTextures = preload("res://Data/BlockTextures.gd")

var block_type: int = BlockTypes.BLOCK_WOOD
var block_textures: Node = null
var has_landed: bool = false
var land_timer: float = 0.0
var collected: bool = false
const DESPAWN_TIME := 10.0  # Longer despawn time to give player time to collect.

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var pickup_area: Area3D = $PickupArea


func _ready() -> void:
	# Set up the visual based on block type.
	_setup_visual()
	
	# Connect to body entered signal for landing detection.
	body_entered.connect(_on_body_entered)
	
	# Connect pickup area for player collection.
	pickup_area.body_entered.connect(_on_pickup_area_body_entered)


func _process(delta: float) -> void:
	if collected:
		return
	
	# Check for player overlap every frame.
	_check_player_pickup()
		
	if has_landed:
		land_timer += delta
		if land_timer >= DESPAWN_TIME:
			queue_free()


func _check_player_pickup() -> void:
	if collected or pickup_area == null:
		return
	
	var bodies := pickup_area.get_overlapping_bodies()
	for body in bodies:
		if body is CharacterBody3D:
			# Find the inventory UI and add to it.
			var inv_ui := _find_inventory_ui()
			if inv_ui:
				inv_ui.add_block(block_type, 1)
			collected = true
			_play_pickup_sound()
			queue_free()
			return


func _setup_visual() -> void:
	# Get or create the block textures singleton.
	block_textures = get_tree().root.get_node_or_null("BlockTextures")
	if block_textures == null:
		block_textures = BlockTextures.new()
		block_textures.name = "BlockTextures"
		get_tree().root.add_child(block_textures)
	
	# Create a custom mesh with proper UVs for the block texture.
	var mesh := _create_textured_box(0.5)
	mesh_instance.mesh = mesh
	
	# Set material with atlas texture.
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = block_textures.get_atlas()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mesh_instance.material_override = mat


func _create_textured_box(size: float) -> ArrayMesh:
	var half := size / 2.0
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Get UV rects for each face.
	var uv_top: Rect2 = block_textures.get_uv_rect(block_type, "top")
	var uv_bottom: Rect2 = block_textures.get_uv_rect(block_type, "bottom")
	var uv_side: Rect2 = block_textures.get_uv_rect(block_type, "side")
	
	# Top face (+Y).
	_add_face(st, 
		Vector3(-half, half, -half), Vector3(half, half, -half),
		Vector3(half, half, half), Vector3(-half, half, half),
		Vector3.UP, uv_top)
	
	# Bottom face (-Y).
	_add_face(st,
		Vector3(-half, -half, half), Vector3(half, -half, half),
		Vector3(half, -half, -half), Vector3(-half, -half, -half),
		Vector3.DOWN, uv_bottom)
	
	# Front face (+Z).
	_add_face(st,
		Vector3(-half, -half, half), Vector3(-half, half, half),
		Vector3(half, half, half), Vector3(half, -half, half),
		Vector3.BACK, uv_side)
	
	# Back face (-Z).
	_add_face(st,
		Vector3(half, -half, -half), Vector3(half, half, -half),
		Vector3(-half, half, -half), Vector3(-half, -half, -half),
		Vector3.FORWARD, uv_side)
	
	# Right face (+X).
	_add_face(st,
		Vector3(half, -half, half), Vector3(half, half, half),
		Vector3(half, half, -half), Vector3(half, -half, -half),
		Vector3.RIGHT, uv_side)
	
	# Left face (-X).
	_add_face(st,
		Vector3(-half, -half, -half), Vector3(-half, half, -half),
		Vector3(-half, half, half), Vector3(-half, -half, half),
		Vector3.LEFT, uv_side)
	
	st.generate_tangents()
	return st.commit()


func _add_face(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, normal: Vector3, uv_rect: Rect2) -> void:
	var uv0 := uv_rect.position
	var uv1 := Vector2(uv_rect.position.x, uv_rect.end.y)
	var uv2 := uv_rect.end
	var uv3 := Vector2(uv_rect.end.x, uv_rect.position.y)
	
	st.set_normal(normal)
	
	# First triangle.
	st.set_uv(uv0)
	st.add_vertex(v0)
	st.set_uv(uv1)
	st.add_vertex(v1)
	st.set_uv(uv2)
	st.add_vertex(v2)
	
	# Second triangle.
	st.set_uv(uv0)
	st.add_vertex(v0)
	st.set_uv(uv2)
	st.add_vertex(v2)
	st.set_uv(uv3)
	st.add_vertex(v3)


func _on_body_entered(body: Node) -> void:
	# RigidBody collision - mark as landed when hitting terrain or other blocks.
	if collected:
		return
	
	if not has_landed:
		has_landed = true
		# Don't freeze - let it bounce and settle naturally.


func _on_pickup_area_body_entered(body: Node) -> void:
	# Area3D detection for player pickup.
	if collected:
		return
	
	# Check if it's the player.
	if body is CharacterBody3D:
		# Find the inventory UI and add to it.
		var inv_ui := _find_inventory_ui()
		if inv_ui:
			inv_ui.add_block(block_type, 1)
		collected = true
		_play_pickup_sound()
		queue_free()


func _find_inventory_ui() -> Control:
	var main := get_tree().current_scene
	if main:
		for child in main.get_children():
			if child.has_method("add_block") and child.has_method("can_place_block"):
				return child
	return null


func _play_pickup_sound() -> void:
	var sound := AudioStreamPlayer.new()
	sound.stream = load("res://Assets/SoundFX/multi-pop.mp3")
	sound.volume_db = 0.0
	get_tree().current_scene.add_child(sound)
	sound.play()
	sound.finished.connect(sound.queue_free)
