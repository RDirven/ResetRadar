import sys, glob, os
from lupa import lua51
here = os.path.dirname(os.path.abspath(__file__))
base = os.path.dirname(here)
lua = lua51.LuaRuntime(unpack_returned_tuples=True)
check = lua.execute("return function(src, name) local fn, err = loadstring(src, name) return err end")
bad = False
for f in glob.glob(base + "/**/*.lua", recursive=True):
    err = check(open(f, encoding="utf-8").read(), "@" + os.path.basename(f))
    if err:
        print("SYNTAX", err); bad = True
if bad: sys.exit(1)
lua.execute(open(os.path.join(here, "mock.lua"), encoding="utf-8").read())
toc = [l.strip().replace("\\", "/") for l in open(base + "/ResetRadar.toc") if l.strip() and not l.startswith("#")]
loader = lua.execute("return function(src, name, ns) local fn = assert(loadstring(src, '@' .. name)) fn('ResetRadar', ns) end")
ns = lua.table()
for f in toc:
    loader(open(base + "/" + f, encoding="utf-8").read(), f, ns)
lua.execute(open(os.path.join(here, "scenario.lua"), encoding="utf-8").read())
print("ALL OK")
