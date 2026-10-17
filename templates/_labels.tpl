{{/*
crdkit.standardLabels (public)

Standard labels computed from Helm's own context — not called
automatically by crdkit.render; a specific library merges the result
into its own `ctx.model.metadata.labels` from within its chain (see
my-crd's `mycrd.integrations.preamble`).

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
app.kubernetes.io/name: {{ $root.Chart.Name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" $root.Chart.Name $root.Chart.Version }}
{{- end -}}
