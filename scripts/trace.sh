#!/bin/sh
# trace.sh — human-readable diff of a crdkit context trace.
#
# Input: JSON {stages: [{entry, ctx}, ...]} (crdkit.render's `trace`,
# e.g. from the stub's trace output). Output: per stage `== <entry>`
# (`(start)` for the first), then one line per changed leaf against the
# previous stage: `+ <path> <json>`, `- <path>`, `~ <path> <old> -> <new>`.
# Paths are jq-style (`.model.spec.x`, `.tokens["A.B"]`).
# Exit: 0 on success; 2 on a usage error, a missing jq or bad JSON.

usage() { echo "usage: trace.sh [<file>|-]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "trace.sh: jq not found" >&2; exit 2; }
[ $# -eq 1 ] || usage
if [ "$1" = "-" ]; then data=$(cat); else [ -f "$1" ] || usage; data=$(cat "$1"); fi
printf '%s' "$data" | jq -e . >/dev/null 2>&1 || { echo "trace.sh: invalid JSON" >&2; exit 2; }

printf '%s' "$data" | jq -r '
  def fmtpath($p):
    reduce $p[] as $s ("";
      if ($s | type) == "number" then . + "[" + ($s | tostring) + "]"
      elif ($s | tostring | test("^[A-Za-z_][A-Za-z0-9_]*$")) then . + "." + ($s | tostring)
      else . + "[\"" + ($s | tostring) + "\"]"
      end);
  def diff($a; $b; $p):
    ($a | type) as $ta | ($b | type) as $tb
    | if $ta != $tb then
        ["~ " + fmtpath($p) + " " + ($a | tojson) + " -> " + ($b | tojson)]
      elif $ta == "object" then
        ((($a | keys_unsorted) + ($b | keys_unsorted)) | unique) as $ks
        | [ $ks[] as $k
            | if ($a | has($k)) and ($b | has($k)) then diff($a[$k]; $b[$k]; $p + [$k])
              elif ($b | has($k)) then ["+ " + fmtpath($p + [$k]) + " " + ($b[$k] | tojson)]
              else ["- " + fmtpath($p + [$k])]
              end ]
        | add // []
      elif $ta == "array" then
        (([$a | length, $b | length] | max)) as $n
        | [ range(0; $n) as $i
            | if $i < ($a | length) and $i < ($b | length) then diff($a[$i]; $b[$i]; $p + [$i])
              elif $i < ($b | length) then ["+ " + fmtpath($p + [$i]) + " " + ($b[$i] | tojson)]
              else ["- " + fmtpath($p + [$i])]
              end ]
        | add // []
      elif $a != $b then
        ["~ " + fmtpath($p) + " " + ($a | tojson) + " -> " + ($b | tojson)]
      else [] end;
  (if type == "string" then fromjson else . end)
  | .stages as $s
  | [ range(0; $s | length) as $i
      | (if $i == 0 then "== (start)" else "== " + ($s[$i].entry | tostring) end),
        (if $i == 0 then empty else diff($s[$i - 1].ctx; $s[$i].ctx; [])[] end)
    ]
  | .[]
'
