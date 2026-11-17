#!/usr/bin/env python3
"""Recover the columns of fee tables from how the TypeScript code uses them.

For every `.from("table")` chain: select lists (inline or a const string in the
same file), filter / order columns, onConflict, and keys of inline objects
passed to insert / update / upsert. Embedded relations `alias:table(cols)` and
`table!hint(cols)` add columns to the related table and record a join.
Also records literal values compared against a column, to guess types.
Output: JSON {table: {col: {"kinds": [...], "values": [...]}}, "_joins": [...]}.
"""
import json, os, re, sys
from collections import defaultdict

ROOT = sys.argv[1]
TABLES = set(sys.argv[2].split(","))
OUT = sys.argv[3]

cols = defaultdict(lambda: defaultdict(lambda: {"kinds": set(), "values": set()}))
joins = set()

def add(t, c, kind, val=None):
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", c or ""):
        return
    e = cols[t][c]
    e["kinds"].add(kind)
    if val is not None:
        e["values"].add(str(val)[:40])

def chain_end(src, i):
    """Index where the call chain starting at i ends (depth-0 ';' or blank-line)."""
    depth = 0; j = i; n = len(src); q = None
    while j < n:
        ch = src[j]
        if q:
            if ch == "\\": j += 2; continue
            if ch == q: q = None
        elif ch in "\"'`": q = ch
        elif ch in "([{": depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth < 0: return j
        elif ch in ";," and depth == 0: return j
        elif depth == 0 and src.startswith(".from(", j): return j
        j += 1
    return n

def split_top(s):
    out, depth, cur, q = [], 0, "", None
    for ch in s:
        if q:
            cur += ch
            if ch == q: q = None
            continue
        if ch in "\"'`": q = ch
        if ch == "(": depth += 1
        if ch == ")": depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    out.append(cur)
    return [x.strip() for x in out if x.strip()]

def parse_select(table, s, consts):
    s = re.sub(r"\$\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}", lambda m: consts.get(m.group(1), ""), s)
    s = re.sub(r"\s+", " ", s)
    for part in split_top(s):
        part = part.strip()
        if part in ("*", "count"): continue
        m = re.match(r"^(?:([a-z_][a-z0-9_]*)\s*:\s*)?([a-z_][a-z0-9_]*)(?:!([a-z_][a-z0-9_]*))?\s*\((.*)\)$", part, re.S)
        if m:
            alias, rel, hint, inner = m.groups()
            if rel in ("count", "sum", "avg", "min", "max"):
                continue
            if hint and hint not in ("inner", "left"):
                add(table, hint, "fk-hint")
            joins.add((table, rel, hint or "", alias or ""))
            parse_select(rel, inner, consts)
            continue
        m = re.match(r"^(?:[a-z_][a-z0-9_]*\s*:\s*)?([a-z_][a-z0-9_]*)(?:::[a-z]+)?(?:->.*)?$", part)
        if m:
            add(table, m.group(1), "select")

def obj_keys(s):
    keys = []
    depth = 0
    for m in re.finditer(r"[{}]|([A-Za-z_][A-Za-z0-9_]*)\s*:|\.\.\.", s):
        tok = m.group(0)
        if tok == "{": depth += 1
        elif tok == "}": depth -= 1
        elif m.group(1) and depth == 1:
            keys.append(m.group(1))
    # shorthand keys { a, b }
    if depth == 0:
        inner = s.strip()[1:-1] if s.strip().startswith("{") else ""
        for p in split_top(inner):
            if re.fullmatch(r"[a-z_][a-z0-9_]*", p): keys.append(p)
    return keys

def matching(s, i):
    open_ch = s[i]; close = {"(": ")", "{": "}", "[": "]"}[open_ch]
    depth = 0; q = None
    for j in range(i, len(s)):
        ch = s[j]
        if q:
            if ch == "\\": continue
            if ch == q: q = None; continue
            continue
        if ch in "\"'`": q = ch; continue
        if ch == open_ch: depth += 1
        elif ch == close:
            depth -= 1
            if depth == 0: return j
    return len(s) - 1

