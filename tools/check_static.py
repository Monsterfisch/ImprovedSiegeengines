"""Static checks, no emulator: lua syntax, every asm script assembled with UCP's own fasm.dll
(through 32-bit PowerShell, 57600 of its 64000 bytes), with the constants the module would pass.

    python tools/check_static.py
"""
import os, re, subprocess, sys, tempfile
import lupa.lua54 as lua54

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.path.join(HERE, 'module')

def lua_syntax():
    rt = lua54.LuaRuntime()
    check = rt.eval('function(s, n) local f, e = load(s, n) return e or "" end')
    ok = True
    for name in ('init.lua', 'templates.lua'):
        src = open(os.path.join(MODULE, name), encoding='utf-8').read()
        err = check(src, name)
        if err:
            print('LUA', name, err); ok = False
        else:
            print('lua ok', name)
    return ok

def scripts():
    rt = lua54.LuaRuntime()
    src = open(os.path.join(MODULE, 'templates.lua'), encoding='utf-8').read()
    t = rt.execute(src)
    return {k: t[k] for k in t}

def strip(script):
    lines = []
    for line in script.split('\n'):
        line = re.sub(r';.*$', '', line).strip()
        if line:
            lines.append(line)
    return re.sub(r'\.([A-Za-z][\w]*)', r'L_\1', '\n'.join(lines)) + '\n'

# every constant a script may name; real vanilla values where they matter for encoding
NAMES = ('D FLAGS WOWNER TILEY ROWS VALID BIDS UNITMAP AREA BTYPE BOWNER HEALTH TEAMS RANGE TICKS '
         'UNITS US TRIBES PLAYERS TILEAT WALLAT CLEARAT SEARCH ALG_X ALG_Y ALG_TILE SHOOT RESUME '
         'TK FORT DIST THREATS ENG_UT ENG_BT THREE TID FOUND CONTINUE ATTACKED_PID LAYER THREATLIST '
         'DISTMAP PREPARE FOOTPRINT SAFE ORIG GAME DIAGONAL DIAGS PF NAV FREETILE LUA LIST COLLECT').split()
SMALL = {'TSTRIDE': 0x334, 'MAXUNITS': 2500, 'MAXTRIBES': 2400, 'TILES': 0x13A10, 'MELEE': 10,
         'MAXTHREATS': 4000, 'MAXTESTS': 24, 'ARGS': 4}

def main():
    ok = lua_syntax()
    out = tempfile.mkdtemp(prefix='ise_fasm_')
    for name, script in scripts().items():
        text = strip(script)
        consts = []
        for i, n in enumerate(NAMES):
            if re.search(r'(?<![\w])%s(?![\w])' % n, text):
                consts.append('%s = 0x%X' % (n, 0x01000000 + i * 0x10000))
        for n, v in SMALL.items():
            if re.search(r'(?<![\w])%s(?![\w])' % n, text):
                consts.append('%s = 0x%X' % (n, v))
        src = 'use32\norg 0x10000000\n' + '\n'.join(consts) + '\n' + text
        open(os.path.join(out, name + '.asm'), 'w', newline='\n').write(src)
    ps = os.path.join(os.environ['WINDIR'], 'SysWOW64', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    subprocess.run([ps, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    os.path.join(HERE, 'tools', 'fasm32_margin.ps1'), out], check=True)
    for f in sorted(os.listdir(out)):
        if f.endswith('.err'):
            ok = False
            print('FASM', f, open(os.path.join(out, f)).read())
        elif f.endswith('.bin'):
            print('fasm ok %-16s %5d bytes' % (f[:-4], os.path.getsize(os.path.join(out, f))))
    print('ALL OK' if ok else 'FAILED')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
