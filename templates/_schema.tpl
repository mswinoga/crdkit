{{/*
Values schema engine — scope (public/internal) is declared per template
below. A library supplies the schema (literal YAML from its own
defines); crdkit validates values against it, normalizes them, checks
per-target values and renders a Markdown reference.

Schema node (a dict):
- type: the value's shape and scalar type (omitted only on a "switch"
  node, a map):
  - string | int | number | bool — a scalar of that type
  - scalar — any scalar
  - map, list — that shape
  - any — everything, nothing below checked
- doc: Markdown text for the reference
- default: inserted when the key is absent (map properties only)
- required: bool — the key must be present
- required omitted = false; doc and default are optional
- scalar types: enum (list), pattern (regex, unanchored), markers
  (false → "@NAME@" markers rejected; omitted = true)
- scalar types and list: tokens (true → the value may be a token
  declaration, resolved per target). Omitted = true, except on a
  "markers: false" scalar and below a node that is per-target (see
  crdkit.schema.tokens.internal)
- map: properties ({key: node}), values (node for every other key;
  omitted = every other key is unknown), keys ({pattern, label?} for keys
  matched by "values"; label = documentation-only placeholder for a
  matched key, e.g. "<ID>")
- list: items (node for every element; omitted = {type: any})
- switch: {by: <key>, cases: {<value>: <node>}} — picks the node for a
  map by the value of one of its keys ("by", not "on": YAML 1.1, which
  Helm's fromYaml speaks, reads an `on:` key as the boolean true)

Diagnostics paths are dotted values paths: a key containing "." goes in
brackets (`a["b.c"]`), list elements are indexed (`a.b[0]`).

Dependency graph (who calls whom):

  crdkit.schema.validate (public)
    -> crdkit.schema.check (public) -> crdkit.schema.checkNode.internal
    -> crdkit.schema.walk.internal          (mode "structural")
         -> crdkit.schema.scalarReason.internal
  crdkit.schema.validateValues (public)
    -> crdkit.schema.check (public)
    -> crdkit.schema.valuesWalk.internal
         -> crdkit.schema.resolveAndCheck.internal
              -> crdkit.tokenDef.value / crdkit.tokens.substitute
              -> crdkit.schema.walk.internal (mode "resolved")
  crdkit.schema.value (public) -> crdkit.schema.resolveAndCheck.internal
  crdkit.schema.node (public)
  crdkit.schema.path (public) -> crdkit.schema.path.internal
  crdkit.schema.docs (public) -> crdkit.schema.docsNode.internal
  crdkit.schema.order.internal (internal) -> crdkit.schema.path.internal
  crdkit.schema.jsonSchema (public)
    -> crdkit.schema.check (public)
    -> crdkit.schema.order.internal
    -> crdkit.schema.sectionProblem.internal
    -> crdkit.schema.jsonNode.internal      (recursive)
         -> crdkit.schema.orderedKeys.internal
         -> crdkit.schema.examples.internal
         -> crdkit.schema.sectionMarkdown.internal
         -> crdkit.schema.ref.internal
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
crdkit.schema.path (public)

Builds the dotted values path of a location, as every schema
diagnostic and the "seen" dict spell it.

Interface:
- Params (dict): { "keys": <list of map keys / list indices from the
  root>, "path": <prefix, optional — "" at the root> }
- Returns: the path as plain text (`a.b`, `a["b.c"]`, `a.b[0]`).

Implementation notes:
- A number is a list index, anything else a map key (a string "0" is a
  key).
*/}}
{{- define "crdkit.schema.path" -}}
{{- $path := .path | default "" -}}
{{- range $key := .keys | default (list) -}}
  {{- if or (kindIs "int" $key) (kindIs "int64" $key) (kindIs "float64" $key) -}}
    {{- $path = include "crdkit.schema.path.internal" (dict "path" $path "index" (int $key)) -}}
  {{- else -}}
    {{- $path = include "crdkit.schema.path.internal" (dict "path" $path "key" (toString $key)) -}}
  {{- end -}}
{{- end -}}
{{- $path -}}
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
crdkit.schema.tokens.internal (internal)

Whether a node is per-target (its value may be a token declaration).

Interface:
- Params (dict): { "node": <node>, "inTokens": <bool, an ancestor is
  per-target> }
- Returns: the plain string `true`, or an EMPTY string.

Implementation notes:
- Only scalar-type and list nodes, never below a per-target ancestor.
- An explicit `tokens:` wins; omitted = true, except on a
  `markers: false` scalar (static by declaration).
*/}}
{{- define "crdkit.schema.tokens.internal" -}}
{{- $node := .node -}}
{{- if and (has (include "crdkit.schema.shape.internal" (dict "node" $node)) (list "scalar" "list")) (not .inTokens) -}}
  {{- if hasKey $node "tokens" -}}
    {{- if eq (toString $node.tokens) "true" -}}
