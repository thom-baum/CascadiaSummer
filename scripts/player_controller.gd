extends CharacterBody3D
## Cascadia player controller. Milestone 1 locomotion is preserved:
## camera-relative WASD toward world -Z, sprint on Shift, jump on Space,
## SpringArm orbit camera with mouse, SkinPivot-only visual rotation.
## Milestone 2 adds the combat core on top:
## - stamina-gated light (3-hit combo) and heavy melee swings with a timed
##   active hitbox window, combo chaining and attack queueing,
## - dodge roll with iframes on Shift tap (hold Shift = sprint),
## - lock-on (Q) that targets the nearest lockable and tracks it,
## - a Health component ready for incoming enemy damage.
## Milestone 3 adds parry on F: a single holdable parry. Press-and-hold plays
## through a short startup into a persistent defensive stance that stays up
## for as long as the button is held; releasing is the only exit (recovery ->
## finish -> locomotion). The PP timing band is graded inside the stance: a
## PERFECT deflect (inside the early band) staggers the enemy into a brief
## HITSTUN plus exported stagger buildup, so repeated perfect parries build
## toward the full vulnerable STAGGER state; a deflect after the band while
## still held is a normal defensive parry (hitstun only, no buildup). A
## mistimed parry applies no deflect and the player takes the hit normally.
## Only an enemy strike may be deflected: the player's own AttackArea is never
## accepted as a deflect source, and the player stays free to attack
## immediately after a parry (the buffered light follow-up swings or commits a
## Critical against a vulnerable enemy; it is never a deflect).
## The body root never rotates on Y; facing lives on SkinPivot (visual) and
## the AttackArea pivot (swing aim). Movement stays camera-relative.
## Milestone 4 adds death handling: death locks the body until the respawn
## loop restores it at SpawnPoint.
## Milestone 5 adds the Visceral/Critical Attack: when a vulnerable (STAGGER)
## enemy is inside the front commit window, the light-attack input commits the
## player into a locked CRITICAL state; the animator plays the UAL Spell_Simple
## chain (enter -> shoot -> exit) and the shoot moment lands the critical
## damage and spawns the plasma FX.

enum PlayerState { IDLE, ATTACK, DODGE, PARRY, CRITICAL }

## Parry phases inside PlayerState.PARRY: startup plays first, then the
## persistent held stance (stays while the button is held; PP band graded at
## deflect time), then recovery on release.
enum ParryPhase { NONE, STARTUP, ACTIVE, RECOVERY }

const ATTACKS := {
	"light_1": {"stamina_cost": 15.0, "damage": 12, "startup": 0.15, "active": 0.13, "recovery": 0.36, "step": 1.8, "chain": "light_2"},
	"light_2": {"stamina_cost": 15.0, "damage": 12, "startup": 0.14, "active": 0.13, "recovery": 0.36, "step": 1.8, "chain": "light_3"},
	"light_3": {"stamina_cost": 18.0, "damage": 18, "startup": 0.18, "active": 0.15, "recovery": 0.5, "step": 2.2, "chain": ""},
	"heavy": {"stamina_cost": 32.0, "damage": 38, "startup": 0.42, "active": 0.18, "recovery": 0.6, "step": 2.6, "chain": ""},
}

@export var walk_speed: float = 4.0
@export var sprint_speed: float = 6.5
@export var jump_velocity: float = 5.8
@export var gravity: float = 20.0
@export var fall_gravity_multiplier: float = 1.35
@export var ground_accel: float = 45.0
@export var ground_friction: float = 55.0
@export var air_accel: float = 15.0
@export var air_friction: float = 3.0
@export var turn_speed: float = 10.0
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.1

@export var camera_path: NodePath = ^"CameraYaw"
@export var skin_pivot_path: NodePath = ^"SkinPivot"
@export var attack_area_path: NodePath = ^"AttackArea"
@export var animator_path: NodePath = ^"SkinPivot/PlayerVisualRoot"

