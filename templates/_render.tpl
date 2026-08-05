{{/*
Generic render engine — the framework's entry point. Every product-
specific bit (system/default tokens, apiVersion/kind, the integration
chain) is supplied by the CALLER's own thin wrapper (e.g. mycrd.render)
as an explicit param; crdkit never hardcodes another chart's template
names, so it stays reusable across any number of specific CRD libraries.

Pipeline:
  0. derive "env" from "target" (crdkit.deriveTargetEnv), ONCE, purely
     to seed the built-in "ENV" token (step 1) — a missing target
     records an ERROR here. This is the only place crdkit.render itself
     needs "env" as such; every token-resolution call below (steps 2, 5)
     takes "target" only and derives env itself, on demand, per call —
     see crdkit's CLAUDE.md for why "env" was dropped as a separate
     param everywhere else (it's always a pure function of "target").
  1. merge system/default/user/builtin token declarations
     (crdkit.mergeTokens) — collision + naming-convention diagnostics
     happen here, but NOTHING is resolved yet. The merged RAW map IS
     ctx.tokens — there is no separate "resolved tokens" structure.
     Resolution is lazy from here on: crdkit.resolveValue resolves (and
     caches, onto the token's own declaration) one name at a time, only
     when something actually needs it. See crdkit's CLAUDE.md for why.
  2. force-resolve every token declaring a targetContainer
     (crdkit.resolveTargetContainerTokens), for THIS render's target —
     the one deliberate exception to laziness: a targetContainer-bearing
     token needs to be valid regardless of whether anything textually
     references it. ctx (with ctx.tokens now populated) is built just
     before this step specifically so it can be passed in.
  3. run the integration chain against a shared "model" accumulator AND
     ctx.tokens (both live, mutable). crdkit does NOT know model's
     shape — see crdkit.ensureDictKey. Integrations should add derived
     tokens via crdkit.addToken rather than hand-rolling ctx.tokens
     mutation.
  4. re-assert locked ("system") AND computed (crdkit.builtinTokens)
     token DECLARATIONS wholesale, unconditionally, after the chain —
     the same "locked always wins" guarantee that applies to
     user-supplied tokens must also hold against integration-code
     mutation, otherwise a chain filter could silently defeat it with
     no diagnostic ever firing. This resets ctx.tokens[name] back to
     the ORIGINAL raw declaration (wiping any "_value" cache that might
     have accumulated under a chain-tampered declaration) rather than
     re-resolving anything — simple, and correct, because resolution is
     lazy: whatever needs the value will resolve it fresh, correctly,
     the next time it's asked for.
  5. NOW do marker substitution — a single textual pass over the
     consumer's raw structure (crdkit.substituteTokens resolves each
     referenced token on demand). This runs AFTER the chain (not
     before) so integration-authored "@token@" references get resolved
     too, not just consumer-authored ones.
  6. merge in the framework's standard labels + whatever the chain
     contributed to model.labels.
  7. prepend accumulated diagnostics as `# ERROR:`/`# WARNING:` comments
     (crdkit.renderDiagnostics — also deduplicates, since steps 2/5 can
     each independently re-diagnose the same broken "target").

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
  system     - raw system-token declarations dict (locked, always wins)
  defaults   - raw default-token declarations dict (consumer may override)
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

{{- $tokensYaml := include "crdkit.mergeTokens" (dict
      "tokens" .tokens "diag" $diag
      "system" $system "defaults" .defaults "builtinTokens" $builtinTokensRaw) -}}
{{- $tokens := $tokensYaml | fromYaml -}}

{{/* no pre-declared shape — see crdkit.ensureDictKey. Every field,
     including "labels" below, is created lazily on first touch by
     whichever integration needs it first. ctx.target exists so any
     helper/integration that needs "the target driving this render" has
     it available — nothing below defaults to it implicitly, though:
     every crdkit.resolveValue/substituteTokens call still names its
     target explicitly (see crdkit's CLAUDE.md on why). */}}
{{- $model := dict -}}
{{- $ctx := dict "root" $root "diag" $diag "model" $model "tokens" $tokens "target" $target -}}

{{- $_ := include "crdkit.resolveTargetContainerTokens" (list $ctx $target) -}}

{{- include "crdkit.integrations.chain" (dict "chain" .chain "ctx" $ctx) -}}

{{/* re-assert locked + computed token DECLARATIONS unconditionally, even
     against chain-code mutation — a wholesale reset to the original raw
     declaration, not a re-resolve, which also wipes any "_value" cache
     that might have accumulated under a tampered declaration. */}}
{{- range $name, $raw := $system -}}
  {{- $_ := set $tokens $name $raw -}}
{{- end -}}
{{- range $name, $raw := $builtinTokensRaw -}}
  {{- $_ := set $tokens $name $raw -}}
{{- end -}}

{{- $structureYaml := omit $root.Values "tokens" | toYaml -}}
{{- $substituted := include "crdkit.substituteTokens" (list $ctx $structureYaml $target) -}}
{{- $substitutedValues := $substituted | fromYaml -}}

{{/* unresolved-marker check: anything still shaped like @word@ in the final
     substituted text after a full pass is either a typo'd reference to a
     token that was never declared, or a genuine cycle already caught by
     crdkit.resolveChainedValue above (that case is reported there, with a
     more specific message naming the token and the cycle — avoid a
     duplicate/less-informative warning here for those). */}}
{{- $unresolvedMarkers := regexFindAll "@[A-Za-z0-9_]+@" $substituted -1 -}}
{{- range $marker := $unresolvedMarkers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if not (hasKey $tokens $name) -}}
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
