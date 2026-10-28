--[[
  Improved Siegeengines

  Four changes to how the AI uses siege engines, each switchable on its own:

  1. Catapults and trebuchets pick their own targets. The game's own search only looks one
     direction at a time and only at walls standing tall; when it finds nothing the engine
     rolls on towards the castle until it stands in front of the wall. Now the engine first
     looks all round, as far as it can throw, for the nearest enemy wall, tower, gatehouse or
     building, and shoots that from where it stands.
     The game only ever looks for a target when an engine stands idle: one that walks - to a
     raid's target, with the army, forward in the AI's siege steps - passes everything in range.
     Now a walking AI catapult or trebuchet runs the same search every 16 ticks, and when it
     finds something it stops and goes idle, where the game's own target choice (with the
     search above) shoots it.
     The search is for the engine's siege target player only; once that player's lord is dead
     it takes any enemy, so the engines go on with the next opponent.

  2. Siege tents. Every tent spot the AI ever used stayed marked as used for the rest of the
     game, so in a long game the tents went further and further out. A spot is free again
     once its troop is gone, nothing stands on it and no enemy that could hit an engine there
     is in reach. Tents for catapults, trebuchets and fire ballistas go where the engine can
     reach the castle: 0 to `variation` tiles short of its range from the castle's walls and
     towers, picked a bit differently for each tent.

  3. Siege towers. A tower docks where the game would, else with its corner against a
     diagonal wall, else at the same wall up to three tiles along. The AI no longer waits for
     its own list of "good walls": an idle tower looks for the nearest enemy wall it can dock
     at, and when there is none it walks with the army's patrol troops (or the main army) like
     a big shield until there is.

  4. Portable shields walk with the AI's own troops only: the moat fillers first, then the
     ranged siege engines, then the backup troops - never the main army, never a deer. More
     shields than places are spread evenly; with nobody to walk with they wait.

  Only the AI's siege engines are changed, except the docking in 3, which every tower uses.
]]

local templates = require("templates")

local MODULE_NAME = "improved-siegeengines"

local DEFAULTS = {
  catapults = { enabled = true, on_the_way = true, other_enemies = true, scatter = 50,
    drop_destroyed = true },
  tents = { free = true, range = true, variation = 10, engineers = true },
  towers = { dock = true, orders = true },
  shields = { enabled = true },
  oil = { aim = true, spread = true, amount = 41, damage = true },
  diagnostics = { log = false },
}

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module reads it
---------------------------------------------------------------------------------------

-- harassBuildingsWithSiegeAI(unit): an AI catapult, trebuchet or fire ballista choosing what
-- to throw at. The same layout in both executables.
local AOB_HARASS = "83 EC 10 53 55 56 57 8B 7C 24 24 8B C7 69 C0 90 04 00 00"
local HARASS_HOOK = { 0x1BB, { 0xBB, 0x15, 0x00, 0x00, 0x00 } }   -- mov ebx, 0x15
-- The building-target branch: mov edx, [ecx + uid] / cmp edx, [esi + 0x9B4] / jne lost.
local HARASS_UID = { 0xDC, { 0x8B, 0x91 } }
local HARASS_TARGET_CHECK = { 0xE2, { 0x3B, 0x96, 0xB4, 0x09, 0x00, 0x00, 0x75, 0x4C } }
local HARASS_TARGET_BACK = 0xEA
local HARASS_TARGET_LOST = 0x136
local HARASS_HOOK_SIZE = 5
local HARASS_RESULT = { 0x1C0, { 0xC7, 0x05 } }                     -- mov [ALG_ResultTile2], 0
local HARASS_TARGET_X = { 0x306, { 0x8B, 0x3D } }                   -- mov edi, [ALG_TargetX]
local HARASS_TARGET_Y = { 0x30C, { 0x8B, 0x15 } }                   -- mov edx, [ALG_TargetY]
local HARASS_SHOOT = 0x306
local HARASS_MAP_ORIENTATION = { 0x2EA, { 0x2B, 0x05 } }  -- sub eax, [map orientation]                                          -- ... and on to the shot

-- findBestAttackTargetTileWithHeightAndOwner: the building array and the "can be damaged" table.
local AOB_CONE = "83 EC 24 83 C8 FF 55 56 8B F1 89 44 24 18"
local CONE_TYPE = { 0x24E, { 0x0F, 0xBF, 0x8F } }                   -- movsx ecx, [edi + type]
local CONE_HEALTH = { 0x255, { 0x83, 0x3C, 0x8D } }                 -- cmp [ecx*4 + table], 0
local CONE_OWNER = { 0x263, { 0x0F, 0xBF, 0x97 } }                  -- movsx edx, [edi + owner]

-- acquireShootTarget: the range of every projectile, in tiles - the only code that reads the
-- table. The Rebalancer replaces that instruction with a jump to its own per-unit ranges, which
-- read the same table again: then it is found in the code the jump leads to.
local AOB_ACQUIRE = "83 EC 40 53 56 57 8B 7C 24 50 69 FF 90 04 00 00 8B F1 0F BF 84 37 AA 06 00 00"
local ACQUIRE_RANGE = 0x131
local RANGE_READ = { 0x8B, 0x04, 0x85 }      -- mov eax, [eax*4 + ranges]
local RANGE_SEARCH = 0x100                   -- how far into a replacement to look for it

-- placeSiegeTentsAndAssignEngineers: the two ways a siege tent is placed.
local AOB_TENTS = "83 EC 10 89 4C 24 08 8B 4C 24 14 0F BE 81 ? ? ? ?"
local TENTS_ANGLE_CALL = 0x2DE              -- call placeSiegeTentAtAttackAngle
local TENTS_SUIT_CALL = 0x2FA               -- call placeSiegeTentOrTunnelAtSuitableLocation
local TENT_PROLOGUE = { 0x53, 0x8B, 0x5C, 0x24, 0x08 }   -- push ebx; mov ebx, [esp+8]
local ANGLE_FIND_CALL = 0x37                -- call algFindAttackAngle
local SPOT_HOOK = { 0x1A1, { 0x8B, 0xC8, 0xC1, 0xE1, 0x05, 0x83, 0xB9 } }
local SPOT_HOOK_SIZE = 0x1B
local SPOT_THREE = 0x1A8                    -- cmp [ecx + spots.three], 0
local SPOT_TRIBE = { 0x1AF, { 0x83, 0xB9 } } -- cmp [ecx + spots.tribeID], 0
local SPOT_FOUND = { 0x1B6, { 0x0F, 0x84 } } -- je <return the spot>

-- findAppropriateLocationForSiegeTent: the test of the AI's distance layer.
local AOB_LOCATION = "83 EC 0C 55 56 57 8B 7C 24 20"
local LOCATION_HOOK = { 0x15F, { 0x83, 0x7C, 0x24, 0x30, 0x00, 0x8B, 0xC3, 0x74, 0x26 } }
local LOCATION_HOOK_SIZE = 0x2F
local LOCATION_ATTACKED = { 0x172, { 0x8B, 0x9B } }
local LOCATION_LAYER = { 0x17E, { 0x0F, 0xB6, 0x9C, 0x33 } }

-- useAITribe_0x12_toPlaceSiegeTentsAndAssignEngineers: siege engine unit types and the
-- building type of each one's tent.
local AOB_ENGINEERS = "83 EC 18 8B D1 8B 4C 24 1C 69 C9 F4 39 00 00"
local ENGINEERS_UNIT_TYPES = { 0x110, { 0x3B, 0x0C, 0x85 } }
local ENGINEERS_TENT_TYPES = { 0x12E, { 0x8B, 0x1C, 0x85 } }

-- aiCommandSiegeEngineTribes(player): towers, rams and shields, once per AI round.
local AOB_COMMAND = "83 EC 14 53 55 56 8B 74 24 24 8B C6"
local CMD_TRIBE_IDS = { 0x18, { 0x0F, 0xBF, 0x81 } }
local CMD_STRIDE = { 0x36, { 0x69, 0xDB } }
local CMD_UNITS = { 0xB6, { 0xBB } }                 -- mov ebx, units[1].type
local CMD_TOWER = { 0x105, { 0x0F, 0xBF, 0x83, 0x4A, 0x02, 0x00, 0x00 } }
local CMD_WIDE = { 0x11C, { 0x83, 0xBA } }           -- the AI's walls for towers and rams
local CMD_TRIBES = { 0x12F, { 0xB9 } }
local CMD_ASSIGN = { 0x134, { 0xE8 } }               -- call assignAttackTargetsForTribe
local CMD_SHIELD = { 0x19F, { 0x0F, 0x85 } }         -- jne <next unit>
local CMD_FOLLOW = { 0x1C9, { 0x66, 0x89, 0x86 } }
local CMD_FOLLOW_UID = { 0x1DC, { 0x89, 0x96 } }
local CMD_LEADER = { 0x1E2, { 0x0F, 0xBF, 0xB8 } }
local CMD_BACKLINK = { 0x1EF, { 0x66, 0x89, 0x88 } }
local CMD_MOVE = { 0x22A, { 0xE8 } }                 -- call giveTribeMoveInstruction
local CMD_DIRECTIONS = { 0x241, { 0xB9 } }       -- mov ecx, DirectionAlgorithmState
local CMD_ORIENT = { 0x246, { 0xE8 } }           -- call calculatePreferredRelativeOrientation
local CMD_ORIENTATION = { 0x24B, { 0x66, 0x8B, 0x15 } }   -- mov dx, [ALG_Orientation]
local CMD_NEXT = 0x265                               -- add ebx, 0x490: the next unit
local CMD_LAST = { 0x26B, { 0x81, 0xFB } }           -- cmp ebx, units[last].type
local CMD_EPILOGUE = { 0x27B, { 0x5F, 0x5E, 0x5D, 0x5B, 0x83, 0xC4, 0x14, 0xC2, 0x04, 0x00 } }
local CMD_EPILOGUE_SIZE = 7