@export var max_stamina: float = 100.0
@export var stamina_regen_rate: float = 26.0
@export var stamina_regen_delay: float = 0.6
@export var dodge_stamina_cost: float = 22.0
@export var dodge_speed: float = 7.2
@export var dodge_duration: float = 0.75
@export var dodge_iframe_begin: float = 0.08
@export var dodge_iframe_end: float = 0.32
@export var dodge_tap_window: float = 0.16
@export var lock_on_range: float = 22.0
@export var attack_damping: float = 14.0
@export var action_turn_speed: float = 20.0
@export var lock_turn_speed: float = 9.0
@export var parry_cost: float = 18.0
@export var parry_startup: float = 0.05
## The parry is a held defensive stance: press-and-hold enters PARRY, stays up
## for as long as the button is held, and releasing is the only exit
## (recovery -> finish -> locomotion). There is no active-window timer.
## The PP timing band below grades a deflect inside the stance; its expiry
## never ends the stance.
## Narrow PP timing band at the start of the parry stance. A deflect landing
## inside parry_startup + parry_perfect_band is a PERFECT parry: same deflect,
## hitstun plus exported stagger buildup. A deflect after the band while the
## stance is still held is a normal defensive parry (no buildup).
@export var parry_perfect_band: float = 0.09
@export var parry_recovery: float = 0.24
## While the parry stance is HELD (active deflect phase), the player may still
## move but at a reduced fraction of walk speed, giving the stance weight.
@export var parry_move_multiplier: float = 0.45
## Damage fraction taken on a NORMAL held block (strike outside the PP band).
## A normal block reduces incoming damage by this factor; a perfect parry
## fully negates it. 1.0 would mean no protection.
@export var parry_block_damage_multiplier: float = 0.3

## Visceral/Critical Attack (committed execution on a staggered enemy).
## Eligibility is a deliberate, player-sized FRONT WINDOW in front of the
## vulnerable enemy's facing/chest - not a radial root-distance radius.
## critical_front_distance is the window center ahead of the enemy chest,
## critical_front_half_width is the lateral half-size, critical_front_depth is
## the fore/aft half-thickness. The enemy's ground marker uses the same shape.
@export var critical_front_distance: float = 1.6
@export var critical_front_half_width: float = 0.85
@export var critical_front_depth: float = 0.5
## Damage dealt when the Spell_Simple_Shoot clip begins. 110 is the enemy max
## health: 70 leaves a survivor when the stagger was built with 1-2 light hits
## and stays lethal for an already wounded enemy.
@export var critical_damage: int = 70
## Safety timeout for the whole committed sequence. The animator normally
## signals critical_sequence_finished; if a clip is missing or wedged this
## returns the player to IDLE (the enemy's own hold uses the same budget).
@export var critical_commit_timeout: float = 8.0
## World height above the enemy root used as the beam target (enemy chest).
@export var critical_fx_chest_height: float = 1.0
## One-shot plasma FX scene spawned at the shoot moment (optional).
@export var critical_fx_scene: PackedScene = null

@onready var camera: ThirdPersonCamera = get_node_or_null(camera_path) as ThirdPersonCamera
@onready var skin_pivot: Node3D = get_node_or_null(skin_pivot_path) as Node3D
@onready var attack_area: MeleeHitbox = _resolve_attack_area()
@onready var animator: Node = get_node_or_null(animator_path)

var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _last_facing: Vector3 = Vector3.FORWARD

var _state: int = PlayerState.IDLE
var _attack_name: String = ""
var _attack_t: float = 0.0
var _queued_attack: String = ""
var _action_dir: Vector3 = Vector3.FORWARD

var _dodge_requested: bool = false
var _dodge_t: float = 0.0
var _dodge_dir: Vector3 = Vector3.BACK

var stamina: float = 100.0
var _stamina_regen_timer: float = 0.0

var _lock_target: Node3D = null

var _attack_request: String = ""
var _mouse_captured_prev: bool = false

var _parry_requested: bool = false
var _parry_phase: int = ParryPhase.NONE
var _parry_t: float = 0.0
var _parry_recovery_start: float = 0.0
var _parry_light_buffer: bool = false
var _dead: bool = false

## Committed Critical Attack: the vulnerable enemy locked for the sequence and
## the elapsed time used by the safety timeout.
var _critical_target: Node3D = null
var _critical_t: float = 0.0
var _critical_signals_connected: bool = false

var _shift_held: bool = false
var _shift_press_ms: int = 0
var _sprint_active: bool = false


func _ready() -> void:
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(45.0)
	stamina = max_stamina
	_connect_animator_signals()


