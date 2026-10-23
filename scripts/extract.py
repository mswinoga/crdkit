#!/usr/bin/env python3
"""Extract a Helm library chart's template call graph and state effects.

Usage:
  extract.py graph <chart dir> <out.js>
      Writes `window.CALL_GRAPH.libraries[<chart name>] = {...}` so
      several libraries' files can be loaded side by side by the viewers
      (script tags work on file://, fetch does not). Prints a define and
      edge summary to stderr.
  extract.py -h | --help
      This text.

Graph content:

Edge kinds:
- call:     include/template "name"
- dispatch: include (printf "pattern" ...) resolved against known defines
- ref:      a define name passed as a string literal (callback wiring);
            `within` names the call whose arguments carry it, `key` the
            dict key holding it
- dynamic:  include $var (target unknown; recorded on the caller only)

Per call edge, `args` lists the ctx state slots handed to the callee.

Per define:
- returns:  yaml | text | nothing (from the doc comment's `Returns` line;
            "nothing" and `""` mark a mutating define)
- declared: ctx slots the `Returns` text names
- writes:   ctx slots the body `set`s/`unset`s
- mutatesArgs: keys of its own argument the body mutates ("*" whole,
            "0" first list item, else a dict key)

- reads:    ctx slots the body reads
- feeds:    {from, to, via}: the result of `include from` (held in `via`)
            is passed into `include to`, both called by this define
- dynamic:  `include $var` targets of the body

Per call edge, `argsBy` maps the callee's argument keys to the ctx slots
passed in them (same keys as mutatesArgs).

A slot is `ctx.<key>` or `ctx.<key>.<sub>`; `.ctx` and `$ctx` are the
roots, followed through simple aliases. A variable bound from the
define's own argument (`$diag := index . 0`) is that argument, not a ctx
alias.
"""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFINE = re.compile(r'\{\{-?\s*define\s+"([^"]+)"\s*-?\}\}')
COMMENT = re.compile(r'\{\{-?\s*/\*.*?\*/\s*-?\}\}', re.S)
ACTION = re.compile(r'\{\{-?(.*?)-?\}\}', re.S)
CALL = re.compile(r'\b(include|template)\s+"([^"]+)"')
DISPATCH = re.compile(r'\binclude\s+\(\s*printf\s+"([^"]+)"')
DYNAMIC = re.compile(r'\binclude\s+(\$[A-Za-z0-9_.]+)')
LITERAL = re.compile(r'"([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"')
HEADER = re.compile(r'^\s*(\S+)\s+\(([^)]+)\)\s*$')

EXPR = r'(?:\$[A-Za-z_]\w*|\.ctx|\.diag)(?:\.[A-Za-z_]\w*)*'
EXPR_RE = re.compile(r'(?<![\w.])' + EXPR)
ASSIGN = re.compile(r'^\s*(\$[A-Za-z_]\w*)\s*:?=\s*(.*)$', re.S)
GET = re.compile(r'^\(?\s*(?:get|index)\s+(' + EXPR + r')\s+(?:"([^"]+)"|\S+)')
DIG = re.compile(r'\bdig((?:\s+"[^"]+")+)\s+(?:\([^()]*\)|"[^"]*"|\S+)\s+(' + EXPR + ')')
# Mutating sprig calls; the first argument (optionally via index/get) is the target.
SET = re.compile(r'\b(?:set|unset|merge|mergeOverwrite|mustMerge|mustMergeOverwrite)\s+\(?\s*(?:(?:index|get)\s+)?('
                 + EXPR + r')(?:\s+"([^"]+)")?')
CTX_DOC = re.compile(r'\bctx\.[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?')


def chart_meta(chart):
    meta = {}
    for line in (chart / "Chart.yaml").read_text().splitlines():
        m = re.match(r'^(name|version):\s*"?([^"\s]+)"?', line)
        if m:
            meta[m.group(1)] = m.group(2)
    return meta


def blank(text, span):
    """Replace a span with spaces, keeping newlines so offsets and line numbers hold."""
    s, e = span
    return text[:s] + re.sub(r'[^\n]', ' ', text[s:e]) + text[e:]


