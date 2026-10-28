"""Every AOB the module scans, every byte it expects and every operand it reads, checked
against both shipped executables without running the game. Reads the constants out of
module/init.lua so the two cannot drift apart.

    python tools/check_sites.py
"""
import os, re, struct, sys
import pefile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = r'H:\steam\steamapps\common\Stronghold Crusader Extreme UCP3 new'
EXES = {'vanilla': os.path.join(GAME, 'Stronghold Crusader.exe'),
        'extreme': os.path.join(GAME, 'Stronghold_Crusader_Extreme.exe')}

src = open(os.path.join(HERE, 'module', 'init.lua'), encoding='utf-8').read()
AOB = dict(re.findall(r'(?:local |^\s+)(AOB_\w+) = "([^"]+)"', src, re.M))
# patterns written over two lines: "..." .. "..."
for k, a1, a2 in re.findall(r'local (AOB_\w+) = "([^"]+)"\n\s*\.\. "([^"]+)"', src):
    AOB[k] = a1 + a2
NUM = {k: int(v, 16) for k, v in re.findall(r'(?:local |^\s+)(\w+) = (-?0x[0-9A-Fa-f]+)\b', src, re.M)}
NUM.update({k: int(v) for k, v in re.findall(r'local (\w+) = (-?\d+)\n', src)})
SITE = {}
for k, off, bytes_ in re.findall(r'(?:local |^\s+)(\w+) = \{ (0x[0-9A-F]+), \{ ([^}]*) \} \}', src, re.M):
    SITE[k] = (int(off, 16), [int(b, 16) for b in bytes_.split(',')])
BYTES = {k: [int(b, 16) for b in v.split(',')] for k, v in
         re.findall(r'local (\w+) = \{ (0x[0-9A-F]{2}(?:, 0x[0-9A-F]{2})+) \}', src)}

class Exe:
    def __init__(self, path):
        pe = pefile.PE(path, fast_load=True)
        self.data = open(path, 'rb').read()
        base = pe.OPTIONAL_HEADER.ImageBase
        self.secs = [(s.VirtualAddress + base, s.SizeOfRawData, s.PointerToRawData) for s in pe.sections]
    def off(self, va):
        for vs, size, raw in self.secs:
            if vs <= va < vs + size:
                return raw + va - vs
        raise ValueError(hex(va))
    def va(self, off):
        for vs, size, raw in self.secs:
            if raw <= off < raw + size:
                return vs + off - raw
    def scan(self, pattern):
        rx = b''.join(b'.' if t == '?' else re.escape(bytes([int(t, 16)])) for t in pattern.split())
        return [self.va(m.start()) for m in re.finditer(rx, self.data, re.S)]
    def b(self, va, n): o = self.off(va); return list(self.data[o:o + n])
    def u32(self, va): return struct.unpack('<I', bytes(self.b(va, 4)))[0]
    def i32(self, va): return struct.unpack('<i', bytes(self.b(va, 4)))[0]

errors = []
def need(cond, what):
    if not cond:
        errors.append(what)
    return cond

