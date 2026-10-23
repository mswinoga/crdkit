#!/usr/bin/env python3
"""Extract a Helm library chart's template call graph and state effects.

Usage:
  extract.py graph <chart dir> <out.js>
      Writes `window.CALL_GRAPH.libraries[<chart name>] = {...}` so
      several libraries' files can be loaded side by side by the viewers
      (script tags work on file://, fetch does not). Prints a define and
      edge summary to stderr.
  extract.py lint [--pending <file>] [--scopes <list>] [--internal-suffix]
                  [--peer <templates dir>]... [--doc-rules] [--md <file>]...
                  [--requirements <file>] [--tests <dir>] [--readme <file>]
                  <templates dir>
      The lint rules on one templates dir (the chart dir is its parent):
      define-naming, output-writes-ctx, mutator-undeclared-write,
      dead-define, doc-unknown-define (doc comments and every --md
      file), doc-names-caller; with --doc-rules doc-param-mismatch (a
      `Params (dict)` key list ≠ the keys the body reads) and doc-shape
      (a purpose over 2 lines; no `Interface:` outside a callback);
      requirement-ids (with --requirements and --tests: an R-/C- id
      cited in --tests files, --md files or doc comments that the
      catalogue lacks; a core/contract entry no --tests file cites);
      dead-reference (--md files and template comments: a repo path in a
      backtick span or link that does not exist, a link anchor no
      heading has, `See [crdkit ]CONTRIBUTING "<heading>"` naming no
      heading); readme-unmarked-block (with --readme: a fenced block
      outside example markers without `<!-- sketch -->` on the line
      before). Output `FAIL|PENDING (<reason>) <rule> <file>:<line>:
      <text>`, `FIXED? (<reason>) <rule> <file>`, then one summary line;
      exit 0 clean, 1 on a failure, 2 on a usage error.
  extract.py reference [--peer <templates dir>]... <chart dir> <out.md>
      The generated per-define reference (spec §9): index, ctx slots
      with writers and readers, one section per define.
  extract.py diagnostics [--peer <templates dir>]... <chart dir> <out.md>
      The generated diagnostics list: one row per crdkit.diag.error|
      warning|info call (also `include $var` with `$var` assigned a diag
      define): level, message template, define. The diag defines come
      from the chart itself or a --peer (crdkit's templates for a
      library).
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
    declared = sorted({slot(s.split(".")) for s in CTX_DOC.findall(text)})
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
        doc_span = next((c for c in reversed(comments)
                         if c.end() <= m.start() and not code[c.end():m.start()].strip()), None)
        doc = re.sub(r'^\{\{-?\s*/\*\s*\n?|\s*\*/\s*-?\}\}$', "", doc_span.group(0) if doc_span else "")
        lines = doc.splitlines()
        lead = re.match(r'^\{\{-?\s*/\*\s*\n?', raw[doc_span.start():]) if doc_span else None
        doc_line = line_of(doc_span.start()) + (lead.group(0).count("\n") if lead else 0) if doc_span else line_of(m.start())
        hm = HEADER.match(lines[0]) if lines else None
        scope = hm.group(2) if hm and hm.group(1) == m.group(1) else ""
        body = "\n".join(lines[1:] if hm else lines).strip()
        summary = re.split(r'\n\s*\n', body)[0].replace("\n", " ") if body else ""
        returns, declared = returns_of(body)
        defines.append({
            "name": m.group(1), "file": rel, "line": line_of(m.start()),
            "scope": scope, "summary": summary, "doc": body, "docLine": doc_line,
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
        self.local = set()  # aliases bound to a ctx the body builds itself
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
            self.local.discard(var)
            return
        key = self.param_key(rhs)
        if key is not None:
            self.params[var] = key
        else:
            self.params.pop(var, None)
        m = re.fullmatch(EXPR, rhs.split("|")[0].strip())
        g = GET.match(rhs)
        d = DIG.search(rhs) if rhs.startswith("dig") else None
        if m and self.path(m.group(0)):
            self.alias[var] = self.path(m.group(0))
            self.local.discard(var)
        elif g and self.path(g.group(1)):
            self.alias[var] = self.path(g.group(1)) + [g.group(2) or "*"]
            self.local.discard(var)
        elif d and self.path(d.group(2)):
            self.alias[var] = self.path(d.group(2)) + re.findall(r'"([^"]+)"', d.group(1))
            self.local.discard(var)
        elif includes:
            self.producer[var] = includes[:1]
            self.alias.pop(var, None)
            self.local.discard(var)
        else:
            # `$input = $fields.input`: inherit the producer of the source variable.
            src = [self.producer[v] for v in re.findall(r'\$[A-Za-z_]\w*', rhs) if v in self.producer]
            if src:
                self.producer[var] = src[0]
            else:
                self.producer.pop(var, None)
            if var == "$ctx" and key is None:
                # A ctx built in the body (`$ctx := dict …`) is no ctx slot.
                self.local.add(var)
            else:
                self.alias.pop(var, None)
                self.local.discard(var)

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
    mutated, local_writes = set(), set()
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
                if m.group(1) in sc.local:
                    local_writes.add(slot(p + ([m.group(2)] if m.group(2) else [])))
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
    d["localWrites"] = sorted(local_writes)
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


def analyze_chart(parsed):
    """(defines, call edges) of parsed template files (see chart_templates)."""
    defines = [d for _, _, ds, _ in parsed for d in ds]
    names = {d["name"] for d in defines}
    calls = []
    for _, code, ds, line_of in parsed:
        for d in ds:
            s, e = d.pop("_span")
            calls += analyze(d, code[s:e], s, line_of, names)
    return defines, calls


def graph(argv):
    if len(argv) != 2:
        return usage("graph takes <chart dir> <out.js>")
    chart_dir, out = argv
    chart = Path(chart_dir)
    meta, parsed = chart_templates(chart)
    defines, calls = analyze_chart(parsed)

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


LINT_RULES = ("define-naming", "output-writes-ctx", "mutator-undeclared-write",
              "dead-define", "doc-unknown-define", "doc-names-caller", "doc-param-mismatch",
              "doc-shape", "requirement-ids", "dead-reference", "readme-unmarked-block")

STRING = re.compile(r'"(?:[^"\\]|\\.)*"|`[^`]*`')
KEY_READ = re.compile(r'\b(?:index|hasKey|get)\s+(\.|\$[A-Za-z_]\w*)\s+"(\w+)"')
DOT_READ = re.compile(r'(?<![\w$)\]])\.([A-Za-z_]\w*)')
ROOT_READ = re.compile(r'\$\.([A-Za-z_]\w*)')
WHOLE_DOT = re.compile(r'(?<![\w$)\].])\.(?![\w.])|\$(?![\w.])')
KEYWORD = re.compile(r'^\s*(range|with|if|else|end|block)\b\s*(.*)$', re.S)


def documented_params(doc):
    """Quoted top-level keys of a `Params (dict): { "k": …, … }` line, or None for another params shape."""
    m = re.search(r'^- Params \(dict\):\s*\{', doc, re.M)
    if not m:
        return None
    depth, keys, i = 1, set(), m.end()
    while i < len(doc) and depth:
        ch = doc[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == '"' and depth == 1:
            k = re.match(r'"([A-Za-z_]\w*)"\s*:', doc[i:])
            if k:
                keys.add(k.group(1))
                i += k.end() - 1
        i += 1
    return keys


def param_reads(body):
    """Keys of the define's own dict argument the body reads, or None when `.` is passed on whole."""
    reads, aliases, dot = set(), set(), [True]
    stack = []
    for a in ACTION.finditer(body):
        text = a.group(1)
        km = KEYWORD.match(text)
        word, expr = (km.group(1), km.group(2)) if km else ("", text)
        if word == "end":
            if stack:
                dot[0] = stack.pop()[1]
            continue
        rebind = word in ("range", "with")
        if word == "else" and stack:
            # The else branch of range/with runs with the outer dot; `else with X` rebinds it again.
            dot[0] = stack[-1][1] if stack[-1][0] in ("range", "with") else dot[0]
            sub = KEYWORD.match(expr)
            if sub and sub.group(1) in ("with", "if"):
                expr = sub.group(2)
                if sub.group(1) == "with":
                    stack[-1], rebind = ("with", dot[0]), True
        outer = dot[0]
        for m in KEY_READ.finditer(expr):
            if (m.group(1) == "." and outer) or m.group(1) in aliases:
                reads.add(m.group(2))
        bare = STRING.sub('""', KEY_READ.sub("", expr))
        reads |= set(ROOT_READ.findall(bare))
        if outer:
            reads |= set(DOT_READ.findall(bare))
            am = ASSIGN.match(bare)
            if am and am.group(2).strip() == ".":
                aliases.add(am.group(1))
                bare = bare[:am.start(2)]
            if WHOLE_DOT.search(bare):
                return None
        for v in aliases:
            reads |= set(re.findall(re.escape(v) + r'\.([A-Za-z_]\w*)', bare))
            if re.search(re.escape(v) + r'(?![\w.])', bare) and not re.match(r'\s*' + re.escape(v) + r'\s*:?=', bare):
                return None
        if word in ("range", "with", "if", "block"):
            stack.append((word, outer))
        if rebind:
            dot[0] = False
    return reads


