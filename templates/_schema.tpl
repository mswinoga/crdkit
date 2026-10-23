{{/*
Values schema engine — scope (public/internal) is declared per template
below. A library supplies the schema (literal YAML from its own
defines); crdkit validates values against it, normalizes them, checks
per-target values and renders a Markdown reference.

Schema node (a dict):
- type: the value's shape and scalar type after substitution — what a
  handler reads and the CR carries (omitted only on a "switch" node, a
  map):
  - string | int | number | bool — a scalar of that type
  - scalar — any scalar
  - map, list — that shape
  - any — everything, nothing below checked
- doc: Markdown text for the reference
- default: inserted when the key is absent (map properties only)
- required: bool — the key must be present
- required omitted = false; doc and default are optional
- scalar types: enum (list), pattern (regex, unanchored), static
  (true → the value is used as written: "@NAME@" markers rejected, never
  per-target; omitted = false) — the only variability flag
- scalar types and list: every non-static node may hold markers; the
  topmost one on a path (the declaration level) may also be per-target
  (a token declaration, resolved per target); below a per-target node
  only markers, and `static: true` there is a self-check ERROR (except a
  switch case's `by` key) — see crdkit.schema.perTarget.internal
- a shape mismatch or unmatched switch on a `required: true` node is an
  ERROR (elsewhere a WARNING); a map on a static scalar is an ERROR;
  both drop the value
- targetKeys (any node): list of target keys a token declaration at or
  below the node may use, next to `default` and `match`; inherited, a
  descendant's own replaces it; absent everywhere = any key
- annotations (scalar types, list): annotation keys a token declaration
  at this node may use
- map: properties ({key: node}), values (node for every other key;
  omitted = every other key is unknown), keys ({pattern, label?} for keys
  matched by "values"; label = documentation-only placeholder for a
  matched key, e.g. "<ID>")
- list: items (node for every element; omitted = {type: any})
- switch: {by: <key>, cases: {<value>: <node>}} — picks the node for a
  map by the value of one of its keys ("by", not "on": YAML 1.1, which
  Helm's fromYaml speaks, reads an `on:` key as the boolean true); optional
  unless: {key: <key>, value: <scalar>} — a map whose `key` equals `value`
  (toJson) is checked against its case reduced to `by` + `key`, every
  other key dropped silently; in JSON Schema such a map selects no case
  ("unless", not "off": YAML 1.1 again)

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
  crdkit.schema.resolve (public)
    -> crdkit.schema.check (public)
    -> crdkit.schema.path (public)
    -> crdkit.schema.valuesWalk.internal
  crdkit.schema.value (public) -> crdkit.schema.resolveAndCheck.internal
  crdkit.schema.node (public)
  crdkit.schema.path (public) -> crdkit.schema.path.internal
  crdkit.schema.docs (public)
    -> crdkit.schema.mdSkeleton.internal    (recursive)
    -> crdkit.schema.mdNode.internal        (recursive)
         -> crdkit.schema.mdRow.internal -> mdType.internal, mdDoc.internal
         -> crdkit.schema.mdTable.internal
         -> crdkit.schema.mdCaseExample.internal
              -> crdkit.schema.generatedExample.internal (recursive)
         -> crdkit.schema.sectionMarkdown.internal
  crdkit.schema.order.internal (internal) -> crdkit.schema.path.internal
  crdkit.schema.document (public)
    -> crdkit.schema.jsonSchema (public)
    -> crdkit.schema.html (public, templates/_viewer.tpl)
    -> crdkit.schema.docs (public)
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
  type it applies to; `static` only on a scalar type, never below a
  per-target node (a switch case's `by` key excepted); never `default`
  together with `required: true`; every switch case declares the switch
  key (and `unless.key`) as a scalar type with `static: true`; `unless` is
  `{key, value: <scalar>}` with `key` ≠ `by`.
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
    {{- include "crdkit.diag.error" (list $diag $problem) -}}
  {{- end -}}
{{- end -}}
{{- if not $problems.list -}}
true
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
- Shares its walker with crdkit.schema.resolve, which also returns the
  values with every per-target value resolved.
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
crdkit.schema.resolve (public)

Returns a subtree of the values with every per-target value resolved
for one target — for library code that maps whole subtrees into the
model.

Interface:
- Params (dict): { "ctx": <ctx>, "schema": <root node>, "values":
  <normalized values, whole — from crdkit.schema.validate>, "keys":
  <list of map keys / list indices from the root to the subtree,
  optional — [] = root>, "target": <optional — defaults to ctx.target>,
  "seen": <dict shared with crdkit.schema.validateValues /
  crdkit.schema.value, optional> }
- Returns YAML: { "value": <the subtree, every per-target value
  resolved for the target> }; `{}` when "keys" address nothing.

Implementation notes:
- "keys" are followed like crdkit.schema.node does, from the root, so
  ancestors (switch cases, per-target state) are known; diagnostic paths
  are spelled as the value pass spells them and "seen" de-duplicates
  across both.
- Same walker as crdkit.schema.validateValues
  (crdkit.schema.valuesWalk.internal): a per-target node or a string
  with markers is resolved and checked (an `int` / `number` / `bool`
  result converted); an `any` node is copied as written; what the
  structural pass would drop is dropped.
- No value found for the target (resolution ERROR) → the key or list
  element is omitted. A value failing its check stays as resolved,
  unconverted.
- A marker to a token that does not exist yet stays as text, for the
  final substitution pass.
- Skipped when the schema is invalid (crdkit.schema.check): returns `{}`.
*/}}
{{- define "crdkit.schema.resolve" -}}
{{- $ctx := .ctx -}}
{{- $seen := ternary .seen (dict) (kindIs "map" .seen) -}}
{{- if include "crdkit.schema.check" (dict "schema" .schema "diag" $ctx.diag) -}}
  {{- $node := .schema -}}
  {{- $value := .values -}}
  {{- $none := index (dict) "none" -}}
  {{- $found := true -}}
  {{- $inTokens := false -}}
  {{- $path := "" -}}
  {{- range $key := .keys | default (list) -}}
    {{- if and $found (hasKey $node "switch") -}}
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
    {{- if $found -}}
      {{- $inTokens = or $inTokens (ne (include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens)) "") -}}
      {{- $shape := include "crdkit.schema.shape.internal" (dict "node" $node) -}}
      {{- if and (eq $shape "map") (kindIs "map" $value) -}}
        {{- $properties := $node.properties | default dict -}}
        {{- if hasKey $properties (toString $key) -}}
          {{- $node = index $properties (toString $key) -}}
        {{- else if hasKey $node "values" -}}
          {{- $node = $node.values -}}
        {{- else -}}
          {{- $found = false -}}
        {{- end -}}
        {{- $value = index $value (toString $key) -}}
        {{- $path = include "crdkit.schema.path" (dict "keys" (list (toString $key)) "path" $path) -}}
      {{- else if and (eq $shape "list") (kindIs "slice" $value) (regexMatch "^[0-9]+$" (toString $key)) (lt (int (toString $key)) (len $value)) -}}
        {{- $node = $node.items | default (dict "type" "any") -}}
        {{- $value = index $value (int (toString $key)) -}}
        {{- $path = include "crdkit.schema.path" (dict "keys" (list (int (toString $key))) "path" $path) -}}
      {{- else -}}
        {{- $found = false -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and $found (not (kindIs "invalid" $value)) -}}
    {{- $out := dict -}}
    {{- include "crdkit.schema.valuesWalk.internal" (dict "ctx" $ctx "node" $node "value" $value "path" $path "target" (.target | default $ctx.target) "seen" $seen "inTokens" $inTokens "out" $out) -}}
    {{- if hasKey $out "value" -}}