func _connect_animator_signals() -> void:
	if animator == null or _critical_signals_connected:
		return
	if animator.has_signal("critical_shoot_started") and not animator.critical_shoot_started.is_connected(_on_critical_shoot_started):
		animator.critical_shoot_started.connect(_on_critical_shoot_started)
	if animator.has_signal("critical_sequence_finished") and not animator.critical_sequence_finished.is_connected(_on_critical_sequence_finished):
		animator.critical_sequence_finished.connect(_on_critical_sequence_finished)
	_critical_signals_connected = true


func _resolve_attack_area() -> MeleeHitbox:
	# P3: the animator reparents the AttackArea under the weapon attach, so
	# resolve it by group with a fallback to the old child path if it never
	# moved (weapon/skeleton/bone missing).
	var hitbox := get_tree().get_first_node_in_group("player_attack_area") as MeleeHitbox
	if hitbox == null:
		hitbox = get_node_or_null(attack_area_path) as MeleeHitbox
	return hitbox


func _physics_process(delta: float) -> void:
	_mouse_captured_prev = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _dead:
		_update_dead(delta)
		return
	_poll_sprint_dodge()
	_tick_stamina(delta)
	_update_lock_on()

	if _dodge_requested:
		_dodge_requested = false
		if stamina >= dodge_stamina_cost and _can_dodge_from_state():
			_start_dodge()

	var light_pressed := _attack_request == "light"
	var heavy_pressed := _attack_request == "heavy"
	_attack_request = ""
	if light_pressed and heavy_pressed:
		heavy_pressed = false

	if _parry_requested:
		if _state == PlayerState.IDLE:
			_parry_requested = false
			if stamina >= parry_cost:
				_start_parry()
		# else: keep the request pending. A parry pressed during recovery or
		# the follow-up attack must fire as soon as the player can act, so a
		# previous normal parry can never eat the next parry activation.

	match _state:
		PlayerState.IDLE:
			_update_idle(light_pressed, heavy_pressed)
		PlayerState.ATTACK:
			_update_attack(delta, light_pressed, heavy_pressed)
		PlayerState.DODGE:
			_update_dodge(delta)
		PlayerState.PARRY:
			_update_parry(delta, light_pressed, heavy_pressed)
		PlayerState.CRITICAL:
			_update_critical(delta)

	_apply_gravity_and_jump(delta)
	_apply_movement(delta)
	_orient_visual(delta)


func _input(event: InputEvent) -> void:
	if _dead:
		return
	# Attacks are mouse-gated: the capture click (first LMB press while the
	# cursor is visible) only re-captures the mouse and never swings.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or not _mouse_captured_prev:
		return
	if event.is_action_pressed("light_attack"):
		_attack_request = "light"
	elif event.is_action_pressed("heavy_attack"):
		_attack_request = "heavy"
	elif event.is_action_pressed("parry"):
		_parry_requested = true


func _unhandled_input(event: InputEvent) -> void:
	if _dead:
		return
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _poll_sprint_dodge() -> void:
	var held: bool = Input.is_action_pressed("sprint")
	var now_ms: int = Time.get_ticks_msec()
	if held and not _shift_held:
		_shift_held = true
		_shift_press_ms = now_ms
		_sprint_active = false
	elif held:
		if not _sprint_active and (now_ms - _shift_press_ms) >= int(dodge_tap_window * 1000.0):
			_sprint_active = true
	elif _shift_held:
		var held_ms: int = now_ms - _shift_press_ms
		var was_sprint: bool = _sprint_active
		_shift_held = false
		_sprint_active = false
		if not was_sprint and held_ms < int(dodge_tap_window * 1000.0):
			_dodge_requested = true


func _tick_stamina(delta: float) -> void:
	if _sprint_active or _state != PlayerState.IDLE:
		return
	if _stamina_regen_timer > 0.0:
		_stamina_regen_timer -= delta
	else:
		stamina = minf(max_stamina, stamina + stamina_regen_rate * delta)


func _update_idle(light_pressed: bool, heavy_pressed: bool) -> void:
	# The light-attack input commits a Critical Attack first: a vulnerable
	# enemy in range overrides a normal swing (and costs no stamina).
	if light_pressed and is_critical_eligible():
		_start_critical()
		return
	if heavy_pressed and stamina >= float(ATTACKS["heavy"].stamina_cost):
		_start_attack("heavy")
	elif light_pressed and stamina >= float(ATTACKS["light_1"].stamina_cost):
		_start_attack("light_1")