true
    {{- end -}}
  {{- else if ne (toString $node.markers) "false" -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.checkNode.internal (internal)

Recursive self-check of one schema node; collects every problem.

Interface:
- Params (dict): { "node": <any>, "path": <schema path string>,
  "inTokens": <bool, an ancestor has tokens: true>, "problems": <dict
  with a "list" key, appended to in place> }
- Returns: nothing.
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
  {{- $allowed := list "doc" "default" "required" "type" "enum" "pattern" "markers" "tokens" "properties" "values" "keys" "items" "switch" -}}
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
    {{- if not (and (kindIs "map" $switch) (kindIs "string" $switch.by) (kindIs "map" $switch.cases) (eq (len $switch) 2)) -}}
      {{- $found = append $found "'switch' must be {by: <key>, cases: {<value>: <node>}}" -}}
    {{- else -}}
      {{- range $caseValue, $caseNode := $switch.cases -}}
        {{- $casePath := printf "%sswitch.cases.%s" $prefix $caseValue -}}
        {{- include "crdkit.schema.checkNode.internal" (dict "node" $caseNode "path" $casePath "inTokens" $inTokens "problems" $problems) -}}
        {{- $onNode := "" -}}
        {{- if and (kindIs "map" $caseNode) (kindIs "map" $caseNode.properties) -}}
          {{- $onNode = index $caseNode.properties $switch.by -}}
        {{- end -}}
        {{- if not (and (eq (include "crdkit.schema.shape.internal" (dict "node" $onNode)) "scalar") (eq (toString $onNode.markers) "false") (ne (toString $onNode.tokens) "true")) -}}
          {{- $found = append $found (printf "case '%s' must declare '%s' as a scalar type with 'markers: false'" $caseValue $switch.by) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- else if not $shape -}}
    {{- $found = append $found (printf "unknown type '%s'" $type) -}}
  {{- end -}}
  {{- $appliesTo := dict "enum" (list "scalar") "pattern" (list "scalar") "markers" (list "scalar") "tokens" (list "scalar" "list") "properties" (list "map") "values" (list "map") "keys" (list "map") "items" (list "list") -}}
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
  {{- range $flag := list "required" "markers" "tokens" -}}
    {{- if and (hasKey $node $flag) (not (kindIs "bool" (index $node $flag))) -}}
      {{- $found = append $found (printf "'%s' must be a bool" $flag) -}}
    {{- end -}}
  {{- end -}}
  {{- if eq (toString $node.tokens) "true" -}}
    {{- if $inTokens -}}
      {{- $found = append $found "'tokens: true' below another 'tokens: true'" -}}
    {{- end -}}
    {{- if eq (toString $node.markers) "false" -}}
      {{- $found = append $found "'tokens: true' and 'markers: false' exclude each other" -}}
    {{- end -}}
  {{- end -}}
  {{- if and (hasKey $node "default") (eq (toString $node.required) "true") -}}
    {{- $found = append $found "'default' and 'required: true' exclude each other" -}}
  {{- end -}}
  {{- if and (hasKey $node "keys") (not (and (kindIs "map" $node.keys) (kindIs "string" $node.keys.pattern))) -}}
    {{- $found = append $found "'keys' must be {pattern: <regex>}" -}}
  {{- else if and (hasKey $node "keys") (hasKey $node.keys "label") (not (kindIs "string" $node.keys.label)) -}}
    {{- $found = append $found "'keys.label' must be a string" -}}
  {{- end -}}
  {{- $childInTokens := or $inTokens (ne (include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens)) "") -}}
  {{- if hasKey $node "properties" -}}
    {{- if not (kindIs "map" $node.properties) -}}
      {{- $found = append $found "'properties' must be a map" -}}
    {{- else -}}
      {{- range $key, $child := $node.properties -}}
        {{- include "crdkit.schema.checkNode.internal" (dict "node" $child "path" (printf "%sproperties.%s" $prefix $key) "inTokens" $childInTokens "problems" $problems) -}}
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
crdkit.schema.check (public)

Self-checks a schema before it is used.

Interface:
- Params (dict): { "schema": <root node>, "diag": <dict> }
- Returns: the plain string `true` when the schema is valid, an EMPTY
  string otherwise (never `false` — a non-empty string is truthy).

Implementation notes:
- Each problem records an ERROR `schema invalid: <schema path>:
  <reason>` — once per message, however often the schema is checked.
- A schema that failed to parse (Helm's `fromYaml` error dict, a single
  `Error` key) is reported as such.
- Rules: known node keys only; a known type (or a switch); each key on a
  type it applies to; `tokens: true` only on a scalar type or `list`,
  never below another one, never with `markers: false`; never `default`
  together with `required: true`; every switch case declares the switch
  key as a scalar type with `markers: false`.
*/}}
{{- define "crdkit.schema.check" -}}
{{- $diag := .diag -}}
{{- $problems := dict "list" (list) -}}
{{- if and (kindIs "map" .schema) (hasKey .schema "Error") (eq (len .schema) 1) -}}
  {{- $_ := set $problems "list" (list (printf "schema invalid: (root): does not parse: %v" .schema.Error)) -}}
{{- else -}}
  {{- include "crdkit.schema.checkNode.internal" (dict "node" .schema "path" "" "inTokens" false "problems" $problems) -}}
{{- end -}}
{{- range $problem := $problems.list -}}
  {{- if not (has $problem $diag.errors) -}}
    {{- $_ := set $diag "errors" (append $diag.errors $problem) -}}
  {{- end -}}
{{- end -}}
{{- if not $problems.list -}}
true
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
crdkit.schema.walk.internal (internal)

Validates one value against one node, recursively.

Interface:
- Params (dict): { "node": <checked node>, "value": <any, never nil>,
  "path": <values path>, "diag": <dict>, "mode": "structural" |
  "resolved", "suffix": <text after the path in resolved-mode messages,
  e.g. " for target 'qa'">, "inTokens": <bool, an ancestor is
  per-target>, "out": <dict, written in place> }
- Returns: nothing; sets out.keep (bool) and out.value (structural:
  the normalized value — defaults applied, failing nodes dropped).

