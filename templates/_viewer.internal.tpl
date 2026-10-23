{{/*
Internal helpers of templates/_viewer.tpl — see its file-level doc
comment for the overview and dependency graph.
*/}}

{{/*
crdkit.schema.viewModel.internal (internal)

Builds the viewer's view model from a JSON Schema: one item per tree row,
in the viewer's walk order, plus one record per switch.

Interface:
- Params (dict): { "json": <JSON Schema as a dict>, "out": <dict;
  "items" and "switches" lists are appended in place> }
- Returns: nothing (mutating helper). Appends to `out.items` one
  `{path, label, parent, type, perTarget, required, shared, summary,
  doc, sections, keywords: {default, pattern, enum, keysPattern},
  declarationKeys, examples, example: {has, value, generated}, case:
  {by, value}}` per tree row, to `out.switches` one `{path, by, values,
  title, unless?}` per switch.

Implementation notes:
- Values come from crdkit.schema.jsonType.internal, jsonPerTarget.internal,
  jsonDeclaration.internal, generatedExample.internal, mdDoc.internal,
  path.internal.
- Items are appended in pre-order: a node before its children, a switch
  case right after its switch; `parent` is the parent item's path (empty
  at the root).
- Examples stay values (not YAML text): the page renders them.
*/}}
{{- define "crdkit.schema.viewModel.internal" -}}
{{- $json := .json -}}
{{- $defs := $json.definitions | default dict -}}
{{- $pairs := list -}}
{{- if and (kindIs "slice" $json.examples) (gt (len $json.examples) 0) -}}
  {{- $pairs = list (dict "keys" (list) "value" (first $json.examples)) -}}
{{- end -}}
{{- $root := dict
      "node" $json "path" "" "label" (index $json "title" | default "Values") "parent" nil
      "required" false "shared" false "labels" (list) "pairs" $pairs
      "instances" (index $json "examples" | default list) "defs" $defs -}}
{{- include "crdkit.schema.viewWalk.internal" (dict "spec" $root "out" .out) -}}
{{- end -}}

