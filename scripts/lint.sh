#!/bin/sh
# lint.sh — template lint: text rules (the Helm/Go template facts of the
# workspace CLAUDE.md) and the extractor rules of scripts/extract.py.
# Run by crdkit `make test` on its own templates/ and by mdeploy
# `tests/run.sh lint` on mdeploy's.
#
# Usage: lint.sh [--fail-define <define>] [--pending <file>]
#               [--regex-check-define <define>] [--library]
#               [--scopes <list>] [--internal-suffix] [--peer <templates dir>]...
#               <templates dir>
#   --fail-define          the one define allowed to call `fail` (default: none)
#   --pending              lines `<rule> <file> <reason>`: a hit of <rule> in
#                          <file> is reported PENDING instead of FAIL; an entry
#                          with no hit is reported FIXED? and fails (a fix must
#                          delete it)
#   --regex-check-define   the one define allowed a variable regex pattern (the
#                          consumer-pattern validity probe)
#   --library              turn on the boundary rules — for a library's
#                          templates, which own no crdkit internals
#   --scopes, --internal-suffix, --peer
#                          forwarded to the extractor (see scripts/extract.py)
#
# Text rules (every regular file under the dir; `{{/* … */}}` comments
# skipped):
#   accumulator-default-dict     .diag/.seen/.acc/.out/.memo piped to
#                                `default dict` (an empty dict is falsy)
#   fail-outside-render          `fail` outside --fail-define
#   unguarded-trailing-index     a line that is only `{{- index A K -}}`,
#                                not preceded by `if hasKey A K`, no
#                                `| default` (`<no value>` across include)
#   non-must-regex-user-pattern  regexMatch|regexFind|regexFindAll|
#                                regexReplaceAll|regexReplaceAllLiteral|
#                                regexSplit whose pattern is not a string
#                                literal, a `$<name>Re` local or
#                                crdkit.markerPattern; allowed inside
#                                --regex-check-define (the validity probe)
#
# Boundary rules (--library only):
#   boundary-ctx-tokens          `ctx.tokens` (use token.annotate|info|names)
#   boundary-token-keys          the reserved keys `"_value"`, `"_gen"`,
#                                `"_generated"`
#   boundary-diag-lists          `diag.errors|warnings|infos` (use
#                                crdkit.diag.lines|count)
#   boundary-marker-regex        the marker character class `[A-Za-z0-9_.]`
#                                (use crdkit.markerPattern)
#   boundary-internal-call       include/template of a `crdkit.*.internal`
#                                define
#
# Extractor rules (`<script dir>/extract.py lint`, spec §8.2): define
# naming, ctx writes of text/mutating defines, dead defines, doc-comment
# define names; needs `python3` (missing → exit 2).
#
# Output: `FAIL <rule> <file>:<line>: <text>`,
# `PENDING (<reason>) <rule> <file>:<line>: <text>`,
# `FIXED? (<reason>) <rule> <file>`, then
# `lint.sh: <n> hits, <f> failed, <p> pending` (both groups counted).
# Exit: 0 iff nothing failed; 1 on a failure; 2 on a usage error.

usage() {
  echo "usage: lint.sh [--fail-define <define>] [--pending <file>] [--regex-check-define <define>]" >&2
  echo "               [--library] [--scopes <list>] [--internal-suffix] [--peer <templates dir>]..." >&2
  echo "               <templates dir>" >&2
  exit 2
}

