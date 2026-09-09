extends CharacterBody3D
## Cascadia milestone 3 hostile enemy (Cable Monster prototype, primitives).
## State machine: IDLE -> CHASE -> TELEGRAPH (0.7s readable windup that leans
## back and flashes red) -> STRIKE (short active hitbox) -> RECOVER -> cooldown.
## Uses the existing combat layer table: Hurtbox on EnemyHurt (16), StrikeArea
## on EnemyHit (32) masking only PlayerHurt (4).
## Player hits flash the enemy and build a stagger meter; once the meter hits
## stagger_max the enemy enters STAGGER. A player parry deflects a strike
## through notify_strike_deflected(perfect): a normal deflect only interrupts
## the strike with a brief HITSTUN (no stagger buildup), while a PERFECT
## deflect adds parry_stagger_buildup toward the meter, so repeated perfect
## parries can fill the meter to the full vulnerable STAGGER state. Only the
## meter threshold opens STAGGER; a single perfect parry never staggers by
## itself. Death collapses the figure and respawns it at home.

enum EnemyState { IDLE, CHASE, TELEGRAPH, STRIKE, RECOVER, HITSTUN, STAGGER, DEAD }

## Emitted whenever the stagger meter changes so the overhead test bar can
## redraw. max_stagger mirrors the current stagger_max tuning value.
signal stagger_changed(buildup: int, max_stagger: int)

@export var aggro_range: float = 11.0
@export var leash_range: float = 30.0
@export var attack_range: float = 2.0
@export var chase_speed: float = 2.7
@export var chase_accel: float = 26.0
@export var turn_rate: float = 7.0
@export var windup_time: float = 0.8
@export var strike_damage: int = 14
@export var strike_active_time: float = 0.18
@export var recover_time: float = 0.55
@export var cooldown_time: float = 1.1
## Brief interrupt after a deflected strike. HITSTUN is distinct from STAGGER:
## it never opens the vulnerable window and grants no stagger buildup by
## itself; it is only the impact reaction for a successful parry.
@export var hitstun_time: float = 0.65
## Stagger meter tuning (current test values): weapon hits add stagger_per_hit
## buildup; when buildup reaches stagger_max the enemy enters the STAGGER
## vulnerable state, which lasts stagger_vulnerable_time and is the opening
## for the future Visceral/Critical Attack.
@export var stagger_max: int = 2
@export var stagger_per_hit: int = 1
## Stagger buildup granted by a PERFECT parry. A normal parry gives no
## buildup (only HITSTUN); a perfect parry adds this reward on top, defaulting
## to the same value as a weapon hit so repeated perfect parries fill the
## meter exactly like hits do.
@export var parry_stagger_buildup: int = 1
## How long the enemy stays open once the stagger threshold is broken.
@export var stagger_vulnerable_time: float = 3.0
@export var respawn_delay: float = 4.0
@export var flash_duration: float = 0.16
## Visual-only delay before the red telegraph flash turns on after the windup
## begins. Windup/strike timing (windup_time) is untouched; this only tightens
## the red cue so it ends right against the strike.
@export var telegraph_flash_delay: float = 0.2
## Ground marker shown while the enemy is staggered/vulnerable. It marks the
## tight FRONT WINDOW the player must stand in to commit a Critical Attack -
## a player-sized pad centered vulnerable_window_distance ahead of the enemy's
## facing, vulnerable_window_half_width lateral half-size and
## vulnerable_window_depth fore/aft half-thickness (mirrors the player's
## critical_front_* exports). The marker is scaled/positioned in _ready.
@export var vulnerable_window_distance: float = 1.6
@export var vulnerable_window_half_width: float = 0.85
@export var vulnerable_window_depth: float = 0.5