def returns_of(doc):
    m = re.search(r'^- Returns( YAML)?:\s*(.*?)(?=\n\S|\n- |\Z)', doc, re.S | re.M)
    if not m:
        return None, []
    if m.group(1):
        return "yaml", []
    text = " ".join(m.group(2).split())
    kind = "nothing" if re.match(r'(nothing|""|`""`)', text) else "text"
    declared = sorted({slot(s.split(".")) for s in CTX_DOC.findall(text)}) if kind == "nothing" else []
    return kind, declared


def parse_file(path, rel):
    raw = path.read_text()
    code = raw
    comments = list(COMMENT.finditer(raw))
    for c in comments:
        code = blank(code, c.span())
    line_of = lambda off: raw.count("\n", 0, off) + 1

    defines = []
    starts = list(DEFINE.finditer(code))
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(code)
        # Doc comment = the comment closing right before this define.
        doc = next((c.group(0) for c in reversed(comments)
                    if c.end() <= m.start() and not code[c.end():m.start()].strip()), "")
        doc = re.sub(r'^\{\{-?\s*/\*\s*\n?|\s*\*/\s*-?\}\}$', "", doc)
        lines = doc.splitlines()
        hm = HEADER.match(lines[0]) if lines else None
        scope = hm.group(2) if hm and hm.group(1) == m.group(1) else ""
        body = "\n".join(lines[1:] if hm else lines).strip()
        summary = re.split(r'\n\s*\n', body)[0].replace("\n", " ") if body else ""
        returns, declared = returns_of(body)
        defines.append({
            "name": m.group(1), "file": rel, "line": line_of(m.start()),
            "scope": scope, "summary": summary, "doc": body,
            "returns": returns, "declared": declared,
            "_span": (m.end(), end),
        })
    return code, defines, line_of


def dispatch_targets(pattern, names):
    rx = re.compile("^" + re.escape(pattern).replace(re.escape("%s"), "(.+)").replace(re.escape("%v"), "(.+)") + "$")
    hits = sorted(n for n in names if rx.match(n))
    # A trailing placeholder also matches a candidate's own sub-defines
    # (`<t>` vs `<t>.schema`): keep only the shortest name per prefix.
    return [n for n in hits if not any(n != h and n.startswith(h + ".") for h in hits)]


def slot(parts):
    """ctx path parts -> `ctx`, `ctx.<key>` or `ctx.<key>.<sub>` (diag collapsed to one slot)."""
    parts = [p for p in parts if p]
    if len(parts) > 1 and parts[1] in ("diag", "model", "tokens"):
        return "ctx." + parts[1]
    return ".".join(parts[:3])


class Scope:
    """Per-define aliases: variable -> ctx path parts, and variable -> producing includes."""

    def __init__(self):
        self.alias = {"$ctx": ["ctx"], "$diag": ["ctx", "diag"]}
        self.producer = {}
        self.params = {}  # variable -> key of the define's own argument it holds ("*", "0", "<dict key>")

    def path(self, expr):
        head, *rest = expr.lstrip(".").split(".") if expr.startswith(".") else expr.split(".")
        if expr.startswith("."):
            base = {"ctx": ["ctx"], "diag": ["ctx", "diag"]}.get(head)
        else:
            base = self.alias.get(head)
        return None if base is None else base + rest

    def assign(self, var, rhs, includes):
        rhs = rhs.strip()
        if rhs == "." and var == "$ctx":
            self.alias[var] = ["ctx"]
            return
        key = self.param_key(rhs)
        if key is not None:
            self.params[var] = key
            if not EXPR_RE.search(rhs):
                # Bound from the define's own argument, not from a ctx slot.
                self.alias.pop(var, None)
        else:
            self.params.pop(var, None)
        m = re.fullmatch(EXPR, rhs.split("|")[0].strip())
        g = GET.match(rhs)
        d = DIG.search(rhs) if rhs.startswith("dig") else None
        if m and self.path(m.group(0)):
            self.alias[var] = self.path(m.group(0))
        elif g and self.path(g.group(1)):
            self.alias[var] = self.path(g.group(1)) + [g.group(2) or "*"]
        elif d and self.path(d.group(2)):
            self.alias[var] = self.path(d.group(2)) + re.findall(r'"([^"]+)"', d.group(1))
        elif includes:
            self.producer[var] = includes[:1]
        else:
            # `$input = $fields.input`: inherit the producer of the source variable.
            src = [self.producer[v] for v in re.findall(r'\$[A-Za-z_]\w*', rhs) if v in self.producer]
            if src:
                self.producer[var] = src[0]
            elif var != "$diag":  # `$diag` is the diagnostics accumulator wherever it is built
                self.alias.pop(var, None)
                self.producer.pop(var, None)

    def param_key(self, expr):
        """Which part of the define's argument an expression reaches: `.out` -> out, `index . 0` -> 0."""
        m = re.match(r'\(?\s*(?:(index|get|first|last)\s+)?(\.(?:[A-Za-z_]\w*)?|\$[A-Za-z_]\w*)(?:\s+(\w+|"[^"]*"))?', expr.strip())
        if not m:
            return None
        fn, src, sub = m.groups()
        base = ("*" if src == "." else src[1:]) if src.startswith(".") else self.params.get(src)
        if base is None:
            return None
        if base == "*" and fn == "first":
            return "0"
        if base == "*" and fn in ("index", "get") and sub:
            return sub.strip('"')
        return base

    def slots(self, text):
        out = set()
        for m in DIG.finditer(text):
            p = self.path(m.group(2))
            if p:
                out.add(slot(p + re.findall(r'"([^"]+)"', m.group(1))))
        for m in EXPR_RE.finditer(text):
            p = self.path(m.group(0))
            if p:
                out.add(slot(p))
        return out


