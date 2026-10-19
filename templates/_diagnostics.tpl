{{/*
crdkit.diag.error (public)

Records an error diagnostic: appends `message` to `diag.errors` in place.
Libraries and crdkit itself record every error through this template.

Interface:
- Params (list): [diag, message]
  - diag (dict): the `{errors, warnings}` dict (a caller holding `ctx`
    passes `$ctx.diag`)
  - message (string)
- Returns: "" (a bare `include` is safe)
*/}}
{{- define "crdkit.diag.error" -}}
{{- $diag := index . 0 -}}
{{- $_ := set $diag "errors" (append $diag.errors (index . 1)) -}}
{{- end -}}

{{/*
crdkit.diag.warning (public)

Records a warning diagnostic: appends `message` to `diag.warnings` in
place. Libraries and crdkit itself record every warning through this
template.

Interface:
- Params (list): [diag, message]
  - diag (dict): the `{errors, warnings}` dict (a caller holding `ctx`
    passes `$ctx.diag`)
  - message (string)
- Returns: "" (a bare `include` is safe)
*/}}
{{- define "crdkit.diag.warning" -}}
{{- $diag := index . 0 -}}
{{- $_ := set $diag "warnings" (append $diag.warnings (index . 1)) -}}
{{- end -}}
