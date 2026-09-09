---
name: cascadia-souls
overview: >-
  Build a moody 3D soulslike set in a fractured Pacific Northwest: third-person
  stamina-driven melee combat with lock-on, perfect parry, and decaying PNW
  cyberpunk atmosphere.
createdAt: '2026-09-08T02:15:03.097Z'
todos:
  - id: base-movement-camera
    content: >-
      Build the minimum playable base: main.tscn with camera-relative
      third-person movement, SpringArm orbit camera, jump, and a moody foggy
      environment with ruined concrete blocks as scaffolding. Set main scene and
      bind input.
    status: completed
  - id: combat-core
    content: >-
      Add the soulslike combat core: lock-on targeting, light/heavy melee
      attacks, stamina system, health component with the canonical take_damage
      contract, and a test dummy with a hurtbox plus hit feedback.
    status: completed
  - id: enemy-parry
    content: >-
      Add one hostile enemy with telegraphed attacks, a perfect parry window
      with high-reward riposte, enemy death and respawn.
    status: completed
  - id: hud-atmosphere
    content: >-
      Add health/stamina/parry HUD, death and respawn loop, and push the
      lighting/fog pass toward the PNW cyberpunk decay mood.
    status: completed
  - id: assets-polish
    content: >-
      Add the player character skin with an animation state machine
      (idle/walk/run/attack), weapon mesh, VFX, audio ambience, and game-feel
      polish.
    status: completed
  - id: player-anim-arch
    content: >-
      Design and implement the player animation architecture, then integrate the
      Universal Base Character + animation library as the playable skin
      replacing the placeholder dwarf.
    status: in_progress
---
## Spine
- Example slice: `3d-game/third-person/third-person-adventure-slice` for the controller/camera architecture (camera-relative movement, SpringArm3D chase camera, SkinPivot model rotation).
- Combat contract: canonical `take_damage(amount, source) -> bool` health component from `common/damage-and-health/health-damage`, wired by hitbox/hurtbox Areas.

## Decisions
- 3D third-person soulslike (Bloodborne/Lies of P weight). GDScript.
- World forward is -Z. Camera hierarchy: CameraYaw/CameraPitch/SpringArm3D/Camera3D, roll always zero, horizontal mouse orbit with fixed modest downward pitch.
- Player: CharacterBody3D root with camera-relative WASD, jump, movement-owned translation (no root motion). Visual rotation lives on a SkinPivot child, never the body.
- Combat: stamina-gated light/heavy attacks, target lock-on, perfect parry timing window, ranged interrupt as a later tactical tool.
- Atmosphere: fog, cold muted colors, moss/rust materials, neon fragments as lighting accents. Primitives are scaffolding until assets land.

## Scene hierarchy (base)
```
main.tscn
  World (Node3D)
    WorldEnvironment (fog + sky, ACES tonemap)
    Sun (DirectionalLight3D, shadows)
    Ground (StaticBody3D + PlaneMesh/BoxMesh + collision)
    Ruins (StaticBody3D blocks - placeholder geometry)
    Player (CharacterBody3D)
      CollisionShape3D (capsule)
      SkinPivot (Node3D - visual placeholder capsule, rotation here)
      CameraYaw (Node3D)
        CameraPitch (Node3D, fixed -15 to -20 deg)
          SpringArm3D
            Camera3D
```

## Milestones
1. Base: movement + orbit camera + moody environment, main scene set, input bound. User can run around and feel the camera.
2. Combat core: lock-on, light/heavy attacks, stamina, health, test dummy.
3. Enemy + parry: telegraphed attacks, perfect parry, death/respawn.
4. HUD + atmosphere pass.
5. Character/asset polish (Asset Expert when reached).

## Verification per milestone
- Files written, main scene set, input actions bound, no script-errors in diagnostics.
- Ask user to Play and report feel. Never claim visual/behavior correctness from a compile alone.
