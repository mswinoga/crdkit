{{/*
Generic render engine — the framework's entry point. Every product-
specific bit (system/default tokens, the integration chain, the target
escalation taxonomy) is supplied by the CALLER's own thin wrapper (e.g.
mycrd.render) as an explicit param; crdkit never hardcodes another
chart's template names, so it stays reusable across any number of
specific CRD libraries.

crdkit.render does NOT know, and does not touch, what the rendered CR
looks like — no apiVersion/kind, no labels, no metadata.name, no spec.
It never reads `context.Values` for any of that either. All of it is
100% the caller's own chain's responsibility, via the ordinary
crdkit.dictMerge/listExtend/ensureDictKey mutation primitives against
ctx.model — exactly the same mechanism, with no special case for any
particular field. crdkit.render's own job is deliberately narrow:

  1. merge system/default/user token DECLARATIONS (crdkit.mergeTokens.internal) —
     collision + naming-convention diagnostics happen here, but nothing
     is resolved yet; the merged raw map IS ctx.tokens. Resolution is
     lazy from here on (crdkit.resolveValue resolves and caches one name
     at a time, only when something actually needs it — see crdkit's
     CLAUDE.md for why).
  2. build an empty ctx.model and ctx itself — shape owned entirely by
     the chain (see crdkit.ensureDictKey).
  3. run the integration chain (crdkit.integrations.chain) against the
     shared, mutable ctx.model/ctx.tokens. This is the ONLY step that
     populates ctx.model — a specific library's "preamble" integration
     (first in `chain`, by convention) is where apiVersion/kind/
     metadata.name/metadata.labels/spec — anything the final CR needs —
     get set, typically by pulling whatever the library cares about out
     of ctx.root.Values itself (see my-crd's mycrd.integration.preamble
     for a real example: it reads .Values.spec/.Values.metadata.labels
     directly, since "what does this CR look like" is exactly as much
     specific-library knowledge as "what's its apiVersion").
  4. ONE substitution pass (crdkit.substituteTokens) over the ENTIRE
     model, in place — this is what lets any "@TOKEN@" marker left
     anywhere in ctx.model by the chain (or by consumer values the chain
     folded in) resolve, on demand, the same way. Runs AFTER the chain
     so integration-authored references resolve too, not just ones
     copied verbatim from consumer values.
  5. scan the substituted text for any leftover "@word@" marker that
     doesn't name a known token — recorded as a WARNING (possible typo);
     a genuine cycle is already diagnosed, with a more specific message,
     inside crdkit.resolveValue.internal during resolution itself.
  6. emit the substituted model directly — `{{ model | toYaml }}` — with
     accumulated diagnostics prepended as `# ERROR:`/`# WARNING:`
     comments (crdkit.renderDiagnostics.internal — also deduplicates).

crdkit has NO notion of "env"/"family"/"tier", and no proactive "target
is required" check anywhere in this pipeline — "target" is an opaque
string, escalated (if at all) via the caller-supplied "parentTarget"
template (see crdkit.resolveValue.internal in _tokens.tpl for the full
resolution order this drives). An entirely unset "target" is only ever
diagnosed lazily, if and when something actually tries to resolve a
token against it and the walk finds nothing — same philosophy as every
other "declared but never checked" case in this library. If a specific
library wants an eager "target must be set" guarantee, or an "@ENV@"-
style convenience token, it implements that itself (e.g. in its own
systemTokens, using its own parentTarget template) — crdkit no longer
has an opinion here at all.

Also has no opinion on whether a rendered CR "needs" an apiVersion/kind,
or what its standard labels should be, or how consumer Values maps onto
its body — those used to be enforced/computed here and were deliberately
removed: enforcing them baked in an assumption about what makes a CR
"valid" that's really a specific library's call, not crdkit's, and
computing/merging standard labels here required its own precedence
logic (standard vs. consumer vs. chain-contributed) that's simpler to
just not have — the chain already fully controls ctx.model, so a
library's own preamble decides both WHAT crdkit.standardLabels
contributes and WHEN (i.e. what wins on collision) by choosing where in
its chain it calls it. See crdkit's CLAUDE.md for the fuller reasoning
and the loophole this used to guard against (chain code overriding a
locked token/label) — dropped for the same reason: chain code is
trusted, first-party library code, not the untrusted boundary (that's
consumer-supplied Values, which crdkit.mergeTokens.internal already protects
tokens against, and which a library's own preamble can protect labels
against the same way, if it chooses to).

Expects a dict:
  context              - the consumer's root $ (per spec, always the
                          CONSUMING chart's root — this library is never
                          a normal subchart with values nested under
                          .Values.<name>.*). Passed through to the chain
                          via ctx.root — crdkit.render itself never
                          reads .Values off of it.
  tokens               - .Values.tokens (raw, may include target-keyed dicts)
  target               - .Values.target — an opaque string identifying
                          what's being rendered, at whatever granularity
                          the specific library's own taxonomy calls for
                          (a sequenced instance, a bare env, a family, a
                          tier — crdkit doesn't care).
  system               - raw system-token declarations dict (locked,
                          always wins against consumer-supplied tokens
                          — see crdkit.mergeTokens.internal)
  defaults             - raw default-token declarations dict (consumer
                          may override)
  parentTargetTemplate - fully-qualified template name (e.g.
                          "mycrd.parentTarget") implementing the
                          caller's own target-escalation taxonomy:
                          called with `{target: <a rung>, context: <this
                          same "context" root>}`, returns the next rung
                          up, or nothing if there is none. Optional —
                          defaults to crdkit.noParentTarget (no
                          escalation at all) if omitted. May be shared
                          across several specific libraries via a common
                          enterprise wrapper library; crdkit doesn't
                          care who implements it.
  chain                - ordered list of fully-qualified integration
                          template names (head = outermost filter) —
                          this is the ONLY thing that builds ctx.model;
                          crdkit.render contributes nothing to it itself.
*/}}
{{- define "crdkit.render" -}}
{{- $diag := dict "errors" (list) "warnings" (list) -}}
{{- $root := .context -}}
{{- $system := .system | default dict -}}
{{- $target := .target -}}
{{- $parentTargetTemplate := .parentTargetTemplate | default "crdkit.noParentTarget" -}}

{{- $tokensYaml := include "crdkit.mergeTokens.internal" (dict
      "tokens" .tokens "diag" $diag
      "system" $system "defaults" .defaults) -}}
{{- $tokens := $tokensYaml | fromYaml -}}

{{- $model := dict -}}
{{- $ctx := dict "root" $root "diag" $diag "model" $model "tokens" $tokens "target" $target "parentTargetTemplate" $parentTargetTemplate -}}

{{- include "crdkit.integrations.chain" (dict "chain" .chain "ctx" $ctx) -}}

{{- $substitutedText := include "crdkit.substituteTokens" (list $ctx ($model | toYaml) $target) -}}
{{- $substitutedModel := $substitutedText | fromYaml -}}

{{/* unresolved-marker check: anything still shaped like @word@ in the final
     substituted text after a full pass is either a typo'd reference to a
     token that was never declared, or a genuine cycle already caught, with
     a more specific message, inside crdkit.resolveValue.internal during
     resolution itself (avoid a duplicate/less-informative warning here for
     those). */}}
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
