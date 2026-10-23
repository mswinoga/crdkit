{{/*
Internal helpers of templates/_schema.tpl — see its file-level doc
comment for the overview and dependency graph.
*/}}

{{/*
crdkit.schema.path.internal (internal)

Appends one key or list index to a dotted values path.

Interface:
- Params (dict): { "path": <string, "" at the root>, "key": <string>,
  "index": <int> } — exactly one of "key"/"index"
- Returns: the extended path as plain text.
*/}}
{{- define "crdkit.schema.path.internal" -}}
{{- if hasKey . "index" -}}
{{- printf "%s[%v]" .path .index -}}
{{- else if contains "." (toString .key) -}}
{{- printf "%s[%s]" .path (.key | toString | quote) -}}
{{- else if .path -}}
{{- printf "%s.%s" .path .key -}}
{{- else -}}
{{- .key -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.shape.internal (internal)

Maps a node's type to the shape of the value it describes — the one
place that knows which types are scalars.

Interface:
- Params (dict): { "node": <node> }
- Returns: `scalar`, `map`, `list` or `any` as plain text; an EMPTY
  string for a non-map node, an unknown or an omitted type (a switch
  node).
*/}}
{{- define "crdkit.schema.shape.internal" -}}
{{- if kindIs "map" .node -}}
  {{- $type := .node.type | default "" | toString -}}
  {{- if has $type (list "string" "int" "number" "bool" "scalar") -}}
scalar
  {{- else if has $type (list "map" "list" "any") -}}
{{- $type -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.perTarget.internal (internal)

Whether a node is per-target (its value may be a token declaration).

Interface:
- Params (dict): { "node": <node>, "inTokens": <bool, an ancestor is
  per-target> }
- Returns: the plain string `true`, or an EMPTY string.

Implementation notes:
- Only scalar-type and list nodes, never below a per-target ancestor,
  never `static`.
- A node carrying `perTarget:` (set by crdkit.schema.node, which knows
  the ancestors) is decided by it alone.
*/}}
{{- define "crdkit.schema.perTarget.internal" -}}
{{- $node := .node -}}
{{- if hasKey $node "perTarget" -}}
  {{- if eq (toString $node.perTarget) "true" -}}
true
  {{- end -}}
{{- else if and (has (include "crdkit.schema.shape.internal" (dict "node" $node)) (list "scalar" "list")) (not .inTokens) (ne (toString $node.static) "true") -}}
true
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.checkNode.internal (internal)

Recursive self-check of one schema node; collects every problem.

Interface:
- Params (dict): { "node": <any>, "path": <schema path string>,
  "inTokens": <bool, an ancestor is per-target>, "switchBy": <list of
  the switch's `by` and `unless.key`, on a switch case node only>,
  "isSwitchBy": <bool, the node is a switch case's `by` or
  `unless.key`>, "problems": <dict with a "list" key, appended to in
  place> }
- Returns: nothing.

Implementation notes:
- `static: true` below a per-target node is a problem, except on a
  switch case's `by` / `unless.key`: they select the case, never a value.