def check(name, e):
    out = {}
    def scan(key, delta=0):
        hits = e.scan(AOB[key])
        need(len(hits) == 1, '%s %s: %d hits' % (name, key, len(hits)))
        return (hits[0] + delta) if hits else None
    def expect(at, bytes_, what):
        need(e.b(at, len(bytes_)) == bytes_, '%s %s at %X: %s' % (name, what, at, bytes(e.b(at, len(bytes_))).hex(' ')))
    def operand(base, key):
        off, bytes_ = SITE[key]
        expect(base + off, bytes_, key)
        return e.u32(base + off + len(bytes_))
    def call(at, what):
        expect(at, [0xE8], what)
        return at + 5 + e.i32(at + 1)

    flags = e.u32(scan('AOB_TILE_FLAGS') + NUM['TILE_FLAGS_OPERAND'])
    teams = e.u32(scan('AOB_TEAMS') + NUM['TEAMS_OPERAND'])
    ticks = e.u32(scan('AOB_TICKS') + NUM['TICKS_OPERAND'])
    upd = scan('AOB_UPDATE_CALL')
    expect(upd + SITE['UPDATE_TABLE'][0], SITE['UPDATE_TABLE'][1], 'UPDATE_TABLE')
    expect(upd + NUM['UPDATE_CURRENT_AT'], [0xA1], 'UPDATE_CURRENT')
    out['current'] = e.u32(upd + NUM['UPDATE_CURRENT_AT'] + 1)
    out['stop'] = scan('AOB_STOP_WALKING')
    print('%-8s update table %X current unit %X stopWalking %X' % (name,
        e.u32(upd + SITE['UPDATE_TABLE'][0] + 3), out['current'], out['stop']))
    harass = scan('AOB_HARASS')
    expect(harass + SITE['HARASS_HOOK'][0], SITE['HARASS_HOOK'][1], 'HARASS_HOOK')
    for k in ('HARASS_RESULT', 'HARASS_TARGET_X', 'HARASS_TARGET_Y'):
        out[k] = operand(harass, k)
    cone = scan('AOB_CONE')
    btype, bowner, health = operand(cone, 'CONE_TYPE'), operand(cone, 'CONE_OWNER'), operand(cone, 'CONE_HEALTH')
    need(bowner - btype == 4, name + ' building layout')
    acq = scan('AOB_ACQUIRE') + NUM['ACQUIRE_RANGE']
    expect(acq, BYTES['RANGE_READ'], 'RANGE_READ')
    rng = e.u32(acq + 3)
    ranges = [e.i32(rng + 4 * i) for i in (1, 2, 3, 0x25)]
    tents = scan('AOB_TENTS')
    angle = call(tents + NUM['TENTS_ANGLE_CALL'], 'angle call')
    suit = call(tents + NUM['TENTS_SUIT_CALL'], 'suitable call')
    expect(angle, BYTES['TENT_PROLOGUE'], 'angle prologue')
    expect(suit, BYTES['TENT_PROLOGUE'], 'suitable prologue')
    find = call(angle + NUM['ANGLE_FIND_CALL'], 'spot search call')
    expect(find + SITE['SPOT_HOOK'][0], SITE['SPOT_HOOK'][1], 'SPOT_HOOK')
    three = e.u32(find + NUM['SPOT_THREE'])
    tid = operand(find, 'SPOT_TRIBE')
    need(three - tid == 8, name + ' tent spot layout')
    off, bytes_ = SITE['SPOT_FOUND']; expect(find + off, bytes_, 'SPOT_FOUND')
    found = find + off + 6 + e.i32(find + off + 2)
    location = scan('AOB_LOCATION')
    expect(location + SITE['LOCATION_HOOK'][0], SITE['LOCATION_HOOK'][1], 'LOCATION_HOOK')
    operand(location, 'LOCATION_ATTACKED'); operand(location, 'LOCATION_LAYER')
    eng = scan('AOB_ENGINEERS')
    ut, bt = operand(eng, 'ENGINEERS_UNIT_TYPES'), operand(eng, 'ENGINEERS_TENT_TYPES')
    cmd = scan('AOB_COMMAND')
    for k in [k for k in SITE if k.startswith('CMD_')]:
        off, bytes_ = SITE[k]; expect(cmd + off, bytes_, k)
    tribes = operand(cmd, 'CMD_TRIBES')
    stride = operand(cmd, 'CMD_STRIDE')
    leader = operand(cmd, 'CMD_LEADER') - tribes
    need(leader == 0x5A, name + ' troop leader offset %X' % leader)
    first = operand(cmd, 'CMD_UNITS')
    maxu = (operand(cmd, 'CMD_LAST') - first) // 0x490 + 1
    call(cmd + SITE['CMD_MOVE'][0], 'move'); call(cmd + SITE['CMD_ASSIGN'][0], 'assign')
    free = scan('AOB_FREE_TILE', NUM['FREE_TILE_START'])
    expect(free, BYTES['FREE_TILE_PROLOGUE'], 'FREE_TILE_PROLOGUE')
    operand(free, 'FREE_TILE_PF'); call(free + SITE['FREE_TILE_NAVIGATE'][0], 'navigate')
    call(scan('AOB_UPDATE_CATAPULT') + NUM['CATAPULT_SET_DESTINATION'], 'setDestinationForUnit')
    order = scan('AOB_INSTRUCTION')
    entrance = call(order + NUM['INSTRUCTION_ENTRANCE'], 'entrance test')
    call(order + NUM['INSTRUCTION_DESELECT'], 'deselect'); call(order + NUM['INSTRUCTION_UNSELECT'], 'unselect')
    required = call(scan('AOB_UPDATE_ENGINEER') + NUM['ENGINEER_REQUIRED'], 'engineer count')
    print('         entrance test %X engineer count %X' % (entrance, required))
    eng = scan('AOB_UPDATE_ENGINEER')
    expect(eng + SITE['ENGINEER_POUR'][0], SITE['ENGINEER_POUR'][1], 'ENGINEER_POUR')
    expect(eng + SITE['ENGINEER_EPILOGUE'][0], SITE['ENGINEER_EPILOGUE'][1], 'ENGINEER_EPILOGUE')
    ao = scan('AOB_AUTO_OIL')
    expect(ao + SITE['AUTO_OIL_TAKE'][0], SITE['AUTO_OIL_TAKE'][1], 'AUTO_OIL_TAKE')
    expect(ao + SITE['AUTO_OIL_FAIL'][0], SITE['AUTO_OIL_FAIL'][1], 'AUTO_OIL_FAIL')
    potA = scan('AOB_OIL_POT')
    fire = call(potA + NUM['OIL_POT_FIRE'], 'oil pot fire')
    expect(potA + SITE['OIL_POT_SOUND'][0], SITE['OIL_POT_SOUND'][1], 'OIL_POT_SOUND')
    call(potA + NUM['OIL_POT_SOUND_CALL'], 'pot sound')
    expect(fire + SITE['FIRE_AT'][0], SITE['FIRE_AT'][1], 'FIRE_AT')
    expect(fire + SITE['FIRE_STRENGTH'][0], SITE['FIRE_STRENGTH'][1], 'FIRE_STRENGTH')
    fl = call(scan('AOB_CONE') + NUM['CONE_FLAMMABLE'], 'flammability')
    expect(scan('AOB_ENTITIES'), SITE['ENTITIES_PROLOGUE'][1], 'ENTITIES_PROLOGUE')
    print('         flammability %X fire strength at %X' % (fl, e.u32(fire + SITE['FIRE_STRENGTH'][0] + 3)))
    mv = scan('AOB_MOVE_COMMAND')
    for k in ('MOVE_LOCAL_PLAYER', 'MOVE_SFX'):
        expect(mv + SITE[k][0], SITE[k][1], k)
    speech = call(mv + NUM['MOVE_SPEECH'], 'speech')
    dmg = scan('AOB_BUILDING_DAMAGE')
    print('         oil: fire %X speech %X damage %X' % (fire, speech, dmg))
    print('%-8s harass %X tents %X/%X spots %X found %X location %X command %X freeTile %X' %
          (name, harass, angle, suit, find, found, location, cmd, free))
    print('         tribes %X stride %X units %X maxUnits %d ranges %s teams %X ticks %X flags %X' %
          (tribes, stride, first - 0x490 - 0x8E, maxu, ranges, teams, ticks, flags))
    print('         engine units %s tent types %s' % ([e.i32(ut + 4 * i) for i in range(6)],
                                                   [e.i32(bt + 4 * i) for i in range(6)]))

for name, path in EXES.items():
    check(name, Exe(path))
print('\n'.join(errors) if errors else 'ALL SITES OK')
sys.exit(1 if errors else 0)
