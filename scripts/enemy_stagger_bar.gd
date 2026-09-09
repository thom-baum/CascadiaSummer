extends Sprite3D
## Cascadia temporary stagger meter: a billboarded, world-space readout below
## the enemy health bar showing stagger buildup as a filled bar (the max is
## the enemy's stagger_max tuning value). Read-only: the enemy's
## stagger_changed signal is the single source of truth; this node never
## writes stagger.
##
## Test instrumentation: the bar is visible for the enemy's whole lifetime so
## buildup can be watched from 0/2 upward. It hides on death and reappears
## when a respawn restores the enemy and resets the meter.

@export var enemy_path: NodePath = ^".."
@export var health_path: NodePath = ^"../Health"
@export var height_above_root: float = 1.94
@export var bar_world_width: float = 0.9
@export var tex_size: Vector2i = Vector2i(64, 4)
@export var back_color: Color = Color(0.1, 0.1, 0.12, 0.9)
@export var fill_color: Color = Color(0.88, 0.72, 0.2, 1.0)

var _enemy = null
var _health: Health = null


func _ready() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	no_depth_test = false
	position = Vector3(0.0, height_above_root, 0.0)
	pixel_size = bar_world_width / float(maxi(1, tex_size.x))

	_enemy = get_node_or_null(enemy_path)
	if _enemy == null or not _enemy.has_signal("stagger_changed"):
		push_warning("enemy_stagger_bar: no stagger_changed signal at " + str(enemy_path))
		visible = false
		return
	_enemy.stagger_changed.connect(_on_stagger_changed)
	_health = get_node_or_null(health_path) as Health
	if _health == null:
		push_warning("enemy_stagger_bar: no Health found at " + str(health_path))
	else:
		_health.died.connect(_on_died)
	_refresh(0, 1)
	visible = _health == null or _health.current > 0


func _process(_delta: float) -> void:
	if _enemy == null:
		return
	if _health == null:
		visible = true
		return
	# Stay visible while the enemy is alive; hide only on death. Respawn
	# restores current above zero, which re-shows the bar next frame.
	visible = _health.current > 0


func _on_stagger_changed(buildup: int, max_stagger: int) -> void:
	_refresh(buildup, max_stagger)


func _on_died() -> void:
	visible = false


func _refresh(buildup: int, max_stagger: int) -> void:
	var ratio := 0.0
	if max_stagger > 0:
		ratio = clampf(float(buildup) / float(max_stagger), 0.0, 1.0)
	var img := Image.create(maxi(1, tex_size.x), maxi(1, tex_size.y), false, Image.FORMAT_RGBA8)
	img.fill(back_color)
	var fill_px := int(round(tex_size.x * ratio))
	if fill_px > 0:
		img.fill_rect(Rect2i(0, 0, fill_px, tex_size.y), fill_color)
	texture = ImageTexture.create_from_image(img)
