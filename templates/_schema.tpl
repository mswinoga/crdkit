{{/*
Values schema engine — scope (public/internal) is declared per template
below. A library supplies the schema (literal YAML from its own
defines); crdkit validates values against it, normalizes them, checks
per-target values and renders a Markdown reference.

Schema node (a dict):
- kind: scalar | map | list | any (omitted only on a "switch" node)
- doc: Markdown text for the reference
- default: inserted when the key is absent (map properties only)
- required: bool — the key must be present
- scalar: type (string | int | number | bool), enum (list), pattern
  (regex, unanchored), markers (false → "@NAME@" markers rejected)
- scalar/list: tokens (true → the value may be a token declaration,
  resolved per target)
- map: properties ({key: node}), values (node for every other key),
  keys ({pattern} for keys matched by "values")
- list: items (node for every element; omitted = {kind: any})
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
  crdkit.schema.docs (public) -> crdkit.schema.docsNode.internal
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
  {{- $allowed := list "kind" "doc" "default" "required" "type" "enum" "pattern" "markers" "tokens" "properties" "values" "keys" "items" "switch" -}}
  {{- range $key, $_ := $node -}}
    {{- if not (has $key $allowed) -}}
      {{- $found = append $found (printf "unknown schema key '%s'" $key) -}}
    {{- end -}}
  {{- end -}}
  {{- $kind := $node.kind | default "" | toString -}}
  {{- if hasKey $node "switch" -}}
    {{- if and $kind (ne $kind "map") -}}
      {{- $found = append $found (printf "'switch' requires kind 'map', got '%s'" $kind) -}}
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
        {{- if not (and (kindIs "map" $onNode) (eq (toString $onNode.kind) "scalar") (eq (toString $onNode.markers) "false") (not $onNode.tokens)) -}}
          {{- $found = append $found (printf "case '%s' must declare '%s' as kind 'scalar' with 'markers: false'" $caseValue $switch.by) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- else if not (has $kind (list "scalar" "map" "list" "any")) -}}
    {{- $found = append $found (printf "unknown kind '%s'" $kind) -}}
  {{- end -}}
  {{- $appliesTo := dict "type" (list "scalar") "enum" (list "scalar") "pattern" (list "scalar") "markers" (list "scalar") "tokens" (list "scalar" "list") "properties" (list "map") "values" (list "map") "keys" (list "map") "items" (list "list") -}}
  {{- if $kind -}}
    {{- range $key, $kinds := $appliesTo -}}
      {{- if and (hasKey $node $key) (not (has $kind $kinds)) -}}
        {{- $found = append $found (printf "'%s' does not apply to kind '%s'" $key $kind) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and (hasKey $node "type") (not (has (toString $node.type) (list "string" "int" "number" "bool"))) -}}
    {{- $found = append $found (printf "unknown type '%v'" $node.type) -}}
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
  {{- end -}}
  {{- $childInTokens := or $inTokens (eq (toString $node.tokens) "true") -}}
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
- Rules: known node keys only; a known kind (or a switch); each key on a
  kind it applies to; `tokens: true` only on scalar/list, never below
  another one, never with `markers: false`; never `default` together
  with `required: true`; every switch case declares the switch key as
  `kind: scalar, markers: false`.
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
- Params (dict): { "node": <scalar node>, "value": <scalar>, "strict":
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
  e.g. " for target 'qa'">, "out": <dict, written in place> }
- Returns: nothing; sets out.keep (bool) and out.value (structural:
  the normalized value — defaults applied, failing nodes dropped).

Implementation notes:
- Results travel through "out", not YAML: a YAML round-trip would turn
  every value into its decoded form at each level.
- structural mode: kind mismatch / unknown key / unmatched switch →
  WARNING; required / type / enum / pattern / markers → ERROR; a node
  that fails is dropped (its parent's default then applies); a key
  failing "keys.pattern" → WARNING, kept. A "tokens: true" node holding
  a dict is a token declaration: kept as written, checked by the value
  pass. A string holding "@NAME@" markers skips type/enum/pattern —
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
{{- $kindLevel := ternary "errors" "warnings" $resolved -}}
{{- $tail := ternary "" " — ignored" $resolved -}}
{{- $_ := set $out "keep" true -}}
{{- $_ := set $out "value" $value -}}
{{- $kind := $node.kind | default "" | toString -}}
{{- $isDeclaration := and (not $resolved) (eq (toString $node.tokens) "true") (kindIs "map" $value) -}}
{{- if hasKey $node "switch" -}}
  {{- $switch := $node.switch -}}
  {{- $onPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $switch.by) -}}
  {{- if not (kindIs "map" $value) -}}
    {{- $_ := set $diag $kindLevel (append (index $diag $kindLevel) (printf "'%s'%s must be a map%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if kindIs "invalid" (index $value $switch.by) -}}
    {{- $_ := set $diag $kindLevel (append (index $diag $kindLevel) (printf "'%s'%s has no '%s'%s" $path $suffix $switch.by $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else if not (hasKey $switch.cases (toString (index $value $switch.by))) -}}
    {{- $_ := set $diag $kindLevel (append (index $diag $kindLevel) (printf "'%s'%s has unknown value '%v'%s" $onPath $suffix (index $value $switch.by) $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- include "crdkit.schema.walk.internal" (dict "node" (index $switch.cases (toString (index $value $switch.by))) "value" $value "path" $path "diag" $diag "mode" $mode "suffix" $suffix "out" $out) -}}
  {{- end -}}
{{- else if or (eq $kind "any") $isDeclaration -}}
  {{/* kept as written */}}
{{- else if eq $kind "scalar" -}}
  {{- if or (kindIs "map" $value) (kindIs "slice" $value) -}}
    {{- $_ := set $diag $kindLevel (append (index $diag $kindLevel) (printf "'%s'%s must be a scalar%s" $path $suffix $tail)) -}}
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
{{- else if eq $kind "list" -}}
  {{- if not (kindIs "slice" $value) -}}
    {{- $_ := set $diag $kindLevel (append (index $diag $kindLevel) (printf "'%s'%s must be a list%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $items := $node.items | default (dict "kind" "any") -}}
    {{- $result := list -}}
    {{- range $i, $element := $value -}}
      {{- $elementPath := include "crdkit.schema.path.internal" (dict "path" $path "index" $i) -}}
      {{- if kindIs "invalid" $element -}}
        {{- $result = append $result $element -}}
      {{- else -}}
        {{- $elementOut := dict -}}
        {{- include "crdkit.schema.walk.internal" (dict "node" $items "value" $element "path" $elementPath "diag" $diag "mode" $mode "suffix" $suffix "out" $elementOut) -}}
        {{- if $elementOut.keep -}}
          {{- $result = append $result $elementOut.value -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $out "value" $result -}}
  {{- end -}}
{{- else if eq $kind "map" -}}
  {{- if not (kindIs "map" $value) -}}
    {{- $_ := set $diag $kindLevel (append (index $diag $kindLevel) (printf "'%s'%s must be a map%s" $path $suffix $tail)) -}}
    {{- $_ := set $out "keep" false -}}
  {{- else -}}
    {{- $properties := $node.properties | default dict -}}
    {{- $result := dict -}}
    {{- range $key, $child := $value -}}
      {{- $childPath := include "crdkit.schema.path.internal" (dict "path" $path "key" $key) -}}
      {{- if not (kindIs "invalid" $child) -}}
        {{- $childNode := dict -}}
        {{- if hasKey $properties $key -}}
          {{- $childNode = index $properties $key -}}
        {{- else if hasKey $node "values" -}}
          {{- $childNode = $node.values -}}
          {{- if and (hasKey $node "keys") (not (mustRegexMatch $node.keys.pattern $key)) -}}
            {{- $_ := set $diag "warnings" (append $diag.warnings (printf "key '%s'%s must match '%s'" $childPath $suffix $node.keys.pattern)) -}}
          {{- end -}}
        {{- end -}}
        {{- if not $childNode -}}
          {{- $_ := set $diag "warnings" (append $diag.warnings (printf "'%s'%s is not a known key%s" $childPath $suffix $tail)) -}}
        {{- else -}}
          {{- $childOut := dict -}}
          {{- include "crdkit.schema.walk.internal" (dict "node" $childNode "value" $child "path" $childPath "diag" $diag "mode" $mode "suffix" $suffix "out" $childOut) -}}
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
  node's kind ({} for a map).
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
    {{- $values = ternary (list) (dict) (eq (toString .schema.kind) "list") -}}
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
  markers>, "path": <values path>, "target": <string>, "seen": <dict>,
  "out": <dict, written in place> }
- Returns: nothing; sets out.value to the resolved value.

Implementation notes:
- A "tokens: true" node resolves through crdkit.tokenDef.value (field
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
{{- if eq (toString $node.tokens) "true" -}}
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
  <any>, "path": <values path>, "target": <string>, "seen": <dict> }
- Returns: nothing.

Implementation notes:
- Per-target values: anything under a "tokens: true" node, and every
  string holding "@NAME@" markers.
- Follows only what the structural pass would keep: an unmatched switch,
  a kind mismatch or an unknown key is skipped silently (already
  reported there).
*/}}
{{- define "crdkit.schema.valuesWalk.internal" -}}
{{- $node := .node -}}
{{- $value := .value -}}
{{- $path := .path -}}
{{- $kind := $node.kind | default "" | toString -}}
{{- $common := dict "ctx" .ctx "target" .target "seen" .seen -}}
{{- if kindIs "invalid" $value -}}
{{- else if hasKey $node "switch" -}}
  {{- if kindIs "map" $value -}}
    {{- $selected := toString (index $value $node.switch.by) -}}
    {{- if and (not (kindIs "invalid" (index $value $node.switch.by))) (hasKey $node.switch.cases $selected) -}}
      {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" (index $node.switch.cases $selected) "value" $value "path" $path) $common) -}}
    {{- end -}}
  {{- end -}}
{{- else if eq $kind "any" -}}
{{- else if or (eq (toString $node.tokens) "true") (and (eq $kind "scalar") (kindIs "string" $value) (regexMatch "@[A-Za-z0-9_]+@" $value)) -}}
  {{- include "crdkit.schema.resolveAndCheck.internal" (merge (dict "node" $node "def" $value "path" $path "out" (dict)) $common) -}}
{{- else if and (eq $kind "list") (kindIs "slice" $value) -}}
  {{- range $i, $element := $value -}}
    {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" ($node.items | default (dict "kind" "any")) "value" $element "path" (include "crdkit.schema.path.internal" (dict "path" $path "index" $i))) $common) -}}
  {{- end -}}
{{- else if and (eq $kind "map") (kindIs "map" $value) -}}
  {{- $properties := $node.properties | default dict -}}
  {{- range $key, $child := $value -}}
    {{- $childNode := dict -}}
    {{- if hasKey $properties $key -}}
      {{- $childNode = index $properties $key -}}
    {{- else if hasKey $node "values" -}}
      {{- $childNode = $node.values -}}
    {{- end -}}
    {{- if $childNode -}}
      {{- include "crdkit.schema.valuesWalk.internal" (merge (dict "node" $childNode "value" $child "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $key))) $common) -}}
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
- Per-target values: values under a "tokens: true" node (resolved like
  a token) and strings holding "@NAME@" markers (substituted).
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
  <its values path>, "target": <optional — defaults to ctx.target>,
  "seen": <dict shared with crdkit.schema.validateValues, optional> }
- Returns YAML: { "value": <resolved value> }

Implementation notes:
- A "tokens: true" node or a string with markers is resolved and
  checked (once per path and target, see "seen"); any other value is
  returned as written — the structural pass already checked it.
- The node must come from a schema that passed crdkit.schema.check.
*/}}
{{- define "crdkit.schema.value" -}}
{{- $ctx := .ctx -}}
{{- $node := .node | default dict -}}
{{- $out := dict "value" .def -}}
{{- if or (eq (toString $node.tokens) "true") (and (kindIs "string" .def) (regexMatch "@[A-Za-z0-9_]+@" .def)) -}}
  {{- include "crdkit.schema.resolveAndCheck.internal" (dict "ctx" $ctx "node" $node "def" .def "path" .path "target" (.target | default $ctx.target) "seen" (ternary .seen (dict) (kindIs "map" .seen)) "out" $out) -}}
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
- A switch is followed by the value of its "by" key at that location; a
  final switch node is returned as its selected case.
*/}}
{{- define "crdkit.schema.node" -}}
{{- $node := .schema -}}
{{- $value := .values -}}
{{- $none := index (dict) "none" -}}
{{- $found := true -}}
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
    {{- $kind := $node.kind | default "" | toString -}}
    {{- if eq $kind "map" -}}
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
    {{- else if and (eq $kind "list") (regexMatch "^[0-9]+$" (toString $key)) -}}
      {{- $node = $node.items | default (dict "kind" "any") -}}
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
value: {{ $node | toYaml | nindent 2 }}
{{- end -}}
{{- end -}}
