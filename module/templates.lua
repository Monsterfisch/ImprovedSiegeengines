--[[
  Improved Siegeengines - the injected code.

  Every script is FASM. Upper-case names are constants init.lua passes in (only the ones a
  script uses are passed - FASM gets a fixed 64 KB). D is the module's data block:

    config (written by init.lua)
      0x00 catapults on    0x04 tent spots freed    0x08 tents by range
      0x0C variation in tiles    0x10 tower docking on
    catapult search
      0x20 x  0x24 y  0x28 owner  0x2C target player  0x30 reach  0x34 reach^2
      0x38 best score  0x3C best tile  0x40 best x  0x44 best y  0x48 own team  0x4C row
      0x50 distance^2  0x54 civilian penalty
    tents
      0x60 band on  0x64 band low  0x68 band high  0x6C tribe owner  0x74 distance map player
      0x78 distance map tick  0x7C threat list tick  0x80 threat list owner  0x84 threats
      0x88 saved ecx  0x8C/0x90 narrow band  0x94/0x98 wide band  0x9C castle found
    docking
      0xA0 unit  0xA4 best dock  0xA8 best distance  0xAC/0xB0 wall x/y  0xB4/0xB8 unit x/y
      0xBC owner  0xC0 unit's area  0xC8 centre tile  0xCC/0xD0 centre x/y
      0xD4/0xD8 wall x/y (along)  0xDC wall owner  0xE0 neighbour
    tower search
      0x100 unit  0x104/0x108 x/y  0x10C target player  0x110 radius  0x114 tests
      0x118 owner  0x11C team  0x120 wall  0xFC dock found
    lua
      0x130 player
    diagnostics
      0x1F0 log the catapults' targets    0x1F4 the engine that just chose one (UnitsState relative)
      0x1F8 other enemies than the besieged player may be shot (ranked after his)
]]

local templates = {}

---------------------------------------------------------------------------------------
-- Map helpers (eax = x, edx = y). They only touch eax and edx.
---------------------------------------------------------------------------------------

-- tileAt: eax = the tile at (x, y), or -1 off the map. Keeps ecx.
-- wallAt: eax = the tile if it carries a wall (not a stockpile), else -1.
-- clearAt: eax = 1 when a siege tower may stand there (no wall, nothing blocking, no building
--          but a siege tent).
templates.tileAt = [[
  cmp eax, 400
  jae .bad
  cmp edx, 400
  jae .bad
  push ecx
  mov ecx, edx
  imul ecx, ecx, 400
  add ecx, eax
  cmp byte [VALID + ecx], 0
  pop ecx
  je .bad
  lea edx, [edx + edx*2]
  add eax, [ROWS + edx*4]
  ret
.bad:
  or eax, -1
  ret
]]

templates.wallAt = [[
  call TILEAT
  test eax, eax
  jl .no
  mov edx, [FLAGS + eax*4]
  test edx, 0x100
  jz .no
  test edx, 2
  jnz .no
  ret
.no:
  or eax, -1
  ret
]]

templates.clearAt = [[
  call TILEAT
  test eax, eax
  jl .no
  mov edx, [FLAGS + eax*4]
  test edx, 0x100
  jnz .no
  test edx, 0x4A5014B1
  jnz .no
  movsx edx, word [BIDS + eax*2]
  test edx, edx
  jz .yes
  imul edx, edx, 0x32C
  cmp word [BTYPE + edx], 0x43
  jne .no
.yes:
  mov eax, 1
  ret
.no:
  xor eax, eax
  ret
]]

---------------------------------------------------------------------------------------
-- 1. Catapults and trebuchets
---------------------------------------------------------------------------------------

-- harassBuildingsWithSiegeAI, where the game is about to start its own direction-by-direction
-- search: esi = the unit (UnitsState relative), ebp = its owner, ecx = the projectile kind
-- (2 catapult, 3 trebuchet). A target found here is shot the game's own way (SHOOT), with the
-- engine turned to face it first, as the game's own search does when it finds one.
templates.catapultHook = [[
  cmp dword [D + 0x00], 0
  je .vanilla
  cmp ecx, 2
  je .go
  cmp ecx, 3
  jne .vanilla
.go:
  pushad
  mov [D + 0x28], ebp
  mov eax, [RANGE + ecx*4]
  sub eax, 2
  jle .none
  mov [D + 0x30], eax
  movsx eax, word [esi + 0x6D8]
  mov [D + 0x20], eax
  movsx eax, word [esi + 0x6DA]
  mov [D + 0x24], eax
  movsx eax, word [esi + 0xA46]
  call LIVE
  mov [D + 0x2C], eax
  call SEARCH
  test eax, eax
  jz .none
  cmp dword [D + 0x1F0], 0
  je .noLog
  mov [D + 0x1F4], esi
  call PICKLOG
.noLog:
  mov eax, [D + 0x40]
  mov [ALG_X], eax
  mov eax, [D + 0x44]
  mov [ALG_Y], eax
  mov eax, [D + 0x3C]
  mov [ALG_TILE], eax
  push dword [D + 0x44]
  push dword [D + 0x40]
  push dword [D + 0x24]
  push dword [D + 0x20]
  mov ecx, DIRSTATE
  call ORIENT
  movzx eax, word [ALG_ORIENT]
  and eax, 7
  mov [esi + 0x8C8], ax
  sub eax, [MAPORIENT]
  and eax, 7
  mov [esi + 0x668], ax
  mov byte [esi + 0xA23], 0
  mov word [esi + 0x958], 0
  popad
  jmp SHOOT
.none:
  popad
.vanilla:
  mov ebx, 0x15
  jmp RESUME
]]