func _update_attack(delta: float, light_pressed: bool, heavy_pressed: bool) -> void:
	var atk: Dictionary = ATTACKS[_attack_name]
	var active_start: float = float(atk.startup)
	var active_end: float = active_start + float(atk.active)
	var total: float = active_end + float(atk.recovery)
	var prev: float = _attack_t
	_attack_t += delta
	var t: float = _attack_t

	if prev < active_start and t >= active_start:
		_begin_swing(atk)
	if prev < active_end and t >= active_end:
		_end_swing()

	if t >= float(atk.startup) * 0.55:
		_buffer_attack_input(light_pressed, heavy_pressed, atk)

	if t >= total:
		_end_swing()
		_finish_attack()


func _update_dodge(delta: float) -> void:
	_dodge_t += delta
	if _dodge_t >= dodge_duration:
		_state = PlayerState.IDLE


func _begin_swing(atk: Dictionary) -> void:
	if attack_area != null:
		attack_area.begin_swing(int(atk.damage))


func _end_swing() -> void:
	if attack_area != null:
		attack_area.end_swing()


func _buffer_attack_input(light_pressed: bool, heavy_pressed: bool, atk: Dictionary) -> void:
	if heavy_pressed and stamina >= float(ATTACKS["heavy"].stamina_cost):
		_queued_attack = "heavy"
		return
	if light_pressed:
		var chain: String = str(atk.get("chain", ""))
		if chain != "" and stamina >= float(ATTACKS[chain].stamina_cost):
			_queued_attack = chain


func _finish_attack() -> void:
	_state = PlayerState.IDLE
	_attack_t = 0.0
	_attack_name = ""
	if _queued_attack != "":
		var key := _queued_attack
		_queued_attack = ""
		if stamina >= float(ATTACKS[key].stamina_cost):
			_start_attack(key)


func _start_attack(key: String) -> void:
	var atk: Dictionary = ATTACKS[key]
	stamina = maxf(0.0, stamina - float(atk.stamina_cost))
	_stamina_regen_timer = stamina_regen_delay
	_state = PlayerState.ATTACK
	_attack_name = key
	_attack_t = 0.0
	_queued_attack = ""
	_action_dir = _resolve_action_dir()
	# The hitbox rides the weapon attach now (P3); the hand animation drives
	# its position and orientation, so no manual yaw is applied here.
	velocity.x = _action_dir.x * float(atk.step)
	velocity.z = _action_dir.z * float(atk.step)


## Dodge may interrupt an attack only during its startup phase (before the
## active hitbox window opens). Once the swing is active or in recovery the
## attack commits: a dodge press at that point is dropped, not buffered.
## Parry and roll commit the same way: a Shift-tap cannot cancel an active
## parry, and cannot re-trigger a roll that is already in progress.
func _can_dodge_from_state() -> bool:
	if _state == PlayerState.PARRY or _state == PlayerState.DODGE or _state == PlayerState.CRITICAL:
		return false
	if _state != PlayerState.ATTACK:
		return true
	var atk: Dictionary = ATTACKS[_attack_name]
	return _attack_t < float(atk.startup)


func _start_dodge() -> void:
	if _state == PlayerState.ATTACK:
		_end_swing()
	stamina = maxf(0.0, stamina - dodge_stamina_cost)
	_stamina_regen_timer = stamina_regen_delay
	_state = PlayerState.DODGE
	_dodge_t = 0.0
	_queued_attack = ""
	_dodge_dir = _pick_dodge_dir()
	_action_dir = _dodge_dir
	velocity.x = _dodge_dir.x * dodge_speed
	velocity.z = _dodge_dir.z * dodge_speed


func _start_parry() -> void:
	stamina = maxf(0.0, stamina - parry_cost)
	_stamina_regen_timer = stamina_regen_delay
	_state = PlayerState.PARRY
	_parry_phase = ParryPhase.STARTUP
	_parry_t = 0.0
	_parry_recovery_start = 0.0
	_queued_attack = ""
	_parry_light_buffer = false
	_action_dir = _resolve_action_dir()


