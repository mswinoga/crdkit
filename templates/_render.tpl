{{/*
Generic render engine — the framework's entry point. Every product-
specific bit (system/default tokens, apiVersion/kind, the integration
chain) is supplied by the CALLER's own thin wrapper (e.g. mycrd.render)
as an explicit param; crdkit never hardcodes another chart's template
names, so it stays reusable across any number of specific CRD libraries.

Pipeline:
  0. derive "env" from "target" (crdkit.deriveTargetEnv) — a
     malformed/missing target records an ERROR and env resolves to
     "", which simply won't match anything in tier 2 of
     crdkit.resolveTokenValue, falling through to family/super-tier/
     default same as any other unrecognized env would.
  1. resolve tokens (system/default/user merge + recursive @ref@
     resolution) -> a flat, mutable "resolvedTokens" dict, handed to the
     chain via ctx.tokens so integrations can branch on already-resolved
     VALUES immediately if they need to (distinct from marker
     substitution below, which is deferred).
  2. run the integration chain against a shared "model" accumulator.
     crdkit does NOT know this shape, and there's no central place that
     pre-declares it — model starts as a bare empty dict, and every
     field on it (including "labels", which crdkit itself reads at step
     5) is lazily created on first touch via crdkit.ensureDictKey, by
     whichever integration touches it first. Filters may also mutate
     ctx.tokens itself (e.g. to contribute a derived token) — see
     crdkit.integrations.chain and README caveats: visibility is
     order-dependent, and a token added mid-chain does NOT get another
     pass through the recursive @ref@ resolver, so it must already be
     fully resolved when inserted.
  3. re-assert locked ("system") AND computed (crdkit.builtinTokens,
     e.g. "ENV") tokens over the (possibly chain-mutated) resolved map,
     unconditionally — the same "locked always wins" guarantee that
     applies to user-supplied tokens must also hold against
     integration-code mutation, otherwise a chain filter could silently
     defeat it with no diagnostic ever firing. "ENV" is exposed as an
     ordinary "@ENV@"-substitutable token this same way, alongside
     being the plain string value tokens.* dicts are looked up by — see
     crdkit.resolveAllTokens for why user-supplied tokens.ENV is
     rejected the same way tokens.AT is. Re-assertion re-resolves each
     raw system/builtin declaration via crdkit.resolveToken rather than
     merging the raw dicts directly over $resolvedTokens — $resolvedTokens
     is struct-shaped ({value, targetContainer}) by this point, while
     $system/$builtinTokensRaw are still raw declarations, so a naive
     merge would corrupt the shape for exactly the keys being reasserted.
  4. NOW do marker substitution — a single textual pass over the
     consumer's raw structure, using the fully-finalized token map. This
     runs AFTER the chain (not before) so integration-authored "@token@"
     references get resolved too, not just consumer-authored ones.
  5. merge in the framework's standard labels + whatever the chain
     contributed to model.labels.
  6. prepend accumulated diagnostics as `# ERROR:`/`# WARNING:` comments.

TODO: only "labels" from the model is wired into the output below —
that's the one field crdkit itself knows about. How the REST of
"model" (whatever fields integrations chose to populate) maps into
"spec" is inherently specific-library knowledge crdkit can't have; that
mapping still needs a design once the real CRD spec shape is known (a
future hook analogous to the integration chain, most likely — not
resolved here).

Expects a dict:
  context    - the consumer's root $ (per spec, always the CONSUMING
               chart's root — this library is never a normal subchart
               with values nested under .Values.<name>.*)
  tokens     - .Values.tokens (raw, may include env-varying dicts)
  target     - .Values.target — the CLI/release-level value env is
               derived from; see crdkit.deriveTargetEnv. Usually just
               "env" directly (e.g. "prod"); optionally "<env>-<seq>"
               (seq = 2 digits, e.g. "prod-01") for the minority of
               CRDs needing multiple numbered instances of the same
               env. Not to be confused with "the CRD this renders"
               below, despite the name collision — this is the env/seq
               identifier, that's apiVersion/kind.
  system     - resolved system-tokens dict (locked, always wins)
  defaults   - resolved default-tokens dict (consumer may override)
  apiVersion - the rendered CRD's apiVersion, e.g. "platform.company.io/v1"
  kind       - the rendered CRD's kind, e.g. "SomeCR"
  chain      - ordered list of fully-qualified integration template
               names (head = outermost filter)
*/}}
{{- define "crdkit.render" -}}
{{- $diag := dict "errors" (list) "warnings" (list) -}}
{{- $root := .context -}}
{{- $system := .system | default dict -}}
{{- $target := .target -}}

