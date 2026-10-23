{{/*
crdkit.standardLabels (public)

Standard labels from Helm's context, for a library's chain to merge into
`ctx.model.metadata.labels` (crdkit.render never adds them).

Interface:
- Params (dict): { "context": <root $> }
- Returns: YAML text of the four standard `app.kubernetes.io/*` +
  `helm.sh/chart` labels.

Implementation notes:
- Uses the CONSUMING chart's `.Chart.Name`/`.Version` (standard Helm
  convention for `helm.sh/chart`) — use `crdkit.dependencyVersion` for a
  library's own version instead.
- Precedence is entirely the caller's choice, via merge order at the
  `crdkit.dictMerge` call site — this helper has no opinion.
*/}}
{{- define "crdkit.standardLabels" -}}
{{- $root := .context -}}
app.kubernetes.io/name: {{ $root.Chart.Name | quote }}
app.kubernetes.io/instance: {{ $root.Release.Name | quote }}
app.kubernetes.io/managed-by: {{ $root.Release.Service | quote }}
helm.sh/chart: {{ printf "%s-%s" $root.Chart.Name $root.Chart.Version | quote }}
{{- end -}}