func _update_parry(delta: float, light_pressed: bool, heavy_pressed: bool) -> void:
	_parry_t += delta
	if light_pressed and not heavy_pressed:
		_parry_light_buffer = true
	match _parry_phase:
		ParryPhase.STARTUP:
			if _parry_t >= parry_startup:
				_parry_phase = ParryPhase.ACTIVE
		ParryPhase.ACTIVE:
			# The held parry stance is a persistent defensive state owned by
			# the held input, not by a deflect/PP timer. It stays up for as
			# long as the parry button is held; releasing is the only exit
			# (recovery -> finish -> locomotion). The PP band is a separate
			# condition graded at deflect time in parry_is_perfect(); its
			# expiry never ends the stance.
			if not Input.is_action_pressed("parry"):
				_begin_parry_recovery()
		ParryPhase.RECOVERY:
			if _parry_t >= _parry_recovery_start + parry_recovery:
				_finish_parry()


func _begin_parry_recovery() -> void:
	if _parry_phase == ParryPhase.RECOVERY:
		return
	_parry_phase = ParryPhase.RECOVERY
	_parry_recovery_start = _parry_t


func _finish_parry() -> void:
	_state = PlayerState.IDLE
	_parry_phase = ParryPhase.NONE
	_parry_t = 0.0
	_parry_recovery_start = 0.0
	if _parry_light_buffer:
		_parry_light_buffer = false
		# A buffered light follow-up after a successful deflect commits the
		# Critical Attack when the deflected enemy is vulnerable in range;
		# otherwise it is a normal swing. Attacking right after a parry is
		# always allowed and is never a deflect.
		if is_critical_eligible():
			_start_critical()
		elif stamina >= float(ATTACKS["light_1"].stamina_cost):
			_start_attack("light_1")


# --- Visceral/Critical Attack ------------------------------------------------
# The player commits when a vulnerable lockable is inside the front commit
# window (critical_front_distance/half_width/depth ahead of the enemy's
# facing) and the existing light-attack input is pressed. The commit locks all
# normal actions; the animator drives the Spell_Simple chain and emits the
# shoot and sequence-finished signals this controller consumes.

func is_critical_eligible() -> bool:
	if _dead or _state != PlayerState.IDLE:
		return false
	return _find_vulnerable_target() != null


func _find_vulnerable_target() -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for node in get_tree().get_nodes_in_group("lockable"):
		if not (node is Node3D) or not (node as Node3D).is_inside_tree():
			continue
		var candidate := node as Node3D
		if not candidate.has_method("is_vulnerable"):
			continue
		if not bool(candidate.call("is_vulnerable")):
			continue
		var dist := _critical_front_window_dist(candidate)
		if dist < best_dist:
			best = candidate
			best_dist = dist
	return best


## Front-window positional test for the Critical Attack. The player must be
## deliberately standing inside a player-sized box centered
## critical_front_distance ahead of the vulnerable enemy's facing (its -Z),
## with lateral half-width critical_front_half_width and fore/aft
## half-thickness critical_front_depth. Returns squared distance to the window
## center when inside, INF when outside. This deliberately replaces the old
## broad radial root-distance bubble.
func _critical_front_window_dist(candidate: Node3D) -> float:
	var forward: Vector3 = -candidate.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.BACK
	forward = forward.normalized()
	var to_player: Vector3 = global_position - candidate.global_position
	to_player.y = 0.0
	var along := to_player.dot(forward)
	if absf(along - critical_front_distance) > critical_front_depth:
		return INF
	var perp := (to_player - forward * along).length()
	if perp > critical_front_half_width:
		return INF
	var center: Vector3 = candidate.global_position + forward * critical_front_distance
	return global_position.distance_squared_to(center)


func _start_critical() -> void:
	var target := _find_vulnerable_target()
	if target == null:
		return
	_critical_target = target
	_state = PlayerState.CRITICAL
	_critical_t = 0.0
	_queued_attack = ""
	_end_swing()
	# Face the committed target; _facing_direction returns _action_dir for any
	# non-IDLE state, so the visual keeps turning toward it while locked.
	var to: Vector3 = target.global_position - global_position
	to.y = 0.0
	if to.length_squared() > 0.0001:
		_action_dir = to.normalized()
	# The enemy holds its vulnerable window open for the whole sequence budget,
	# so the window cannot expire mid-commit.
	if target.has_method("on_critical_commit"):
		target.call("on_critical_commit", critical_commit_timeout)