{{/*
crdkit.schema.viewWalk.internal (internal)

Walks one JSON Schema node into the view model: appends its item, a
switch's cases or its child specs, in the viewer's order.

Interface:
- Params (dict): { "spec": <{node, path, label, parent, required, shared,
  labels, pairs, instances, defs}>, "out": <the view model dict> }
- Returns: nothing (mutating helper).
*/}}
{{- define "crdkit.schema.viewWalk.internal" -}}
{{- $spec := .spec -}}
{{- $out := .out -}}
{{- $node := $spec.node -}}
{{- $defs := $spec.defs -}}
{{- $item := dict
      "path" $spec.path "label" $spec.label "parent" $spec.parent
      "type" (include "crdkit.schema.jsonType.internal" (dict "node" $node))
      "perTarget" (include "crdkit.schema.jsonPerTarget.internal" (dict "node" $node))
      "required" $spec.required "shared" $spec.shared
      "summary" (first (splitList "\n" (index $node "description" | default "")))
      "doc" (include "crdkit.schema.mdDoc.internal" (dict "node" $node))
      "sections" (index $node "x-crdkit-sections" | default list)
      "keywords" (include "crdkit.schema.viewKeywords.internal" (dict "node" $node) | fromYaml)
      "examples" $spec.instances
      "example" (dict "has" false) -}}
{{- $generated := dict -}}
{{- include "crdkit.schema.generatedExample.internal" (dict "node" $node "defs" $defs "out" $generated) -}}
{{- $_ := set $item "example" (dict "has" $generated.has "value" $generated.value "generated" true) -}}
{{- $decl := dict -}}
{{- include "crdkit.schema.jsonDeclaration.internal" (dict "node" $node "defs" $defs "out" $decl) -}}
{{- if hasKey $decl "targetKeys" -}}
  {{- $_ := set $item "declarationKeys" (concat $decl.targetKeys (list "default" "match") $decl.annotations) -}}
{{- end -}}
{{- if hasKey $node "x-crdkit-switch" -}}
  {{- $switch := index $node "x-crdkit-switch" -}}
  {{- $record := dict "path" $spec.path "by" $switch.by "values" $switch.cases "title" (join "." (concat $spec.labels (list $switch.by))) -}}
  {{- if hasKey $switch "unless" -}}
    {{- $_ := set $record "unless" $switch.unless -}}
  {{- end -}}
  {{- $_ := set $out "switches" (append $out.switches $record) -}}
  {{- $_ := set $out "items" (append $out.items $item) -}}
  {{- $refs := index $switch "refs" | default dict -}}
  {{- range $value := $switch.cases -}}
    {{- $casePath := printf "%s[%s=%s]" $spec.path $switch.by $value -}}
    {{- $caseNode := index $defs $casePath | default dict -}}
    {{- if not $caseNode -}}
      {{- $ref := index $refs (toString $value) | default "" -}}
      {{- $caseNode = index $defs (last (splitList "/" $ref)) | default dict -}}
    {{- end -}}
    {{- $example := dict -}}
    {{- include "crdkit.schema.viewCaseExample.internal" (dict "node" $caseNode "switch" $switch "value" $value "pairs" $spec.pairs "labels" $spec.labels "defs" $defs "out" $example) -}}
    {{- $caseItem := dict
          "path" $casePath "label" (toString $value) "parent" $spec.path
          "type" (include "crdkit.schema.jsonType.internal" (dict "node" $caseNode))
          "perTarget" (include "crdkit.schema.jsonPerTarget.internal" (dict "node" $caseNode))
          "required" false "shared" false
          "summary" (first (splitList "\n" (index $caseNode "description" | default "")))
          "doc" (include "crdkit.schema.mdDoc.internal" (dict "node" $caseNode))
          "sections" (index $caseNode "x-crdkit-sections" | default list)
          "keywords" (include "crdkit.schema.viewKeywords.internal" (dict "node" $caseNode) | fromYaml)
          "case" (dict "by" $switch.by "value" $value)
          "example" $example -}}
    {{- $caseDecl := dict -}}
    {{- include "crdkit.schema.jsonDeclaration.internal" (dict "node" $caseNode "defs" $defs "out" $caseDecl) -}}
    {{- if hasKey $caseDecl "targetKeys" -}}
      {{- $_ := set $caseItem "declarationKeys" (concat $caseDecl.targetKeys (list "default" "match") $caseDecl.annotations) -}}
    {{- end -}}
    {{- $_ := set $out "items" (append $out.items $caseItem) -}}
    {{- $instances := list -}}
    {{- range $instance := $spec.instances -}}
      {{- if and (kindIs "map" $instance) (hasKey $instance $switch.by) (eq (toString (index $instance $switch.by)) (toString $value)) -}}
        {{- $instances = append $instances $instance -}}
      {{- end -}}
    {{- end -}}
    {{- include "crdkit.schema.viewChildren.internal" (dict
          "node" $caseNode "path" $casePath "labels" $spec.labels
          "pairs" (list) "instances" $instances "defs" $defs "out" $out) -}}
  {{- end -}}
{{- else -}}
  {{- $_ := set $out "items" (append $out.items $item) -}}
  {{- include "crdkit.schema.viewChildren.internal" (dict
        "node" $node "path" $spec.path "labels" $spec.labels
        "pairs" $spec.pairs "instances" $spec.instances "defs" $defs "out" $out) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.viewChildren.internal (internal)

Walks a node's children into the view model: its properties, then the
`values` entries of the node's map value, then its list items.

Interface:
- Params (dict): { "node": <JSON Schema node>, "path": <its path>,
  "labels": <key labels from the root to the node>, "pairs": <example
  values at the node, each {keys, value}>, "instances": <example values
  at the node>, "defs": <JSON Schema definitions>, "out": <the view
  model dict> }
- Returns: nothing (mutating helper).
*/}}
{{- define "crdkit.schema.viewChildren.internal" -}}
{{- $node := .node -}}
{{- $path := .path -}}
{{- $defs := .defs -}}
{{- $out := .out -}}
{{- $type := include "crdkit.schema.jsonType.internal" (dict "node" $node) -}}
{{- $core := $node -}}
{{- if hasKey $node "anyOf" -}}
  {{- $core = first $node.anyOf -}}
{{- end -}}
{{- $props := index $node "properties" | default dict -}}
{{- $required := index $node "required" | default list -}}
{{- $order := list -}}
{{- range $k := (index $node "x-crdkit-order" | default list) -}}
  {{- if hasKey $props $k -}}
    {{- $order = append $order $k -}}
  {{- end -}}
{{- end -}}
{{- range $k := keys $props | sortAlpha -}}
  {{- if not (has $k $order) -}}
    {{- $order = append $order $k -}}
  {{- end -}}
{{- end -}}
{{- range $k := $order -}}
  {{- $child := index $props $k -}}
  {{- $pairs := list -}}
  {{- if eq $type "map" -}}
    {{- range $pair := $.pairs -}}
      {{- if and (kindIs "map" $pair.value) (hasKey $pair.value $k) (not (kindIs "invalid" (index $pair.value $k))) -}}
        {{- $pairs = append $pairs (dict "keys" (concat $pair.keys (list $k)) "value" (index $pair.value $k)) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $instances := list -}}
  {{- range $instance := $.instances -}}
    {{- if and (kindIs "map" $instance) (hasKey $instance $k) (not (kindIs "invalid" (index $instance $k))) -}}
      {{- $instances = append $instances (index $instance $k) -}}
    {{- end -}}
  {{- end -}}
  {{- include "crdkit.schema.viewWalk.internal" (dict "spec" (dict
        "node" $child "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" $k))
        "label" $k "parent" $path "required" (has $k $required)
        "shared" (eq (index $child "x-crdkit-shared") true)
        "labels" (concat $.labels (list $k)) "pairs" $pairs
        "instances" $instances "defs" $defs) "out" $out) -}}
{{- end -}}
{{- if kindIs "map" (index $core "additionalProperties") -}}
  {{- $valuesNode := index $core "additionalProperties" -}}
  {{- $pairs := list -}}
  {{- if eq $type "map" -}}
    {{- range $pair := $.pairs -}}
      {{- if kindIs "map" $pair.value -}}
        {{- range $entryKey := keys $pair.value | sortAlpha -}}
          {{- if and (not (hasKey $props $entryKey)) (not (kindIs "invalid" (index $pair.value $entryKey))) -}}
            {{- $pairs = append $pairs (dict "keys" (concat $pair.keys (list $entryKey)) "value" (index $pair.value $entryKey)) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $instances := list -}}
  {{- range $instance := $.instances -}}
    {{- if kindIs "map" $instance -}}
      {{- range $entryKey := keys $instance | sortAlpha -}}
        {{- if and (not (hasKey $props $entryKey)) (not (kindIs "invalid" (index $instance $entryKey))) -}}
          {{- $instances = append $instances (index $instance $entryKey) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $label := index $node "x-crdkit-keyLabel" | default "<key>" -}}
  {{- include "crdkit.schema.viewWalk.internal" (dict "spec" (dict
        "node" $valuesNode "path" (include "crdkit.schema.path.internal" (dict "path" $path "key" "*"))
        "label" $label
        "parent" $path "required" false "shared" false
        "labels" (concat $.labels (list $label)) "pairs" $pairs "instances" $instances "defs" $defs) "out" $out) -}}
{{- end -}}
{{- if kindIs "map" (index $core "items") -}}
  {{- $instances := list -}}
  {{- range $instance := $.instances -}}
    {{- if kindIs "slice" $instance -}}
      {{- range $element := $instance -}}
        {{- if not (kindIs "invalid" $element) -}}
          {{- $instances = append $instances $element -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- include "crdkit.schema.viewWalk.internal" (dict "spec" (dict
        "node" (index $core "items") "path" (printf "%s[]" $path) "label" "[]"
        "parent" $path "required" false "shared" false
        "labels" $.labels "pairs" (list) "instances" $instances "defs" $defs) "out" $out) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.schema.viewKeywords.internal (internal)

Collects the structural keywords the viewer shows in an item's row and
detail page.

Interface:
- Params (dict): { "node": <JSON Schema node> }
- Returns: a YAML dict of the keywords present: `default`, `pattern`,
  `enum`, `keysPattern` (the `propertyNames.pattern`).
*/}}
{{- define "crdkit.schema.viewKeywords.internal" -}}
{{- $node := .node -}}
{{- $core := $node -}}
{{- if hasKey $node "anyOf" -}}
  {{- $core = first $node.anyOf -}}
{{- end -}}
{{- $keywords := dict -}}
{{- if hasKey $node "default" -}}
  {{- $_ := set $keywords "default" $node.default -}}
{{- end -}}
{{- if hasKey $core "pattern" -}}
  {{- $_ := set $keywords "pattern" $core.pattern -}}
{{- end -}}
{{- if hasKey $core "enum" -}}
  {{- $_ := set $keywords "enum" $core.enum -}}
{{- end -}}
{{- $propertyNames := index $core "propertyNames" | default dict -}}
{{- if hasKey $propertyNames "pattern" -}}
  {{- $_ := set $keywords "keysPattern" $propertyNames.pattern -}}
{{- end -}}
{{- toYaml $keywords -}}
{{- end -}}

