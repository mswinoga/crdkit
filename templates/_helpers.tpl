{{/*
Miscellaneous small helpers with no token/rendering logic of their own.
*/}}

{{/*
crdkit.name (public)

Base name for the current release, following the common Helm chart
convention. Available for callers that need a truncated/sanitized name.

Interface:
- Params: root context (`.`).
- Returns: `.Release.Name`, truncated to 63 characters, trailing `-` removed.
*/}}
{{- define "crdkit.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
crdkit.dependencyVersion (public)

Looks up a named dependency's resolved version from the consuming
chart's own declared `dependencies:` (Chart.yaml) — how a library
reports its own version.

Interface:
- Params (dict): { "name": <dependency name to look up>, "context": <root $> }
- Returns: the dependency's version string, or `unknown` when no such
  dependency is declared (never fails the render).

Implementation notes:
- Library charts never get their own root context — every `include`
  runs with whatever "." the caller passed — so a naive `.Chart.Version`
  inside a library helper would report the CONSUMING chart's version.
  The consumer's resolved dependency list is where Helm records the
  version of every file://-or-repository dependency it fetched.
*/}}
{{- define "crdkit.dependencyVersion" -}}
{{- $name := .name -}}
{{- $root := .context -}}
{{- $found := "" -}}
{{- range $root.Chart.Dependencies -}}
  {{- if eq .Name $name -}}
    {{- $found = .Version -}}
  {{- end -}}
{{- end -}}
{{- if $found -}}
{{- $found -}}
{{- else -}}
unknown
{{- end -}}
{{- end -}}