fail_define=
pending=
regex_define=
library=0
extras=
while [ $# -gt 0 ]; do
  case $1 in
    --fail-define) [ $# -ge 2 ] || usage; fail_define=$2; shift 2 ;;
    --pending) [ $# -ge 2 ] || usage; pending=$2; shift 2 ;;
    --regex-check-define) [ $# -ge 2 ] || usage; regex_define=$2; shift 2 ;;
    --library) library=1; shift ;;
    --scopes) [ $# -ge 2 ] || usage; extras="$extras --scopes $2"; shift 2 ;;
    --internal-suffix) extras="$extras --internal-suffix"; shift ;;
    --peer) [ $# -ge 2 ] || usage; extras="$extras --peer $2"; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || usage
dir=${1%/}
[ -d "$dir" ] || { echo "lint.sh: no such directory: $dir" >&2; exit 2; }
if [ -n "$pending" ] && [ ! -f "$pending" ]; then
  echo "lint.sh: no such pending file: $pending" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || {
  echo "lint.sh: python3 not found — the extractor rules need it" >&2
  exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lint.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# The pending file is read first (as awk's first input), "" when absent.
# The trailing count line is internal: this script prints the combined one.
find "$dir" -type f | LC_ALL=C sort | {
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done
  awk -v failDefine="$fail_define" -v pendingFile="$pending" -v regexDefine="$regex_define" \
      -v library="$library" '
  BEGIN {
    split("accumulator-default-dict fail-outside-render unguarded-trailing-index non-must-regex-user-pattern", r, " ")
    for (i in r) textrule[r[i]] = 1
    if (library) {
      split("boundary-ctx-tokens boundary-token-keys boundary-diag-lists boundary-marker-regex boundary-internal-call", b, " ")
      for (i in b) textrule[b[i]] = 1
    }
    if (pendingFile != "") {
      while ((getline l < pendingFile) > 0) {
        if (l ~ /^[[:space:]]*(#|$)/) continue
        n = split(l, w, /[[:space:]]+/)
        if (!(w[1] in textrule)) continue
        key = w[1] " " w[2]
        reason = l
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", reason)
        pend[key] = reason
        pendOrder[++pendCount] = key
      }
      close(pendingFile)
    }
    hits = 0; failed = 0; pendingHits = 0
  }

  FNR == 1 { inComment = 0; define = ""; prev = "" }

  # Removes `{{/* … */}}` comments (single- and multi-line) from the line.
  function stripComments(s,    out, i, j) {
    out = ""
    while (1) {
      if (inComment) {
        j = index(s, "*/")
        if (j == 0) return out
        s = substr(s, j + 2)
        sub(/^[[:space:]]*-?[}][}]/, "", s)
        inComment = 0
      }
      if (match(s, /[{][{]-?[[:space:]]*\/\*/) == 0) return out s
      out = out substr(s, 1, RSTART - 1)
      s = substr(s, RSTART + RLENGTH)
      inComment = 1
    }
  }

  function hit(rule, text,    key) {
    hits++
    key = rule " " FILENAME
    if (key in pend) {
      pendingHits++
      seen[key] = 1
      printf "PENDING (%s) %s %s:%d: %s\n", pend[key], rule, FILENAME, FNR, text
    } else {
      failed++
      printf "FAIL %s %s:%d: %s\n", rule, FILENAME, FNR, text
    }
  }

  # A regex call whose pattern argument starts the string s is allowed.
  function allowedPattern(s) {
    if (s ~ /^"/ || s ~ /^`/) return 1
    if (s ~ /^\$[A-Za-z0-9_]*Re([^A-Za-z0-9_]|$)/) return 1
    if (s ~ /^\([[:space:]]*include[[:space:]]+"crdkit\.markerPattern"/) return 1
    if (regexDefine != "" && define == regexDefine) return 1
    return 0
  }

  {
    raw = $0
    code = stripComments(raw)
    text = raw
    sub(/^[[:space:]]+/, "", text)

    if (match(code, /define[[:space:]]+"[^"]+"/)) {
      define = substr(code, RSTART, RLENGTH)
      sub(/^define[[:space:]]+"/, "", define)
      sub(/"$/, "", define)
    }

    if (code ~ /\.(diag|seen|acc|out|memo)[[:space:]]*\|[[:space:]]*default[[:space:]]+\(?dict\)?([^A-Za-z0-9_]|$)/)
      hit("accumulator-default-dict", text)

    if (code ~ /([{][{]-?|\(|\|)[[:space:]]*fail([[:space:]]|\)|$)/ && (failDefine == "" || define != failDefine))
      hit("fail-outside-render", text)

    if (code ~ /^[[:space:]]*[{][{]-?[[:space:]]*index[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*-?[}][}][[:space:]]*$/) {
      args = code
      sub(/^[[:space:]]*[{][{]-?[[:space:]]*index[[:space:]]+/, "", args)
      sub(/[[:space:]]*-?[}][}][[:space:]]*$/, "", args)
      split(args, a, /[[:space:]]+/)
      guard = "if hasKey " a[1] " " a[2]
      if (index(prev, guard) == 0) hit("unguarded-trailing-index", text)
    }

    rest = code
    while (match(rest, /(^|[^A-Za-z0-9_.])regex(Match|Find|FindAll|ReplaceAll|ReplaceAllLiteral|Split)[[:space:]]+/)) {
      rest = substr(rest, RSTART + RLENGTH)
      if (!allowedPattern(rest)) { hit("non-must-regex-user-pattern", text); break }
    }

    if (library) {
      if (code ~ /(^|[^A-Za-z0-9_.])ctx\.tokens([^A-Za-z0-9_]|$)/)
        hit("boundary-ctx-tokens", text)
      if (code ~ /"_(value|gen|generated)"/)
        hit("boundary-token-keys", text)
      if (code ~ /(^|[^A-Za-z0-9_.])diag\.(errors|warnings|infos)([^A-Za-z0-9_]|$)/)
        hit("boundary-diag-lists", text)
      if (index(code, "[A-Za-z0-9_.]") > 0)
        hit("boundary-marker-regex", text)
      if (code ~ /(include|template)[[:space:]]+"crdkit\.[A-Za-z0-9_.]*\.internal"/)
        hit("boundary-internal-call", text)
    }

    if (code ~ /[^[:space:]]/) prev = code
  }

  END {
    for (i = 1; i <= pendCount; i++) {
      key = pendOrder[i]
      if (!(key in seen)) {
        failed++
        split(key, k, " ")
        printf "FIXED? (%s) %s %s\n", pend[key], k[1], k[2]
      }
    }
    printf "text-lint: %d hits, %d failed, %d pending\n", hits, failed, pendingHits
    exit (failed > 0 ? 1 : 0)
  }
  ' "$@"
} > "$tmp/text"

python3 -I "$script_dir/extract.py" lint $extras --pending "$pending" "$dir" > "$tmp/extract"
extract_rc=$?

counts() { # counts <file> <tool> -> "<hits> <failed> <pending>"
  sed -n "s/^$2: \([0-9][0-9]*\) hits, \([0-9][0-9]*\) failed, \([0-9][0-9]*\) pending$/\1 \2 \3/p" "$1" | tail -1
}
t=$(counts "$tmp/text" text-lint)
e=$(counts "$tmp/extract" extract.py)
if [ -z "$t" ] || [ -z "$e" ]; then
  echo "lint.sh: a lint group produced no summary" >&2
  cat "$tmp/text" "$tmp/extract" >&2
  exit 2
fi
# shellcheck disable=SC2086
set -- $t $e
grep -v '^text-lint: ' "$tmp/text"
grep -v '^extract.py: ' "$tmp/extract"
printf 'lint.sh: %d hits, %d failed, %d pending\n' $(($1 + $4)) $(($2 + $5)) $(($3 + $6))
[ "$extract_rc" -le 1 ] || exit 2
[ $(($2 + $5)) -eq 0 ]