{{/*
crdkit.schema.viewCaseExample.internal (internal)

A switch case's example: the matching example entries in their ancestor
keys, else the generated example with its `by` set, in the key labels.

Interface:
- Params (dict): { "node": <case definition>, "switch": <the
  `x-crdkit-switch` dict>, "value": <case value>, "pairs": <example
  values at the switch node, each {keys, value}>, "labels": <key labels
  from the root to the switch node>, "defs": <JSON Schema definitions>,
  "out": <dict; "has", "value" and "generated" are set in place> }
- Returns: nothing (mutating helper).
*/}}
{{- define "crdkit.schema.viewCaseExample.internal" -}}
{{- $switch := .switch -}}
{{- $value := .value -}}
{{- $out := .out -}}
{{- $merged := dict -}}
{{- $generated := true -}}
{{- range $pair := .pairs -}}
  {{- if and (kindIs "map" $pair.value) (hasKey $pair.value $switch.by) (eq (toString (index $pair.value $switch.by)) (toString $value)) -}}
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
  {{- $wrapped := dict -}}
  {{- if kindIs "map" $body.value -}}
    {{- $wrapped = deepCopy $body.value -}}
  {{- end -}}
  {{- $_ := set $wrapped $switch.by $value -}}
  {{- range $label := reverse .labels -}}
    {{- $wrapped = dict $label $wrapped -}}
  {{- end -}}
  {{- $merged = $wrapped -}}
{{- end -}}
{{- $_ := set $out "has" true -}}
{{- $_ := set $out "value" $merged -}}
{{- $_ := set $out "generated" $generated -}}
{{- end -}}

