{{/*
Internal helpers of templates/_render.tpl and templates/_chain.tpl.
*/}}

{{/*
crdkit.snapshotCtx.internal (internal)

Builds a deep copy of ctx for the context trace. Invoked by
crdkit.integrations.chain when a `trace` dict is given.

Interface:
- Params (dict): { "ctx": <ctx>, "out": <dict, written in place> }
- Returns: ""; sets out.ctx to the snapshot.

Implementation notes:
- `root` is dropped (the chart context, not state); every declaration in
  `tokens` loses `_value`/`_gen` caches. `diag`, `model`, `gen`,
  `_generated` and state keys are kept.
- A full deep copy, so later chain mutations never rewrite an earlier
  stage's snapshot.
*/}}
{{- define "crdkit.snapshotCtx.internal" -}}
{{- $copy := deepCopy (omit .ctx "root") -}}
{{- $tokens := dict -}}
{{- range $name, $decl := ($copy.tokens | default dict) -}}
  {{- if kindIs "map" $decl -}}
    {{- $_ := set $tokens $name (omit $decl "_value" "_gen") -}}
  {{- else -}}
    {{- $_ := set $tokens $name $decl -}}
  {{- end -}}
{{- end -}}
{{- $_ := set $copy "tokens" $tokens -}}
{{- $_ := set .out "ctx" $copy -}}
{{- end -}}
