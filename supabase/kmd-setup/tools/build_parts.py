#!/usr/bin/env python3
"""Pack the base, every migration (with KMD overrides, minus skips) and the
finishing step into numbered SQL Editor parts. A part ends after any file that
adds an enum value, because Postgres will not use a new enum value in the
same transaction that added it, and the SQL Editor runs a paste as one."""
import os, re, sys

KDB = "/home/claude/kmddb"
REPO = "/home/claude/src/kmd-one/supabase"
OUT = sys.argv[1]
MAX = int(sys.argv[2]) if len(sys.argv) > 2 else 380_000

skip = set(open(f"{KDB}/skip.txt").read().split())
files = []
for f in sorted(os.listdir(f"{KDB}/base")):
    files.append(("base", f, f"{KDB}/base/{f}"))
migs = []
for d in ("migrations", "fee-migrations"):
    for f in os.listdir(f"{REPO}/{d}"):
        if f.endswith(".sql") and f not in skip:
            p = f"{KDB}/override/{f}" if os.path.exists(f"{KDB}/override/{f}") else f"{REPO}/{d}/{f}"
            migs.append((d, f, p))
migs.sort(key=lambda x: x[1])
files += migs
for f in sorted(os.listdir(f"{KDB}/post")):
    files.append(("post", f, f"{KDB}/post/{f}"))

os.makedirs(OUT, exist_ok=True)
for old in os.listdir(OUT):
    os.remove(os.path.join(OUT, old))

parts, cur, size = [], [], 0
for kind, name, path in files:
    text = open(path, encoding="utf-8").read()
    block = f"\n-- ======================================================== {kind}/{name}\n{text.rstrip()}\n"
    if cur and size + len(block.encode()) > MAX:
        parts.append(cur); cur, size = [], 0
    cur.append((name, block)); size += len(block.encode())
    if re.search(r"alter\s+type\s+\S+\s+add\s+value", text, re.I):
        parts.append(cur); cur, size = [], 0
if cur: parts.append(cur)

total = len(parts) + 1
ext = """-- KMD One database setup — part 1 of %d: switch on the extensions it uses.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
""" % total
open(f"{OUT}/kmd_db_part01_extensions.sql", "w").write(ext)
for i, p in enumerate(parts, start=2):
    head = f"-- KMD One database setup — part {i} of {total}. Run the parts in order, each once.\n-- Files: {p[0][0]} … {p[-1][0]}\n"
    open(f"{OUT}/kmd_db_part{i:02d}.sql", "w", encoding="utf-8").write(head + "".join(b for _, b in p))
    print(f"part {i:02d}: {len(p):3d} files, {sum(len(b.encode()) for _, b in p)//1024:4d} KB  ({p[0][0]} .. {p[-1][0]})")