@onready var _health: Health = $Health
@onready var _hurtbox: Area3D = $Hurtbox
@onready var _strike_area: MeleeHitbox = $StrikeArea
@onready var _lean_pivot: Node3D = $VisualRoot/LeanPivot
@onready var _body_mesh: MeshInstance3D = $VisualRoot/LeanPivot/Body
@onready var _eye_mesh: MeshInstance3D = $VisualRoot/LeanPivot/Eye
@onready var _hit_fx: GPUParticles3D = $HitFx
@onready var _deflect_fx: GPUParticles3D = $DeflectFx
@onready var _vulnerable_ring: MeshInstance3D = $VulnerableRing

var _state: int = EnemyState.IDLE
var _home: Vector3 = Vector3.ZERO
var _player: Node3D = null

var _windup_t: float = 0.0
var _strike_t: float = 0.0
var _recover_t: float = 0.0
var _hitstun_t: float = 0.0
var _stagger_t: float = 0.0
var _stagger_buildup: int = 0
## While a player Critical Attack is committed this counts down from the hold
## duration passed to on_critical_commit(). Above zero the vulnerable window
## cannot expire on its own; reaching zero without the critical landing is the
## safety that un-wedges a failed/missing clip.
var _critical_hold_t: float = 0.0
var _cooldown_t: float = 0.0
var _respawn_t: float = 0.0

var _body_mat: StandardMaterial3D = null
var _eye_mat: StandardMaterial3D = null
var _base_body_color: Color = Color(0.1, 0.09, 0.11, 1)
var _telegraph_body_color: Color = Color(0.85, 0.12, 0.07, 1)
var _vulnerable_body_color: Color = Color(0.55, 0.6, 0.72, 1)
var _dead_body_color: Color = Color(0.04, 0.04, 0.05, 1)
var _base_eye_color: Color = Color(0.9, 0.15, 0.12, 1)

var _flash_tween: Tween = null
var _lean_tween: Tween = null
var _telegraph_flash_shown: bool = false
var _spawn_layer: int = 1
var _spawn_mask: int = 1


func _ready() -> void:
	_home = global_position
	_spawn_layer = collision_layer
	_spawn_mask = collision_mask
	floor_snap_length = 0.3
	_body_mat = _own_material(_body_mesh)
	_eye_mat = _own_material(_eye_mesh)
	if _body_mat != null:
		_base_body_color = _body_mat.albedo_color
	if _vulnerable_ring != null:
		var pad_w := maxf(0.1, vulnerable_window_half_width * 2.0)
		var pad_d := maxf(0.1, vulnerable_window_depth * 2.0)
		_vulnerable_ring.scale = Vector3(pad_w, 1.0, pad_d)
		# Local -Z is the enemy's facing; the pad sits just above the ground
		# centered vulnerable_window_distance ahead of the root.
		_vulnerable_ring.position = Vector3(0.0, 0.02, -maxf(0.1, vulnerable_window_distance))
		_vulnerable_ring.visible = false
	_apply_idle_visual()
	_health.damaged.connect(_on_damaged)
	_health.died.connect(_on_died)


func _physics_process(delta: float) -> void:
	match _state:
		EnemyState.IDLE:
			_tick_idle(delta)
		EnemyState.CHASE:
			_tick_chase(delta)
		EnemyState.TELEGRAPH:
			_tick_telegraph(delta)
		EnemyState.STRIKE:
			_tick_strike(delta)
		EnemyState.RECOVER:
			_tick_recover(delta)
		EnemyState.HITSTUN:
			_tick_hitstun(delta)
		EnemyState.STAGGER:
			_tick_stagger(delta)
		EnemyState.DEAD:
			_tick_dead(delta)
	if _state != EnemyState.DEAD:
		velocity.y = -6.0
		move_and_slide()


# --- State ticks -------------------------------------------------------------

func _tick_idle(delta: float) -> void:
	_damp_horizontal(delta)
	var player := _find_player()
	if player == null:
		return
	if global_position.distance_to(player.global_position) <= aggro_range:
		_cooldown_t = 0.4
		_enter_chase()


