{{/*
Scope: public

Interface:
- Params (dict): { "chain": <list of fully-qualified template names>,
  "ctx": <root/diag/model/tokens/target dict> }
- Returns: nothing (each integration mutates `ctx` in place).
- Calls each template in "chain", in order, passing `ctx` directly — the
  dispatcher for a specific library's "integration" templates.

Implementation notes:
- Flat loop, not recursive: an integration receives plain `ctx` and does
  NOT call back into this template itself. A pre/post ("onion") need is
  met by splitting the integration into separate chain entries instead.
- `ctx` is a shared, mutate-in-place accumulator (same discipline as
  `$diag`) — never rebuilt or copied here.
- Chain entry names are the caller's own naming (e.g.
  `"mycrd.integrations.database"`) — crdkit never needs to know another
  chart's convention.
*/}}
{{- define "crdkit.integrations.chain" -}}
{{- $ctx := .ctx -}}
{{- $chain := .chain -}}
{{- range $template := $chain | default list -}}
  {{- include $template $ctx -}}
{{- end -}}
{{- end -}}
