{{/*
All generic token resolution logic lives in this file. Product-specific
token content (which keys are locked/defaulted, what values they carry)
is NEVER referenced here by name — callers pass their own "system"/
"defaults" dicts in explicitly (see crdkit.mergeTokens.internal), so this file
has zero knowledge of any specific CRD library that depends on crdkit.

Diagnostics: every helper below that can fail takes a "diag" dict (built
once by the caller as `dict "errors" (list) "warnings" (list)`) and
*appends* to it rather than calling `fail`. crdkit is consumed by many
downstream CRD libraries, each themselves consumed by many app repos, so
a single author mistake anywhere must never hard-abort a render — it
shows up as a `# ERROR:`/`# WARNING:` comment in the rendered output
instead.

RESOLUTION IS LAZY, PER-TARGET, AND MEMOIZED — this is a deliberate
redesign, not the original shape of this library. There is no "resolve
every declared token up front" pass anymore, and no separate eager-
resolution trigger for anything, including targetContainer-bearing
tokens (an earlier version of this file force-resolved those regardless
of textual reference — removed because nothing in crdkit's own output
ever surfaced a resolved targetContainer anywhere, so eagerly validating
one bought nothing observable; see crdkit's CLAUDE.md). A token only
gets resolved (and only gets diagnosed for being malformed) when
something actually needs its value — a "@NAME@" marker referencing it.
targetContainer itself is still validated whenever that happens to occur
(crdkit.resolveValue.internal does this as part of ordinary resolution), just
never forced ahead of time anymore.
A DECLARED-BUT-NEVER-USED broken token produces no diagnostic at all.
That's an intentional trade against this library's earlier "diagnose
everything declared, whether used or not" guarantee — made because the
alternative (eager resolution) can't cheaply support resolving the same
token for a target other than the one driving the current render, which
this design exists specifically to enable. See crdkit's CLAUDE.md.

Every RESOLVED token is a struct `{value, targetContainer}`, never a
bare string — see crdkit.resolveValue (the public, list-based entry
point: `[ctx, name, target]`) and crdkit.resolveValue.internal (the
internal engine it delegates to). A token's DECLARATION may still be a
bare scalar or a dict keyed by arbitrary "target" strings (shorthand for
`{value: <that>}`, targetContainer implied "none") — see
crdkit.resolveValue.internal for the disambiguation rule.

ctx.tokens IS the merged raw declarations map (crdkit.mergeTokens.internal's
output) — not a separate resolved structure. Resolved values get cached
onto it in place, under a reserved "_value" sub-key per token, as
they're computed (see crdkit.resolveValue.internal). This means
`ctx.tokens[NAME]` is NOT guaranteed to be a `{value, targetContainer}`
struct the way it used to be — it's a raw declaration that may or may
not have been resolved yet. Always go through crdkit.resolveValue to
get the guaranteed-resolved shape; never read ctx.tokens[NAME].value
directly.

CRDKIT HAS NO CONCEPT OF "ENV", "FAMILY", OR "TIER" — it never did more
than pretend to be generic about this, and now it isn't lying about it.
"target" is an OPAQUE STRING as far as crdkit is concerned: it might be
a sequenced instance, a bare environment name, a family, a tier, or
anything else a specific library's own taxonomy calls for. Escalating
from one target to a broader one ("qa-01" to "qa", "qa" to "QA", "QA" to
"NONPROD", whatever a client library wants) is entirely delegated to a
CLIENT-SUPPLIED template — see "parentTarget" in crdkit.resolveValue.internal
below. crdkit only provides the WALKING mechanism (call the template
repeatedly, check a literal key at each rung, cache what it finds,
detect cycles) — never the taxonomy itself. A specific library (or a
shared enterprise wrapper library sitting between crdkit and several
specific libraries) owns that; crdkit.matchRules remains available as a
reusable regex primitive for such a template to build on (e.g. to
implement its own "strip a numeric sequence suffix" first hop), but
crdkit itself no longer has an opinion on what that first hop is, or
whether there even is one.

Consequence: there's no more "env" token, no more proactive "target is
required" check anywhere in this file (an unset target is only ever
diagnosed if something actually tries to resolve a token against it,
walks nowhere, and errors normally — same lazy philosophy as everything
else here, not a special case).
*/}}