func _tick_chase(delta: float) -> void:
	_cooldown_t = maxf(0.0, _cooldown_t - delta)
	var player := _find_player()
	if player == null:
		_enter_idle()
		return
	var to_player: Vector3 = player.global_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	if dist > leash_range:
		_enter_idle()
		return
	if dist > attack_range:
		if dist > 0.001:
			var dir := to_player / dist
			_drive_toward(dir, chase_speed, delta)
			_face_toward(dir, delta)
	else:
		_damp_horizontal(delta)
		_turn_toward_player(delta)
		if _cooldown_t <= 0.0:
			_start_telegraph()


func _tick_telegraph(delta: float) -> void:
	_windup_t += delta
	_turn_toward_player(delta)
	if not _telegraph_flash_shown and _windup_t >= telegraph_flash_delay:
		_telegraph_flash_shown = true
		_apply_telegraph_visual()
	if _windup_t >= windup_time:
		_start_strike()


func _tick_strike(delta: float) -> void:
	_strike_t += delta
	if _strike_t >= strike_active_time:
		_strike_area.end_swing()
		_state = EnemyState.RECOVER
		_recover_t = 0.0
		_set_lean(0.0, 0.18)
		_apply_eye_idle()


func _tick_recover(delta: float) -> void:
	_damp_horizontal(delta)
	_recover_t += delta
	if _recover_t >= recover_time:
		_cooldown_t = cooldown_time
		_enter_chase()


func _tick_hitstun(delta: float) -> void:
	_damp_horizontal(delta)
	_hitstun_t -= delta
	if _hitstun_t <= 0.0:
		# HITSTUN never feeds the stagger meter; the enemy simply re-engages.
		_enter_chase()


func _tick_stagger(delta: float) -> void:
	_damp_horizontal(delta)
	if _critical_hold_t > 0.0:
		# A committed Critical Attack owns the vulnerable window: it cannot
		# expire mid-commit. The hold itself is a safety timeout, so a failed
		# or missing clip still un-wedges the enemy.
		_critical_hold_t -= delta
		if _critical_hold_t <= 0.0:
			_critical_hold_t = 0.0
			_end_vulnerable_window()
		return
	_stagger_t -= delta
	_turn_toward_player(delta)
	if _stagger_t <= 0.0:
		_end_vulnerable_window()


func _end_vulnerable_window() -> void:
	_cooldown_t = maxf(_cooldown_t, cooldown_time * 0.45)
	# The vulnerable window closed: the meter is spent and the enemy
	# re-engages. It was open for a Visceral/Critical Attack.
	_set_stagger_buildup(0)
	_enter_chase()


func _tick_dead(delta: float) -> void:
	_respawn_t -= delta
	if _respawn_t <= 0.0:
		_respawn()


# --- Transitions -------------------------------------------------------------

func _enter_idle() -> void:
	if _state == EnemyState.DEAD:
		return
	_state = EnemyState.IDLE
	_damp_horizontal(0.016)
	# Losing the player clears any partial stagger buildup.
	_set_stagger_buildup(0)
	_apply_idle_visual()


func _enter_chase() -> void:
	if _state == EnemyState.DEAD:
		return
	_state = EnemyState.CHASE
	_apply_idle_visual()


func _start_telegraph() -> void:
	_state = EnemyState.TELEGRAPH
	_windup_t = 0.0
	_damp_horizontal(0.016)
	_telegraph_flash_shown = false
	# Physical windup (lean back) starts immediately; the red flash turns on
	# telegraph_flash_delay later so the cue is tight against the strike.
	_set_lean(0.42, 0.14)


func _start_strike() -> void:
	_state = EnemyState.STRIKE
	_strike_t = 0.0
	_strike_area.begin_swing(strike_damage)
	_apply_body_color(_base_body_color)
	_clear_body_glow()
	_set_eye_energy(4.5)
	_set_lean(-0.3, 0.12)


# --- Stagger meter -----------------------------------------------------------

func _set_stagger_buildup(value: int) -> void:
	var clamped := clampi(value, 0, maxi(0, stagger_max))
	if clamped == _stagger_buildup:
		return
	_stagger_buildup = clamped
	stagger_changed.emit(_stagger_buildup, maxi(1, stagger_max))


