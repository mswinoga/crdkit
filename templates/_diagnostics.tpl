{{/*
Emits accumulated diagnostics as YAML comments, prefixed exactly
`# ERROR:` / `# WARNING:` — downstream tooling greps for these exact
prefixes, so don't reformat them.

Expects a dict: { "diag": <dict with "errors"/"warnings" lists> }
*/}}
{{- define "crdkit.renderDiagnostics" -}}
{{- $diag := .diag -}}
{{- range $diag.errors }}
# ERROR: {{ . }}
{{- end }}
{{- range $diag.warnings }}
# WARNING: {{ . }}
{{- end }}
{{- end -}}