def doc_shape(d):
    """doc-shape problems of one define's doc comment (purpose length, missing Interface)."""
    lines = d["doc"].splitlines()
    cut = next((i for i, l in enumerate(lines) if re.match(r'^(Interface|Implementation notes):\s*$', l)), len(lines))
    purpose = [l for l in lines[:cut] if l.strip()]
    out = []
    if len(purpose) > 2:
        out.append(f"{d['name']} has a {len(purpose)}-line purpose (at most 2)")
    if d["scope"] != "callback" and not any(re.match(r'^Interface:\s*$', l) for l in lines):
        out.append(f"{d['name']} has no 'Interface:'")
    return out


def slug(heading):
    """GitHub anchor of a heading text."""
    text = re.sub(r'[^\w\- ]', "", heading.strip().lower())
    return text.replace(" ", "-")


def md_headings(text):
    """(heading texts, anchors) of a Markdown file; fenced blocks skipped, `<a id|name>` anchors included."""
    texts, anchors, seen, fence = set(), set(), {}, None
    for line in text.splitlines():
        f = re.match(r'^\s*(```|~~~)', line)
        if f:
            fence = None if fence == f.group(1) else (fence or f.group(1))
            continue
        if fence:
            continue
        h = re.match(r'^#{1,6}\s+(.*?)\s*#*\s*$', line)
        if h:
            texts.add(h.group(1))
            s = slug(h.group(1))
            n = seen.get(s, 0)
            anchors.add(s if n == 0 else f"{s}-{n}")
            seen[s] = n + 1
        anchors |= set(re.findall(r'<a\s+(?:id|name)="([^"]+)"', line))
    return texts, anchors