## Shared stagger qualification used by weapon hits and parries alike. Adds
## buildup and, only when the meter reaches stagger_max, drops the enemy into
## the STAGGER vulnerable state. An enemy already staggered or reacting
## (HITSTUN) never stacks more buildup, so the reaction timer owns its window.
func _add_stagger_buildup(amount: int) -> void:
	if _state == EnemyState.DEAD or _state == EnemyState.STAGGER or _state == EnemyState.HITSTUN:
		return
	_set_stagger_buildup(_stagger_buildup + maxi(0, amount))
	if _stagger_buildup >= stagger_max:
		_strike_area.end_swing()
		_state = EnemyState.STAGGER
		_stagger_t = stagger_vulnerable_time
		_apply_stagger_vulnerable_visual()


## True while the stagger threshold is broken and the enemy is open for a
## Visceral/Critical Attack.
func is_vulnerable() -> bool:
	return _state == EnemyState.STAGGER


## Called by the player when a Critical Attack commits. Holds the vulnerable
## window open for `duration` seconds so the committed sequence (enter ->
## shoot -> exit) cannot expire mid-animation. Returns false when the enemy is
## not actually vulnerable, which refuses the commit.
func on_critical_commit(duration: float) -> bool:
	if _state != EnemyState.STAGGER:
		return false
	_critical_hold_t = maxf(0.0, duration)
	return true


## The committed critical damage lands. Routes through Health.take_damage so
## the HUD popup, hit feedback, and the death/respawn flow stay consistent,
## then clears the vulnerable state: a survivor drops to RECOVER before normal
## combat; a lethal hit keeps the existing death/respawn flow. Stagger buildup
## resets to 0 either way.
func apply_critical_hit(damage: int) -> bool:
	if _state == EnemyState.DEAD or _state != EnemyState.STAGGER:
		return false
	_critical_hold_t = 0.0
	_set_stagger_buildup(0)
	_health.take_damage(maxi(1, damage), _find_player())
	if _state == EnemyState.DEAD:
		# Lethal: _on_died already collapsed the body and started respawn.
		return true
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_state = EnemyState.RECOVER
	_recover_t = 0.0
	_cooldown_t = maxf(_cooldown_t, cooldown_time * 0.35)
	_apply_idle_visual()
	return true


# --- External callbacks ------------------------------------------------------

## Called by the player's HurtboxArea when an enemy strike was deflected by a
## parry. `perfect` is true when the deflect landed inside the perfect band of
## the player's active window. A parry cancels the incoming strike and puts
## the enemy into a brief HITSTUN with NO stagger buildup; a perfect parry
## adds the parry_stagger_buildup reward on top so repeated perfect parries
## fill the meter to the full vulnerable STAGGER state. Normal weapon hits
## keep their own stagger_per_hit route through _on_damaged unchanged.
func notify_strike_deflected(perfect: bool = false) -> void:
	if _state == EnemyState.DEAD or _state == EnemyState.STAGGER or _state == EnemyState.HITSTUN:
		return
	_strike_area.end_swing()
	_play_deflect_fx()
	if perfect:
		# The perfect reward is applied while the enemy is still in its normal
		# state so a full meter promotes straight to the vulnerable STAGGER
		# window; a partial meter falls through into the brief HITSTUN.
		_add_stagger_buildup(parry_stagger_buildup)
		if _state == EnemyState.STAGGER:
			return
	_enter_hitstun()


## Brief impact reaction after a parried strike: the enemy drops its attack,
## flashes, and leans back for hitstun_time. HITSTUN is distinct from STAGGER -
## it never opens the vulnerable window by itself and never grants buildup;
## only the perfect-parry reward above feeds the stagger meter.
func _enter_hitstun() -> void:
	_state = EnemyState.HITSTUN
	_hitstun_t = hitstun_time
	_apply_body_color(Color(0.9, 0.95, 1.0, 1))
	_apply_eye_idle()
	_set_lean(0.35, 0.08)
	var player := _find_player()
	if player != null:
		var dir: Vector3 = global_position - player.global_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			var push := dir.normalized() * 2.4
			velocity.x = push.x
			velocity.z = push.z