def file_consts(src):
    consts = {}
    for m in re.finditer(r"const\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*((?:[\"'`](?:[^\"'`\\]|\\.)*[\"'`]\s*\+?\s*)+)", src):
        consts[m.group(1)] = "".join(re.findall(r"[\"'`]((?:[^\"'`\\]|\\.)*)[\"'`]", m.group(2)))
    for m in re.finditer(r"const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\[([^\]]*)\]\s*\.join\(", src):
        consts[m.group(1)] = ",".join(re.findall(r"[\"'`]([^\"'`]*)[\"'`]", m.group(2)))
    return consts

FILTERS = "eq neq gt gte lt lte in is like ilike contains containedBy order not overlaps textSearch".split()

for d, _, fs in os.walk(ROOT):
    if "node_modules" in d: continue
    for f in fs:
        if not f.endswith((".ts", ".tsx")): continue
        src = open(os.path.join(d, f), encoding="utf-8").read()
        consts = file_consts(src)
        for m in re.finditer(r"\.from\(\s*[\"'`]([a-z_0-9]+)[\"'`]\s*\)", src):
            t = m.group(1)
            if t not in TABLES: continue
            end = chain_end(src, m.end())
            chain = src[m.end():end]
            for sm in re.finditer(r"\.select\(\s*", chain):
                k = sm.end()
                if k < len(chain) and chain[k] in "\"'`":
                    q = chain[k]; e = chain.find(q, k + 1)
                    while e > 0 and chain[e - 1] == "\\": e = chain.find(q, e + 1)
                    parse_select(t, chain[k + 1:e], consts)
                else:
                    vm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", chain[k:])
                    if vm and vm.group(1) in consts: parse_select(t, consts[vm.group(1)], consts)
            for fm in re.finditer(r"\.(" + "|".join(FILTERS) + r")\(\s*[\"'`]([a-z_][a-z0-9_.]*)[\"'`]\s*(?:,\s*([^,)]{0,60}))?", chain):
                col = fm.group(2).split(".")[0]
                if "." in fm.group(2):  # foreign table filter
                    continue
                v = (fm.group(3) or "").strip()
                add(t, col, "filter", v if re.fullmatch(r"[\"'`][^\"'`]*[\"'`]|-?\d+(\.\d+)?|true|false|null", v) else None)
            for om in re.finditer(r"onConflict\s*:\s*[\"'`]([^\"'`]+)[\"'`]", chain):
                for c in om.group(1).split(","): add(t, c.strip(), "conflict")
            for wm in re.finditer(r"\.(insert|update|upsert)\(\s*", chain):
                k = wm.end()
                if k >= len(chain): continue
                body = None
                if chain[k] == "{":
                    body = chain[k:matching(chain, k) + 1]
                elif chain[k] == "[":
                    inner = chain[k:matching(chain, k) + 1]
                    om2 = inner.find("{")
                    if om2 >= 0: body = inner[om2:matching(inner, om2) + 1]
                else:
                    vm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", chain[k:])
                    if vm:
                        name = vm.group(1)
                        dm = re.search(r"(?:const|let)\s+" + name + r"\s*(?::[^=]{0,200})?=\s*", src)
                        if dm:
                            p = dm.end()
                            if src[p] == "{": body = src[p:matching(src, p) + 1]
                            elif src[p] == "[":
                                inner = src[p:matching(src, p) + 1]; o = inner.find("{")
                                if o >= 0: body = inner[o:matching(inner, o) + 1]
                            else:
                                # rows.map((x) => ({ ... }))
                                mm = re.match(r"[^;]{0,200}?=>\s*\(\s*\{", src[p:])
                                if mm:
                                    o = p + mm.end() - 1; body = src[o:matching(src, o) + 1]
                if body:
                    for key in obj_keys(body):
                        if re.fullmatch(r"[a-z_][a-z0-9_]*", key) and "_" in key or key in ("status", "notes", "amount", "name", "label", "role", "email", "phone", "value", "key", "kind", "reason", "remarks", "source", "section", "mode", "stage", "state", "title", "body", "payload", "summary", "details", "metadata", "description", "category", "priority", "position", "result", "message", "active", "enabled", "locked", "id"):
                            add(t, key, wm.group(1))

res = {t: {c: {"kinds": sorted(v["kinds"]), "values": sorted(v["values"])[:6]} for c, v in sorted(cs.items())} for t, cs in sorted(cols.items())}
res["_joins"] = sorted(joins)
json.dump(res, open(OUT, "w"), indent=1)
print({t: len(c) for t, c in res.items() if t != "_joins"})
