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
    `state.input` / `state.schema`;
  - `ops` → run by `stub.ops`, the only chain entry;
  - `reportSeed: true` → appends `seed: {errors: <n>}`, the length of
    the caller's seed `errors` after the render.
- Returns: the `crdkit.render` text (+ the `seed` line).

Implementation notes:
- The default seed holds all three lists: a pre-render pass
  (`schema.validate`) appends to them before `crdkit.render` fills in
  missing ones.
*/}}
{{- define "stub.render" -}}
{{- $v := .Values | toYaml | fromYaml -}}
{{- $args := dict "context" . "tokens" ($v.tokens | default dict) "target" $v.target
      "system" ($v.system | default dict) "chain" (list "stub.ops")
      "tokenAnnotations" ($v.annotations | default list) "state" ($v.state | default dict) -}}
{{- if $v.ladder -}}{{- $_ := set $args "parentTargetTemplate" "stub.parentTarget" -}}{{- end -}}
{{- $diag := dict "errors" (list) "warnings" (list) "infos" (list) -}}
{{- if hasKey $v "diag" -}}{{- $diag = $v.diag -}}{{- end -}}
{{- $_ := set $args "diag" $diag -}}
{{- if $v.schema -}}
  {{- $input := (include "crdkit.schema.validate" (dict "schema" $v.schema "values" ($v.input | default dict) "diag" $diag) | fromYaml).value -}}
  {{- $_ := set $args "state" (merge (dict "schema" $v.schema "input" $input) $args.state) -}}
{{- end -}}
{{- include "crdkit.render" $args }}
{{- if $v.reportSeed }}
seed: {errors: {{ len ($diag.errors | default list) }}}
{{- end -}}
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
stub.ops (test)

The stub's only chain integration. Invoked by `crdkit.integrations.chain`.
Sets `kind: Stub`, then runs `.Values.ops` in list order.

Interface:
- Param: ctx.
- Ops (one key selects the op):
  - `{put: [k1..kN], value}` — `crdkit.dictMerge`: model.k1…kN = value;
  - `{add: name, value, annotations?, target?}` — `crdkit.token.add`;
  - `{underlay: name, value, annotations?, target?}` —
    `crdkit.token.underlay`;
  - `{diag: error|warning|info, msg}` — `crdkit.diag.<level>`;
  - `{resolve: [keys], at: [k1..kN]}` — `crdkit.schema.resolve` of
    `ctx.input` against `ctx.schema` (set by `stub.render` from
    `schema` + `input`) → model.k1…kN.
- Returns: "".
*/}}
{{- define "stub.ops" -}}
{{- $ctx := . -}}
{{- include "crdkit.dictMerge" (list $ctx.model (dict "kind" "Stub")) -}}
{{- range $op := ($ctx.root.Values | toYaml | fromYaml).ops | default list -}}
  {{- if hasKey $op "put" -}}
    {{- include "crdkit.dictMerge" (concat (list $ctx.model) (initial $op.put) (list (dict (last $op.put) $op.value))) -}}
  {{- else if hasKey $op "add" -}}
    {{- include "crdkit.token.add" (list $ctx $op.add $op.value ($op.annotations | default dict) ($op.target | default "")) -}}
  {{- else if hasKey $op "underlay" -}}
    {{- include "crdkit.token.underlay" (list $ctx $op.underlay $op.value ($op.annotations | default dict) ($op.target | default "")) -}}
  {{- else if hasKey $op "diag" -}}
    {{- include (printf "crdkit.diag.%s" $op.diag) (list $ctx.diag $op.msg) -}}
  {{- else if hasKey $op "resolve" -}}
    {{- $r := (include "crdkit.schema.resolve" (dict "ctx" $ctx "schema" $ctx.schema "values" $ctx.input "keys" $op.resolve) | fromYaml).value -}}
    {{- include "crdkit.dictMerge" (concat (list $ctx.model) (initial $op.at) (list (dict (last $op.at) $r))) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