-- harassBuildingsWithSiegeAI, an engine with a building target (targetingType 9: a fire
-- ballista's burnable building, or an attack-building order): the game only checks that the
-- building's uid still matches, and a destroyed building keeps its uid until the slot is reused,
-- so the engine shoots the empty spot for ever and never moves. Also require the building to be
-- standing (logicalState 2); else the game's own "target lost" (targetingType 3, search again).
-- ecx = building * 0x32C, esi = the unit (UnitsState relative), edx = the building's uid.
templates.standingTarget = [[
  cmp edx, [esi + 0x9B4]
  jne .lost
  cmp word [ecx + BSTATE], 2
  jne .lost
  jmp BACK
.lost:
  jmp LOST
]]

-- setRandomShootLocation, where the random miss is ready (ecx along the engine's facing, esi
-- across it, edi the height) and about to be clamped: for AI catapults and trebuchets it is
-- scaled to SCATTER percent, and a catapult's miss - the game's runs 12 tiles short to 4 long -
-- is first centred on the target. [esp + 0x10] is the unit (UnitsState relative).
templates.scatterHook = [[
  push eax
  push edx
  mov eax, [esp + 0x18]
  movsx edx, word [eax + 0x6AA]
  cmp edx, 1
  jl .done
  cmp edx, 8
  jg .done
  imul edx, edx, PSTRIDE
  cmp dword [PLAYERS + edx + AITYPE], 0
  je .done
  movzx eax, word [eax + 0x6A2]
  cmp eax, 0x27
  je .catapult
  cmp eax, 0x28
  jne .done
  jmp .scale
.catapult:
  add ecx, 0x20
.scale:
  mov eax, ecx
  imul eax, eax, SCATTER
  cdq
  idiv dword [HUNDRED]
  mov ecx, eax
  mov eax, esi
  imul eax, eax, SCATTER
  cdq
  idiv dword [HUNDRED]
  mov esi, eax
.done:
  pop edx
  pop eax
  cmp edi, 8
  jge .high
  jmp LOW
.high:
  jmp HIGH
]]

-- The nearest enemy wall, tower or gatehouse within reach of (x, y) (keep doors never, they
-- cannot be destroyed); a civilian
-- building only when none of those is in reach (CIVILIAN is added to its distance). eax = 1 found.
-- eax = the engine's siege target player -> eax = that player while his lord lives, else 0, which
-- makes the target search take any enemy: the next opponent once the first is beaten. Keeps
-- every other register.
templates.livePlayer = [[
  cmp eax, 1
  jl .none
  cmp eax, 8
  jg .none
  push edx
  push ecx
  mov edx, eax
  imul edx, edx, PSTRIDE
  mov ecx, [PLORD + edx]
  test ecx, ecx
  jle .dead
  imul ecx, ecx, 0x490
  cmp word [U_STATE + ecx], 2
  jne .dead
  cmp word [U_TYPE + ecx], LORDTYPE
  jne .dead
  mov ecx, [U_UID + ecx]
  cmp ecx, [PLORDUID + edx]
  jne .dead
  pop ecx
  pop edx
  ret
.dead:
  pop ecx
  pop edx
.none:
  xor eax, eax
  ret
]]

-- In the unit update table for catapults and trebuchets (cdecl, no arguments; the unit is the
-- current unit). Every 16 ticks an AI engine that walks (state 1 or 0x65) or creeps forward in
-- the AI's siege steps (9) runs the module's target search; with a target in range it stops
-- walking and goes idle (state 0, no wait), so that this same tick the game's idle code calls
-- harassBuildingsWithSiegeAI, whose hooked start finds the target again and shoots it. Then
-- whatever update function the table held runs.
templates.walkCheck = [[
  cmp dword [D + 0x00], 0
  je .go
  mov eax, [CURRENT]
  mov edx, [TICKS]
  add edx, eax
  test edx, EVERY
  jnz .go
  imul ecx, eax, 0x490
  movzx edx, word [U_ORDER + ecx]
  cmp edx, 1
  je .walking
  cmp edx, 0x65
  je .walking
  cmp edx, 9
  jne .go
.walking:
  movsx edx, word [U_OWNER + ecx]
  cmp edx, 1
  jl .go
  cmp edx, 8
  jg .go
  imul edx, edx, PSTRIDE
  cmp dword [AITYPE + edx], 0
  je .go
  movsx edx, word [U_TYPE + ecx]
  cmp edx, FIRST
  jl .go
  cmp edx, LAST
  jg .go
  pushad
  sub edx, FIRST - 2
  mov eax, [RANGE + edx*4]
  sub eax, 2
  jle .none
  mov [D + 0x30], eax
  movsx eax, word [U_OWNER + ecx]
  mov [D + 0x28], eax
  movsx eax, word [U_X + ecx]
  mov [D + 0x20], eax
  movsx eax, word [U_Y + ecx]
  mov [D + 0x24], eax
  movsx eax, word [U_TARGETP + ecx]
  call LIVE
  mov [D + 0x2C], eax
  call SEARCH
  test eax, eax
  jz .none
  push dword [CURRENT]
  mov ecx, US
  call STOP
  mov eax, [CURRENT]
  imul eax, eax, 0x490
  mov word [U_ORDER + eax], 0
  mov dword [U_COOLDOWN + eax], 0
.none:
  popad
.go:
  mov eax, [CURRENT]
  imul eax, eax, 0x490
  movsx eax, word [U_TYPE + eax]
  jmp dword [ORIGINALS + eax*4]
]]

templates.catapultSearch = [[
  push ebx
  push esi
  push edi
  push ebp
  mov eax, [D + 0x28]
  mov eax, [TEAMS + eax*4]
  mov [D + 0x48], eax
  mov eax, [D + 0x30]
  imul eax, eax
  mov [D + 0x34], eax
  mov dword [D + 0x38], 0x7FFFFFFF
  mov dword [D + 0x3C], 0
  mov ebp, [D + 0x30]
  neg ebp
.row:
  cmp ebp, [D + 0x30]
  jg .done
  mov eax, [D + 0x24]
  add eax, ebp
  cmp eax, 400
  jae .nextRow
  mov [D + 0x4C], eax
  mov edi, [D + 0x30]
  neg edi
.col:
  cmp edi, [D + 0x30]
  jg .nextRow
  mov eax, edi
  imul eax, eax
  mov edx, ebp
  imul edx, edx
  add eax, edx
  cmp eax, [D + 0x34]
  jg .nextCol
  cmp eax, [D + 0x38]
  jge .nextCol
  mov [D + 0x50], eax
  mov ebx, [D + 0x20]
  add ebx, edi
  cmp ebx, 400
  jae .nextCol
  mov ecx, [D + 0x4C]
  imul ecx, ecx, 400
  add ecx, ebx
  cmp byte [VALID + ecx], 0
  je .nextCol
  mov ecx, [D + 0x4C]
  lea ecx, [ecx + ecx*2]
  mov ecx, [ROWS + ecx*4]
  add ecx, ebx
  mov edx, [FLAGS + ecx*4]
  test edx, 0x100
  jz .building
  test edx, 2
  jnz .nextCol
  mov dword [D + 0x54], 0
  movzx eax, byte [WOWNER + ecx]
  and eax, 7
  inc eax
  jmp .owner
.building:
  test edx, 0x10000400
  jz .nextCol
  movsx eax, word [BIDS + ecx*2]
  test eax, eax
  jle .nextCol
  imul eax, eax, 0x32C
  cmp word [BSTATE + eax], 2
  jne .nextCol
  movsx edx, word [BTYPE + eax]
  cmp edx, 0
  jl .nextCol
  cmp dword [HEALTH + edx*4], 0
  je .nextCol
  cmp edx, 71
  jb .notKeepDoor
  cmp edx, 73
  jbe .nextCol
.notKeepDoor:
  mov dword [D + 0x54], CIVILIAN
  cmp edx, 511
  ja .civilian
  cmp byte [FORT + edx], 0
  je .civilian
  mov dword [D + 0x54], 0
.civilian:
  movsx eax, word [BOWNER + eax]
.owner:
  cmp eax, 1
  jl .nextCol
  cmp eax, 8
  jg .nextCol
  mov edx, [D + 0x2C]
  test edx, edx
  jz .team
  cmp eax, edx
  je .take
  cmp dword [D + 0x1F8], 0
  je .nextCol
  add dword [D + 0x54], OTHER
.team:
  cmp eax, [D + 0x28]
  je .nextCol
  mov edx, [TEAMS + eax*4]
  cmp edx, [D + 0x48]
  je .nextCol
.take:
  mov eax, [D + 0x50]
  add eax, [D + 0x54]
  cmp eax, [D + 0x38]
  jge .nextCol
  mov [D + 0x38], eax
  mov [D + 0x3C], ecx
  mov [D + 0x40], ebx
  mov eax, [D + 0x4C]
  mov [D + 0x44], eax
.nextCol:
  inc edi
  jmp .col
.nextRow:
  inc ebp
  jmp .row
.done:
  xor eax, eax
  cmp dword [D + 0x3C], 0
  setne al
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

---------------------------------------------------------------------------------------
-- 2. Siege tents
---------------------------------------------------------------------------------------

-- Enemy troops that could hit a siege engine, for the tribe owner in [D+0x80]: x, y and the
-- squared reach, 12 bytes each. TK[type] is 0 (not a threat), 0xFF00 (melee) or a projectile
-- whose reach the game's range table gives.
templates.threats = [[
  push ebx
  push esi
  push edi
  push ebp
  mov eax, [D + 0x80]
  mov ebp, [TEAMS + eax*4]
  xor edi, edi
  mov esi, UNITS + 0x490
  mov ebx, 1
.unit:
  cmp ebx, MAXUNITS
  jge .done
  cmp word [esi + 0x8C], 2
  jne .next
  cmp word [esi + 0x2A0], 0
  jne .next
  movsx eax, word [esi + 0x96]
  cmp eax, 1
  jl .next
  cmp eax, 8
  jg .next
  cmp eax, [D + 0x80]
  je .next
  cmp [TEAMS + eax*4], ebp
  je .next
  movsx eax, word [esi + 0x8E]
  cmp eax, 79
  ja .next
  mov eax, [TK + eax*4]
  test eax, eax
  jz .next
  cmp eax, 0xFF00
  jne .ranged
  mov eax, MELEE
  jmp .reach
.ranged:
  mov eax, [RANGE + eax*4]
.reach:
  imul eax, eax
  cmp edi, MAXTHREATS
  jge .done
  lea ecx, [edi + edi*2]
  mov [THREATS + ecx*4 + 8], eax
  movsx eax, word [esi + 0xC4]
  mov [THREATS + ecx*4], eax
  movsx eax, word [esi + 0xC6]
  mov [THREATS + ecx*4 + 4], eax
  inc edi
.next:
  add esi, 0x490
  inc ebx
  jmp .unit
.done:
  mov [D + 0x84], edi
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- How far every tile is from the castle of the player in [D+0x74] (its walls and fortified
-- buildings), in fifths of a tile: a two-pass chamfer over the 400x400 grid, y * 400 + x.
templates.distanceMap = [[
  push ebx
  push esi
  push edi
  push ebp
  mov dword [D + 0x9C], 0
  xor ebp, ebp
.iy:
  cmp ebp, 400
  jge .forward
  lea eax, [ebp + ebp*2]
  mov esi, [ROWS + eax*4]
  mov edi, ebp
  imul edi, edi, 400
  xor ebx, ebx
.ix:
  cmp ebx, 400
  jge .iny
  lea ecx, [edi + ebx]
  mov word [DIST + ecx*2], 30000
  cmp byte [VALID + ecx], 0
  je .inx
  lea edx, [esi + ebx]
  mov eax, [FLAGS + edx*4]
  test eax, 0x100
  jz .ib
  test eax, 2
  jnz .inx
  movzx eax, byte [WOWNER + edx]
  and eax, 7
  inc eax
  cmp eax, [D + 0x74]
  jne .inx
  jmp .zero
.ib:
  test eax, 0x10000400
  jz .inx
  movsx eax, word [BIDS + edx*2]
  test eax, eax
  jle .inx
  imul eax, eax, 0x32C
  movsx edx, word [BTYPE + eax]
  cmp edx, 511
  ja .inx
  cmp byte [FORT + edx], 0
  je .inx
  movsx eax, word [BOWNER + eax]
  cmp eax, [D + 0x74]
  jne .inx
.zero:
  mov word [DIST + ecx*2], 0
  mov dword [D + 0x9C], 1
.inx:
  inc ebx
  jmp .ix
.iny:
  inc ebp
  jmp .iy
.forward:
  cmp dword [D + 0x9C], 0
  je .out
  xor ecx, ecx
  xor ebp, ebp
.fy:
  cmp ebp, 400
  jge .backward
  xor ebx, ebx
.fx:
  cmp ebx, 400
  jge .fny
  movzx eax, word [DIST + ecx*2]
  test ebx, ebx
  jz .f1
  movzx edx, word [DIST + ecx*2 - 2]
  add edx, 5
  cmp edx, eax
  jge .f1
  mov eax, edx
.f1:
  test ebp, ebp
  jz .fs
  movzx edx, word [DIST + ecx*2 - 800]
  add edx, 5
  cmp edx, eax
  jge .f2
  mov eax, edx
.f2:
  test ebx, ebx
  jz .f3
  movzx edx, word [DIST + ecx*2 - 802]
  add edx, 7
  cmp edx, eax
  jge .f3
  mov eax, edx
.f3:
  cmp ebx, 399
  jge .fs
  movzx edx, word [DIST + ecx*2 - 798]
  add edx, 7
  cmp edx, eax
  jge .fs
  mov eax, edx
.fs:
  mov [DIST + ecx*2], ax
  inc ecx
  inc ebx
  jmp .fx
.fny:
  inc ebp
  jmp .fy
.backward:
  mov ecx, 159999
  mov ebp, 399
.by:
  cmp ebp, 0
  jl .out
  mov ebx, 399
.bx:
  cmp ebx, 0
  jl .bny
  movzx eax, word [DIST + ecx*2]
  cmp ebx, 399
  jge .b1
  movzx edx, word [DIST + ecx*2 + 2]
  add edx, 5
  cmp edx, eax
  jge .b1
  mov eax, edx
.b1:
  cmp ebp, 399
  jge .bs
  movzx edx, word [DIST + ecx*2 + 800]
  add edx, 5
  cmp edx, eax
  jge .b2
  mov eax, edx
.b2:
  cmp ebx, 399
  jge .b3
  movzx edx, word [DIST + ecx*2 + 802]
  add edx, 7
  cmp edx, eax
  jge .b3
  mov eax, edx
.b3:
  test ebx, ebx
  jz .bs
  movzx edx, word [DIST + ecx*2 + 798]
  add edx, 7
  cmp edx, eax
  jge .bs
  mov eax, edx
.bs:
  mov [DIST + ecx*2], ax
  dec ecx
  dec ebx
  jmp .bx
.bny:
  dec ebp
  jmp .by
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- prepareTent(tribe, buildingType), stdcall: builds the threat list when spots are freed, and,
-- for a ranged engine's tent, the band of distances from the castle its tent should stand at.
templates.prepareTent = [[
  push ebx
  push esi
  push edi
  push ebp
  mov dword [D + 0x60], 0
  mov eax, [esp + 0x14]
  test eax, eax
  jle .out
  cmp eax, MAXTRIBES
  jae .out
  imul eax, eax, TSTRIDE
  mov esi, [TRIBES + eax + 0x2C]
  cmp esi, 1
  jl .out
  cmp esi, 8
  jg .out
  mov [D + 0x6C], esi
  cmp dword [D + 0x04], 0
  je .range
  mov eax, [TICKS]
  cmp eax, [D + 0x7C]
  jne .build
  cmp esi, [D + 0x80]
  je .range
.build:
  mov [D + 0x7C], eax
  mov [D + 0x80], esi
  call THREATLIST
.range:
  cmp dword [D + 0x08], 0
  je .out
  mov eax, [esp + 0x18]
  xor ecx, ecx
.find:
  cmp eax, [ENG_BT + ecx*4]
  je .engine
  inc ecx
  cmp ecx, 6
  jl .find
  jmp .out
.engine:
  mov eax, [ENG_UT + ecx*4]
  mov edx, 2
  cmp eax, 39
  je .proj
  mov edx, 3
  cmp eax, 40
  je .proj
  mov edx, 4
  cmp eax, 41
  je .proj
  mov edx, 0x25
  cmp eax, 77
  je .proj
  jmp .out
.proj:
  mov ebx, [RANGE + edx*4]
  sub ebx, MARGIN
  cmp ebx, 3
  jl .out
  mov eax, esi
  imul eax, eax, 0x39F4
  mov eax, [PLAYERS + eax + 0x2BD8]
  cmp eax, 1
  jl .out
  cmp eax, 8
  jg .out
  mov ecx, [TICKS]
  cmp ecx, [D + 0x78]
  jne .map
  cmp eax, [D + 0x74]
  je .have
.map:
  mov [D + 0x78], ecx
  mov [D + 0x74], eax
  call DISTMAP
.have:
  cmp dword [D + 0x9C], 0
  je .out
  mov eax, ebx
  sub eax, [D + 0x0C]
  cmp eax, 1
  jge .wide
  mov eax, 1
.wide:
  imul eax, eax, 5
  mov [D + 0x94], eax
  mov eax, ebx
  imul eax, eax, 5
  mov [D + 0x98], eax
  mov eax, [TICKS]
  mov ecx, [esp + 0x14]
  imul ecx, ecx, 7
  add eax, ecx
  and eax, 0x7FFFFFFF
  xor edx, edx
  mov ecx, [D + 0x0C]
  inc ecx
  div ecx
  mov eax, ebx
  sub eax, edx
  cmp eax, 1
  jge .narrow
  mov eax, 1
.narrow:
  lea ecx, [eax - 1]
  imul ecx, ecx, 5
  mov [D + 0x8C], ecx
  mov [D + 0x64], ecx
  lea ecx, [eax + 1]
  cmp ecx, ebx
  jle .top
  mov ecx, ebx
.top:
  imul ecx, ecx, 5
  mov [D + 0x90], ecx
  mov [D + 0x68], ecx
  mov dword [D + 0x60], 1
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret 8
]]

-- placeSiegeTentAtAttackAngle(tribe, type) and placeSiegeTentOrTunnelAtSuitableLocation(tribe,
-- type, kind, x), thiscall: try the narrow band, then the wide one, then the game's own way.
-- ARGS is the argument count, ORIG the game's function with its first five bytes replayed.
templates.tentWrapper = [[
  mov [D + 0x88], ecx
  push dword [esp + 8]
  push dword [esp + 8]
  call PREPARE
  mov ecx, [D + 0x88]
  repeat ARGS
  push dword [esp + ARGS*4]
  end repeat
  call ORIG
  test eax, eax
  jnz .done
  cmp dword [D + 0x60], 0
  je .done
  mov eax, [D + 0x94]
  mov [D + 0x64], eax
  mov eax, [D + 0x98]
  mov [D + 0x68], eax
  mov ecx, [D + 0x88]
  repeat ARGS
  push dword [esp + ARGS*4]
  end repeat
  call ORIG
  test eax, eax
  jnz .done
  mov dword [D + 0x60], 0
  mov ecx, [D + 0x88]
  repeat ARGS
  push dword [esp + ARGS*4]
  end repeat
  call ORIG
.done:
  mov dword [D + 0x60], 0
  ret ARGS*4
]]

-- The first five bytes of both tent functions (push ebx; mov ebx, [esp+8]), replayed.
templates.tentOrig = [[
  push ebx
  mov ebx, [esp + 8]
  jmp RESUME
]]

-- algFindAttackAngle, a tent spot the search reached: eax = its index. Takes the place of the
-- game's "never used" test (three == 0 and tribeID == 0).
templates.tentSpot = [[
  cmp dword [D + 0x04], 0
  jne .mine
  cmp dword [D + 0x60], 0
  jne .mine
  mov ecx, eax
  shl ecx, 5
  cmp dword [ecx + THREE], 0
  jne CONTINUE
  cmp dword [ecx + TID], 0
  je FOUND
  jmp CONTINUE
.mine:
  push eax
  push ebx
  push edx
  push esi
  mov esi, eax
  shl esi, 5
  mov ebx, [esi + TID]
  cmp dword [esi + THREE], 0
  jne .used
  test ebx, ebx
  jz .band
.used:
  cmp dword [D + 0x04], 0
  je .reject
  test ebx, ebx
  jz .vacant
  cmp ebx, MAXTRIBES
  jae .vacant
  imul ebx, ebx, TSTRIDE
  cmp word [TRIBES + ebx + 0x40], 2
  jne .vacant
  mov edx, [TRIBES + ebx + 0x34]
  cmp edx, [esi + TID + 4]
  je .reject
.vacant:
  mov eax, [esi + TID - 0x10]
  mov edx, [esi + TID - 0x0C]
  call FOOTPRINT
  test eax, eax
  jz .reject
  mov eax, [esi + TID - 0x10]
  mov edx, [esi + TID - 0x0C]
  call SAFE
  test eax, eax
  jz .reject
.band:
  cmp dword [D + 0x60], 0
  je .accept
  mov eax, [esi + TID - 0x10]
  mov edx, [esi + TID - 0x0C]
  cmp eax, 400
  jae .reject
  cmp edx, 400
  jae .reject
  imul edx, edx, 400
  add edx, eax
  movzx eax, word [DIST + edx*2]
  cmp eax, [D + 0x64]
  jl .reject
  cmp eax, [D + 0x68]
  jg .reject
.accept:
  pop esi
  pop edx
  pop ebx
  pop eax
  jmp FOUND
.reject:
  pop esi
  pop edx
  pop ebx
  pop eax
  jmp CONTINUE
]]

-- footprint (eax = x, edx = y): 1 when the tent's 3x3 around it is free to build on.
-- safe (eax = x, edx = y): 1 when no enemy in the threat list can reach it.
templates.footprint = [[
  push ebx
  push ecx
  push esi
  push edi
  mov esi, eax
  mov edi, edx
  mov ebx, -1
.oy:
  cmp ebx, 1
  jg .yes
  mov ecx, -1
.ox:
  cmp ecx, 1
  jg .noy
  lea eax, [esi + ecx]
  lea edx, [edi + ebx]
  call TILEAT
  test eax, eax
  jl .no
  mov edx, [FLAGS + eax*4]
  test edx, 0x4A7014B1
  jnz .no
  test edx, 4
  jnz .no
  cmp word [UNITMAP + eax*2], 0
  jne .no
  cmp word [BIDS + eax*2], 0
  jne .no
  inc ecx
  jmp .ox
.noy:
  inc ebx
  jmp .oy
.yes:
  mov eax, 1
  jmp .out
.no:
  xor eax, eax
.out:
  pop edi
  pop esi
  pop ecx
  pop ebx
  ret
]]

templates.safe = [[
  push ebx
  push ecx
  push esi
  push edi
  mov ecx, [D + 0x84]
  mov esi, THREATS
.l:
  test ecx, ecx
  jz .safe
  mov ebx, [esi]
  sub ebx, eax
  imul ebx, ebx
  mov edi, [esi + 4]
  sub edi, edx
  imul edi, edi
  add ebx, edi
  cmp ebx, [esi + 8]
  jle .unsafe
  add esi, 12
  dec ecx
  jmp .l
.safe:
  mov eax, 1
  jmp .o
.unsafe:
  xor eax, eax
.o:
  pop edi
  pop esi
  pop ecx
  pop ebx
  ret
]]

-- findAppropriateLocationForSiegeTent, a free 3x3 the search reached: esi = its tile. In a
-- band the tile has to lie in it; otherwise the game's own test (the AI's distance layer equal
-- to `kind`). eax = 1 takes the tile.
templates.tentLocation = [[
  cmp dword [D + 0x60], 0
  jne .band
  mov eax, 1
  cmp dword [esp + 0x30], 0
  je .out
  mov ebx, [esp + 0x34]
  imul ebx, ebx, 0x177BC
  mov ebx, [ebx + ATTACKED_PID]
  imul ebx, ebx, 0x13A10
  movzx ebx, byte [ebx + esi + LAYER]
  cmp ebx, [esp + 0x30]
  je .out
  xor eax, eax
  jmp .out
.band:
  push ecx
  push edx
  movzx edx, word [TILEY + esi*2]
  lea ecx, [edx + edx*2]
  mov ecx, [ROWS + ecx*4]
  neg ecx
  add ecx, esi
  imul edx, edx, 400
  add edx, ecx
  movzx ecx, word [DIST + edx*2]
  xor eax, eax
  cmp ecx, [D + 0x64]
  jl .pop
  cmp ecx, [D + 0x68]
  jg .pop
  mov eax, 1
.pop:
  pop edx
  pop ecx
.out:
  mov ebx, 1
  jmp RESUME
]]

---------------------------------------------------------------------------------------
-- 3. Siege towers
---------------------------------------------------------------------------------------

-- diagonalDock(wallTile), stdcall, unit in [D+0xA0]: a 3x3 siege tower docks with its corner
-- against a diagonal wall. For the wall tile (wx, wy) and a diagonal d the wall has to run
-- across d, the tower stands at (wx+2dx, wy+2dy), its 3x3 must be clear and the unit must be
-- able to get there. The nearest such spot to the unit wins. eax = its tile or 0.
templates.diagonalDock = [[
  push ebx
  push esi
  push edi
  push ebp
  mov dword [D + 0xA4], 0
  mov dword [D + 0xA8], 0x7FFFFFFF
  mov edi, [esp + 0x14]
  test edi, edi
  jle .done
  cmp edi, TILES
  jge .done
  movzx ecx, word [TILEY + edi*2]
  cmp ecx, 400
  jae .done
  mov [D + 0xB0], ecx
  lea edx, [ecx + ecx*2]
  mov eax, edi
  sub eax, [ROWS + edx*4]
  cmp eax, 400
  jae .done
  mov [D + 0xAC], eax
  mov esi, [D + 0xA0]
  imul esi, esi, 0x490
  add esi, UNITS
  movsx eax, word [esi + 0x96]
  mov [D + 0xBC], eax
  mov eax, [esi + 0xD4]
  movsx eax, word [AREA + eax*2]
  mov [D + 0xC0], eax
  movsx eax, word [esi + 0xC4]
  mov [D + 0xB4], eax
  movsx eax, word [esi + 0xC6]
  mov [D + 0xB8], eax
  xor ebp, ebp
.dir:
  cmp ebp, 4
  jge .done
  mov ebx, [DIAGS + ebp*8]
  mov esi, [DIAGS + ebp*8 + 4]
  mov eax, [D + 0xAC]
  add eax, ebx
  mov edx, [D + 0xB0]
  sub edx, esi
  call WALLAT
  test eax, eax
  jl .next
  mov eax, [D + 0xAC]
  sub eax, ebx
  mov edx, [D + 0xB0]
  add edx, esi
  call WALLAT
  test eax, eax
  jl .next
  mov eax, [D + 0xAC]
  lea eax, [eax + ebx*2]
  mov [D + 0xCC], eax
  mov edx, [D + 0xB0]
  lea edx, [edx + esi*2]
  mov [D + 0xD0], edx
  mov edi, -1
.oy:
  cmp edi, 1
  jg .clear
  mov ecx, -1
.ox:
  cmp ecx, 1
  jg .noy
  mov eax, [D + 0xCC]
  add eax, ecx
  mov edx, [D + 0xD0]
  add edx, edi
  call CLEARAT
  test eax, eax
  jz .next
  inc ecx
  jmp .ox
.noy:
  inc edi
  jmp .oy
.clear:
  mov eax, [D + 0xCC]
  mov edx, [D + 0xD0]
  call TILEAT
  test eax, eax
  jl .next
  mov [D + 0xC8], eax
  movsx eax, word [AREA + eax*2]
  push 0
  push eax
  push dword [D + 0xC0]
  push dword [D + 0xBC]
  mov ecx, PF
  call NAV
  test eax, eax
  jz .next
  mov eax, [D + 0xCC]
  sub eax, [D + 0xB4]
  imul eax, eax
  mov edx, [D + 0xD0]
  sub edx, [D + 0xB8]
  imul edx, edx
  add eax, edx
  cmp eax, [D + 0xA8]
  jge .next
  mov [D + 0xA8], eax
  mov eax, [D + 0xC8]
  mov [D + 0xA4], eax
.next:
  inc ebp
  jmp .dir
.done:
  mov eax, [D + 0xA4]
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret 4
]]

-- UnitsState::findFreeTileNearby(unit, wallTile), thiscall: where a siege tower stands to dock.
-- The game's own spot first, then the diagonal one, then the same for the wall tiles of the
-- same owner up to three tiles along (nearest ring first, always in the same order, so the
-- answer for a wall tile never changes while nothing on the map does).
templates.freeTile = [[
  push dword [esp + 8]
  push dword [esp + 8]
  call GAME
  test eax, eax
  jnz .ret
  cmp dword [D + 0x10], 0
  je .ret
  push ebx
  push esi
  push edi
  push ebp
  mov esi, [esp + 0x14]
  mov edi, [esp + 0x18]
  mov [D + 0xA0], esi
  push edi
  call DIAGONAL
  test eax, eax
  jnz .out
  test edi, edi
  jle .none
  cmp edi, TILES
  jge .none
  test dword [FLAGS + edi*4], 0x100
  jz .none
  movzx eax, byte [WOWNER + edi]
  and eax, 7
  mov [D + 0xDC], eax
  movzx ecx, word [TILEY + edi*2]
  cmp ecx, 400
  jae .none
  mov [D + 0xD8], ecx
  lea edx, [ecx + ecx*2]
  mov eax, edi
  sub eax, [ROWS + edx*4]
  cmp eax, 400
  jae .none
  mov [D + 0xD4], eax
  mov ebx, 1
.ring:
  cmp ebx, 3
  jg .none
  mov ebp, ebx
  neg ebp
.dy:
  cmp ebp, ebx
  jg .nextRing
  mov edi, ebx
  neg edi
.dx:
  cmp edi, ebx
  jg .nextDy
  mov eax, edi
  cdq
  xor eax, edx
  sub eax, edx
  cmp eax, ebx
  je .onRing
  mov eax, ebp
  cdq
  xor eax, edx
  sub eax, edx
  cmp eax, ebx
  jne .nextDx
.onRing:
  mov eax, [D + 0xD4]
  add eax, edi
  mov edx, [D + 0xD8]
  add edx, ebp
  call WALLAT
  test eax, eax
  jl .nextDx
  movzx edx, byte [WOWNER + eax]
  and edx, 7
  cmp edx, [D + 0xDC]
  jne .nextDx
  mov [D + 0xE0], eax
  push eax
  push esi
  mov ecx, US
  call GAME
  test eax, eax
  jnz .out
  mov [D + 0xA0], esi
  push dword [D + 0xE0]
  call DIAGONAL
  test eax, eax
  jnz .out
.nextDx:
  inc edi
  jmp .dx
.nextDy:
  inc ebp
  jmp .dy
.nextRing:
  inc ebx
  jmp .ring
.none:
  xor eax, eax
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
.ret:
  ret 8
]]

-- The game's findFreeTileNearby, its first nine bytes replayed.
templates.freeTileGame = [[
  sub esp, 0x10
  push ebx
  push ebp
  mov ebp, [esp + 0x1C]
  jmp RESUME
]]

-- towerFind(unit, targetPlayer, radius), cdecl, for lua: the nearest wall tile of the target
-- (any enemy when 0) a siege tower can dock at, ring by ring around the tower (only each ring's
-- edge: top, right, bottom, left), at most MAXTESTS docking tests. eax = the wall tile or 0, [D+0xFC] = where the tower stands.
templates.towerFind = [[
  push ebx
  push esi
  push edi
  push ebp
  mov eax, [esp + 0x14]
  mov [D + 0x100], eax
  mov eax, [esp + 0x18]
  mov [D + 0x10C], eax
  mov eax, [esp + 0x1C]
  mov [D + 0x110], eax
  mov esi, [D + 0x100]
  imul esi, esi, 0x490
  add esi, UNITS
  movsx eax, word [esi + 0xC4]
  mov [D + 0x104], eax
  movsx eax, word [esi + 0xC6]
  mov [D + 0x108], eax
  movsx eax, word [esi + 0x96]
  mov [D + 0x118], eax
  and eax, 15
  mov eax, [TEAMS + eax*4]
  mov [D + 0x11C], eax
  mov dword [D + 0x114], 0
  mov dword [D + 0xFC], 0
  mov ebx, 1
.ring:
  cmp ebx, [D + 0x110]
  jg .none
  mov dword [D + 0x124], 0
.edge:
  mov eax, [D + 0x124]
  lea ecx, [ebx*8]
  cmp eax, ecx
  jge .nextRing
  lea ecx, [ebx + ebx]
  xor edx, edx
  div ecx
  mov edi, edx
  sub edi, ebx
  mov ebp, ebx
  neg ebp
  test eax, eax
  jz .onRing
  mov ecx, edi
  mov edi, ebx
  mov ebp, ecx
  cmp eax, 1
  je .onRing
  neg ecx
  mov edi, ecx
  mov ebp, ebx
  cmp eax, 2
  je .onRing
  mov edi, ebx
  neg edi
  mov ebp, ecx
.onRing:
  mov eax, [D + 0x104]
  add eax, edi
  mov edx, [D + 0x108]
  add edx, ebp
  call WALLAT
  test eax, eax
  jl .nextDx
  mov [D + 0x120], eax
  movzx edx, byte [WOWNER + eax]
  and edx, 7
  inc edx
  mov ecx, [D + 0x10C]
  test ecx, ecx
  jz .team
  cmp edx, ecx
  jne .nextDx
  jmp .try
.team:
  cmp edx, [D + 0x118]
  je .nextDx
  mov edx, [TEAMS + edx*4]
  cmp edx, [D + 0x11C]
  je .nextDx
.try:
  push dword [D + 0x120]
  push dword [D + 0x100]
  mov ecx, US
  call FREETILE
  test eax, eax
  jz .miss
  mov [D + 0xFC], eax
  mov eax, [D + 0x120]
  jmp .out
.miss:
  inc dword [D + 0x114]
  cmp dword [D + 0x114], MAXTESTS
  jge .none
.nextDx:
  inc dword [D + 0x124]
  jmp .edge
.nextRing:
  inc ebx
  jmp .ring
.none:
  xor eax, eax
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

---------------------------------------------------------------------------------------
-- 4. Shields and siege towers in the AI's command round
---------------------------------------------------------------------------------------

-- The player's ([D+0x130]) shields, siege towers, ranged engines and engineers, for lua: LIST =
-- count, then that many unit indices (at most 1023). The unit array is too long for lua to walk.
templates.collect = [[
  push ebx
  push esi
  push edi
  xor edi, edi
  mov esi, UNITS + 0x490
  mov ebx, 1
.unit:
  cmp ebx, MAXUNITS
  jge .done
  cmp word [esi + 0x8C], 0
  je .next
  movsx eax, word [esi + 0x96]
  cmp eax, [D + 0x130]
  jne .next
  movzx eax, word [esi + 0x8E]
  cmp eax, 60
  je .take
  cmp eax, 58
  je .take
  cmp eax, 39
  je .take
  cmp eax, 40
  je .take
  cmp eax, 41
  je .take
  cmp eax, 77
  je .take
  cmp eax, 30
  jne .next
.take:
  cmp edi, 1023
  jge .done
  mov [LIST + 4 + edi*4], ebx
  inc edi
.next:
  add esi, 0x490
  inc ebx
  jmp .unit
.done:
  mov [LIST], edi
  pop edi
  pop esi
  pop ebx
  ret
]]

-- The player's siege tents (building types 54 and 80-84), for lua: TLIST = count, then that many
-- building indices (at most 255).
templates.collectTents = [[
  push ebx
  push esi
  push edi
  xor edi, edi
  mov esi, BUILDINGS + 0x32C
  mov ebx, 1
.building:
  cmp ebx, 2000
  jge .done
  cmp word [esi + 0xD0], 0
  je .next
  movsx eax, word [esi + 0xD6]
  cmp eax, [D + 0x130]
  jne .next
  movzx eax, word [esi + 0xD2]
  cmp eax, 54
  je .take
  cmp eax, 80
  jb .next
  cmp eax, 84
  ja .next
.take:
  cmp edi, 255
  jge .done
  mov [TLIST + 4 + edi*4], ebx
  inc edi
.next:
  add esi, 0x32C
  inc ebx
  jmp .building
.done:
  mov [TLIST], edi
  pop edi
  pop esi
  pop ebx
  ret
]]

-- aiCommandSiegeEngineTribes(player), at its end: lua gives the shields and towers their
-- orders, then the game's epilogue.
templates.commandEnd = [[
  pushad
  mov eax, [esp + 0x48]
  mov [D + 0x130], eax
  call COLLECT
  call COLLECT_TENTS
  call LUA
  popad
  pop edi
  pop esi
  pop ebp
  pop ebx
  add esp, 0x14
  ret 4
]]

---------------------------------------------------------------------------------------
-- 5. Oil engineers
---------------------------------------------------------------------------------------
--[[
  OIL is the oil block:
    0x00 aim on  0x04 spread on  0x08 amount (tiles)  0x0C building damage on
    0x10 generation  0x14 count  0x18 head  0x1C buildings  0x20/0x24 target x/y
    0x28/0x2C engineer x/y  0x30/0x34 target - engineer  0x38 its length^2
    0x40/0x44 ring dx/dy  0x48 ring index  0x4C owner  0x50/0x54 landing x/y  0x58 depth
    0x5C entry being expanded  0x64 queued events  0x68 last tick  0x6C its step  0x70.. the event being queued: due tick,
    kind (0 fire, 1 damage), owner, then mx, my, z, strength or tile, x, y, damage
  PEND: 32 bytes per queued event, the same eight dwords (due 0 = a free slot).
  QUEUE: 16 bytes per tile (tile, x, y, depth). BLIST: 16 bytes per building (id, tile, x, y)
  plus BDEPTH: 4 bytes per building (nearest depth). STAMP: a dword per map tile.
]]

-- pourable: eax = tile -> eax = 1 when burning oil can lie there (no wall, stairs, tower or
-- other obstacle, no building but the few the game's fire ignores). Keeps every other register.
templates.pourable = [[
  push edx
  mov edx, [FLAGS + eax*4]
  test edx, 0x10300131
  jnz .no
  movsx edx, word [BIDS + eax*2]
  test edx, edx
  jz .yes
  imul edx, edx, 0x32C
  movzx edx, word [BTYPE + edx]
  cmp edx, 0x32
  je .yes
  cmp edx, 0x43
  je .yes
  cmp edx, 0x55
  je .yes
.no:
  xor eax, eax
  pop edx
  ret
.yes:
  mov eax, 1
  pop edx
  ret
]]

-- ringStep: [OIL+0x48] = index on ring ebx (0 .. 8r-1) -> [OIL+0x40/0x44] = dx, dy (top, right,
-- bottom, left edge). Keeps ebx, esi, edi, ebp.
templates.ringStep = [[
  push ecx
  push edx
  mov eax, [OIL + 0x48]
  lea ecx, [ebx + ebx]
  xor edx, edx
  div ecx
  sub edx, ebx
  test eax, eax
  jnz .right
  mov [OIL + 0x40], edx
  neg ebx
  mov [OIL + 0x44], ebx
  neg ebx
  jmp .done
.right:
  cmp eax, 1
  jne .bottom
  mov [OIL + 0x40], ebx
  mov [OIL + 0x44], edx
  jmp .done
.bottom:
  neg edx
  cmp eax, 2
  jne .left
  mov [OIL + 0x40], edx
  mov [OIL + 0x44], ebx
  jmp .done
.left:
  neg ebx
  mov [OIL + 0x40], ebx
  neg ebx
  mov [OIL + 0x44], edx
.done:
  pop edx
  pop ecx
  ret
]]

-- oilAim(unit), stdcall, the moment an engineer pours: eax = 1 pour, 0 not. Its target tile
-- must be pourable. An automatic pour (targeting 0x19) is simply not made otherwise; a manual
-- one is moved to the nearest pourable tile up to 4 tiles away that lies no more than 45 degrees
-- off the engineer's line to the target, or refused with the "impossible location" line. A
-- refused engineer keeps his pot (state 0xB, holding it).
templates.oilAim = [[
  push ebx
  push esi
  push edi
  push ebp
  mov esi, [esp + 0x14]
  imul esi, esi, 0x490
  add esi, UNITS
  movsx eax, word [esi + 0x3E8]
  mov [OIL + 0x20], eax
  movsx eax, word [esi + 0x3EA]
  mov [OIL + 0x24], eax
  movsx eax, word [esi + 0xC4]
  mov [OIL + 0x28], eax
  movsx eax, word [esi + 0xC6]
  mov [OIL + 0x2C], eax
  mov eax, [OIL + 0x20]
  mov edx, [OIL + 0x24]
  call TILEAT
  test eax, eax
  jl .search
  call POURABLE
  test eax, eax
  jnz .ok
.search:
  cmp word [esi + 0x39C], 0x19
  je .quiet
  mov eax, [OIL + 0x20]
  sub eax, [OIL + 0x28]
  mov [OIL + 0x30], eax
  imul eax, eax
  mov ecx, [OIL + 0x24]
  sub ecx, [OIL + 0x2C]
  mov [OIL + 0x34], ecx
  imul ecx, ecx
  add eax, ecx
  mov [OIL + 0x38], eax
  cmp eax, 1600
  jg .refuse
  mov ebx, 1
.ring:
  cmp ebx, 4
  jg .refuse
  mov dword [OIL + 0x48], 0
.step:
  lea eax, [ebx*8]
  cmp [OIL + 0x48], eax
  jge .nextRing
  call RINGSTEP
  mov edi, [OIL + 0x20]
  add edi, [OIL + 0x40]
  mov ebp, [OIL + 0x24]
  add ebp, [OIL + 0x44]
  mov eax, edi
  mov edx, ebp
  call TILEAT
  test eax, eax
  jl .next
  call POURABLE
  test eax, eax
  jz .next
  mov eax, edi
  sub eax, [OIL + 0x28]
  mov ecx, ebp
  sub ecx, [OIL + 0x2C]
  mov edx, eax
  imul edx, [OIL + 0x30]
  push ecx
  imul ecx, [OIL + 0x34]
  add edx, ecx
  pop ecx
  test edx, edx
  jle .next
  imul eax, eax
  imul ecx, ecx
  add eax, ecx
  imul edx, edx
  add edx, edx
  mov ecx, eax
  imul ecx, [OIL + 0x38]
  cmp edx, ecx
  jl .next
  shl eax, 2
  mov ecx, [OIL + 0x38]
  lea ecx, [ecx + ecx*4 + 64]
  cmp eax, ecx
  jg .next
  mov [esi + 0x3E8], di
  mov [esi + 0x3EA], bp
  jmp .ok
.next:
  inc dword [OIL + 0x48]
  jmp .step
.nextRing:
  inc ebx
  jmp .ring
.refuse:
  movsx eax, word [esi + 0x96]
  cmp eax, [CURPLAYER]
  jne .quiet
  push 9
  push 30
  mov ecx, SFX
  call SPEECH
.quiet:
  mov word [esi + 0x2C0], 0xB
  mov word [esi + 0x39C], 0
  mov dword [esi + 0x2B0], 0
  xor eax, eax
  jmp .out
.ok:
  mov eax, 1
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret 4
]]

-- UpdateEngineer, state 0xA at the pouring frame, where the game marks the pot used: eax =
-- unit * 0x490, edx = the unit, esi = 0. Refused: straight to the function's epilogue.
templates.oilThrow = [[
  cmp dword [OIL + 0x00], 0
  je .pour
  push eax
  push edx
  push edx
  call OILAIM
  test eax, eax
  pop edx
  pop eax
  jz .refused
.pour:
  mov [eax + DEPOSIT], si
  jmp RESUME
.refused:
  jmp EPILOGUE
]]

-- ifNecessaryThrowOilAutomatically, about to take the enemy at edx (* 0x490) as its target:
-- only when it stands on pourable ground.
templates.oilAuto = [[
  cmp dword [OIL + 0x00], 0
  je .take
  mov eax, [edx + UNITTILE]
  call POURABLE
  test eax, eax
  jz FAIL
.take:
  mov word [esi + TARGETING], 0x14
  jmp RESUME
]]

-- ignite(owner, mx, my, height, strength), cdecl: the game's own fire at exactly that spot - its
-- fire function past the random nudge it gives every hit.
templates.ignite = [[
  push ebp
  push esi
  push edi
  mov edi, [esp + 0x14]
  mov ebp, [esp + 0x18]
  mov eax, edi
  cdq
  and edx, 7
  add eax, edx
  mov ecx, eax
  mov eax, ebp
  cdq
  and edx, 7
  add eax, edx
  sar ecx, 3
  sar eax, 3
  jmp FIRE_AT
]]

-- oilFire(owner, mx, my, height, strength), cdecl: ignite, and the new fire never spreads by
-- itself (its count of spread directions already at 4) - the oil decides where fire is. It burns,
-- flares at strength 3 and up and dies down like any other fire, the way a pitch ditch's does.
templates.oilFire = [[
  push dword [esp + 0x14]
  push dword [esp + 0x14]
  push dword [esp + 0x14]
  push dword [esp + 0x14]
  push dword [esp + 0x14]
  call IGNITE
  add esp, 0x14
  test eax, eax
  jle .done
  imul eax, eax, 0xE8
  mov word [FIREPARAM + eax + 2], 4
.done:
  ret
]]

-- oilSpread(owner, mx, my, height, strength), cdecl, in place of the fire an oil pot starts where
-- it lands: the same amount of oil spread over the ground - a flood from the landing tile over
-- pourable tiles of about the same height, AMOUNT tiles. Each tile burns with a strength from 5 at
-- the landing tile down to 2 at the far end (3 and up is the tall flame a pitch ditch burns with,
-- 2 a smaller one); none of these fires spreads by itself, so nothing burns past the oil and no
-- building catches. Narrow ground carries the oil far, open ground keeps it a pool.
-- With building damage on, a flammable building it touches loses a third of its health at most,
-- less the further from the landing tile the oil that reaches it is.
templates.oilSpread = [[
  cmp dword [OIL + 0x04], 0
  je FIRE
  push ebx
  push esi
  push edi
  push ebp
  mov eax, [esp + 0x14]
  mov [OIL + 0x4C], eax
  mov eax, [esp + 0x18]
  sar eax, 3
  mov [OIL + 0x50], eax
  mov eax, [esp + 0x1C]
  sar eax, 3
  mov [OIL + 0x54], eax
  mov eax, [OIL + 0x50]
  mov edx, [OIL + 0x54]
  call TILEAT
  test eax, eax
  jl .land
  call POURABLE
  test eax, eax
  jnz .landed
.land:
  mov ebx, 1
.lring:
  cmp ebx, 2
  jg .out
  mov dword [OIL + 0x48], 0
.lstep:
  lea eax, [ebx*8]
  cmp [OIL + 0x48], eax
  jge .lnext
  call RINGSTEP
  mov eax, [OIL + 0x50]
  add eax, [OIL + 0x40]
  mov edx, [OIL + 0x54]
  add edx, [OIL + 0x44]
  call TILEAT
  test eax, eax
  jl .lskip
  call POURABLE
  test eax, eax
  jz .lskip
  mov eax, [OIL + 0x40]
  add [OIL + 0x50], eax
  mov eax, [OIL + 0x44]
  add [OIL + 0x54], eax
  jmp .landed
.lskip:
  inc dword [OIL + 0x48]
  jmp .lstep
.lnext:
  inc ebx
  jmp .lring
.landed:
  inc dword [OIL + 0x10]
  mov dword [OIL + 0x14], 0
  mov dword [OIL + 0x18], 0
  mov dword [OIL + 0x1C], 0
  mov eax, [OIL + 0x50]
  mov edx, [OIL + 0x54]
  call TILEAT
  mov ecx, [OIL + 0x10]
  mov [STAMP + eax*4], ecx
  mov [QUEUE], eax
  mov ecx, [OIL + 0x50]
  mov [QUEUE + 4], ecx
  mov ecx, [OIL + 0x54]
  mov [QUEUE + 8], ecx
  mov dword [QUEUE + 12], 0
  mov dword [OIL + 0x14], 1
.pop:
  mov esi, [OIL + 0x18]
  cmp esi, [OIL + 0x14]
  jge .burn
  mov [OIL + 0x5C], esi
  mov byte [QFLAG + esi], 0
  inc dword [OIL + 0x18]
  shl esi, 4
  add esi, QUEUE
  xor ebx, ebx
.dir:
  cmp ebx, 4
  jge .pop
  mov edi, [esi + 4]
  add edi, [DIRS + ebx*8]
  mov ebp, [esi + 8]
  add ebp, [DIRS + ebx*8 + 4]
  inc ebx
  mov eax, edi
  mov edx, ebp
  call TILEAT
  test eax, eax
  jl .dir
  mov ecx, [OIL + 0x10]
  cmp [STAMP + eax*4], ecx
  je .dir
  mov edx, [esi]
  movzx ecx, byte [HEIGHT + edx]
  movzx edx, byte [HEIGHT + eax]
  sub ecx, edx
  jns .abs
  neg ecx
.abs:
  cmp ecx, 0x19
  jge .dir
  push eax
  call POURABLE
  test eax, eax
  pop eax
  jz .wall
  mov ecx, [OIL + 0x14]
  cmp ecx, [OIL + 0x08]
  jge .dir
  mov edx, [OIL + 0x10]
  mov [STAMP + eax*4], edx
  inc dword [OIL + 0x14]
  shl ecx, 4
  mov [QUEUE + ecx], eax
  mov [QUEUE + ecx + 4], edi
  mov [QUEUE + ecx + 8], ebp
  mov edx, [esi + 12]
  inc edx
  mov [QUEUE + ecx + 12], edx
  jmp .dir
.wall:
  mov edx, [OIL + 0x10]
  mov [STAMP + eax*4], edx
  movsx edx, word [BIDS + eax*2]
  test edx, edx
  jle .dir
  mov ecx, [OIL + 0x5C]
  mov byte [QFLAG + ecx], 1
  mov ecx, [OIL + 0x1C]
.seen:
  dec ecx
  js .new
  push ecx
  shl ecx, 4
  cmp [BLIST + ecx], edx
  pop ecx
  jne .seen
  jmp .dir
.new:
  mov ecx, [OIL + 0x1C]
  cmp ecx, 32
  jge .dir
  inc dword [OIL + 0x1C]
  push ecx
  shl ecx, 4
  mov [BLIST + ecx], edx
  mov [BLIST + ecx + 4], eax
  mov [BLIST + ecx + 8], edi
  mov [BLIST + ecx + 12], ebp
  pop ecx
  mov edx, [esi + 12]
  mov [BDEPTH + ecx*4], edx
  jmp .dir
.burn:
  mov eax, [OIL + 0x14]
  dec eax
  shl eax, 4
  mov eax, [QUEUE + eax + 12]
  mov [OIL + 0x58], eax
  xor esi, esi
.light:
  cmp esi, [OIL + 0x14]
  jge .damage
  mov edi, esi
  shl edi, 4
  mov eax, [OIL + 0x58]
  sub eax, [QUEUE + edi + 12]
  imul eax, eax, 3
  add eax, [OIL + 0x58]
  mov ecx, [OIL + 0x58]
  inc ecx
  xor edx, edx
  div ecx
  lea ebx, [eax + 2]
  cmp ebx, 5
  jle .strength
  mov ebx, 5
.strength:
  mov [OIL + 0x8C], ebx
  mov dword [OIL + 0x74], 0
  mov eax, [OIL + 0x4C]
  mov [OIL + 0x78], eax
  mov eax, [QUEUE + edi + 4]
  shl eax, 3
  add eax, 4
  mov [OIL + 0x7C], eax
  mov eax, [QUEUE + edi + 8]
  shl eax, 3
  add eax, 4
  mov [OIL + 0x80], eax
  mov eax, [QUEUE + edi]
  movzx eax, byte [HEIGHT + eax]
  add eax, 8
  mov [OIL + 0x84], eax
  mov eax, [QUEUE + edi + 12]
  imul eax, eax, STEP
  add eax, [TICKS]
  inc eax
  mov [OIL + 0x70], eax
  test esi, esi
  jz .now
  call ENQUEUE
  test eax, eax
  jnz .lit
.now:
  push dword [OIL + 0x8C]
  push dword [OIL + 0x84]
  push dword [OIL + 0x80]
  push dword [OIL + 0x7C]
  push dword [OIL + 0x78]
  call OILFIRE
  add esp, 0x14
.lit:
  inc esi
  jmp .light
.damage:
  cmp dword [OIL + 0x0C], 0
  je .out
  inc dword [OIL + 0x58]
  xor esi, esi
.hurt:
  cmp esi, [OIL + 0x1C]
  jge .out
  mov edi, esi
  shl edi, 4
  push dword [BLIST + edi]
  mov ecx, BSTATE
  call FLAMMABLE
  test eax, eax
  jz .skip
  cmp eax, 4
  je .skip
  mov eax, [BLIST + edi]
  imul eax, eax, 0x32C
  movzx eax, word [BMAXHP + eax]
  mov ecx, [OIL + 0x58]
  sub ecx, [BDEPTH + esi*4]
  jle .skip
  imul eax, ecx
  mov ecx, [OIL + 0x58]
  imul ecx, ecx, 3
  xor edx, edx
  div ecx
  test eax, eax
  jnz .hit
  mov eax, 1
.hit:
  mov [OIL + 0x8C], eax
  mov dword [OIL + 0x74], 1
  mov eax, [OIL + 0x4C]
  mov [OIL + 0x78], eax
  mov eax, [BLIST + edi + 4]
  mov [OIL + 0x7C], eax
  mov eax, [BLIST + edi + 8]
  mov [OIL + 0x80], eax
  mov eax, [BLIST + edi + 12]
  mov [OIL + 0x84], eax
  mov eax, [BDEPTH + esi*4]
  inc eax
  imul eax, eax, STEP
  add eax, [TICKS]
  inc eax
  mov [OIL + 0x70], eax
  call ENQUEUE
  test eax, eax
  jnz .skip
  push 0
  push 0
  push dword [OIL + 0x78]
  push 0
  push dword [OIL + 0x8C]
  push dword [OIL + 0x84]
  push dword [OIL + 0x80]
  push dword [OIL + 0x7C]
  mov ecx, TMS
  call DAMAGE
.skip:
  inc esi
  jmp .hurt
.out:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret
]]

-- enqueue: the event at [OIL+0x70] (8 dwords) into a free PEND slot. eax = 1 queued, 0 full.
templates.oilEnqueue = [[
  push esi
  push edi
  push ecx
  xor ecx, ecx
.find:
  cmp ecx, PENDMAX
  jge .full
  mov edi, ecx
  shl edi, 5
  add edi, PEND
  cmp dword [edi], 0
  je .put
  inc ecx
  jmp .find
.put:
  lea esi, [OIL + 0x70]
  mov ecx, 8
  cld
  rep movsd
  inc dword [OIL + 0x64]
  mov eax, 1
  jmp .out
.full:
  xor eax, eax
.out:
  pop ecx
  pop edi
  pop esi
  ret
]]

-- updateEntities, once a tick, before the game's own: the queued oil fire and building damage
-- that is due, so the oil runs outwards tile by tile (all dropped when the tick counter jumps - a
-- loaded game). Then the game's first six bytes.
templates.oilTick = [[
  push eax
  push edx
  mov eax, [TICKS]
  mov edx, eax
  sub edx, [OIL + 0x68]
  mov [OIL + 0x68], eax
  mov [OIL + 0x6C], edx
  pop edx
  pop eax
  cmp dword [OIL + 0x64], 0
  je .game
  pushad
  mov ebx, [TICKS]
  cmp dword [OIL + 0x6C], 4000
  jb .run
  mov edi, PEND
  mov ecx, PENDMAX * 8
  xor eax, eax
  cld
  rep stosd
  mov dword [OIL + 0x64], 0
  jmp .done
.run:
  xor esi, esi
.event:
  cmp esi, PENDMAX
  jge .done
  mov edi, esi
  shl edi, 5
  add edi, PEND
  mov eax, [edi]
  test eax, eax
  jz .next
  cmp eax, ebx
  ja .next
  cmp dword [edi + 4], 0
  jne .damage
  push dword [edi + 24]
  push dword [edi + 20]
  push dword [edi + 16]
  push dword [edi + 12]
  push dword [edi + 8]
  call OILFIRE
  add esp, 0x14
  jmp .free
.damage:
  push 0
  push 0
  push dword [edi + 8]
  push 0
  push dword [edi + 24]
  push dword [edi + 20]
  push dword [edi + 16]
  push dword [edi + 12]
  mov ecx, TMS
  call DAMAGE
.free:
  mov dword [edi], 0
  dec dword [OIL + 0x64]
.next:
  inc esi
  jmp .event
.done:
  popad
.game:
  push ecx
  push ebx
  push ebp
  push esi
  mov esi, ecx
  jmp RESUME
]]

return templates
