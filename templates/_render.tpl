{{/*
Scope: public

Interface:
- Params (dict):
  - context: consumer's root $ (never nested under .Values.<name>.*)
  - tokens: .Values.tokens (raw, may include target-keyed dicts)
  - target: .Values.target — opaque string, whatever granularity the
    caller's taxonomy uses
  - system: raw locked-token declarations (always wins over consumer
    tokens — see crdkit.tokens.merge.internal)
  - defaults: raw default-token declarations (consumer may override)
  - parentTargetTemplate: fully-qualified template name implementing
    the caller's target-escalation taxonomy — optional, defaults to
    crdkit.noParentTarget (no escalation)
  - chain: ordered list of fully-qualified integration template names
    (head = outermost) — the ONLY thing that builds ctx.model
  - annotations: optional list of annotation names supplied by the
    library; these become reserved keys alongside crdkit's built-in ones
  - diag: optional {errors, warnings} seed; crdkit only transports its
    entries and appends new diagnostics as they arise
- Returns: the rendered CR as YAML text, with diagnostics prepended as
  `# ERROR:`/`# WARNING:` comments.
- The engine's entry point. Product-specific input (tokens, chain,
  taxonomy) is supplied by the caller's own thin wrapper (e.g.
  mycrd.render).

Implementation notes:
- Pipeline: merge tokens -> build empty ctx.model -> run the chain (the
  ONLY step that populates ctx.model) -> one substitution pass over the
  whole model -> scan for unresolved "@word@" markers (possible typos)
  -> emit diagnostics + `{{ model | toYaml }}`.
- Never reads `context.Values` itself, and has no opinion on
  apiVersion/kind/labels/spec — entirely the chain's responsibility via
  crdkit.dictMerge/listExtend/ensureDictKey.
- No proactive "target is required" check — an unset target is only
  diagnosed lazily, if something resolves against it and the walk
  finds nothing.
*/}}
{{- define "crdkit.render" -}}
{{- $diag := .diag | default dict -}}
{{- if not (hasKey $diag "errors") -}}
  {{- $diag = set $diag "errors" (list) -}}
{{- end -}}
{{- if not (hasKey $diag "warnings") -}}
  {{- $diag = set $diag "warnings" (list) -}}
{{- end -}}
{{- $root := .context -}}
{{- $system := .system | default dict -}}
{{- $target := .target -}}
{{- $parentTargetTemplate := .parentTargetTemplate | default "crdkit.noParentTarget" -}}

{{- $reservedKeysYaml := include "crdkit.reservedKeys.internal" (dict
      "annotations" (.annotations | default (list)) "diag" $diag) -}}
{{- $reservedKeys := ($reservedKeysYaml | fromYaml).value -}}

{{- $tokensYaml := include "crdkit.tokens.merge.internal" (dict
      "tokens" .tokens "diag" $diag
      "system" $system "defaults" .defaults) -}}
{{- $tokens := $tokensYaml | fromYaml -}}

{{- $model := dict -}}
{{- $ctx := dict "root" $root "diag" $diag "model" $model "tokens" $tokens "target" $target "parentTargetTemplate" $parentTargetTemplate "reservedKeys" $reservedKeys -}}

{{- include "crdkit.integrations.chain" (dict "chain" .chain "ctx" $ctx) -}}

{{- $substitutedText := include "crdkit.tokens.substitute" (list $ctx ($model | toYaml) $target) -}}
{{- $substitutedModel := $substitutedText | fromYaml -}}

{{/* leftover "@word@" after substitution = possible typo; a genuine cycle is already reported elsewhere with a more specific message. */}}
{{- $unresolvedMarkers := regexFindAll "@[A-Za-z0-9_]+@" $substitutedText -1 -}}
{{- range $marker := $unresolvedMarkers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if not (hasKey $tokens $name) -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "'%s' in the rendered model does not match any known token after resolution — possible typo" $marker)) -}}
  {{- end -}}
{{- end -}}

{{- include "crdkit.renderDiagnostics.internal" (dict "diag" $diag) }}
{{ $substitutedModel | toYaml }}
{{- end -}}
