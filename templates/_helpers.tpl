{{/*
Miscellaneous small helpers with no token/rendering logic of their own.
*/}}

{{/*
Base name for the current release, following the common Helm chart
convention. Available for callers that need a truncated/sanitized name.
*/}}
{{- define "crdkit.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Looks up a named dependency's resolved version from the consuming
chart's own declared `dependencies:` (Chart.yaml). Library charts never
get their own root context — every `include` runs with whatever "." the
caller passed — so a naive `.Chart.Version` inside a library helper
would report the CONSUMING chart's version, not the library's own.
Instead, a library that wants to report its own version looks itself up
by name in the consumer's resolved dependency list (where Helm records
the version of every file://-or-repository dependency it fetched).

Falls back to "unknown" if no such dependency is found (e.g. included
some other way) rather than failing the render.

Expects a dict: { "name": <dependency name to look up>, "context": <root $> }
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
