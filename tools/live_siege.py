"""Read-only look at the running game (Extreme or vanilla): every AI player's attack state,
shields, siege towers, ranged engines and the troops a shield could walk with - the same fields
the module reads. Nothing is written to the game.

    python tools/live_siege.py
"""
import ctypes, ctypes.wintypes as W, struct, subprocess

K = ctypes.WinDLL('kernel32', use_last_error=True)
K.OpenProcess.restype = W.HANDLE
K.ReadProcessMemory.argtypes = [W.HANDLE, W.LPCVOID, W.LPVOID, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]

# units, unit count, tribes, tribe stride, players, teams, tile flags
LAYOUT = {
    'Stronghold_Crusader_Extreme.exe': (0x145D03C, 10000, 0x1F9AFC0, 0x688, 0x11EEA38, 0x1210188, 0x268B868),
    'Stronghold Crusader.exe': (0x138854C, 2500, 0x1667F78, 0x334, 0x115BDF8, 0x117D548, 0x1BF8368),
}
FOLLOW = {0x334: 0x21A, 0x688: 0x56C}
NAMES = {60: 'shield', 58: 'tower', 39: 'catapult', 40: 'trebuchet', 41: 'mangonel', 77: 'fire ballista',
         30: 'engineer', 22: 'archer', 23: 'crossbow', 70: 'A archer', 72: 'slinger', 74: 'horse archer',
         76: 'firethrower'}
SLOTS = {'diggers': [0x11], 'backup': [0xBA, 0xBB, 0xBC], 'patrol': [0x0F, 0x10], 'siegedef': [0xBE, 0xBF],
         'main': list(range(0xC0, 0xC8)), 'engage': [0xBD], 'att2': [0x0C]}


def pid_of(name):
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq ' + name, '/FO', 'CSV', '/NH'],
                         capture_output=True, text=True, encoding='mbcs', errors='replace').stdout or ''
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if parts and parts[0].lower() == name.lower():
            return int(parts[1])


class Game:
    def __init__(self):
        for name, layout in LAYOUT.items():
            pid = pid_of(name)
            if pid:
                self.name = name
                self.units, self.count, self.tribes, self.stride, self.players, self.teams, flags = layout
                self.h = K.OpenProcess(0x0010 | 0x0400, False, pid)
                if not self.h:
                    raise SystemExit('cannot open %s: error %d' % (name, ctypes.get_last_error()))
                return
        raise SystemExit('the game is not running')

    def read(self, address, size):
        buf = ctypes.create_string_buffer(size)
        got = ctypes.c_size_t()
        if not K.ReadProcessMemory(self.h, address, buf, size, ctypes.byref(got)):
            raise OSError('read %X failed' % address)
        return buf.raw

    def u32(self, a): return struct.unpack('<I', self.read(a, 4))[0]
    def s16(self, a): return struct.unpack('<h', self.read(a, 2))[0]
    def u8(self, a): return self.read(a, 1)[0]


def main():
    g = Game()
    print(g.name)
    unit = lambda i: g.units + i * 0x490
    tribe = lambda t: g.tribes + t * g.stride
    blob = g.read(g.units, g.count * 0x490)
    def field(i, off, fmt='<h'):
        return struct.unpack_from(fmt, blob, i * 0x490 + off)[0]
    for p in range(1, 9):
        pa = g.players + p * 0x39F4
        if g.u32(pa + 0x2300) == 0:
            continue
        print('\nplayer %d  ai state %d  attacks %d  team %d' % (p, g.u32(pa + 0x2BA4), g.u32(pa + 0x2BD8),
                                                             g.u32(g.teams + 4 * p)))
        for label, slots in SLOTS.items():
            out = []
            for s in slots:
                t = g.s16(pa + 0x310C + 2 * s)
                if t <= 0:
                    continue
                ok = g.u32(pa + 0x329C + 4 * s) == g.u32(tribe(t) + 0x34)
                leader = g.s16(tribe(t) + 0x5A)
                kind = field(leader, 0x8E) if 0 < leader < g.count else -1
                out.append('%X:troop %d %s alive=%d size=%d leader %d (%s, its troop %d)' % (
                    s, t, 'ok' if ok else 'STALE', g.s16(tribe(t) + 0x40), g.s16(tribe(t) + 0x5C), leader,
                    NAMES.get(kind, kind), field(leader, 0x2D8) if 0 < leader < g.count else -1))
            if out:
                print('  %-8s %s' % (label, '\n           '.join(out)))
        for i in range(1, g.count):
            if field(i, 0x8C) == 0 or field(i, 0x96) != p:
                continue
            kind = field(i, 0x8E)
            if kind not in (60, 58, 39, 40, 41, 77):
                continue
            t = field(i, 0x2D8)
            link = g.s16(tribe(t) + FOLLOW[g.stride]) if t > 0 else 0
            print('  %-13s unit %5d at %3d,%3d state %d order %3d troop %4d -> %4d tentbyte %d behaviour %2d '
                  'crew %d targeting %d' % (
                      NAMES[kind], i, field(i, 0xC4), field(i, 0xC6), field(i, 0x8C), field(i, 0x2C0), t, link,
                      blob[i * 0x490 + 0x3FE], field(i, 0x42A), field(i, 0x3B4), field(i, 0x39C)))


if __name__ == '__main__':
    main()