func _on_damaged(amount: int, _current: int) -> void:
	if _state == EnemyState.DEAD:
		return
	_clear_body_glow()
	_flash()
	_apply_knockback(amount)
	_play_hit_fx()
	# Player attacks are damage-only: they never feed the stagger meter.
	# Stagger buildup comes solely from the perfect-parry reward in
	# notify_strike_deflected(perfect), so a player attack can never produce
	# parry-derived stagger.


func _on_died() -> void:
	if _state == EnemyState.DEAD:
		return
	_state = EnemyState.DEAD
	_respawn_t = respawn_delay
	_strike_area.end_swing()
	_hurtbox.monitoring = false
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO
	_apply_death_visual()


func _respawn() -> void:
	_state = EnemyState.IDLE
	global_position = _home
	velocity = Vector3.ZERO
	rotation.y = 0.0
	collision_layer = _spawn_layer
	collision_mask = _spawn_mask
	_hurtbox.monitoring = true
	_health.reset()
	_respawn_t = 0.0
	_stagger_t = 0.0
	_critical_hold_t = 0.0
	_set_stagger_buildup(0)
	_cooldown_t = 0.0
	if _lean_tween != null and _lean_tween.is_valid():
		_lean_tween.kill()
	_lean_pivot.rotation = Vector3.ZERO
	_apply_idle_visual()


## Public reset used by the player respawn loop (HUD): every enemy returns to
## its home position, fully healed and idle, before the player comes back.
func reset_to_home() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_strike_area.end_swing()
	_respawn()


# --- Movement helpers --------------------------------------------------------

func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player) and _player.is_inside_tree():
		return _player
	_player = get_tree().get_first_node_in_group("player") as Node3D
	return _player


func _damp_horizontal(delta: float) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z)
	h = h.move_toward(Vector3.ZERO, chase_accel * 2.0 * delta)
	velocity.x = h.x
	velocity.z = h.z


func _drive_toward(dir: Vector3, speed: float, delta: float) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z)
	h = h.move_toward(dir * speed, chase_accel * delta)
	velocity.x = h.x
	velocity.z = h.z


func _face_toward(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.0001:
		return
	var target_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-turn_rate * delta))


func _turn_toward_player(delta: float) -> void:
	var player := _find_player()
	if player == null:
		return
	var to := player.global_position - global_position
	to.y = 0.0
	if to.length_squared() > 0.0001:
		_face_toward(to.normalized(), delta)


func _apply_knockback(amount: int) -> void:
	var source := _health.last_hit_source
	if source is Node3D and is_instance_valid(source):
		var dir: Vector3 = global_position - (source as Node3D).global_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			dir = dir.normalized()
			var force := minf(3.0 + float(amount) * 0.12, 6.0)
			velocity.x = dir.x * force
			velocity.z = dir.z * force


# --- Visuals -----------------------------------------------------------------

func _own_material(mesh: MeshInstance3D) -> StandardMaterial3D:
	var mat := mesh.material_override as StandardMaterial3D
	if mat == null:
		mat = mesh.get_active_material(0) as StandardMaterial3D
	if mat == null:
		return null
	var copy: StandardMaterial3D = mat.duplicate() as StandardMaterial3D
	mesh.material_override = copy
	return copy


func _apply_idle_visual() -> void:
	_apply_body_state_color()
	_apply_eye_idle()
	_set_lean(0.0, 0.12)
	_set_vulnerable_ring_visible(false)


func _apply_telegraph_visual() -> void:
	_apply_body_color(_telegraph_body_color)
	_set_body_glow(Color(0.95, 0.13, 0.06, 1), 2.2)
	_set_eye_energy(6.0)
	_set_eye_color(Color(1.0, 0.12, 0.05, 1))


func _apply_stagger_vulnerable_visual() -> void:
	_apply_body_color(_vulnerable_body_color)
	_clear_body_glow()
	_set_eye_color(Color(0.55, 0.65, 1.0, 1))
	_set_eye_energy(1.2)
	_set_lean(0.0, 0.1)
	_set_vulnerable_ring_visible(true)


