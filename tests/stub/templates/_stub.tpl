{{/*
stub.render (test)

Minimal library on crdkit's public API, so a crdkit contract test is
values only. Invoked by `cr.yaml` (through `test.withDiagnostics`).

Interface:
- Param: the chart root `$`.
- Values read:
  - `tokens`, `target`, `system`, `state` → the `crdkit.render` params
    of the same name;
  - `annotations` (list) → `tokenAnnotations`;
  - `diag` → the `diag` seed, only when the key is present;
  - `ladder` (map rung → parent rung) → `parentTargetTemplate:
    stub.parentTarget`;
  - `schema` + `input` → `crdkit.schema.validate` before the render;
    the validated input and the schema reach the chain as
    `state.input` / `state.schema` (and `state.seen` starts as `{}`);
  - `ops` → run by `stub.ops`, the only chain entry;
  - `reportSeed: true` → appends `seed: {errors: <n>}`, the length of
    the caller's seed `errors` after the render;
  - `trace: true` → passes `trace: {}` and appends `trace: <compact
    JSON>`.
- Returns: the `crdkit.render` text (+ the `seed`/`trace` lines).

Implementation notes:
- `state` is a fresh copy; `seen` is the shared de-duplication dict of
  the schema ops.
- The default seed holds all three lists: a pre-render pass
  (`schema.validate`) appends to them before `crdkit.render` fills in
  missing ones.
*/}}
{{- define "stub.render" -}}
{{- $v := .Values | toYaml | fromYaml -}}
{{- $state := $v.state | default dict -}}
{{- $_ := set $state "seen" (dict) -}}
{{- $args := dict "context" . "tokens" ($v.tokens | default dict) "target" $v.target
      "system" ($v.system | default dict) "defaults" ($v.defaults | default dict) "chain" (list "stub.ops")
      "tokenAnnotations" ($v.annotations | default list) "state" $state -}}
{{- if $v.ladder -}}{{- $_ := set $args "parentTargetTemplate" "stub.parentTarget" -}}{{- end -}}
{{- $diag := dict "errors" (list) "warnings" (list) "infos" (list) -}}
{{- if hasKey $v "diag" -}}{{- $diag = $v.diag -}}{{- end -}}
{{- $_ := set $args "diag" $diag -}}
{{- if $v.trace -}}{{- $_ := set $args "trace" (dict) -}}{{- end -}}
{{- if $v.schema -}}
  {{- $input := (include "crdkit.schema.validate" (dict "schema" $v.schema "values" ($v.input | default dict) "diag" $diag) | fromYaml).value -}}
  {{- $_ := set $args "state" (merge (dict "schema" $v.schema "input" $input) $args.state) -}}
{{- end -}}
{{- include "crdkit.render" $args }}
{{- if $v.reportSeed }}
seed: {errors: {{ len ($diag.errors | default list) }}}
{{- end -}}
{{- if $v.trace }}
trace: {{ (index $args "trace") | toJson | quote }}
{{- end }}
{{- end -}}

{{/*
stub.parentTarget (test)

`parentTargetTemplate` hook of `stub.render`. Invoked by crdkit's
ladder walk.

Interface:
- Params: `{target, context}`.
- Returns: `.Values.ladder[target]`, or empty at the top of the ladder.
*/}}
{{- define "stub.parentTarget" -}}
{{- $ladder := .context.Values.ladder | default dict -}}
{{- if hasKey $ladder .target -}}{{- index $ladder .target -}}{{- end -}}
{{- end -}}

{{/*
stub.write (test)

Writes `value` at the `at` path of `model`, creating map levels.
Invoked by `stub.ops` for ops whose result is not a map merge.

Interface:
- Params: `{model, at, value}` (`at` has at least one element).
- Returns: "".
*/}}
{{- define "stub.write" -}}
{{- $node := .model -}}
{{- range $key := initial .at -}}
  {{- if not (hasKey $node $key) -}}{{- $_ := set $node $key (dict) -}}{{- end -}}
  {{- $node = index $node $key -}}
{{- end -}}
{{- $_ := set $node (last .at) .value -}}
{{- end -}}