{{/*
crdkit.schema.viewer.internal (internal)

The viewer document: shell markup, CSS, the embedded schema, the view
model and the JS.

Interface:
- Params (dict): { "title": <page title>, "json": <JSON Schema text> }
- Returns: the HTML document as plain text.

Implementation notes:
- The view model of crdkit.schema.viewModel.internal is embedded beside
  the schema, so the page's item order, types, declarations and examples
  are decided here, not in the JS.
- The JS must never contain `{{` (the template delimiter).
- The page holds no `http://` or `https://` outside the embedded JSON.
- `</` is escaped as `<\/` in both embeds.
*/}}
{{- define "crdkit.schema.viewer.internal" -}}
{{- $view := dict "items" (list) "switches" (list) -}}
{{- include "crdkit.schema.viewModel.internal" (dict "json" (.json | fromJson) "out" $view) -}}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ .title | html }}</title>
<style>
:root {
  color-scheme: light dark;
  --ground: #f6f7f9; --surface: #ffffff; --ink: #1b2130; --muted: #5d6679; --rule: #dde1e8;
  --accent: #2b49c4; --accent-soft: #e7ecfb; --on-accent: #ffffff;
  --t-str: #1d7a55; --t-str-bg: #e3f3eb;
  --t-num: #9a5b00; --t-num-bg: #fbefdc;
  --t-bool: #8a2f86; --t-bool-bg: #f6e5f5;
  --t-map: #2b49c4; --t-map-bg: #e7ecfb;
  --t-any: #5d6679; --t-any-bg: #eceef2;
  --pt-yes: #0d6f7a; --pt-yes-bg: #dff2f3;
  --err: #c2410c; --code-bg: #f0f2f6;
  --font: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ground: #12151c; --surface: #1a1e28; --ink: #e5e8ef; --muted: #9aa3b5; --rule: #2c3240;
    --accent: #8fa6ff; --accent-soft: #232c4d; --on-accent: #0f1428;
    --t-str: #6fd1a4; --t-str-bg: #183229;
    --t-num: #f0b665; --t-num-bg: #362a16;
    --t-bool: #e39be0; --t-bool-bg: #352036;
    --t-map: #8fa6ff; --t-map-bg: #232c4d;
    --t-any: #9aa3b5; --t-any-bg: #262b36;
    --pt-yes: #6fd3dc; --pt-yes-bg: #173337;
    --err: #ff9a6b; --code-bg: #141821;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; }
body { background: var(--ground); color: var(--ink); font-family: var(--font); font-size: 15px; line-height: 1.5; }
code, pre, .mono { font-family: var(--mono); font-size: 0.86em; }
:not(pre) > code { background: var(--code-bg); padding: 0.08em 0.35em; border-radius: 4px; }
pre { background: var(--code-bg); border: 1px solid var(--rule); border-radius: 8px; padding: 10px 12px; margin: 0; overflow-x: auto; font-size: 0.8rem; line-height: 1.5; }
p { margin: 0; }
ul { margin: 0; padding-left: 1.2em; }
.app { display: flex; flex-direction: column; height: 100vh; background: var(--surface); }
.bar { display: flex; flex-wrap: wrap; gap: 10px 16px; align-items: center; padding: 10px 16px; border-bottom: 1px solid var(--rule); }
.bar .title { font-weight: 700; font-size: 1.05rem; }
.bar .spacer { flex: 1; }
.search { display: flex; align-items: center; gap: 6px; background: var(--ground); border: 1px solid var(--rule); border-radius: 8px; padding: 4px 10px; min-width: 0; flex: 0 1 280px; }
.search input { border: 0; background: transparent; color: var(--ink); font: inherit; font-size: 0.9rem; outline: none; width: 100%; min-width: 0; }
.search:focus-within { border-color: var(--accent); }
.chk { display: inline-flex; align-items: center; gap: 6px; font-size: 0.85rem; color: var(--muted); cursor: pointer; }
.filters { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; padding: 8px 16px; border-bottom: 1px solid var(--rule); background: var(--ground); font-size: 0.82rem; color: var(--muted); }
.filters[hidden] { display: none; }
.filters .fl { font-family: var(--mono); font-size: 0.78rem; color: var(--ink); }
.fgroup { display: inline-flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.seg { display: inline-flex; border: 1px solid var(--rule); border-radius: 7px; overflow: hidden; background: var(--surface); }
.seg button { font: inherit; font-family: var(--mono); font-size: 0.78rem; border: 0; background: transparent; color: var(--ink); padding: 3px 10px; cursor: pointer; border-right: 1px solid var(--rule); }
.seg button:last-child { border-right: 0; }
.seg button[aria-pressed="true"] { background: var(--accent); color: var(--on-accent); }
.seg button:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
.panes { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr); flex: 1; min-height: 0; }
.tree { padding: 8px 0 14px; font-family: var(--mono); font-size: 0.83rem; overflow: auto; }
.detail { border-left: 1px solid var(--rule); padding: 18px 20px; display: grid; gap: 14px; align-content: start; min-width: 0; overflow: auto; }
@media (max-width: 860px) {
  .app { height: auto; }
  .panes { display: block; }
  .tree { max-height: 55vh; }
  .detail { border-left: 0; border-top: 1px solid var(--rule); }
}
.row { display: flex; align-items: center; gap: 8px; padding: 3px 16px 3px 0; cursor: pointer; white-space: nowrap; border-left: 3px solid transparent; }
.row:hover { background: var(--ground); }
.row.sel { background: var(--accent-soft); border-left-color: var(--accent); }
.row:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
.row .tw { width: 14px; color: var(--muted); text-align: center; flex: none; user-select: none; }
.row .k { color: var(--ink); font-weight: 500; }
.row .k.ph { color: var(--muted); font-style: italic; }
.row .by { color: var(--muted); font-weight: 400; margin-right: 4px; }
.row .colon { color: var(--muted); margin-left: -6px; }
.row .doc { color: var(--muted); font-family: var(--font); font-size: 0.8rem; overflow: hidden; text-overflow: ellipsis; max-width: 32ch; }
.row.case .k { color: var(--accent); font-weight: 600; }
.row.root .k { font-weight: 700; }
.badge { font-family: var(--mono); font-size: 0.7rem; padding: 1px 6px; border-radius: 4px; font-weight: 500; flex: none; }
.ty-string { color: var(--t-str); background: var(--t-str-bg); }
.ty-int, .ty-number { color: var(--t-num); background: var(--t-num-bg); }
.ty-bool { color: var(--t-bool); background: var(--t-bool-bg); }
.ty-map, .ty-list { color: var(--t-map); background: var(--t-map-bg); }
.ty-scalar, .ty-any { color: var(--t-any); background: var(--t-any-bg); }
.ty-case { color: var(--accent); border: 1px solid var(--accent); }
.pt { font-family: var(--font); font-size: 0.68rem; padding: 1px 6px; border-radius: 999px; flex: none; font-weight: 600; letter-spacing: 0.02em; }
.pt-yes { color: var(--pt-yes); background: var(--pt-yes-bg); }
.pt-markers { color: var(--muted); border: 1px dashed var(--rule); }
.pt-shared { color: var(--muted); background: var(--t-any-bg); font-weight: 500; }
.ctx .k, .ctx .badge, .ctx .doc, .ctx .def, .ctx .pt { opacity: 0.5; }
.hit .k { background: color-mix(in srgb, var(--t-num) 24%, transparent); border-radius: 3px; }
.no-hits { padding: 10px 16px; color: var(--muted); font-family: var(--font); font-size: 0.86rem; }
.gen { font-family: var(--font); font-size: 0.68rem; color: var(--muted); flex: none; }
.req { color: var(--err); font-weight: 700; }
.def { color: var(--muted); font-size: 0.76rem; }
.path { font-family: var(--mono); font-size: 0.8rem; color: var(--muted); word-break: break-all; }
.detail h3 { font-family: var(--mono); font-size: 1.1rem; font-weight: 600; margin: 0; overflow-wrap: anywhere; }
.facts { display: grid; grid-template-columns: max-content 1fr; gap: 6px 14px; font-size: 0.87rem; margin: 0; }
.facts dt { color: var(--muted); }
.facts dd { margin: 0; min-width: 0; }
.block { display: grid; gap: 6px; }
.eyebrow { font-size: 0.72rem; letter-spacing: 0.07em; text-transform: uppercase; color: var(--muted); font-weight: 600; }
.dtable { border: 1px solid var(--rule); border-radius: 7px; overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.8rem; }
th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { font-size: 0.7rem; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); font-weight: 600; }
tr:last-child td { border-bottom: 0; }
.dtable td:first-child { font-family: var(--mono); white-space: nowrap; }
.link { background: none; border: 0; padding: 0; font: inherit; color: var(--accent); cursor: pointer; text-decoration: underline; text-underline-offset: 2px; }
.link:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 2px; }
.empty-note { color: var(--muted); font-size: 0.85rem; }
.prose { display: grid; gap: 8px; font-size: 0.92rem; }
.legend { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; padding: 8px 16px; border-top: 1px solid var(--rule); font-size: 0.78rem; color: var(--muted); }
.legend span { display: inline-flex; gap: 6px; align-items: center; }
</style>
</head>
<body>
<div class="app">
  <div class="bar">
    <div class="title" id="title"></div>
    <div class="spacer"></div>
    <label class="search" for="q"><span aria-hidden="true" style="color:var(--muted)">&#8981;</span><input id="q" type="search" autocomplete="off"></label>
    <label class="chk" for="onlyPt"><input id="onlyPt" type="checkbox"> per-target only</label>
  </div>
  <div class="filters" id="filters" hidden></div>
  <div class="panes">
    <div class="tree" id="tree" role="tree" aria-label="Values tree"></div>
    <div class="detail" id="detail" aria-live="polite"></div>
  </div>
  <div class="legend">
    <span><span class="badge ty-string">string</span><span class="badge ty-bool">bool</span><span class="badge ty-map">map</span> type</span>
    <span><span class="badge ty-case">case</span> switch value, with its own page</span>
    <span><span class="pt pt-yes">per-target</span> plain value or token declaration</span>
    <span><span class="pt pt-markers">markers</span> may hold <code>@NAME@</code></span>
    <span><span class="req">*</span> required</span>
  </div>
