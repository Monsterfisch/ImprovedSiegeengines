# Improved Siegeengines

Version 1.0.19

The AI's siege engines in the unmodified game waste themselves: catapults roll up to the wall
they could have hit from far away, siege tents creep further out the longer a game goes until
the trebuchets cannot reach anything, siege towers stand around waiting for a wall the AI
considers good enough, and shields wander off after deer. This module fixes each of those.

Everything below can be switched on or off on its own. Only the AI's siege engines are
changed, except for where siege towers can dock, which helps the player's towers too.

## What it does

**Catapults and trebuchets pick their own targets.** An AI catapult or trebuchet looks all the
way round, as far as it can throw, for the nearest enemy wall, tower or gatehouse, and shoots
it from where it stands. Civilian buildings are only shot at once no fortification is in reach. It only rolls closer when nothing
at all is in reach. (The game's own search looks one direction at a time and ignores walls
that have been shot down a bit, which is why catapults used to drive right up to the wall.)

**Catapults and trebuchets stop to shoot on the way.** The game only looks for a target while a
siege engine stands still, so AI catapults on a raid, marching with the army or creeping towards
the walls rolled past everything in range. Now a walking AI catapult or trebuchet looks all round
every few moments and stops to shoot as soon as an enemy wall, tower, gatehouse or building is in
its range.

**On to the next opponent.** A catapult or trebuchet only aims at the player its army was sent
against. Once that player is beaten (his lord is dead), it shoots at any other enemy in range
instead of standing idle.

**Other enemies in reach.** When nothing of the player it was sent against is in reach, a
catapult or trebuchet shoots other enemies' walls and buildings in reach instead of rolling past
them. The besieged player's still come first. Buildings that are already destroyed are never
aimed at.

**No more shooting at ruins.** A siege engine aiming at a building - a fire ballista at
something that burns, or a catapult ordered at a building - went on shooting the empty spot once
that building was destroyed, and never moved on. That was the game checking only the building's
number, which stays the same until another building takes it. Now a destroyed target is dropped
and the engine picks a new one. This covers fire ballistas too.

**Better aim.** The game lets an AI catapult's rock land up to 12 tiles short of its target and 6
to the side, so at long range most rocks hit open ground in front of the wall. The miss is now
halved and centred on the target (a setting; 100% keeps the game's aim). Your own engines aim as
before.

**Siege tent spots are used again.** Once a spot's troop is gone, nothing stands on it and no
enemy soldier is close enough to attack an engine there, the AI can put a new tent on it. In
the unmodified game a spot stayed used for the rest of the game, which is why tents ended up so
far away in long games.

**Tents for ranged engines go by range.** Catapult, trebuchet and fire ballista tents go where
the engine can reach the castle: measured from the enemy's walls, towers and gatehouses, 0 to 10
tiles (a setting) short of the engine's range, so it can hit things further inside too.

**Engineers always get into their tent.** When a tent's entrance is blocked it moves to a free
side, and engineers that gave up on a tent - or got stuck on the way - are sent again, with idle
engineers nearby filling in. A tent walled in completely gets its engineers as soon as a way
opens.

**Siege towers dock at more walls.** Where the game finds no docking spot, a tower docks with its
corner against a diagonal wall, or at the same wall up to three tiles along.

**AI siege towers find their own wall.** An idle AI tower goes to the nearest enemy wall it can
dock at (within 100 tiles). When there is none, or the way there gets it nowhere, it walks with
the army like a big shield until there is - with
the patrol troops, else the siege defence, else the main army, else a randomly picked ranged
troop of the attacking army, and only when none of those are left the backup troops.

**Shields walk with their own troops.** AI shields go to the moat fillers, the attacking army's
ranged siege engines (never the ones defending the AI's own castle) and its ranged troops,
spread evenly over them. The backup troops only get shields once none of those are left; with
nobody at all a shield stops and waits where it is.

**Oil engineers pour on ground.** Engineers - yours too - only pour oil where it can burn: open
ground, never a wall, stairs or tower, where the unmodified game's oil simply fizzled. On their own
they only pour on an enemy standing on such ground. Sent at a spot that is not, an engineer pours
on the nearest ground no more than 45 degrees off his line to it, or keeps his oil and says
"impossible location".

**Oil spreads by its amount.** One pot's oil runs out tile by tile over a set number of tiles (41, a
setting), starting where the engineer aimed: a pool in the open, a long streak down a narrow
passage. It burns like a lit pitch ditch, tall flames all over in a random mix of sizes. Buildings the game's fire can
set alight (from hovels and workshops to the armoury, church and cathedral) don't catch fire but
lose up to a third of their health, most right at the landing spot; walls, towers, gatehouses and
keeps are not hurt.

## Good to know

* Smarter Walls used to do the diagonal docking. Use Smarter Walls 1.0.16 or newer with this
  module - older versions change the same piece of the game and the two get in each other's way.
* Everyone in a multiplayer game needs this module with the same settings.
* Nothing is stored in save games.
