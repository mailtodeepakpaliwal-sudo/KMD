#!/usr/bin/env python3
"""Columns of public.* objects as the SQL migrations use them: `alias.col`
where alias is bound by `from/join public.obj [as] alias`, plus insert column
lists `insert into public.obj (a, b)`. Output JSON {obj: [cols]}."""
import glob, json, re, sys
from collections import defaultdict

files = sys.argv[1:-1]
out = defaultdict(set)
KW = set("on where join left right inner full cross group order limit using set values select returning union lateral and or as".split())
for f in files:
    t = open(f).read().lower()
    t = re.sub(r"--[^\n]*", "", t)
    # split into statements roughly by function body / ';'
    for chunk in re.split(r";\s*\n", t):
        aliases = {}
        for m in re.finditer(r"(?:from|join|update|into)\s+public\.([a-z_0-9]+)(?:\s+(?:as\s+)?([a-z_][a-z0-9_]*))?", chunk):
            obj, al = m.group(1), m.group(2)
            if al and al not in KW:
                aliases[al] = obj
            aliases.setdefault(obj, obj)
            aliases["public." + obj] = obj
        for m in re.finditer(r"\b(public\.)?([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\b", chunk):
            key = (m.group(1) or "") + m.group(2)
            if key in aliases:
                out[aliases[key]].add(m.group(3))
        for m in re.finditer(r"insert\s+into\s+public\.([a-z_0-9]+)\s*\(([^)]*)\)", chunk):
            for c in m.group(2).split(","):
                c = c.strip()
                if re.fullmatch(r"[a-z_][a-z0-9_]*", c): out[m.group(1)].add(c)
        for m in re.finditer(r"update\s+public\.([a-z_0-9]+)(?:\s+(?:as\s+)?[a-z_]+)?\s+set\s+(.*?)(?:\bwhere\b|$)", chunk, re.S):
            for c in re.findall(r"(?:^|,)\s*([a-z_][a-z0-9_]*)\s*=", m.group(2)):
                out[m.group(1)].add(c)
json.dump({k: sorted(v) for k, v in sorted(out.items())}, open(sys.argv[-1], "w"), indent=1)
print(len(out), "objects")