{{/*
stub.ops (test)

The stub's only chain integration. Invoked by `crdkit.integrations.chain`.
Sets `kind: Stub`, then runs `.Values.ops` in list order.

Interface:
- Param: ctx.
- Ops (the key selects the op; `at` is a model path written through
  `stub.write`):
  - `{put: [k1..kN], value}` — `crdkit.dictMerge`;
  - `{listExtend: [k1..kN], value}` — `crdkit.listExtend`;
  - `{ensureDictKey: key, default}` — `crdkit.ensureDictKey`;
  - `{hasPath: [k1..kN], at}` — `crdkit.model.hasPath`;
  - `{add|underlay: name, value, annotations?, target?}` —
    `crdkit.token.add` / `crdkit.token.underlay`;
  - `{tokenValue: name, target?, at}` · `{tokenString: name, target?,
    at}` — `crdkit.token.value` (`.value`) · `crdkit.token.string`;
  - `{tokenDef: <decl>, id, target?, string?, at}` —
    `crdkit.tokenDef.value` / `crdkit.tokenDef.string`;
  - `{substitute: text, target?, at}` — `crdkit.tokens.substitute`;
  - `{matchRules: rules, subject, consumer?, at}` — `crdkit.matchRules`
    (`consumer: true` → `diag` + `label: rules`);
  - `{diag: error|warning|info, msg}` — `crdkit.diag.<level>`;
  - `{state: key, at}` — copies `ctx.<key>` of a `state` key;
  - `{check: {}, at}` — `crdkit.schema.check` of `ctx.schema`;
  - `{validateValues: {path?, target?}}` — `crdkit.schema.validateValues`
    of `ctx.input` (its `seen` effects are readable through `state`);
  - `{resolve: [k1..kN], target?, at}` — `crdkit.schema.resolve`;
  - `{schemaValue: {node, def | token, path, target?}, at}` —
    `crdkit.schema.value`;
  - `{node: [k1..kN], at}` — `crdkit.schema.node`;
  - `{path: {keys, path?}, at}` — `crdkit.schema.path`;
  - `{labels: {}, at}` — `crdkit.standardLabels`;
  - `{dependencyVersion: name, at}` — `crdkit.dependencyVersion`;
  - `{name: {}, at}` — `crdkit.name`.
- Returns: "".
*/}}
{{- define "stub.ops" -}}
{{- $ctx := . -}}
{{- $v := $ctx.root.Values | toYaml | fromYaml -}}
{{- include "crdkit.dictMerge" (list $ctx.model (dict "kind" "Stub")) -}}
{{- range $op := $v.ops | default (list) -}}
  {{- if hasKey $op "put" -}}
    {{- if $op.put -}}
      {{- include "crdkit.dictMerge" (concat (list $ctx.model) (initial $op.put) (list (dict (last $op.put) $op.value))) -}}
    {{- else -}}
      {{- include "crdkit.dictMerge" (list $ctx.model $op.value) -}}
    {{- end -}}
  {{- else if hasKey $op "listExtend" -}}
    {{- include "crdkit.listExtend" (concat (list $ctx.model) $op.listExtend (list $op.value)) -}}
  {{- else if hasKey $op "ensureDictKey" -}}
    {{- include "crdkit.ensureDictKey" (dict "model" $ctx.model "key" $op.ensureDictKey "default" $op.default) -}}
  {{- else if hasKey $op "hasPath" -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.model.hasPath" (concat (list $ctx.model) $op.hasPath))) -}}
  {{- else if hasKey $op "add" -}}
    {{- include "crdkit.token.add" (list $ctx $op.add $op.value ($op.annotations | default dict) ($op.target | default "")) -}}
  {{- else if hasKey $op "underlay" -}}
    {{- include "crdkit.token.underlay" (list $ctx $op.underlay $op.value ($op.annotations | default dict) ($op.target | default "")) -}}
  {{- else if hasKey $op "tokenValue" -}}
    {{- $r := (include "crdkit.token.value" (list $ctx $op.tokenValue ($op.target | default "")) | fromYaml).value -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
  {{- else if hasKey $op "tokenString" -}}
    {{- $r := include "crdkit.token.string" (list $ctx $op.tokenString ($op.target | default "")) -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
  {{- else if hasKey $op "tokenDef" -}}
    {{- if $op.string -}}
      {{- $r := include "crdkit.tokenDef.string" (list $ctx $op.id $op.tokenDef ($op.target | default "")) -}}
      {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
    {{- else -}}
      {{- $r := (include "crdkit.tokenDef.value" (list $ctx $op.id $op.tokenDef ($op.target | default "")) | fromYaml).value -}}
      {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
    {{- end -}}
  {{- else if hasKey $op "substitute" -}}
    {{- $r := include "crdkit.tokens.substitute" (list $ctx $op.substitute ($op.target | default "")) -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
  {{- else if hasKey $op "matchRules" -}}
    {{- $args := dict "subject" $op.subject "rules" $op.matchRules -}}
    {{- if $op.consumer -}}{{- $_ := set $args "diag" $ctx.diag -}}{{- $_ := set $args "label" "rules" -}}{{- end -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.matchRules" $args | fromYaml)) -}}
  {{- else if hasKey $op "diag" -}}
    {{- include (printf "crdkit.diag.%s" $op.diag) (list $ctx.diag $op.msg) -}}
  {{- else if hasKey $op "state" -}}
    {{- if hasKey $ctx $op.state -}}
      {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (index $ctx $op.state)) -}}
    {{- end -}}
  {{- else if hasKey $op "check" -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.schema.check" (dict "schema" $ctx.schema "diag" $ctx.diag))) -}}
  {{- else if hasKey $op "validateValues" -}}
    {{- $a := $op.validateValues -}}
    {{- include "crdkit.schema.validateValues" (dict "ctx" $ctx "schema" $ctx.schema "values" $ctx.input "path" ($a.path | default "") "target" ($a.target | default "") "seen" $ctx.seen) -}}
  {{- else if hasKey $op "resolve" -}}
    {{- $r := (include "crdkit.schema.resolve" (dict "ctx" $ctx "schema" $ctx.schema "values" $ctx.input "keys" $op.resolve "target" ($op.target | default "") "seen" $ctx.seen) | fromYaml).value -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
  {{- else if hasKey $op "schemaValue" -}}
    {{- $a := $op.schemaValue -}}
    {{- $r := (include "crdkit.schema.value" (dict "ctx" $ctx "node" $a.node "def" ($a.def | default dict) "token" ($a.token | default "") "path" $a.path "target" ($a.target | default "") "seen" $ctx.seen) | fromYaml).value -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" $r) -}}
  {{- else if hasKey $op "node" -}}
    {{- $r := include "crdkit.schema.node" (dict "schema" $ctx.schema "values" $ctx.input "keys" $op.node) | fromYaml -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (dict "found" (hasKey $r "value") "value" $r.value)) -}}
  {{- else if hasKey $op "path" -}}
    {{- $a := $op.path -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.schema.path" (dict "keys" $a.keys "path" ($a.path | default "")))) -}}
  {{- else if hasKey $op "labels" -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.standardLabels" (dict "context" $ctx.root) | fromYaml)) -}}
  {{- else if hasKey $op "dependencyVersion" -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.dependencyVersion" (dict "name" $op.dependencyVersion "context" $ctx.root))) -}}
  {{- else if hasKey $op "name" -}}
    {{- include "stub.write" (dict "model" $ctx.model "at" $op.at "value" (include "crdkit.name" $ctx.root)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