</div>
<script type="application/json" id="crdkit-schema">{{ .json | trim | replace "</" "<\\/" }}</script>
<script type="application/json" id="crdkit-view">{{ $view | toJson | replace "</" "<\\/" }}</script>
<script>
(function () {
"use strict";
var SCHEMA = {};
try { SCHEMA = JSON.parse(document.getElementById("crdkit-schema").textContent) || {}; } catch (e) { SCHEMA = {}; }
var VIEW = {};
try { VIEW = JSON.parse(document.getElementById("crdkit-view").textContent) || {}; } catch (e) { VIEW = {}; }

// ---------- helpers ----------
var has = function (o, k) { return o !== null && typeof o === "object" && Object.prototype.hasOwnProperty.call(o, k); };
var isMap = function (v) { return v !== null && typeof v === "object" && !Array.isArray(v); };
var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); };

// ---------- Markdown (inline code, bold, paragraphs, lists, fences) ----------
function inline(s) {
  return esc(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
}
function mdText(text) {
  return String(text).split(/\n{2,}/).map(function (par) {
    var lines = par.split("\n");
    if (lines.every(function (l) { return /^\s*[-*] /.test(l); })) {
      return "<ul>" + lines.map(function (l) { return "<li>" + inline(l.replace(/^\s*[-*] /, "")) + "</li>"; }).join("") + "</ul>";
    }
    return "<p>" + lines.map(inline).join("<br>") + "</p>";
  }).join("");
}
function md(text) {
  if (!text) { return ""; }
  var fence = new RegExp("```[a-z]*\\n([\\s\\S]*?)```", "g"), out = "", last = 0, m;
  while ((m = fence.exec(text)) !== null) {
    out += mdText(text.slice(last, m.index).trim()) + "<pre>" + esc(m[1].replace(/\n$/, "")) + "</pre>";
    last = m.index + m[0].length;
  }
  return out + (text.slice(last).trim() ? mdText(text.slice(last).trim()) : "");
}

// ---------- YAML (keys sorted, sequences at the key's indentation, like Helm's toYaml) ----------
function yScalar(v) {
  if (v === null || v === undefined) { return "null"; }
  if (typeof v === "string") {
    var plain = /^[A-Za-z<][A-Za-z0-9_ <>.\/-]*$/.test(v) && v.trim() === v && !/^(true|false|null|yes|no|on|off|y|n)$/i.test(v);
    return plain ? v : JSON.stringify(v);
  }
  return String(v);
}
var nonEmpty = function (v) { return Array.isArray(v) ? v.length > 0 : isMap(v) && Object.keys(v).length > 0; };
function yInline(v) {
  if (Array.isArray(v)) { return "[]"; }
  if (isMap(v)) { return "{}"; }
  return yScalar(v);
}
function yLines(v, ind) {
  var lines = [];
  if (Array.isArray(v)) {
    v.forEach(function (x) {
      if (nonEmpty(x)) {
        var sub = yLines(x, ind + "  ");
        sub[0] = ind + "- " + sub[0].slice(ind.length + 2);
        lines = lines.concat(sub);
      } else { lines.push(ind + "- " + yInline(x)); }
    });
  } else if (isMap(v)) {
    Object.keys(v).sort().forEach(function (k) {
      var x = v[k], key = yScalar(k);
      if (!nonEmpty(x)) { lines.push(ind + key + ": " + yInline(x)); }
      else if (Array.isArray(x)) { lines.push(ind + key + ":"); lines = lines.concat(yLines(x, ind)); }
      else { lines.push(ind + key + ":"); lines = lines.concat(yLines(x, ind + "  ")); }
    });
  } else { lines.push(ind + yScalar(v)); }
  return lines;
}
function toYaml(v) { return nonEmpty(v) ? yLines(v, "").join("\n") : yInline(v); }

// ---------- model (built in Go by crdkit.schema.viewModel.internal) ----------
var ITEMS = VIEW.items || [], SWITCHES = VIEW.switches || [], ALL = {}, SW = {};
SWITCHES.forEach(function (sw) { SW[sw.path] = sw; });
ITEMS.forEach(function (it) { it.kids = []; ALL[it.path] = it; });
ITEMS.forEach(function (it) { it.parentItem = it.parent === null ? null : ALL[it.parent]; if (it.parentItem) { it.parentItem.kids.push(it); } });
ITEMS.forEach(function (it) {
  it.parent = it.parentItem; delete it.parentItem;
  it.kind = it.case ? "case" : "key";
  it.depth = it.parent ? it.parent.depth + 1 : 0;
  it.isRoot = !it.parent;
  it.inShared = !!(it.shared || (it.parent && it.parent.inShared));
  it.caseOf = it.case ? null : (it.parent && (it.parent.kind === "case" ? it.parent : it.parent.caseOf));
  if (it.case) { it.by = it.case.by; it.caseValue = it.case.value; it.sw = it.parent ? SW[it.parent.path] : null; it.owner = it.parent; }
});
function sectionRows(it) {
  return (it.sections || []).reduce(function (a, s) { return a + (Array.isArray(s.rows) ? s.rows.length : 0); }, 0);
}

// ---------- state ----------
var state = { sel: "", q: "", onlyPt: false, collapsed: {}, filter: {}, hidden: [] };
SWITCHES.forEach(function (s) { state.filter[s.path] = ""; });
var tree = document.getElementById("tree"), detail = document.getElementById("detail"), filtersEl = document.getElementById("filters");
var qEl = document.getElementById("q");
document.getElementById("title").textContent = SCHEMA.title || "Values";
qEl.placeholder = SWITCHES.length ? "Search keys · " + SWITCHES[0].by + ": " + SWITCHES[0].values[0] : "Search keys";

// ---------- search / filters ----------
function classify() {
  ITEMS.forEach(function (it) {
    var f = it.kind === "case" ? state.filter[it.sw.path] : "";
    it.off = !!((it.parent && it.parent.off) || (f && f !== it.caseValue));
    it.match = false; it.below = false; it.inside = false;
  });
  var q = state.q.trim().toLowerCase(), active = !!(q || state.onlyPt);
  state.hidden = [];
  if (!active) {
    ITEMS.forEach(function (it) { it.vis = it.off ? "hide" : "show"; });
    return 0;
  }
  var sq = q.match(/^([^\s:=]+)\s*[:=]\s*(.*)$/);
  var caseQuery = sq && SWITCHES.some(function (s) { return s.by.toLowerCase() === sq[1]; }) ? { by: sq[1], value: sq[2].trim() } : null;
  var nameHit = function (isCase, by, label) {
    if (caseQuery) { return isCase && by.toLowerCase() === caseQuery.by && label.toLowerCase().indexOf(caseQuery.value) >= 0; }
    return label.toLowerCase().indexOf(q) >= 0;
  };
  var hits = 0;
  ITEMS.forEach(function (it) {
    if (it.off || it.isRoot) { return; }
    var pt = it.kind === "key" && it.perTarget === "yes";
    it.match = (!q || nameHit(it.kind === "case", it.by || "", it.label)) && (!state.onlyPt || pt);
    if (it.match) { hits++; }
  });
  if (q) {
    SWITCHES.forEach(function (sw) {
      var f = state.filter[sw.path];
      if (!f) { return; }
      sw.values.forEach(function (v) { if (v !== f && nameHit(true, sw.by, v)) { state.hidden.push({ sw: sw, v: v }); } });
    });
  }
  ITEMS.forEach(function (it) { it.inside = !!(it.parent && (it.parent.match || it.parent.inside)); });
  for (var i = ITEMS.length - 1; i >= 0; i--) {
    var x = ITEMS[i];
    if ((x.match || x.below) && x.parent) { x.parent.below = true; }
  }
  ITEMS.forEach(function (it) { it.vis = it.off ? "hide" : it.match ? "hit" : it.inside ? "show" : it.below ? "ctx" : "hide"; });
  return hits;
}

// ---------- tree ----------
function render() {
  renderFilters();
  var hits = classify();
  var searching = !!(state.q.trim() || state.onlyPt);
  tree.innerHTML = "";
  var hiddenUnder = {};
  ITEMS.forEach(function (it) {
    if (it.vis === "hide") { return; }
    if (!searching && it.parent && (hiddenUnder[it.parent.path] || state.collapsed[it.parent.path])) { hiddenUnder[it.path] = true; return; }
    drawRow(it, searching);
  });
  if (searching && !hits) {
    var none = document.createElement("div"); none.className = "no-hits";
    none.textContent = "No key or type matches “" + state.q + "”.";
    tree.appendChild(none);
  }
  if (searching && state.hidden.length) {
    var note = document.createElement("div"); note.className = "no-hits";
    note.innerHTML = "Also matches " + state.hidden.map(function (h) { return "<code>" + esc(h.sw.by) + ": " + esc(h.v) + "</code>"; }).join(", ") +
      ', hidden by the filter. <button type="button" class="link" id="clear-filter">Show all</button>';
    tree.appendChild(note);
    note.querySelector("#clear-filter").addEventListener("click", function () {
      SWITCHES.forEach(function (sw) { state.filter[sw.path] = ""; });
      render();
    });
  }
  renderDetail();
}
function drawRow(it, searching) {
  var hasKids = it.kids.length > 0, open = searching || !state.collapsed[it.path];
  var el = document.createElement("div");
  el.className = "row" + (it.kind === "case" ? " case" : "") + (it.isRoot ? " root" : "") + (state.sel === it.path ? " sel" : "") +
    (it.vis === "hit" ? " hit" : "") + (it.vis === "ctx" ? " ctx" : "");
  el.style.paddingLeft = (12 + it.depth * 18) + "px";
  el.setAttribute("role", "treeitem"); el.setAttribute("aria-level", it.depth + 1);
  el.tabIndex = 0; el.dataset.path = it.path;
  if (hasKids) { el.setAttribute("aria-expanded", open ? "true" : "false"); }
  var html = '<span class="tw">' + (hasKids ? (open ? "▾" : "▸") : "") + "</span>";
  if (it.kind === "case") {
    var rows = sectionRows(it);
    html += '<span class="k"><span class="by">' + esc(it.by) + ":</span>" + esc(it.label) + "</span>" +
      '<span class="badge ty-case">case</span>' + (rows ? '<span class="gen">generates ' + rows + "</span>" : "");
  } else {
    var ph = !it.isRoot && it.label.charAt(0) === "<";
    var t = it.type, pt = it.perTarget;
    html += '<span class="k' + (ph ? " ph" : "") + '">' + esc(it.label) + (it.required ? '<span class="req">*</span>' : "") + "</span>" +
      (it.isRoot ? "" : '<span class="colon">:</span>') + '<span class="badge ty-' + esc(t) + '">' + esc(t) + "</span>" +
      (pt === "yes" ? '<span class="pt pt-yes">per-target</span>' : pt === "markers" ? '<span class="pt pt-markers">markers</span>' : "") +
      (it.shared ? '<span class="pt pt-shared">shared</span>' : "") +
      (has(it.keywords, "default") ? '<span class="def">= ' + esc(JSON.stringify(it.keywords["default"])) + "</span>" : "") +
      (it.keywords.keysPattern ? '<span class="def">keys ' + esc(it.keywords.keysPattern) + "</span>" : "");
  }
  html += '<span class="doc">' + esc(it.summary) + "</span>";
  el.innerHTML = html;
  tree.appendChild(el);
}
tree.addEventListener("click", function (e) {
  var row = e.target.closest(".row");
  if (!row) { return; }
  var path = row.dataset.path, it = ALL[path];
  if (e.target.classList.contains("tw") && it.kids.length && !(state.q.trim() || state.onlyPt)) {
    if (state.collapsed[path]) { delete state.collapsed[path]; } else { state.collapsed[path] = true; }
    render(); focusRow(path); return;
  }
  select(path, true);
});
tree.addEventListener("keydown", function (e) {
  var row = e.target.closest ? e.target.closest(".row") : null;
  if (!row) { return; }
  var path = row.dataset.path, it = ALL[path], searching = !!(state.q.trim() || state.onlyPt);
  if (e.key === "Enter" || e.key === " ") { e.preventDefault(); select(path, true); }
  else if (e.key === "ArrowLeft" && it.kids.length && !searching) { e.preventDefault(); state.collapsed[path] = true; render(); focusRow(path); }
  else if (e.key === "ArrowRight" && it.kids.length && !searching) { e.preventDefault(); delete state.collapsed[path]; render(); focusRow(path); }
  else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    var rows = Array.prototype.slice.call(tree.querySelectorAll(".row")), nx = rows[rows.indexOf(row) + (e.key === "ArrowDown" ? 1 : -1)];
    if (nx) { nx.focus(); }
  }
});
function focusRow(path) {
  var rows = tree.querySelectorAll(".row");
  for (var i = 0; i < rows.length; i++) { if (rows[i].dataset.path === path) { rows[i].focus(); return; } }
}

