#!/usr/bin/env python3
"""Generate the README example blocks from docs/readme-examples/ inputs.

Usage:
  examples.py render <readme> --chart <test chart> --kind stub|consumer [--base <values>]
      Rewrites every example block of <readme> in place.
  examples.py check <readme> --chart <test chart> --kind stub|consumer [--base <values>]
      Renders in memory and compares block by block; a differing block prints
      `FAIL examples.py: <readme>:<line>: block <stem> differs — run make docs`.
  examples.py -h | --help
      This text.

Markers (each pair on its own lines, content between them generated):
  <!-- example: docs/readme-examples/<stem> [target=a,b] [show=p1,p2] [render=none] [lang=<l>] -->
  <!-- /example -->
  Paths are relative to the README's directory.

Generated blocks:
- input: `<stem>.yaml` verbatim, first line `# <stem>.yaml`;
- `--kind stub`: `<stem>.tpl` verbatim, then the snippet's result: one
  block per target (headed `# <target>` when `target=` is given; fence
  language `lang`, default yaml);
- `--kind consumer`: one block per target, per `show` path a line
  `# <target>: spec.<path>` and that path's YAML;
- `render=none`: the input only, unlabelled, `@CHART_VERSION@` replaced
  by the `version` of the README directory's Chart.yaml.

Rendering (`helm template <chart>`; the chart's dependencies must be
up to date):
- stub: `-s templates/cr.yaml -f <stem>.yaml --set-file ops[0].tpl=<stem>.tpl
  --set ops[0].at[0]=result [--set target=<t>]`; the result is the
  model's `result` key.
- consumer: `-s templates/example.yaml [-f <base>] -f <stem>.yaml
  --set-json example={"show": [...]} [--set deploymentConfig.target=<t>]`;
  the template prints, per show path, a line `# show: <path>` followed by
  the path's `toYaml`, and the render's diagnostic lines.
- A render failure or any `# ERROR:` / `# WARNING:` / `# INFO:` line
  fails the example.

Output: `FAIL examples.py: …` lines on stderr, then
`examples.py: <n> examples, <f> failed`. Exit 0 clean, 1 on a failure,
2 on a usage error. Needs `helm` and `python3` (run with `-I`).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

OPEN = re.compile(r'^<!-- example: (\S+)((?:\s+\w+=\S+)*)\s*-->$')
CLOSE = "<!-- /example -->"
DIAG = re.compile(r'^# (ERROR|WARNING|INFO): ', re.M)


class ExampleError(Exception):
    pass


def helm(args):
    p = subprocess.run(["helm", "template"] + args, capture_output=True, text=True)
    if p.returncode != 0:
        raise ExampleError(f"helm template failed: {p.stderr.strip()}")
    if DIAG.search(p.stdout):
        raise ExampleError("render has diagnostics: " + "; ".join(
            l for l in p.stdout.splitlines() if DIAG.match(l)))
    return p.stdout


def top_key(text, key):
    """The YAML text of a top-level `key` of a rendered document (no YAML parser)."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(re.escape(key) + r':(?:\s+(.*))?$', line)
        if not m:
            continue
        body = []
        for nxt in lines[i + 1:]:
            if nxt and not nxt.startswith((" ", "- ")) and nxt != "-":
                break
            body.append(nxt)
        if m.group(1) and not re.match(r'[|>][-+]?$', m.group(1)):
            return m.group(1)
        indent = min((len(l) - len(l.lstrip()) for l in body if l.strip()), default=0)
        return "\n".join(l[indent:] for l in body).rstrip()
    raise ExampleError(f"render has no top-level '{key}'")


def fence(lang, text):
    """A fenced block, its fence longer than any backtick run the text starts a line with."""
    runs = [len(m.group(0)) for m in re.finditer(r'^[ \t]*`{3,}', text, re.M)]
    tick = "`" * max([3] + [r + 1 for r in runs])
    return [f"{tick}{lang}"] + text.rstrip("\n").splitlines() + [tick]


