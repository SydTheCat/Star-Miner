extends CharacterBody3D

# Basic first-person controller for Godot 4.x.
# Uses Input Map actions:
#   move_forward, move_back, move_left, move_right, jump, sprint, toggle_mouse_capture

const MOVE_SPEED := 6.0
const SPRINT_MULTIPLIER := 1.7
const JUMP_VELOCITY := 7.0

# Use a normal var here because ProjectSettings.get_setting() is not a constant expression.
var GRAVITY: float = ProjectSettings.get_setting("physics/3d/default_gravity") * 2.0

var mouse_sensitivity: float = 0.0025
var yaw: float = 0.0
var pitch: float = 0.0

# Inventory: Dictionary of block_type -> count.
var inventory: Dictionary = {}

# Footsteps sound.
var footsteps_sound: AudioStreamPlayer
var is_walking: bool = false

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_setup_footsteps_sound()


func _physics_process(delta: float) -> void:
	# Don't allow movement when Ctrl is held (for block rotation).
	var allow_movement := not Input.is_key_pressed(KEY_CTRL)
	
	var input_dir := Vector2.ZERO
	if allow_movement:
		input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		input_dir.y = Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")

	var direction := Vector3.ZERO
	if input_dir.length() > 0.0:
		input_dir = input_dir.normalized()
		direction = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var speed := MOVE_SPEED
	if Input.is_action_pressed("sprint"):
		speed *= SPRINT_MULTIPLIER

	# Only allow movement changes when on the floor (no air control).
	if is_on_floor():
		if direction != Vector3.ZERO:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
		else:
			velocity.x = move_toward(velocity.x, 0.0, speed)
			velocity.z = move_toward(velocity.z, 0.0, speed)
		
		if Input.is_action_just_pressed("jump"):
			velocity.y = JUMP_VELOCITY
	else:
		# In the air - apply gravity, no direction changes.
		velocity.y -= GRAVITY * delta

	move_and_slide()
	
	# Handle footsteps sound.
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var should_play := is_on_floor() and horizontal_speed > 0.5
	if should_play and not footsteps_sound.playing:
		footsteps_sound.play()
	elif not should_play and footsteps_sound.playing:
		footsteps_sound.stop()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, deg_to_rad(-89.0), deg_to_rad(89.0))

		rotation.y = yaw
		head.rotation.x = pitch

	if event.is_action_pressed("toggle_mouse_capture"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func add_to_inventory(block_type: int, count: int = 1) -> void:
	if inventory.has(block_type):
		inventory[block_type] += count
	else:
		inventory[block_type] = count


func get_inventory_count(block_type: int) -> int:
	return inventory.get(block_type, 0)


func remove_from_inventory(block_type: int, count: int = 1) -> bool:
	if not inventory.has(block_type):
		return false
	if inventory[block_type] < count:
		return false
	inventory[block_type] -= count
	if inventory[block_type] <= 0:
		inventory.erase(block_type)
	return true


func _setup_footsteps_sound() -> void:
	footsteps_sound = AudioStreamPlayer.new()
	footsteps_sound.stream = load("res://Assets/SoundFX/footsteps.mp3")
	footsteps_sound.volume_db = -5.0
	add_child(footsteps_sound)
