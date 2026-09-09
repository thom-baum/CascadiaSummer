extends Node3D
## Cascadia semantic player animator.
## Pure observer/representer for the player visual. It reads the player
## controller's public state each physics frame and plays the matching UAL
## clip on the character rig. It never changes gameplay state: the controller
## owns attacks, iframes, stamina, parry, and death.
##
## Clip mapping uses ONLY names verified by the runtime probe of the imported
## UAL libraries (see res://scenes/_anim_clips.txt). At runtime the animator
## loads UAL1/UAL2, extracts the mapped clips, rewrites their bone track paths
## onto this rig's Skeleton3D, and registers them in an AnimationLibrary owned
## by a player created here, so the exact verified clip names play on the UBC.

const UAL1_PATH := "res://assets/Universal Animation Library[Standard]/Unreal-Godot/UAL1_Standard.glb"
const UAL2_PATH := "res://assets/Universal Animation Library 2[Standard]/Unreal-Godot/UAL2_Standard.glb"

## Mirrors PlayerState in player_controller.gd (IDLE, ATTACK, DODGE, PARRY,
## CRITICAL).
const STATE_IDLE := 0
const STATE_ATTACK := 1
const STATE_DODGE := 2
const STATE_PARRY := 3
const STATE_CRITICAL := 4

## Emitted when the Spell_Simple_Shoot clip of a committed Critical Attack
## begins. The controller listens for it to land the critical damage and spawn
## the FX at the given world-space hand position.
signal critical_shoot_started(hand_world_position: Vector3)
## Emitted when the full critical clip chain (enter -> shoot -> exit) ends.
signal critical_sequence_finished

const BLEND_LOCOMOTION := 0.22
const BLEND_ACTION := 0.12

const WALK_SPEED := 0.6
const JOG_SPEED := 4.6

## Semantic state -> (library, verified clip name).
const CLIP_MAP := {
	"idle": {"lib": "ual1", "clip": "Idle"},
	"walk": {"lib": "ual1", "clip": "Walk"},
	"jog": {"lib": "ual1", "clip": "Jog_Fwd"},
	"sprint": {"lib": "ual1", "clip": "Sprint"},
	"light_1": {"lib": "ual2", "clip": "Sword_Regular_A"},
	"light_2": {"lib": "ual2", "clip": "Sword_Regular_B"},
	"light_3": {"lib": "ual2", "clip": "Sword_Regular_C"},
	"heavy": {"lib": "ual2", "clip": "Sword_Heavy_Combo"},
	"dodge": {"lib": "ual1", "clip": "Roll"},
	"parry": {"lib": "ual2", "clip": "Sword_Block"},
	"hit": {"lib": "ual1", "clip": "Hit_Chest"},
	"death": {"lib": "ual1", "clip": "Death01"},
	"jump": {"lib": "ual1", "clip": "Jump"},
	"jump_land": {"lib": "ual1", "clip": "Jump_Land"},
	"critical_enter": {"lib": "ual1", "clip": "Spell_Simple_Enter"},
	"critical_shoot": {"lib": "ual1", "clip": "Spell_Simple_Shoot"},
	"critical_exit": {"lib": "ual1", "clip": "Spell_Simple_Exit"},
}

@export var player_path: NodePath = ^"../../../Player"
@export var health_path: NodePath = ^"../../Health"
@export var character_root_path: NodePath = ^"CharacterVisual"
## Pacing for the committed Critical chain (enter -> shoot -> exit). A short
## windup pause after Enter before Shoot begins, and a beat after Shoot before
## Exit, make the sequence read as deliberate without dragging. The Shoot clip
## also plays slightly slowed so the blast moment lands clearly.
@export var critical_windup_hold: float = 0.3
@export var critical_shoot_beat: float = 0.35
@export var critical_shoot_speed: float = 0.85
## Time into the Sword_Block entry clip at which the held parry stance pins
## and pauses. Negative pins when the clip reaches its end pose (the committed
## guard), which is the safe default for any clip length.
@export var parry_hold_time: float = -1.0

var _player  # duck-typed reference to the player controller (no class_name)
var _health: Health = null
var _character_root: Node = null
var _skeleton: Skeleton3D = null
var _skeleton_path := NodePath()
var _anim_player: AnimationPlayer = null

var _current_target: String = ""
var _hit_override: bool = false
var _landing_override: bool = false
var _was_on_floor: bool = true
## Which part of the committed Critical chain is active. Guards the pacing
## timers so a stale timeout can never start the next clip after a bail or a
## death interrupt.
var _critical_stage: String = ""


