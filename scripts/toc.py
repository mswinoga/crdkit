#!/usr/bin/env python3
"""Generate the table of contents of a Markdown file between toc markers.

Usage:
  toc.py render <md>...
      Rewrites every toc block in place.
  toc.py check <md>...
      Generates in memory and compares block by block; a differing block
      prints `FAIL toc.py: <md>:<line>: toc differs — run make docs`.
  toc.py -h | --help
      This text.

Markers (each on its own line, content between them generated):
  <!-- toc [depth=<n>] -->
  <!-- /toc -->
  `depth`: the deepest heading level listed, 2..6 (default 3).

Generated block: a blank line, one bullet per heading of level 2..depth
outside fenced blocks, in file order, indented two spaces per level below
2 — `- [<heading text>](#<anchor>)` — then a blank line. Anchors are
GitHub's: `extract.py` `slug`, a repeated anchor suffixed `-1`, `-2`, …
counted over every heading level; the lint's dead-reference rule checks
the same anchors.

Output: `FAIL toc.py: …` lines on stderr, then
`toc.py: <n> blocks, <f> failed`. Exit 0 clean, 1 on a failure, 2 on a
usage error. Run with `python3 -I`.
"""
import re
import sys
from pathlib import Path

# `-I` leaves the script directory off sys.path; extract.py sits beside this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract import fence_step, slug  # noqa: E402

OPEN = re.compile(r'^<!-- toc((?:\s+\w+=\S+)*)\s*-->$')
CLOSE = "<!-- /toc -->"
HEADING = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')


def entries(lines, depth):
    """The toc bullets of lines, headings of level 2..depth."""
    out, seen, fence = [], {}, None
    for line in lines:
        fence, edge = fence_step(fence, line)
        if edge or fence:
            continue
        h = HEADING.match(line)
        if not h:
            continue
        level, text = len(h.group(1)), h.group(2)
        s = slug(text)
        n = seen.get(s, 0)
        seen[s] = n + 1
        if 2 <= level <= depth:
            out.append(f"{'  ' * (level - 2)}- [{text}](#{s if n == 0 else f'{s}-{n}'})")
    return out


def rewrite(md):
    """(new text, [(line, generated lines, current lines)], [failures])."""
    lines = md.read_text().splitlines()
    out, blocks, failures, i = [], [], [], 0
    while i < len(lines):
        m = OPEN.match(lines[i].strip())
        out.append(lines[i])
        if not m:
            i += 1
            continue
        end = next((j for j in range(i + 1, len(lines)) if lines[j].strip() == CLOSE), None)
        if end is None:
            failures.append(f"{md}:{i + 1}: toc has no '{CLOSE}'")
            i += 1
            continue
        attrs = dict(a.split("=", 1) for a in m.group(1).split())
        current = lines[i + 1:end]
        depth = attrs.get("depth", "3")
        if set(attrs) - {"depth"} or depth not in ("2", "3", "4", "5", "6"):
            failures.append(f"{md}:{i + 1}: toc takes only depth=2..6")
            generated = current
        else:
            generated = [""] + entries(lines, int(depth)) + [""]
        blocks.append((i + 1, generated, current))
        out += generated + [lines[end]]
        i = end + 1
    return "\n".join(out) + "\n", blocks, failures


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, files = argv[0], argv[1:]
    if cmd not in ("render", "check") or not files or any(f.startswith("-") for f in files):
        print("usage: toc.py render|check <md>...", file=sys.stderr)
        return 2
    count, failures = 0, []
    for f in files:
        md = Path(f)
        text, blocks, fails = rewrite(md)
        count += len(blocks)
        if cmd == "render" and not fails:
            md.write_text(text)
        if cmd == "check":
            fails += [f"{md}:{line}: toc differs — run make docs"
                      for line, generated, current in blocks if generated != current]
        failures += fails
    for f in failures:
        print(f"FAIL toc.py: {f}", file=sys.stderr)
    print(f"toc.py: {count} blocks, {len(failures)} failed", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