-- UnitsState::findFreeTileNearby(unit, wallTile): where a siege tower stands to dock. Found
-- past its first nine bytes, which are the ones a module hooking it rewrites.
local AOB_FREE_TILE = "56 69 ED 90 04 00 00 8B 85 ? ? ? ? 0F BF 1C 45"
local FREE_TILE_START = -9
local FREE_TILE_PROLOGUE = { 0x83, 0xEC, 0x10, 0x53, 0x55, 0x8B, 0x6C, 0x24, 0x1C }
local FREE_TILE_SIZE = 9
local FREE_TILE_PF = { 0x5A, { 0xB9 } }
local FREE_TILE_NAVIGATE = { 0x67, { 0xE8 } }

-- giveTribeAnInstruction, sending engineers into a siege building: its entrance test (which moves
-- a blocked entrance), and the two calls that take the engineer out of the selection.
local AOB_INSTRUCTION = "83 EC 1C 8B 44 24 20 69 C0 ? ? 00 00 53 8B 5C 24 30 55 8D 2C 08 33 D2 56 0F BF 75 5C"
local INSTRUCTION_ENTRANCE = 0x1D1F        -- call resolveBuildingEntryAccessibility
local INSTRUCTION_DESELECT = 0x1DC5        -- call deselectUnit
local INSTRUCTION_UNSELECT = 0x1DDA        -- call clearOrDeselectUnitFromSelection

-- UpdateEngineer: how many engineers a siege building needs.
local AOB_UPDATE_ENGINEER = "51 8B 0D ? ? ? ? 8B C1 69 C0 90 04 00 00 83 3D ? ? ? ? 00"
local ENGINEER_REQUIRED = 0x10FD           -- call getRequiredEngineerCountForSiegeBuilding

-- The oil engineers' code sites, in one table (the main chunk is near Lua's 200 locals).
local OILAT = {
  -- UpdateEngineer, pouring oil (state 0xA, the frame the pot is emptied) and the end of it.
  ENGINEER_POUR = { 0x19B0, { 0x66, 0x89, 0xB0 } },      -- mov [eax + resourceToDeposit], si
  ENGINEER_POUR_SIZE = 7,
  ENGINEER_EPILOGUE = { 0x1A30, { 0x5F, 0x5E, 0x5D, 0x5B, 0x59, 0xC3 } },

  -- ifNecessaryThrowOilAutomatically: taking an enemy as the target of an automatic pour.
  AOB_AUTO_OIL = "83 EC 0C 56 8B 74 24 14 69 F6 90 04 00 00",
  AUTO_OIL_TAKE = { 0x229, { 0x66, 0xC7, 0x86 } },      -- mov word [esi + targeting], 0x14
  AUTO_OIL_TAKE_SIZE = 9,
  AUTO_OIL_FAIL = { 0xB7, { 0x5B, 0x5F, 0x33, 0xC0 } },  -- pop ebx / pop edi / xor eax, eax

  -- The oil pot's entity: where it lands it calls the fire function (owner, mx, my, z, 5).
  AOB_OIL_POT = "A1 ? ? ? ? ? ? ? ? 00 00 0F B7 88 ? ? ? ? 66 83 F9 0E",
  OIL_POT_FIRE = 0xFC,
  FIRE_AT = { 0x4B, { 0x81, 0xF9, 0x8F, 0x01, 0x00, 0x00 } },   -- past the random nudge
  FIRE_STRENGTH = { 0x1A0, { 0x66, 0x89, 0x91 } },   -- mov [ecx + fire.strength], dx
  -- updateEntities, once a tick: the oil flows on from here
  AOB_ENTITIES = "51 53 55 56 8B F1 8B 0D",
  ENTITIES_PROLOGUE = { 0x00, { 0x51, 0x53, 0x55, 0x56, 0x8B, 0xF1 } },
  ENTITIES_PROLOGUE_SIZE = 6,
  OIL_STEP = 3,            -- ticks the oil takes from one tile to the next
  OIL_EVENTS = 1024,       -- queued fires and damage, all pots together
  OIL_REACH = 5,           -- tiles the game's own oil fire (strength 5) covers by itself
  OIL_SEED_GAP = 3,        -- beyond that, a further fire every this many tiles along the oil
  OIL_SEED = 3,            -- of this strength (it spreads 2 tiles each way)
  -- the "can it burn" test, as the siege engines' target search calls it
  CONE_FLAMMABLE = 0x281,

  -- giveMoveCommand: the "impossible location" line (playUnitSpeech(type, 9)) for the local player.
  AOB_MOVE_COMMAND = "83 EC 08 8B 44 24 10 8B 54 24 18",
  MOVE_LOCAL_PLAYER = { 0x16C, { 0x3B, 0x15 } },
  MOVE_SFX = { 0x22B, { 0xB9 } },
  MOVE_SPEECH = 0x230,
  SPEECH_IMPOSSIBLE = 9,

  -- TileMapState::processDamageToBuilding(tile, x, y, damage, 0, player, 0, unit)
  AOB_BUILDING_DAMAGE = "83 EC 0C 53 55 56 8B 74 24 30",
}

-- UpdateCatapult: its call of setDestinationForUnit. Several modules hook that function's own
-- first bytes, so it is found through a call (and called through their hooks).
local AOB_UPDATE_CATAPULT = "83 EC 74 53 8B 1D ? ? ? ? 55 56"
local CATAPULT_SET_DESTINATION = 0x87F
local AOB_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local TEAMS_OPERAND = 0x03
local AOB_TICKS = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15"
local TICKS_OPERAND = 0x0E
local AOB_TILE_FLAGS = "F7 04 9D ? ? ? ? 00 01 00 00"
-- updateUnits, where it calls each unit's update function from the table by unit type
-- (smarter-recruits patches the 8 bytes before this), and the current unit before that.
local AOB_UPDATE_CALL = "0F BF 91 A2 06 00 00 8B 04 95 ? ? ? ? FF D0"
local UPDATE_TABLE = { 0x07, { 0x8B, 0x04, 0x95 } }
local UPDATE_CURRENT_AT = -0x19
local UPDATE_CURRENT_BYTE = { 0xA1 }
-- UnitsState::stopWalking(unit): clears a unit's path (what the game's attack orders call).
local AOB_STOP_WALKING = "8B 44 24 04 69 C0 90 04 00 00 03 C1 33 C9 66 89 88 ? ? 00 00 66 89 88 ? ? 00 00 "
  .. "66 89 88 ? ? 00 00 66 89 88 ? ? 00 00 C2 04 00"
local TILE_FLAGS_OPERAND = 0x03

---------------------------------------------------------------------------------------
-- Layouts (the same in both executables unless read from code above)
---------------------------------------------------------------------------------------

local U = { STRIDE = 0x490, STATE = 0x8C, TYPE = 0x8E, OWNER = 0x96, UID = 0x98, TARGET_UID = 0xA0,
  X = 0xC4, Y = 0xC6, DEPOSIT = 0x388,
  TILE = 0xD4, DYING = 0x2A0, ORDER_STATE = 0x2C0, TRIBE = 0x2D8, TARGET = 0x336,
  TARGETING = 0x39C, WALL_TILE = 0x3A8, DOCK_TILE = 0x3B8, SIEGE_BYTE = 0x3FE, WALL_X = 0x3E8,
  WALL_Y = 0x3EA, COOLDOWN = 0x3BC, SIEGE_TARGET = 0x432, BEHAVIOUR = 0x42A, STATE_OFFSET = 0x614 }
local P = { STRIDE = 0x39F4, HAS_KEEP = 0x94, KEEP_TILE = 0x1E0, LORD = 0x21F8, LORD_UID = 0x21FC,
  AI_TYPE = 0x2300, ATTACKED = 0x2BD8,
  TRIBE_IDS = 0x310C, TRIBE_UIDS = 0x329C }
local T = { OWNER = 0x2C, UID = 0x34, STATE = 0x40, LEADER = 0x5A }
local MAP = { HEIGHT = 0x29FA30, FLAGS = 0x165160, WALL_OWNER = 0x2C6E50, AREA = 0x363ED0, Y_OF_TILE = 0x742B90,
  ROWS = 0x8A40F8, VALID = 0x71BA90, BUILDINGS = 0x2029B0, UNITS = 0x23D7E0 }
local B = { STRIDE = 0x32C, STATE = 0xD0, TYPE = 0xD2, OWNER = 0xD6, UID = 0xD8, X = 0xEE, Y = 0xF0,
  MAX_HEALTH = 0x10E,
  ENTRY_X = 0xFE, ENTRY_Y = 0x100, WORKERS = 0x19A, STATE_OFFSET = 0x14 }

