{{/*
crdkit.renderDiagnostics.internal (internal)

Emits accumulated diagnostics — downstream tooling greps for these exact
prefixes, so don't reformat them.

Interface:
- Params (dict): { "diag": <dict with "errors"/"warnings" lists,
  optional "infos" list> }
- Returns: YAML comment lines, prefixed exactly `# ERROR:` / `# WARNING:`
  / `# INFO:`, in that order.

Implementation notes:
- Dedupes (`uniq`, order-preserving) before printing: lazy, on-demand
  resolution means the same broken target can get diagnosed by more
  than one call site (e.g. once per `@NAME@` marker sharing that
  target). Only affects the printed comments — raw `diag.errors`/
  `diag.warnings`/`diag.infos` (e.g. what tests assert against) stay
  undeduplicated.
*/}}
{{- define "crdkit.renderDiagnostics.internal" -}}
{{- $diag := .diag -}}
{{- range uniq $diag.errors }}
# ERROR: {{ . }}
{{- end }}
{{- range uniq $diag.warnings }}
# WARNING: {{ . }}
{{- end }}
{{- range uniq (get $diag "infos" | default list) }}
# INFO: {{ . }}
{{- end }}
{{- end -}}