// ---------- selection and links ----------
function reveal(path) {
  var it = ALL[path];
  for (var a = it; a; a = a.parent) {
    if (a !== it) { delete state.collapsed[a.path]; }
    if (a.kind === "case") {
      var f = state.filter[a.sw.path];
      if (f && f !== a.caseValue) { state.filter[a.sw.path] = a.caseValue; }
    }
  }
}
function setHash(path) {
  try {
    if (path) { if (decodeURIComponent(location.hash.slice(1)) !== path) { location.hash = path; } }
    else if (location.hash) { history.replaceState(null, "", location.pathname + location.search); }
  } catch (e) { /* a page opened where the location is not writable keeps working without the fragment */ }
}
function select(path, updateHash) {
  if (!has(ALL, path)) { return; }
  state.sel = path;
  reveal(path);
  if (updateHash) { setHash(path); }
  render();
  focusRow(path);
}
function applyHash() {
  var p = "";
  try { p = decodeURIComponent(location.hash.slice(1)); } catch (e) { p = ""; }
  if (has(ALL, p) && p !== state.sel) { state.sel = p; reveal(p); render(); }
  else if (!p && state.sel) { state.sel = ""; render(); }
}
window.addEventListener("hashchange", applyHash);

function setFilter(sw, v) {
  state.filter[sw.path] = v;
  var sel = ALL[state.sel], a = sel;
  while (a && !(a.kind === "case" && a.sw === sw)) { a = a.parent; }
  if (v && a && a.caseValue !== v) {
    var base = sw.path + "[" + sw.by + "=" + v + "]", np = base + state.sel.slice(a.path.length);
    state.sel = has(ALL, np) ? np : base;
    setHash(state.sel);
  }
  render();
}
function renderFilters() {
  filtersEl.hidden = !SWITCHES.length;
  filtersEl.innerHTML = "";
  if (!SWITCHES.length) { return; }
  var lead = document.createElement("span"); lead.textContent = "Filter:"; filtersEl.appendChild(lead);
  SWITCHES.forEach(function (sw) {
    var wrap = document.createElement("span"); wrap.className = "fgroup";
    wrap.innerHTML = '<span class="fl">' + esc(sw.title) + "</span>";
    var seg = document.createElement("div"); seg.className = "seg"; seg.setAttribute("role", "group");
    seg.setAttribute("aria-label", "Filter " + sw.title);
    [""].concat(sw.values).forEach(function (v) {
      var b = document.createElement("button"); b.type = "button"; b.textContent = v || "all";
      b.setAttribute("aria-pressed", state.filter[sw.path] === v ? "true" : "false");
      b.addEventListener("click", function () { setFilter(sw, v); });
      seg.appendChild(b);
    });
    wrap.appendChild(seg); filtersEl.appendChild(wrap);
  });
}