local TILES = 0x13A10
local MAX_TRIBES = 1251          -- 1250 troops, in both executables
local MAX_THREATS = 4000
local MELEE_REACH = 10
-- Added to a civilian building's distance in the catapults' search: any fortification in reach
-- comes first.
local CIVILIAN_PENALTY = 0x1000000
-- Added for a wall or building of another enemy than the besieged player: his come first.
local OTHER_PENALTY = 0x2000000
-- A ranged engine's tent stands this many tiles inside its reach: the tent's own 3x3 and the
-- tile or two the engine rolls out beside it, so even the far end of the band is in range.
local TENT_MARGIN = 6
local TOWER_RADIUS = 100
local TOWER_TESTS = 32
local WIDE_STRIDE = 0x177BC

local UT = { LORD = 55, ENGINEER = 30, SHIELD = 60, TOWER = 58, CATAPULT = 39, TREBUCHET = 40, MANGONEL = 41, FIRE_BALLISTA = 77 }
local RANGED_ENGINES = { [39] = true, [40] = true, [41] = true, [77] = true }

-- Troop slots in the AI's attack troop list (aiTribeIDs).
local SLOT_DIGGERS = { 0x11 }
local SLOT_BACKUP = { 0xBA, 0xBB, 0xBC }
local SLOT_PATROL = { 0x0F, 0x10 }
local SLOT_SIEGEDEF = { 0xBE, 0xBF }
local SLOT_MAIN = { 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7 }
-- Every attack troop slot but the backup troops: where the attacking army's ranged troops are.
-- The backup troops only get shields and towers once none of those are left.
local SLOT_ATTACK = { 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xBE, 0xBF, 0x0C, 0xBD,
  0x0F, 0x10 }
-- Archers, crossbowmen, Arab archers, slingers, horse archers, fire throwers.
local RANGED_TROOPS = { [22] = true, [23] = true, [70] = true, [72] = true, [74] = true, [76] = true }

