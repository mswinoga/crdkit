{{/*
Standard labels, computed from Helm's own context (.Chart/.Release), not
consumer values. A plain, product-agnostic helper — crdkit.render does
NOT call this automatically (it doesn't touch ctx.model at all; see
crdkit's CLAUDE.md). A specific library merges this into its own
ctx.model.metadata.labels from within its chain (by convention, its
"preamble" integration, before any other integration runs — see my-crd's
mycrd.integration.preamble) via crdkit.dictMerge, the same way it sets
apiVersion/kind. That call site is also what decides precedence: merge
this in AFTER the consumer's own metadata.labels but BEFORE recursing
into the rest of the chain, and it protects against an accidental
consumer clash without needing any special "always wins" semantics here
— a later chain integration can still deliberately override a key
afterward, same as it can for anything else in ctx.model.

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