{{/*
Regex-based matching — a general-purpose primitive, not tied to any
specific tier concept. Used by the "match:" tier in
crdkit.resolveValue.internal below, and available for a client library's own
"parentTarget" template to build on (e.g. to strip a numeric sequence
suffix as its own first escalation hop) rather than reimplementing
regex handling from scratch.

Evaluates an ordered list of single-key {pattern: replacement} rules
against a subject string; the FIRST pattern that matches wins (full-
string anchored: "^(?:pattern)$", so a rule always classifies the WHOLE
subject, never a substring of it). "replacement" may reference the
pattern's own capture groups via $1/$2/... (Go regexp.ReplaceAll
syntax) — e.g. rule `"(.+)-[0-9]{2}": "$1"` against "prod-01" yields
"prod".

Uses the "must" regex variants DELIBERATELY: a malformed pattern here
is an author bug in the pattern's syntax itself (not merely "did not
match" — regexp.MatchString/ReplaceAll never error on a legitimate
non-match, only on a pattern that fails to compile), and is treated as
severely as any other template type error: it aborts the render
immediately. This is a deliberate, SCOPED exception to this library's
usual "never fail(), always diagnose" rule — Go templates cannot catch
a `must*` function's error and downgrade it to a diagnostic, so there
is no way to have both "malformed regex is diagnosable" and "malformed
regex can never crash a render" at once. Crashing on clearly-broken
regex syntax was chosen over silently swallowing it. See crdkit's
CLAUDE.md.

Expects a dict: { "subject": <string>, "rules": <list of single-key dicts, may be nil/empty> }
Returns YAML: { "matched": <bool>, "value": <string> }. "value" is ""
when unmatched — callers decide whether that deserves a diagnostic.
*/}}
{{- define "crdkit.matchRules" -}}
{{- $subject := .subject -}}
{{- $rules := .rules | default (list) -}}
{{- $result := "" -}}
{{- $found := false -}}
{{- range $rule := $rules -}}
  {{- if not $found -}}
    {{- range $pattern, $repl := $rule -}}
      {{- $anchored := printf "^(?:%s)$" $pattern -}}
      {{- if mustRegexMatch $anchored $subject -}}
        {{- $result = mustRegexReplaceAll $anchored $subject $repl -}}
        {{- $found = true -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
matched: {{ $found }}
value: {{ $result | quote }}
{{- end -}}

{{/*
Default "parentTarget" template used when a specific library doesn't
supply its own (see crdkit.render's "parentTargetTemplate" param) — always
returns nothing, meaning no escalation beyond the exact target is
possible. This is the honest, assumption-free default: crdkit does not
guess at any taxonomy on a client's behalf. A specific library (or a
shared enterprise wrapper) opts into escalation by supplying its own
template name instead.

Expects a dict: { "target": <string, the current rung being escalated FROM>, "context": <caller's root context, e.g. for reading .Values> } — same shape every "parentTarget" template receives.
Returns: the next rung up, or nothing if there is none.
*/}}
{{- define "crdkit.noParentTarget" -}}
{{- end -}}

{{/*
Merges system/default/user tokens, applies collision + naming-convention
warnings. Does NOT resolve anything — see the file-level doc comment on
why resolution is lazy now. This is a pure merge-and-validate step;
its output (raw declarations only) becomes ctx.tokens.

"system" and "defaults" are supplied by the CALLER (a specific CRD
library's own render wrapper, e.g. mycrd.render) as already-rendered
dicts of RAW declarations — crdkit has no template-name knowledge of any
specific library, by design, so it cannot `include` a "systemTokens"/
"defaultTokens" define itself.

Merge order, later wins: defaults -> user tokens -> system (locked,
most authoritative). Sprig's plain `merge` gives PRIORITY TO THE FIRST
(destination) argument on key collisions — i.e. earlier args win, not
later ones — so it cannot express "later wins" directly; `mergeOverwrite`
is used instead, which lets each subsequent source overwrite matching
keys already in the destination.

The built-in "AT" token name (the only one crdkit itself reserves — see
crdkit.substituteTokens) is never allowed into the user tokens map, same
treatment as a system-token collision.

Every FINAL token name (user + system + defaults) is checked against
`^[A-Z][A-Z0-9_]*$` — a non-conforming name records a WARNING (not an
ERROR: it still resolves and renders normally, this is a readability
convention, not a hard requirement — see crdkit's CLAUDE.md for why it
can only ever be a warning given this library's no-fail() rule).
Applies uniformly to system token names too, not just user-supplied
ones — there's no special exemption for library-authored tokens; they're
expected to already comply.

Expects a dict: { "tokens": <raw tokens map, may be nil>, "diag": <dict>, "system": <dict>, "defaults": <dict> }
Returns YAML: the merged raw declarations map (NOT resolved).
*/}}
{{- define "crdkit.mergeTokens.internal" -}}
{{- $userTokens := .tokens | default dict -}}
{{- $diag := .diag -}}
{{- $system := .system | default dict -}}
{{- $defaults := .defaults | default dict -}}
{{- $builtins := list "AT" -}}

{{- range $name, $_ := $userTokens -}}
  {{- if hasKey $system $name -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token '%s' is reserved by the library and was overridden back to the library value" $name)) -}}
  {{- else if has $name $builtins -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token '%s' is a reserved built-in and cannot be redefined; the user-supplied value was ignored" $name)) -}}
  {{- end -}}
{{- end -}}
{{- range $builtins -}}
  {{- $userTokens = omit $userTokens . -}}
{{- end -}}

{{- $merged := mergeOverwrite (dict) $defaults $userTokens -}}
{{- $merged = mergeOverwrite $merged $system -}}

{{- range $name := keys $merged -}}
  {{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" $name) -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token name '%s' should be UPPER_SNAKE_CASE for readability" $name)) -}}
  {{- end -}}
{{- end -}}

{{- $merged | toYaml -}}
{{- end -}}

{{/*
Resolves ONE token, by NAME, out of a LIVE tokens map (ctx.tokens, i.e.
crdkit.mergeTokens.internal's output) for a specific target — the full
`{value, targetContainer}` struct, never a bare string. Memoized: the
result is cached back onto the token's own raw declaration under a
reserved "_value" sub-key, so asking for the SAME (name, target) again
is instant, and asking for a DIFFERENT target than the one driving the
current render (e.g. resolving "qap1" while the render itself is for
"qa") is a first-class, cheap operation — this is the whole point of
the redesign, see crdkit's CLAUDE.md.

A declaration may be:
  - a bare scalar — same in every target, no ladder at all.
  - a dict keyed by arbitrary TARGET STRINGS (a literal "prod-01" key,
    a literal "qa" key, a literal "NONPROD" key — crdkit does not
    distinguish these by shape or name, only by whether the key
    LITERALLY equals the rung being checked — see the walk below), plus
    an optional "match:" list — shorthand for `{value: <that>}`,
    targetContainer implied "none".
  - a wrapper dict `{value: <scalar-or-dict-above>, targetContainer:
    <string>}` — used when a token needs to declare targetContainer.
Disambiguated by `hasKey $raw "value"`: no target-keyed special key is
ever literally named "value", so this is unambiguous.

Two author mistakes guarded against explicitly (same as before this
redesign): `targetContainer` declared WITHOUT `value` records a clear
ERROR instead of a confusing "no value found" one; `value` declared
ALONGSIDE other now-ignored keys (besides "targetContainer"/"_value")
records a WARNING naming them.

RESOLUTION ORDER, for a dict-shaped value:
  1. exact-target cache hit (`_value.<target>`) — always checked first,
     always safe, covers EVERYTHING below (a "dedicated attribute" hit,
     a "match:" hit, or a value found by walking the parent chain — see
     crdkit's CLAUDE.md for why an exact-target cache hit is always
     safe to trust without redoing any of the checks below it).
  2. (cache miss) DEDICATED ATTRIBUTE: a literal key in "value" that
     equals the target string EXACTLY, at whatever granularity that
     happens to be (a full "prod-01" sequenced instance, a bare "qa"
     env, a "QA" family, a "NONPROD" tier — crdkit doesn't care, it's
     just a literal key comparison). Wins over "match:" — most specific
     always beats pattern-based.
  3. (still not found) "match:" — an ordered list of regex rules tested
     against the target string, tried EXACTLY ONCE, right here, for the
     EXACT target being resolved — never re-tried at any rung reached
     by escalating (step 4 below is pure literal-key lookups only, no
     regex). This is deliberately unconditional now — earlier revisions
     of this library only tried "match:" when the target "looked like"
     a sequenced instance; crdkit no longer has any notion of what a
     target is supposed to look like, so there's nothing left to gate
     on. A token author who never needs "match:" simply never declares
     one.
  4. (still not found) WALK THE PARENT CHAIN: repeatedly call the
     caller-supplied "parentTarget" template (a fully-qualified name,
     e.g. "mycrd.parentTarget" — see crdkit.render), passing it `{target:
     <current rung>, context: <the render's root $>}` — the root context
     is threaded through in case the client's own mapping needs to read
     `.Values`/`.Chart`/etc. rather than just returning from a hardcoded
     dict — moving to whatever it returns, checking a literal key (or an
     already-cached value) at each new rung, until the template returns
     nothing (chain exhausted — record an ERROR) or a rung repeats
     (cycle in the client's own map — record a different ERROR; this is
     a template-authoring bug, not a token-authoring one, but it's
     still diagnosed rather than left to hang, per this library's
     philosophy). crdkit ships no default taxonomy: `crdkit.noParentTarget`
     (used when a caller doesn't supply one at all) always returns
     nothing, so step 4 becomes a no-op and steps 2-3 are all a token
     gets. EVERY rung visited during a successful walk gets cached
     (not just the one where the value was finally found), so a LATER
     resolution sharing any of those rungs is an instant hit — e.g.
     walking target "qam1-01" all the way to a value declared under
     "NONPROD" caches "qam1-01", "qam1", "QA", AND "NONPROD" to that
     same result, so a later "qap1-01" lookup (same family) hits the
     "QA" cache entry immediately, without re-walking. This is exactly
     why "match:" must be checked BEFORE this walk even starts, and
     ONLY against the exact original target: "qap1-01" might have its
     OWN "match:" rule that should win over that "QA" cache-tier value
     — if the walk's cache-hit check ran before an exact-target "match:"
     check, a different target's cached result could silently steal
     precedence from a target-specific pattern rule that never got a
     chance to fire. Getting this backwards was caught and fixed once
     already during this library's redesign — see
     tests/tokens_test.yaml's "caching / multi-target semantics" section.

Chained "@ref@" markers within a resolved value are substituted
recursively (crdkit.resolveChainedValue.internal), for the SAME target being
resolved (a dependency of a "qap1" resolution is itself resolved under
"qap1", not under whatever the "current" render target is) — with
proper cycle detection via an in-progress name stack scoped to this one
top-level resolution (see crdkit.resolveChainedValue.internal; a cycle under one
target says nothing about whether the same token is cyclic under
another, since "match:"/the parent chain can make the dependency graph
itself target-dependent).

A raw declaration that's a BARE SCALAR (not a map at all) has nowhere
to attach a "_value" cache — Go template maps are the only mutable
container this trick works on — so scalar tokens are simply resolved
fresh every call. This is not a meaningful cost (there's no ladder to
walk, only the chained-value substitution, which is cheap), and it
avoids silently rewriting a consumer's plain-string declaration into a
dict behind their back just to give it somewhere to cache.

This is the internal ENGINE — consumers and integration authors should
call the public `crdkit.resolveValue` (list-based: `[ctx, name, target]`)
instead, which pulls "tokens"/"diag"/"parentTargetTemplate" from ctx.

Expects a dict: { "name": <string>, "tokens": <live tokens map>, "target": <string>, "diag": <dict>, "parentTargetTemplate": <fully-qualified template name>, "root": <caller's root context, passed through to that template>, "fieldName": <string, optional>, "resolving": <list, internal use for cycle detection> }
Returns YAML: { "value": <resolved string>, "targetContainer": <string> }
*/}}
{{- define "crdkit.resolveValue.internal" -}}
{{- $tokens := .tokens -}}
{{- $name := .name -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $parentTargetTemplate := .parentTargetTemplate -}}
{{- $root := .root -}}
{{- $fieldName := .fieldName | default $name -}}
{{- $resolving := .resolving | default (list) -}}

{{- if not (hasKey $tokens $name) -}}
{{- $_ := set $diag "errors" (append $diag.errors (printf "unknown token '%s' referenced" $name)) -}}
value: ""
targetContainer: "none"
{{- else -}}
{{- $raw := index $tokens $name -}}
{{- $valueRaw := $raw -}}
{{- $targetContainer := "none" -}}
{{- if and (kindIs "map" $raw) (hasKey $raw "value") -}}
  {{- $valueRaw = $raw.value -}}
  {{- if hasKey $raw "targetContainer" -}}
    {{- $targetContainer = $raw.targetContainer -}}
  {{- end -}}
  {{- $extraKeys := list -}}
  {{- range $k, $_ := $raw -}}
    {{- if not (has $k (list "value" "targetContainer" "_value")) -}}
      {{- $extraKeys = append $extraKeys $k -}}
    {{- end -}}
  {{- end -}}
  {{- if $extraKeys -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "'%s' declares 'value' alongside other keys (%s) that are ignored once 'value' is present" $fieldName (join ", " $extraKeys))) -}}
  {{- end -}}
{{- else if and (kindIs "map" $raw) (hasKey $raw "targetContainer") -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "'%s' declares targetContainer without a 'value' key — wrap the actual value as {value: ..., targetContainer: ...}" $fieldName)) -}}
  {{- $valueRaw = "" -}}
  {{- $targetContainer = $raw.targetContainer -}}
{{- end -}}
{{- $validContainers := list "main" "side-car" "both" "none" -}}
{{- if not (has $targetContainer $validContainers) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "invalid targetContainer '%s' for '%s' — must be one of main/side-car/both (or omitted)" $targetContainer $fieldName)) -}}
  {{- $targetContainer = "none" -}}
{{- end -}}