-- Who could hit a siege engine: a projectile id (its reach is the game's range table) or melee.
local MELEE = 0xFF00
local THREAT_KIND = {
  [22] = 1, [23] = 7, [70] = 1, [72] = 0x21, [74] = 1, [76] = 0x22,       -- ranged troops
  [24] = MELEE, [25] = MELEE, [26] = MELEE, [27] = MELEE, [28] = MELEE, [37] = MELEE,
  [55] = MELEE, [71] = MELEE, [73] = MELEE, [75] = MELEE,
}

-- The castle a ranged engine's tent is measured from and its engines shoot first: walls plus
-- these fortified buildings (gatehouses, drawbridge, towers). The keep's doors (71-73) are left
-- out - they cannot be destroyed.
local FORTIFICATIONS = { 45, 46, 47, 48, 49, 60, 61, 74, 75, 76, 77, 78 }

local ORDER_WALL, STATE_TO_WALL, STATE_DOCKING = 0x17, 0x65, 8
local STATE_IDLE, STATE_TO_TENT = 0, 8
local ENGINEER_RADIUS = 60       -- idle engineers this close to a tent may be sent into it
local STUCK_ROUNDS = 3           -- AI rounds an engineer may stand still on its way to a tent
local KIND_TOWER_WALLS = 0x414

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local rd32, wr32 = core.readInteger, core.writeInteger

local function u16(address) return core.readSmallInteger(address) & 0xFFFF end
local function s16(address)
  local value = u16(address)
  if value >= 0x8000 then value = value - 0x10000 end
  return value
end
local function wr16(address, value) core.writeSmallInteger(address, value & 0xFFFF) end
local function byte(address) return core.readByte(address) & 0xFF end

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(string.format("could not find %s", purpose), 0)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, value in ipairs(bytes) do
    if byte(address + index - 1) ~= value then
      error(string.format("%s at 0x%X is not the code this module knows", purpose, address), 0)
    end
  end
end

local function operand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return rd32(base + site[1] + #site[2])
end

local function relative(at)
  return (at + 5 + rd32(at + 1)) & 0xFFFFFFFF
end

local function callTarget(at, purpose)
  expectBytes(at, { 0xE8 }, purpose)
  return relative(at)
end

local function matches(address, bytes)
  for index, value in ipairs(bytes) do
    if byte(address + index - 1) ~= value then return false end
  end
  return true
end

-- The projectile range table: read where the game reads it, or where whoever replaced that
-- instruction with a jump reads it now.
local function rangeTable(acquire)
  local at = acquire + ACQUIRE_RANGE
  if matches(at, RANGE_READ) then return rd32(at + #RANGE_READ) end
  if byte(at) == 0xE9 then
    local code = relative(at)
    for offset = 0, RANGE_SEARCH do
      if matches(code + offset, RANGE_READ) then return rd32(code + offset + #RANGE_READ) end
    end
  end
  error(string.format("the range table at 0x%X is not read the way this module knows", at), 0)
end

-- FASM gets a fixed 64 KB for source, symbols and output: strip the script, pass only what it
-- uses. Local labels (".name") become plain ones; every script is assembled on its own.
local function assemble(script, values)
  local lines = {}
  for line in script:gmatch("[^\n]+") do
    line = line:gsub(";.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then lines[#lines + 1] = line end
  end
  local text = table.concat(lines, "\n"):gsub("%.(%a[%w_]*)", "L_%1") .. "\n"
  local used = {}
  for name, value in pairs(values) do
    if text:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(text, used)
end

local function jumpCode(address, target, size)
  local code = { 0xE9, core.itob(core.getRelativeAddress(address, target, -5)) }
  for _ = 6, size do code[#code + 1] = 0x90 end
  return code
end

local function setting(config, group, name)
  local section = type(config) == "table" and config[group] or nil
  if type(section) == "table" and section[name] ~= nil then
    if type(DEFAULTS[group][name]) == "boolean" then return section[name] == true end
    return section[name]
  end
  return DEFAULTS[group][name]
end

local function number(config, group, name, low, high)
  local value = tonumber(setting(config, group, name)) or DEFAULTS[group][name]
  value = math.tointeger(math.floor(value)) or DEFAULTS[group][name]
  return math.max(low, math.min(high, value))
end

-- A cdecl function with no arguments that runs `callback` in lua.
local function luaFunction(purpose, callback)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  local reported = false
  core.detourCode(function(registers)
    local ok, message = pcall(callback)
    if not ok and not reported then
      reported = true
      log(WARNING, string.format("%s: %s failed: %s", MODULE_NAME, purpose, tostring(message)))
    end
    return registers
  end, pad, 5)
  return pad
end

---------------------------------------------------------------------------------------
-- The module's state
---------------------------------------------------------------------------------------

local G = {}           -- addresses
local F = {}           -- game functions callable from lua
local O = {}           -- options
local patched = {}     -- { address, original bytes }, in the order written

local function patch(address, code, size)
  patched[#patched + 1] = { address = address, bytes = core.readBytes(address, size) }
  core.writeCode(address, code)
end

local function diag(format, ...)
  if O.log then log(INFO, MODULE_NAME .. ": " .. string.format(format, ...)) end
end

---------------------------------------------------------------------------------------
-- Troops, units and tribes
---------------------------------------------------------------------------------------

local function unitAt(index) return G.units + index * U.STRIDE end

local function unitAlive(index)
  if index <= 0 or index >= G.maxUnits then return false end
  local a = unitAt(index)
  return u16(a + U.STATE) == 2 and u16(a + U.DYING) == 0
end

local function tribeAt(tribe) return G.tribes + tribe * G.tribeStride end

local function tribeAlive(tribe)
  return tribe > 0 and tribe < MAX_TRIBES and u16(tribeAt(tribe) + T.STATE) == 2
end

local function friendly(owner, player)
  if owner == player then return true end
  if owner < 1 or owner > 8 then return false end
  return rd32(G.teams + 4 * owner) == rd32(G.teams + 4 * player)
end

-- The troop the AI keeps in `slot`, if it is still that troop and alive.
local function slotTribe(player, slot)
  local base = G.players + player * P.STRIDE
  local tribe = s16(base + P.TRIBE_IDS + 2 * slot)
  if tribe <= 0 or not tribeAlive(tribe) then return nil end
  if rd32(base + P.TRIBE_UIDS + 4 * slot) ~= rd32(tribeAt(tribe) + T.UID) then return nil end
  return tribe
end

-- A troop's leader, if it is alive, on the player's side and really in that troop.
local function leaderOf(tribe, player)
  local leader = s16(tribeAt(tribe) + G.leaderOffset)
  if not unitAlive(leader) then return nil end
  local a = unitAt(leader)
  if not friendly(s16(a + U.OWNER), player) then return nil end
  if s16(a + U.TRIBE) ~= tribe then return nil end
  return leader
end

local function troopsIn(player, slots, into)
  for _, slot in ipairs(slots) do
    local tribe = slotTribe(player, slot)
    local leader = tribe and leaderOf(tribe, player)
    if leader then
      into[#into + 1] = { tribe = tribe, unit = leader, uid = rd32(tribeAt(tribe) + T.UID) }
    end
  end
  return into
end

-- The attacking army's ranged troops (by their leader), in an order that looks random but is the
-- same on every machine of a multiplayer game: shuffled by troop uid.
local function rangedTroops(player)
  local all, ranged = troopsIn(player, SLOT_ATTACK, {}), {}
  for _, troop in ipairs(all) do
    if RANGED_TROOPS[u16(unitAt(troop.unit) + U.TYPE)] then
      troop.key = (troop.uid * 2654435761) & 0xFFFFFFFF
      ranged[#ranged + 1] = troop
    end
  end
  table.sort(ranged, function(p, q) return p.key < q.key end)
  return ranged
end

local function moveTribe(tribe, unit)
  local a = unitAt(unit)
  F.move(G.tribes, tribe, s16(a + U.X), s16(a + U.Y), 0, 0, 0)
end

-- The player's shields, towers and ranged engines (collected in asm), as the game's own loop
-- picks shields and towers: from a siege tent (byte 3), not the siege camp's own (behaviour
-- 0x15) and in a troop.
-- Where a player's keep stands, or nil.
local function keepAt(player)
  local base = G.players + player * P.STRIDE
  if rd32(base + P.HAS_KEEP) == 0 then return nil end
  local tile = rd32(base + P.KEEP_TILE)
  if tile <= 0 or tile >= TILES then return nil end
  local y = u16(G.tileY + 2 * tile)
  return tile - rd32(G.rows + 12 * y), y
end

-- A ranged engine of the attacking army, not one the AI keeps at home: built in a siege tent
-- (or sent on a raid), and nearer the attacked castle's keep than its own.
local function attackEngine(index, player)
  local a = unitAt(index)
  if byte(a + U.SIEGE_BYTE) ~= 3 and u16(a + U.BEHAVIOUR) ~= 0x16 then return false end
  local attacked = rd32(G.players + player * P.STRIDE + P.ATTACKED)
  if attacked < 1 or attacked > 8 then return false end
  local ex, ey = keepAt(attacked)
  local ox, oy = keepAt(player)
  if ex == nil or ox == nil then return true end
  local x, y = s16(a + U.X), s16(a + U.Y)
  return (x - ex) ^ 2 + (y - ey) ^ 2 < (x - ox) ^ 2 + (y - oy) ^ 2
end

local function siegeUnits(player)
  local found = { shields = {}, towers = {}, engines = {}, engineers = {},
    skipped = { notTent = 0, camp = 0, noTroop = 0, homeEngines = 0 } }
  for i = 1, math.min(rd32(G.list), 1023) do
    local index = rd32(G.list + 4 * i)
    local a = unitAt(index)
    local kind = u16(a + U.TYPE)
    if kind == UT.ENGINEER then
      if unitAlive(index) then found.engineers[#found.engineers + 1] = index end
    elseif RANGED_ENGINES[kind] then
      if unitAlive(index) then
        if attackEngine(index, player) then
          found.engines[#found.engines + 1] = index
        else
          found.skipped.homeEngines = found.skipped.homeEngines + 1
        end
      end
    elseif byte(a + U.SIEGE_BYTE) ~= 3 then
      found.skipped.notTent = found.skipped.notTent + 1
    elseif u16(a + U.BEHAVIOUR) == 0x15 then
      found.skipped.camp = found.skipped.camp + 1
    elseif s16(a + U.TRIBE) <= 0 then
      found.skipped.noTroop = found.skipped.noTroop + 1
    else
      local list = kind == UT.SHIELD and found.shields or found.towers
      list[#list + 1] = index
    end
  end
  return found
end

---------------------------------------------------------------------------------------
-- 4. Shields
---------------------------------------------------------------------------------------

local shieldTargets = {}    -- shield tribe -> the engine it walks with (lua only)

local function commandShields(player, units)
  if #units.shields == 0 then return end
  -- Where a shield may go: the moat fillers, the attacking army's ranged siege engines and its
  -- ranged troops; the backup troops only once none of those are left.
  local places = troopsIn(player, SLOT_DIGGERS, {})
  for _, engine in ipairs(units.engines) do
    local tribe = s16(unitAt(engine) + U.TRIBE)
    places[#places + 1] = { tribe = (tribe > 0 and tribeAlive(tribe)) and tribe or 0,
      unit = engine, uid = rd32(unitAt(engine) + U.UID), engine = true }
  end
  for _, troop in ipairs(rangedTroops(player)) do places[#places + 1] = troop end
  units.placesFound = #places

  local seen, shields = {}, {}
  for _, unit in ipairs(units.shields) do
    local tribe = s16(unitAt(unit) + U.TRIBE)
    if not seen[tribe] then
      seen[tribe] = { unit = unit }
      shields[#shields + 1] = tribe
    end
  end

  -- Nowhere to go: a shield that was walking with someone stops where it is and waits.
  -- None of those left: the backup troops.
  if #places == 0 then places = troopsIn(player, SLOT_BACKUP, {}); units.rangedFound = #places end
  if #places == 0 then
    for _, shield in ipairs(shields) do
      local base = tribeAt(shield)
      if s16(base + G.followOffset) ~= 0 or shieldTargets[shield] ~= nil then
        moveTribe(shield, seen[shield].unit)
        wr16(base + G.followOffset, 0)
        shieldTargets[shield] = nil
        diag("player %d: shield troop %d has nobody to walk with and waits", player, shield)
      end
    end
    return
  end

  -- Keep each shield where it already is while that place is still on the list and has no
  -- more than its share, so the shields stay spread evenly over the places there are.
  local share = math.max(1, #shields // #places)
  local counts, assigned = {}, {}
  for _, shield in ipairs(shields) do
    local base = tribeAt(shield)
    local link, linkUid = s16(base + G.followOffset), rd32(base + G.followUidOffset)
    local remembered = shieldTargets[shield]
    for i, place in ipairs(places) do
      local same
      if place.engine then
        same = remembered ~= nil and remembered.unit == place.unit and remembered.uid == place.uid
      else
        same = link == place.tribe and linkUid == place.uid
      end
      if same and (counts[i] or 0) < share then
        assigned[shield] = i
        counts[i] = (counts[i] or 0) + 1
        break
      end
    end
  end
  -- The others go to the place with the fewest shields, the better one on a tie.
  for _, shield in ipairs(shields) do
    if assigned[shield] == nil then
      local best
      for i = 1, #places do
        if best == nil or (counts[i] or 0) < (counts[best] or 0) then best = i end
      end
      assigned[shield] = best
      counts[best] = (counts[best] or 0) + 1
      diag("player %d: shield troop %d now walks with %s %d", player, shield,
        places[best].engine and "siege engine" or "troop",
        places[best].engine and places[best].unit or places[best].tribe)
    end
    local place = places[assigned[shield]]
    local base = tribeAt(shield)
    moveTribe(shield, place.unit)
    if place.tribe > 0 then
      wr16(base + G.followOffset, place.tribe)
      wr32(base + G.followUidOffset, rd32(tribeAt(place.tribe) + T.UID))
      wr16(tribeAt(place.tribe) + G.backlinkOffset, shield)
    else
      wr16(base + G.followOffset, 0)
    end
    shieldTargets[shield] = place.engine and { unit = place.unit, uid = place.uid } or nil
  end
end

---------------------------------------------------------------------------------------
-- 3. Siege towers
---------------------------------------------------------------------------------------

local function tileXY(tile)
  local y = u16(G.tileY + 2 * tile)
  return tile - rd32(G.rows + 12 * y), y
end

-- Send the tower at a wall the way its own update does when it finds one.
local function sendToWall(unit, wall, dock)
  local a = unitAt(unit)
  local dx, dy = tileXY(dock)
  local wx, wy = tileXY(wall)
  F.setDestination(G.unitsState, unit, dx, dy, 0)
  wr16(a + U.TARGETING, ORDER_WALL)
  wr16(a + U.ORDER_STATE, STATE_TO_WALL)
  wr16(a + U.TARGET, wall)
  wr32(a + U.WALL_TILE, wall)
  wr32(a + U.DOCK_TILE, dock)
  wr16(a + U.WALL_X, wx)
  wr16(a + U.WALL_Y, wy)
end

local towerMode = {}     -- tower unit -> "wall" / "list" / "follow", for the log
local towerStill = {}    -- tower unit -> { x, y, rounds } while it is on its way to a wall
local listFailed = {}    -- tower unit -> true once a wall from the AI's own list got it nowhere

local function commandTowers(player, units)
  if #units.towers == 0 then return end
  local attacked = rd32(G.players + player * P.STRIDE + P.ATTACKED)
  local wide = rd32(G.wide + player * WIDE_STRIDE)
  local escorts
  local followers = 0
  for _, tower in ipairs(units.towers) do
    local a = unitAt(tower)
    -- (a docked tower has left its troop and is not in the list at all)
    local busy = u16(a + U.TARGETING) == ORDER_WALL
      and (u16(a + U.ORDER_STATE) == STATE_TO_WALL or u16(a + U.ORDER_STATE) == STATE_DOCKING)
    -- on its way, but standing still for a while: that wall is not working out
    local x, y = s16(a + U.X), s16(a + U.Y)
    if busy then
      local seen = towerStill[tower]
      if seen and seen.x == x and seen.y == y then
        seen.rounds = seen.rounds + 1
      else
        seen = { x = x, y = y, rounds = 0 }
        towerStill[tower] = seen
      end
      if seen.rounds >= STUCK_ROUNDS then
        busy = false
        towerStill[tower] = nil
        if towerMode[tower] == "list" then listFailed[tower] = true end
      end
    else
      towerStill[tower] = nil
    end
    if not busy and unitAlive(tower) then
      -- given a wall from the AI's list last round and still not on its way: the list fails it
      if towerMode[tower] == "list" then listFailed[tower] = true end
      local tribe = s16(a + U.TRIBE)
      local wall = F.towerFind(tower, (attacked >= 1 and attacked <= 8) and attacked or 0, TOWER_RADIUS)
      local mode
      if wall ~= 0 then
        sendToWall(tower, wall, rd32(G.data + 0xFC))
        mode = "wall"
        listFailed[tower] = nil
      elseif wide ~= 0 and not listFailed[tower] then
        F.assign(G.tribes, tribe, KIND_TOWER_WALLS)
        if u16(a + U.TARGETING) == ORDER_WALL then
          mode = "list"
        else
          listFailed[tower] = true      -- the AI's own wall gave it no order
        end
      end
      if mode == nil then
        -- patrol troops first, then siege defence, the main army, any ranged troop of the attack,
        -- and the backup troops only when none of those are left
        if escorts == nil then
          escorts = {}
          for _, slots in ipairs({ SLOT_PATROL, SLOT_SIEGEDEF, SLOT_MAIN }) do
            troopsIn(player, slots, escorts)
          end
          if #escorts == 0 then escorts = rangedTroops(player) end
          if #escorts == 0 then escorts = troopsIn(player, SLOT_BACKUP, {}) end
        end
        if #escorts > 0 then
          followers = followers + 1
          moveTribe(tribe, escorts[(followers - 1) % #escorts + 1].unit)
          mode = "follow"
        end
      end
      if mode ~= nil and towerMode[tower] ~= mode then
        diag("player %d: siege tower %d %s", player, tower, mode == "wall" and
          string.format("goes to dock at wall tile %d", wall) or mode == "list" and
          "takes a wall from the AI's own list" or "walks with the army, no wall to dock at")
      end
      towerMode[tower] = mode
    end
  end
end

---------------------------------------------------------------------------------------
-- 2b. Engineers into their siege tents
---------------------------------------------------------------------------------------

local function buildingAt(index) return G.buildings + index * B.STRIDE end

-- Send an engineer into a siege building the way the game's own order does: the entrance test
-- first (it moves a blocked entrance to a free side), then the way there, then the walk.
local function sendEngineer(unit, building, player)
  local a, ba = unitAt(unit), buildingAt(building)
  if F.entrance(G.buildingsState, building, 1, s16(a + U.X), s16(a + U.Y)) == 0 then return false end
  local ex, ey = s16(ba + B.ENTRY_X), s16(ba + B.ENTRY_Y)
  if ex < 0 or ey < 0 or ex >= 400 or ey >= 400 or byte(G.valid + ey * 400 + ex) == 0 then
    return false
  end
  local entry = rd32(G.rows + 12 * ey) + ex
  local to, from = s16(G.area + 2 * entry), s16(G.area + 2 * rd32(a + U.TILE))
  if F.navigate(G.pathFinder, player, to, from, 0) == 0 then return false end
  wr16(a + U.TARGET, building)
  wr32(a + U.TARGET_UID, rd32(ba + B.UID))
  F.setDestination(G.unitsState, unit, ex, ey, 0)
  wr16(a + U.ORDER_STATE, STATE_TO_TENT)
  wr16(a + U.DEPOSIT, 0)
  F.deselect(G.unitsState, unit)
  F.unselect(G.unitsState, player, unit, 0)
  return true
end

local onTheWay = {}      -- engineer -> { x, y, rounds } while it walks to a tent

local function commandEngineers(player, units)
  local count = math.min(rd32(G.tlist), 255)
  if count == 0 or #units.engineers == 0 then return end
  local taken = {}
  for i = 1, count do
    local building = rd32(G.tlist + 4 * i)
    local ba = buildingAt(building)
    local need = 0
    if u16(ba + B.STATE) == 2 then
      need = F.required(G.buildingsState, building) - s16(ba + B.WORKERS)
    end
    if need > 0 then
      local uid = rd32(ba + B.UID)
      local bx, by = s16(ba + B.X), s16(ba + B.Y)
      local mine, idle = {}, {}
      for _, engineer in ipairs(units.engineers) do
        if not taken[engineer] then
          local a = unitAt(engineer)
          local state = u16(a + U.ORDER_STATE)
          local ours = s16(a + U.TARGET) == building and rd32(a + U.TARGET_UID) == uid
          local x, y = s16(a + U.X), s16(a + U.Y)
          if state == STATE_TO_TENT and ours then
            -- on its way: it counts, unless it has stood still for a while (a way that closed)
            local seen = onTheWay[engineer]
            if seen and seen.x == x and seen.y == y then
              seen.rounds = seen.rounds + 1
            else
              seen = { x = x, y = y, rounds = 0 }
              onTheWay[engineer] = seen
            end
            if seen.rounds >= STUCK_ROUNDS then mine[#mine + 1] = engineer else need = need - 1 end
          elseif state == STATE_IDLE then
            if ours then
              mine[#mine + 1] = engineer
            else
              local d = (x - bx) * (x - bx) + (y - by) * (y - by)
              if d <= ENGINEER_RADIUS * ENGINEER_RADIUS then idle[#idle + 1] = { engineer, d } end
            end
          end
        end
      end
      table.sort(idle, function(p, q) return p[2] < q[2] end)
      for _, entry in ipairs(idle) do mine[#mine + 1] = entry[1] end
      for _, engineer in ipairs(mine) do
        if need <= 0 then break end
        if sendEngineer(engineer, building, player) then
          taken[engineer] = true
          onTheWay[engineer] = nil
          need = need - 1
          diag("player %d: engineer %d sent into siege tent %d", player, engineer, building)
        end
      end
    end
  end
end

local lastSummary = {}    -- player -> the round summary last written to the log

local function onSiegeCommand()
  local player = rd32(G.data + 0x130)
  if player < 1 or player > 8 then return end
  local units = siegeUnits(player)
  if O.engineers then commandEngineers(player, units) end
  if O.shields then commandShields(player, units) end
  if O.towerOrders then commandTowers(player, units) end
  if O.log then
    local k = units.skipped
    local summary = string.format("player %d, AI state %d: %d shields, %d towers, %d attack engines, "
      .. "%d engineers in the round; left out: %d not from a tent, %d of the siege camp, %d in no troop, "
      .. "%d engines at home; shield places %s, backup troops %s", player,
      rd32(G.players + player * P.STRIDE + 0x2BA4), #units.shields, #units.towers, #units.engines,
      #units.engineers, k.notTent, k.camp, k.noTroop, k.homeEngines,
      tostring(units.placesFound or "-"), tostring(units.rangedFound or "-"))
    if summary ~= lastSummary[player] then
      lastSummary[player] = summary
      diag("%s", summary)
    end
  end
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function readCommon()
  local flags = rd32(scan(AOB_TILE_FLAGS, "the tile flags") + TILE_FLAGS_OPERAND)
  local tms = flags - MAP.FLAGS
  G.flags = flags
  G.wallOwner = tms + MAP.WALL_OWNER
  G.area = tms + MAP.AREA
  G.tileY = tms + MAP.Y_OF_TILE
  G.rows = tms + MAP.ROWS
  G.valid = tms + MAP.VALID
  G.buildingIds = tms + MAP.BUILDINGS
  G.unitIds = tms + MAP.UNITS
  G.teams = rd32(scan(AOB_TEAMS, "the team table") + TEAMS_OPERAND)
  G.ticks = rd32(scan(AOB_TICKS, "the tick counter") + TICKS_OPERAND)

  local cone = scan(AOB_CONE, "the siege engines' target search")
  G.buildingType = operand(cone, CONE_TYPE, "the building types")
  G.buildingOwner = operand(cone, CONE_OWNER, "the building owners")
  G.health = operand(cone, CONE_HEALTH, "the damageable buildings")
  if G.buildingOwner - G.buildingType ~= B.OWNER - B.TYPE then
    error("the building layout is not the one this module knows", 0)
  end
  G.buildings = G.buildingType - B.TYPE
  G.buildingsState = G.buildings - B.STATE_OFFSET
  G.range = rangeTable(scan(AOB_ACQUIRE, "the shooting code"))

  local command = scan(AOB_COMMAND, "the AI's siege engine orders")
  G.command = command
  G.players = operand(command, CMD_TRIBE_IDS, "the AI's troop list") - P.TRIBE_IDS
  G.tribeStride = operand(command, CMD_STRIDE, "the troop size")
  G.tribes = operand(command, CMD_TRIBES, "the troops")
  local first = operand(command, CMD_UNITS, "the unit array")
  G.units = first - U.STRIDE - U.TYPE
  G.maxUnits = (operand(command, CMD_LAST, "the unit array") - first) // U.STRIDE + 1
  G.unitsState = G.units - U.STATE_OFFSET
  G.leaderOffset = operand(command, CMD_LEADER, "the troop leader") - G.tribes
  G.followOffset = operand(command, CMD_FOLLOW, "the shield link") - G.tribes
  G.followUidOffset = operand(command, CMD_FOLLOW_UID, "the shield link") - G.tribes
  G.backlinkOffset = operand(command, CMD_BACKLINK, "the shield link") - G.tribes
  G.wide = operand(command, CMD_WIDE, "the AI's tower walls")
  if G.leaderOffset ~= T.LEADER then
    error("the troop layout is not the one this module knows", 0)
  end

  G.data = core.allocate(0x200, true)
  G.fort = core.allocate(512, true)
  for _, kind in ipairs(FORTIFICATIONS) do core.writeByte(G.fort + kind, 1) end
  wr32(G.data + 0x78, 0x7FFFFFFF)
  wr32(G.data + 0x7C, 0x7FFFFFFF)

  local helpers = { VALID = G.valid, ROWS = G.rows, FLAGS = G.flags, BIDS = G.buildingIds,
    BTYPE = G.buildingType }
  G.tileAt = assemble(templates.tileAt, helpers)
  helpers.TILEAT = G.tileAt
  G.wallAt = assemble(templates.wallAt, helpers)
  G.clearAt = assemble(templates.clearAt, helpers)
end

-- The values every script may use; assemble() passes each script only its own.
local function values(extra)
  local v = {
    D = G.data, FLAGS = G.flags, WOWNER = G.wallOwner, TILEY = G.tileY, ROWS = G.rows,
    VALID = G.valid, BIDS = G.buildingIds, UNITMAP = G.unitIds, AREA = G.area,
    BTYPE = G.buildingType, BOWNER = G.buildingOwner, HEALTH = G.health, TEAMS = G.teams,
    RANGE = G.range, TICKS = G.ticks, UNITS = G.units, US = G.unitsState, TRIBES = G.tribes,
    TSTRIDE = G.tribeStride, PLAYERS = G.players, MAXUNITS = G.maxUnits,
    MAXTRIBES = MAX_TRIBES, TILES = TILES, TILEAT = G.tileAt, WALLAT = G.wallAt,
    CLEARAT = G.clearAt, FORT = G.fort, CIVILIAN = CIVILIAN_PENALTY, OTHER = OTHER_PENALTY,
    BSTATE = G.buildings + B.STATE,
  }
  for name, value in pairs(extra or {}) do v[name] = value end
  return v
end

-- Diagnostics: every target a catapult or trebuchet picks in the module's search, once per
-- engine and target tile, with what stands on that tile.
local lastPick = {}

local function logPick()
  local esi = rd32(G.data + 0x1F4)
  local index = (esi - G.unitsState) // U.STRIDE
  local unit = G.units + index * U.STRIDE
  local tile = rd32(G.data + 0x3C)
  if lastPick[index] == tile then return end
  lastPick[index] = tile
  local ex, ey = rd32(G.data + 0x20), rd32(G.data + 0x24)
  local tx, ty = rd32(G.data + 0x40), rd32(G.data + 0x44)
  local flags = rd32(G.flags + tile * 4)
  local what
  if flags & 0x100 ~= 0 then
    what = string.format("wall of player %d", (core.readByte(G.wallOwner + tile) & 7) + 1)
  else
    local id = core.readSmallInteger(G.buildingIds + tile * 2)
    if id > 0 then
      local b = G.buildings + id * B.STRIDE
      what = string.format("building %d (type %d) of player %d", id, core.readSmallInteger(b + B.TYPE),
        core.readSmallInteger(b + B.OWNER))
    else
      what = "no wall or building"
    end
  end
  local kind = core.readSmallInteger(unit + U.TYPE) == UT.TREBUCHET and "trebuchet" or "catapult"
  diag("%s %d of player %d at (%d,%d) aims at (%d,%d), %d tiles away: %s, tile flags 0x%X, "
    .. "target player %d", kind, index, rd32(G.data + 0x28), ex, ey, tx, ty,
    math.floor(math.sqrt((tx - ex) ^ 2 + (ty - ey) ^ 2) + 0.5), what, flags, rd32(G.data + 0x2C))
end

local function enableCatapults()
  local harass = scan(AOB_HARASS, "the siege engines' target choice")
  expectBytes(harass + HARASS_HOOK[1], HARASS_HOOK[2], "the siege engines' target choice")
  local search = assemble(templates.catapultSearch, values())
  G.search = search
  G.live = assemble(templates.livePlayer, values({ PSTRIDE = P.STRIDE, PLORD = G.players + P.LORD,
    PLORDUID = G.players + P.LORD_UID, U_STATE = G.units + U.STATE, U_TYPE = G.units + U.TYPE,
    U_UID = G.units + U.UID, LORDTYPE = UT.LORD }))
  local hook = assemble(templates.catapultHook, values({
    SEARCH = search, LIVE = G.live, PICKLOG = luaFunction("the catapult target log", logPick),
    ALG_TILE = operand(harass, HARASS_RESULT, "the search result"),
    ALG_X = operand(harass, HARASS_TARGET_X, "the search result"),
    ALG_Y = operand(harass, HARASS_TARGET_Y, "the search result"),
    SHOOT = harass + HARASS_SHOOT,
    MAPORIENT = operand(harass, HARASS_MAP_ORIENTATION, "the map orientation"),
    DIRSTATE = operand(G.command, CMD_DIRECTIONS, "the direction finder"),
    ORIENT = callTarget(G.command + CMD_ORIENT[1], "the direction finder"),
    ALG_ORIENT = operand(G.command, CMD_ORIENTATION, "the direction finder"),
    RESUME = harass + HARASS_HOOK[1] + HARASS_HOOK_SIZE,
  }))
  patch(harass + HARASS_HOOK[1], jumpCode(harass + HARASS_HOOK[1], hook, HARASS_HOOK_SIZE),
    HARASS_HOOK_SIZE)
end

local function enableStandingTargets()
  local harass = scan(AOB_HARASS, "the siege engines' target choice")
  expectBytes(harass + HARASS_TARGET_CHECK[1], HARASS_TARGET_CHECK[2], "the siege engines' building target")
  if operand(harass, HARASS_UID, "the building uid") - B.UID + B.STATE ~= G.buildings + B.STATE then
    error("the building layout is not the one this module knows", 0)
  end
  local site = harass + HARASS_TARGET_CHECK[1]
  local stub = assemble(templates.standingTarget, values({
    BACK = harass + HARASS_TARGET_BACK, LOST = harass + HARASS_TARGET_LOST,
  }))
  patch(site, jumpCode(site, stub, 8), 8)
end

-- setRandomShootLocation(unit, x, y, z): the random miss of a shot, ready at +0x286 just before
-- the height is clamped (cmp edi, 8 / jge +7).
local AOB_SCATTER = "51 8B 44 24 08 8B 54 24 0C 69 C0 90 04 00 00 53 55 56 8D 34 08"
local SCATTER_HOOK = { 0x286, { 0x83, 0xFF, 0x08, 0x7D, 0x07 } }
local SCATTER_TYPE = { 0x63, { 0x0F, 0xB7, 0x86, 0xA2, 0x06, 0x00, 0x00 } }

local function enableScatter()
  local scatter = scan(AOB_SCATTER, "the siege engines' aim")
  expectBytes(scatter + SCATTER_HOOK[1], SCATTER_HOOK[2], "the siege engines' aim")
  expectBytes(scatter + SCATTER_TYPE[1], SCATTER_TYPE[2], "the siege engines' aim")
  local site = scatter + SCATTER_HOOK[1]
  local hundred = core.allocate(4, true)
  wr32(hundred, 100)
  local hook = assemble(templates.scatterHook, values({
    PSTRIDE = P.STRIDE, AITYPE = P.AI_TYPE, SCATTER = O.scatter, HUNDRED = hundred,
    LOW = site + 5, HIGH = site + 5 + 7,
  }))
  patch(site, jumpCode(site, hook, 5), 5)
end

local function enableTents()
  local tents = scan(AOB_TENTS, "the AI's siege tent placement")
  local angle = callTarget(tents + TENTS_ANGLE_CALL, "the siege tent placement")
  local suitable = callTarget(tents + TENTS_SUIT_CALL, "the siege tent placement")
  expectBytes(angle, TENT_PROLOGUE, "the siege tent placement")
  expectBytes(suitable, TENT_PROLOGUE, "the siege tent placement")
  local find = callTarget(angle + ANGLE_FIND_CALL, "the tent spot search")
  expectBytes(find + SPOT_HOOK[1], SPOT_HOOK[2], "the tent spot search")
  local three = rd32(find + SPOT_THREE)
  local tribeId = operand(find, SPOT_TRIBE, "the tent spots")
  if three - tribeId ~= 8 then error("the tent spots are not laid out as this module knows", 0) end
  expectBytes(find + SPOT_FOUND[1], SPOT_FOUND[2], "the tent spot search")
  local found = (find + SPOT_FOUND[1] + 6 + rd32(find + SPOT_FOUND[1] + 2)) & 0xFFFFFFFF
  local location = scan(AOB_LOCATION, "the siege tent location search")
  expectBytes(location + LOCATION_HOOK[1], LOCATION_HOOK[2], "the siege tent location search")
  local engineers = scan(AOB_ENGINEERS, "the siege engine types")

  -- tables lua fills once: threat kinds by unit type, fortified building types
  local tk = core.allocate(4 * 80, true)
  for kind, value in pairs(THREAT_KIND) do wr32(tk + 4 * kind, value) end
  local dist = core.allocate(400 * 400 * 2, true)
  local threats = core.allocate(12 * MAX_THREATS, true)

  local v = values({ TK = tk, DIST = dist, THREATS = threats,
    MELEE = MELEE_REACH, MAXTHREATS = MAX_THREATS, MARGIN = TENT_MARGIN,
    ENG_UT = operand(engineers, ENGINEERS_UNIT_TYPES, "the siege engine types"),
    ENG_BT = operand(engineers, ENGINEERS_TENT_TYPES, "the siege tent types"),
    THREE = three, TID = tribeId, FOUND = found, CONTINUE = find + SPOT_HOOK[1] + SPOT_HOOK_SIZE,
    ATTACKED_PID = operand(location, LOCATION_ATTACKED, "the AI's distance layer"),
    LAYER = operand(location, LOCATION_LAYER, "the AI's distance layer"),
    RESUME = location + LOCATION_HOOK[1] + LOCATION_HOOK_SIZE })
  v.THREATLIST = assemble(templates.threats, v)
  v.DISTMAP = assemble(templates.distanceMap, v)
  v.PREPARE = assemble(templates.prepareTent, v)
  v.FOOTPRINT = assemble(templates.footprint, v)
  v.SAFE = assemble(templates.safe, v)

  local spot = assemble(templates.tentSpot, v)
  local inLocation = assemble(templates.tentLocation, v)
  local function wrapper(at, args)
    local orig = assemble(templates.tentOrig, { RESUME = at + #TENT_PROLOGUE })
    return assemble(templates.tentWrapper, values({ PREPARE = v.PREPARE, ORIG = orig, ARGS = args }))
  end
  local angleWrapper = wrapper(angle, 2)
  local suitableWrapper = wrapper(suitable, 4)

  patch(find + SPOT_HOOK[1], jumpCode(find + SPOT_HOOK[1], spot, SPOT_HOOK_SIZE), SPOT_HOOK_SIZE)
  patch(location + LOCATION_HOOK[1],
    jumpCode(location + LOCATION_HOOK[1], inLocation, LOCATION_HOOK_SIZE), LOCATION_HOOK_SIZE)
  patch(angle, jumpCode(angle, angleWrapper, 5), 5)
  patch(suitable, jumpCode(suitable, suitableWrapper, 5), 5)
end

local function freeTileSearch()
  return scan(AOB_FREE_TILE, "where a siege tower docks") + FREE_TILE_START
end

local function enableDocking()
  local search = freeTileSearch()
  local ok = pcall(expectBytes, search, FREE_TILE_PROLOGUE, "where a siege tower docks")
  if not ok then
    error("another module already changes where siege towers dock (Smarter Walls before "
      .. "1.0.16 did; update it)", 0)
  end
  local pf = operand(search, FREE_TILE_PF, "the path finder")
  local navigate = callTarget(search + FREE_TILE_NAVIGATE[1], "the area test")
  local diagonals = core.allocate(32, true)
  for i, d in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
    wr32(diagonals + 8 * (i - 1), d[1])
    wr32(diagonals + 8 * (i - 1) + 4, d[2])
  end
  local game = assemble(templates.freeTileGame, { RESUME = search + FREE_TILE_SIZE })
  local diagonal = assemble(templates.diagonalDock, values({ DIAGS = diagonals, PF = pf, NAV = navigate }))
  local free = assemble(templates.freeTile, values({ GAME = game, DIAGONAL = diagonal }))
  patch(search, jumpCode(search, free, FREE_TILE_SIZE), FREE_TILE_SIZE)
  G.freeTile = free
end

-- Walking AI catapults and trebuchets: the module's stub goes into the unit update table for
-- both types and chains on to whatever the table held.
local WALK_TYPES = { UT.CATAPULT, UT.TREBUCHET }
local WALK_EVERY = 15                        -- every 16 ticks, staggered by unit
local UNIT_TYPES = 80

local function enableWalking()
  local call = scan(AOB_UPDATE_CALL, "where every unit's update function is called")
  local tableAt = operand(call, UPDATE_TABLE, "the unit update table")
  expectBytes(call + UPDATE_CURRENT_AT, UPDATE_CURRENT_BYTE, "the current unit")
  local current = rd32(call + UPDATE_CURRENT_AT + 1)
  local stop = scan(AOB_STOP_WALKING, "the game's stop walking")
  local originals = core.allocate(UNIT_TYPES * 4, true)
  for kind = 0, UNIT_TYPES - 1 do wr32(originals + kind * 4, rd32(tableAt + kind * 4)) end
  local check = assemble(templates.walkCheck, values({
    CURRENT = current, EVERY = WALK_EVERY, ORIGINALS = originals, STOP = stop, SEARCH = G.search, LIVE = G.live,
    U_OWNER = G.units + U.OWNER, U_ORDER = G.units + U.ORDER_STATE, U_TYPE = G.units + U.TYPE,
    U_X = G.units + U.X, U_Y = G.units + U.Y, U_TARGETP = G.units + U.SIEGE_TARGET,
    U_COOLDOWN = G.units + U.COOLDOWN, AITYPE = G.players + P.AI_TYPE, PSTRIDE = P.STRIDE,
    FIRST = UT.CATAPULT, LAST = UT.TREBUCHET }))
  for _, kind in ipairs(WALK_TYPES) do
    patch(tableAt + kind * 4, core.itob(check), 4)
  end
end

local function enableOil()
  local engineer = scan(AOB_UPDATE_ENGINEER, "the engineer update")
  local pour = engineer + OILAT.ENGINEER_POUR[1]
  local deposit = operand(engineer, OILAT.ENGINEER_POUR, "the engineers' oil pots")
  if deposit ~= G.units + U.DEPOSIT then error("the engineers' oil pots are not where expected", 0) end
  expectBytes(engineer + OILAT.ENGINEER_EPILOGUE[1], OILAT.ENGINEER_EPILOGUE[2], "the end of the engineer update")
  local auto = scan(OILAT.AOB_AUTO_OIL, "the engineers' automatic oil")
  local targeting = operand(auto, OILAT.AUTO_OIL_TAKE, "the engineers' automatic oil")
  if targeting ~= G.units + U.TARGETING then error("the automatic oil target is not where expected", 0) end
  expectBytes(auto + OILAT.AUTO_OIL_FAIL[1], OILAT.AUTO_OIL_FAIL[2], "the engineers' automatic oil")
  local pot = scan(OILAT.AOB_OIL_POT, "the oil pot")
  local fire = callTarget(pot + OILAT.OIL_POT_FIRE, "the oil pot's fire")
  expectBytes(fire + OILAT.FIRE_AT[1], OILAT.FIRE_AT[2], "the fire function")
  local move = scan(OILAT.AOB_MOVE_COMMAND, "the move order")
  local flammable = callTarget(scan(AOB_CONE, "the siege engines' target search") + OILAT.CONE_FLAMMABLE,
    "the flammability test")
  local damage = scan(OILAT.AOB_BUILDING_DAMAGE, "the building damage")

  local entities = scan(OILAT.AOB_ENTITIES, "the entity update")
  expectBytes(entities, OILAT.ENTITIES_PROLOGUE[2], "the entity update")
  G.oil = core.allocate(0x100, true)
  wr32(G.oil + 0x00, O.oilAim and 1 or 0)
  wr32(G.oil + 0x04, O.oilSpread and 1 or 0)
  wr32(G.oil + 0x08, O.oilAmount)
  wr32(G.oil + 0x0C, O.oilDamage and 1 or 0)
  local dirs = core.allocate(32, true)
  for i, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    wr32(dirs + 8 * (i - 1), d[1])
    wr32(dirs + 8 * (i - 1) + 4, d[2])
  end
  local tms = G.flags - MAP.FLAGS
  -- how strong each oil fire burns, picked at random: mostly 3 (the tall pitch flame)
  local mix = core.allocate(8, true)
  for i, strength in ipairs({ 2, 3, 3, 3, 3, 4, 4, 5 }) do core.writeByte(mix + i - 1, strength) end
  local v = values({ OIL = G.oil, DIRS = dirs, HEIGHT = tms + MAP.HEIGHT, TMS = tms,
    QUEUE = core.allocate(16 * 256, true), BLIST = core.allocate(16 * 32, true),
    BDEPTH = core.allocate(4 * 32, true), STAMP = core.allocate(4 * TILES, true),
    QFLAG = core.allocate(256, true), AIMS = core.allocate(16 * 32, true), MIX = mix, PEND = core.allocate(32 * OILAT.OIL_EVENTS, true),
    PENDMAX = OILAT.OIL_EVENTS, STEP = OILAT.OIL_STEP, TICKS = G.ticks,
    REACH = OILAT.OIL_REACH, SEEDGAP = OILAT.OIL_SEED_GAP, SEED = OILAT.OIL_SEED, FIREPARAM = operand(fire, OILAT.FIRE_STRENGTH, "the fire strength"),
    FLAMMABLE = flammable, BSTATE = G.buildingsState,
    BMAXHP = G.buildings + B.MAX_HEALTH, DAMAGE = damage, FIRE = fire, FIRE_AT = fire + OILAT.FIRE_AT[1],
    CURPLAYER = operand(move, OILAT.MOVE_LOCAL_PLAYER, "the local player"),
    SFX = operand(move, OILAT.MOVE_SFX, "the sound system"),
    SPEECH = callTarget(move + OILAT.MOVE_SPEECH, "the unit speech"),
    DEPOSIT = deposit, TARGETING = targeting, UNITTILE = G.units + U.TILE,
    EPILOGUE = engineer + OILAT.ENGINEER_EPILOGUE[1], FAIL = auto + OILAT.AUTO_OIL_FAIL[1] })
  v.POURABLE = assemble(templates.pourable, v)
  v.RINGSTEP = assemble(templates.ringStep, v)
  v.IGNITE = assemble(templates.ignite, v)
  v.OILFIRE = assemble(templates.oilFire, v)
  v.ENQUEUE = assemble(templates.oilEnqueue, v)
  v.OILAIM = assemble(templates.oilAim, v)
  local spread = assemble(templates.oilSpread, v)
  v.RESUME = pour + OILAT.ENGINEER_POUR_SIZE
  local throw = assemble(templates.oilThrow, v)
  v.RESUME = auto + OILAT.AUTO_OIL_TAKE[1] + OILAT.AUTO_OIL_TAKE_SIZE
  local take = assemble(templates.oilAuto, v)

  v.RESUME = entities + OILAT.ENTITIES_PROLOGUE_SIZE
  local tick = assemble(templates.oilTick, v)

  patch(entities, jumpCode(entities, tick, OILAT.ENTITIES_PROLOGUE_SIZE), OILAT.ENTITIES_PROLOGUE_SIZE)
  patch(pour, jumpCode(pour, throw, OILAT.ENGINEER_POUR_SIZE), OILAT.ENGINEER_POUR_SIZE)
  patch(auto + OILAT.AUTO_OIL_TAKE[1], jumpCode(auto + OILAT.AUTO_OIL_TAKE[1], take, OILAT.AUTO_OIL_TAKE_SIZE),
    OILAT.AUTO_OIL_TAKE_SIZE)
  patch(pot + OILAT.OIL_POT_FIRE, { 0xE8, core.itob(core.getRelativeAddress(pot + OILAT.OIL_POT_FIRE, spread, -5)) }, 5)
end

local function try(purpose, fn)
  local ok, message = pcall(fn)
  if not ok then
    log(WARNING, string.format("%s: %s is off: %s", MODULE_NAME, purpose, tostring(message)))
  end
  return ok
end

local function enableCommands()
  local command = G.command
  F.move = core.exposeCode(callTarget(command + CMD_MOVE[1], "the troop move order"), 7, 1)
  F.assign = core.exposeCode(callTarget(command + CMD_ASSIGN[1], "the troop target order"), 3, 1)
  F.setDestination = core.exposeCode(callTarget(scan(AOB_UPDATE_CATAPULT, "the catapult update")
    + CATAPULT_SET_DESTINATION, "setDestinationForUnit"), 5, 1)
  expectBytes(command + CMD_EPILOGUE[1], CMD_EPILOGUE[2], "the end of the AI's siege orders")
  expectBytes(command + CMD_TOWER[1], CMD_TOWER[2], "the AI's siege tower orders")
  expectBytes(command + CMD_SHIELD[1], CMD_SHIELD[2], "the AI's shield orders")
  G.list = core.allocate(4 * 1024, true)
  G.tlist = core.allocate(4 * 256, true)
  local collect = assemble(templates.collect, values({ LIST = G.list }))
  local collectTents = assemble(templates.collectTents, values({ TLIST = G.tlist,
    BUILDINGS = G.buildings }))
  local lua = luaFunction("the shield, siege tower and engineer orders", onSiegeCommand)
  local tail = assemble(templates.commandEnd, { D = G.data, LUA = lua, COLLECT = collect,
    COLLECT_TENTS = collectTents })

  if O.engineers then
    O.engineers = try("engineers into their siege tents", function()
      local order = scan(AOB_INSTRUCTION, "the troop order code")
      F.entrance = core.exposeCode(callTarget(order + INSTRUCTION_ENTRANCE, "the entrance test"), 5, 1)
      F.deselect = core.exposeCode(callTarget(order + INSTRUCTION_DESELECT, "deselectUnit"), 2, 1)
      F.unselect = core.exposeCode(callTarget(order + INSTRUCTION_UNSELECT, "the selection"), 4, 1)
      local engineer = scan(AOB_UPDATE_ENGINEER, "the engineer update")
      F.required = core.exposeCode(callTarget(engineer + ENGINEER_REQUIRED, "the engineer count"), 2, 1)
      local search = freeTileSearch()
      G.pathFinder = operand(search, FREE_TILE_PF, "the path finder")
      F.navigate = core.exposeCode(callTarget(search + FREE_TILE_NAVIGATE[1], "the area test"), 5, 1)
    end)
  end

  if O.towerOrders then
    O.towerOrders = try("siege tower orders", function()
      -- the tower's free-spot search: the module's own when docking is on
      local free = G.freeTile or freeTileSearch()
      local find = assemble(templates.towerFind, values({ FREETILE = free, MAXTESTS = TOWER_TESTS }))
      F.towerFind = core.exposeCode(find, 3, 0)
    end)
    if O.towerOrders then
      -- the game's own tower branch goes straight on to the next unit
      patch(command + CMD_TOWER[1], jumpCode(command + CMD_TOWER[1], command + CMD_NEXT, 7), 7)
    end
  end
  if O.shields then
    patch(command + CMD_SHIELD[1], jumpCode(command + CMD_SHIELD[1], command + CMD_NEXT, 6), 6)
  end
  patch(command + CMD_EPILOGUE[1], jumpCode(command + CMD_EPILOGUE[1], tail, CMD_EPILOGUE_SIZE),
    CMD_EPILOGUE_SIZE)
end

return {

  enable = function(self, config)
    O.catapults = setting(config, "catapults", "enabled")
    O.onTheWay = O.catapults and setting(config, "catapults", "on_the_way")
    O.otherEnemies = O.catapults and setting(config, "catapults", "other_enemies")
    O.standing = setting(config, "catapults", "drop_destroyed")
    O.scatter = number(config, "catapults", "scatter", 0, 100)
    O.freeSpots = setting(config, "tents", "free")
    O.tentRange = setting(config, "tents", "range")
    O.variation = number(config, "tents", "variation", 0, 30)
    O.dock = setting(config, "towers", "dock")
    O.towerOrders = setting(config, "towers", "orders")
    O.shields = setting(config, "shields", "enabled")
    O.engineers = setting(config, "tents", "engineers")
    O.log = setting(config, "diagnostics", "log")
    O.oilAim = setting(config, "oil", "aim")
    O.oilSpread = setting(config, "oil", "spread")
    O.oilAmount = number(config, "oil", "amount", 5, 200)
    O.oilDamage = setting(config, "oil", "damage")
    if not (O.catapults or O.freeSpots or O.tentRange or O.dock or O.towerOrders or O.shields
        or O.engineers or O.standing or O.scatter < 100 or O.oilAim or O.oilSpread) then
      return
    end
    if not try("the whole module", readCommon) then return end

    local state = {}
    state.catapults = O.catapults and try("catapults and trebuchets choosing targets", enableCatapults)
    state.walking = O.onTheWay and state.catapults and try("catapults and trebuchets shooting on the way",
      enableWalking)
    state.scatter = O.scatter < 100 and try("catapult and trebuchet scatter", enableScatter)
    state.standing = O.standing and try("siege engines dropping destroyed targets", enableStandingTargets)
    state.tents = (O.freeSpots or O.tentRange) and try("siege tent placement", enableTents)
    state.dock = O.dock and try("siege tower docking", enableDocking)
    state.oil = (O.oilAim or O.oilSpread) and try("the oil engineers", enableOil)
    state.commands = (O.towerOrders or O.shields or O.engineers)
      and try("shield, siege tower and engineer orders", enableCommands)

    wr32(G.data + 0x00, state.catapults and 1 or 0)
    wr32(G.data + 0x04, (state.tents and O.freeSpots) and 1 or 0)
    wr32(G.data + 0x08, (state.tents and O.tentRange) and 1 or 0)
    wr32(G.data + 0x0C, O.variation)
    wr32(G.data + 0x10, state.dock and 1 or 0)
    wr32(G.data + 0x1F0, (O.log and state.catapults) and 1 or 0)
    wr32(G.data + 0x1F8, O.otherEnemies and 1 or 0)
    if not state.commands then O.shields, O.towerOrders, O.engineers = false, false, false end
    state.towers = state.commands and O.towerOrders
    state.engineers = state.commands and O.engineers

    local function word(on, ready) return not on and "off" or ready and "on" or "unavailable" end
    log(INFO, string.format("%s: oil aim %s, oil spread %s (%d tiles, building damage %s)", MODULE_NAME,
      word(O.oilAim, state.oil), word(O.oilSpread, state.oil), O.oilAmount, O.oilDamage and "on" or "off"))
    log(INFO, string.format("%s: catapults %s, shooting on the way %s, other enemies %s, scatter %s, "
      .. "destroyed targets dropped %s, "
      .. "tent spots %s, tents by range %s "
      .. "(up to %d tiles short), engineers into tents %s, tower docking %s, tower orders %s, shields %s",
      MODULE_NAME, word(O.catapults, state.catapults), word(O.onTheWay, state.walking),
      O.otherEnemies and "on" or "off",
      O.scatter >= 100 and "the game's own" or (state.scatter and (O.scatter .. "%") or "unavailable"),
      word(O.standing, state.standing),
      word(O.freeSpots, state.tents),
      word(O.tentRange, state.tents), O.variation,
      word(setting(config, "tents", "engineers"), state.engineers), word(O.dock, state.dock),
      word(setting(config, "towers", "orders"), state.towers), word(O.shields, state.commands)))
  end,

  disable = function(self, config)
    if G.data ~= nil then
      for offset = 0x00, 0x10, 4 do wr32(G.data + offset, 0) end
      wr32(G.data + 0x1F0, 0)
    end
    O.shields, O.towerOrders, O.engineers = false, false, false
    if G.oil ~= nil then
      for offset = 0x00, 0x0C, 4 do wr32(G.oil + offset, 0) end
    end
    for index = #patched, 1, -1 do
      core.writeCodeBytes(patched[index].address, patched[index].bytes)
    end
    patched = {}
  end,

}