func _apply_death_visual() -> void:
	_set_vulnerable_ring_visible(false)
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_clear_body_glow()
	_apply_body_color(_dead_body_color)
	if _eye_mat != null:
		_eye_mat.albedo_color = Color(0.2, 0.2, 0.22, 1)
		_eye_mat.emission_energy_multiplier = 0.0
	_set_lean(0.0, 0.0)
	if _lean_tween != null and _lean_tween.is_valid():
		_lean_tween.kill()
	_lean_pivot.rotation = Vector3.ZERO
	_lean_tween = create_tween()
	_lean_tween.tween_property(_lean_pivot, "rotation:z", -1.5, 0.28)


func _apply_body_state_color() -> void:
	_apply_body_color(_desired_body_color())
	if _body_mat == null:
		return
	if _state == EnemyState.TELEGRAPH:
		_set_body_glow(Color(0.95, 0.13, 0.06, 1), 2.2)
	else:
		_clear_body_glow()


func _desired_body_color() -> Color:
	match _state:
		EnemyState.TELEGRAPH:
			return _telegraph_body_color
		EnemyState.STAGGER:
			return _vulnerable_body_color
		EnemyState.DEAD:
			return _dead_body_color
	return _base_body_color


func _apply_body_color(color: Color) -> void:
	if _body_mat != null:
		_body_mat.albedo_color = color


func _set_body_glow(color: Color, energy: float) -> void:
	if _body_mat == null:
		return
	_body_mat.emission_enabled = true
	_body_mat.emission = color
	_body_mat.emission_energy_multiplier = energy


func _clear_body_glow() -> void:
	if _body_mat == null:
		return
	_body_mat.emission_enabled = false
	_body_mat.emission_energy_multiplier = 0.0


func _apply_eye_idle() -> void:
	_set_eye_color(_base_eye_color)
	_set_eye_energy(1.6)


func _set_eye_color(color: Color) -> void:
	if _eye_mat != null:
		_eye_mat.albedo_color = color
		_eye_mat.emission = color


func _set_eye_energy(energy: float) -> void:
	if _eye_mat != null:
		_eye_mat.emission_energy_multiplier = energy


func _set_vulnerable_ring_visible(visible: bool) -> void:
	if _vulnerable_ring != null:
		_vulnerable_ring.visible = visible


func _flash() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_apply_body_color(Color(1.0, 1.0, 1.0, 1.0))
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_mat, "albedo_color", _desired_body_color(), flash_duration)


func _set_lean(target_x: float, dur: float) -> void:
	if _lean_tween != null and _lean_tween.is_valid():
		_lean_tween.kill()
	if dur <= 0.0:
		_lean_pivot.rotation.x = target_x
		return
	_lean_tween = create_tween()
	_lean_tween.tween_property(_lean_pivot, "rotation:x", target_x, dur)


# --- Milestone 5 game-feel FX -------------------------------------------------

func _fx_burst(fx: GPUParticles3D, world: Vector3) -> void:
	if fx == null:
		return
	fx.global_position = world
	fx.restart()


func _impact_point() -> Vector3:
	var source := _health.last_hit_source
	if source is Node3D and is_instance_valid(source):
		var dir: Vector3 = global_position - (source as Node3D).global_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			return global_position + dir.normalized() * 0.62 + Vector3(0, 1.0, 0)
	return global_position + Vector3(0, 1.0, 0)


func _deflect_point() -> Vector3:
	var player := _find_player()
	if player != null:
		var dir: Vector3 = player.global_position - global_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			return global_position + dir.normalized() * 0.85 + Vector3(0, 1.02, 0)
	return global_position + Vector3(0, 1.02, 0)


func _play_hit_fx() -> void:
	_fx_burst(_hit_fx, _impact_point())


func _play_deflect_fx() -> void:
	_fx_burst(_deflect_fx, _deflect_point())