value: {{ $out.value | toYaml | nindent 2 }}
    {{- end -}}
  {{- end -}}
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
- A resolved string of an `int` / `number` / `bool` node is returned
  converted to that type when it passes the check (see
  crdkit.schema.resolveAndCheck.internal), on every call.
- For a whole subtree use crdkit.schema.resolve.
- The node must come from a schema that passed crdkit.schema.check,
  through crdkit.schema.node (which makes its per-target state
  explicit — "node" alone cannot know its ancestors).
*/}}
{{- define "crdkit.schema.value" -}}
{{- $ctx := .ctx -}}
{{- $node := .node | default dict -}}
{{- $out := dict "value" .def -}}
{{- $tokens := include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" false) -}}
{{- if or $tokens (and (kindIs "string" .def) (regexMatch (include "crdkit.markerPattern" (dict)) .def)) -}}
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
- A returned scalar-type or list node carries an explicit `perTarget:`
  bool — its per-target state depends on its ancestors.
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
    {{- $inTokens = or $inTokens (ne (include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens)) "") -}}
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
    {{- $node = merge (dict "perTarget" (ne (include "crdkit.schema.perTarget.internal" (dict "node" $node "inTokens" $inTokens)) "")) (omit $node "perTarget") -}}
  {{- end -}}
value: {{ $node | toYaml | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.docs (public)

Renders a JSON Schema generated by crdkit.schema.jsonSchema as a
Markdown values reference.

Interface:
- Params (dict): { "schema": <JSON Schema text>, "title": <heading text,
  optional — default the schema's title, else "Values">, "htmlLink":
  <URL of the HTML reference, optional> }
- Returns: Markdown text, ending with a newline:
  - `# <title>` and a link to the HTML reference when given;
  - when the schema has `$id`, an "Editor support" line with the
    modeline `# yaml-language-server: $schema=<$id>` as a YAML block;
  - a commented YAML skeleton of the tree (keys in schema order, type,
    `required` and `per target` as trailing comments; switch cases as
    `# <by>: <value>` blocks);
  - one `## <path>` section per map node: its doc and a table of its
    keys (Key, Type, Per target, Default, Required, Description — only
    the columns with content);
  - one `## <node path>` section per switch case: doc, keys table
    (shared keys marked), example as a YAML block (generated when the
    schema's examples do not reach the case), sections (tables, `code`
    as YAML blocks);
  - when per-target nodes have closed declaration keys
    (`targetKeys`), a final `## Token declarations` section listing
    each distinct key set of the shared declaration definitions
    (crdkit.schema.jsonDeclaration.internal).

Implementation notes:
- Reads the extensions of crdkit.schema.jsonSchema (`x-crdkit-order`,
  `x-crdkit-switch`, `x-crdkit-shared`, `x-crdkit-sections` …) and the
  `examples` of the root; a section is rendered for any node that has
  sections.
*/}}
{{- define "crdkit.schema.docs" -}}
{{- $js := .schema | default "{}" | fromJson -}}
{{- $defs := $js.definitions | default dict -}}
{{- $parts := list (printf "# %s" (.title | default $js.title | default "Values")) -}}
{{- if .htmlLink -}}
  {{- $parts = append $parts (printf "[HTML reference](%s)" .htmlLink) -}}
{{- end -}}
{{- if index $js "$id" -}}
  {{- $parts = append $parts (printf "**Editor support** — first line of a values file:\n\n```yaml\n# yaml-language-server: $schema=%s\n```" (index $js "$id")) -}}
{{- end -}}
{{- $skeleton := dict "lines" (list) -}}
{{- include "crdkit.schema.mdSkeleton.internal" (dict "name" "" "node" $js "path" "" "defs" $defs "required" false "lead" "" "pad" "" "acc" $skeleton) -}}
{{- if $skeleton.lines -}}
  {{- $parts = append $parts (printf "```yaml\n%s\n```" (join "\n" $skeleton.lines)) -}}
{{- end -}}
{{- $pairs := list -}}
{{- if $js.examples -}}
  {{- $pairs = list (dict "keys" (list) "value" (first $js.examples)) -}}
{{- end -}}
{{- $acc := dict "sections" (list) -}}
{{- include "crdkit.schema.mdNode.internal" (dict "node" $js "path" "" "defs" $defs "pairs" $pairs "labels" (list) "acc" $acc) -}}
{{- $parts = concat $parts $acc.sections -}}
{{- $keySets := dict "sets" (list) -}}
{{- range $name := keys $defs | sortAlpha -}}
  {{- $declaration := dict -}}
  {{- include "crdkit.schema.jsonDeclaration.internal" (dict "node" (dict "anyOf" (list (dict "$ref" (printf "#/definitions/%s" $name)))) "defs" $defs "out" $declaration) -}}
  {{- if and (hasKey $declaration "targetKeys") (not (has $declaration.targetKeys $keySets.sets)) -}}
    {{- $_ := set $keySets "sets" (append $keySets.sets $declaration.targetKeys) -}}
  {{- end -}}
{{- end -}}
{{- if $keySets.sets -}}
  {{- $lines := list "## Token declarations" "A per-target value is a plain value or a token declaration: a map with these keys (plus the annotations named in its row). An exact target is not a key: it goes in `match`, a list of `{<regex>: <value>}`." -}}
  {{- $bullets := list -}}
  {{- range $set := $keySets.sets -}}
    {{- $keys := list -}}
    {{- range $key := concat $set (list "default" "match") -}}
      {{- $keys = append $keys (printf "`%s`" $key) -}}
    {{- end -}}
    {{- $bullets = append $bullets (printf "- %s" (join ", " $keys)) -}}
  {{- end -}}
  {{- $lines = append $lines (join "\n" $bullets) -}}
  {{- $parts = append $parts (join "\n\n" $lines) -}}
{{- end -}}
{{- join "\n\n" $parts }}
{{ end -}}

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
- Examples: the root and every scalar node get `examples`, the unique
  example values found at its path (see crdkit.schema.examples.internal);
  readers derive map and list examples from the root's. Generated examples
  for unreached nodes are not stored: the viewer and the Markdown derive
  them.
- Sections attach to the node named by their node path (values path with
  `*` for a `values` key, `[]` for list items, `[<by>=<value>]` for a
  case). A malformed section or a path naming no node records an ERROR
  and is dropped. crdkit never interprets a section's content.
- A non-empty `id` becomes the root `$id` (the viewer and the Markdown
  show it as the editor modeline); empty or absent → no `$id`; a
  non-string records an ERROR and is ignored.
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
  {{- $acc := dict "definitions" (dict "tokenDeclaration" (dict "type" "object" "minProperties" 1) "markers" (dict "type" "string" "pattern" (include "crdkit.markerPattern" (dict)))) "paths" (dict) -}}
  {{- $out := dict -}}
  {{- include "crdkit.schema.jsonNode.internal" (dict "node" $schema "schemaPath" "" "nodePath" "" "inTokens" false "instances" (ternary (list $example) (list) (kindIs "map" $example)) "order" $order "sections" $sections "acc" $acc "out" $out) -}}
  {{- range $sectionPath := keys $sections | sortAlpha -}}
    {{- if not (hasKey $acc.paths $sectionPath) -}}
      {{- $problems = append $problems (printf "sections: '%s' names no node — dropped" $sectionPath) -}}
    {{- end -}}
  {{- end -}}
  {{- range $problem := $problems -}}
    {{- if not (has $problem $diag.errors) -}}
      {{- include "crdkit.diag.error" (list $diag $problem) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $root "$schema" "http://json-schema.org/draft-07/schema#" -}}
  {{- if kindIs "string" .id -}}
    {{- if .id -}}
      {{- $_ := set $root "$id" .id -}}
    {{- end -}}
  {{- else if not (kindIs "invalid" .id) -}}
    {{- include "crdkit.diag.error" (list $diag "crdkit.schema.jsonSchema: 'id' must be a string — ignored") -}}
  {{- end -}}
  {{- $_ := set $root "title" (.title | default "Values") -}}
  {{- range $key, $value := $out.result -}}
    {{- $_ := set $root $key $value -}}
  {{- end -}}
  {{- $_ := set $root "definitions" $acc.definitions -}}
{{- end -}}
{{ $root | toPrettyJson }}
{{ end -}}

{{/*
crdkit.schema.document (public)

Generates one rendering of a values schema's documentation: the JSON
Schema, the HTML viewer or the Markdown reference. A library calls it
once per format, from its own documentation templates.

Interface:
- Params (dict): { "format": "json" | "html" | "md", "schemaText":
  <schema as YAML text>, "example": <example values, optional>,
  "sections": <{<node path>: [<section>]}, optional>, "title": <title,
  optional>, "htmlLink": <URL of the HTML reference, "md" only,
  optional>, "id": <root `$id`, see crdkit.schema.jsonSchema, optional>,
  "diag": <dict> }
- Returns: that format's text (see crdkit.schema.jsonSchema,
  crdkit.schema.html, crdkit.schema.docs); an empty string for an
  unknown format (an ERROR is recorded).

Implementation notes:
- One crdkit.schema.jsonSchema call feeds every format, so the three
  outputs agree. An invalid schema yields `{}` there (its ERRORs are
  recorded) and the html/md renderers receive that.
*/}}
{{- define "crdkit.schema.document" -}}
{{- $format := .format | default "" -}}
{{- if not (has $format (list "json" "html" "md")) -}}
  {{- include "crdkit.diag.error" (list .diag (printf "crdkit.schema.document: unknown format '%s' (json, html or md) — nothing rendered" $format)) -}}
{{- else -}}
  {{- $json := include "crdkit.schema.jsonSchema" (dict "schemaText" .schemaText "example" .example "sections" .sections "title" (.title | default "") "id" .id "diag" .diag) -}}
  {{- if eq $format "json" -}}
    {{- $json -}}
  {{- else if eq $format "html" -}}
    {{- include "crdkit.schema.html" (dict "schema" $json "title" (.title | default "")) -}}
  {{- else -}}
    {{- include "crdkit.schema.docs" (dict "schema" $json "title" (.title | default "") "htmlLink" (.htmlLink | default "")) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