*/}}
{{- define "crdkit.schema.checkNode.internal" -}}
{{- $node := .node -}}
{{- $path := .path | default "" -}}
{{- $prefix := ternary (printf "%s." $path) "" (ne $path "") -}}
{{- $problems := .problems -}}
{{- $inTokens := .inTokens -}}
{{- $found := list -}}
{{- if not (kindIs "map" $node) -}}
  {{- $found = append $found "node must be a map" -}}
{{- else -}}
  {{- $allowed := list "doc" "default" "required" "type" "enum" "pattern" "static" "properties" "values" "keys" "items" "switch" "targetKeys" "annotations" -}}
  {{- range $key, $_ := $node -}}
    {{- if not (has $key $allowed) -}}
      {{- $found = append $found (printf "unknown schema key '%s'" $key) -}}
    {{- end -}}
  {{- end -}}
  {{- $type := $node.type | default "" | toString -}}
  {{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
  {{- if hasKey $node "switch" -}}
    {{- if and $type (ne $type "map") -}}
      {{- $found = append $found (printf "'switch' requires type 'map', got '%s'" $type) -}}
    {{- end -}}
    {{- $switch := $node.switch -}}
    {{- if not (and (kindIs "map" $switch) (kindIs "string" $switch.by) (kindIs "map" $switch.cases) (eq (len (omit $switch "unless")) 2)) -}}
      {{- $found = append $found "'switch' must be {by: <key>, cases: {<value>: <node>}, unless?: {key: <key>, value: <scalar>}}" -}}
    {{- else -}}
      {{- $keys := list $switch.by -}}
      {{- if hasKey $switch "unless" -}}
        {{- $unless := $switch.unless -}}
        {{- if not (and (kindIs "map" $unless) (eq (len $unless) 2) (kindIs "string" $unless.key) (hasKey $unless "value") (not (kindIs "map" $unless.value)) (not (kindIs "slice" $unless.value)) (not (kindIs "invalid" $unless.value))) -}}
          {{- $found = append $found "'switch.unless' must be {key: <key>, value: <scalar>}" -}}
        {{- else if eq $unless.key $switch.by -}}
          {{- $found = append $found (printf "'switch.unless.key' must differ from 'by' ('%s')" $switch.by) -}}
        {{- else -}}
          {{- $keys = append $keys $unless.key -}}
        {{- end -}}
      {{- end -}}
      {{- range $caseValue, $caseNode := $switch.cases -}}
        {{- $casePath := printf "%sswitch.cases.%s" $prefix $caseValue -}}
        {{- include "crdkit.schema.checkNode.internal" (dict "node" $caseNode "path" $casePath "inTokens" $inTokens "switchBy" $keys "problems" $problems) -}}
        {{- range $key := $keys -}}
          {{- $onNode := "" -}}
          {{- if and (kindIs "map" $caseNode) (kindIs "map" $caseNode.properties) -}}
            {{- $onNode = index $caseNode.properties $key -}}
          {{- end -}}
          {{- if not (and (eq (include "crdkit.schema.shape.internal" (dict "node" $onNode)) "scalar") (eq (toString $onNode.static) "true")) -}}
            {{- $found = append $found (printf "case '%s' must declare '%s' as a scalar type with 'static: true'" $caseValue $key) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- else if not $shape -}}
    {{- $found = append $found (printf "unknown type '%s'" $type) -}}
  {{- end -}}
  {{- $appliesTo := dict "enum" (list "scalar") "pattern" (list "scalar") "static" (list "scalar") "properties" (list "map") "values" (list "map") "keys" (list "map") "items" (list "list") "annotations" (list "scalar" "list") -}}
  {{- if $shape -}}
    {{- range $key, $shapes := $appliesTo -}}
      {{- if and (hasKey $node $key) (not (has $shape $shapes)) -}}
        {{- $found = append $found (printf "'%s' does not apply to type '%s'" $key $type) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and (hasKey $node "enum") (not (kindIs "slice" $node.enum)) -}}
    {{- $found = append $found "'enum' must be a list" -}}
  {{- end -}}
  {{- if and (hasKey $node "pattern") (not (kindIs "string" $node.pattern)) -}}
    {{- $found = append $found "'pattern' must be a string" -}}
  {{- end -}}
  {{- range $key := list "targetKeys" "annotations" -}}
    {{- if hasKey $node $key -}}
      {{- $strings := kindIs "slice" (index $node $key) -}}
      {{- if $strings -}}
        {{- range $item := index $node $key -}}
          {{- $strings = and $strings (kindIs "string" $item) -}}
        {{- end -}}
      {{- end -}}
      {{- if not $strings -}}
        {{- $found = append $found (printf "'%s' must be a list of strings" $key) -}}
      {{- else -}}
        {{- range $reserved := list "default" "match" -}}
          {{- if has $reserved (index $node $key) -}}
            {{- $found = append $found (printf "'%s' must not list '%s' (always allowed)" $key $reserved) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- range $flag := list "required" "static" -}}
    {{- if and (hasKey $node $flag) (not (kindIs "bool" (index $node $flag))) -}}
      {{- $found = append $found (printf "'%s' must be a bool" $flag) -}}
    {{- end -}}
  {{- end -}}
  {{- if and $inTokens (eq (toString $node.static) "true") (not .isSwitchBy) -}}
    {{- $found = append $found "'static' does not apply below a per-target node" -}}
  {{- end -}}
  {{- if and (hasKey $node "default") (eq (toString $node.required) "true") -}}
    {{- $found = append $found "'default' and 'required: true' exclude each other" -}}
  {{- end -}}
  {{- if and (hasKey $node "keys") (not (and (kindIs "map" $node.keys) (kindIs "string" $node.keys.pattern))) -}}
    {{- $found = append $found "'keys' must be {pattern: <regex>}" -}}
  {{- else if and (hasKey $node "keys") (hasKey $node.keys "label") (not (kindIs "string" $node.keys.label)) -}}
    {{- $found = append $found "'keys.label' must be a string" -}}
  {{- end -}}
  {{- $childInTokens := or $inTokens (ne (include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens)) "") -}}
  {{- if hasKey $node "properties" -}}
    {{- if not (kindIs "map" $node.properties) -}}
      {{- $found = append $found "'properties' must be a map" -}}
    {{- else -}}
      {{- range $key, $child := $node.properties -}}
        {{- include "crdkit.schema.checkNode.internal" (dict "node" $child "path" (printf "%sproperties.%s" $prefix $key) "inTokens" $childInTokens "isSwitchBy" (and (kindIs "slice" $.switchBy) (has $key $.switchBy)) "problems" $problems) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- range $key := list "values" "items" -}}
    {{- if hasKey $node $key -}}
      {{- include "crdkit.schema.checkNode.internal" (dict "node" (index $node $key) "path" (printf "%s%s" $prefix $key) "inTokens" $childInTokens "problems" $problems) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $problem := $found -}}
  {{- $_ := set $problems "list" (append $problems.list (printf "schema invalid: %s: %s" ($path | default "(root)") $problem)) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.scalarReason.internal (internal)

Checks one scalar value against a node's type/enum/pattern.

Interface:
- Params (dict): { "node": <scalar-type node>, "value": <scalar>, "strict":
  <bool> }
- Returns: the first violated rule as plain text (`must be of type
  'int'`, `must be one of 'a', 'b'`, `must match '<re>'`), or an EMPTY
  string.

Implementation notes:
- strict (values as written): native type only — Helm decodes every
  number as float64, so `int` accepts an integral number.
- not strict ("parses as", resolved values): the native type OR a
  string spelling it (`^-?[0-9]+$` for int, a decimal/exponent for
  number, `true|false` for bool); `string` accepts every scalar.
- pattern uses `mustRegexMatch`: an invalid regex aborts the render,
  like a `match:` rule (crdkit.matchRules).
*/}}
{{- define "crdkit.schema.scalarReason.internal" -}}
{{- $node := .node -}}
{{- $value := .value -}}
{{- $text := toString $value -}}
{{- $numeric := or (kindIs "float64" $value) (kindIs "int" $value) (kindIs "int64" $value) -}}
{{- $isString := kindIs "string" $value -}}
{{- $intRe := "^-?[0-9]+$" -}}
{{- $numberRe := "^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$" -}}
{{- $ok := true -}}
{{- $type := $node.type | default "" | toString -}}
{{- if eq $type "string" -}}
  {{- $ok = or $isString (not .strict) -}}
{{- else if eq $type "int" -}}
  {{- $ok = or (and $numeric (regexMatch $intRe $text)) (and (not .strict) $isString (regexMatch $intRe $text)) -}}
{{- else if eq $type "number" -}}
  {{- $ok = or $numeric (and (not .strict) $isString (regexMatch $numberRe $text)) -}}
{{- else if eq $type "bool" -}}
  {{- $ok = or (kindIs "bool" $value) (and (not .strict) $isString (regexMatch "^(true|false)$" $text)) -}}
{{- end -}}
{{- if not $ok -}}
{{- printf "must be of type '%s'" $type -}}
{{- else if and (hasKey $node "enum") (not (has $text ($node.enum | toStrings))) -}}
{{- $quoted := list -}}
{{- range $allowed := $node.enum -}}
  {{- $quoted = append $quoted (printf "'%v'" $allowed) -}}
{{- end -}}
{{- printf "must be one of %s" (join ", " $quoted) -}}
{{- else if and (hasKey $node "pattern") (not (mustRegexMatch $node.pattern $text)) -}}
{{- printf "must match '%s'" $node.pattern -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.declarationKeys.internal (internal)

The keys a token declaration at a node may use when target keys are in
effect.

Interface:
- Params (dict): { "node": <checked node>, "targetKeys": <list of
  strings in effect at the node> }
- Returns YAML: { "value": [<target keys>..., default, match,
  <node annotations>...] }
*/}}
{{- define "crdkit.schema.declarationKeys.internal" -}}
value: {{ concat .targetKeys (list "default" "match") (.node.annotations | default list) | toYaml | nindent 2 }}
{{- end -}}

{{/*
crdkit.schema.checkDeclaration.internal (internal)

Checks the keys of one consumer token declaration against the keys in
effect (crdkit.schema.declarationKeys.internal); part of the structural
pass.

Interface:
- Params (dict): { "node": <checked node>, "value": <the declaration, a
  dict>, "path": <values path>, "diag": <dict>, "targetKeys": <list of
  strings in effect>, "out": <dict, written in place> }
- Returns: nothing; sets out.value to the declaration without the keys
  that failed (out.keep stays true).

Implementation notes:
- An unknown key → ERROR `'<path>.<key>' is not a target key — ignored;
  allowed: <keys>; an exact target goes in 'match'`, key dropped.
- `match` that is not a list of single-key maps → ERROR, dropped; each
  well-formed rule's regex is checked here (invalid → ERROR
  `'<path>.match[<i>]'`, rule dropped).
- Keys are visited in sorted order, so messages are stable.
*/}}
{{- define "crdkit.schema.checkDeclaration.internal" -}}
{{- $diag := .diag -}}
{{- $allowed := (include "crdkit.schema.declarationKeys.internal" (dict "node" .node "targetKeys" .targetKeys) | fromYaml).value -}}
{{- $result := dict -}}
{{- range $key := keys .value | sortAlpha -}}
  {{- $entry := index $.value $key -}}
  {{- $keyPath := include "crdkit.schema.path.internal" (dict "path" $.path "key" $key) -}}
  {{- if not (has $key $allowed) -}}
    {{- include "crdkit.diag.error" (list $diag (printf "'%s' is not a target key — ignored; allowed: %s; an exact target goes in 'match'" $keyPath (join ", " $allowed))) -}}
  {{- else if eq $key "match" -}}
    {{- $valid := kindIs "slice" $entry -}}
    {{- if $valid -}}
      {{- range $rule := $entry -}}
        {{- $valid = and $valid (kindIs "map" $rule) (eq (len $rule) 1) -}}
      {{- end -}}
    {{- end -}}
    {{- if $valid -}}
      {{- $kept := list -}}
      {{- range $i, $rule := $entry -}}
        {{- $pattern := first (keys $rule) -}}
        {{- if include "crdkit.regexValid.internal" (dict "pattern" $pattern) -}}
          {{- $kept = append $kept $rule -}}
        {{- else -}}
          {{- include "crdkit.diag.error" (list $diag (printf "'%s[%d]': '%s' is not a valid regex — rule ignored" $keyPath $i $pattern)) -}}
        {{- end -}}
      {{- end -}}
      {{- $_ := set $result $key $kept -}}
    {{- else -}}
      {{- include "crdkit.diag.error" (list $diag (printf "'%s' must be a list of single-key maps {<regex>: <value>} — ignored" $keyPath)) -}}
    {{- end -}}
  {{- else -}}
    {{- $_ := set $result $key $entry -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "value" $result -}}
{{- end -}}

{{/*
crdkit.schema.switchCase.internal

The case a switch selects for a map value, reduced on an `unless` hit.

Interface:
- Params (dict): { "switch": <switch node: {by, cases, unless?}>, "value":
  <map whose `by` value names an existing case>, "out": <dict, written
  in place> }
- Returns: nothing; sets out.node (case node) and out.value (value).

Implementation notes:
- `unless` hit = `unless.key` equal to `unless.value` by `toJson`
  (type-strict). Then node and value keep only the `by` and
  `unless.key` properties: every other key is dropped without a
  diagnostic.
*/}}
{{- define "crdkit.schema.switchCase.internal" -}}
{{- $switch := .switch -}}
{{- $node := index $switch.cases (toString (index .value $switch.by)) -}}
{{- $value := .value -}}
{{- if and (hasKey $switch "unless") (hasKey $value $switch.unless.key) (eq (toJson (index $value $switch.unless.key)) (toJson $switch.unless.value)) -}}
  {{- $node = merge (dict "properties" (pick ($node.properties | default dict) $switch.by $switch.unless.key)) (omit $node "properties") -}}
  {{- $value = pick $value $switch.by $switch.unless.key -}}
{{- end -}}
{{- $_ := set .out "node" $node -}}
{{- $_ := set .out "value" $value -}}
{{- end -}}

{{/*
crdkit.schema.walk.internal (internal)

Validates one value against one node, recursively.

Interface:
- Params (dict): { "node": <checked node>, "value": <any, never nil>,
  "path": <values path>, "diag": <dict>, "mode": "structural" |
  "resolved", "suffix": <text after the path in resolved-mode messages,
  e.g. " for target 'qa'">, "inTokens": <bool, an ancestor is
  per-target>, "targetKeys": <inherited target keys, optional>, "out":
  <dict, written in place> }
- Returns: nothing; sets out.keep (bool) and out.value (structural:
  the normalized value — defaults applied, failing nodes dropped).

Implementation notes:
- Results travel through "out", not YAML: a YAML round-trip would turn
  every value into its decoded form at each level.
- structural mode: shape mismatch / unmatched switch → WARNING, ERROR
  on a `required: true` node (the required check reads the input as
  written, so the drop would pass silently); unknown key → WARNING;
  required / type / enum / pattern / markers / keys.pattern → ERROR; a
  map on a static scalar node → ERROR, whatever `required` says (a
  fallback to the default would invert e.g. `enabled: {PROD: false}`);
  a node that fails is dropped (its parent's default then
  applies), a key failing "keys.pattern" with its value, and a YAML 1.1
  boolean word (y/n/yes/no/on/off/true/false, any case) as a `keys` map
  key (checked before the pattern). A per-target
  node holding a dict is a token declaration: kept as written, checked
  by the value pass; with target keys in effect (the node's own
  `targetKeys`, else the inherited ones) its keys are checked first
  (crdkit.schema.checkDeclaration.internal). A string holding "@NAME@" markers skips type/enum/pattern —
  it is checked by the value pass once substituted.
- resolved mode: the value is a resolved per-target value; every
  violation except an unknown key is an ERROR; scalars are checked
  "parses as"; no defaults, no markers check.
- A nil map entry counts as absent.
*/}}
{{- define "crdkit.schema.walk.internal" -}}
{{- $node := .node -}}
{{- $value := .value -}}
{{- $path := .path -}}
{{- $diag := .diag -}}
{{- $out := .out -}}
{{- $mode := .mode -}}
{{- $suffix := .suffix | default "" -}}
{{- $resolved := eq $mode "resolved" -}}
{{- $shapeDiag := ternary "crdkit.diag.error" "crdkit.diag.warning" (or $resolved (eq (toString $node.required) "true")) -}}
{{- $tail := ternary "" " — ignored" $resolved -}}
{{- $_ := set $out "keep" true -}}
{{- $_ := set $out "value" $value -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $inTokens := .inTokens -}}
{{- $targetKeys := .targetKeys -}}
{{- if hasKey $node "targetKeys" -}}
  {{- $targetKeys = $node.targetKeys -}}
{{- end -}}
{{- $tokens := include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- $isDeclaration := and (not $resolved) $tokens (kindIs "map" $value) -}}
{{- if hasKey $node "switch" -}}
  {{- $switch := $node.switch -}}
  {{- $onPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $switch.by) -}}
  {{- if not (kindIs "map" $value) -}}
    {{- include $shapeDiag (list $diag (printf "'%s'%s must be a map%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if kindIs "invalid" (index $value $switch.by) -}}
    {{- include $shapeDiag (list $diag (printf "'%s'%s has no '%s'%s" $path $suffix $switch.by $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if not (hasKey $switch.cases (toString (index $value $switch.by))) -}}
    {{- include $shapeDiag (list $diag (printf "'%s'%s has unknown value '%v'%s" $onPath $suffix (index $value $switch.by) $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $case := dict -}}
    {{- include "crdkit.schema.switchCase.internal" (dict "switch" $switch "value" $value "out" $case) -}}
    {{- include "crdkit.schema.walk.internal" (dict "node" $case.node "value" $case.value "path" $path "diag" $diag "mode" $mode "suffix" $suffix "inTokens" $inTokens "targetKeys" $targetKeys "out" $out) -}}
  {{- end -}}
{{- else if and $isDeclaration (kindIs "slice" $targetKeys) -}}
  {{- include "crdkit.schema.checkDeclaration.internal" (dict "node" $node "value" $value "path" $path "diag" $diag "targetKeys" $targetKeys "out" $out) -}}
{{- else if or (eq $shape "any") $isDeclaration -}}
  {{/* kept as written */}}
{{- else if eq $shape "scalar" -}}
  {{- if and (not $resolved) (kindIs "map" $value) (eq (toString $node.static) "true") -}}
    {{- include "crdkit.diag.error" (list $diag (printf "'%s' is static — a token declaration is not allowed — ignored" $path)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if or (kindIs "map" $value) (kindIs "slice" $value) -}}
    {{- include $shapeDiag (list $diag (printf "'%s'%s must be a scalar%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $hasMarkers := and (not $resolved) (kindIs "string" $value) (regexMatch (include "crdkit.markerPattern" (dict)) $value) -}}
    {{- if and $hasMarkers (eq (toString $node.static) "true") -}}
      {{- include "crdkit.diag.error" (list $diag (printf "'%s' must not contain '@NAME@' markers — ignored" $path)) -}}
      {{- $_ := set $out "keep" false -}}
    {{- else if not $hasMarkers -}}
      {{- $reason := include "crdkit.schema.scalarReason.internal" (dict "node" $node "value" $value "strict" (not $resolved)) -}}
      {{- if $reason -}}
        {{- if $resolved -}}
          {{- include "crdkit.diag.error" (list $diag (printf "'%s'%s %s — got '%v'" $path $suffix $reason $value)) -}}
        {{- else -}}
          {{- include "crdkit.diag.error" (list $diag (printf "'%s' %s — ignored" $path $reason)) -}}
        {{- end -}}
        {{- $_ := set $out "keep" false -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- else if eq $shape "list" -}}
  {{- if not (kindIs "slice" $value) -}}
    {{- include $shapeDiag (list $diag (printf "'%s'%s must be a list%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $items := $node.items | default (dict "type" "any") -}}
    {{- $result := list -}}
    {{- range $i, $element := $value -}}
      {{- $elementPath := include "crdkit.schema.path.internal" (dict "path" $path "index" $i) -}}
      {{- if kindIs "invalid" $element -}}
        {{- $result = append $result $element -}}
      {{- else -}}
        {{- $elementOut := dict -}}
        {{- include "crdkit.schema.walk.internal" (dict "node" $items "value" $element "path" $elementPath "diag" $diag "mode" $mode "suffix" $suffix "inTokens" $childInTokens "targetKeys" $targetKeys "out" $elementOut) -}}
        {{- if $elementOut.keep -}}
          {{- $result = append $result $elementOut.value -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $out "value" $result -}}
  {{- end -}}
{{- else if eq $shape "map" -}}
  {{- if not (kindIs "map" $value) -}}
    {{- include $shapeDiag (list $diag (printf "'%s'%s must be a map%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $properties := $node.properties | default dict -}}
    {{- $result := dict -}}
    {{- range $key, $child := $value -}}
      {{- $childPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $key) -}}
      {{- if not (kindIs "invalid" $child) -}}
        {{- $childNode := dict -}}
        {{- $badKey := false -}}
        {{- $booleanWord := false -}}
        {{- if hasKey $properties $key -}}
          {{- $childNode = index $properties $key -}}
        {{- else if hasKey $node "values" -}}
          {{- $childNode = $node.values -}}
          {{- if hasKey $node "keys" -}}
            {{- if and (not $resolved) (regexMatch "(?i)^(y|n|yes|no|on|off|true|false)$" $key) -}}
              {{- $booleanWord = true -}}
            {{- else -}}
              {{- $badKey = not (mustRegexMatch $node.keys.pattern $key) -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
        {{- if $booleanWord -}}
          {{- include "crdkit.diag.error" (list $diag (printf "key '%s'%s is a YAML 1.1 boolean word (y, n, yes, no, on, off, true, false) — ignored" $childPath $suffix)) -}}
        {{- else if $badKey -}}
          {{- include "crdkit.diag.error" (list $diag (printf "key '%s'%s must match '%s'%s" $childPath $suffix $node.keys.pattern $tail)) -}}
        {{- else if not $childNode -}}
          {{- include "crdkit.diag.warning" (list $diag (printf "'%s'%s is not a known key%s" $childPath $suffix $tail)) -}}
        {{- else -}}
          {{- $childOut := dict -}}
          {{- include "crdkit.schema.walk.internal" (dict "node" $childNode "value" $child "path" $childPath "diag" $diag "mode" $mode "suffix" $suffix "inTokens" $childInTokens "targetKeys" $targetKeys "out" $childOut) -}}
          {{- if $childOut.keep -}}
            {{- $_ := set $result $key $childOut.value -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- range $key, $childNode := $properties -}}
      {{- if not (hasKey $result $key) -}}
        {{- $given := and (hasKey $value $key) (not (kindIs "invalid" (index $value $key))) -}}
        {{- if and (hasKey $childNode "default") (not $resolved) -}}
          {{- $_ := set $result $key (index $childNode "default" | deepCopy) -}}
        {{- else if and (eq (toString $childNode.required) "true") (not $given) -}}
          {{- $childPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $key) -}}
          {{- include "crdkit.diag.error" (list $diag (printf "'%s'%s is required" $childPath $suffix)) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $out "value" $result -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.resolveAndCheck.internal (internal)

Resolves one per-target value for a target and checks the result.

Interface:
- Params (dict): { "ctx": <ctx>, "node": <checked node>, "def": <the
  value as written: a token declaration, a plain value or a string with
  markers>, "tokens": <bool, the node is per-target>, "path": <values
  path>, "target": <string>, "seen": <dict>, "out": <dict, written in
  place> }
- Returns: nothing; sets out.value to the resolved value — for an
  `int` / `number` / `bool` node, a resolved string that passes the node's
  "parses as" check (crdkit.schema.scalarReason.internal) converted to
  that type (int, float64, bool).

Implementation notes:
- A value that fails the check, or still holds an unresolved marker
  (e.g. one left for a later substitution pass), is returned
  unconverted. `string` / `scalar` nodes are returned as resolved.
- A "token" param resolves through crdkit.token.value; a per-target
  node otherwise through crdkit.tokenDef.value (field id = the values
  path); any other value through crdkit.tokens.substitute.
- Checked at most once per `<path>|<target>` (recorded in "seen").
- Not checked when resolution itself recorded an ERROR (e.g. "no value
  found") or left a marker unresolved — that diagnostic already names
  the problem.
*/}}
{{- define "crdkit.schema.resolveAndCheck.internal" -}}
{{- $ctx := .ctx -}}
{{- $node := .node -}}
{{- $target := .target -}}
{{- $errorsBefore := len $ctx.diag.errors -}}
{{- $value := "" -}}
{{- if .token -}}
  {{- $value = (include "crdkit.token.value" (list $ctx .token $target) | fromYaml).value -}}
{{- else if .tokens -}}
  {{- $value = (include "crdkit.tokenDef.value" (list $ctx .path .def $target) | fromYaml).value -}}
{{- else -}}
  {{- $value = include "crdkit.tokens.substitute" (list $ctx .def $target) -}}
{{- end -}}
{{- $_ := set .out "value" $value -}}
{{- $unresolved := and (kindIs "string" $value) (regexMatch (include "crdkit.markerPattern" (dict)) $value) -}}
{{- $type := $node.type | default "" | toString -}}
{{/* converted on every call, not only the checked one: a repeated call (check skipped via "seen") must return the same value. */}}
{{- if and (kindIs "string" $value) (not $unresolved) (has $type (list "int" "number" "bool")) -}}
  {{- if not (include "crdkit.schema.scalarReason.internal" (dict "node" $node "value" $value "strict" false)) -}}
    {{- if eq $type "int" -}}
      {{- $_ := set .out "value" (atoi $value) -}}
    {{- else if eq $type "number" -}}
      {{- $_ := set .out "value" (float64 $value) -}}
    {{- else -}}
      {{- $_ := set .out "value" (eq $value "true") -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $seenKey := printf "%s|%s" .path $target -}}
{{- if not (hasKey .seen $seenKey) -}}
  {{- $_ := set .seen $seenKey true -}}
  {{- if and (eq (len $ctx.diag.errors) $errorsBefore) (not $unresolved) (not (kindIs "invalid" $value)) -}}
    {{- include "crdkit.schema.walk.internal" (dict "node" $node "value" $value "path" .path "diag" $ctx.diag "mode" "resolved" "suffix" (printf " for target '%s'" $target) "out" (dict)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.valuesWalk.internal (internal)

Value pass over (normalized) values: finds every per-target value and
checks it for one target; with "out", also builds the copy of the values
with every per-target value resolved.

Interface:
- Params (dict): { "ctx": <ctx>, "node": <checked node>, "value":
  <any>, "path": <values path>, "target": <string>, "seen": <dict>,
  "inTokens": <bool, an ancestor is per-target>, "out": <dict, optional> }
- Returns: nothing; with "out", sets out.value to the resolved copy of
  "value" (and leaves it unset for a value that has no result).

Implementation notes:
- Without "out" the walk only checks.
- Per-target values: the value of every per-target node
  (crdkit.schema.perTarget.internal), and every string holding "@NAME@"
  markers.
- Follows only what the structural pass would keep: an unmatched switch,
  a shape mismatch or an unknown key is skipped silently (already
  reported there) and has no result.
- Result per level: map → dict of the children's results (a child
  without a result is omitted), list → list likewise, switch → the
  selected case's result, "any" and a plain scalar → as written,
  per-target value → resolved (crdkit.schema.resolveAndCheck.internal).
- A per-target value whose resolution recorded an ERROR and returned
  nothing ("no value found") has no result; one that resolved but failed
  its check keeps the resolved value, unconverted.
*/}}
{{- define "crdkit.schema.valuesWalk.internal" -}}
{{- $node := .node -}}
{{- $value := .value -}}
{{- $path := .path -}}
{{- $out := .out -}}
{{- $collect := kindIs "map" $out -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $inTokens := .inTokens -}}
{{- $tokens := include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- $common := dict "ctx" .ctx "target" .target "seen" .seen -}}
{{- if kindIs "invalid" $value -}}
{{- else if hasKey $node "switch" -}}
  {{- if kindIs "map" $value -}}
    {{- $selected := toString (index $value $node.switch.by) -}}
    {{- if and (not (kindIs "invalid" (index $value $node.switch.by))) (hasKey $node.switch.cases $selected) -}}
      {{- $case := dict -}}
      {{- include "crdkit.schema.switchCase.internal" (dict "switch" $node.switch "value" $value "out" $case) -}}
      {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" $case.node "value" $case.value "path" $path "inTokens" $inTokens "out" $out) $common) -}}
    {{- end -}}
  {{- end -}}
{{- else if eq $shape "any" -}}
  {{- if $collect -}}{{- $_ := set $out "value" $value -}}{{- end -}}
{{- else if or $tokens (and (eq $shape "scalar") (kindIs "string" $value) (regexMatch (include "crdkit.markerPattern" (dict)) $value)) -}}
  {{- $leaf := dict -}}
  {{- $errorsBefore := len .ctx.diag.errors -}}
  {{- include "crdkit.schema.resolveAndCheck.internal" (merge (dict "node" $node "def" $value "tokens" (ne $tokens "") "path" $path "out" $leaf) $common) -}}
  {{- if $collect -}}
    {{/* an ERROR with an empty result = nothing found for the target. */}}
    {{- $missing := and (gt (len .ctx.diag.errors) $errorsBefore) (or (kindIs "invalid" $leaf.value) (eq (toString $leaf.value) "")) -}}
    {{- if not $missing -}}{{- $_ := set $out "value" $leaf.value -}}{{- end -}}
  {{- end -}}
{{- else if and (eq $shape "scalar") (not (kindIs "map" $value)) (not (kindIs "slice" $value)) -}}
  {{- if $collect -}}{{- $_ := set $out "value" $value -}}{{- end -}}
{{- else if and (eq $shape "list") (kindIs "slice" $value) -}}
  {{- $items := list -}}
  {{- range $i, $element := $value -}}
    {{- $childOut := ternary (dict) (index (dict) "none") $collect -}}
    {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" ($node.items | default (dict "type" "any")) "value" $element "path" (include "crdkit.schema.path.internal" (dict "path" $path "index" $i)) "inTokens" $childInTokens "out" $childOut) $common) -}}
    {{- if and $collect (hasKey $childOut "value") -}}{{- $items = append $items $childOut.value -}}{{- end -}}
  {{- end -}}
  {{- if $collect -}}{{- $_ := set $out "value" $items -}}{{- end -}}
{{- else if and (eq $shape "map") (kindIs "map" $value) -}}
  {{- $properties := $node.properties | default dict -}}
  {{- $children := dict -}}
  {{- range $key, $child := $value -}}
    {{- $childNode := dict -}}
    {{- if hasKey $properties $key -}}
      {{- $childNode = index $properties $key -}}
    {{- else if hasKey $node "values" -}}
      {{- $childNode = $node.values -}}
    {{- end -}}
    {{- if $childNode -}}
      {{- $childOut := ternary (dict) (index (dict) "none") $collect -}}
      {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" $childNode "value" $child "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $key)) "inTokens" $childInTokens "out" $childOut) $common) -}}
      {{- if and $collect (hasKey $childOut "value") -}}{{- $_ := set $children $key $childOut.value -}}{{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if $collect -}}{{- $_ := set $out "value" $children -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.jsonType.internal (internal)

Returns the values-schema type of a JSON Schema node, read from its
standard keywords.

Interface:
- Params (dict): { "node": <JSON Schema node> }
- Returns: plain text `string`, `int`, `number`, `bool`, `scalar`,
  `map`, `list` or `any`.

Implementation notes:
- Reads the `anyOf` core of a wrapped node; a switch node is a `map`;
  no `type` is `any`; the type list `[string, number, boolean]` is
  `scalar`.
*/}}
{{- define "crdkit.schema.jsonType.internal" -}}
{{- $core := .node -}}
{{- if hasKey .node "anyOf" -}}
  {{- $core = first .node.anyOf -}}
{{- end -}}
{{- if hasKey .node "x-crdkit-switch" -}}
map
{{- else if kindIs "slice" $core.type -}}
scalar
{{- else -}}
{{- get (dict "string" "string" "integer" "int" "number" "number" "boolean" "bool" "object" "map" "array" "list") ($core.type | default "" | toString) | default "any" -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.jsonPerTarget.internal (internal)

Returns how a JSON Schema node's value may vary, read from its keywords.

Interface:
- Params (dict): { "node": <JSON Schema node> }
- Returns: plain text `yes` (per target: plain value or token
  declaration), `markers` (`@NAME@` markers only), `no` (static) or an
  empty string (a map, a switch or `any`).

Implementation notes:
- `x-crdkit-perTarget` is stored only for `no`; `yes` is an `anyOf`
  branch referencing a declaration definition (any `$ref` but
  markers); otherwise a scalar type is `markers`.
*/}}
{{- define "crdkit.schema.jsonPerTarget.internal" -}}
{{- $declaration := false -}}
{{- range $branch := .node.anyOf | default list -}}
  {{- $ref := $branch | default dict | dig "$ref" "" | toString -}}
  {{- if and $ref (ne $ref "#/definitions/markers") -}}
    {{- $declaration = true -}}
  {{- end -}}
{{- end -}}
{{- if hasKey .node "x-crdkit-perTarget" -}}
{{- index .node "x-crdkit-perTarget" -}}
{{- else if $declaration -}}
yes
{{- else if has (include "crdkit.schema.jsonType.internal" (dict "node" .node)) (list "string" "int" "number" "bool" "scalar") -}}
markers
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.mdType.internal (internal)

Spells the Type cell of a Markdown table row.

Interface:
- Params (dict): { "node": <JSON Schema node of crdkit.schema.jsonSchema> }
- Returns: plain text — the DSL type, `list of <items type>`, or `map, by
  `<key>`: <cases>`; enum, pattern and key pattern appended.
*/}}
{{- define "crdkit.schema.mdType.internal" -}}
{{- $node := .node -}}
{{- $core := $node -}}
{{- if hasKey $node "anyOf" -}}
  {{- $core = first $node.anyOf -}}
{{- end -}}
{{- $text := include "crdkit.schema.jsonType.internal" (dict "node" $node) -}}
{{- if hasKey $node "x-crdkit-switch" -}}
  {{- $switch := index $node "x-crdkit-switch" -}}
  {{- $text = printf "map, by `%s`: %s" $switch.by (join ", " $switch.cases) -}}
  {{- if hasKey $switch "unless" -}}
    {{- $text = printf "%s; unless `%s: %s`" $text $switch.unless.key (toJson $switch.unless.value) -}}
  {{- end -}}
{{- else if hasKey $core "items" -}}
  {{- $text = printf "list of %s" (include "crdkit.schema.jsonType.internal" (dict "node" $core.items)) -}}
{{- end -}}
{{- if hasKey $core "enum" -}}
  {{- $text = printf "%s, one of: %s" $text (join ", " ($core.enum | toStrings)) -}}
{{- end -}}
{{- if hasKey $core "pattern" -}}
  {{- $text = printf "%s, matches `%s`" $text $core.pattern -}}
{{- end -}}
{{- if hasKey $core "propertyNames" -}}
  {{- $text = printf "%s, keys match `%s`" $text $core.propertyNames.pattern -}}
{{- end -}}
{{- $text -}}
{{- end -}}

{{/*
crdkit.schema.mdDoc.internal (internal)

Returns the doc of a JSON Schema node without its sections.

Interface:
- Params (dict): { "node": <JSON Schema node> }
- Returns: the Markdown doc as plain text, empty when the node has none.

Implementation notes:
- `markdownDescription` is the doc followed by the rendered sections
  (crdkit.schema.jsonNode.internal); the sections are cut off again by
  rendering them the same way. Absent when equal to `description`.
*/}}
{{- define "crdkit.schema.mdDoc.internal" -}}
{{- $node := .node -}}
{{- $rendered := list -}}
{{- range $section := index $node "x-crdkit-sections" | default (list) -}}
  {{- $rendered = append $rendered (include "crdkit.schema.sectionMarkdown.internal" (dict "section" $section)) -}}
{{- end -}}
{{- index $node "markdownDescription" | default $node.description | default "" | toString | trimSuffix (join "\n\n" $rendered) | trim -}}
{{- end -}}

{{/*
crdkit.schema.mdRow.internal (internal)

Appends one table row (six cells: Key, Type, Per target, Default,
Required, Description) to acc.rows.

Interface:
- Params (dict): { "key": <text shown as the key>, "node": <JSON Schema
  node>, "defs": <JSON Schema definitions>, "required": <bool>,
  "shared": <bool>, "acc": <dict with a "rows" list, appended to in
  place> }
- Returns: nothing (mutating helper).

Implementation notes:
- Cells are escaped for a Markdown table (`|`, line breaks).
- A per-target node with closed declaration keys
  (crdkit.schema.jsonDeclaration.internal) links its Per target cell to the "Token declarations" section and
  names its annotations.
*/}}
{{- define "crdkit.schema.mdRow.internal" -}}
{{- $node := .node -}}
{{- $default := "" -}}
{{- if hasKey $node "default" -}}
  {{- $default = printf "`%s`" (toJson (index $node "default")) -}}
{{- end -}}
{{- $key := printf "`%s`" .key -}}
{{- if .shared -}}
  {{- $key = printf "%s (shared)" $key -}}
{{- end -}}
{{- $perTarget := include "crdkit.schema.jsonPerTarget.internal" (dict "node" $node) -}}
{{- $declaration := dict -}}
{{- include "crdkit.schema.jsonDeclaration.internal" (dict "node" $node "defs" .defs "out" $declaration) -}}
{{- if and (eq $perTarget "yes") (hasKey $declaration "targetKeys") -}}
  {{- $perTarget = "[yes](#token-declarations)" -}}
  {{- $annotations := list -}}
  {{- range $annotation := $declaration.annotations -}}
    {{- $annotations = append $annotations (printf "`%s`" $annotation) -}}
  {{- end -}}
  {{- if $annotations -}}
    {{- $perTarget = printf "%s, annotations: %s" $perTarget (join ", " $annotations) -}}
  {{- end -}}
{{- end -}}
{{- $cells := list $key (include "crdkit.schema.mdType.internal" (dict "node" $node)) $perTarget $default (ternary "yes" "" .required) (include "crdkit.schema.mdDoc.internal" (dict "node" $node)) -}}
{{- $escaped := list -}}
{{- range $cell := $cells -}}
  {{- $escaped = append $escaped ($cell | replace "\n" " " | replace "|" "\\|" | trim) -}}
{{- end -}}
{{- $_ := set .acc "rows" (append .acc.rows $escaped) -}}
{{- end -}}

{{/*
crdkit.schema.mdTable.internal (internal)

Renders rows of crdkit.schema.mdRow.internal as a Markdown table.

Interface:
- Params (dict): { "rows": <list of six-cell lists> }
- Returns: the table as plain text.

Implementation notes:
- Key and Type are always shown; Per target, Default, Required and
  Description only when at least one row has content.
*/}}
{{- define "crdkit.schema.mdTable.internal" -}}
{{- $names := list "Key" "Type" "Per target" "Default" "Required" "Description" -}}
{{- $used := list 0 1 -}}
{{- range $i := untilStep 2 6 1 -}}
  {{- $any := false -}}
  {{- range $row := $.rows -}}
    {{- if ne (index $row $i) "" -}}
      {{- $any = true -}}
    {{- end -}}
  {{- end -}}
  {{- if $any -}}
    {{- $used = append $used $i -}}
  {{- end -}}
{{- end -}}
{{- $header := list -}}
{{- $rule := list -}}
{{- range $i := $used -}}
  {{- $header = append $header (index $names $i) -}}
  {{- $rule = append $rule "---" -}}
{{- end -}}
{{- $lines := list (printf "| %s |" (join " | " $header)) (printf "| %s |" (join " | " $rule)) -}}
{{- range $row := .rows -}}
  {{- $cells := list -}}
  {{- range $i := $used -}}
    {{- $cells = append $cells (index $row $i) -}}
  {{- end -}}
  {{- $lines = append $lines (printf "| %s |" (join " | " $cells)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
crdkit.schema.generatedExample.internal (internal)

Derives the example of a node the example values do not reach.

Interface:
- Params (dict): { "node": <JSON Schema node>, "defs": <JSON Schema
  definitions>, "out": <dict, "has" (bool) and "value" are set in
  place> }
- Returns: nothing (mutating helper).

Implementation notes:
- `default`, else the first `enum` value, else by type: string/scalar
  `"text"`, int `1`, number `1.5`, bool `true`, list `[<items example>]`,
  map its properties' examples, any `{}`.
- A string or scalar with a `pattern` and no `default`/`enum` has none
  ("text" might not match); a map omits such properties.
- A per-target node (crdkit.schema.jsonPerTarget.internal `yes`)
  becomes `{default:
  <example>, prod: <example>}`; with closed declaration keys
  (crdkit.schema.jsonDeclaration.internal) without `prod`, the first target key replaces
  `prod`.
*/}}
{{- define "crdkit.schema.generatedExample.internal" -}}
{{- $node := .node -}}
{{- $core := $node -}}
{{- if hasKey $node "anyOf" -}}
  {{- $core = first $node.anyOf -}}
{{- end -}}
{{- $type := include "crdkit.schema.jsonType.internal" (dict "node" $node) -}}
{{- $has := true -}}
{{- $value := "" -}}
{{- if hasKey $node "default" -}}
  {{- $value = index $node "default" -}}
{{- else if hasKey $core "enum" -}}
  {{- $value = first $core.enum -}}
{{- else if and (has $type (list "string" "scalar")) (hasKey $core "pattern") -}}
  {{- $has = false -}}
{{- else if has $type (list "string" "scalar") -}}
  {{- $value = "text" -}}
{{- else if eq $type "int" -}}
  {{- $value = 1 -}}
{{- else if eq $type "number" -}}
  {{- $value = 1.5 -}}
{{- else if eq $type "bool" -}}
  {{- $value = true -}}
{{- else if eq $type "list" -}}
  {{- $item := dict -}}
  {{- include "crdkit.schema.generatedExample.internal" (dict "node" $core.items "defs" .defs "out" $item) -}}
  {{- $value = ternary (list $item.value) (list) $item.has -}}
{{- else if eq $type "map" -}}
  {{- $value = dict -}}
  {{- range $name := index $node "x-crdkit-order" | default (list) -}}
    {{- $child := dict -}}
    {{- include "crdkit.schema.generatedExample.internal" (dict "node" (index $node.properties $name) "defs" $.defs "out" $child) -}}
    {{- if $child.has -}}
      {{- $_ := set $value $name $child.value -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- $value = dict -}}
{{- end -}}
{{- if and $has (eq (include "crdkit.schema.jsonPerTarget.internal" (dict "node" $node)) "yes") -}}
  {{- $targetKey := "prod" -}}
  {{- $declaration := dict -}}
  {{- include "crdkit.schema.jsonDeclaration.internal" (dict "node" $node "defs" .defs "out" $declaration) -}}
  {{- $closed := $declaration.targetKeys | default list -}}
  {{- if and $closed (not (has "prod" $closed)) -}}
    {{- $targetKey = first $closed -}}
  {{- end -}}
  {{- $value = dict "default" $value $targetKey $value -}}
{{- end -}}
{{- $_ := set .out "has" $has -}}
{{- $_ := set .out "value" $value -}}
{{- end -}}

{{/*
crdkit.schema.mdCaseExample.internal (internal)

Builds the example block of a switch case.

Interface:
- Params (dict): { "node": <case definition>, "by": <switch key>,
  "value": <case value>, "pairs": <list of {keys, value}: the example
  values found at the switch node and the keys leading to each>,
  "labels": <list of key labels from the root to the switch node>,
  "defs": <JSON Schema definitions>, "out": <dict, "text" (YAML) and
  "generated" (bool) are set in place> }
- Returns: nothing (mutating helper).

Implementation notes:
- The matching example entries (their `by` key equals `value`), each
  wrapped in its ancestor keys and merged (`application: {services:
  {APP: …}}`).
- Without a match, the generated example of the case (see
  crdkit.schema.generatedExample.internal) with `by` set to the case
  value, wrapped in the key labels (`<ID>`).
*/}}
{{- define "crdkit.schema.mdCaseExample.internal" -}}
{{- $merged := dict -}}
{{- $generated := true -}}
{{- range $pair := .pairs -}}
  {{- if and (kindIs "map" $pair.value) (hasKey $pair.value $.by) (eq (toString (index $pair.value $.by)) $.value) -}}
    {{- $generated = false -}}
    {{- $wrapped := deepCopy $pair.value -}}
    {{- range $key := reverse $pair.keys -}}
      {{- $wrapped = dict $key $wrapped -}}
    {{- end -}}
    {{- $_ := mergeOverwrite $merged $wrapped -}}
  {{- end -}}
{{- end -}}
{{- if $generated -}}
  {{- $body := dict -}}
  {{- include "crdkit.schema.generatedExample.internal" (dict "node" .node "defs" .defs "out" $body) -}}
  {{- $wrapped := set $body.value .by .value -}}
  {{- range $label := reverse .labels -}}
    {{- $wrapped = dict $label $wrapped -}}
  {{- end -}}
  {{- $merged = $wrapped -}}
{{- end -}}
{{- $_ := set .out "text" ($merged | toYaml | trimSuffix "\n") -}}
{{- $_ := set .out "generated" $generated -}}
{{- end -}}

{{/*
crdkit.schema.mdSkeleton.internal (internal)

Appends the commented YAML skeleton lines of a node and its descendants.

Interface:
- Params (dict): { "name": <key text, "" for the root>, "node": <JSON
  Schema node>, "path": <node path>, "defs": <JSON Schema definitions>,
  "required": <bool>, "lead": <text before every line>, "pad":
  <indentation>, "acc": <dict with a "lines" list, appended to in place> }
- Returns: nothing (mutating helper).

Implementation notes:
- Each key line is `<key>:  # <type>[, required][, per target]`.
- A switch case is a `# <by>: <value>` line followed by the case's keys,
  commented out (`lead` grows by `# `): the cases are alternatives.
*/}}
{{- define "crdkit.schema.mdSkeleton.internal" -}}
{{- $node := .node -}}
{{- $acc := .acc -}}
{{- $lead := .lead -}}
{{- $pad := .pad -}}
{{- $path := .path -}}
{{- $defs := .defs -}}
{{- $core := $node -}}
{{- if hasKey $node "anyOf" -}}
  {{- $core = first $node.anyOf -}}
{{- end -}}
{{- $type := include "crdkit.schema.jsonType.internal" (dict "node" $node) -}}
{{- $childPad := $pad -}}
{{- if ne .name "" -}}
  {{- $short := $type -}}
  {{- if hasKey $node "x-crdkit-switch" -}}
    {{- $short = printf "map, by %s" (index $node "x-crdkit-switch").by -}}
  {{- else if hasKey $core "items" -}}
    {{- $short = printf "list of %s" (include "crdkit.schema.jsonType.internal" (dict "node" $core.items)) -}}
  {{- end -}}
  {{- $parts := list $short -}}
  {{- if .required -}}
    {{- $parts = append $parts "required" -}}
  {{- end -}}
  {{- if eq (include "crdkit.schema.jsonPerTarget.internal" (dict "node" $node)) "yes" -}}
    {{- $parts = append $parts "per target" -}}
  {{- end -}}
  {{- $_ := set $acc "lines" (append $acc.lines (printf "%s%s%s:  # %s" $lead $pad .name (join ", " $parts))) -}}
  {{- $childPad = printf "%s  " $pad -}}
{{- end -}}
{{- if hasKey $node "x-crdkit-switch" -}}
  {{- $switch := index $node "x-crdkit-switch" -}}
  {{- range $caseValue := $switch.cases -}}
    {{- $_ := set $acc "lines" (append $acc.lines (printf "%s%s# %s: %s" $lead $childPad $switch.by $caseValue)) -}}
    {{- $caseKey := printf "%s[%s=%s]" $path $switch.by $caseValue -}}
    {{- include "crdkit.schema.mdSkeleton.internal" (dict "name" "" "node" (index $defs $caseKey) "path" $caseKey "defs" $defs "required" false "lead" (printf "%s%s# " $lead $childPad) "pad" "" "acc" $acc) -}}
  {{- end -}}
{{- else if eq $type "map" -}}
  {{- $required := $node.required | default (list) -}}
  {{- range $name := index $node "x-crdkit-order" | default (list) -}}
    {{- include "crdkit.schema.mdSkeleton.internal" (dict "name" $name "node" (index $node.properties $name) "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $name)) "defs" $defs "required" (has $name $required) "lead" $lead "pad" $childPad "acc" $acc) -}}
  {{- end -}}
  {{- if kindIs "map" (index $node "additionalProperties") -}}
    {{- include "crdkit.schema.mdSkeleton.internal" (dict "name" (index $node "x-crdkit-keyLabel") "node" (index $node "additionalProperties") "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" "*")) "defs" $defs "required" false "lead" $lead "pad" $childPad "acc" $acc) -}}
  {{- end -}}
{{- else if hasKey $core "items" -}}
  {{- $items := $core.items -}}
  {{- if eq (include "crdkit.schema.jsonType.internal" (dict "node" $items)) "map" -}}
    {{- $_ := set $acc "lines" (append $acc.lines (printf "%s%s-" $lead $childPad)) -}}
    {{- include "crdkit.schema.mdSkeleton.internal" (dict "name" "" "node" $items "path" (printf "%s[]" $path) "defs" $defs "required" false "lead" $lead "pad" (printf "%s    " $pad) "acc" $acc) -}}
  {{- else -}}
    {{- $_ := set $acc "lines" (append $acc.lines (printf "%s%s- # %s" $lead $childPad (include "crdkit.schema.jsonType.internal" (dict "node" $items)))) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.mdNode.internal (internal)

Appends the Markdown section of a node and, recursively, of its
descendants to acc.sections.

Interface:
- Params (dict): { "node": <JSON Schema node>, "path": <node path>,
  "defs": <JSON Schema definitions>, "pairs": <list of {keys, value}:
  the example values at the node and the keys leading to each>,
  "labels": <list of key labels from the root>, "case": <{by, value},
  only for a switch case body, optional>, "acc": <dict with a
  "sections" list, appended to in place> }
- Returns: nothing (mutating helper).

Implementation notes:
- A section (`## <node path>`) is written for a map with keys, a switch
  case (always) and any node that has sections; it holds the doc, the
  keys table, a case's example and the node's sections.
- Examples follow crdkit.schema.mdCaseExample.internal.
*/}}
{{- define "crdkit.schema.mdNode.internal" -}}
{{- $node := .node -}}
{{- $path := .path -}}
{{- $defs := .defs -}}
{{- $acc := .acc -}}
{{- $pairs := .pairs | default (list) -}}
{{- $labels := .labels | default (list) -}}
{{- $case := index . "case" -}}
{{- $core := $node -}}
{{- if hasKey $node "anyOf" -}}
  {{- $core = first $node.anyOf -}}
{{- end -}}
{{- $type := include "crdkit.schema.jsonType.internal" (dict "node" $node) -}}
{{- $isSwitch := hasKey $node "x-crdkit-switch" -}}
{{- $isMap := and (eq $type "map") (not $isSwitch) -}}
{{- $names := index $node "x-crdkit-order" | default (list) -}}
{{- $props := $node.properties | default dict -}}
{{- $required := $node.required | default (list) -}}
{{- $valuesNode := index $node "additionalProperties" -}}
{{- $label := index $node "x-crdkit-keyLabel" | default "<key>" -}}
{{- $rows := dict "rows" (list) -}}
{{- if $isMap -}}
  {{- range $name := $names -}}
    {{- $child := index $props $name -}}
    {{- include "crdkit.schema.mdRow.internal" (dict "key" $name "node" $child "defs" $defs "required" (has $name $required) "shared" (eq (index $child "x-crdkit-shared" | default false | toString) "true") "acc" $rows) -}}
  {{- end -}}
  {{- if kindIs "map" $valuesNode -}}
    {{- include "crdkit.schema.mdRow.internal" (dict "key" $label "node" $valuesNode "defs" $defs "required" false "shared" false "acc" $rows) -}}
  {{- end -}}
{{- end -}}
{{- $nodeSections := index $node "x-crdkit-sections" | default (list) -}}
{{- if or $case $rows.rows $nodeSections -}}
  {{- $parts := list (printf "## %s" (ternary "(root)" (printf "`%s`" $path) (eq $path ""))) -}}
  {{- $doc := include "crdkit.schema.mdDoc.internal" (dict "node" $node) -}}
  {{- if $doc -}}
    {{- $parts = append $parts $doc -}}
  {{- end -}}
  {{- if $rows.rows -}}
    {{- $parts = append $parts (include "crdkit.schema.mdTable.internal" (dict "rows" $rows.rows)) -}}
  {{- end -}}
  {{- if $case -}}
    {{- $example := dict -}}
    {{- include "crdkit.schema.mdCaseExample.internal" (dict "node" $node "by" $case.by "value" $case.value "pairs" $pairs "labels" $labels "defs" $defs "out" $example) -}}
    {{- $parts = append $parts (printf "**Example**%s\n\n```yaml\n%s\n```" (ternary " (generated)" "" $example.generated) $example.text) -}}
  {{- end -}}
  {{- range $section := $nodeSections -}}
    {{- $parts = append $parts (include "crdkit.schema.sectionMarkdown.internal" (dict "section" $section)) -}}
  {{- end -}}
  {{- $_ := set $acc "sections" (append $acc.sections (join "\n\n" $parts)) -}}
{{- end -}}
{{- if $isSwitch -}}
  {{- $switch := index $node "x-crdkit-switch" -}}
  {{- range $caseValue := $switch.cases -}}
    {{- $caseKey := printf "%s[%s=%s]" $path $switch.by $caseValue -}}
    {{- include "crdkit.schema.mdNode.internal" (dict "node" (index $defs $caseKey) "path" $caseKey "defs" $defs "pairs" $pairs "labels" $labels "case" (dict "by" $switch.by "value" $caseValue) "acc" $acc) -}}
  {{- end -}}
{{- else if $isMap -}}
  {{- range $name := $names -}}
    {{- $next := list -}}
    {{- range $pair := $pairs -}}
      {{- if and (kindIs "map" $pair.value) (hasKey $pair.value $name) (not (kindIs "invalid" (index $pair.value $name))) -}}
        {{- $next = append $next (dict "keys" (append $pair.keys $name) "value" (index $pair.value $name)) -}}
      {{- end -}}
    {{- end -}}
    {{- include "crdkit.schema.mdNode.internal" (dict "node" (index $props $name) "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $name)) "defs" $defs "pairs" $next "labels" (append $labels $name) "acc" $acc) -}}
  {{- end -}}
  {{- if kindIs "map" $valuesNode -}}
    {{- $next := list -}}
    {{- range $pair := $pairs -}}
      {{- if kindIs "map" $pair.value -}}
        {{- range $entryKey, $entry := $pair.value -}}
          {{- if and (not (hasKey $props $entryKey)) (not (kindIs "invalid" $entry)) -}}
            {{- $next = append $next (dict "keys" (append $pair.keys $entryKey) "value" $entry) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- include "crdkit.schema.mdNode.internal" (dict "node" $valuesNode "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" "*")) "defs" $defs "pairs" $next "labels" (append $labels $label) "acc" $acc) -}}
  {{- end -}}
{{- else if hasKey $core "items" -}}
  {{- include "crdkit.schema.mdNode.internal" (dict "node" $core.items "path" (printf "%s[]" $path) "defs" $defs "pairs" (list) "labels" $labels "acc" $acc) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.order.internal (internal)

Derives the text position of every block-style key of a schema written
as YAML. Helm's fromYaml decodes into Go maps, so a parsed schema has no
key order; the text keeps it.

Interface:
- Params (dict): { "text": <schema as YAML text> }
- Returns: `{value: {<schema path>: <index>}}` — the path is the chain of
  YAML keys from the root (`properties.application.properties.services`,
  spelled by crdkit.schema.path.internal), the index counts block keys in
  text order from 0.

Implementation notes:
- Line scanner with an indentation stack. A key written inside a flow
  map or flow list (`{a: 1, b: 2}`, also across lines) has no entry.
- Lines inside a block scalar (`doc: |`, `>`) and lines of a block list
  item (`- …` with its continuation) are skipped, so `key:`-looking
  text there is never recorded.
- Expects the text of a schema that passed crdkit.schema.check; quoted
  multi-line scalars are not recognized.
*/}}
{{- define "crdkit.schema.order.internal" -}}
{{- $out := dict -}}
{{- $st := dict "indents" (list) "keys" (list) "skipAbove" -1 "flow" 0 "count" 0 -}}
{{- range $line := splitList "\n" (.text | default "") -}}
  {{- $content := regexReplaceAll "^ +" $line "" -}}
  {{- $indent := sub (len $line) (len $content) | int -}}
  {{- if or (eq $content "") (hasPrefix "#" $content) -}}
    {{/* blank or comment */}}
  {{- else if and (ge (int $st.skipAbove) 0) (gt $indent (int $st.skipAbove)) -}}
    {{/* inside a block scalar or a list item */}}
  {{- else -}}
    {{- $_ := set $st "skipAbove" -1 -}}
    {{- if gt (int $st.flow) 0 -}}
      {{- $bare := regexReplaceAll "\"[^\"]*\"|'[^']*'" $content "" -}}
      {{- $_ := set $st "flow" (sub (add (int $st.flow) (len (regexFindAll "[{\\[]" $bare -1))) (len (regexFindAll "[}\\]]" $bare -1)) | int) -}}
    {{- else if hasPrefix "-" $content -}}
      {{- $_ := set $st "skipAbove" $indent -}}
    {{- else if regexMatch "^(\"[^\"]*\"|'[^']*'|[^\\s\"'#{\\[|>-][^:]*?)\\s*:(\\s|$)" $content -}}
      {{- $key := regexReplaceAll "^(\"[^\"]*\"|'[^']*'|[^\\s\"'#{\\[|>-][^:]*?)\\s*:(\\s.*|)$" $content "${1}" | trimAll "\"'" -}}
      {{- $rest := regexReplaceAll "^(\"[^\"]*\"|'[^']*'|[^\\s\"'#{\\[|>-][^:]*?)\\s*:" $content "" -}}
      {{- $indents := list -}}
      {{- $keys := list -}}
      {{- range $i, $ind := $st.indents -}}
        {{- if lt (int $ind) $indent -}}
          {{- $indents = append $indents $ind -}}
          {{- $keys = append $keys (index $st.keys $i) -}}
        {{- end -}}
      {{- end -}}
      {{- $path := "" -}}
      {{- range $k := $keys -}}
        {{- $path = include "crdkit.schema.path.internal" (dict "path" $path "key" $k) -}}
      {{- end -}}
      {{- $path = include "crdkit.schema.path.internal" (dict "path" $path "key" $key) -}}
      {{- $_ := set $out $path $st.count -}}
      {{- $_ := set $st "count" (add (int $st.count) 1) -}}
      {{- $_ := set $st "indents" (append $indents $indent) -}}
      {{- $_ := set $st "keys" (append $keys $key) -}}
      {{- if regexMatch "^\\s*[|>][-+0-9]*\\s*(#.*)?$" $rest -}}
        {{- $_ := set $st "skipAbove" $indent -}}
      {{- else -}}
        {{- $bare := regexReplaceAll "\"[^\"]*\"|'[^']*'" $rest "" -}}
        {{- $_ := set $st "flow" (max 0 (sub (len (regexFindAll "[{\\[]" $bare -1)) (len (regexFindAll "[}\\]]" $bare -1))) | int) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
value:
{{ $out | toYaml | indent 2 }}
{{- end -}}

{{/*
crdkit.schema.orderedKeys.internal (internal)

Sorts map keys into schema text order.

Interface:
- Params (dict): { "keys": <list of strings>, "parentPath": <schema path
  of the map holding them>, "order": <crdkit.schema.order.internal's
  value> }
- Returns: YAML `{value: [<key>…]}` — keys with a text position by
  position, then the rest alphabetically.
*/}}
{{- define "crdkit.schema.orderedKeys.internal" -}}
{{- $parent := .parentPath -}}
{{- $order := .order -}}
{{- $tagged := list -}}
{{- range $key := .keys -}}
  {{- $at := include "crdkit.schema.path.internal" (dict "path" $parent "key" $key) -}}
  {{- $index := ternary (index $order $at | int) 99999999 (hasKey $order $at) -}}
  {{- $tagged = append $tagged (printf "%08d|%s" $index $key) -}}
{{- end -}}
{{- $sorted := list -}}
{{- range $item := sortAlpha $tagged -}}
  {{- $sorted = append $sorted (regexReplaceAll "^[0-9]{8}\\|" $item "") -}}
{{- end -}}
value: {{ $sorted | toYaml | nindent 2 }}
{{- end -}}

{{/*
crdkit.schema.ref.internal (internal)

Spells a definitions key as a JSON Schema `$ref`.

Interface:
- Params (dict): { "key": <definitions key> }
- Returns: `#/definitions/<key>` as plain text, the key escaped as a
  JSON Pointer segment (`~0`, `~1`) and a URI fragment (`%25`, `%22`,
  `%20`, `%23`, `%3C`, `%3E`).

Implementation notes:
- `[`/`]` stay literal: switch-case keys use them, and several parsers
  resolve `%5B`/`%5D` without percent-decoding.
*/}}
{{- define "crdkit.schema.ref.internal" -}}
{{- $key := .key | replace "~" "~0" | replace "/" "~1" | replace "%" "%25" | replace "\"" "%22" | replace " " "%20" | replace "#" "%23" | replace "<" "%3C" | replace ">" "%3E" -}}
{{- printf "#/definitions/%s" $key -}}
{{- end -}}

{{/*
crdkit.schema.examples.internal (internal)

Selects the example values that reach a child of a node.

Interface:
- Params (dict): { "node": <schema node>, "instances": <list of the
  example values found at the node>, "via": "property" | "values" |
  "items" | "case", "key": <property name / case value, for property
  and case>, "out": <dict, "instances" is set in place> }
- Returns: nothing (mutating helper).

Implementation notes:
- property: the value under `key` of every map instance; values: every
  entry of every map instance whose key is not a property of the node;
  items: every element of every list instance; case: the map instances
  whose `switch.by` value equals `key`.
- Null values are skipped; entries keep the maps' alphabetical order.
*/}}
{{- define "crdkit.schema.examples.internal" -}}
{{- $node := .node -}}
{{- $key := .key | default "" | toString -}}
{{- $found := list -}}
{{- range $inst := .instances -}}
  {{- if eq $.via "items" -}}
    {{- if kindIs "slice" $inst -}}
      {{- range $element := $inst -}}
        {{- if not (kindIs "invalid" $element) -}}
          {{- $found = append $found $element -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- else if kindIs "map" $inst -}}
    {{- if eq $.via "property" -}}
      {{- if and (hasKey $inst $key) (not (kindIs "invalid" (index $inst $key))) -}}
        {{- $found = append $found (index $inst $key) -}}
      {{- end -}}
    {{- else if eq $.via "values" -}}
      {{- range $entryKey, $entry := $inst -}}
        {{- if and (not (hasKey ($node.properties | default dict) $entryKey)) (not (kindIs "invalid" $entry)) -}}
          {{- $found = append $found $entry -}}
        {{- end -}}
      {{- end -}}
    {{- else if eq $.via "case" -}}
      {{- if and (hasKey $inst $node.switch.by) (eq (toString (index $inst $node.switch.by)) $key) -}}
        {{- $found = append $found $inst -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "instances" $found -}}
{{- end -}}

{{/*
crdkit.schema.sectionProblem.internal (internal)

Checks the shape of one documentation section.

Interface:
- Params (dict): { "section": <any> }
- Returns: the first problem as plain text, or an EMPTY string for a
  valid `{title, doc?, columns?, rows?, code?}` (`columns` strings,
  `rows` lists of strings as long as `columns`, `doc`/`code` strings).
*/}}
{{- define "crdkit.schema.sectionProblem.internal" -}}
{{- $section := .section -}}
{{- $found := list -}}
{{- if not (kindIs "map" $section) -}}
  {{- $found = append $found "a section must be a map" -}}
{{- else -}}
  {{- range $key, $_ := $section -}}
    {{- if not (has $key (list "title" "doc" "columns" "rows" "code")) -}}
      {{- $found = append $found (printf "unknown section key '%s'" $key) -}}
    {{- end -}}
  {{- end -}}
  {{- if not (and (kindIs "string" $section.title) (ne $section.title "")) -}}
    {{- $found = append $found "'title' must be a non-empty string" -}}
  {{- end -}}
  {{- range $key := list "doc" "code" -}}
    {{- if and (hasKey $section $key) (not (kindIs "string" (index $section $key))) -}}
      {{- $found = append $found (printf "'%s' must be a string" $key) -}}
    {{- end -}}
  {{- end -}}
  {{- $columns := 0 -}}
  {{- if hasKey $section "columns" -}}
    {{- if not (kindIs "slice" $section.columns) -}}
      {{- $found = append $found "'columns' must be a list of strings" -}}
    {{- else -}}
      {{- $columns = len $section.columns -}}
      {{- range $column := $section.columns -}}
        {{- if not (kindIs "string" $column) -}}
          {{- $found = append $found "'columns' must be a list of strings" -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if hasKey $section "rows" -}}
    {{- if not (and (kindIs "slice" $section.rows) (kindIs "slice" $section.columns)) -}}
      {{- $found = append $found "'rows' must be a list and need 'columns'" -}}
    {{- else -}}
      {{- range $i, $row := $section.rows -}}
        {{- $ok := kindIs "slice" $row -}}
        {{- if $ok -}}
          {{- range $cell := $row -}}
            {{- if not (kindIs "string" $cell) -}}
              {{- $ok = false -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
        {{- if not (and $ok (eq (len $row) $columns)) -}}
          {{- $found = append $found (printf "row %d must be a list of %d strings" $i $columns) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- first (append $found "") -}}
{{- end -}}

{{/*
crdkit.schema.sectionMarkdown.internal (internal)

Renders one valid documentation section as Markdown.

Interface:
- Params (dict): { "section": <valid section> }
- Returns: Markdown text — `**title**`, the doc, a table, a `yaml` code
  block; absent parts are skipped.
*/}}
{{- define "crdkit.schema.sectionMarkdown.internal" -}}
{{- $section := .section -}}
{{- $parts := list (printf "**%s**" $section.title) -}}
{{- if $section.doc -}}
  {{- $parts = append $parts ($section.doc | trim) -}}
{{- end -}}
{{- if $section.columns -}}
  {{- $rows := list -}}
  {{- $header := list -}}
  {{- $rule := list -}}
  {{- range $column := $section.columns -}}
    {{- $header = append $header ($column | replace "|" "\\|" | replace "\n" " ") -}}
    {{- $rule = append $rule "---" -}}
  {{- end -}}
  {{- $rows = list (printf "| %s |" (join " | " $header)) (printf "| %s |" (join " | " $rule)) -}}
  {{- range $row := $section.rows | default (list) -}}
    {{- $cells := list -}}
    {{- range $cell := $row -}}
      {{- $cells = append $cells ($cell | replace "|" "\\|" | replace "\n" " ") -}}
    {{- end -}}
    {{- $rows = append $rows (printf "| %s |" (join " | " $cells)) -}}
  {{- end -}}
  {{- $parts = append $parts (join "\n" $rows) -}}
{{- end -}}
{{- if $section.code -}}
  {{- $parts = append $parts (printf "```yaml\n%s\n```" ($section.code | trimSuffix "\n")) -}}
{{- end -}}
{{- join "\n\n" $parts -}}
{{- end -}}

{{/*
crdkit.schema.jsonNode.internal (internal)

Converts one schema node (and, recursively, its descendants) to a JSON
Schema node, see crdkit.schema.jsonSchema.

Interface:
- Params (dict): { "node": <checked node>, "schemaPath": <YAML key
  chain of the node in the schema text>, "nodePath": <node path: values
  path with `*` for a `values` key, `[]` for list items and
  `[<by>=<value>]` for a case>, "inTokens": <bool, an ancestor is
  per-target>, "instances": <list of example values at the node>,
  "order": <crdkit.schema.order.internal's value>, "sections": <{<node
  path>: [<valid section>]}>, "targetKeys": <inherited target keys,
  optional>, "acc": <dict with "definitions" and
  "paths", appended to in place>, "shared": <list of property names
  flagged x-crdkit-shared, optional>, "out": <dict, "result" is set to
  the JSON Schema node> }
- Returns: nothing (mutating helper).

Implementation notes:
- Structural keywords (`type`, `enum`, `pattern`, `not`, `items`,
  `properties` …) and annotation keywords (`description`, `default`,
  `examples`, `x-crdkit-*`) are collected apart. A per-target scalar or
  list wraps the structural part in `anyOf` with its declaration
  branch; the markers branch is added only where a marker could violate
  the structural part (an int/number/bool, or a string/scalar with
  `enum` or `pattern`): the render substitutes before it checks, the
  editor cannot. A plain string/scalar accepts a marker as a string; a
  list never holds one (substitution is text, a marker never becomes a
  list). A non-per-target marker-accepting scalar of the violable kind
  is `anyOf` [type, markers]; any other stays unwrapped. The
  annotations stay on the outer node.
- A static string/scalar carries `not: {$ref: markers}`, not a `$ref`
  to a static definition: draft-07 ignores keywords next to `$ref`
  (`enum`, `pattern`, `description`).
- Each switch case is stored in acc.definitions under its node path.
- With target keys in effect (the node's own `targetKeys`, else the
  inherited ones) a per-target node's declaration branch references a
  shared closed definition instead of `tokenDeclaration`
  (crdkit.schema.declarationRef.internal): the key names are closed,
  the values are not typed (the value pass checks them per target).
  Readers get the keys from that definition
  (crdkit.schema.jsonDeclaration.internal).
*/}}
{{- define "crdkit.schema.jsonNode.internal" -}}
{{- $node := .node -}}
{{- $sp := .schemaPath -}}
{{- $path := .nodePath -}}
{{- $acc := .acc -}}
{{- $order := .order -}}
{{- $sections := .sections -}}
{{- $instances := .instances | default (list) -}}
{{- $shared := .shared | default (list) -}}
{{- $inTokens := .inTokens -}}
{{- $targetKeys := .targetKeys -}}
{{- if hasKey $node "targetKeys" -}}
  {{- $targetKeys = $node.targetKeys -}}
{{- end -}}
{{- $_ := set $acc.paths $path true -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $isSwitch := hasKey $node "switch" -}}
{{- $type := $node.type | default "map" | toString -}}
{{- $tokens := include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- $meta := dict -}}
{{- $core := dict -}}
{{- if hasKey $node "default" -}}
  {{- $_ := set $meta "default" (index $node "default") -}}
{{- end -}}
{{- $nodeSections := ternary (index $sections $path) (list) (hasKey $sections $path) -}}
{{- $doc := $node.doc | default "" | toString | trim -}}
{{- if $doc -}}
  {{- $_ := set $meta "description" (regexReplaceAll "\\[([^\\]]*)\\]\\([^)]*\\)" $doc "${1}" | replace "`" "") -}}
{{- end -}}
{{- if or $doc $nodeSections -}}
  {{- $parts := ternary (list $doc) (list) (ne $doc "") -}}
  {{- range $section := $nodeSections -}}
    {{- $parts = append $parts (include "crdkit.schema.sectionMarkdown.internal" (dict "section" $section)) -}}
  {{- end -}}
  {{- $markdown := join "\n\n" $parts -}}
  {{- if ne $markdown ($meta.description | default "") -}}
    {{- $_ := set $meta "markdownDescription" $markdown -}}
  {{- end -}}
{{- end -}}
{{- if $nodeSections -}}
  {{- $_ := set $meta "x-crdkit-sections" $nodeSections -}}
{{- end -}}
{{- if and $instances (or (eq $path "") (not (or $isSwitch (has $shape (list "map" "list"))))) -}}
  {{- $seenExamples := dict -}}
  {{- $examples := list -}}
  {{- range $instance := $instances -}}
    {{- $id := toJson $instance -}}
    {{- if not (hasKey $seenExamples $id) -}}
      {{- $_ := set $seenExamples $id true -}}
      {{- $examples = append $examples $instance -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $meta "examples" $examples -}}
{{- end -}}
{{- if $isSwitch -}}
  {{- $by := $node.switch.by -}}
  {{- $cases := $node.switch.cases -}}
  {{- $caseValues := (include "crdkit.schema.orderedKeys.internal" (dict "keys" (keys $cases) "parentPath" (include "crdkit.schema.path.internal" (dict "path" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "switch")) "key" "cases")) "order" $order) | fromYaml).value -}}
  {{- $sharedKeys := list -}}
  {{- $first := ternary (index $cases (first $caseValues)) (dict) (gt (len $caseValues) 0) -}}
  {{- if and (gt (len $caseValues) 1) (kindIs "map" $first.properties) -}}
    {{- range $name, $property := $first.properties -}}
      {{- $same := true -}}
      {{- range $caseValue := $caseValues -}}
        {{- $other := index $cases $caseValue -}}
        {{- if not (and (kindIs "map" $other.properties) (hasKey $other.properties $name) (eq (toJson (index $other.properties $name)) (toJson $property))) -}}
          {{- $same = false -}}
        {{- end -}}
      {{- end -}}
      {{- if $same -}}
        {{- $sharedKeys = append $sharedKeys $name -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $allOf := list -}}
  {{- $refs := dict -}}
  {{- range $caseValue := $caseValues -}}
    {{- $caseKey := printf "%s[%s=%s]" $path $by $caseValue -}}
    {{- $ref := include "crdkit.schema.ref.internal" (dict "key" $caseKey) -}}
    {{- $caseInstances := dict -}}
    {{- include "crdkit.schema.examples.internal" (dict "node" $node "instances" $instances "via" "case" "key" $caseValue "out" $caseInstances) -}}
    {{- $caseOut := dict -}}
    {{- include "crdkit.schema.jsonNode.internal" (dict "node" (index $cases $caseValue) "schemaPath" (include "crdkit.schema.path.internal" (dict "path" (include "crdkit.schema.path.internal" (dict "path" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "switch")) "key" "cases")) "key" $caseValue)) "nodePath" $caseKey "inTokens" $inTokens "instances" $caseInstances.instances "order" $order "sections" $sections "targetKeys" $targetKeys "acc" $acc "shared" $sharedKeys "out" $caseOut) -}}
    {{- $_ := set $caseOut.result "x-crdkit-path" $caseKey -}}
    {{- $_ := set $acc.definitions $caseKey $caseOut.result -}}
    {{- $_ := set $refs $caseValue $ref -}}
    {{- $if := dict "properties" (dict $by (dict "const" $caseValue)) "required" (list $by) -}}
    {{- if hasKey $node.switch "unless" -}}
      {{- $_ := set $if.properties $node.switch.unless.key (dict "not" (dict "const" $node.switch.unless.value)) -}}
    {{- end -}}
    {{- $allOf = append $allOf (dict "if" $if "then" (dict "$ref" $ref)) -}}
  {{- end -}}
  {{- $_ := set $core "type" "object" -}}
  {{- $_ := set $core "required" (list $by) -}}
  {{- $_ := set $core "properties" (dict $by (dict "enum" $caseValues)) -}}
  {{- $_ := set $core "allOf" $allOf -}}
  {{- $_ := set $meta "x-crdkit-switch" (dict "by" $by "cases" $caseValues "refs" $refs) -}}
  {{- if hasKey $node.switch "unless" -}}
    {{- $_ := set (index $meta "x-crdkit-switch") "unless" (pick $node.switch.unless "key" "value") -}}
  {{- end -}}
{{- else if eq $shape "map" -}}
  {{- $_ := set $core "type" "object" -}}
  {{- $props := $node.properties | default dict -}}
  {{- if $props -}}
    {{- $propsSp := include "crdkit.schema.path.internal" (dict "path" $sp "key" "properties") -}}
    {{- $names := (include "crdkit.schema.orderedKeys.internal" (dict "keys" (keys $props) "parentPath" $propsSp "order" $order) | fromYaml).value -}}
    {{- $jsonProps := dict -}}
    {{- $required := list -}}
    {{- range $name := $names -}}
      {{- $child := index $props $name -}}
      {{- $childInstances := dict -}}
      {{- include "crdkit.schema.examples.internal" (dict "node" $node "instances" $instances "via" "property" "key" $name "out" $childInstances) -}}
      {{- $childOut := dict -}}
      {{- include "crdkit.schema.jsonNode.internal" (dict "node" $child "schemaPath" (include "crdkit.schema.path.internal" (dict "path" $propsSp "key" $name)) "nodePath" (include "crdkit.schema.path.internal" (dict "path" $path "key" $name)) "inTokens" $childInTokens "instances" $childInstances.instances "order" $order "sections" $sections "targetKeys" $targetKeys "acc" $acc "out" $childOut) -}}
      {{- if has $name $shared -}}
        {{- $_ := set $childOut.result "x-crdkit-shared" true -}}
      {{- end -}}
      {{- $_ := set $jsonProps $name $childOut.result -}}
      {{- if eq (toString $child.required) "true" -}}
        {{- $required = append $required $name -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $core "properties" $jsonProps -}}
    {{- if $required -}}
      {{- $_ := set $core "required" $required -}}
    {{- end -}}
    {{- $_ := set $meta "x-crdkit-order" $names -}}
  {{- end -}}
  {{- if hasKey $node "values" -}}
    {{- $childInstances := dict -}}
    {{- include "crdkit.schema.examples.internal" (dict "node" $node "instances" $instances "via" "values" "out" $childInstances) -}}
    {{- $childOut := dict -}}
    {{- include "crdkit.schema.jsonNode.internal" (dict "node" $node.values "schemaPath" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "values")) "nodePath" (include "crdkit.schema.path.internal" (dict "path" $path "key" "*")) "inTokens" $childInTokens "instances" $childInstances.instances "order" $order "sections" $sections "targetKeys" $targetKeys "acc" $acc "out" $childOut) -}}
    {{- $_ := set $core "additionalProperties" $childOut.result -}}
    {{- $_ := set $meta "x-crdkit-keyLabel" (($node.keys | default dict).label | default "<key>") -}}
  {{- else -}}
    {{- $_ := set $core "additionalProperties" false -}}
  {{- end -}}
  {{- if hasKey $node "keys" -}}
    {{- $_ := set $core "propertyNames" (dict "pattern" $node.keys.pattern) -}}
  {{- end -}}
{{- else if eq $shape "list" -}}
  {{- $_ := set $core "type" "array" -}}
  {{- $childInstances := dict -}}
  {{- include "crdkit.schema.examples.internal" (dict "node" $node "instances" $instances "via" "items" "out" $childInstances) -}}
  {{- $childOut := dict -}}
  {{- include "crdkit.schema.jsonNode.internal" (dict "node" ($node.items | default (dict "type" "any")) "schemaPath" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "items")) "nodePath" (printf "%s[]" $path) "inTokens" $childInTokens "instances" $childInstances.instances "order" $order "sections" $sections "targetKeys" $targetKeys "acc" $acc "out" $childOut) -}}
  {{- $_ := set $core "items" $childOut.result -}}
  {{- if not $tokens -}}
    {{- $_ := set $meta "x-crdkit-perTarget" "no" -}}
  {{- end -}}
{{- else if eq $shape "scalar" -}}
  {{- if eq $type "scalar" -}}
    {{- $_ := set $core "type" (list "string" "number" "boolean") -}}
  {{- else -}}
    {{- $_ := set $core "type" (get (dict "string" "string" "int" "integer" "number" "number" "bool" "boolean") $type) -}}
  {{- end -}}
  {{- range $key := list "enum" "pattern" -}}
    {{- if hasKey $node $key -}}
      {{- $_ := set $core $key (index $node $key) -}}
    {{- end -}}
  {{- end -}}
  {{- if and (eq (toString $node.static) "true") (has $type (list "string" "scalar")) -}}
    {{- $_ := set $core "not" (dict "$ref" "#/definitions/markers") -}}
  {{- end -}}
  {{- if and (not $tokens) (eq (toString $node.static) "true") -}}
    {{- $_ := set $meta "x-crdkit-perTarget" "no" -}}
  {{- end -}}
{{- end -}}
{{- $result := $meta -}}
{{- $wrapped := list -}}
{{- $violable := and (eq $shape "scalar") (ne (toString $node.static) "true") (or (has $type (list "int" "number" "bool")) (hasKey $node "enum") (hasKey $node "pattern")) -}}
{{- if and $tokens (has $shape (list "scalar" "list")) -}}
  {{- $ref := "#/definitions/tokenDeclaration" -}}
  {{- if kindIs "slice" $targetKeys -}}
    {{- $ref = include "crdkit.schema.declarationRef.internal" (dict "targetKeys" $targetKeys "annotations" ($node.annotations | default list) "acc" $acc) -}}
  {{- end -}}
  {{- $wrapped = list $core (dict "$ref" $ref) -}}
  {{- if $violable -}}
    {{- $wrapped = append $wrapped (dict "$ref" "#/definitions/markers") -}}
  {{- end -}}
{{- else if $violable -}}
  {{- $wrapped = list $core (dict "$ref" "#/definitions/markers") -}}
{{- end -}}
{{- if $wrapped -}}
  {{- $_ := set $result "anyOf" $wrapped -}}
{{- else -}}
  {{- range $key, $value := $core -}}
    {{- $_ := set $result $key $value -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "result" $result -}}
{{- end -}}

{{/*
crdkit.schema.jsonDeclaration.internal (internal)

Reads the closed declaration keys of a per-target JSON Schema node from
the shared definition its declaration branch references (see
crdkit.schema.declarationRef.internal).

Interface:
- Params (dict): { "node": <JSON Schema node>, "defs": <JSON Schema
  definitions>, "out": <dict, "targetKeys" and "annotations" (lists)
  are set in place; untouched for an open or non-per-target node> }
- Returns: nothing (mutating helper).

Implementation notes:
- The definition's `propertyNames.enum` is `<targetKeys>, default,
  match, <annotations>`: split on `default` and `match`.
*/}}
{{- define "crdkit.schema.jsonDeclaration.internal" -}}
{{- $defs := .defs | default dict -}}
{{- range $branch := .node.anyOf | default list -}}
  {{- $ref := $branch | default dict | dig "$ref" "" | toString -}}
  {{- $name := trimPrefix "#/definitions/" $ref -}}
  {{- $enum := dig "propertyNames" "enum" list (index $defs $name | default dict) -}}
  {{- if and $ref (has "default" $enum) (has "match" $enum) -}}
    {{- $targetKeys := list -}}
    {{- $annotations := list -}}
    {{- $part := "keys" -}}
    {{- range $key := $enum -}}
      {{- if eq $key "default" -}}
        {{- $part = "fixed" -}}
      {{- else if eq $key "match" -}}
        {{- $part = "annotations" -}}
      {{- else if eq $part "keys" -}}
        {{- $targetKeys = append $targetKeys $key -}}
      {{- else if eq $part "annotations" -}}
        {{- $annotations = append $annotations $key -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $.out "targetKeys" $targetKeys -}}
    {{- $_ := set $.out "annotations" $annotations -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.declarationRef.internal (internal)

Returns the `$ref` of the shared closed token declaration definition
for one key set, creating the definition on first use.

Interface:
- Params (dict): { "targetKeys": <list of target keys>, "annotations":
  <list of annotation keys>, "acc": <crdkit.schema.jsonNode.internal's
  acc: "definitions" written, "declarations" registry created> }
- Returns: plain text `#/definitions/<name>`.

Implementation notes:
- Definition: an object with at least one key, key names closed to the
  target keys, `default`, `match` and the annotations (`propertyNames`
  enum); `match` a list of single-key objects, annotations strings;
  other values untyped.
- Name: `targetDeclaration`, a number from the second distinct
  `targetKeys` set (`targetDeclaration2`), then `.<annotation>` per
  annotation. No `[`: never read as a switch case.
*/}}
{{- define "crdkit.schema.declarationRef.internal" -}}
{{- $acc := .acc -}}
{{- if not (hasKey $acc "declarations") -}}
  {{- $_ := set $acc "declarations" (dict "keySets" (dict) "names" (dict)) -}}
{{- end -}}
{{- $registry := $acc.declarations -}}
{{- $keysId := toJson .targetKeys -}}
{{- if not (hasKey $registry.keySets $keysId) -}}
  {{- $_ := set $registry.keySets $keysId (len $registry.keySets) -}}
{{- end -}}
{{- $index := index $registry.keySets $keysId -}}
{{- $name := ternary "targetDeclaration" (printf "targetDeclaration%d" (add1 $index)) (eq (int $index) 0) -}}
{{- range $annotation := .annotations -}}
  {{- $name = printf "%s.%s" $name $annotation -}}
{{- end -}}
{{- if not (hasKey $acc.definitions $name) -}}
  {{- $properties := dict "match" (dict "type" "array" "items" (dict "type" "object" "minProperties" 1 "maxProperties" 1)) -}}
  {{- range $annotation := .annotations -}}
    {{- $_ := set $properties $annotation (dict "type" "string") -}}
  {{- end -}}
  {{- $names := concat .targetKeys (list "default" "match") .annotations -}}
  {{- $_ := set $acc.definitions $name (dict "type" "object" "minProperties" 1 "propertyNames" (dict "enum" $names) "properties" $properties) -}}
{{- end -}}
{{- include "crdkit.schema.ref.internal" (dict "key" $name) -}}
{{- end -}}
