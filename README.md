# Improved Siegeengines

A UCP3 module for Stronghold Crusader that makes the AI use its siege engines properly:
catapults and trebuchets shoot from range instead of rolling up to the wall, siege tents stop
drifting away in long games and are placed by the engine's range, siege towers find walls to
dock at (diagonal ones too) or walk with the army until they can, and portable shields stay
with their own troops. The player-facing description is in
[module/locale/description-en.md](module/locale/description-en.md).

## What is in here

| Path | What |
| --- | --- |
| `module/` | the module itself (`init.lua`, `templates.lua`, options and texts) |
| `tools/publish.py` | copy `module/` into the game's `ucp/modules/improved-siegeengines-<version>` |
| `tools/check_sites.py` | every AOB, expected byte and operand, checked against both exes |
| `tools/check_static.py` | lua syntax, and every asm script assembled with UCP's own fasm.dll |

## Working on it

1. Edit `module/`, bump `module/definition.yml` (and the version line in the description).
2. `python tools/check_sites.py` and `python tools/check_static.py` - both must say ALL OK.
3. With the game closed: `python tools/publish.py`, then F5 and apply in the UCP3 GUI.

## How it works

* **Catapults**: one hook in `harassBuildingsWithSiegeAI` where the game starts its own
  direction-by-direction search; a ring scan out to the engine's range (from the game's range
  table) for the nearest enemy wall or damageable building, shot through the game's own path.
* **Tents**: wrappers on `placeSiegeTentAtAttackAngle` and
  `placeSiegeTentOrTunnelAtSuitableLocation` set a distance band for ranged engines; the spot
  test in `algFindAttackAngle` and the layer test in `findAppropriateLocationForSiegeTent`
  check it against a chamfer distance map from the attacked castle's walls and fortifications.
  The spot test also frees spots whose troop is gone, whose 3x3 is clear and that no enemy
  troop can reach.
* **Docking**: `findFreeTileNearby` wrapped - the game's spot, then a diagonal corner dock,
  then the same wall up to three tiles along, in a fixed order.
* **Shields and towers**: the game's shield and tower branches in `aiCommandSiegeEngineTribes`
  are skipped; at its end the AI's shields, towers and ranged engines are collected in asm and
  lua gives the orders.