def generate(root, stem, attrs, opts):
    """The lines between one marker pair."""
    base = root / stem
    values = base.with_suffix(".yaml")
    if not values.is_file():
        raise ExampleError(f"no {stem}.yaml")
    if attrs.get("render") == "none":
        version = re.search(r'^version:\s*"?([^"\s]+)', (root / "Chart.yaml").read_text(), re.M)
        return fence("yaml", values.read_text().replace("@CHART_VERSION@", version.group(1) if version else ""))
    targets = [t for t in attrs.get("target", "").split(",") if t] or [None]
    out = fence("yaml", f"# {stem}.yaml\n" + values.read_text())
    if opts["kind"] == "stub":
        snippet = base.with_suffix(".tpl")
        if not snippet.is_file():
            raise ExampleError(f"no {stem}.tpl")
        out += fence("gotemplate", snippet.read_text())
        for t in targets:
            args = [opts["chart"], "-s", "templates/cr.yaml", "-f", str(values),
                    "--set-file", f"ops[0].tpl={snippet}", "--set", "ops[0].at[0]=result"]
            if t:
                args += ["--set", f"target={t}"]
            result = top_key(helm(args), "result")
            out += fence(attrs.get("lang", "yaml"), (f"# {t}\n" if t else "") + result)
    else:
        show = [p for p in attrs.get("show", "").split(",") if p]
        if not show:
            raise ExampleError("a consumer example needs show=")
        for t in targets:
            args = [opts["chart"], "-s", "templates/example.yaml"]
            args += ["-f", opts["base"]] if opts["base"] else []
            args += ["-f", str(values), "--set-json", "example=" + json.dumps({"show": show})]
            if t:
                args += ["--set", f"deploymentConfig.target={t}"]
            text = helm(args)
            parts = re.split(r'^# show: (.*)$', text, flags=re.M)
            got = dict(zip(parts[1::2], parts[2::2]))
            block = []
            for p in show:
                if p not in got:
                    raise ExampleError(f"render shows no '{p}'")
                block += [f"# {t + ': ' if t else ''}spec.{p}"] + got[p].strip("\n").splitlines()
            out += fence("yaml", "\n".join(block))
    return out


def rewrite(readme, opts):
    """(new text, [(line, stem, generated lines, current lines)], [failures])."""
    root = readme.parent
    lines = readme.read_text().splitlines()
    out, blocks, failures, i = [], [], [], 0
    while i < len(lines):
        m = OPEN.match(lines[i].strip())
        out.append(lines[i])
        if not m:
            i += 1
            continue
        end = next((j for j in range(i + 1, len(lines)) if lines[j].strip() == CLOSE), None)
        if end is None:
            failures.append(f"{readme}:{i + 1}: example {m.group(1)} has no '{CLOSE}'")
            i += 1
            continue
        attrs = dict(a.split("=", 1) for a in m.group(2).split())
        current = lines[i + 1:end]
        try:
            generated = generate(root, m.group(1), attrs, opts)
        except ExampleError as e:
            failures.append(f"{readme}:{i + 1}: example {m.group(1)}: {e}")
            generated = current
        blocks.append((i + 1, m.group(1), generated, current))
        out += generated + [lines[end]]
        i = end + 1
    return "\n".join(out) + "\n", blocks, failures


def parse(argv):
    opts = {"readme": "", "chart": "", "kind": "", "base": ""}
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--chart", "--kind", "--base"):
            if not args:
                return None, f"{a} needs a value"
            opts[a[2:]] = args.pop(0)
        elif a.startswith("-") or opts["readme"]:
            return None, f"unexpected argument: {a}"
        else:
            opts["readme"] = a
    if not (opts["readme"] and opts["chart"]) or opts["kind"] not in ("stub", "consumer"):
        return None, "needs <readme> --chart <test chart> --kind stub|consumer"
    return opts, ""


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, (opts, error) = argv[0], parse(argv[1:])
    if cmd not in ("render", "check") or error:
        print(f"examples.py: {error or 'unknown subcommand: ' + cmd}", file=sys.stderr)
        print("usage: examples.py render|check <readme> --chart <dir> --kind stub|consumer [--base <values>]",
              file=sys.stderr)
        return 2
    readme = Path(opts["readme"])
    text, blocks, failures = rewrite(readme, opts)
    if cmd == "render" and not failures:
        readme.write_text(text)
    if cmd == "check":
        failures += [f"{readme}:{line}: block {stem} differs — run make docs"
                     for line, stem, generated, current in blocks if generated != current]
    for f in failures:
        print(f"FAIL examples.py: {f}", file=sys.stderr)
    print(f"examples.py: {len(blocks)} examples, {len(failures)} failed", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
