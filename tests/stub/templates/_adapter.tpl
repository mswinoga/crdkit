{{/*
test.withDiagnostics (test)

Repeats a render's diagnostic comment lines as data so helm-unittest
can assert them (it cannot see comments). Invoked by `cr.yaml` around
the library entry point.

Interface:
- Param: the render text (string).
- Returns: the text unchanged, then a top-level
  `diagnostics: {error: [..], warning: [..], info: [..]}` holding each
  `# ERROR:` / `# WARNING:` / `# INFO:` line without its prefix, in
  output order per level.

Implementation notes:
- A level key exists only when it has lines; `diagnostics` exists only
  when any level has lines (a clean render has no `diagnostics` key).
- Parses only the `# LEVEL: ` prefix (the consumer contract), never
  message text.
*/}}
{{- define "test.withDiagnostics" -}}
{{- $out := . -}}
{{- $d := dict -}}
{{- range $level := list "error" "warning" "info" -}}
  {{- $prefix := printf "# %s: " (upper $level) -}}
  {{- $lines := list -}}
  {{- range regexFindAll (printf "(?m)^%s.*$" $prefix) $out -1 -}}
    {{- $lines = append $lines (trimPrefix $prefix .) -}}
  {{- end -}}
  {{- if $lines -}}{{- $_ := set $d $level $lines -}}{{- end -}}
{{- end -}}
{{ $out }}
{{- if $d }}
diagnostics:
{{- toYaml $d | nindent 2 }}
{{- end }}
{{- end -}}