Implementation notes:
- Results travel through "out", not YAML: a YAML round-trip would turn
  every value into its decoded form at each level.
- structural mode: shape mismatch / unknown key / unmatched switch →
  WARNING; required / type / enum / pattern / markers / keys.pattern →
  ERROR; a node that fails is dropped (its parent's default then
  applies), a key failing "keys.pattern" with its value. A per-target
  node holding a dict is a token declaration: kept as written, checked
  by the value pass. A string holding "@NAME@" markers skips type/enum/pattern —
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
{{- $shapeLevel := ternary "errors" "warnings" $resolved -}}
{{- $tail := ternary "" " — ignored" $resolved -}}
{{- $_ := set $out "keep" true -}}
{{- $_ := set $out "value" $value -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $inTokens := .inTokens -}}
{{- $tokens := include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- $isDeclaration := and (not $resolved) $tokens (kindIs "map" $value) -}}
{{- if hasKey $node "switch" -}}
  {{- $switch := $node.switch -}}
  {{- $onPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $switch.by) -}}
  {{- if not (kindIs "map" $value) -}}
    {{- $_ := set $diag $shapeLevel (append (index $diag $shapeLevel) (printf "'%s'%s must be a map%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if kindIs "invalid" (index $value $switch.by) -}}
    {{- $_ := set $diag $shapeLevel (append (index $diag $shapeLevel) (printf "'%s'%s has no '%s'%s" $path $suffix $switch.by $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if not (hasKey $switch.cases (toString (index $value $switch.by))) -}}
    {{- $_ := set $diag $shapeLevel (append (index $diag $shapeLevel) (printf "'%s'%s has unknown value '%v'%s" $onPath $suffix (index $value $switch.by) $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- include "crdkit.schema.walk.internal" (dict "node" (index $switch.cases (toString (index $value $switch.by))) "value" $value "path" $path "diag" $diag "mode" $mode "suffix" $suffix "inTokens" $inTokens "out" $out) -}}
  {{- end -}}
{{- else if or (eq $shape "any") $isDeclaration -}}
  {{/* kept as written */}}
{{- else if eq $shape "scalar" -}}
  {{- if or (kindIs "map" $value) (kindIs "slice" $value) -}}
    {{- $_ := set $diag $shapeLevel (append (index $diag $shapeLevel) (printf "'%s'%s must be a scalar%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $hasMarkers := and (not $resolved) (kindIs "string" $value) (regexMatch "@[A-Za-z0-9_]+@" $value) -}}
    {{- if and $hasMarkers (eq (toString $node.markers) "false") -}}
      {{- $_ := set $diag "errors" (append $diag.errors (printf "'%s' must not contain '@NAME@' markers — ignored" $path)) -}}
      {{- $_ := set $out "keep" false -}}
    {{- else if not $hasMarkers -}}
      {{- $reason := include "crdkit.schema.scalarReason.internal" (dict "node" $node "value" $value "strict" (not $resolved)) -}}
      {{- if $reason -}}
        {{- if $resolved -}}
          {{- $_ := set $diag "errors" (append $diag.errors (printf "'%s'%s %s — got '%v'" $path $suffix $reason $value)) -}}
        {{- else -}}
          {{- $_ := set $diag "errors" (append $diag.errors (printf "'%s' %s — ignored" $path $reason)) -}}
        {{- end -}}
        {{- $_ := set $out "keep" false -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- else if eq $shape "list" -}}
  {{- if not (kindIs "slice" $value) -}}
    {{- $_ := set $diag $shapeLevel (append (index $diag $shapeLevel) (printf "'%s'%s must be a list%s" $path $suffix $tail)) -}}
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
        {{- include "crdkit.schema.walk.internal" (dict "node" $items "value" $element "path" $elementPath "diag" $diag "mode" $mode "suffix" $suffix "inTokens" $childInTokens "out" $elementOut) -}}
        {{- if $elementOut.keep -}}
          {{- $result = append $result $elementOut.value -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $out "value" $result -}}
  {{- end -}}
{{- else if eq $shape "map" -}}
  {{- if not (kindIs "map" $value) -}}
    {{- $_ := set $diag $shapeLevel (append (index $diag $shapeLevel) (printf "'%s'%s must be a map%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $properties := $node.properties | default dict -}}
    {{- $result := dict -}}
    {{- range $key, $child := $value -}}
      {{- $childPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $key) -}}
      {{- if not (kindIs "invalid" $child) -}}
        {{- $childNode := dict -}}
        {{- $badKey := false -}}
        {{- if hasKey $properties $key -}}
          {{- $childNode = index $properties $key -}}
        {{- else if hasKey $node "values" -}}
          {{- $childNode = $node.values -}}
          {{- $badKey = and (hasKey $node "keys") (not (mustRegexMatch $node.keys.pattern $key)) -}}
        {{- end -}}
        {{- if $badKey -}}
          {{- $_ := set $diag "errors" (append $diag.errors (printf "key '%s'%s must match '%s'%s" $childPath $suffix $node.keys.pattern $tail)) -}}
        {{- else if not $childNode -}}
          {{- $_ := set $diag "warnings" (append $diag.warnings (printf "'%s'%s is not a known key%s" $childPath $suffix $tail)) -}}
        {{- else -}}
          {{- $childOut := dict -}}
          {{- include "crdkit.schema.walk.internal" (dict "node" $childNode "value" $child "path" $childPath "diag" $diag "mode" $mode "suffix" $suffix "inTokens" $childInTokens "out" $childOut) -}}
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
          {{- $_ := set $diag "errors" (append $diag.errors (printf "'%s'%s is required" $childPath $suffix)) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $out "value" $result -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.validate (public)

Structural pass: validates values against a schema and returns them
normalized.

Interface:
- Params (dict): { "schema": <root node>, "values": <any>, "diag":
  <dict>, "path": <values path prefix, optional — "" at the root> }
- Returns YAML: { "value": <normalized values> } — defaults applied,
  every failing node dropped; the values unchanged when the schema
  itself is invalid (crdkit.schema.check, validation skipped).

Implementation notes:
- Severities and drop rules: see crdkit.schema.walk.internal.
- Per-target values (token declarations, "@NAME@" markers) are only
  checked by crdkit.schema.validateValues / crdkit.schema.value.
- A root value that fails its node comes back as an empty value of the
  node's shape ({} for a map).
*/}}
{{- define "crdkit.schema.validate" -}}
{{- $values := .values -}}
{{- if include "crdkit.schema.check" (dict "schema" .schema "diag" .diag) -}}
  {{- $out := dict -}}
  {{- if kindIs "invalid" .values -}}
    {{- $values = dict -}}
  {{- end -}}
  {{- include "crdkit.schema.walk.internal" (dict "node" .schema "value" $values "path" (.path | default "") "diag" .diag "mode" "structural" "out" $out) -}}
  {{- $values = $out.value -}}
  {{- if not $out.keep -}}
    {{- $values = ternary (list) (dict) (eq (include "crdkit.schema.shape.internal" (dict "node" .schema)) "list") -}}
  {{- end -}}
{{- end -}}
value: {{ $values | toYaml | nindent 2 }}
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
- Returns: nothing; sets out.value to the resolved value.

Implementation notes:
- A per-target node resolves through crdkit.tokenDef.value (field
  id = the values path); any other value through
  crdkit.tokens.substitute.
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
{{- if .tokens -}}
  {{- $value = (include "crdkit.tokenDef.value" (list $ctx .path .def $target) | fromYaml).value -}}
{{- else -}}
  {{- $value = include "crdkit.tokens.substitute" (list $ctx .def $target) -}}
{{- end -}}
{{- $_ := set .out "value" $value -}}
{{- $seenKey := printf "%s|%s" .path $target -}}
{{- if not (hasKey .seen $seenKey) -}}
  {{- $_ := set .seen $seenKey true -}}
  {{- $unresolved := and (kindIs "string" $value) (regexMatch "@[A-Za-z0-9_]+@" $value) -}}
  {{- if and (eq (len $ctx.diag.errors) $errorsBefore) (not $unresolved) (not (kindIs "invalid" $value)) -}}
    {{- include "crdkit.schema.walk.internal" (dict "node" $node "value" $value "path" .path "diag" $ctx.diag "mode" "resolved" "suffix" (printf " for target '%s'" $target) "out" (dict)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.valuesWalk.internal (internal)

Value pass over (normalized) values: finds every per-target value and
checks it for one target.

Interface:
- Params (dict): { "ctx": <ctx>, "node": <checked node>, "value":
  <any>, "path": <values path>, "target": <string>, "seen": <dict>,
  "inTokens": <bool, an ancestor is per-target> }
- Returns: nothing.

Implementation notes:
- Per-target values: the value of every per-target node
  (crdkit.schema.tokens.internal), and every string holding "@NAME@"
  markers.
- Follows only what the structural pass would keep: an unmatched switch,
  a shape mismatch or an unknown key is skipped silently (already
  reported there).
*/}}
{{- define "crdkit.schema.valuesWalk.internal" -}}
{{- $node := .node -}}
{{- $value := .value -}}
{{- $path := .path -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $inTokens := .inTokens -}}
{{- $tokens := include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- $common := dict "ctx" .ctx "target" .target "seen" .seen -}}
{{- if kindIs "invalid" $value -}}
{{- else if hasKey $node "switch" -}}
  {{- if kindIs "map" $value -}}
    {{- $selected := toString (index $value $node.switch.by) -}}
    {{- if and (not (kindIs "invalid" (index $value $node.switch.by))) (hasKey $node.switch.cases $selected) -}}
      {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" (index $node.switch.cases $selected) "value" $value "path" $path "inTokens" $inTokens) $common) -}}
    {{- end -}}
  {{- end -}}
{{- else if eq $shape "any" -}}
{{- else if or $tokens (and (eq $shape "scalar") (kindIs "string" $value) (regexMatch "@[A-Za-z0-9_]+@" $value)) -}}
  {{- include "crdkit.schema.resolveAndCheck.internal" (merge (dict "node" $node "def" $value "tokens" (ne $tokens "") "path" $path "out" (dict)) $common) -}}
{{- else if and (eq $shape "list") (kindIs "slice" $value) -}}
  {{- range $i, $element := $value -}}
    {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" ($node.items | default (dict "type" "any")) "value" $element "path" (include "crdkit.schema.path.internal" (dict "path" $path "index" $i)) "inTokens" $childInTokens) $common) -}}
  {{- end -}}
{{- else if and (eq $shape "map") (kindIs "map" $value) -}}
  {{- $properties := $node.properties | default dict -}}
  {{- range $key, $child := $value -}}
    {{- $childNode := dict -}}
    {{- if hasKey $properties $key -}}
      {{- $childNode = index $properties $key -}}
    {{- else if hasKey $node "values" -}}
      {{- $childNode = $node.values -}}
    {{- end -}}
    {{- if $childNode -}}
      {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" $childNode "value" $child "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $key)) "inTokens" $childInTokens) $common) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.validateValues (public)

Value pass: checks every per-target value in (normalized) values for one
target.

Interface:
- Params (dict): { "ctx": <ctx>, "schema": <root node>, "values":
  <normalized values, from crdkit.schema.validate>, "path": <values
  path prefix, optional>, "target": <optional — defaults to ctx.target>,
  "seen": <dict shared with crdkit.schema.value calls, optional> }
- Returns: nothing (records into ctx.diag, marks "seen").

Implementation notes:
- Per-target values: values of per-target nodes (resolved like a
  token) and strings holding "@NAME@" markers (substituted).
- Every violation is an ERROR naming the target: `'<path>' for target
  '<t>' must be of type 'int' — got '<v>'`; scalars are checked "parses
  as" (see crdkit.schema.scalarReason.internal).
- Resolving caches onto token declarations in "values" (`_value`/`_gen`,
  as crdkit.tokenDef.value does).
- Resolution substitutes markers now: tokens added to ctx after this
  call are not seen.
- Skipped when the schema is invalid (crdkit.schema.check).
*/}}
{{- define "crdkit.schema.validateValues" -}}
{{- $ctx := .ctx -}}
{{/* never `.seen | default dict`: an empty dict is falsy, so the caller's shared dict would be swapped for a fresh one. */}}
{{- $seen := ternary .seen (dict) (kindIs "map" .seen) -}}
{{- if include "crdkit.schema.check" (dict "schema" .schema "diag" $ctx.diag) -}}
  {{- include "crdkit.schema.valuesWalk.internal" (dict "ctx" $ctx "node" .schema "value" .values "path" (.path | default "") "target" (.target | default $ctx.target) "seen" $seen) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.value (public)

Resolves one field's value for a target and checks it against the
field's node — for library code that needs a value for a target other
than the render's own.

Interface:
- Params (dict): { "ctx": <ctx>, "node": <the field's node, see
  crdkit.schema.node>, "def": <the field's value as written>, "path":
  <its values path, see crdkit.schema.path>, "target": <optional —
  defaults to ctx.target>, "seen": <dict shared with
  crdkit.schema.validateValues, optional> }
- Returns YAML: { "value": <resolved value> }

Implementation notes:
- A per-target node or a string with markers is resolved and
  checked (once per path and target, see "seen"); any other value is
  returned as written — the structural pass already checked it.
- The node must come from a schema that passed crdkit.schema.check,
  through crdkit.schema.node (which makes its per-target state
  explicit — "node" alone cannot know its ancestors).
*/}}
{{- define "crdkit.schema.value" -}}
{{- $ctx := .ctx -}}
{{- $node := .node | default dict -}}
{{- $out := dict "value" .def -}}
{{- $tokens := include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" false) -}}
{{- if or $tokens (and (kindIs "string" .def) (regexMatch "@[A-Za-z0-9_]+@" .def)) -}}
  {{- include "crdkit.schema.resolveAndCheck.internal" (dict "ctx" $ctx "node" $node "def" .def "tokens" (ne $tokens "") "path" .path "target" (.target | default $ctx.target) "seen" (ternary .seen (dict) (kindIs "map" .seen)) "out" $out) -}}
{{- end -}}
value: {{ $out.value | toYaml | nindent 2 }}
{{- end -}}

{{/*
crdkit.schema.node (public)

Finds the node describing one location in values.

Interface:
- Params (dict): { "schema": <root node>, "values": <the values the
  location lives in — needed to follow a switch>, "keys": <list of map
  keys / list indices from the root> }
- Returns YAML: { "value": <node> } when found, `{}` otherwise.

Implementation notes:
- A returned scalar-type or list node carries an explicit `tokens:` — its
  per-target state depends on its ancestors.
- A switch is followed by the value of its "by" key at that location; a
  final switch node is returned as its selected case.
*/}}
{{- define "crdkit.schema.node" -}}
{{- $node := .schema -}}
{{- $value := .values -}}
{{- $none := index (dict) "none" -}}
{{- $found := true -}}
{{- $inTokens := false -}}
{{- range $key := concat (.keys | default (list)) (list "") -}}
  {{- if $found -}}
    {{- if and (kindIs "map" $node) (hasKey $node "switch") -}}
      {{- $by := "" -}}
      {{- if kindIs "map" $value -}}
        {{- $by = index $value $node.switch.by -}}
      {{- end -}}
      {{- if and (not (kindIs "invalid" $by)) (ne (toString $by) "") (hasKey $node.switch.cases (toString $by)) -}}
        {{- $node = index $node.switch.cases (toString $by) -}}
      {{- else -}}
        {{- $found = false -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and $found (ne (toString $key) "") -}}
    {{- $inTokens = or $inTokens (ne (include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens)) "") -}}
    {{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
    {{- if eq $shape "map" -}}
      {{- $properties := $node.properties | default dict -}}
      {{- if hasKey $properties (toString $key) -}}
        {{- $node = index $properties (toString $key) -}}
      {{- else if hasKey $node "values" -}}
        {{- $node = $node.values -}}
      {{- else -}}
        {{- $found = false -}}
      {{- end -}}
      {{- if kindIs "map" $value -}}
        {{- $value = index $value (toString $key) -}}
      {{- else -}}
        {{- $value = $none -}}
      {{- end -}}
    {{- else if and (eq $shape "list") (regexMatch "^[0-9]+$" (toString $key)) -}}
      {{- $node = $node.items | default (dict "type" "any") -}}
      {{- $index := int (toString $key) -}}
      {{- if and (kindIs "slice" $value) (lt $index (len $value)) -}}
        {{- $value = index $value $index -}}
      {{- else -}}
        {{- $value = $none -}}
      {{- end -}}
    {{- else -}}
      {{- $found = false -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if $found -}}
  {{- if has (include "crdkit.schema.shape.internal" (dict "node" $node)) (list "scalar" "list") -}}
    {{- $node = merge (dict "tokens" (ne (include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens)) "")) (omit $node "tokens") -}}
  {{- end -}}
value: {{ $node | toYaml | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.docsNode.internal (internal)

Collects reference-table rows for one node and its descendants.

Interface:
- Params (dict): { "node": <checked node>, "path": <docs path>,
  "inTokens": <bool, an ancestor is per-target>, "self": <bool, emit a
  row for the node itself>, "acc": <dict with
  "rows" and "sections" lists, appended to in place> }
- Returns: nothing.

Implementation notes:
- A "values" child is shown as `<path>.<key>`, list items as
  `<path>[]`.
- A switch node gets one row; each case is queued in acc.sections and
  rendered as its own table by crdkit.schema.docs.
*/}}
{{- define "crdkit.schema.docsNode.internal" -}}
{{- $node := .node -}}
{{- $path := .path -}}
{{- $acc := .acc -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $inTokens := .inTokens -}}
{{- $tokens := include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- if .self -}}
  {{- $typeText := $node.type | default "" | toString -}}
  {{- if hasKey $node "switch" -}}
    {{- $typeText = printf "map, by `%s`: %s" $node.switch.by (keys $node.switch.cases | sortAlpha | join ", ") -}}
  {{- end -}}
  {{- if hasKey $node "enum" -}}
    {{- $typeText = printf "%s, one of: %s" $typeText (join ", " ($node.enum | toStrings)) -}}
  {{- end -}}
  {{- if hasKey $node "pattern" -}}
    {{- $typeText = printf "%s, matches `%s`" $typeText $node.pattern -}}
  {{- end -}}
  {{- if hasKey $node "keys" -}}
    {{- $typeText = printf "%s, keys match `%s`" $typeText $node.keys.pattern -}}
  {{- end -}}
  {{- $perTarget := "" -}}
  {{- if $tokens -}}
    {{- $perTarget = "yes" -}}
  {{- else if eq (toString $node.markers) "false" -}}
    {{- $perTarget = "no" -}}
  {{- else if eq $shape "scalar" -}}
    {{- $perTarget = "markers" -}}
  {{- end -}}
  {{- $default := "" -}}
  {{- if hasKey $node "default" -}}
    {{- $default = printf "`%s`" (toJson (index $node "default")) -}}
  {{- end -}}
  {{- $required := ternary "yes" "" (eq (toString $node.required) "true") -}}
  {{- $doc := $node.doc | default "" | toString | replace "\n" " " | replace "|" "\\|" | trim -}}
  {{- $row := printf "| `%s` | %s | %s | %s | %s | %s |" $path ($typeText | replace "|" "\\|") $perTarget ($default | replace "|" "\\|") $required $doc -}}
  {{- $_ := set $acc "rows" (append $acc.rows $row) -}}
{{- end -}}
{{- if hasKey $node "switch" -}}
  {{- range $caseValue := keys $node.switch.cases | sortAlpha -}}
    {{- $_ := set $acc "sections" (append $acc.sections (dict "path" $path "by" $node.switch.by "case" $caseValue "node" (index $node.switch.cases $caseValue) "inTokens" $inTokens)) -}}
  {{- end -}}
{{- else if eq $shape "map" -}}
  {{- range $key, $child := $node.properties | default dict -}}
    {{- include "crdkit.schema.docsNode.internal" (dict "node" $child "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $key)) "inTokens" $childInTokens "self" true "acc" $acc) -}}
  {{- end -}}
  {{- if hasKey $node "values" -}}
    {{- include "crdkit.schema.docsNode.internal" (dict "node" $node.values "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" "<key>")) "inTokens" $childInTokens "self" true "acc" $acc) -}}
  {{- end -}}
{{- else if and (eq $shape "list") (hasKey $node "items") -}}
  {{- include "crdkit.schema.docsNode.internal" (dict "node" $node.items "path" (printf "%s[]" $path) "inTokens" $childInTokens "self" true "acc" $acc) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.docs (public)

Renders a schema as a Markdown values reference.

Interface:
- Params (dict): { "schema": <root node>, "title": <heading text,
  optional — default "Values"> }
- Returns: Markdown text — a `# <title>` heading, one table for the
  root (omitted when it has no rows), then one `## <path> with <by>:
  <case>` table per switch case; ends with a newline.

Implementation notes:
- Columns: Key (dotted path), Type (with enum / pattern / keys pattern,
  or the switch key and its cases), Per target (`yes` = may be a token declaration, `markers` = may hold
  "@NAME@" markers, `no` = static), Default, Required, Description
  (the node's `doc`, on one line).
- Keys are sorted alphabetically; a schema's own key order is not
  preserved (Go maps are unordered).
- Expects a schema that passed crdkit.schema.check.
*/}}
{{- define "crdkit.schema.docs" -}}
{{- $acc := dict "rows" (list) "sections" (list) -}}
{{- $header := list "| Key | Type | Per target | Default | Required | Description |" "| --- | --- | --- | --- | --- | --- |" -}}
{{- $lines := list (printf "# %s" (.title | default "Values")) "" -}}
{{- include "crdkit.schema.docsNode.internal" (dict "node" .schema "path" "" "self" false "acc" $acc) -}}
{{- if $acc.rows -}}
  {{- $lines = concat $lines $header $acc.rows -}}
{{- end -}}
{{- range $i := until 1000 -}}
  {{- if lt $i (len $acc.sections) -}}
    {{- $section := index $acc.sections $i -}}
    {{- $_ := set $acc "rows" (list) -}}
    {{- include "crdkit.schema.docsNode.internal" (dict "node" $section.node "path" $section.path "inTokens" $section.inTokens "self" false "acc" $acc) -}}
    {{- if ne (last $lines) "" -}}
      {{- $lines = append $lines "" -}}
    {{- end -}}
    {{- $heading := ternary (printf "`%s`" $section.path) "(root)" (ne $section.path "") -}}
    {{- $lines = append $lines (printf "## %s with `%s: %s`" $heading $section.by $section.case) -}}
    {{- $lines = append $lines "" -}}
    {{- $lines = concat $lines $header $acc.rows -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $lines }}
{{ end -}}

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
  JSON Pointer segment (`~0`, `~1`) and a URI fragment (`%25`, `%5B`,
  `%5D`, `%22`, `%20`, `%23`, `%3C`, `%3E`).
*/}}
{{- define "crdkit.schema.ref.internal" -}}
{{- $key := .key | replace "~" "~0" | replace "/" "~1" | replace "%" "%25" | replace "[" "%5B" | replace "]" "%5D" | replace "\"" "%22" | replace " " "%20" | replace "#" "%23" | replace "<" "%3C" | replace ">" "%3E" -}}
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
  path>: [<valid section>]}>, "acc": <dict with "definitions" and
  "paths", appended to in place>, "shared": <list of property names
  flagged x-crdkit-shared, optional>, "out": <dict, "result" is set to
  the JSON Schema node> }
- Returns: nothing (mutating helper).

Implementation notes:
- Structural keywords (`type`, `enum`, `pattern`, `not`, `items`,
  `properties` …) and annotation keywords (`description`, `default`,
  `examples`, `x-crdkit-*`) are collected apart. A per-target scalar or
  list, and a marker-accepting int/number/bool, wrap the structural part
  in `anyOf`; the annotations stay on the outer node.
- Each switch case is stored in acc.definitions under its node path.
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
{{- $_ := set $acc.paths $path true -}}
{{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
{{- $isSwitch := hasKey $node "switch" -}}
{{- $type := $node.type | default "map" | toString -}}
{{- $tokens := include "crdkit.schema.tokens.internal" (dict "node" $node "inTokens" $inTokens) -}}
{{- $childInTokens := or $inTokens (ne $tokens "") -}}
{{- $meta := dict "x-crdkit-type" $type -}}
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
  {{- $_ := set $meta "markdownDescription" (join "\n\n" $parts) -}}
{{- end -}}
{{- if $nodeSections -}}
  {{- $_ := set $meta "x-crdkit-sections" $nodeSections -}}
{{- end -}}
{{- if $instances -}}
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
    {{- include "crdkit.schema.jsonNode.internal" (dict "node" (index $cases $caseValue) "schemaPath" (include "crdkit.schema.path.internal" (dict "path" (include "crdkit.schema.path.internal" (dict "path" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "switch")) "key" "cases")) "key" $caseValue)) "nodePath" $caseKey "inTokens" $inTokens "instances" $caseInstances.instances "order" $order "sections" $sections "acc" $acc "shared" $sharedKeys "out" $caseOut) -}}
    {{- $_ := set $caseOut.result "x-crdkit-path" $caseKey -}}
    {{- $_ := set $acc.definitions $caseKey $caseOut.result -}}
    {{- $_ := set $refs $caseValue $ref -}}
    {{- $allOf = append $allOf (dict "if" (dict "properties" (dict $by (dict "const" $caseValue)) "required" (list $by)) "then" (dict "$ref" $ref)) -}}
  {{- end -}}
  {{- $_ := set $core "type" "object" -}}
  {{- $_ := set $core "required" (list $by) -}}
  {{- $_ := set $core "properties" (dict $by (dict "enum" $caseValues)) -}}
  {{- $_ := set $core "allOf" $allOf -}}
  {{- $_ := set $meta "x-crdkit-switch" (dict "by" $by "cases" $caseValues "refs" $refs) -}}
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
      {{- include "crdkit.schema.jsonNode.internal" (dict "node" $child "schemaPath" (include "crdkit.schema.path.internal" (dict "path" $propsSp "key" $name)) "nodePath" (include "crdkit.schema.path.internal" (dict "path" $path "key" $name)) "inTokens" $childInTokens "instances" $childInstances.instances "order" $order "sections" $sections "acc" $acc "out" $childOut) -}}
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
    {{- include "crdkit.schema.jsonNode.internal" (dict "node" $node.values "schemaPath" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "values")) "nodePath" (include "crdkit.schema.path.internal" (dict "path" $path "key" "*")) "inTokens" $childInTokens "instances" $childInstances.instances "order" $order "sections" $sections "acc" $acc "out" $childOut) -}}
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
  {{- include "crdkit.schema.jsonNode.internal" (dict "node" ($node.items | default (dict "type" "any")) "schemaPath" (include "crdkit.schema.path.internal" (dict "path" $sp "key" "items")) "nodePath" (printf "%s[]" $path) "inTokens" $childInTokens "instances" $childInstances.instances "order" $order "sections" $sections "acc" $acc "out" $childOut) -}}
  {{- $_ := set $core "items" $childOut.result -}}
  {{- $_ := set $meta "x-crdkit-perTarget" (ternary "yes" "no" (ne $tokens "")) -}}
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
  {{- if and (eq (toString $node.markers) "false") (has $type (list "string" "scalar")) -}}
    {{- $_ := set $core "not" (dict "pattern" "@[A-Za-z0-9_]+@") -}}
  {{- end -}}
  {{- $_ := set $meta "x-crdkit-perTarget" (ternary "yes" (ternary "no" "markers" (eq (toString $node.markers) "false")) (ne $tokens "")) -}}
{{- end -}}
{{- $result := $meta -}}
{{- $wrapped := list -}}
{{- if and $tokens (has $shape (list "scalar" "list")) -}}
  {{- $wrapped = list $core (dict "$ref" "#/definitions/tokenDeclaration") (dict "$ref" "#/definitions/markers") -}}
{{- else if and (eq $shape "scalar") (ne (toString $node.markers) "false") (has $type (list "int" "number" "bool")) -}}
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
crdkit.schema.jsonSchema (public)

Generates the JSON Schema (draft-07, `x-crdkit-*` extensions) of a
values schema, for editors and the HTML viewer.

Interface:
- Params (dict): { "schemaText": <schema as YAML text>, "example":
  <example values, optional>, "sections": <{<node path>: [<section>]}>,
  optional>, "title": <root title, optional — default "Values">,
  "diag": <dict> }
- Returns: the JSON Schema as pretty-printed JSON text; `{}` when the
  schema fails crdkit.schema.check (its ERRORs are recorded).

Implementation notes:
- The schema arrives as text because key order lives only there
  (crdkit.schema.order.internal); the text is parsed here.
- Examples: every node gets `examples`, the unique example values found
  at its path (see crdkit.schema.examples.internal). Generated examples
  for unreached nodes are not stored: the viewer and the Markdown derive
  them.
- Sections attach to the node named by their node path (values path with
  `*` for a `values` key, `[]` for list items, `[<by>=<value>]` for a
  case). A malformed section or a path naming no node records an ERROR
  and is dropped. crdkit never interprets a section's content.
- Output is encoded by toPrettyJson: `<`, `>` and `&` appear as
  `<`, `>` and `&` (valid JSON).
*/}}
{{- define "crdkit.schema.jsonSchema" -}}
{{- $diag := .diag -}}
{{- $schema := .schemaText | default "" | fromYaml -}}
{{- $root := dict -}}
{{- if include "crdkit.schema.check" (dict "schema" $schema "diag" $diag) -}}
  {{- $order := (include "crdkit.schema.order.internal" (dict "text" .schemaText) | fromYaml).value -}}
  {{- $example := (dict "v" .example | toYaml | fromYaml).v -}}
  {{- $given := (dict "v" (.sections | default dict) | toYaml | fromYaml).v -}}
  {{- $sections := dict -}}
  {{- $problems := list -}}
  {{- range $sectionPath := keys $given | sortAlpha -}}
    {{- $list := index $given $sectionPath -}}
    {{- if not (kindIs "slice" $list) -}}
      {{- $problems = append $problems (printf "sections: '%s' must be a list of sections — dropped" $sectionPath) -}}
    {{- else -}}
      {{- $valid := list -}}
      {{- range $i, $section := $list -}}
        {{- $why := include "crdkit.schema.sectionProblem.internal" (dict "section" $section) -}}
        {{- if $why -}}
          {{- $problems = append $problems (printf "sections: '%s'[%d]: %s — dropped" $sectionPath $i $why) -}}
        {{- else -}}
          {{- $valid = append $valid $section -}}
        {{- end -}}
      {{- end -}}
      {{- $_ := set $sections $sectionPath $valid -}}
    {{- end -}}
  {{- end -}}
  {{- $acc := dict "definitions" (dict "tokenDeclaration" (dict "type" "object" "minProperties" 1) "markers" (dict "type" "string" "pattern" "@[A-Za-z0-9_]+@")) "paths" (dict) -}}
  {{- $out := dict -}}
  {{- include "crdkit.schema.jsonNode.internal" (dict "node" $schema "schemaPath" "" "nodePath" "" "inTokens" false "instances" (ternary (list $example) (list) (kindIs "map" $example)) "order" $order "sections" $sections "acc" $acc "out" $out) -}}
  {{- range $sectionPath := keys $sections | sortAlpha -}}
    {{- if not (hasKey $acc.paths $sectionPath) -}}
      {{- $problems = append $problems (printf "sections: '%s' names no node — dropped" $sectionPath) -}}
    {{- end -}}
  {{- end -}}
  {{- range $problem := $problems -}}
    {{- if not (has $problem $diag.errors) -}}
      {{- $_ := set $diag "errors" (append $diag.errors $problem) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $root "$schema" "http://json-schema.org/draft-07/schema#" -}}
  {{- $_ := set $root "title" (.title | default "Values") -}}
  {{- range $key, $value := $out.result -}}
    {{- $_ := set $root $key $value -}}
  {{- end -}}
  {{- $_ := set $root "definitions" $acc.definitions -}}
{{- end -}}
{{ $root | toPrettyJson }}
{{ end -}}