{{- $builtinTokensRaw := include "crdkit.builtinTokens" (dict "target" $target "diag" $diag) | fromYaml -}}
{{- $env := $builtinTokensRaw.ENV -}}

{{- $resolvedTokensYaml := include "crdkit.resolveAllTokens" (dict
      "tokens" .tokens "env" $env "target" $target "diag" $diag
      "system" $system "defaults" .defaults "builtinTokens" $builtinTokensRaw) -}}
{{- $resolvedTokens := $resolvedTokensYaml | fromYaml -}}

{{/* no pre-declared shape — see crdkit.ensureDictKey. Every field,
     including "labels" below, is created lazily on first touch by
     whichever integration needs it first. */}}
{{- $model := dict -}}
{{- $ctx := dict "root" $root "diag" $diag "model" $model "tokens" $resolvedTokens -}}
{{- include "crdkit.integrations.chain" (dict "chain" .chain "ctx" $ctx) -}}

{{/* re-assert locked + computed tokens unconditionally, even against
     chain-code mutation — re-resolved individually via crdkit.resolveToken
     since $resolvedTokens is struct-shaped and $system/$builtinTokensRaw
     are still raw declarations (see pipeline doc above). */}}
{{- range $name, $raw := $system -}}
  {{- $resolved := include "crdkit.resolveToken" (dict "raw" $raw "env" $env "target" $target "diag" $diag "fieldName" (printf "system.%s" $name)) | fromYaml -}}
  {{- $resolvedTokens = set $resolvedTokens $name $resolved -}}
{{- end -}}
{{- range $name, $raw := $builtinTokensRaw -}}
  {{- $resolved := include "crdkit.resolveToken" (dict "raw" $raw "env" $env "target" $target "diag" $diag "fieldName" (printf "builtin.%s" $name)) | fromYaml -}}
  {{- $resolvedTokens = set $resolvedTokens $name $resolved -}}
{{- end -}}

{{- $structureYaml := omit $root.Values "tokens" | toYaml -}}
{{- $substituted := include "crdkit.substituteTokens" (dict "text" $structureYaml "tokens" $resolvedTokens "applyAt" true) -}}
{{- $substitutedValues := $substituted | fromYaml -}}

{{/* unresolved-marker check: anything still shaped like @word@ in the final
     substituted text after a full pass is either a typo'd reference to a
     token that was never defined, or a genuine cycle already caught by
     crdkit.resolveTokensRecursive above (that case is reported there, with
     a more specific message naming the token and the cycle — avoid a
     duplicate/less-informative warning here for those). */}}
{{- $unresolvedMarkers := regexFindAll "@[A-Za-z0-9_]+@" $substituted -1 -}}
{{- range $marker := $unresolvedMarkers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if not (hasKey $resolvedTokens $name) -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "'%s' in the rendered structure does not match any known token after resolution — possible typo" $marker)) -}}
  {{- end -}}
{{- end -}}

{{/* precedence, earlier wins (plain `merge` semantics): standardLabels is
     guaranteed present/correct and always wins on collision; consumer
     labels win over anything the integration chain contributed; model
     labels only fill in keys nobody else claimed. Swap the order below
     to change precedence. */}}
{{- include "crdkit.ensureDictKey" (dict "model" $model "key" "labels" "default" (dict)) -}}
{{- $standardLabels := include "crdkit.standardLabels" (dict "context" $root) | fromYaml -}}
{{- $consumerLabels := dig "metadata" "labels" (dict) $substitutedValues -}}
{{- $finalLabels := merge (dict) $standardLabels $consumerLabels $model.labels -}}

{{- include "crdkit.renderDiagnostics" (dict "diag" $diag) -}}
apiVersion: {{ .apiVersion }}
kind: {{ .kind }}
metadata:
  name: {{ $root.Release.Name }}
  labels:
{{ $finalLabels | toYaml | indent 4 }}
spec:
{{ $substitutedValues.spec | toYaml | indent 2 }}
{{- end -}}