{{- $cacheable := kindIs "map" $raw -}}
{{- $cache := dict -}}
{{- if $cacheable -}}
  {{- if not (hasKey $raw "_value") -}}
    {{- $_ := set $raw "_value" (dict) -}}
  {{- end -}}
  {{- $cache = $raw._value -}}
{{- end -}}

{{- if and $cacheable (hasKey $cache $target) -}}
value: {{ index $cache $target | quote }}
targetContainer: {{ $targetContainer | quote }}
{{- else -}}
  {{- $found := false -}}
  {{- $rawValue := "" -}}
  {{- $rungsWalked := list $target -}}
  {{- $current := $target -}}

  {{- if not (kindIs "map" $valueRaw) -}}
    {{- $rawValue = $valueRaw -}}
    {{- $found = true -}}
  {{- else -}}
    {{- if hasKey $valueRaw $target -}}
      {{- $rawValue = index $valueRaw $target -}}
      {{- $found = true -}}
    {{- end -}}
    {{- if and (not $found) (hasKey $valueRaw "match") -}}
      {{- $matchResult := include "crdkit.matchRules" (dict "subject" $target "rules" $valueRaw.match) | fromYaml -}}
      {{- if $matchResult.matched -}}
        {{- $rawValue = $matchResult.value -}}
        {{- $found = true -}}
      {{- end -}}
    {{- end -}}
    {{- if not $found -}}
      {{- $visited := list $target -}}
      {{- $stop := false -}}
      {{- $cycleDetected := false -}}
      {{- range $i := until 1000 -}}
        {{- if not $stop -}}
          {{- $next := "" -}}
          {{- if $parentTargetTemplate -}}
            {{- $next = include $parentTargetTemplate (dict "target" $current "context" $root) -}}
          {{- end -}}
          {{- if not $next -}}
            {{- $stop = true -}}
          {{- else if has $next $visited -}}
            {{- $_ := set $diag "errors" (append $diag.errors (printf "target escalation chain for '%s' cycles back to '%s' while resolving from '%s'" $fieldName $next $target)) -}}
            {{- $stop = true -}}
            {{- $cycleDetected = true -}}
          {{- else -}}
            {{- $visited = append $visited $next -}}
            {{- $rungsWalked = append $rungsWalked $next -}}
            {{- if and $cacheable (hasKey $cache $next) -}}
              {{- $rawValue = index $cache $next -}}
              {{- $found = true -}}
              {{- $stop = true -}}
            {{- else if hasKey $valueRaw $next -}}
              {{- $rawValue = index $valueRaw $next -}}
              {{- $found = true -}}
              {{- $stop = true -}}
            {{- else -}}
              {{- $current = $next -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
      {{/* skip the generic "no value found" error once a cycle has
           already been reported for this same resolution — the cycle
           message is strictly more informative, same principle as
           crdkit.render's unresolved-marker check avoiding a duplicate,
           less-informative warning on top of an already-reported "@ref@"
           cycle. */}}
      {{- if and (not $found) (not $cycleDetected) -}}
        {{- $_ := set $diag "errors" (append $diag.errors (printf "no value found for '%s' — target chain exhausted at '%s' starting from '%s'" $fieldName $current $target)) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- $resolvedValue := include "crdkit.resolveChainedValue.internal" (dict "text" $rawValue "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" (append $resolving $name)) -}}
  {{- if $cacheable -}}
    {{- range $rung := $rungsWalked -}}
      {{- $_ := set $cache $rung $resolvedValue -}}
    {{- end -}}
  {{- end -}}
value: {{ $resolvedValue | quote }}
targetContainer: {{ $targetContainer | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Public entry point for resolving one token by name, for a given target —
the only thing most callers (integration authors, consumers referencing
a token directly rather than through "@NAME@" substitution) need. Pulls
"tokens"/"diag"/"parentTargetTemplate" from ctx rather than taking them
as separate params, since all three are always ctx.tokens/ctx.diag/
ctx.parentTargetTemplate in practice.

Takes a LIST, not a dict — `[ctx, name, target]`, all three required.
This is a deliberate, second exception to crdkit's usual "always a dict
with named keys" convention (see crdkit.dictMerge/listExtend for the
first one, and crdkit's CLAUDE.md for the reasoning) — for a call this
short and fixed-shape, the positional form reads better at the call
site, and there's no variable-length or optional-key part that would
need named keys to stay self-documenting.

Nothing is implicitly defaulted from ctx — there is no ambient "current
target," only whatever target each individual call names. That's
deliberate: it makes resolving for a target OTHER than the one driving
the current render (the entire point of this library's lazy/memoized
design — see crdkit's CLAUDE.md) exactly as easy to reach for as the
common case, never a special path bolted on the side.

Expects a list: [ctx, name, target]
  ctx    - dict with (at least) "tokens", "diag", and "parentTargetTemplate" keys
  name   - token name to resolve
  target - the target to resolve it for (not necessarily the one
           driving the overall render — see above)
Returns YAML: { "value": <resolved string>, "targetContainer": <string> }
*/}}
{{- define "crdkit.resolveValue" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $target := index . 2 -}}
{{- include "crdkit.resolveValue.internal" (dict "name" $name "tokens" $ctx.tokens "target" $target "diag" $ctx.diag "parentTargetTemplate" $ctx.parentTargetTemplate "root" $ctx.root) -}}
{{- end -}}

{{/*
Recursively substitutes "@NAME@" references within a single value
string, resolving each referenced token (crdkit.resolveValue.internal) for
the SAME target as the value being substituted into — a dependency of a
"qap1" resolution is itself resolved under "qap1", not under whatever
target is driving the overall render (confirmed as the intended
semantics; this is not incidental).

Cycle detection: "resolving" is the list of token names currently
in-progress on THIS top-level resolution's call stack, for THIS target
only — referencing a name already on it is a cycle, recorded as an
ERROR (not a fail()), and that one marker is left unexpanded (rather
than recursing infinitely) so the rest of the value still resolves as
far as possible. A cycle detected while resolving for one target says
nothing about another target, since "match:"/the parent chain can make
the dependency graph itself target-dependent — so this stack is never
shared across separate top-level resolutions, only within the recursion
of one. (This is a DIFFERENT cycle check from the parent-chain one in
crdkit.resolveValue.internal — that one guards against a malformed
"parentTarget" template looping on itself; this one guards against
tokens referencing each other via "@ref@".)

"@AT@" is deliberately never treated as a token reference here (it's
handled once, separately, by crdkit.substituteTokens' final pass) —
skipped explicitly rather than relying on it simply not being a key in
$tokens, in case a future built-in token is ever literally named "AT"
by mistake.

Expects a dict: { "text": <string>, "tokens": <live tokens map>, "target": <string>, "diag": <dict>, "parentTargetTemplate": <fully-qualified template name>, "resolving": <list of names in progress, non-empty> }
*/}}
{{- define "crdkit.resolveChainedValue.internal" -}}
{{- $text := .text -}}
{{- $tokens := .tokens -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $parentTargetTemplate := .parentTargetTemplate -}}
{{- $root := .root -}}
{{- $resolving := .resolving -}}
{{- $markers := regexFindAll "@[A-Za-z0-9_]+@" $text -1 -}}
{{- range $marker := $markers -}}
  {{- $refName := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $refName "AT") (hasKey $tokens $refName) -}}
    {{- if has $refName $resolving -}}
      {{- $_ := set $diag "errors" (append $diag.errors (printf "token '%s' references '@%s@', which is already being resolved — cycle (direct or indirect self-reference)" (last $resolving) $refName)) -}}
    {{- else -}}
      {{- $refResolved := include "crdkit.resolveValue.internal" (dict "name" $refName "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" $resolving) | fromYaml -}}
      {{- $text = $text | replace $marker $refResolved.value -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $text -}}
{{- end -}}

{{/*
Replaces "@NAME@" markers in an arbitrary text block (e.g. the
consumer's whole values structure) by resolving each referenced token
on demand for the given target — this is what makes a token "used" (see
the file-level doc comment): a marker found here is the primary trigger
for lazy resolution. A marker naming something that ISN'T a known token
is left untouched (crdkit.render's caller is responsible for the
"possible typo" diagnostic against whatever's left over — this helper
only resolves what it can). Always also replaces the built-in "@AT@"
marker with a literal '@', as the very last step, after every other
substitution — so "@AT@" can't be misread as part of another marker
mid-resolution.

Takes a LIST — `[ctx, text, target]` — same reasoning as
crdkit.resolveValue above (a second, deliberate exception to crdkit's
"always a dict" convention): pulls "tokens"/"diag"/"parentTargetTemplate"
from ctx.

Expects a list: [ctx, text, target]
*/}}
{{- define "crdkit.substituteTokens" -}}
{{- $ctx := index . 0 -}}
{{- $text := index . 1 -}}
{{- $target := index . 2 -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}
{{- $parentTargetTemplate := $ctx.parentTargetTemplate -}}
{{- $markers := regexFindAll "@[A-Za-z0-9_]+@" $text -1 -}}
{{- range $marker := $markers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $name "AT") (hasKey $tokens $name) -}}
    {{- $resolved := include "crdkit.resolveValue.internal" (dict "name" $name "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $ctx.root) | fromYaml -}}
    {{- $text = $text | replace $marker $resolved.value -}}
  {{- end -}}
{{- end -}}
{{- $text = $text | replace "@AT@" "@" -}}
{{- $text -}}
{{- end -}}

{{/*
Injects one new, derived token into a LIVE tokens map (ctx.tokens) — the
counterpart to crdkit.dictMerge/listExtend for ctx.model, but for
tokens: an integration contributing a derived token (e.g. computed from
something in ctx.model) calls this instead of hand-rolling the raw
declaration itself.

"value" is stored as a DEDICATED ATTRIBUTE — a literal key equal to the
exact "target" string given, merged into (not replacing) whatever
target-keyed entries the token's value-dict already has — NOT resolved
at add-time. This is a deliberate choice (on request, after first
trying and rejecting eager resolution — see below): it means an
addToken-inserted token is not special at all, and goes through the
exact same lazy resolution as any hand-declared token (dedicated
attribute is literally step 2 of crdkit.resolveValue.internal's own
resolution order), the first time something actually references it.

Why lazy rather than resolving "value" right here: crdkit.render's chain
runs integrations in a fixed order, and one integration's addToken call
may produce a value that references a token ANOTHER integration adds
later in the same chain (e.g. "several related tokens set one after
another" — token A's value refers to token B, but B is only added by an
integration further down the chain). Resolving eagerly at addToken's
own call site — an earlier version of this helper did exactly that, via
crdkit.substituteTokens — would resolve "value" against whatever
ctx.tokens looked like AT THAT POINT in the chain, which may not yet
include B, producing a spurious "unknown token" error for a reference
that would have resolved fine had it stayed lazy. Deferring resolution
means it happens against the FINAL state of ctx.tokens, after the whole
chain has run — the same guarantee every other token already gets.

A SECOND addToken call for a name that already exists (e.g. the same
integration — or a different one — contributing a value for a
DIFFERENT target than a previous call did) MERGES into the existing
value-dict: the new target's entry is added/overwritten, every OTHER
target's entry (and "match:", if present) is left untouched, since
setting one key on the existing dict is all that's needed — there's no
list to filter or de-duplicate the way an earlier, match:-list-based
version of this helper needed to. If the existing declaration ISN'T
itself a compatible dict shape (e.g. a bare scalar, or a wrapper whose
"value" isn't a dict), it's replaced outright rather than merged into —
addToken has no way to safely merge into a shape it doesn't recognize.

"targetContainer" is preserved the same way: a repeat call that OMITS
it (the common case — most calls after the first one just want to add
another target's value, not touch targetContainer at all) inherits
whatever the existing declaration already has, rather than resetting it
back to the "none" default. Only an EXPLICIT targetContainer argument
overrides it. This matters because the underlying list positional arg
can't otherwise distinguish "caller didn't pass one" from "caller
wants none" — both look like a missing/falsy list element — so
"missing" is deliberately interpreted as "inherit," not "reset."

Applies the same invariants every other token gets: name-casing WARNING
(^[A-Z][A-Z0-9_]*$, same rule as crdkit.mergeTokens.internal) and
targetContainer enum validation (ERROR + falls back to "none" if
invalid, same as crdkit.resolveValue.internal — pre-validated here so a bad
value is caught at the point it's added, not silently deferred to
whenever something happens to reference it). Deliberately does NOT run
the reserved-name collision check crdkit.mergeTokens.internal does — that's
specifically about protecting against untrusted CONSUMER input at the
initial merge; an integration calling this is trusted library-author
code, a different trust boundary entirely.

Mutates ctx.tokens in place (same reference-passing trick as
crdkit.ensureDictKey — see crdkit's CLAUDE.md) — no return value.

Takes a LIST — `[ctx, name, value, targetContainer, target]` — same
convention as crdkit.resolveValue/substituteTokens above. "target" is
the EXACT target string "value" applies to — it can be at ANY
granularity (a full sequenced instance, a bare env, a family, a tier —
addToken doesn't care, same as crdkit.resolveValue.internal doesn't).

Expects a list: [ctx, name, value, targetContainer, target]
  ctx             - dict with (at least) "tokens" and "diag" keys
  name            - token name to add
  value           - the token's raw value TEXT for this exact target —
                    may contain "@ref@" markers, resolved lazily (see
                    above), same as any hand-declared token's value
  targetContainer - one of main/side-car/both/none, optional (default "none")
  target          - the EXACT target string "value" applies to
*/}}
{{- define "crdkit.addToken" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $value := index . 2 -}}
{{- $rawTargetContainer := index . 3 -}}
{{- $target := index . 4 -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}
{{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" $name) -}}
  {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token name '%s' should be UPPER_SNAKE_CASE for readability" $name)) -}}
{{- end -}}

{{- $valueDict := dict -}}
{{- $existingTargetContainer := "" -}}
{{- if hasKey $tokens $name -}}
  {{- $existing := index $tokens $name -}}
  {{- if and (kindIs "map" $existing) (hasKey $existing "value") (kindIs "map" $existing.value) -}}
    {{- $valueDict = $existing.value -}}
  {{- end -}}
  {{- if and (kindIs "map" $existing) (hasKey $existing "targetContainer") -}}
    {{- $existingTargetContainer = $existing.targetContainer -}}
  {{- end -}}
{{- end -}}

{{- $targetContainer := $rawTargetContainer | default $existingTargetContainer | default "none" -}}
{{- $validContainers := list "main" "side-car" "both" "none" -}}
{{- if not (has $targetContainer $validContainers) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "invalid targetContainer '%s' for token '%s' — must be one of main/side-car/both (or omitted)" $targetContainer $name)) -}}
  {{- $targetContainer = "none" -}}
{{- end -}}

{{- $_ := set $valueDict $target $value -}}
{{- $_ := set $tokens $name (dict "value" $valueDict "targetContainer" $targetContainer) -}}
{{- end -}}

{{/*
REMOVED (was crdkit.resolveTargetContainerTokens): used to force
resolution of every token declaring a valid targetContainer, regardless
of whether anything textually referenced it — on the theory that a
downstream controller needs it valid "just in case." Deleted because
nothing in crdkit's output has ever actually surfaced a resolved
targetContainer for a controller to read (that wiring was never built),
so the eager forcing validated something with no observable effect
either way — speculative complexity for an unbuilt feature. If a real
"expose targetContainer-bearing tokens to a controller" mechanism gets
built later, it'll be the thing that reads those tokens and writes them
into ctx.model — resolution (and diagnosis) happens as a natural side
effect of that write, exactly like any other token reference, with no
separate forcing step needed. targetContainer's enum validation itself
is untouched — still lives in crdkit.resolveValue.internal and still fires
on any resolution, lazy or not.
*/}}
