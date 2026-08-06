{{/*
Emits accumulated diagnostics as YAML comments, prefixed exactly
`# ERROR:` / `# WARNING:` — downstream tooling greps for these exact
prefixes, so don't reformat them.

Deduplicates (Sprig's `uniq`, order-preserving) before printing —
defense-in-depth against the same diagnostic text getting appended more
than once. Concretely: values are resolved lazily, on demand, by
crdkit.resolveValue/substituteTokens rather than computed once up
front, so a genuinely broken "target" CAN get diagnosed by more than
one call site in the same render (e.g. once per distinct "@NAME@"
marker referencing a token that shares the same broken target chain).
Deduping here is simpler and more robust than trying to guarantee every
such call site diagnoses at most once — this only affects the rendered COMMENT output,
not $diag itself, so anything asserting against raw diag.errors/
diag.warnings (e.g. the test harness) still sees the undeduplicated list.

Expects a dict: { "diag": <dict with "errors"/"warnings" lists> }
*/}}
{{- define "crdkit.renderDiagnostics.internal" -}}
{{- $diag := .diag -}}
{{- range uniq $diag.errors }}
# ERROR: {{ . }}
{{- end }}
{{- range uniq $diag.warnings }}
# WARNING: {{ . }}
{{- end }}
{{- end -}}
