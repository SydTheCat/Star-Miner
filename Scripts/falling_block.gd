extends RigidBody3D

# A falling block that was part of a tree.
# Falls with physics, can be collected by player on touch.

const BlockTypes = preload("res://Data/BlockTypes.gd")

var block_type: int = BlockTypes.BLOCK_WOOD
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
		if body.has_method("add_to_inventory"):
			body.add_to_inventory(block_type, 1)
			collected = true
			queue_free()
			return


func _setup_visual() -> void:
	# Create a simple colored box for the falling block.
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.5, 0.5)  # Smaller pickup size.
	mesh_instance.mesh = box
	
	# Set material based on block type.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	match block_type:
		BlockTypes.BLOCK_WOOD:
			mat.albedo_color = Color(0.4, 0.26, 0.13, 1.0)
		BlockTypes.BLOCK_LEAVES:
			var leaves_tex := load("res://Textures/leaves.png") as Texture2D
			if leaves_tex:
				mat.albedo_texture = leaves_tex
				mat.albedo_color = Color(0.3, 0.7, 0.2, 1.0)  # Green tint.
			else:
				mat.albedo_color = Color(0.2, 0.5, 0.15, 1.0)
		_:
			mat.albedo_color = Color(1.0, 0.0, 1.0, 1.0)  # Magenta for unknown.
	
	mesh_instance.material_override = mat


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
	if body.has_method("add_to_inventory"):
		body.add_to_inventory(block_type, 1)
		collected = true
		queue_free()