// ---------- detail ----------
var PT_TEXT = {
  yes: "Per target: a plain value or a token declaration (default, target keys, match), resolved for the render target.",
  markers: "May hold @NAME@ markers, substituted after the chain.",
  no: "Static: no markers, no per-target values."
};
function go(path, label) { return '<button type="button" class="link" data-go="' + esc(path) + '">' + esc(label) + "</button>"; }
function badge(it) { return '<span class="badge ty-' + esc(it.type) + '">' + esc(it.type) + "</span>"; }
function sectionsHtml(list) {
  return (list || []).map(function (s) {
    var head = Array.isArray(s.columns) ? "<thead><tr>" + s.columns.map(function (c) { return "<th>" + esc(c) + "</th>"; }).join("") + "</tr></thead>" : "";
    var body = (s.rows || []).map(function (r) { return "<tr>" + r.map(function (c) { return "<td>" + esc(c) + "</td>"; }).join("") + "</tr>"; }).join("");
    return '<div class="block"><div class="eyebrow">' + esc(s.title) + "</div>" +
      (s.doc ? '<div class="prose">' + md(s.doc) + "</div>" : "") +
      (body ? '<div class="dtable"><table>' + head + "<tbody>" + body + "</tbody></table></div>" : "") +
      (s.code ? "<pre>" + esc(String(s.code).replace(/\n$/, "")) + "</pre>" : "") + "</div>";
  }).join("");
}
function block(title, inner) { return inner ? '<div class="block"><div class="eyebrow">' + title + "</div>" + inner + "</div>" : ""; }
function keyExamples(it) {
  var seen = {}, ex = (it.examples || []).filter(function (v) { var id = JSON.stringify(v); return has(seen, id) ? false : (seen[id] = true); });
  if (ex.length) {
    return block("Examples", ex.map(function (v) { return "<pre>" + esc(toYaml(v)) + "</pre>"; }).join(""));
  }
  if (SW[it.path]) { return ""; }
  return it.example && it.example.has ? block("Example (generated)", "<pre>" + esc(toYaml(it.example.value)) + "</pre>") : "";
}
function renderDetail() {
  var it = ALL[state.sel] || ALL[""], html = "";
  if (it.kind === "case") {
    var ex = { text: toYaml(it.example.value), generated: it.example.generated };
    var rows = it.kids.map(function (k) {
      var pt = k.perTarget;
      return "<tr><td>" + go(k.path, k.label) + (k.required ? '<span class="req">*</span>' : "") + "</td><td>" + badge(k) +
        (k.shared ? ' <span class="pt pt-shared">shared</span>' : "") +
        (pt === "yes" ? ' <span class="pt pt-yes">per-target</span>' : pt === "markers" ? ' <span class="pt pt-markers">markers</span>' : "") +
        "</td><td>" + esc(k.summary) + "</td></tr>";
    }).join("");
    var others = it.sw.values.filter(function (v) { return v !== it.caseValue; }).map(function (v) { return go(it.sw.path + "[" + it.by + "=" + v + "]", v); }).join(", ");
    html = '<div class="path">' + esc(it.sw.path || "(root)") + " · " + esc(it.by) + ": " + esc(it.caseValue) + "</div>" +
      "<h3>" + esc(it.by) + ": " + esc(it.caseValue) + "</h3>" +
      (it.doc ? '<div class="prose">' + md(it.doc) + "</div>" : "") +
      block("Keys", rows ? '<div class="dtable"><table><tbody>' + rows + "</tbody></table></div>" : "") +
      block("Example" + (ex.generated ? " (generated)" : ""), "<pre>" + esc(ex.text) + "</pre>") +
      sectionsHtml(it.sections) +
      (others ? '<p class="empty-note">Other ' + esc(it.by) + "s: " + others + "</p>" : "");
  } else {
    var facts = [["Type", badge(it)]], pt2 = it.perTarget;
    if (PT_TEXT[pt2]) { facts.push(["Per target", esc(PT_TEXT[pt2])]); }
    if (it.declarationKeys) {
      facts.push(["Declaration keys", it.declarationKeys.map(function (k) { return "<code>" + esc(k) + "</code>"; }).join(", ") +
        " — an exact target goes in <code>match</code>"]);
    }
    if (it.required) { facts.push(["Required", "yes"]); }
    if (has(it.keywords, "default")) { facts.push(["Default", "<code>" + esc(JSON.stringify(it.keywords["default"])) + "</code>"]); }
    if (it.keywords.keysPattern) { facts.push(["Keys", "match <code>" + esc(it.keywords.keysPattern) + "</code>"]); }
    if (it.keywords.pattern) { facts.push(["Pattern", "<code>" + esc(it.keywords.pattern) + "</code>"]); }
    if (Array.isArray(it.keywords["enum"])) { facts.push(["Values", it.keywords["enum"].map(function (v) { return "<code>" + esc(JSON.stringify(v)) + "</code>"; }).join(", ")]); }
    var sw = SW[it.path];
    if (sw) {
      facts.push(["Switch", "by <code>" + esc(sw.by) + "</code>: " + sw.values.map(function (v) { return go(it.path + "[" + sw.by + "=" + v + "]", v); }).join(", ")]);
      if (isMap(sw.unless)) { facts.push(["Unless", "<code>" + esc(sw.unless.key + ": " + JSON.stringify(sw.unless.value)) + "</code>: only <code>" + esc(sw.by) + "</code> and <code>" + esc(sw.unless.key) + "</code> are checked"]); }
    }
    if (it.caseOf) {
      var co = it.caseOf, rest = it.path.slice(co.path.length);
      if (it.inShared) {
        facts.push(["In", "every " + esc(co.by) + ", identically: " + co.sw.values.map(function (v) {
          var p = co.sw.path + "[" + co.by + "=" + v + "]" + rest;
          return v === co.caseValue || !has(ALL, p) ? "<b>" + esc(v) + "</b>" : go(p, v);
        }).join(", ")]);
      } else {
        facts.push(["In", go(co.path, co.by + ": " + co.caseValue) + " only"]);
      }
    }
    html = '<div class="path">' + esc(it.isRoot ? "(root)" : it.path) + "</div>" +
      "<h3>" + esc(it.label) + "</h3>" +
      (it.doc ? '<div class="prose">' + md(it.doc) + "</div>" : "") +
      '<dl class="facts">' + facts.map(function (f) { return "<dt>" + f[0] + "</dt><dd>" + f[1] + "</dd>"; }).join("") + "</dl>" +
      (it.isRoot && typeof SCHEMA.$id === "string" && SCHEMA.$id ? block("Editor support", "<pre>" + esc("# yaml-language-server: $schema=" + SCHEMA.$id) + "</pre>") : "") +
      keyExamples(it) + sectionsHtml(it.sections);
  }
  detail.innerHTML = html;
}
detail.addEventListener("click", function (e) {
  var b = e.target.closest ? e.target.closest("[data-go]") : null;
  if (b) { select(b.dataset.go, true); }
});

qEl.addEventListener("input", function () { state.q = qEl.value; render(); });
document.getElementById("onlyPt").addEventListener("change", function (e) { state.onlyPt = e.target.checked; render(); });

(function init() {
  var p = "";
  try { p = decodeURIComponent(location.hash.slice(1)); } catch (e) { p = ""; }
  if (has(ALL, p)) { state.sel = p; reveal(p); }
  render();
})();
})();
</script>
</body>
</html>
{{- end -}}
