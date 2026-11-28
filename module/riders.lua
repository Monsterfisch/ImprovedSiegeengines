--[[
  Siege tower passengers.

  Foot soldiers ride on top of a siege tower: up to 9, on the 3x3 square the tower docks with.
  They stay ordinary units the whole time - drawn on the tower's top, moved with it every tick,
  at the docked tower's height (so arrows from below do a third of the damage and swords cannot
  reach them), ranged ones shooting while it rolls. When the tower is destroyed they die with it,
  through the game's own dying path. When it docks they are simply left standing on the docked
  tower, which covers the same 3x3.

  Player: select foot soldiers, point at an own siege tower (the "man the engine" arrows) and
  click - they walk over and climb on as they reach it. Select the tower and point at it (the
  "leave the engine" arrows): the first click puts the passengers down around it, the next one
  the engineers, as in the unmodified game. Passengers cannot be selected.
  AI: every few moments an AI tower takes on its own ranged troops standing within 3 tiles.

  Both orders go through the game's own troop orders (instructions 0x10 and 0x11), so they are
  network commands like any other.

  Who rides where is one 24 byte record per unit, saved with the game through map-extensions:
    +0 passenger uid, +4 tower unit (word), +6 mode (1 on its way, 2 riding), +7 place 0..8,
    +8 tower uid, +0xC/+0xE where the walk was sent (the unit's destination), +0x10/+0x12 the
    tower's tile then.
]]

local riders = {}

local RECORD = 24
local TOWER = 58
local HEIGHT = 0x76          -- getBuildingHeightForBuildingID(69): a docked tower's top
local BOARD_REACH = 2        -- tiles from the tower at which a walking soldier climbs on
local STOP_REACH = 4         -- ... or one that stopped walking
local AI_REACH = 3           -- tiles an AI tower takes ranged troops from
local SAVE_SECTION = "improved-siegeengines-riders"
local SAVE_KEY = "records"

-- All foot soldiers but the special workers (tunnellers, laddermen, engineers) and the lord.
local BOARDABLE = { 22, 23, 24, 25, 26, 27, 37, 70, 71, 72, 73, 75, 76 }
-- What an AI tower takes on: archers, crossbowmen, Arab archers, slingers, fire throwers.
local AI_RANGED = { 22, 23, 70, 72, 76 }
-- The 3x3 places, in micro units from the tower (8 to a tile), in the order they fill up: half
-- a tile apart, which keeps all nine on the moving tower's top deck (its sprite's deck is about
-- 80 by 30 pixels, 118 above the ground point - the docked tower's height).
local HALF_FULL = 5          -- passengers (of 9) from which a tower is one speed step slower
-- setUnitValues: a unit's speed from the table by unit type (read live, so balance changes count).
local AOB_SPEED = "0F B7 04 BD ? ? ? ? 33 D2 66 89 86 60 09 00 00"
local AOB_TILE_BITS = "F6 04 5D ? ? ? ? 10 74 0D 83 BE"
-- All riders stand on the tower's own tile and point; the places are only where they are drawn.
local PLACES = { { -4, -4 }, { 0, -4 }, { 4, -4 }, { -4, 0 }, { 4, 0 }, { -4, 4 }, { 0, 4 },
  { 4, 4 }, { 0, 0 } }