def items(text):
    """Top-level space-separated items of a template expression (groups and strings kept whole)."""
    out, cur, depth, quoted = [], "", 0, False
    for i, ch in enumerate(text):
        if ch == '"' and (i == 0 or text[i - 1] != "\\"):
            quoted = not quoted
        elif not quoted and ch == "(":
            depth += 1
        elif not quoted and ch == ")":
            depth -= 1
        if ch.isspace() and not quoted and depth == 0:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += ch
    return out + ([cur] if cur else [])


def args_by_key(args, sc):
    """`(dict "k" v ...)` -> {k: slots}; `(list a b)` -> {"0": ..., "1": ...}; otherwise {"*": slots}."""
    parts = items(args.strip())
    if len(parts) == 1 and parts[0].startswith("("):
        inner = items(parts[0][1:-1].strip())
        if inner and inner[0] == "dict":
            pairs = zip(inner[1::2], inner[2::2])
            return {k.strip('"'): sorted(sc.slots(v)) for k, v in pairs if sc.slots(v)}
        if inner[:1] == ["concat"] and len(inner) > 1 and inner[1].startswith("(list"):
            inner = items(inner[1][1:-1].strip())  # positions of the leading list hold
        if inner and inner[0] == "list":
            return {str(i): sorted(sc.slots(v)) for i, v in enumerate(inner[1:]) if sc.slots(v)}
    found = sc.slots(args)
    return {"*": sorted(found)} if found else {}


def args_end(text, i):
    """End of an include's arguments starting at i: the enclosing group's `)`, a top-level `|`, or the action end."""
    depth, quoted = 0, False
    while i < len(text):
        ch = text[i]
        if ch == '"' and text[i - 1] != "\\":
            quoted = not quoted
        elif not quoted:
            if ch == "(":
                depth += 1
            elif ch == ")":
                if depth == 0:
                    return i
                depth -= 1
            elif ch == "|" and depth == 0:
                return i
        i += 1
    return i