LINE_SUFFIX = re.compile(r':\d+(?:-\d+)?(?:,\s*\d+(?:-\d+)?)*$')


def reference_hits(text, src, root, peers, md_cache):
    """dead-reference hits of one text (a Markdown file or a template comment): [(line index, message)]."""
    hits = []
    top = {p.name for p in root.iterdir() if not p.name.startswith(".")}
    peer_roots = {f"../{p.name}": p for p in peers}

    def headings(path):
        if path not in md_cache:
            md_cache[path] = md_headings(path.read_text()) if path.is_file() else (set(), set())
        return md_cache[path]

    def check_path(ref, base, i, link):
        ref = LINE_SUFFIX.sub("", ref)
        path, _, anchor = ref.partition("#")
        if any(c in path for c in "<*{ ") or re.match(r'^\w+:', path):
            return
        if not path:
            if link and anchor and anchor not in headings(src)[1]:
                hits.append((i, f"'#{anchor}' names no heading of {src.name}"))
            return
        target = None
        first = path.split("/")[0]
        if link:
            resolved = (base / path).resolve()
            for prefix, proot in peer_roots.items():
                if path.startswith(prefix + "/") or path == prefix:
                    target = resolved
            try:
                rel = resolved.relative_to(root.resolve())
                if rel.parts and rel.parts[0] in top:
                    target = resolved
            except ValueError:
                pass
        elif first in top:
            target = root / path
        elif any(path == p or path.startswith(p + "/") for p in peer_roots):
            target = root / path
        if target is None:
            return
        if not target.exists():
            hits.append((i, f"'{path}' does not exist"))
        elif link and anchor and target.suffix == ".md" and anchor not in headings(target)[1]:
            hits.append((i, f"'{path}#{anchor}' names no heading"))

    fence = None
    for i, line in enumerate(text.splitlines()):
        f = re.match(r'^\s*(```|~~~)', line)
        if f:
            fence = None if fence == f.group(1) else (fence or f.group(1))
            continue
        if fence:
            continue
        for m in re.finditer(r'\[[^\]]*\]\(([^)\s]+)\)', line):
            check_path(m.group(1), src.parent, i, True)
        for m in re.finditer(r'`([^`]+)`', re.sub(r'\[[^\]]*\]\([^)]*\)', "", line)):
            check_path(m.group(1), src.parent, i, False)
        for m in re.finditer(r'See (crdkit )?CONTRIBUTING "([^"]+)"', line):
            contributing = (peer_roots.get("../crdkit") if m.group(1) else root)
            if contributing is None:
                hits.append((i, f"'crdkit CONTRIBUTING' needs --peer ../crdkit/templates"))
            elif m.group(2) not in headings(contributing / "CONTRIBUTING.md")[0]:
                hits.append((i, f"CONTRIBUTING has no heading '{m.group(2)}'"))
    return hits


