{{/*
crdkit.integrations.chain (public)

Calls each template in "chain", in order, passing `ctx` directly — the
dispatcher for a specific library's "integration" templates.

Interface:
- Params (dict): { "chain": <list of fully-qualified template names>,
  "ctx": <root/diag/model/tokens/target dict>, "trace": <optional
  caller-owned dict> }
- Returns: nothing (each integration mutates `ctx` in place).

Implementation notes:
- Flat loop, not recursive: an integration receives plain `ctx` and does
  NOT call back into this template itself. A pre/post ("onion") need is
  met by splitting the integration into separate chain entries instead.
- `ctx` is a shared, mutate-in-place accumulator (same discipline as
  `$diag`) — never rebuilt or copied here.
- Chain entry names are the caller's own naming (e.g.
  `"mdeploy.integrations.services"`) — crdkit never needs to know another
  chart's convention.
- With `trace`, appends to `trace.stages` (created when missing):
  `{entry: "", ctx}` before the first entry, then `{entry: <template
  name>, ctx}` after each — a snapshot via
  crdkit.snapshotCtx.internal. No `trace` → no snapshot, no cost.
*/}}
{{- define "crdkit.integrations.chain" -}}
{{- $ctx := .ctx -}}
{{- $chain := .chain -}}
{{- $trace := .trace -}}
{{- if kindIs "map" $trace -}}
  {{- if not (hasKey $trace "stages") -}}{{- $_ := set $trace "stages" (list) -}}{{- end -}}
  {{- $snapshot := dict -}}
  {{- include "crdkit.snapshotCtx.internal" (dict "ctx" $ctx "out" $snapshot) -}}
  {{- $_ := set $trace "stages" (append $trace.stages (dict "entry" "" "ctx" $snapshot.ctx)) -}}
{{- end -}}
{{- range $template := $chain | default list -}}
  {{- include $template $ctx -}}
  {{- if kindIs "map" $trace -}}
    {{- $snapshot := dict -}}
    {{- include "crdkit.snapshotCtx.internal" (dict "ctx" $ctx "out" $snapshot) -}}
    {{- $_ := set $trace "stages" (append $trace.stages (dict "entry" $template "ctx" $snapshot.ctx)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