func _update_critical(delta: float) -> void:
	_critical_t += delta
	# Safety: if the animator chain never emits critical_sequence_finished
	# (missing clip, wedge), return to IDLE instead of locking forever. The
	# enemy's own hold times out on the same budget.
	if _critical_t >= critical_commit_timeout:
		_abort_critical()


func _abort_critical() -> void:
	_critical_target = null
	_critical_t = 0.0
	_state = PlayerState.IDLE


## Animator signal: the Spell_Simple_Shoot clip began. Land the critical
## damage on the committed vulnerable enemy and spawn the plasma FX from the
## hand to the enemy chest.
func _on_critical_shoot_started(hand_world: Vector3) -> void:
	if _state != PlayerState.CRITICAL:
		return
	var target := _critical_target
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	if target.has_method("apply_critical_hit"):
		target.call("apply_critical_hit", critical_damage)
	_spawn_critical_fx(hand_world, target.global_position + Vector3(0.0, critical_fx_chest_height, 0.0))


## Animator signal: the full enter -> shoot -> exit chain ended. Release the
## commit back to normal locomotion.
func _on_critical_sequence_finished() -> void:
	if _state != PlayerState.CRITICAL:
		return
	_critical_target = null
	_critical_t = 0.0
	_state = PlayerState.IDLE


func _spawn_critical_fx(hand_world: Vector3, chest_world: Vector3) -> void:
	if critical_fx_scene == null:
		return
	var fx: Node3D = critical_fx_scene.instantiate() as Node3D
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	scene_root.add_child(fx)
	if fx.has_method("setup"):
		fx.call("setup", hand_world, chest_world)


func parry_active() -> bool:
	return _state == PlayerState.PARRY and _parry_phase == ParryPhase.ACTIVE


## A deflect inside the narrow perfect band at the start of the active window
## is a PERFECT parry: same single parry mechanic, timing-based reward upgrade.
func parry_is_perfect() -> bool:
	return parry_active() and _parry_t < parry_startup + parry_perfect_band


## True while the player is holding the parry button in the live active
## window - the defensive stance is still up. Used by the animator to keep
## the parry pose frozen at its end frame instead of drifting or cutting.
func is_parry_held() -> bool:
	return _state == PlayerState.PARRY and _parry_phase == ParryPhase.ACTIVE and Input.is_action_pressed("parry")


## Called by this body's HurtboxArea when an Area3D overlaps it. Only an enemy
## strike may enter the parry pathway: the hitbox's owning body must expose
## notify_strike_deflected (enemy.gd) or carry the explicit "enemy_strike"
## marker. The player's own AttackArea is a MeleeHitbox with get_damage too,
## but its owner (the weapon attach / player) exposes neither, so it can never
## enter this pathway - a follow-up player attack is always a normal attack
## and cannot satisfy or trigger the deflect route. Returns:
##   0 = not parried (full damage applies)
##   1 = normal held block (strike is interrupted, reduced damage taken)
##   2 = perfect parry (strike fully negated + existing PP reward)
## A normal held block puts the enemy into HITSTUN with no stagger buildup; a
## perfect deflect adds the exported stagger buildup reward. Damage reduction
## for the normal block uses parry_block_damage_multiplier.
func on_deflect_opportunity(hitbox: Area3D) -> int:
	if not parry_active():
		return 0
	if not _is_deflectable_strike(hitbox):
		return 0
	var enemy_root: Node = hitbox.get_parent()
	var perfect: bool = parry_is_perfect()
	enemy_root.notify_strike_deflected(perfect)
	return 2 if perfect else 1


## Damage actually taken after a NORMAL held block (strike outside the PP
## band). The block reduces the incoming amount by parry_block_damage_multiplier
## but never fully negates it; a perfect parry uses the 2 result instead.
func get_blocked_damage(amount: int) -> int:
	return maxi(1, int(round(float(amount) * parry_block_damage_multiplier)))


## Explicit source attribution for the deflect pathway: the hitbox's owning
## body must be an enemy (exposes notify_strike_deflected) or carry the
## "enemy_strike" marker group. Anything else - including the player's own
## AttackArea - is refused before any reward is applied.
func _is_deflectable_strike(hitbox: Area3D) -> bool:
	var root: Node = hitbox.get_parent()
	if root != null and root.has_method("notify_strike_deflected"):
		return true
	if hitbox.is_in_group("enemy_strike"):
		return true
	return root != null and root.is_in_group("enemy_strike")