def analyze(d, body, base, line_of, names):
    """Walk one define's actions in order: calls with their args, refs, writes, reads, feeds."""
    sc = Scope()
    calls, writes, reads, feeds = [], set(), set(), []
    mutated = set()
    for a in ACTION.finditer(body):
        text = a.group(1)
        line = line_of(base + a.start())
        sites = [(m.start(), m.end(), [m.group(2)], "call") for m in CALL.finditer(text)]
        # A dispatch's args start after its `(printf ...)` group.
        sites += [(m.start(), args_end(text, m.end()) + 1, dispatch_targets(m.group(1), names), "dispatch", m.group(1))
                  for m in DISPATCH.finditer(text)]
        sites.sort()
        for site in sites:
            start, end, targets, kind = site[:4]
            args = text[end:args_end(text, end)]
            arg_slots = sc.slots(args)
            args_by = args_by_key(args, sc)
            for t in targets:
                c = {"from": d["name"], "to": t, "kind": kind, "line": line, "args": arg_slots, "argsBy": args_by}
                if kind == "dispatch":
                    c["pattern"] = site[4]
                calls.append(c)
                for v in sorted(set(re.findall(r'\$[A-Za-z_]\w*', args))):
                    for p in sc.producer.get(v, []):
                        if p != t:
                            feeds.append({"from": p, "to": t, "via": v})
        call_names = {m.start(2) for m in CALL.finditer(text)}
        for m in LITERAL.finditer(text):
            if m.start() + 1 in call_names or m.group(1) not in names or m.group(1) == d["name"]:
                continue
            within = next((s[2][0] for s in sites if s[0] < m.start() and s[2]), None)
            # The dict key that carries the name: `"chain" (list "a" "b")`, `"parentTargetTemplate" "a"`.
            key = re.search(r'"(\w+)"\s*(?:\(\s*list\s+(?:"[^"]*"\s*)*)?$', text[:m.start()])
            calls.append({"from": d["name"], "to": m.group(1), "kind": "ref", "line": line, "args": set(),
                          **({"within": within} if within else {}), **({"key": key.group(1)} if key else {})})
        for m in SET.finditer(text):
            p = sc.path(m.group(1))
            if p:
                writes.add(slot(p + ([m.group(2)] if m.group(2) else [])))
            else:
                k = sc.param_key(m.group(1))
                if k is not None:
                    mutated.add(k)
        am = ASSIGN.match(text)
        rhs_text = am.group(2) if am else text
        reads |= sc.slots(re.sub(SET, lambda m: m.group(0).replace(m.group(1), ""), rhs_text))
        if am:
            sc.assign(am.group(1), am.group(2), [n for s in sites for n in s[2]])
    reads.discard("ctx")
    d["writes"] = sorted(writes)
    d["mutatesArgs"] = sorted(mutated)
    d["reads"] = sorted(reads - writes)
    d["feeds"] = sorted((dict(t) for t in {tuple(sorted(f.items())) for f in feeds}),
                         key=lambda f: json.dumps(f, sort_keys=True))
    d["dynamic"] = sorted({m.group(1) for m in DYNAMIC.finditer(body)})
    return calls


def chart_templates(chart):
    """(chart metadata, [(file, code, defines, line_of)] for every template, in path order)."""
    tdir = chart / "templates"
    return chart_meta(chart), [(p,) + parse_file(p, str(p.relative_to(tdir))) for p in sorted(tdir.rglob("*.tpl"))]


def graph(argv):
    if len(argv) != 2:
        return usage("graph takes <chart dir> <out.js>")
    chart_dir, out = argv
    chart = Path(chart_dir)
    meta, parsed = chart_templates(chart)
    defines = [d for _, _, ds, _ in parsed for d in ds]
    names = {d["name"] for d in defines}

    calls = []
    for _, code, ds, line_of in parsed:
        for d in ds:
            s, e = d.pop("_span")
            calls += analyze(d, code[s:e], s, line_of, names)

    # One edge per (from, to, kind); keep every call-site line and union the args.
    merged = {}
    for c in calls:
        key = (c["from"], c["to"], c["kind"])
        if key in merged:
            merged[key]["lines"].append(c["line"])
            merged[key]["args"] |= c["args"]
            for k, v in c["argsBy"].items():
                merged[key]["argsBy"][k] = sorted(set(merged[key]["argsBy"].get(k, [])) | set(v))
        else:
            merged[key] = {**{k: v for k, v in c.items() if k != "line"}, "lines": [c["line"]]}
    for c in merged.values():
        c["args"] = sorted(c["args"])

    lib = {
        "name": meta.get("name"), "version": meta.get("version"),
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "defines": defines, "calls": list(merged.values()),
    }
    Path(out).write_text(
        "window.CALL_GRAPH = window.CALL_GRAPH || { libraries: {} };\n"
        f"window.CALL_GRAPH.libraries[{json.dumps(lib['name'])}] = "
        + json.dumps(lib, indent=1) + ";\n")
    kinds = {}
    for c in merged.values():
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    mut = sum(d["returns"] == "nothing" for d in defines)
    print(f"{lib['name']} {lib['version']}: {len(defines)} defines ({mut} mutating), "
          f"{len(merged)} edges {kinds}", file=sys.stderr)


def usage(reason):
    print(f"extract.py: {reason}", file=sys.stderr)
    print("usage: extract.py graph <chart dir> <out.js> | extract.py -h", file=sys.stderr)
    return 2


def main(argv):
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if not argv:
        return usage("no subcommand")
    cmd, rest = argv[0], argv[1:]
    if cmd == "graph":
        return graph(rest)
    return usage(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