-- selectAllUnitsOfTypeForPlayer (double click): its "inside an engine" test, and the control
-- group recall's "fading out" test - riders are left out of both (and stay in the group).
local AOB_TYPE_SELECT = "66 83 B8 D4 08 00 00 6D 74 ? 0F BF 98 A2 06 00 00 3B 5C 24 10"
local TYPE_SELECT_SIZE = 10
local STANDING_SIZE = 10                  -- mov eax, [esp+4] / imul eax, eax, 0x490
local STANDING_START = { 0x8B, 0x44, 0x24, 0x04, 0x69, 0xC0, 0x90, 0x04, 0x00, 0x00 }
-- renderMap, a unit's height in the flattened view (spacebar): its own height is taken off
-- again, which leaves anything on a building at ground level. Riders keep theirs - the
-- moving tower is a unit and is not flattened.
local AOB_FLAT_HEIGHT = "83 7C 24 24 00 74 ? 0F BE 96 ? ? ? ? 0F BF 8E ? ? ? ? 2B D1 03 15"
local FLAT_HEIGHT = { 0xE, { 0x0F, 0xBF, 0x8E } }   -- movsx ecx, word [esi + unit height]
local FLAT_HEIGHT_SIZE = 7
-- renderMap: whether a unit is drawn at all (its vanish field, which the game's gatehouse fade
-- sets by the unit's own tile and destination). For riders it is decided here instead: hidden
-- inside a gatehouse (types 45-47), shown everywhere else.
local AOB_DRAW_VANISH = "8B 9E ? ? ? ? 85 DB 66 89 96 ? ? ? ? 8B 54 24 34 74"
local DRAW_VANISH_SIZE = 6
local GATEHOUSES = { 45, 47 }
-- The click handler's Shift test (as attack-move finds it): its operand is ModifierKeyState +8
-- (shift), +4 from there is Alt. With Alt held the tower is not offered: the click moves.
-- attack-move hooks the 6 bytes at +0x0C, so they are left open. Not found: Alt is not looked at.
local AOB_SHIFT = "39 3D ? ? ? ? 0F 84 ? ? ? ? ? ? ? ? ? ? 3B CF A1 ? ? ? ? 74 4B 83 F8 0A 89 6C 24 2C 0F 8D"
local SHIFT_TO_ALT = 4
-- updateUnits, every 16 ticks: a unit on a tile of no walkable area (area 0) for 1000 match
-- time is taken out as stuck (state 0x6E) - a rider floats over walls, rocks, buildings and
-- water, so riders are left out of that test (edx = the unit, ecx = its tile).
local AOB_STUCK = "66 83 3C 4D ? ? ? ? 00 0F 85 ? ? ? ? F7 04 8D ? ? ? ? 00 00 00 40"
local STUCK_SIZE = 15
local AOB_GROUP_SELECT = "80 BA 42 09 00 00 00 75 ? 66 89 BA 48 06 00 00"
local GROUP_SELECT_SIZE = 9
local GROUP_NEXT = { 0x1B, { 0x83, 0xC0, 0x08 } }   -- add eax, 8: the next unit of the group

-- giveTribeAnInstruction: its jump table, and the cases for 0x10 (man an engine) and 0x11
-- (leave an engine). Offsets inside both cases are the same in both executables.
local INSTR = {
  INDEX = { 0x5C, { 0x0F, 0xB6, 0x80 } },       -- movzx eax, byte [eax + index table]
  TABLE = { 0x63, { 0xFF, 0x24, 0x85 } },       -- jmp [eax*4 + case table]
  MAN_START = { 0x8B, 0x4C, 0x24, 0x18, 0x8B, 0x54, 0x24, 0x3C },
  MAN_SIZE = 8,
  MAN_MEMBER = 0x54,                            -- call getUnitIDForIndexInTribe
  MAN_DESTINATION = 0x199,                      -- call setDestinationForUnit
  MAN_DESELECT = 0x1D8,                         -- call deselectUnit
  MAN_UNSELECT = 0x1ED,                         -- call clearOrDeselectUnitFromSelection
  LEAVE_START = { 0x8B, 0x44, 0x24, 0x40, 0xF7, 0xD8, 0x1B, 0xC0 },
  LEAVE_SIZE = 6,
  LEAVE_OFFSETS = { 0xF2, { 0x0F, 0xBF, 0x3C, 0x85 } },   -- the 16 spots around an engine
  LEAVE_PF = { 0x130, { 0xB9 } },
  LEAVE_FIND = 0x135,                           -- call findWalkableTileThatDoesNotContainUnit
  LEAVE_TILE = { 0x13A, { 0xA1 } },
  LEAVE_X = { 0x194, { 0x8B, 0x0D } },
  LEAVE_Y = { 0x19A, { 0x8B, 0x15 } },
  LEAVE_HEIGHT = { 0x1A8, { 0x66, 0x0F, 0xB6, 0xB8 } },
  LEAVE_MICRO = 0x20E,                          -- call updateMicroPosition
  LEAVE_RESET = 0x219,                          -- call resetUnitMovementState
  LEAVE_STOP = 0x264,                           -- call makeUnitStopWalkingByClearingPathProgressState
}
-- resetUnitMovementState's neighbour 0x50 before it: clears the walk, marks the unit pending and
-- takes it off its tile's unit list (resetUnitMovementState puts a pending unit back on).
local UNLINK_AT = -0x50
local UNLINK_START = { 0x8B, 0x54, 0x24, 0x04, 0x8B, 0xC2, 0x69, 0xC0, 0x90, 0x04, 0x00, 0x00,
  0x03, 0xC1, 0x56, 0x33, 0xF6 }
-- recomputeUnitStandingHeight(unit): the height of whatever a unit stands on. updateUnits runs
-- it for every unit after its update function, so a rider's height is put back after it.
local AOB_STANDING = "8B 44 24 04 69 C0 90 04 00 00 53 56 8D 34 08 8B 8E ? ? 00 00 8B 04 8D ? ? ? ? 25 00 0D 01 10"
-- The mouse over an own siege engine with a selection (imul esi, esi, 0x490 at the start of the
-- "leave the engine" test); 0x7B before it the "man the engine" test (can the selection walk
-- there, then the order at -0x2A), 0x67 after it the "leave" order.
local AOB_HOVER = "69 F6 90 04 00 00 0F B7 86 ? ? ? ? 66 85 C0 0F 84 ? ? ? ? 66 83 BE ? ? ? ? 00 0F 84"
local HOVER_SIZE = 6
local HOVER_MAN = { -0x2A, { 0xC7, 0x05 }, 3 }
local HOVER_REACH = { -0x7B, { 0x69, 0xF6, 0x90, 0x04, 0x00, 0x00 } }
local HOVER_LEAVE = { 0x67, { 0xC7, 0x05 }, 4 }

local T = {}

-- TAKEN(tower): bit k set when place k carries a living passenger.
T.used = [[
  push ebx
  push esi
  push edi
  push ebp
  mov edi, [esp + 20]
  imul eax, edi, 0x490
  mov ebp, [UNITS + 0x98 + eax]
  xor eax, eax
  mov ecx, 1
.loop:
  cmp ecx, MAXUNITS
  jge .done
  imul esi, ecx, RECORD
  cmp byte [RIDE + esi + 6], 2
  jne .next
  movzx edx, word [RIDE + esi + 4]
  cmp edx, edi
  jne .next
  cmp [RIDE + esi + 8], ebp
  jne .next
  imul ebx, ecx, 0x490
  cmp word [UNITS + 0x8C + ebx], 2
  jne .next
  mov edx, [UNITS + 0x98 + ebx]
  cmp edx, [RIDE + esi]
  jne .next
  cmp word [UNITS + 0x2A0 + ebx], 0
  jne .next
  movzx edx, byte [RIDE + esi + 7]
  bts eax, edx
.next:
  inc ecx
  jmp .loop
.done:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- SEND(unit, tower): walk to the tower, remembering where to.
T.send = [[
  push ebx
  push esi
  push edi
  push ebp
  mov edi, [esp + 20]
  mov ebp, [esp + 24]
  imul ebx, edi, 0x490
  imul esi, edi, RECORD
  imul ebp, ebp, 0x490
  push 0
  movsx eax, word [UNITS + 0xC6 + ebp]
  push eax
  movsx eax, word [UNITS + 0xC4 + ebp]
  push eax
  push edi
  mov ecx, US
  call SETDEST
  mov word [UNITS + 0x2C0 + ebx], 0x65
  mov ax, [UNITS + 0xC8 + ebx]
  mov [RIDE + esi + 0xC], ax
  mov ax, [UNITS + 0xCA + ebx]
  mov [RIDE + esi + 0xE], ax
  mov ax, [UNITS + 0xC4 + ebp]
  mov [RIDE + esi + 0x10], ax
  mov ax, [UNITS + 0xC6 + ebp]
  mov [RIDE + esi + 0x12], ax
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- EJECT(unit, tower): put a passenger down on free ground around the tower, the way the game
-- puts engineers out of an engine.
T.eject = [[
  push ebx
  push esi
  push edi
  push ebp
  mov edi, [esp + 20]
  mov eax, [esp + 24]
  mov [RDAT + 0x24], eax
  imul ebp, eax, 0x490
  imul ebx, edi, 0x490
  imul esi, edi, RECORD
  mov byte [RIDE + esi + 6], 0
  push edi
  mov ecx, US
  call UNLINKP
  mov dword [RDAT + 0x18], 0
.try:
  mov eax, [TICKS]
  add eax, [RDAT + 0x18]
  add eax, edi
  and eax, 15
  movsx ecx, word [OFFS + eax*4]
  movsx edx, word [OFFS + eax*4 + 2]
  movsx eax, word [UNITS + 0xC4 + ebp]
  add ecx, eax
  movsx eax, word [UNITS + 0xC6 + ebp]
  add edx, eax
  mov [RDAT + 0x1C], ecx
  mov [RDAT + 0x20], edx
  push 1
  push edx
  push ecx
  push dword [RDAT + 0x24]
  mov ecx, PF
  call FINDWALK
  cmp dword [RESTILE], 0
  jne .found
  push 0
  push dword [RDAT + 0x20]
  push dword [RDAT + 0x1C]
  push dword [RDAT + 0x24]
  mov ecx, PF
  call FINDWALK
  cmp dword [RESTILE], 0
  jne .found
  inc dword [RDAT + 0x18]
  cmp dword [RDAT + 0x18], 16
  jl .try
  mov eax, [UNITS + 0xD4 + ebp]
  movsx ecx, word [UNITS + 0xC4 + ebp]
  movsx edx, word [UNITS + 0xC6 + ebp]
  jmp .place
.found:
  mov eax, [RESTILE]
  mov ecx, [RESX]
  mov edx, [RESY]
.place:
  mov [UNITS + 0xC4 + ebx], cx
  mov [UNITS + 0xE0 + ebx], cx
  mov [UNITS + 0xC8 + ebx], cx
  mov [UNITS + 0xEC + ebx], cx
  mov [UNITS + 0xC6 + ebx], dx
  mov [UNITS + 0xE2 + ebx], dx
  mov [UNITS + 0xCA + ebx], dx
  mov [UNITS + 0xEE + ebx], dx
  mov [UNITS + 0xD4 + ebx], eax
  mov [UNITS + 0xE4 + ebx], eax
  mov [UNITS + 0xD8 + ebx], eax
  movzx eax, byte [HEIGHTMAP + eax]
  mov [UNITS + 0xBA + ebx], ax
  lea ecx, [ecx*8 + 4]
  lea edx, [edx*8 + 4]
  mov [UNITS + 0xB6 + ebx], cx
  mov [UNITS + 0xB8 + ebx], dx
  mov word [UNITS + 0xFC + ebx], 0
  mov word [UNITS + 0xBC + ebx], 0
  mov word [UNITS + 0x84 + ebx], 0
  mov dword [UNITS + 0x64 + ebx], 0
  mov word [UNITS + 0x2A4 + ebx], 1
  push edi
  mov ecx, US
  call MICROPOS
  push edi
  mov ecx, US
  call RESET
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- EJECTCMD(tower, uid): the player's "leave the engine" order. Puts the passengers down and
-- answers how many; with none, the game's own order goes on and puts the engineers out.
T.ejectCommand = [[
  push ebx
  push esi
  push edi
  push ebp
  mov dword [RDAT + 0x44], 0
  cmp dword [RDAT + 8], 0
  je .done
  mov edi, [esp + 20]
  cmp edi, 1
  jl .done
  cmp edi, MAXUNITS
  jge .done
  imul ebp, edi, 0x490
  mov eax, [esp + 24]
  cmp [UNITS + 0x98 + ebp], eax
  jne .done
  cmp word [UNITS + 0x8E + ebp], TOWER
  jne .done
  cmp word [UNITS + 0x8C + ebp], 2
  jne .done
  mov ecx, 1
.loop:
  cmp ecx, MAXUNITS
  jge .done
  imul esi, ecx, RECORD
  cmp byte [RIDE + esi + 6], 0
  je .next
  movzx edx, word [RIDE + esi + 4]
  cmp edx, edi
  jne .next
  mov edx, [UNITS + 0x98 + ebp]
  cmp edx, [RIDE + esi + 8]
  jne .next
  cmp byte [RIDE + esi + 6], 2
  je .rider
  mov byte [RIDE + esi + 6], 0
  jmp .next
.rider:
  imul ebx, ecx, 0x490
  cmp word [UNITS + 0x8C + ebx], 2
  jne .next
  mov edx, [UNITS + 0x98 + ebx]
  cmp edx, [RIDE + esi]
  jne .next
  cmp word [UNITS + 0x2A0 + ebx], 0
  jne .next
  push ecx
  push edi
  push ecx
  call EJECT
  add esp, 8
  pop ecx
  inc dword [RDAT + 0x44]
.next:
  inc ecx
  jmp .loop
.done:
  mov eax, [RDAT + 0x44]
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- BOARDTRIBE(tribe, tower, uid): the player's "man the engine" order at a siege tower. Sends
-- the troop's foot soldiers there, as many as there are free places.
T.boardTribe = [[
  push ebx
  push esi
  push edi
  push ebp
  cmp dword [RDAT + 8], 0
  je .done
  mov edi, [esp + 24]
  cmp edi, 1
  jl .done
  cmp edi, MAXUNITS
  jge .done
  imul ebp, edi, 0x490
  mov eax, [esp + 28]
  cmp [UNITS + 0x98 + ebp], eax
  jne .done
  cmp word [UNITS + 0x8E + ebp], TOWER
  jne .done
  cmp word [UNITS + 0x8C + ebp], 2
  jne .done
  cmp word [UNITS + 0x2A0 + ebp], 0
  jne .done
  cmp word [UNITS + 0x2C0 + ebp], 9
  je .done
  push edi
  call TAKEN
  add esp, 4
  mov ecx, 9
.count:
  test eax, eax
  jz .counted
  lea edx, [eax - 1]
  and eax, edx
  dec ecx
  jmp .count
.counted:
  mov [RDAT + 0x10], ecx
  mov dword [RDAT + 0x14], 0
.member:
  cmp dword [RDAT + 0x10], 0
  jle .done
  mov eax, [esp + 20]
  cmp eax, 1
  jl .done
  cmp eax, MAXTRIBES
  jge .done
  imul edx, eax, TSTRIDE
  movsx edx, word [TRIBES + 0x5C + edx]
  cmp [RDAT + 0x14], edx
  jge .done
  push dword [RDAT + 0x14]
  push eax
  mov ecx, TRIBES
  call GETMEMBER
  inc dword [RDAT + 0x14]
  cmp eax, 1
  jl .member
  cmp eax, MAXUNITS
  jge .member
  mov esi, eax
  imul ebx, esi, 0x490
  cmp word [UNITS + 0x8C + ebx], 2
  jne .member
  cmp word [UNITS + 0x2A0 + ebx], 0
  jne .member
  cmp word [UNITS + 0x2A4 + ebx], 0
  je .member
  mov ax, [UNITS + 0x96 + ebx]
  cmp ax, [UNITS + 0x96 + ebp]
  jne .member
  movzx eax, word [UNITS + 0x8E + ebx]
  cmp eax, 80
  jae .member
  cmp byte [BOARDABLE + eax], 0
  je .member
  imul ecx, esi, RECORD
  cmp byte [RIDE + ecx + 6], 0
  je .take
  mov eax, [UNITS + 0x98 + ebx]
  cmp eax, [RIDE + ecx]
  je .member
.take:
  mov eax, [UNITS + 0x98 + ebx]
  mov [RIDE + ecx], eax
  mov [RIDE + ecx + 4], di
  mov byte [RIDE + ecx + 6], 1
  mov byte [RIDE + ecx + 7], 0
  mov eax, [UNITS + 0x98 + ebp]
  mov [RIDE + ecx + 8], eax
  push edi
  push esi
  call SEND
  add esp, 8
  dec dword [RDAT + 0x10]
  jmp .member
.done:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- Climbing on only takes a soldier out of the selection (what clearOrDeselectUnitFromSelection does
-- after it has removed the unit from its troop): it stays in its troop, so the troop's stance is
-- its stance again once the tower has docked - aggressive troops go for the enemies on the walls.
-- PRE(unit): before a rider's own update. 1 = riding on (move it with the tower after the
-- update), 0 = not riding (any more): on its way, put down, killed or released.
T.pre = [[
  push ebx
  push esi
  push edi
  push ebp
  mov edi, [esp + 20]
  imul esi, edi, RECORD
  imul ebx, edi, 0x490
  mov eax, [UNITS + 0x98 + ebx]
  cmp eax, [RIDE + esi]
  jne .clear
  cmp word [UNITS + 0x8C + ebx], 2
  jne .clear
  cmp word [UNITS + 0x2A0 + ebx], 0
  jne .fallen
  movzx ebp, word [RIDE + esi + 4]
  cmp ebp, MAXUNITS
  jae .clear
  imul ebp, ebp, 0x490
  cmp word [UNITS + 0x8C + ebp], 2
  jne .gone
  mov eax, [UNITS + 0x98 + ebp]
  cmp eax, [RIDE + esi + 8]
  jne .gone
  cmp word [UNITS + 0x8E + ebp], TOWER
  jne .gone
  cmp byte [RIDE + esi + 6], 1
  je .boarding
  cmp word [UNITS + 0x2A0 + ebp], 0
  jne .kill
  mov ax, [UNITS + 0x96 + ebp]
  cmp ax, [UNITS + 0x96 + ebx]
  jne .off
  cmp word [UNITS + 0x2C0 + ebp], 9
  je .release
  mov eax, 1
  jmp .out
.gone:
  cmp byte [RIDE + esi + 6], 2
  jne .clear
.kill:
  mov dword [UNITS + 0x3C8 + ebx], 0
  mov word [UNITS + 0x2A0 + ebx], 1
  mov dword [UNITS + 0x2B0 + ebx], 0
  mov word [UNITS + 0x2C0 + ebx], 0x72
  mov word [UNITS + 0xF6 + ebx], 1
  mov ax, [UNITS + 0x400 + ebp]
  mov [UNITS + 0x400 + ebx], ax
  mov ax, [UNITS + 0x436 + ebp]
  mov [UNITS + 0x436 + ebx], ax
.fallen:
  cmp byte [RIDE + esi + 6], 2
  jne .clear
  mov word [UNITS + 0xBC + ebx], 0
  mov dword [UNITS + 0x64 + ebx], 0
  jmp .clear
.off:
  movzx eax, word [RIDE + esi + 4]
  push eax
  push edi
  call EJECT
  add esp, 8
  xor eax, eax
  jmp .out
.release:
  mov byte [RIDE + esi + 6], 0
  mov word [UNITS + 0x2A4 + ebx], 1
  push edi
  mov ecx, US
  call STANDING
  xor eax, eax
  jmp .out
.clear:
  mov byte [RIDE + esi + 6], 0
  xor eax, eax
  jmp .out
.boarding:
  cmp word [UNITS + 0x2A0 + ebp], 0
  jne .clear
  cmp word [UNITS + 0x2C0 + ebp], 9
  je .clear
  mov ax, [UNITS + 0x96 + ebp]
  cmp ax, [UNITS + 0x96 + ebx]
  jne .clear
  mov ax, [UNITS + 0xC8 + ebx]
  cmp ax, [RIDE + esi + 0xC]
  jne .clear
  mov ax, [UNITS + 0xCA + ebx]
  cmp ax, [RIDE + esi + 0xE]
  jne .clear
  movsx eax, word [UNITS + 0xC4 + ebx]
  movsx ecx, word [UNITS + 0xC4 + ebp]
  sub eax, ecx
  cdq
  xor eax, edx
  sub eax, edx
  mov ecx, eax
  movsx eax, word [UNITS + 0xC6 + ebx]
  movsx edx, word [UNITS + 0xC6 + ebp]
  sub eax, edx
  cdq
  xor eax, edx
  sub eax, edx
  cmp eax, ecx
  jge .far
  mov eax, ecx
.far:
  cmp eax, BOARDREACH
  jle .board
  cmp word [UNITS + 0x2C0 + ebx], 0x65
  jne .stopped
  mov ecx, [TICKS]
  add ecx, edi
  test ecx, 15
  jnz .walk
  mov cx, [UNITS + 0xC4 + ebp]
  cmp cx, [RIDE + esi + 0x10]
  jne .resend
  mov cx, [UNITS + 0xC6 + ebp]
  cmp cx, [RIDE + esi + 0x12]
  je .walk
.resend:
  movzx eax, word [RIDE + esi + 4]
  push eax
  push edi
  call SEND
  add esp, 8
.walk:
  xor eax, eax
  jmp .out
.stopped:
  cmp eax, STOPREACH
  jg .clear
.board:
  movzx eax, word [RIDE + esi + 4]
  push eax
  call TAKEN
  add esp, 4
  not eax
  and eax, 0x1FF
  jz .clear
  bsf ecx, eax
  mov [RIDE + esi + 7], cl
  mov byte [RIDE + esi + 6], 2
  movzx eax, word [RIDE + esi + 4]
  imul eax, eax, 9
  add eax, ecx
  mov [TSLOT + eax*2], di
  push edi
  mov ecx, US
  call DESELECT
  cmp word [UNITS + 0xB2 + ebx], 0
  je .unselected
  mov word [UNITS + 0xB2 + ebx], 0
  movsx eax, word [UNITS + 0x96 + ebx]
  dec dword [US + 0x24 + eax*4]
.unselected:
  mov word [UNITS + 0x2A4 + ebx], 0
  push edi
  mov ecx, US
  call STOPWALK
  mov eax, 1
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- PIN(unit): after a rider's own update, put it back on its place on the tower: on the tile
-- under that place (moving it from one tile's unit list to the other's the game's way), at the
-- tower's top, drawn after the tower, standing still, not selectable.
T.pin = [[
  push ebx
  push esi
  push edi
  push ebp
  mov edi, [esp + 20]
  imul esi, edi, RECORD
  cmp byte [RIDE + esi + 6], 2
  jne .out
  imul ebx, edi, 0x490
  cmp word [UNITS + 0x8C + ebx], 2
  jne .out
  cmp word [UNITS + 0x2A0 + ebx], 0
  jne .out
  movzx ebp, word [RIDE + esi + 4]
  test ebp, ebp
  jz .out
  cmp ebp, MAXUNITS
  jae .out
  imul ebp, ebp, 0x490
  movzx eax, word [UNITS + 0xB6 + ebp]
  mov [RDAT + 0x30], eax
  movzx eax, word [UNITS + 0xB8 + ebp]
  mov [RDAT + 0x34], eax
  movsx eax, word [UNITS + 0xC4 + ebp]
  mov [RDAT + 0x38], eax
  movsx eax, word [UNITS + 0xC6 + ebp]
  mov [RDAT + 0x3C], eax
  mov eax, [UNITS + 0xD4 + ebp]
  mov [RDAT + 0x40], eax
  cmp eax, [UNITS + 0xD4 + ebx]
  je .same
  push edi
  mov ecx, US
  call UNLINKP
  call .write
  mov eax, [RDAT + 0x40]
  mov [UNITS + 0xD4 + ebx], eax
  mov [UNITS + 0xE4 + ebx], eax
  mov dword [UNITS + 0xE8 + ebx], 0
  push edi
  mov ecx, US
  call RESET
  jmp .common
.same:
  call .write
.common:
  mov ax, [UNITS + 0xBA + ebp]
  mov [UNITS + 0xBA + ebx], ax
  mov word [UNITS + 0xBC + ebx], HEIGHT
  mov eax, [RDAT + 0x0C]
  neg eax
  mov [UNITS + 0x84 + ebx], ax
  mov dword [UNITS + 0x64 + ebx], 2
  mov word [UNITS + 0x2A4 + ebx], 0
  mov word [UNITS + 0x3FC + ebx], 0
  cmp word [UNITS + 0xFC + ebx], 0
  jne .stop
  cmp word [UNITS + 0xF6 + ebx], 0
  je .stand
.stop:
  push edi
  mov ecx, US
  call STOPWALK
  mov word [UNITS + 0xF6 + ebx], 0
  mov word [UNITS + 0x2D2 + ebx], 0
.stand:
  mov ax, [UNITS + 0xC4 + ebx]
  mov [UNITS + 0xC8 + ebx], ax
  mov [UNITS + 0xEC + ebx], ax
  mov ax, [UNITS + 0xC6 + ebx]
  mov [UNITS + 0xCA + ebx], ax
  mov [UNITS + 0xEE + ebx], ax
  mov eax, [UNITS + 0xD4 + ebx]
  mov [UNITS + 0xD8 + ebx], eax
  push edi
  mov ecx, US
  call MICROPOS
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
.write:
  mov eax, [RDAT + 0x30]
  mov [UNITS + 0xB6 + ebx], ax
  mov eax, [RDAT + 0x34]
  mov [UNITS + 0xB8 + ebx], ax
  mov eax, [RDAT + 0x38]
  mov [UNITS + 0xC4 + ebx], ax
  mov [UNITS + 0xE0 + ebx], ax
  mov eax, [RDAT + 0x3C]
  mov [UNITS + 0xC6 + ebx], ax
  mov [UNITS + 0xE2 + ebx], ax
  ret
]]

-- AIBOARD(tower): an AI tower takes on its own ranged troops standing close by (on the ground,
-- not yet riding), until its 9 places are full. The targeted build uses the same
-- seat assignment for one eligible infantry unit, without the proximity filter.
T.aiBoard = [[
  push ebx
  push esi
  push edi
  push ebp
  mov edi, [esp + 20]
  imul ebp, edi, 0x490
  cmp word [UNITS + 0x8C + ebp], 2
  jne .done
  cmp word [UNITS + 0x2A0 + ebp], 0
  jne .done
  cmp word [UNITS + 0x2C0 + ebp], 9
  je .done
  push edi
  call TAKEN
  add esp, 4
  mov [RDAT + 0x50], eax
if TARGETED
  mov ecx, [esp + 24]
else
  mov ecx, 1
end if
.loop:
  cmp dword [RDAT + 0x50], 0x1FF
  je .done
  cmp ecx, MAXUNITS
  jge .done
  imul ebx, ecx, 0x490
  cmp word [UNITS + 0x8C + ebx], 2
  jne .next
  cmp word [UNITS + 0x2A0 + ebx], 0
  jne .next
  cmp word [UNITS + 0x2A4 + ebx], 0
  je .next
  mov ax, [UNITS + 0x96 + ebx]
  cmp ax, [UNITS + 0x96 + ebp]
  jne .next
  movzx eax, word [UNITS + 0x8E + ebx]
  cmp eax, 80
  jae .next
if TARGETED
  cmp byte [BOARDABLE + eax], 0
else
  cmp byte [AIRANGED + eax], 0
end if
  je .next
  cmp word [UNITS + 0xBC + ebx], 0
  jne .next
if TARGETED = 0
  movsx eax, word [UNITS + 0xC4 + ebx]
  movsx edx, word [UNITS + 0xC4 + ebp]
  sub eax, edx
  add eax, AIREACH
  cmp eax, AIREACH * 2
  ja .next
  movsx eax, word [UNITS + 0xC6 + ebx]
  movsx edx, word [UNITS + 0xC6 + ebp]
  sub eax, edx
  add eax, AIREACH
  cmp eax, AIREACH * 2
  ja .next
end if
  imul esi, ecx, RECORD
  cmp byte [RIDE + esi + 6], 0
  je .take
  mov eax, [UNITS + 0x98 + ebx]
  cmp eax, [RIDE + esi]
  je .next
.take:
  mov eax, [RDAT + 0x50]
  not eax
  and eax, 0x1FF
  bsf edx, eax
  bts dword [RDAT + 0x50], edx
  mov [RIDE + esi + 7], dl
  mov eax, [UNITS + 0x98 + ebx]
  mov [RIDE + esi], eax
  mov [RIDE + esi + 4], di
  mov eax, [UNITS + 0x98 + ebp]
  mov [RIDE + esi + 8], eax
  mov byte [RIDE + esi + 6], 2
  imul eax, edi, 9
  add eax, edx
  mov [TSLOT + eax*2], cx
  mov word [UNITS + 0x2A4 + ebx], 0
  push ecx
  push ecx
  mov ecx, US
  call STOPWALK
  pop ecx
if TARGETED
  mov eax, 1
  jmp .return
.next:
else
.next:
  inc ecx
  jmp .loop
end if
.done:
if TARGETED
  xor eax, eax
.return:
end if
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- In the unit update table for foot soldiers and siege towers: riders are moved with their
-- tower after their own update; AI towers look for ranged troops every 32 ticks.
T.update = [[
  mov eax, [CURRENT]
  imul ecx, eax, RECORD
  cmp byte [RIDE + ecx + 6], 0
  jne .rider
  imul ecx, eax, 0x490
  cmp word [UNITS + 0x8E + ecx], TOWER
  jne .orig
  movsx edx, word [UNITS + 0x96 + ecx]
  cmp edx, 1
  jl .tower
  cmp edx, 8
  jg .tower
  imul edx, edx, PSTRIDE
  cmp dword [AITYPE + edx], 0
  je .tower
  cmp dword [RDAT + 0x64], 0
  je .auto
  call CREWPOLICY
  cmp dword [RDAT + 0x68], 0
  jne .tower
.auto:
  cmp dword [RDAT + 4], 0
  je .tower
  mov eax, [CURRENT]
  mov edx, [TICKS]
  add edx, eax
  test edx, 31
  jnz .tower
  push eax
  call AIBOARD
  add esp, 4
.tower:
  if SPEEDS <> 0
  push dword [CURRENT]
  call TAKEN
  add esp, 4
  xor ecx, ecx
.bits:
  test eax, eax
  jz .counted
  lea edx, [eax - 1]
  and eax, edx
  inc ecx
  jmp .bits
.counted:
  mov edx, [SPEEDS + TOWER*4]
  cmp ecx, HALFFULL
  jl .speed
  inc edx
.speed:
  mov eax, [CURRENT]
  imul eax, eax, 0x490
  mov [UNITS + 0x34C + eax], dx
  end if
.run:
  push dword [CURRENT]
  call dword [ORIGS + TOWER*4]
  call PINALL
  add esp, 4
  ret
.orig:
  mov eax, [CURRENT]
  imul eax, eax, 0x490
  movsx eax, word [UNITS + 0x8E + eax]
  jmp dword [ORIGS + eax*4]
.rider:
  push eax
  call PRE
  test eax, eax
  jz .plain
  mov eax, [esp]
  imul eax, eax, 0x490
  movsx eax, word [UNITS + 0x8E + eax]
  call dword [ORIGS + eax*4]
  call PIN
  add esp, 4
  ret
.plain:
  add esp, 4
  jmp .orig
]]

-- SELINF: does the local player have a foot soldier selected?
T.selectedInfantry = [[
  push ebx
  mov ecx, 1
.loop:
  cmp ecx, MAXUNITS
  jge .none
  imul ebx, ecx, 0x490
  cmp word [UNITS + 0x34 + ebx], 0
  je .next
  cmp word [UNITS + 0x8C + ebx], 2
  jne .next
  movsx eax, word [UNITS + 0x96 + ebx]
  cmp eax, [CURPLAYER]
  jne .next
  movzx eax, word [UNITS + 0x8E + ebx]
  cmp eax, 80
  jae .next
  cmp byte [BOARDABLE + eax], 0
  je .next
  mov eax, 1
  jmp .done
.next:
  inc ecx
  jmp .loop
.none:
  xor eax, eax
.done:
  pop ebx
  ret
]]

-- The mouse over an own siege engine (esi = its index): over an own movable siege tower with
-- foot soldiers selected, a place free and Alt not held, the game's "man the engine" test (which shows the
-- move arrow instead when they cannot walk there); over a selected one with
-- passengers, "leave the engine". Anything else: the game's own test.
T.hover = [[
  pushad
  cmp dword [RDAT + 8], 0
  je .vanilla
  imul edi, esi, 0x490
  cmp word [UNITS + 0x8E + edi], TOWER
  jne .vanilla
  cmp word [UNITS + 0x8C + edi], 2
  jne .vanilla
  movsx eax, word [UNITS + 0x96 + edi]
  cmp eax, [CURPLAYER]
  jne .vanilla
  cmp word [UNITS + 0x2C0 + edi], 9
  je .vanilla
  push esi
  call TAKEN
  add esp, 4
  cmp word [UNITS + 0x34 + edi], 0
  jne .selected
  cmp dword [ALT], 0
  jne .vanilla
  and eax, 0x1FF
  cmp eax, 0x1FF
  je .vanilla
  call SELINF
  test eax, eax
  jz .vanilla
  popad
  jmp GOMAN
.selected:
  test eax, eax
  jz .vanilla
  popad
  imul esi, esi, 0x490
  jmp GOLEAVE
.vanilla:
  popad
  imul esi, esi, 0x490
  jmp BACK
]]

-- giveTribeAnInstruction 0x10 (man an engine, edi = the engine): foot soldiers of the troop
-- head for a siege tower first, then the game's own case sends its engineers.
T.man = [[
  pushad
  push dword [esp + 0x3C + 32]
  push edi
  push dword [esp + 0x30 + 40]
  call BOARDTRIBE
  add esp, 12
  popad
  mov ecx, [esp + 0x18]
  mov edx, [esp + 0x3C]
  jmp BACK
]]

-- giveTribeAnInstruction 0x11 (leave an engine): passengers first; only with none on the
-- tower does the game's own case put the engineers out.
T.leave = [[
  pushad
  push dword [esp + 0x3C + 32]
  push edi
  call EJECTCMD
  add esp, 8
  test eax, eax
  popad
  jnz .done
  mov eax, [esp + 0x40]
  neg eax
  jmp BACK
.done:
  pop edi
  pop esi
  pop ebp
  mov eax, 1
  pop ebx
  add esp, 0x1C
  ret 0x14
]]

-- Double click (eax = the unit in UnitsState terms, edx = its index): riders are not picked.
T.typeSelect = [[
  cmp word [eax + 0x8D4], 0x6D
  je SKIP
  push ecx
  imul ecx, edx, RECORD
  cmp byte [RIDE + ecx + 6], 2
  jne .no
  push edx
  mov edx, [eax + 0x6AC]
  cmp edx, [RIDE + ecx]
  pop edx
  pop ecx
  je SKIP
  jmp BACK
.no:
  pop ecx
  jmp BACK
]]

-- Control group recall (eax = the group entry: unit, uid; ebp = the uid): riders are not
-- selected but stay in the group.
T.groupSelect = [[
  cmp byte [edx + 0x942], 0
  jne REMOVE
  push ecx
  mov ecx, [eax]
  imul ecx, ecx, RECORD
  cmp byte [RIDE + ecx + 6], 2
  jne .no
  cmp ebp, [RIDE + ecx]
  pop ecx
  je NEXT
  jmp BACK
.no:
  pop ecx
  jmp BACK
]]

-- recomputeUnitStandingHeight, wrapped: the game's own answer, then for a rider the tower's
-- top (HEIGHT) and the draw lift.
T.standingOrig = [[
  mov eax, [esp + 4]
  imul eax, eax, 0x490
  jmp BACK
]]
T.standing = [[
  push dword [esp + 4]
  call ORIGINAL
  mov eax, [esp + 4]
  cmp eax, 1
  jl .done
  cmp eax, MAXUNITS
  jge .done
  imul ecx, eax, 0x490
  cmp word [UNITS + 0x8E + ecx], TOWER
  jne .unit
  cmp word [UNITS + 0x2C0 + ecx], 9
  je .done
  push eax
  call PINALL
  add esp, 4
  ret 4
.unit:
  imul ecx, eax, RECORD
  cmp byte [RIDE + ecx + 6], 2
  jne .done
  imul eax, eax, 0x490
  mov edx, [UNITS + 0x98 + eax]
  cmp edx, [RIDE + ecx]
  jne .done
  cmp word [UNITS + 0x2A0 + eax], 0
  jne .done
  movzx edx, word [RIDE + ecx + 4]
  test edx, edx
  jz .done
  cmp edx, MAXUNITS
  jae .done
  imul edx, edx, 0x490
  mov cx, [UNITS + 0xBA + edx]
  mov [UNITS + 0xBA + eax], cx
  mov word [UNITS + 0xBC + eax], HEIGHT
  mov ecx, [RDAT + 0x0C]
  neg ecx
  mov [UNITS + 0x84 + eax], cx
.done:
  ret 4
]]

-- The flattened view (esi = the unit * 0x490): a rider's height counts as 0 here, so it is
-- drawn at the tower's top as in the ordinary view.
T.flatHeight = [[
  push eax
  push edx
  mov eax, esi
  xor edx, edx
  mov ecx, 0x490
  div ecx
  cmp eax, MAXUNITS
  jae .no
  imul eax, eax, RECORD
  cmp byte [RIDE + eax + 6], 2
  jne .no
  mov edx, [UNITS + 0x98 + esi]
  cmp edx, [RIDE + eax]
  jne .no
  pop edx
  pop eax
  xor ecx, ecx
  jmp BACK
.no:
  pop edx
  pop eax
  movsx ecx, word [UNITS + 0xBC + esi]
  jmp BACK
]]

-- PINALL(tower): right after the tower has moved, every rider back on its place - so none of
-- them is a tick behind (those updated before the tower) and the nine stay in step.
T.pinAll = [[
  push ebx
  push esi
  push edi
  mov edi, [esp + 16]
  imul ebx, edi, 9
  xor esi, esi
.loop:
  lea eax, [ebx + esi]
  movzx eax, word [TSLOT + eax*2]
  test eax, eax
  jz .next
  cmp eax, MAXUNITS
  jae .next
  imul ecx, eax, RECORD
  cmp byte [RIDE + ecx + 6], 2
  jne .next
  movzx edx, word [RIDE + ecx + 4]
  cmp edx, edi
  jne .next
  movzx edx, byte [RIDE + ecx + 7]
  cmp edx, esi
  jne .next
  imul edx, eax, 0x490
  mov edx, [UNITS + 0x98 + edx]
  cmp edx, [RIDE + ecx]
  jne .next
  imul edx, edi, 0x490
  mov edx, [UNITS + 0x98 + edx]
  cmp edx, [RIDE + ecx + 8]
  jne .next
  push eax
  call PIN
  add esp, 4
.next:
  inc esi
  cmp esi, 9
  jl .loop
  pop edi
  pop esi
  pop ebx
  ret
]]

-- renderMap, where it reads whether to draw a unit (esi = the unit * 0x490, ebx = its vanish
-- field; di / cx = where it is drawn): a rider is drawn unless it or its tower stands in a
-- gatehouse, on its place on the deck, and always after the tower: the queue of units is a ring
-- of five map rows, +0x64 = 2 waits 5 rows, 1 waits 4. A tower is drawn at once, except on the
-- display bit 0x10 (by buildings), where the game queues it 5 rows too: a loaded one then waits 4.
T.drawVanish = [[
  mov ebx, [UNITS + 0x68 + esi]
  push eax
  push ecx
  push edx
  mov eax, esi
  xor edx, edx
  mov ecx, 0x490
  div ecx
  cmp eax, MAXUNITS
  jae .done
  cmp word [UNITS + 0x8E + esi], TOWER
  je .tower
  imul eax, eax, RECORD
  cmp byte [RIDE + eax + 6], 2
  jne .done
  mov edx, [UNITS + 0x98 + esi]
  cmp edx, [RIDE + eax]
  jne .done
  movzx ecx, byte [RIDE + eax + 7]
  add di, [SLOTS + ecx*4]
  mov [UNITS + 0x14 + esi], di
  mov cx, [SLOTS + ecx*4 + 2]
  add [esp + 4], cx
  mov cx, [esp + 4]
  mov [UNITS + 0x16 + esi], cx
  mov dword [UNITS + 0x64 + esi], 2
  xor ebx, ebx
  mov edx, [UNITS + 0xD4 + esi]
  call .gate
  movzx edx, word [RIDE + eax + 4]
  test edx, edx
  jz .done
  cmp edx, MAXUNITS
  jae .done
  imul edx, edx, 0x490
  mov edx, [UNITS + 0xD4 + edx]
  call .gate
.done:
  pop edx
  pop ecx
  pop eax
  jmp BACK
.tower:
  if TILEBITS <> 0
  cmp dword [UNITS + 0x64 + esi], 0
  jne .done
  mov edx, [UNITS + 0xD4 + esi]
  cmp edx, TILES
  jae .done
  test byte [TILEBITS + edx*2], 0x10
  jz .done
  push eax
  call TAKEN
  add esp, 4
  test eax, eax
  jz .done
  mov dword [UNITS + 0x64 + esi], 1
  end if
  jmp .done
.gate:
  cmp edx, TILES
  jae .out
  movsx ecx, word [BIDS + edx*2]
  test ecx, ecx
  jle .out
  imul ecx, ecx, 0x32C
  movsx ecx, word [BTYPE + ecx]
  cmp ecx, GATEFIRST
  jl .out
  cmp ecx, GATELAST
  jg .out
  mov ebx, 1
.out:
  ret
]]

T.stuck = [[
  push eax
  imul eax, edx, RECORD
  cmp byte [RIDE + eax + 6], 2
  pop eax
  je SKIP
  cmp word [AREA + ecx*2], 0
  jne SKIP
  jmp BACK
]]

riders.templates = T

function riders.enable(env)
  local G, rd32, wr32 = env.G, env.rd32, env.wr32
  local scan, expectBytes, operand, callTarget = env.scan, env.expectBytes, env.operand, env.callTarget
  local byte = function(address) return core.readByte(address) & 0xFF end

  -- the unit update table
  local call = scan(env.aob.updateCall, "where every unit's update function is called")
  local tableAt = operand(call, env.aob.updateTable, "the unit update table")
  expectBytes(call + env.aob.currentAt, { 0xA1 }, "the current unit")
  local current = rd32(call + env.aob.currentAt + 1)

  -- the troop orders
  local order = scan(env.aob.instruction, "the troop order code")
  local index = operand(order, INSTR.INDEX, "the troop order cases")
  local cases = operand(order, INSTR.TABLE, "the troop order cases")
  local function case(instruction) return rd32(cases + 4 * byte(index + instruction - 3)) end
  local man, leave = case(0x10), case(0x11)
  expectBytes(man, INSTR.MAN_START, "the order to man an engine")
  expectBytes(leave, INSTR.LEAVE_START, "the order to leave an engine")
  local reset = callTarget(leave + INSTR.LEAVE_RESET, "resetUnitMovementState")
  expectBytes(reset + UNLINK_AT, UNLINK_START, "taking a unit off its tile")

  local hover = scan(AOB_HOVER, "the mouse over an own siege engine")
  for _, site in ipairs({ HOVER_MAN, HOVER_LEAVE }) do
    expectBytes(hover + site[1], site[2], "the man / leave the engine orders")
    if rd32(hover + site[1] + 6) ~= site[3] then
      error("the man / leave the engine orders are not the ones this module knows", 0)
    end
  end
  expectBytes(hover + HOVER_REACH[1], HOVER_REACH[2], "the man the engine test")
  local move = scan(env.aob.moveCommand, "the move order")

  local standing = scan(AOB_STANDING, "the height a unit stands at")
  expectBytes(standing, STANDING_START, "the height a unit stands at")
  local flat = scan(AOB_FLAT_HEIGHT, "a unit's height in the flattened view") + FLAT_HEIGHT[1]
  if env.operand(flat - FLAT_HEIGHT[1], FLAT_HEIGHT, "a unit's height in the flattened view")
      ~= G.units + 0xBC then
    error("the flattened view's unit height is not the one this module knows", 0)
  end
  local vanish = scan(AOB_DRAW_VANISH, "whether a unit is drawn")
  if rd32(vanish + 2) ~= G.units + 0x68 then
    error("whether a unit is drawn is not decided the way this module knows", 0)
  end
  local ok, shift = pcall(scan, AOB_SHIFT, "the Shift and Alt keys")
  local alt
  if ok then
    alt = rd32(shift + 2) + SHIFT_TO_ALT
  else
    alt = core.allocate(4, true)
    log(ERROR, "Using Alt to keep troops off siege towers is off.")
    log(WARNING, "improved-siegeengines: Alt does not keep troops off a siege tower: " .. tostring(shift))
  end
  local stuck = scan(AOB_STUCK, "the stuck unit test")
  if rd32(stuck + 4) ~= G.area then
    error("the stuck unit test does not read the area map this module knows", 0)
  end
  local typeSelect = scan(AOB_TYPE_SELECT, "selecting all units of a kind")
  local groupSelect = scan(AOB_GROUP_SELECT, "selecting a control group")
  expectBytes(groupSelect + GROUP_NEXT[1], GROUP_NEXT[2], "selecting a control group")

  local function optionalOperand(pattern, description, offset)
    local resolved, address = pcall(scan, pattern, description)
    if resolved then return rd32(address + offset) end
    log(ERROR, description .. " is off.")
    log(WARNING, tostring(address))
    return 0
  end
  local tileBits = optionalOperand(AOB_TILE_BITS, "siege tower draw ordering", 3)
  local speeds = env.slow and optionalOperand(AOB_SPEED, "loaded siege tower slowdown", 4) or 0
  local ride = core.allocate(G.maxUnits * RECORD, true)
  local tslot = core.allocate(G.maxUnits * 9 * 2, true)
  local rd = core.allocate(0x100, true)
  wr32(rd + 0x0C, env.lift or 0)
  wr32(rd + 0x04, env.ai and 1 or 0)
  wr32(rd + 0x08, env.player and 1 or 0)
  local boardable, ranged = core.allocate(80, true), core.allocate(80, true)
  for _, kind in ipairs(BOARDABLE) do core.writeByte(boardable + kind, 1) end
  for _, kind in ipairs(AI_RANGED) do core.writeByte(ranged + kind, 1) end
  local slots = core.allocate(4 * #PLACES, true)
  for i, place in ipairs(PLACES) do
    core.writeSmallInteger(slots + 4 * (i - 1), (2 * (place[1] - place[2])) & 0xFFFF)
    core.writeSmallInteger(slots + 4 * (i - 1) + 2, (place[1] + place[2]) & 0xFFFF)
  end
  local originals = core.allocate(80 * 4, true)
  for kind = 0, 79 do wr32(originals + kind * 4, rd32(tableAt + kind * 4)) end

  local v = {
    UNITS = G.units, US = G.unitsState, TRIBES = G.tribes, TSTRIDE = G.tribeStride,
    MAXUNITS = G.maxUnits, MAXTRIBES = env.maxTribes, TICKS = G.ticks, CURRENT = current,
    SPEEDS = speeds, HALFFULL = HALF_FULL, TILEBITS = tileBits,
    ALT = alt, RIDE = ride, TSLOT = tslot, RDAT = rd, RECORD = RECORD, TILES = 0x13A10,
    BIDS = G.buildingIds, BTYPE = G.buildingType, GATEFIRST = GATEHOUSES[1], GATELAST = GATEHOUSES[2], TOWER = TOWER, HEIGHT = HEIGHT,
    BOARDREACH = BOARD_REACH, STOPREACH = STOP_REACH, AIREACH = AI_REACH,
    BOARDABLE = boardable, AIRANGED = ranged, SLOTS = slots, ORIGS = originals,
    TILEAT = G.tileAt, PSTRIDE = env.playerStride, AITYPE = env.aiType,
    CURPLAYER = operand(move, env.aob.localPlayer, "the local player"),
    GETMEMBER = callTarget(man + INSTR.MAN_MEMBER, "the troop's units"),
    SETDEST = callTarget(man + INSTR.MAN_DESTINATION, "setDestinationForUnit"),
    DESELECT = callTarget(man + INSTR.MAN_DESELECT, "deselectUnit"),
    UNSELECT = callTarget(man + INSTR.MAN_UNSELECT, "the selection"),
    OFFS = operand(leave, INSTR.LEAVE_OFFSETS, "the spots around an engine"),
    PF = operand(leave, INSTR.LEAVE_PF, "the path finder"),
    FINDWALK = callTarget(leave + INSTR.LEAVE_FIND, "the free spot search"),
    RESTILE = operand(leave, INSTR.LEAVE_TILE, "the free spot search"),
    RESX = operand(leave, INSTR.LEAVE_X, "the free spot search"),
    RESY = operand(leave, INSTR.LEAVE_Y, "the free spot search"),
    HEIGHTMAP = operand(leave, INSTR.LEAVE_HEIGHT, "the terrain height"),
    MICROPOS = callTarget(leave + INSTR.LEAVE_MICRO, "updateMicroPosition"),
    RESET = reset, UNLINKP = reset + UNLINK_AT,
    STOPWALK = callTarget(leave + INSTR.LEAVE_STOP, "stopping a unit"),
    STANDING = standing,
  }
  local assemble = env.assemble
  v.TAKEN = assemble(T.used, v)
  v.SEND = assemble(T.send, v)
  v.EJECT = assemble(T.eject, v)
  v.EJECTCMD = assemble(T.ejectCommand, v)
  v.BOARDTRIBE = assemble(T.boardTribe, v)
  v.PRE = assemble(T.pre, v)
  v.PIN = assemble(T.pin, v)
  v.PINALL = assemble(T.pinAll, v)
  v.TARGETED = 0
  v.AIBOARD = assemble(T.aiBoard, v)
  v.TARGETED = 1
  local boardUnit = core.exposeCode(assemble(T.aiBoard, v), 2, 0)
  local taken = core.exposeCode(v.TAKEN, 1, 0)
  v.SELINF = assemble(T.selectedInfantry, v)
  v.CREWPOLICY = env.luaFunction("the AI tower crew policy", function()
    wr32(rd + 0x68, 0)
    if env.crewPolicy(rd32(current)) then wr32(rd + 0x68, 1) end
  end)
  local update = assemble(T.update, v)
  v.GOMAN, v.GOLEAVE, v.BACK = hover + HOVER_REACH[1], hover + HOVER_LEAVE[1], hover + HOVER_SIZE
  local hoverCode = assemble(T.hover, v)
  v.BACK = man + INSTR.MAN_SIZE
  local manCode = assemble(T.man, v)
  v.BACK = leave + INSTR.LEAVE_SIZE
  local leaveCode = assemble(T.leave, v)
  v.SKIP = typeSelect + TYPE_SELECT_SIZE + string.unpack("b", string.char(byte(typeSelect + 9)))
  v.BACK = typeSelect + TYPE_SELECT_SIZE
  local typeCode = assemble(T.typeSelect, v)
  v.REMOVE = groupSelect + GROUP_SELECT_SIZE + string.unpack("b", string.char(byte(groupSelect + 8)))
  v.NEXT, v.BACK = groupSelect + GROUP_NEXT[1], groupSelect + GROUP_SELECT_SIZE
  local groupCode = assemble(T.groupSelect, v)
  v.BACK = standing + STANDING_SIZE
  v.ORIGINAL = assemble(T.standingOrig, v)
  local standingCode = assemble(T.standing, v)
  v.BACK = flat + FLAT_HEIGHT_SIZE
  local flatCode = assemble(T.flatHeight, v)
  v.BACK = vanish + DRAW_VANISH_SIZE
  local vanishCode = assemble(T.drawVanish, v)
  v.SKIP = (stuck + STUCK_SIZE + rd32(stuck + 11)) & 0xFFFFFFFF
  v.BACK, v.AREA = stuck + STUCK_SIZE, G.area
  local stuckCode = assemble(T.stuck, v)

  -- saved games: who rides where
  modules["map-extensions"]:registerSection(SAVE_SECTION, {
    initialize = function(self)
      core.setMemory(ride, 0, G.maxUnits * RECORD)
      core.setMemory(tslot, 0, G.maxUnits * 9 * 2)
    end,
    serialize = function(self, handle)
      local parts = {}
      for unit = 1, G.maxUnits - 1 do
        local at = ride + unit * RECORD
        if byte(at + 6) ~= 0 then
          parts[#parts + 1] = string.pack("<I2", unit) .. string.char(table.unpack(core.readBytes(at, RECORD)))
        end
      end
      handle:put(SAVE_KEY, table.concat(parts))
    end,
    deserialize = function(self, handle)
      core.setMemory(ride, 0, G.maxUnits * RECORD)
      core.setMemory(tslot, 0, G.maxUnits * 9 * 2)
      if not handle:exists(SAVE_KEY) then return end
      local data = handle:get(SAVE_KEY)
      for offset = 1, #data - RECORD - 1, RECORD + 2 do
        local unit, _, tower, mode, place = string.unpack("<I2I4I2BB", data, offset)
        if unit > 0 and unit < G.maxUnits and tower > 0 and tower < G.maxUnits
            and unit ~= tower and (mode == 1 or mode == 2) and place < 9 then
          local at = ride + unit * RECORD
          local seat = tslot + 2 * (tower * 9 + place)
          if byte(at + 6) == 0 and (mode == 1 or core.readSmallInteger(seat) == 0) then
            core.writeBytes(at, { data:byte(offset + 2, offset + 1 + RECORD) })
            if mode == 2 then core.writeSmallInteger(seat, unit) end
          end
        end
      end
    end,
  })

  -- the update table: every foot soldier that can ride, and the tower for the AI's boarding
  local kinds = { TOWER }
  for _, kind in ipairs(BOARDABLE) do kinds[#kinds + 1] = kind end
  for _, kind in ipairs(kinds) do
    env.patch(tableAt + kind * 4, core.itob(update), 4)
  end
  env.patch(standing, env.jumpCode(standing, standingCode, STANDING_SIZE), STANDING_SIZE)
  env.patch(flat, env.jumpCode(flat, flatCode, FLAT_HEIGHT_SIZE), FLAT_HEIGHT_SIZE)
  env.patch(vanish, env.jumpCode(vanish, vanishCode, DRAW_VANISH_SIZE), DRAW_VANISH_SIZE)
  env.patch(stuck, env.jumpCode(stuck, stuckCode, STUCK_SIZE), STUCK_SIZE)
  env.patch(typeSelect, env.jumpCode(typeSelect, typeCode, TYPE_SELECT_SIZE), TYPE_SELECT_SIZE)
  env.patch(groupSelect, env.jumpCode(groupSelect, groupCode, GROUP_SELECT_SIZE), GROUP_SELECT_SIZE)
  if env.player then
    env.patch(hover, env.jumpCode(hover, hoverCode, HOVER_SIZE), HOVER_SIZE)
    env.patch(man, env.jumpCode(man, manCode, INSTR.MAN_SIZE), INSTR.MAN_SIZE)
    env.patch(leave, env.jumpCode(leave, leaveCode, INSTR.LEAVE_SIZE), INSTR.LEAVE_SIZE)
  end
  local function validIndex(index)
    return math.type(index) == "integer" and index > 0 and index < G.maxUnits
  end
  local function validTower(tower)
    return validIndex(tower) and core.readSmallInteger(G.units + tower * 0x490 + 0x8E) == 58
  end
  riders.data = rd
  riders.enableCrewPolicy = function() wr32(rd + 0x64, 1) end
  if env.hasCrewPolicy then riders.enableCrewPolicy() end
  riders.isClimbingReady = function()
    return rd32(rd + 4) ~= 0 or rd32(rd + 8) ~= 0
  end
  riders.getFreeSeats = function(tower)
    if not riders.isClimbingReady() or not validTower(tower) then return 0 end
    local mask, seats = taken(tower), #PLACES
    while mask ~= 0 do
      mask = mask & (mask - 1)
      seats = seats - 1
    end
    return seats
  end
  riders.boardUnit = function(tower, unit)
    return riders.isClimbingReady() and validTower(tower) and validIndex(unit)
      and boardUnit(tower, unit) == 1
  end
  return true
end

function riders.disable()
  if riders.data ~= nil then
    core.writeInteger(riders.data + 0x04, 0)
    core.writeInteger(riders.data + 0x08, 0)
  end
end

return riders
