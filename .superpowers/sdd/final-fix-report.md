# Final Fix Report — Whole-Branch Important Findings

## Status

Complete.

## Fixes

1. **Placement ghosts not hostile / attackable**
   - `BuildingAgent.take_damage` no-ops when `is_placement_ghost`
   - AI `_nearest_hostile_in_radius`, `UnitAgent.command_attack`, selection enemy pick skip ghosts (`== true` so missing props stay safe)
   - `BuildSystem.cancel_placement` / `_process` tolerate externally freed ghosts

2. **Carry type on gather switch**
   - `UnitAgent.command_gather`: if `carry_amount > 0` and new resource type differs, drop off current then gather the new node (`_last_resource` + `_begin_drop_off`)

3. **Winner freezes player simulation**
   - `MatchState.frozen` set in `set_winner`
   - `UnitAgent` / `BuildingAgent` `_physics_process` early-return when frozen
   - HUD disables physics on **all** entities (not AI-only)

## Verification

```
Godot_v4.7.1-stable --path aoe2 --headless -s res://tests/run_tests.gd
→ ALL TESTS PASSED
```

Extended coverage: ghost damage/attack refusal, AI hostile skip, cancel after free, gather type-switch drop-off, `MatchState.frozen`, player unit freeze after winner.

## Commit

`fix: harden ghosts gather switch and match freeze`

## Concerns

- Ghosts still live under `Entities` until cancelled; overlap checks intentionally include them.
- Drop-off-then-gather on type switch can briefly look idle if no drop-off exists (order clears).
