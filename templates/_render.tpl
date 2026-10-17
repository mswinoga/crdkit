{{/*
Scope: public

The engine's entry point. Product-specific input (tokens, chain,
taxonomy) is supplied by the caller's own thin wrapper (e.g.
mycrd.render).

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
    library. Each becomes a reserved key (never a target entry) on token
    declarations; crdkit stores annotations but never interprets or
    resolves them. A name equal to a crdkit-internal key, "match" or
    "default" records an ERROR and is ignored.
  - diag: optional {errors, warnings} seed (missing lists are filled in
    with empty ones); crdkit only transports the seeded entries and
    appends new diagnostics as they arise, then emits them all
- Returns: the rendered CR as YAML text, with diagnostics prepended as
  `# ERROR:`/`# WARNING:` comments.

Implementation notes:
- Pipeline: merge tokens -> build empty ctx.model -> run the chain (the
  ONLY step that populates ctx.model) -> one substitution pass over the
  whole model -> scan for unresolved "@word@" markers (possible typos)
  -> emit diagnostics + `{{ model | toYaml }}`.
- ctx carries: root, diag, model, tokens, target, parentTargetTemplate,
  reservedKeys (list) and gen (int, starts at 0; bumped by
  crdkit.token.add / crdkit.token.underlay to invalidate resolution
  caches).
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
{{- $ctx := dict "root" $root "diag" $diag "model" $model "tokens" $tokens "target" $target "parentTargetTemplate" $parentTargetTemplate "reservedKeys" $reservedKeys "gen" 0 -}}

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