func _ready() -> void:
	_player = get_node_or_null(player_path)
	if _player == null:
		push_warning("player_animator: player not found at " + str(player_path))
		return
	_health = get_node_or_null(health_path) as Health
	_setup_animation_player()
	if _anim_player == null:
		push_warning("player_animator: no AnimationPlayer; animation disabled")
		return
	if _health != null:
		_health.damaged.connect(_on_damaged)
	_anim_player.animation_finished.connect(_on_animation_finished)
	# Start on idle so the rig never rests in bind pose.
	_current_target = "idle"
	_play_clip(CLIP_MAP["idle"].clip, 0.0)


func _physics_process(_delta: float) -> void:
	if _player == null or _anim_player == null:
		return
	_update_landing()
	# Held parry stance: the parry clip is the ENTRY motion into the block
	# pose. Once playback reaches parry_hold_time (or the clip ends), pin the
	# AnimationPlayer to that pose and pause so the defensive stance persists
	# while the button is held; release/recovery blends back out to locomotion.
	if _player.has_method("is_parry_held") and _player.is_parry_held():
		if _current_target == "parry":
			var clip_len := _anim_player.get_current_animation_length()
			var hold_time := parry_hold_time if parry_hold_time >= 0.0 else clip_len
			hold_time = minf(hold_time, clip_len)
			if _anim_player.current_animation_position >= hold_time or not _anim_player.is_playing():
				_anim_player.seek(hold_time, true)
				_anim_player.pause()
	var target := _evaluate_target()
	if target != _current_target and (target == "death" or _is_action_target(target) or not _is_action_clip_playing()):
		_play_target(target)


## Committed action clips (attacks, dodge, parry) play to completion: while
## such a clip is still playing, do not let the animator switch to locomotion
## when the controller returns to IDLE (the gameplay window may end just
## before the clip finishes). Death always interrupts so the death animation
## can never be blocked by an action clip.
func _is_action_clip_playing() -> bool:
	if _anim_player == null or not _anim_player.is_playing():
		return false
	return _is_action_target(_current_target)

## Targets that are committed actions. Switching directly between actions
## (e.g. a queued combo chain or a future visceral follow-up) is allowed; the
## hold only prevents cutting out to locomotion before the clip finishes.
func _is_action_target(target: String) -> bool:
	return target == "dodge" or target == "parry" or target == "light_1" \
		or target == "light_2" or target == "light_3" or target == "heavy" \
		or target == "critical_enter" or target == "critical_shoot" or target == "critical_exit"


func _update_landing() -> void:
	var on_floor: bool = _player.is_on_floor()
	if not _was_on_floor and on_floor:
		_landing_override = true
	_was_on_floor = on_floor


func _evaluate_target() -> String:
	if _player.is_dead():
		return "death"
	var state: int = _player.get_state()
	if state == STATE_ATTACK:
		var attack_name: String = _player.get_attack_name()
		if attack_name != "":
			return attack_name
	elif state == STATE_DODGE:
		return "dodge"
	elif state == STATE_PARRY:
		return "parry"
	elif state == STATE_CRITICAL:
		# Hold whatever committed critical clip is playing; never cut the
		# chain to locomotion while the controller is locked in CRITICAL.
		if _current_target == "critical_enter" or _current_target == "critical_shoot" or _current_target == "critical_exit":
			return _current_target
		return "critical_enter"
	if _landing_override:
		return "jump_land"
	if _hit_override:
		return "hit"
	if not _player.is_on_floor():
		return "jump"
	var horizontal := Vector3(_player.velocity.x, 0.0, _player.velocity.z)
	var speed := horizontal.length()
	if _player.is_sprinting():
		return "sprint"
	if speed >= JOG_SPEED:
		return "jog"
	if speed >= WALK_SPEED:
		return "walk"
	return "idle"


func _play_target(target: String) -> void:
	_current_target = target
	if target != "hit":
		_hit_override = false
	if target != "jump_land":
		_landing_override = false
	var entry: Dictionary = CLIP_MAP[target]
	var blend := BLEND_ACTION
	if target == "idle" or target == "walk" or target == "jog" or target == "sprint" or target == "jump":
		blend = BLEND_LOCOMOTION
	_play_clip(entry.clip, blend)


