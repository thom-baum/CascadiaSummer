extends Sprite3D
## Cascadia enemy health bar: a billboarded, world-space readout above the
## enemy's head showing current HP as a filled bar. The enemy's Health
## component is the single source of truth - this node never writes health.
##
## The bar appears when the enemy takes damage and hides after hide_delay
## seconds without damage; it hides on death and reappears when a respawn or
## reset restores current above zero (Health.reset() has no signal, so the
## bar detects it while hidden). Depth testing is enabled so walls occlude
## it, and the engine culls it when the enemy leaves the view frustum.

@export var health_path: NodePath = ^"../Health"
@export var height_above_root: float = 2.05
@export var bar_world_width: float = 0.9
@export var tex_size: Vector2i = Vector2i(64, 6)
@export var hide_delay: float = 3.0
@export var back_color: Color = Color(0.1, 0.1, 0.12, 0.9)
@export var fill_color: Color = Color(0.76, 0.2, 0.16, 1.0)

var _health: Health
var _hide_timer: float = 0.0


func _ready() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	no_depth_test = false
	position = Vector3(0.0, height_above_root, 0.0)
	pixel_size = bar_world_width / float(maxi(1, tex_size.x))

	_health = get_node_or_null(health_path) as Health
	if _health == null:
		push_warning("enemy_health_bar: no Health found at " + str(health_path))
		visible = false
		return
	_health.damaged.connect(_on_damaged)
	_health.died.connect(_on_died)
	_refresh(_health.current, _health.max_health)
	visible = false


func _process(delta: float) -> void:
	if _health == null:
		return
	if _health.current <= 0:
		visible = false
		return
	if not visible:
		# Health.reset() emits no signal; poll while hidden so a respawn or
		# reset (current restored above zero) brings the bar back.
		_refresh(_health.current, _health.max_health)
		visible = true
	_hide_timer -= delta
	if _hide_timer <= 0.0:
		visible = false


func _on_damaged(_amount: int, current: int) -> void:
	if _health == null:
		return
	visible = true
	_hide_timer = hide_delay
	_refresh(current, _health.max_health)


func _on_died() -> void:
	visible = false
	_hide_timer = 0.0


func _refresh(current: int, max_hp: int) -> void:
	var ratio := 0.0
	if max_hp > 0:
		ratio = clampf(float(current) / float(max_hp), 0.0, 1.0)
	var img := Image.create(maxi(1, tex_size.x), maxi(1, tex_size.y), false, Image.FORMAT_RGBA8)
	img.fill(back_color)
	var fill_px := int(round(tex_size.x * ratio))
	if fill_px > 0:
		img.fill_rect(Rect2i(0, 0, fill_px, tex_size.y), fill_color)
	texture = ImageTexture.create_from_image(img)
