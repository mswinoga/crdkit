{{/*
Standard labels computed by the framework itself — NOT token-
substituted, since they come from Helm's own context (.Chart/.Release),
not consumer values. Kept separate from consumer-supplied labels
deliberately: these are guaranteed present and correctly formed
regardless of what a consumer does or doesn't set under metadata.labels.

This intentionally uses the CONSUMING chart's .Chart.Name/.Version (the
standard Helm convention for helm.sh/chart) — for a library's own
version use crdkit.dependencyVersion instead.

Expects a dict: { "context": <root $> }
*/}}
{{- define "crdkit.standardLabels" -}}
{{- $root := .context -}}
app.kubernetes.io/name: {{ $root.Chart.Name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" $root.Chart.Name $root.Chart.Version }}
{{- end -}}