func is_invulnerable() -> bool:
	return _state == PlayerState.DODGE and _dodge_t >= dodge_iframe_begin and _dodge_t < dodge_iframe_end


# --- Read-only accessors for the animation layer -----------------------------
# Pure reads of the current gameplay state for player_animator.gd. The animator
# is a strict observer: it must never change these values or call any
# state-transition method.

func get_state() -> int:
	return _state


func get_attack_name() -> String:
	return _attack_name


func is_sprinting() -> bool:
	return _sprint_active


func _resolve_action_dir() -> Vector3:
	if _lock_target != null and is_instance_valid(_lock_target):
		var to: Vector3 = (_lock_target as Node3D).global_position - global_position
		to.y = 0.0
		if to.length_squared() > 0.0001:
			return to.normalized()
	var input_v: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := _camera_relative_direction(input_v)
	if wish.length_squared() > 0.01:
		return wish
	if _last_facing.length_squared() > 0.001:
		return _last_facing.normalized()
	return Vector3.FORWARD


func _pick_dodge_dir() -> Vector3:
	var input_v: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := _camera_relative_direction(input_v)
	if wish.length_squared() > 0.01:
		return wish
	return -_flat_forward()


func _yaw_for_direction(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


func _update_lock_on() -> void:
	if Input.is_action_just_pressed("lock_on"):
		if _lock_target != null and is_instance_valid(_lock_target):
			_clear_lock()
		else:
			_acquire_lock()
	if _lock_target == null:
		return
	if not is_instance_valid(_lock_target) or not _lock_target.is_inside_tree():
		_clear_lock()
		return
	if global_position.distance_to((_lock_target as Node3D).global_position) > lock_on_range * 1.35:
		_clear_lock()


func _acquire_lock() -> void:
	var best: Node3D = null
	var best_dist := INF
	for node in get_tree().get_nodes_in_group("lockable"):
		if node is Node3D and node.is_inside_tree():
			var candidate := node as Node3D
			var dist := global_position.distance_to(candidate.global_position)
			if dist <= lock_on_range and dist < best_dist:
				best = candidate
				best_dist = dist
	if best == null:
		return
	_lock_target = best
	if camera != null:
		camera.set_lock_target(best)


func _clear_lock() -> void:
	_lock_target = null
	if camera != null:
		camera.clear_lock_target()


func _apply_gravity_and_jump(delta: float) -> void:
	if is_on_floor():
		_coyote_timer = coyote_time
	elif _coyote_timer > 0.0:
		_coyote_timer -= delta

	if Input.is_action_just_pressed("jump") and _state == PlayerState.IDLE:
		_jump_buffer_timer = jump_buffer_time
	elif _jump_buffer_timer > 0.0:
		_jump_buffer_timer -= delta

	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0 and _state == PlayerState.IDLE:
		velocity.y = jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
	elif not is_on_floor():
		var multiplier := fall_gravity_multiplier if velocity.y < 0.0 else 1.0
		velocity.y -= gravity * multiplier * delta


func _apply_movement(delta: float) -> void:
	var input_v: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish_dir := _camera_relative_direction(input_v)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if _state == PlayerState.IDLE:
		var sprinting: bool = _sprint_active and Input.is_action_pressed("sprint") and wish_dir.length_squared() > 0.01
		var target_speed := sprint_speed if sprinting else walk_speed
		var accel := ground_accel if is_on_floor() else air_accel
		var friction := ground_friction if is_on_floor() else air_friction
		if wish_dir.length_squared() > 0.01:
			horizontal = horizontal.move_toward(wish_dir * target_speed, accel * delta)
			_last_facing = wish_dir
		else:
			horizontal = horizontal.move_toward(Vector3.ZERO, friction * delta)
	elif _state == PlayerState.ATTACK:
		horizontal = horizontal.move_toward(Vector3.ZERO, attack_damping * delta)
	elif _state == PlayerState.PARRY:
		# Holding the parry stance allows slow deliberate movement; startup
		# and recovery (released or expired) lock the body as before.
		var stance_held := _parry_phase == ParryPhase.ACTIVE and Input.is_action_pressed("parry")
		if stance_held and wish_dir.length_squared() > 0.01:
			var stance_speed := walk_speed * parry_move_multiplier
			horizontal = horizontal.move_toward(wish_dir * stance_speed, ground_accel * 0.5 * delta)
			_last_facing = wish_dir
		else:
			horizontal = horizontal.move_toward(Vector3.ZERO, attack_damping * delta)
	elif _state == PlayerState.DODGE:
		horizontal = horizontal.move_toward(Vector3.ZERO, 8.0 * delta)
	elif _state == PlayerState.CRITICAL:
		# Committed: no player movement, no sprint, no dodge. The body is
		# locked facing the target while gravity still applies via the
		# vertical velocity handled in _apply_gravity_and_jump.
		horizontal = horizontal.move_toward(Vector3.ZERO, attack_damping * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()


func _camera_relative_direction(input_v: Vector2) -> Vector3:
	if camera == null:
		return Vector3(input_v.x, 0.0, input_v.y).normalized()
	var dir := _flat_right() * input_v.x + _flat_forward() * -input_v.y
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	return dir


func _flat_forward() -> Vector3:
	if camera == null:
		return Vector3.FORWARD
	var f := -camera.global_transform.basis.z
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return Vector3.FORWARD
	return f.normalized()


func _flat_right() -> Vector3:
	if camera == null:
		return Vector3.RIGHT
	var r := camera.global_transform.basis.x
	r.y = 0.0
	if r.length_squared() < 0.0001:
		return Vector3.RIGHT
	return r.normalized()


func _orient_visual(delta: float) -> void:
	if skin_pivot == null:
		return
	var dir := _facing_direction()
	if dir.length_squared() < 0.001:
		return
	var speed := action_turn_speed if _state != PlayerState.IDLE else turn_speed
	if _state == PlayerState.IDLE and _lock_target != null and is_instance_valid(_lock_target):
		speed = lock_turn_speed
	var target_basis := Basis.looking_at(dir.normalized(), Vector3.UP)
	var current := skin_pivot.global_transform.basis.get_rotation_quaternion()
	var goal := target_basis.get_rotation_quaternion()
	var t := 1.0 - exp(-speed * delta)
	var skin_transform := skin_pivot.global_transform
	skin_transform.basis = Basis(current.slerp(goal, t))
	skin_pivot.global_transform = skin_transform


func _facing_direction() -> Vector3:
	if _state != PlayerState.IDLE:
		return _action_dir
	if _lock_target != null and is_instance_valid(_lock_target):
		var to: Vector3 = (_lock_target as Node3D).global_position - global_position
		to.y = 0.0
		if to.length_squared() > 0.0001:
			return to.normalized()
	return _last_facing


# --- Death and respawn (driven by the HUD) -----------------------------------

## Locks the body during the death fade: no input, no actions, no lock-on, just
## gravity so the corpse stays planted until the HUD respawns it.
func set_dead(dead: bool) -> void:
	if dead == _dead:
		return
	_dead = dead
	if _dead:
		_state = PlayerState.IDLE
		_attack_request = ""
		_queued_attack = ""
		_parry_requested = false
		_dodge_requested = false
		_critical_target = null
		_critical_t = 0.0
		_end_swing()
		_clear_lock()
		velocity = Vector3.ZERO


func is_dead() -> bool:
	return _dead


## Restores health and stamina and clears every transient combat state so the
## body is fully fresh when the respawn fade lifts. The Health node is reset in
## place, so the HUD stays bound to the same component.
func reset_for_respawn() -> void:
	var health_node := get_node_or_null("Health") as Health
	if health_node != null:
		health_node.reset()
	stamina = max_stamina
	_stamina_regen_timer = 0.0
	_state = PlayerState.IDLE
	_attack_request = ""
	_queued_attack = ""
	_parry_requested = false
	_dodge_requested = false
	_critical_target = null
	_critical_t = 0.0
	_end_swing()
	_clear_lock()
	velocity = Vector3.ZERO


func _update_dead(delta: float) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z)
	h = h.move_toward(Vector3.ZERO, ground_friction * delta)
	velocity.x = h.x
	velocity.z = h.z
	if not is_on_floor():
		velocity.y -= gravity * delta
	move_and_slide()