def unmarked_blocks(text):
    """Line indexes of fenced blocks outside example markers without `<!-- sketch -->` on the line before."""
    out, lines, fence, inside = [], text.splitlines(), None, False
    for i, line in enumerate(lines):
        if re.match(r'^\s*<!--\s*example:', line):
            inside = True
        elif re.match(r'^\s*<!--\s*/example\s*-->', line):
            inside = False
        f = re.match(r'^\s*(```|~~~)', line)
        if not f:
            continue
        if fence:
            fence = None if f.group(1) == fence else fence
            continue
        fence = f.group(1)
        if not inside and not (i and lines[i - 1].strip() == "<!-- sketch -->"):
            out.append(i)
    return out


REQ_ID = re.compile(r'(?<![\w-])(C-\d+|R-[A-Z]+-\d+)(?![\w-])')
REQ_ENTRY = re.compile(r'^\s*-\s+\*\*(C-\d+|R-[A-Z]+-\d+)\*\*\s+·\s+(\w+)')


def text_files(top):
    """Readable text files under a dir (packaged charts and snapshots skipped)."""
    for p in sorted(Path(top).rglob("*")):
        if p.is_file() and not ({"charts", "__snapshot__"} & set(p.parts)):
            try:
                yield p, p.read_text()
            except UnicodeDecodeError:
                continue


def read_pending(path):
    """({(rule, file): reason}, [keys in file order]) from a lint.pending file."""
    pending, order = {}, []
    if not path:
        return pending, order
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        key = (parts[0], parts[1])
        pending[key] = parts[2] if len(parts) > 2 else ""
        order.append(key)
    return pending, order


def name_mentions(doc, prefixes):
    """`<prefix>.<name>` mentions in a doc comment: [(name, 0-based line index)].

    A trailing dot (family form `x.<t>`, `x.*`, a cut-off `x.…`) is dropped;
    a following `|` list (`x.a|b`) leaves only the first name checked.
    """
    rx = re.compile(r'(?<![\w.])(?:' + "|".join(re.escape(p) for p in prefixes) + r')\.[A-Za-z0-9_.]*')
    return [(m.group(0).rstrip("."), i) for i, line in enumerate(doc.splitlines()) for m in rx.finditer(line)]


def known_name(name, names):
    """A define, or a family prefix (a family form needs a define starting `name.`)."""
    return name in names or any(n.startswith(name + ".") for n in names)


def lint_options(argv):
    """(options, error): `lint` flags and the one templates dir."""
    opts = {"pending": "", "scopes": [], "internal_suffix": False, "doc_rules": False, "peers": [], "md": [],
            "requirements": "", "tests": "", "readme": "", "dir": "", "help": False}
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("-h", "--help"):
            opts["help"] = True
        elif a in ("--pending", "--scopes", "--peer", "--md", "--requirements", "--tests", "--readme"):
            if not args:
                return opts, f"{a} needs a value"
            v = args.pop(0)
            if a == "--scopes":
                opts["scopes"] = [s for s in v.split(",") if s]
            elif a in ("--peer", "--md"):
                opts[a[2:] + ("s" if a == "--peer" else "")].append(v)
            else:
                opts[a[2:]] = v
        elif a == "--internal-suffix":
            opts["internal_suffix"] = True
        elif a == "--doc-rules":
            opts["doc_rules"] = True
        elif a.startswith("-"):
            return opts, f"unknown flag: {a}"
        elif not opts["dir"]:
            opts["dir"] = a.rstrip("/")
        else:
            return opts, "lint takes one <templates dir>"
    if bool(opts["requirements"]) != bool(opts["tests"]):
        return opts, "--requirements and --tests go together"
    return opts, "" if (opts["dir"] or opts["help"]) else "lint takes <templates dir>"


