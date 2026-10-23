#!/bin/sh
# lint.sh — text lint for Helm library templates (the Helm/Go template
# facts of the workspace CLAUDE.md). Run by crdkit `make test` on its own
# templates/ and by mdeploy `tests/run.sh lint` on mdeploy's.
#
# Usage: lint.sh [--fail-define <define>] [--pending <file>] <templates dir>
#   --fail-define  the one define allowed to call `fail` (default: none)
#   --pending      lines `<rule> <file> <reason>`: a hit of <rule> in <file>
#                  is reported PENDING instead of FAIL; an entry with no
#                  hit is reported FIXED? and fails (a fix must delete it)
#
# Rules (every regular file under the dir; `{{/* … */}}` comments skipped):
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
#                                crdkit.markerPattern.internal
#
# Output: `FAIL <rule> <file>:<line>: <text>`,
# `PENDING (<reason>) <rule> <file>:<line>: <text>`,
# `FIXED? (<reason>) <rule> <file>`, then
# `lint.sh: <n> hits, <f> failed, <p> pending`.
# Exit: 0 iff nothing failed; 1 on a failure; 2 on a usage error.

usage() {
  echo "usage: lint.sh [--fail-define <define>] [--pending <file>] <templates dir>" >&2
  exit 2
}

fail_define=
pending=
while [ $# -gt 0 ]; do
  case $1 in
    --fail-define) [ $# -ge 2 ] || usage; fail_define=$2; shift 2 ;;
    --pending) [ $# -ge 2 ] || usage; pending=$2; shift 2 ;;
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

# The pending file is read first (as awk's first input), "" when absent.
find "$dir" -type f | LC_ALL=C sort | {
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done
  awk -v failDefine="$fail_define" -v pendingFile="$pending" '
  BEGIN {
    if (pendingFile != "") {
      while ((getline l < pendingFile) > 0) {
        if (l ~ /^[[:space:]]*(#|$)/) continue
        n = split(l, w, /[[:space:]]+/)
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
    if (s ~ /^\([[:space:]]*include[[:space:]]+"crdkit\.markerPattern\.internal"/) return 1
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
    printf "lint.sh: %d hits, %d failed, %d pending\n", hits, failed, pendingHits
    exit (failed > 0 ? 1 : 0)
  }
  ' "$@"
}
