{{/*
crdkit.render (public)

The engine's entry point. Product-specific input (tokens, chain,
taxonomy) is supplied by the caller's own thin wrapper (e.g.
mycrd.render).

Interface:
- Params (dict):
  - context: consumer's root $ (never nested under .Values.<name>.*)
  - tokens: raw consumer token declarations (may include target-keyed
    dicts)
  - target: opaque string, whatever granularity the caller's taxonomy
    uses
  - system: raw locked-token declarations (always wins over consumer
    tokens — see crdkit.tokens.merge.internal)
  - defaults: raw default-token declarations (consumer may override)
  - parentTargetTemplate: fully-qualified template name implementing
    the caller's target-escalation taxonomy — optional, defaults to
    crdkit.noParentTarget (no escalation)
  - chain: ordered list of fully-qualified integration template names
    (called in list order) — the ONLY thing that builds ctx.model
  - tokenAnnotations: optional list of token annotation names supplied
    by the library (metadata on token declarations, e.g. an owning
    service). Each becomes a reserved key (never a target entry) on token
    declarations; crdkit stores them but never interprets or
    resolves them. A name equal to a crdkit-internal key, "match" or
    "default" records an ERROR and is ignored.
  - diag: optional {errors, warnings, infos} seed (missing lists are filled in
    with empty ones); crdkit only transports the seeded entries and
    appends new diagnostics as they arise, then emits them all
  - state: optional dict whose keys are copied into ctx before the chain
    runs — library-owned data for its integrations (e.g. normalized
    input); crdkit never reads it. A key equal to a crdkit ctx key
    records an ERROR and is ignored.
- Returns: the rendered CR as YAML text, followed by its diagnostics as
  `# ERROR:`/`# WARNING:`/`# INFO:` comment lines.

Implementation notes:
- Pipeline: merge tokens -> build empty ctx.model -> run the chain (the
  ONLY step that populates ctx.model) -> one substitution pass over the
  whole model -> scan for unresolved "@word@" markers (possible typos)
  -> replace "@AT@" with "@" -> emit `{{ model | toYaml }}`, then the diagnostics.
- ctx carries: root, diag, model, tokens, target, parentTargetTemplate,
  reservedKeys (list) and gen (int, starts at 0; bumped by
  crdkit.token.add / crdkit.token.underlay to invalidate resolution
  caches), plus every accepted "state" key.
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
{{- if not (hasKey $diag "infos") -}}
  {{- $diag = set $diag "infos" (list) -}}
{{- end -}}
{{- $root := .context -}}
{{- $system := .system | default dict -}}
{{- $target := .target -}}
{{- $parentTargetTemplate := .parentTargetTemplate | default "crdkit.noParentTarget" -}}

{{- $reservedKeysYaml := include "crdkit.reservedKeys.internal" (dict
      "tokenAnnotations" (.tokenAnnotations | default (list)) "diag" $diag) -}}
{{- $reservedKeys := ($reservedKeysYaml | fromYaml).value -}}

{{- $tokensYaml := include "crdkit.tokens.merge.internal" (dict
      "tokens" .tokens "diag" $diag
      "system" $system "defaults" .defaults) -}}
{{- $tokens := $tokensYaml | fromYaml -}}

{{- $model := dict -}}
{{- $ctx := dict "root" $root "diag" $diag "model" $model "tokens" $tokens "target" $target "parentTargetTemplate" $parentTargetTemplate "reservedKeys" $reservedKeys "gen" 0 -}}
{{- range $key, $value := .state | default dict -}}
  {{- if hasKey $ctx $key -}}
    {{- include "crdkit.diag.error" (list $diag (printf "state key '%s' collides with a crdkit ctx key and was ignored" $key)) -}}
  {{- else -}}
    {{- $_ := set $ctx $key $value -}}
  {{- end -}}
{{- end -}}

{{- include "crdkit.integrations.chain" (dict "chain" .chain "ctx" $ctx) -}}

{{- $substitutedText := include "crdkit.tokens.substituteMarkers.internal" (list $ctx ($model | toYaml) $target) -}}

{{/* leftover "@word@" after substitution = possible typo; a genuine cycle is already reported elsewhere with a more specific message. Scanned before "@AT@" becomes "@", so an escaped marker is never reported. */}}
{{- $unresolvedMarkers := regexFindAll (include "crdkit.markerPattern.internal" (dict)) $substitutedText -1 -}}
{{- $substitutedModel := $substitutedText | replace "@AT@" "@" | fromYaml -}}
{{- range $marker := $unresolvedMarkers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $name "AT") (not (hasKey $tokens $name)) -}}
    {{- include "crdkit.diag.warning" (list $diag (printf "'%s' in the rendered model does not match any known token after resolution — possible typo" $marker)) -}}
  {{- end -}}
{{- end -}}

{{ $substitutedModel | toYaml }}
{{- include "crdkit.renderDiagnostics.internal" (dict "diag" $diag) }}
{{- end -}}