def lint(argv):
    """The extractor rules (spec §8.2): naming, state effects, dead defines, doc prose."""
    opts, error = lint_options(argv)
    if error:
        return usage(error)
    if opts["help"]:
        print(__doc__.strip())
        return 0

    root = Path(opts["dir"]).parent
    meta, parsed = chart_templates(root)
    bodies = {d["name"]: code[d["_span"][0]:d["_span"][1]] for _, code, ds, _ in parsed for d in ds}
    defines, edges = analyze_chart(parsed)
    prefix = meta.get("name") or root.name
    names = {d["name"] for d in defines}
    prefixes = [prefix]
    peer_roots = []
    for peer in opts["peers"]:
        peer_roots.append(Path(peer.rstrip("/")).parent)
        pmeta, pparsed = chart_templates(peer_roots[-1])
        pdefines, _ = analyze_chart(pparsed)
        names |= {d["name"] for d in pdefines}
        prefixes.append(pmeta.get("name") or Path(peer).parent.name)

    reachable = {c["to"] for c in edges if c["kind"] in ("call", "dispatch", "ref")}
    callers = {}
    for c in edges:
        if c["kind"] in ("call", "dispatch"):
            callers.setdefault(c["to"], set()).add(c["from"])

    hits = []

    def hit(rule, d, text, line=None):
        hits.append((rule, f"{opts['dir']}/{d['file']}", d["line"] if line is None else line, text))

    def hit_at(rule, file, line, text):
        hits.append((rule, str(file), line, text))

    for d in defines:
        name, scope = d["name"], d["scope"]
        if not name.startswith(prefix + "."):
            hit("define-naming", d, f"{name} has no chart prefix '{prefix}.'")
        if not scope:
            hit("define-naming", d, f"{name} has no doc header '{name} (<scope>)'")
        elif opts["scopes"] and scope not in opts["scopes"]:
            hit("define-naming", d, f"{name} has scope '{scope}', none of --scopes")
        stem = Path(d["file"]).name[:-len(".tpl")] if d["file"].endswith(".tpl") else Path(d["file"]).name
        parts = stem.split(".")
        if len(parts) > 1 and parts[-1] in opts["scopes"] and scope != parts[-1]:
            hit("define-naming", d, f"{name} has scope '{scope}' in '*.{parts[-1]}.tpl'")
        suffix = name.endswith(".internal")
        in_file = d["file"].endswith(".internal.tpl")
        if opts["internal_suffix"]:
            if suffix and scope != "internal":
                hit("define-naming", d, f"{name} ends '.internal' but its scope is '{scope}'")
            if scope == "internal" and not suffix:
                hit("define-naming", d, f"{name} has scope 'internal' but no '.internal' suffix")
            if suffix and not in_file:
                hit("define-naming", d, f"{name} ends '.internal' but is not in '*.internal.tpl'")
            if in_file and not suffix:
                hit("define-naming", d, f"{name} is in '*.internal.tpl' but does not end '.internal'")
        elif suffix:
            hit("define-naming", d, f"{name} ends '.internal'")

        if d["returns"] in ("text", "yaml"):
            for w in [w for w in d["writes"] if w not in d["localWrites"]]:
                if not any(w == s or w.startswith(s + ".") for s in d["declared"]):
                    hit("output-writes-ctx", d, f"{name} returns {d['returns']} and writes {w}")
                    break
        if d["returns"] == "nothing":
            for w in d["writes"]:
                if not any(w == s or w.startswith(s + ".") for s in d["declared"]):
                    hit("mutator-undeclared-write", d, f"{name} writes {w}, not named in its Returns")
                    break
        if scope != "public" and name not in reachable:
            hit("dead-define", d, f"{name} has no caller")
        for mention, i in name_mentions(d["doc"], prefixes):
            if not known_name(mention, names):
                hit("doc-unknown-define", d, f"{mention} is not a define", d["docLine"] + i)
            elif scope != "callback" and mention in callers.get(name, ()):
                hit("doc-names-caller", d, f"{mention} calls {name}", d["docLine"] + i)
        documented = documented_params(d["doc"]) if opts["doc_rules"] else None
        if documented is not None:
            read = param_reads(bodies[name])
            # A callback documents the caller's fixed shape: it may leave keys unread.
            unread = documented - read if read is not None and scope != "callback" else set()
            if read is not None and (unread or read - documented):
                gaps = [f"documented, never read: {', '.join(sorted(unread))}" if unread else "",
                        f"read, undocumented: {', '.join(sorted(read - documented))}" if read - documented else ""]
                hit("doc-param-mismatch", d, f"{name} params — " + "; ".join(g for g in gaps if g))
        if scope and opts["doc_rules"]:
            for problem in doc_shape(d):
                hit("doc-shape", d, problem)

    md_texts = {md: Path(md).read_text() for md in opts["md"] + ([opts["readme"]] if opts["readme"] else [])}
    for md in opts["md"]:
        for mention, i in name_mentions(md_texts[md], prefixes):
            if not known_name(mention, names):
                hit_at("doc-unknown-define", md, i + 1, f"{mention} is not a define")

    if opts["requirements"]:
        catalogue = Path(opts["requirements"])
        entries = {}
        for i, line in enumerate(catalogue.read_text().splitlines()):
            m = REQ_ENTRY.match(line)
            if m:
                entries[m.group(1)] = (m.group(2), i + 1)
        cited = set()

        def cite(file, text, base=1):
            for i, line in enumerate(text.splitlines()):
                for m in REQ_ID.finditer(line):
                    if m.group(1) not in entries:
                        hit_at("requirement-ids", file, base + i, f"{m.group(1)} is not in {catalogue}")
        for p, text in text_files(opts["tests"]):
            cited |= set(REQ_ID.findall(text))
            cite(p, text)
        for md in opts["md"]:
            if Path(md).resolve() != catalogue.resolve():
                cite(md, md_texts[md])
        for d in defines:
            cite(f"{opts['dir']}/{d['file']}", d["doc"], d["docLine"])
        for rid, (cls, line) in sorted(entries.items()):
            if cls in ("core", "contract") and rid not in cited:
                hit_at("requirement-ids", catalogue, line, f"{rid} ({cls}) is cited by no file under {opts['tests']}")

    md_cache = {}
    for md, text in md_texts.items():
        for i, msg in reference_hits(text, Path(md), root, peer_roots, md_cache):
            hit_at("dead-reference", md, i + 1, msg)
    for p, _, _, _ in parsed:
        raw = p.read_text()
        for c in COMMENT.finditer(raw):
            base = raw.count("\n", 0, c.start()) + 1
            for i, msg in reference_hits(c.group(0), p, root, peer_roots, md_cache):
                hit_at("dead-reference", f"{opts['dir']}/{p.relative_to(root / 'templates')}", base + i, msg)

    if opts["readme"]:
        for i in unmarked_blocks(md_texts[opts["readme"]]):
            hit_at("readme-unmarked-block", opts["readme"], i + 1,
                   "fenced block outside example markers, no '<!-- sketch -->' on the line before")

    pending, order = read_pending(opts["pending"])
    seen, hits_n, failed, pending_n = set(), 0, 0, 0
    for rule, file, line, text in sorted(hits, key=lambda h: (h[1], h[2], h[0])):
        if rule not in LINT_RULES:
            continue
        hits_n += 1
        key = (rule, file)
        if key in pending:
            seen.add(key)
            pending_n += 1
            print(f"PENDING ({pending[key]}) {rule} {file}:{line}: {text}")
        else:
            failed += 1
            print(f"FAIL {rule} {file}:{line}: {text}")
    for key in order:
        if key[0] in LINT_RULES and key not in seen:
            failed += 1
            print(f"FIXED? ({pending[key]}) {key[0]} {key[1]}")
    print(f"extract.py: {hits_n} hits, {failed} failed, {pending_n} pending")
    return 1 if failed else 0


