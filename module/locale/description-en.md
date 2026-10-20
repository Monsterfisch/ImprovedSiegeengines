# Improved Siegeengines

Version 1.0.2

The AI's siege engines in the unmodified game waste themselves: catapults roll up to the wall
they could have hit from far away, siege tents creep further out the longer a game goes until
the trebuchets cannot reach anything, siege towers stand around waiting for a wall the AI
considers good enough, and shields wander off after deer. This module fixes each of those.

Everything below can be switched on or off on its own. Only the AI's siege engines are
changed, except for where siege towers can dock, which helps the player's towers too.

## What it does

**Catapults and trebuchets pick their own targets.** An AI catapult or trebuchet looks all the
way round, as far as it can throw, for the nearest enemy wall, tower, gatehouse or other
building it can damage, and shoots it from where it stands. It only rolls closer when nothing
at all is in reach. (The game's own search looks one direction at a time and ignores walls
that have been shot down a bit, which is why catapults used to drive right up to the wall.)

**Siege tent spots are used again.** Once a spot's troop is gone, nothing stands on it and no
enemy soldier is close enough to attack an engine there, the AI can put a new tent on it. In
the unmodified game a spot stayed used for the rest of the game, which is why tents ended up so
far away in long games.

**Tents for ranged engines go by range.** Catapult, trebuchet and fire ballista tents go where
the engine can reach the castle: measured from the enemy's walls, towers and gatehouses, 0 to 10
tiles (a setting) short of the engine's range, so it can hit things further inside too.

**Siege towers dock at more walls.** Where the game finds no docking spot, a tower docks with its
corner against a diagonal wall, or at the same wall up to three tiles along.

**AI siege towers find their own wall.** An idle AI tower goes to the nearest enemy wall it can
dock at. When there is none, it walks with the army like a big shield until there is - with
the patrol troops, else the siege defence, else the main army, else the backup troops.

**Shields walk with their own troops.** AI shields go to the moat fillers first, then the ranged
siege engines, then the backup troops - never the main army, never anyone not on their side.
The shields are spread evenly over whoever is there; with nobody to walk with they stop and
wait where they are.

## Good to know

* Smarter Walls used to do the diagonal docking. Use Smarter Walls 1.0.16 or newer with this
  module - older versions change the same piece of the game and the two get in each other's way.
* Everyone in a multiplayer game needs this module with the same settings.
* Nothing is stored in save games.