func _play_clip(clip_name: String, blend: float, speed: float = 1.0) -> bool:
	var full := "Ual/" + clip_name
	if _anim_player.has_animation(full):
		_anim_player.play(full, blend, speed)
		return true
	return false


func _on_damaged(_amount: int, _current: int) -> void:
	if _player == null or _anim_player == null:
		return
	if _player.is_dead():
		return
	# Only show the hit reaction when the controller is idle, so an action
	# clip (attack/dodge/parry) is never misrepresented by a stagger.
	if _player.get_state() == STATE_IDLE:
		_hit_override = true


func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == &"Ual/Hit_Chest":
		_hit_override = false
	elif anim_name == &"Ual/Jump_Land":
		_landing_override = false
	elif anim_name == &"Ual/Spell_Simple_Enter":
		_on_critical_enter_finished()
	elif anim_name == &"Ual/Spell_Simple_Shoot":
		_on_critical_shoot_finished()
	elif anim_name == &"Ual/Spell_Simple_Exit":
		_critical_stage = ""
		_current_target = ""
		critical_sequence_finished.emit()


## Real clip durations plus exported pacing hold the committed sequence:
## Enter finishes, a short windup pause (critical_windup_hold), Shoot begins
## (the controller lands damage and spawns FX on the signal), the Shoot clip
## plays slightly slowed, a beat (critical_shoot_beat), then Exit begins. The
## player stays committed throughout: the controller only exits CRITICAL on
## critical_sequence_finished (or its own safety timeout).
func _on_critical_enter_finished() -> void:
	_critical_stage = "wait_shoot"
	get_tree().create_timer(critical_windup_hold).timeout.connect(_begin_critical_shoot)


func _begin_critical_shoot() -> void:
	if _critical_stage != "wait_shoot" or _player == null or _player.get_state() != STATE_CRITICAL:
		_critical_bail("critical aborted during windup hold")
		return
	_critical_stage = "shoot"
	if _play_clip(CLIP_MAP["critical_shoot"].clip, 0.0, critical_shoot_speed):
		critical_shoot_started.emit(_cast_hand_world_position())
	else:
		_critical_bail("critical_shoot clip missing")


func _on_critical_shoot_finished() -> void:
	_critical_stage = "wait_exit"
	get_tree().create_timer(critical_shoot_beat).timeout.connect(_begin_critical_exit)


func _begin_critical_exit() -> void:
	if _critical_stage != "wait_exit" or _player == null or _player.get_state() != STATE_CRITICAL:
		_critical_bail("critical aborted during shoot beat")
		return
	_critical_stage = "exit"
	if not _play_clip(CLIP_MAP["critical_exit"].clip, 0.0):
		_critical_bail("critical_exit clip missing")


## Safety for a failed/missing clip: release the commit so gameplay cannot
## wedge in CRITICAL waiting for a signal that never fires. Also clears the
## pacing stage so a stale hold timer cannot start the next clip afterwards.
func _critical_bail(reason: String) -> void:
	push_warning("player_animator: critical sequence aborted: " + reason)
	_critical_stage = ""
	_current_target = ""
	critical_sequence_finished.emit()


## World-space position of the rig's right hand (the spell-casting hand on
## the Spell_Simple clips). Used as the FX origin when the Shoot clip begins.
func _cast_hand_world_position() -> Vector3:
	if _skeleton != null:
		var bone_idx := _skeleton.find_bone(&"hand_r")
		if bone_idx != -1:
			var pose := _skeleton.get_bone_global_pose(bone_idx)
			return _skeleton.to_global(pose.origin)
	if _character_root != null and _character_root is Node3D:
		return (_character_root as Node3D).global_position + Vector3(0.0, 1.35, 0.0)
	return Vector3.ZERO


func _setup_animation_player() -> void:
	_character_root = get_node_or_null(character_root_path)
	if _character_root == null:
		push_warning("player_animator: character root not found at " + str(character_root_path))
		return
	_skeleton = _find_skeleton(_character_root)
	if _skeleton == null:
		push_warning("player_animator: no Skeleton3D under " + _character_root.name)
		return
	_anim_player = _find_animation_player(_character_root)
	if _anim_player == null:
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimatorPlayer"
		add_child(_anim_player)
	var anchor: Node = _anim_player.get_parent()
	_anim_player.root_node = NodePath("..")
	_skeleton_path = anchor.get_path_to(_skeleton)
	_build_library()
	_attach_weapon_to_hand()