REFERENCE_TITLE = "define reference"


def md_cell(text):
    """A Markdown table cell with `|` escaped."""
    return str(text).replace("|", "\\|")


def md_names(names, own):
    """Sorted comma-separated define names; own defines linked, peers plain."""
    out = []
    for n in sorted(names):
        if n in own:
            out.append(f"[{n}](#{n})")
        else:
            out.append(f"`{n}`")
    return ", ".join(out) if out else "—"


def md_code_list(values):
    return ", ".join(f"`{v}`" for v in sorted(values)) if values else "—"


def reference(argv):
    """The generated per-define reference (spec §9) of one chart."""
    peers, args = [], list(argv)
    while args and args[0].startswith("-"):
        flag = args.pop(0)
        if flag == "--peer":
            if not args:
                return usage("--peer needs a templates dir")
            peers.append(args.pop(0))
        elif flag in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            return usage(f"unknown flag: {flag}")
    if len(args) != 2:
        return usage("reference takes <chart dir> <out.md>")
    chart_dir, out = args
    chart = Path(chart_dir)
    meta, parsed = chart_templates(chart)
    defines, edges = analyze_chart(parsed)
    own = {d["name"] for d in defines}
    peer_names = set()
    for peer in peers:
        pdefines, _ = analyze_chart(chart_templates(Path(peer.rstrip("/")).parent)[1])
        peer_names |= {d["name"] for d in pdefines}

    called_by = {}
    calls = {}
    for c in edges:
        calls.setdefault(c["from"], set()).add(c["to"])
        called_by.setdefault(c["to"], set()).add(c["from"])

    slots = {}
    for d in defines:
        for w in d["writes"]:
            slots.setdefault(w, {"written": set(), "read": set()})["written"].add(d["name"])
        for r in d["reads"]:
            slots.setdefault(r, {"written": set(), "read": set()})["read"].add(d["name"])

    name = meta.get("name") or chart.name
    lines = [
        f"# {name} — {REFERENCE_TITLE}",
        "",
        "Generated by `crdkit/scripts/extract.py reference`; do not edit.",
        "",
        "## Index",
        "",
        "| Define | Scope | File |",
        "| --- | --- | --- |",
    ]
    for d in sorted(defines, key=lambda d: d["name"]):
        lines.append(f"| [{d['name']}](#{d['name']}) | {md_cell(d['scope'] or '—')} | `{d['file']}` |")
    lines += ["", "## Context slots", "", "| Slot | Written by | Read by |", "| --- | --- | --- |"]
    for slot in sorted(slots):
        row = slots[slot]
        lines.append(f"| `{slot}` | {md_names(row['written'], own)} | {md_names(row['read'], own)} |")
    lines += ["", "## Defines", ""]
    for d in sorted(defines, key=lambda d: d["name"]):
        n = d["name"]
        lines += [
            f'<a id="{n}"></a>',
            "",
            f"### {n}",
            "",
            f"- Scope: {d['scope'] or '—'}",
            f"- File: `{d['file']}`",
            f"- Called by: {md_names(called_by.get(n, set()), own)}",
            f"- Calls: {md_names(calls.get(n, set()), own)}",
            f"- Mutated arguments: {md_code_list(d['mutatesArgs'])}",
            f"- Writes ctx: {md_code_list(d['writes'])}",
            f"- Reads ctx: {md_code_list(d['reads'])}",
            "",
        ]
        if d["doc"].strip():
            lines += [d["doc"].strip(), ""]
    Path(out).write_text("\n".join(lines).rstrip("\n") + "\n")
    print(f"{out}: {len(defines)} defines, {len({(c['from'], c['to'], c['kind']) for c in edges})} edges", file=sys.stderr)
    return 0