func _build_library() -> void:
	var ual1: PackedScene = load(UAL1_PATH) as PackedScene
	var ual2: PackedScene = load(UAL2_PATH) as PackedScene
	if ual1 == null or ual2 == null:
		push_warning("player_animator: failed to load UAL libraries")
		return
	var lib := AnimationLibrary.new()
	for key in CLIP_MAP:
		var entry: Dictionary = CLIP_MAP[key]
		var packed: PackedScene = ual1 if entry.lib == "ual1" else ual2
		var clip := _extract_clip(packed, entry.clip)
		if clip == null:
			push_warning("player_animator: clip not found: " + str(entry.clip))
			continue
		_rewrite_tracks(clip)
		lib.add_animation(entry.clip, clip)
	_anim_player.add_animation_library(&"Ual", lib)


## Parents the HeldWeapon child onto the rig's right-hand bone so the hammer
## follows hand animations (idle, walk, attacks). Falls back silently to the
## original local placement if the bone is missing.
func _attach_weapon_to_hand() -> void:
	if _skeleton == null:
		return
	var weapon := get_node_or_null("HeldWeapon")
	if weapon == null:
		return
	var bone_idx := _skeleton.find_bone(&"hand_r")
	if bone_idx == -1:
		push_warning("player_animator: hand_r bone not found; weapon stays on PlayerVisualRoot")
		return
	var attach := BoneAttachment3D.new()
	attach.name = &"WeaponAttach"
	attach.bone_name = &"hand_r"
	_skeleton.add_child(attach)
	weapon.reparent(attach, false)
	# Grip offset from the wrist bone: small forward + slightly outward so the
	# handle sits in the palm. The hammer glb origin is near its head.
	weapon.position = Vector3(-0.03, 0.07, 0.0)
	weapon.rotation_degrees = Vector3(-90, 0, 180)
	weapon.scale = Vector3(2.2, 2.2, 2.2)
	# Axial roll: spin the hammer around its own handle axis (the model's local
	# +Y, confirmed by AABB probe - the 0.153-long axis). Post-multiplying the
	# basis rotates in model space, so the handle keeps pointing exactly where
	# the grip places it while the head twists a quarter turn around it.
	weapon.basis = weapon.basis * Basis(Vector3.UP, deg_to_rad(90.0))
	# P3: carry the player's melee hitbox with the weapon so it follows the
	# hammer during attack animations. The Area keeps its MeleeHitbox script,
	# layer/mask (8/16), and damage contract; the shape is centered on the
	# hand bone so the box sweeps through the target during the swing.
	if _player != null:
		var attack_area: Node3D = _player.get_node_or_null("AttackArea")
		if attack_area != null:
			attack_area.reparent(attach, false)
			attack_area.position = Vector3.ZERO
			attack_area.rotation = Vector3.ZERO
			var attack_shape: Node3D = attack_area.get_node_or_null("CollisionShape3D")
			if attack_shape != null:
				attack_shape.transform = Transform3D.IDENTITY
			attack_area.add_to_group(&"player_attack_area")


func _extract_clip(packed: PackedScene, clip_name: String) -> Animation:
	var instance := packed.instantiate()
	var clip: Animation = null
	if instance != null:
		var player := _find_animation_player(instance)
		if player != null and player.has_animation(clip_name):
			var source: Animation = player.get_animation(clip_name)
			if source != null:
				clip = source.duplicate(true) as Animation
		instance.free()
	return clip


## Rewrites every skeleton bone track so it resolves on THIS rig's Skeleton3D
## relative to the animator player root. Root/object tracks (no subname) are
## skipped: UAL standard clips are in-place skeleton clips.
func _rewrite_tracks(clip: Animation) -> void:
	if _skeleton_path.is_empty():
		return
	for i in range(clip.get_track_count()):
		var track_type := clip.track_get_type(i)
		if track_type != Animation.TYPE_POSITION_3D and track_type != Animation.TYPE_ROTATION_3D and track_type != Animation.TYPE_SCALE_3D:
			continue
		var track_path: NodePath = clip.track_get_path(i)
		var subname_count := track_path.get_subname_count()
		if subname_count == 0:
			continue
		var subnames := PackedStringArray()
		for si in subname_count:
			subnames.append(str(track_path.get_subname(si)))
		var new_path := str(_skeleton_path) + ":" + ":".join(subnames)
		clip.track_set_path(i, NodePath(new_path))


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null