DIAG_LEVELS = {"crdkit.diag.error": "ERROR", "crdkit.diag.warning": "WARNING", "crdkit.diag.info": "INFO"}
DIAG_CALL = re.compile(r'\binclude\s+(?:"(crdkit\.diag\.(?:error|warning|info))"|(\$[A-Za-z_]\w*))')
PRINTF_VERB = re.compile(r'%[-+# 0]*\d*(?:\.\d+)?[a-zA-Z%]')


def go_string(literal):
    """The text of a Go string literal (`"…"` with `\\"`, `\\\\`, `\\n` escapes)."""
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), literal[1:-1])


def placeholder(arg):
    """`$path` -> `<path>`, `.id` / `$x.id` -> `<id>`, anything else -> `<…>`."""
    m = re.fullmatch(r'(?:\$[A-Za-z_]\w*|)(?:\.([A-Za-z_]\w*))*', arg)
    if m and arg.startswith("$") and "." not in arg:
        return f"<{arg[1:]}>"
    if m and arg:
        return f"<{arg.rsplit('.', 1)[1]}>"
    return "<…>"


def message_template(arg):
    """A diag message argument -> its template text, or None when it is computed."""
    if re.fullmatch(r'"(?:[^"\\]|\\.)*"', arg):
        return go_string(arg)
    if not (arg.startswith("(") and arg.endswith(")")):
        return None
    parts = items(arg[1:-1].strip())
    if len(parts) < 2 or parts[0] != "printf" or not re.fullmatch(r'"(?:[^"\\]|\\.)*"', parts[1]):
        return None
    fmt, args = go_string(parts[1]), iter(parts[2:])
    return PRINTF_VERB.sub(lambda v: "%" if v.group(0) == "%%" else placeholder(next(args, "")), fmt)


def diag_level(var, body):
    """Level of `include $var`: from its assignment in the define body, None when it names no diag define."""
    assigns = [m.group(1) for m in re.finditer(re.escape(var) + r'\s*:?=\s*([^}]*)', body)]
    named = [n for a in assigns for n in re.findall(r'"(crdkit\.diag\.[A-Za-z]+)"', a)]
    if not named and not any("crdkit.diag." in a for a in assigns):
        return None
    readable = all(re.fullmatch(r'\s*(?:ternary\s+"[^"]+"\s+"[^"]+"\s+.*|"[^"]+")\s*-?', a, re.S) for a in assigns)
    if not readable or not named or any(n not in DIAG_LEVELS for n in named):
        return "(computed level)"
    return " / ".join(dict.fromkeys(DIAG_LEVELS[n] for n in named))


def diagnostic_rows(parsed):
    """(define, level, message) per diag call of parsed template files (see chart_templates)."""
    rows = []
    for _, code, ds, _ in parsed:
        for d in ds:
            s, e = d["_span"]
            body = code[s:e]
            for a in ACTION.finditer(body):
                text = a.group(1)
                for m in DIAG_CALL.finditer(text):
                    level = DIAG_LEVELS[m.group(1)] if m.group(1) else diag_level(m.group(2), body)
                    if level is None:
                        continue
                    args = items(text[m.end():args_end(text, m.end())].strip())
                    inner = items(args[0][1:-1].strip()) if args and args[0].startswith("(") else []
                    msg = message_template(inner[2]) if len(inner) == 3 and inner[0] == "list" else None
                    rows.append((d["name"], level, "(computed message)" if msg is None else msg))
    return rows


def diagnostics(argv):
    """The generated diagnostics list of one chart (one row per diag call)."""
    peers, args = [], list(argv)
    while args and args[0].startswith("-"):
        flag = args.pop(0)
        if flag == "--peer":
            if not args:
                return usage("--peer needs a templates dir")
            peers.append(args.pop(0))
        elif flag in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            return usage(f"unknown flag: {flag}")
    if len(args) != 2:
        return usage("diagnostics takes <chart dir> <out.md>")
    chart_dir, out = args
    chart = Path(chart_dir)
    meta, parsed = chart_templates(chart)
    names = {d["name"] for _, _, ds, _ in parsed for d in ds}
    for peer in peers:
        names |= {d["name"] for _, _, ds, _ in chart_templates(Path(peer.rstrip("/")).parent)[1] for d in ds}
    if not set(DIAG_LEVELS) <= names:
        return usage("no crdkit.diag.error|warning|info defines (pass --peer <crdkit templates dir>)")
    rows = sorted(diagnostic_rows(parsed), key=lambda r: (r[0], r[2], r[1]))
    name = meta.get("name") or chart.name
    lines = [
        f"# {name} — diagnostics",
        "",
        "Generated by `crdkit/scripts/extract.py diagnostics`; do not edit.",
        "",
        "One row per diagnostic call. `<x>` = the `printf` argument `$x` / `.x`;",
        "`<…>` = an expression.",
        "",
        "| Level | Message | Define |",
        "| --- | --- | --- |",
    ]
    for define, level, msg in rows:
        text = msg if msg.startswith("(computed") else f"`{' '.join(msg.split())}`"
        lines.append(f"| {level} | {md_cell(text)} | `{define}` |")
    Path(out).write_text("\n".join(lines) + "\n")
    print(f"{out}: {len(rows)} diagnostics", file=sys.stderr)
    return 0


def usage(reason):
    print(f"extract.py: {reason}", file=sys.stderr)
    print("usage: extract.py {graph <chart dir> <out.js> | lint [flags] <templates dir>"
          " | reference|diagnostics [--peer <templates dir>]... <chart dir> <out.md>} | extract.py -h",
          file=sys.stderr)
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
    if cmd == "lint":
        return lint(rest)
    if cmd == "reference":
        return reference(rest)
    if cmd == "diagnostics":
        return diagnostics(rest)
    return usage(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
