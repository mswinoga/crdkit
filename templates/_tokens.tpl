{{/*
All generic token/env resolution logic lives in this file. Product-
specific token content (which keys are locked/defaulted, what values
they carry) is NEVER referenced here by name — callers pass their own
"system"/"defaults" dicts in explicitly (see crdkit.mergeTokens), so
this file has zero knowledge of any specific CRD library that depends
on crdkit.

Diagnostics: every helper below that can fail takes a "diag" dict (built
once by the caller as `dict "errors" (list) "warnings" (list)`) and
*appends* to it rather than calling `fail`. crdkit is consumed by many
downstream CRD libraries, each themselves consumed by many app repos, so
a single author mistake anywhere must never hard-abort a render — it
shows up as a `# ERROR:`/`# WARNING:` comment in the rendered output
instead.

RESOLUTION IS LAZY, PER-TARGET, AND MEMOIZED — this is a deliberate
redesign, not the original shape of this library. There is no "resolve
every declared token up front" pass anymore. A token only gets resolved
(and only gets diagnosed for being malformed) when something actually
needs its value — either a "@NAME@" marker referencing it, or it
declaring a targetContainer (see crdkit.resolveTargetContainerTokens).
A DECLARED-BUT-NEVER-USED broken token produces no diagnostic at all.
That's an intentional trade against this library's earlier "diagnose
everything declared, whether used or not" guarantee — made because the
alternative (eager resolution) can't cheaply support resolving the same
token for a target other than the one driving the current render, which
this design exists specifically to enable. See crdkit's CLAUDE.md.

Every RESOLVED token is a struct `{value, targetContainer}`, never a
bare string — see crdkit.resolveValue (the public, list-based entry
point: `[ctx, name, target]`) and crdkit.resolveValue.core (the
internal engine it delegates to). A token's DECLARATION may still be a
bare scalar or the env-varying dict shape (shorthand for `{value:
<that>}`, targetContainer implied "none") — see crdkit.resolveValue.core
for the disambiguation rule.

ctx.tokens IS the merged raw declarations map (crdkit.mergeTokens'
output) — not a separate resolved structure. Resolved values get cached
onto it in place, under a reserved "_value" sub-key per token, as
they're computed (see crdkit.resolveValue.core). This means
`ctx.tokens[NAME]` is NOT guaranteed to be a `{value, targetContainer}`
struct the way it used to be — it's a raw declaration that may or may
not have been resolved yet. Always go through crdkit.resolveValue to
get the guaranteed-resolved shape; never read ctx.tokens[NAME].value
directly.

Every one of these helpers derives "env" from "target" itself
(crdkit.deriveTargetEnv) rather than taking both as separate params —
env is always a pure function of target, so asking a caller for both
was redundant and a source of accidental mismatches. There is no
"current render's target" implicitly available anywhere in this file;
every call names the target it wants resolved, which is what makes
resolving for a target OTHER than the one driving the render (the whole
point of this design) exactly as easy as the common case.
*/}}

{{/*
Regex-based matching, shared by the "match:" tier in
crdkit.resolveValue.core below AND by env derivation from "target" (see
crdkit.deriveTargetEnv in _tokens.builtin.tpl) — one primitive, two
callers, so the target→env parsing isn't bespoke logic living apart
from the general-purpose mechanism a token author gets via "match:".

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
Merges system/default/user tokens, applies collision + naming-convention
warnings. Does NOT resolve anything — see the file-level doc comment on
why resolution is lazy now. This is a pure merge-and-validate step;
its output (raw declarations only) becomes ctx.tokens.

"system" and "defaults" are supplied by the CALLER (a specific CRD
library's own render wrapper, e.g. mycrd.render) as already-rendered
dicts of RAW declarations — crdkit has no template-name knowledge of any
specific library, by design, so it cannot `include` a "systemTokens"/
"defaultTokens" define itself. "builtinTokens" (crdkit.builtinTokens) is
also a dict of raw declarations, same as the others — it doesn't need
special-case handling here despite being crdkit-owned.

Merge order, later wins: defaults -> user tokens -> system -> builtin
(crdkit.builtinTokens — computed facts like "ENV", most authoritative of
all). Sprig's plain `merge` gives PRIORITY TO THE FIRST (destination)
argument on key collisions — i.e. earlier args win, not later ones — so
it cannot express "later wins" directly; `mergeOverwrite` is used
instead, which lets each subsequent source overwrite matching keys
already in the destination.

The built-in "AT" token name, plus every key crdkit.builtinTokens
defines, is reserved and never allowed into the user tokens map, same
treatment as a system-token collision.

Every FINAL token name (user + system + defaults + builtin) is checked
against `^[A-Z][A-Z0-9_]*$` — a non-conforming name records a WARNING
(not an ERROR: it still resolves and renders normally, this is a
readability convention, not a hard requirement — see crdkit's CLAUDE.md
for why it can only ever be a warning given this library's no-fail()
rule). Applies uniformly to system/builtin token names too, not just
user-supplied ones — there's no special exemption for library-authored
tokens; they're expected to already comply.

Expects a dict: { "tokens": <raw tokens map, may be nil>, "diag": <dict>, "system": <dict>, "defaults": <dict>, "builtinTokens": <dict> }
Returns YAML: the merged raw declarations map (NOT resolved).
*/}}
{{- define "crdkit.mergeTokens" -}}
{{- $userTokens := .tokens | default dict -}}
{{- $diag := .diag -}}
{{- $system := .system | default dict -}}
{{- $defaults := .defaults | default dict -}}
{{- $builtinTokens := .builtinTokens | default dict -}}
{{- $builtins := append (keys $builtinTokens) "AT" -}}

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
{{- $merged = mergeOverwrite $merged $builtinTokens -}}

{{- range $name := keys $merged -}}
  {{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" $name) -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token name '%s' should be UPPER_SNAKE_CASE for readability" $name)) -}}
  {{- end -}}
{{- end -}}

{{- $merged | toYaml -}}
{{- end -}}

{{/*
Resolves ONE token, by NAME, out of a LIVE tokens map (ctx.tokens, i.e.
crdkit.mergeTokens' output) for a specific env/target — the full
`{value, targetContainer}` struct, never a bare string. Memoized: the
result is cached back onto the token's own raw declaration under a
reserved "_value" sub-key, so asking for the SAME (name, target) again
is instant, and asking for a DIFFERENT target than the one driving the
current render (e.g. resolving "qap1" while the render itself is for
"qa") is a first-class, cheap operation — this is the whole point of
the redesign, see crdkit's CLAUDE.md.

A declaration may be:
  - a bare scalar or the env-varying dict (env names, family/super-tier
    names, "default", "match") — shorthand for `{value: <that>}`,
    targetContainer implied "none".
  - a wrapper dict `{value: <scalar-or-env-dict>, targetContainer:
    <string>}` — used when a token needs to declare targetContainer.
Disambiguated by `hasKey $raw "value"`: no env-dict special key is ever
named "value", so this is unambiguous and fully backward compatible.

Two author mistakes guarded against explicitly (same as before this
redesign): `targetContainer` declared WITHOUT `value` records a clear
ERROR instead of a confusing "no value for env" one; `value` declared
ALONGSIDE other now-ignored keys (besides "targetContainer"/"_value")
records a WARNING naming them.

CACHING AND MATCH: FRESHNESS, PRECISELY. The one rule that keeps this
safe: "match:" is evaluated FRESH for the specific target being resolved
on EVERY call that isn't an exact-target cache hit — it is NEVER
answered from a broader (env/family/super-tier) cache entry populated
by resolving a DIFFERENT target, because "match:" tests the FULL target
string and can legitimately distinguish "prod-01" from "prod-02" even
though both share env "prod". Only once "match:" has been evaluated
(fresh) for THIS target and ruled out does the env/family/super-
tier/default ladder apply — and THAT part IS purely a function of env,
so it's safe to check/populate a shared cache across every target
sharing an env, family, or super-tier. Concretely, cache lookup/writes
happen in this order:
  1. exact target (`_value.<target>`) — always checked first, always
     safe, covers "match:" results too. A hit here short-circuits
     everything below, including a fresh "match:" check.
  2. (cache miss) evaluate "match:" fresh against the target. If it
     fires, cache ONLY under the exact target (not generalizable to
     other targets) and return.
  3. (match ruled out) walk env -> family tier -> super tier ->
     "default", using a cache hit OR an explicit key in the
     declaration, whichever comes first. Once found, cache the result
     under the exact target AND every tier key walked through en route
     (e.g. resolving "qam1-01" with no "qam1"/"QA" key but an explicit
     "NONPROD" one caches ALL of target, "qam1", "QA", AND "NONPROD" to
     that same value — so a LATER "qap1-01" lookup, same family, gets
     an instant hit at the "QA" cache tier, no re-derivation needed;
     "match:" still gets evaluated fresh for "qap1-01" first, per the
     rule above, in case it has its own target-specific rule).

Chained "@ref@" markers within a resolved value are substituted
recursively (crdkit.resolveChainedValue), for the SAME target being
resolved (a dependency of a "qap1" resolution is itself resolved under
"qap1", not under whatever the "current" render target is) — with
proper cycle detection via an in-progress name stack scoped to this one
top-level resolution (see crdkit.resolveChainedValue; a cycle under one
target says nothing about whether the same token is cyclic under
another, since "match:" can make the dependency graph itself
target-dependent).

A raw declaration that's a BARE SCALAR (not a map at all) has nowhere
to attach a "_value" cache — Go template maps are the only mutable
container this trick works on — so scalar tokens are simply resolved
fresh every call. This is not a meaningful cost (there's no ladder to
walk, only the chained-value substitution, which is cheap), and it
avoids silently rewriting a consumer's plain-string declaration into a
dict behind their back just to give it somewhere to cache.

This is the internal ENGINE — takes an already-derived "env" rather than
deriving it itself, so it can be called recursively (crdkit.resolveChainedValue)
without re-deriving env (and re-diagnosing a missing "target") on every
step of a chain. Consumers and integration authors should call the
public `crdkit.resolveValue` (list-based: `[ctx, name, target]`) below
instead — it derives "env" from "target" once and delegates here.

Expects a dict: { "name": <string>, "tokens": <live tokens map>, "env": <string>, "target": <string>, "diag": <dict>, "fieldName": <string, optional>, "resolving": <list, internal use for cycle detection> }
Returns YAML: { "value": <resolved string>, "targetContainer": <string> }
*/}}
{{- define "crdkit.resolveValue.core" -}}
{{- $tokens := .tokens -}}
{{- $name := .name -}}
{{- $env := .env -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
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
  {{- $matchResult := dict "matched" false "value" "" -}}
  {{- if and (kindIs "map" $valueRaw) (hasKey $valueRaw "match") -}}
    {{- $matchResult = include "crdkit.matchRules" (dict "subject" $target "rules" $valueRaw.match) | fromYaml -}}
  {{- end -}}
  {{- if $matchResult.matched -}}
    {{- $resolvedValue := include "crdkit.resolveChainedValue" (dict "text" $matchResult.value "tokens" $tokens "env" $env "target" $target "diag" $diag "resolving" (append $resolving $name)) -}}
    {{- if $cacheable -}}
      {{- $_ := set $cache $target $resolvedValue -}}
    {{- end -}}
value: {{ $resolvedValue | quote }}
targetContainer: {{ $targetContainer | quote }}
  {{- else -}}
    {{- $tierKeys := list -}}
    {{- $matchedTierIndex := -1 -}}
    {{- $rawValue := "" -}}
    {{- $found := false -}}
    {{- if kindIs "map" $valueRaw -}}
      {{- $envFamily := dict "dev" "DEV" "test" "TEST" "qa" "QA" "qam1" "QA" "qap1" "QA" "prod" "PROD" -}}
      {{- $familyTier := dict "DEV" "NONPROD" "TEST" "NONPROD" "QA" "NONPROD" "PROD" "PROD" -}}
      {{- $penv := index $envFamily $env -}}
      {{- $pnp := "" -}}
      {{- if $penv -}}
        {{- $pnp = index $familyTier $penv -}}
      {{- end -}}
      {{- $tierKeys = append $tierKeys $env -}}
      {{- if $penv -}}
        {{- $tierKeys = append $tierKeys $penv -}}
      {{- end -}}
      {{- if $pnp -}}
        {{- $tierKeys = append $tierKeys $pnp -}}
      {{- end -}}
      {{- $tierKeys = append $tierKeys "default" -}}
      {{- range $i, $tk := $tierKeys -}}
        {{- if not $found -}}
          {{- if and $cacheable (hasKey $cache $tk) -}}
            {{- $rawValue = index $cache $tk -}}
            {{- $found = true -}}
            {{- $matchedTierIndex = $i -}}
          {{- else if hasKey $valueRaw $tk -}}
            {{- $rawValue = index $valueRaw $tk -}}
            {{- $found = true -}}
            {{- $matchedTierIndex = $i -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
      {{- if not $found -}}
        {{- $_ := set $diag "errors" (append $diag.errors (printf "no value for env '%s' and no 'default' defined for '%s'" $env $fieldName)) -}}
      {{- end -}}
    {{- else -}}
      {{- $rawValue = $valueRaw -}}
      {{- $found = true -}}
    {{- end -}}
    {{- $resolvedValue := include "crdkit.resolveChainedValue" (dict "text" $rawValue "tokens" $tokens "env" $env "target" $target "diag" $diag "resolving" (append $resolving $name)) -}}
    {{- if $cacheable -}}
      {{- $_ := set $cache $target $resolvedValue -}}
      {{- range $i, $tk := $tierKeys -}}
        {{- if le $i $matchedTierIndex -}}
          {{- $_ := set $cache $tk $resolvedValue -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
value: {{ $resolvedValue | quote }}
targetContainer: {{ $targetContainer | quote }}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Public entry point for resolving one token by name, for a given target —
the only thing most callers (integration authors, consumers referencing
a token directly rather than through "@NAME@" substitution) need. Derives
"env" from "target" itself (crdkit.deriveTargetEnv) so callers never
supply both — env is ALWAYS a pure function of target, so asking for it
twice was redundant and a source of accidental env/target mismatches.
Pulls "tokens" and "diag" from ctx rather than taking them as separate
params, since both are always ctx.tokens/ctx.diag in practice.

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
  ctx    - dict with (at least) "tokens" and "diag" keys
  name   - token name to resolve
  target - the target to resolve it for (not necessarily the one
           driving the overall render — see above)
Returns YAML: { "value": <resolved string>, "targetContainer": <string> }
*/}}
{{- define "crdkit.resolveValue" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $target := index . 2 -}}
{{- $env := include "crdkit.deriveTargetEnv" (dict "target" $target "diag" $ctx.diag) -}}
{{- include "crdkit.resolveValue.core" (dict "name" $name "tokens" $ctx.tokens "env" $env "target" $target "diag" $ctx.diag) -}}
{{- end -}}

{{/*
Recursively substitutes "@NAME@" references within a single value
string, resolving each referenced token (crdkit.resolveValue.core) for
the SAME target as the value being substituted into — a dependency of a
"qap1" resolution is itself resolved under "qap1", not under whatever
target is driving the overall render (confirmed as the intended
semantics; this is not incidental). Takes an already-derived "env"
(same reasoning as crdkit.resolveValue.core above: this runs inside a
recursion, so re-deriving env — and re-diagnosing a missing "target" —
on every step would be wrong, not just wasteful).

Cycle detection: "resolving" is the list of token names currently
in-progress on THIS top-level resolution's call stack, for THIS target
only — referencing a name already on it is a cycle, recorded as an
ERROR (not a fail()), and that one marker is left unexpanded (rather
than recursing infinitely) so the rest of the value still resolves as
far as possible. A cycle detected while resolving for one target says
nothing about another target, since "match:" can make the dependency
graph itself target-dependent — so this stack is never shared across
separate top-level resolutions, only within the recursion of one.

"@AT@" is deliberately never treated as a token reference here (it's
handled once, separately, by crdkit.substituteTokens' final pass) —
skipped explicitly rather than relying on it simply not being a key in
$tokens, in case a future built-in token is ever literally named "AT"
by mistake.

Expects a dict: { "text": <string>, "tokens": <live tokens map>, "env": <string>, "target": <string>, "diag": <dict>, "resolving": <list of names in progress, non-empty> }
*/}}
{{- define "crdkit.resolveChainedValue" -}}
{{- $text := .text -}}
{{- $tokens := .tokens -}}
{{- $env := .env -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $resolving := .resolving -}}
{{- $markers := regexFindAll "@[A-Za-z0-9_]+@" $text -1 -}}
{{- range $marker := $markers -}}
  {{- $refName := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $refName "AT") (hasKey $tokens $refName) -}}
    {{- if has $refName $resolving -}}
      {{- $_ := set $diag "errors" (append $diag.errors (printf "token '%s' references '@%s@', which is already being resolved — cycle (direct or indirect self-reference)" (last $resolving) $refName)) -}}
    {{- else -}}
      {{- $refResolved := include "crdkit.resolveValue.core" (dict "name" $refName "tokens" $tokens "env" $env "target" $target "diag" $diag "resolving" $resolving) | fromYaml -}}
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
mid-resolution. (There used to be an "applyAt" opt-out for a
theoretical non-final pass; every real call site always wanted it on,
so it was dropped — applying it twice across two passes is harmless
anyway, since the first pass consumes every "@AT@" there is.)

Takes a LIST — `[ctx, text, target]` — same reasoning as
crdkit.resolveValue above (a second, deliberate exception to crdkit's
"always a dict" convention): pulls "tokens"/"diag" from ctx, derives
"env" from "target" itself. Env derivation is done LAZILY, only if
"text" actually contains at least one marker — otherwise a no-op call
(e.g. substituting into an empty/marker-free structure) would still
unconditionally re-diagnose a missing "target", duplicating the ONE
diagnostic crdkit.render's own upfront crdkit.builtinTokens call already
records for that. See crdkit.renderDiagnostics for the other half of
this defense (deduping identical diagnostic lines regardless of cause).

Expects a list: [ctx, text, target]
*/}}
{{- define "crdkit.substituteTokens" -}}
{{- $ctx := index . 0 -}}
{{- $text := index . 1 -}}
{{- $target := index . 2 -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}
{{- $markers := regexFindAll "@[A-Za-z0-9_]+@" $text -1 -}}
{{- if $markers -}}
  {{- $env := include "crdkit.deriveTargetEnv" (dict "target" $target "diag" $diag) -}}
  {{- range $marker := $markers -}}
    {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
    {{- if and (ne $name "AT") (hasKey $tokens $name) -}}
      {{- $resolved := include "crdkit.resolveValue.core" (dict "name" $name "tokens" $tokens "env" $env "target" $target "diag" $diag) | fromYaml -}}
      {{- $text = $text | replace $marker $resolved.value -}}
    {{- end -}}
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

"value" is stored as a "match:" rule keyed by the EXACT "target" string
given — `{value: {match: [{"<target>": "<value>"}, ...]}, ...}` — NOT
resolved at add-time. This is a deliberate choice (on request, after
first trying and rejecting eager resolution — see below): it means an
addToken-inserted token is not special at all, and goes through the
exact same lazy ladder/match/chain resolution as any hand-declared
token, the first time something actually references it, same as ever.

Why "match:" specifically, rather than just storing "value" as a bare
scalar: crdkit.render's chain runs integrations in a fixed order, and
one integration's addToken call may produce a value that references a
token ANOTHER integration adds later in the same chain (e.g. "several
related tokens set one after another" — token A's value refers to
token B, but B is only added by an integration further down the
chain). Resolving eagerly at addToken's own call site — an earlier
version of this helper did exactly that, via crdkit.substituteTokens —
would resolve "value" against whatever ctx.tokens looked like AT THAT
POINT in the chain, which may not yet include B, producing a spurious
"unknown token" error for a reference that would have resolved fine
had it stayed lazy. Storing it as a "match:" rule instead defers
resolution to whenever it's ACTUALLY needed (a "@NAME@" marker,
crossTargets, or a targetContainer trigger), by which point the full
chain (and everything every integration contributed) has already run —
exactly the same "resolve only when needed, against the FINAL state of
ctx.tokens" guarantee every other token already gets.

A SECOND addToken call for a name that already exists (e.g. the same
integration — or a different one — contributing a value for a
DIFFERENT target than a previous call did) MERGES into the existing
"match:" list rather than clobbering it: any prior rule for the exact
same target is replaced (never left as an unreachable, shadowed
duplicate), every rule for a DIFFERENT target is preserved. A repeat
call for the SAME (name, target) pair silently overwrites the earlier
value — same "no protection, by design" precedent as everything else
addToken does (see the reserved-name-collision paragraph below). If the
existing declaration ISN'T itself an addToken-produced match-list shape
(e.g. a consumer's own hand-declared token, or anything else), it's
replaced outright rather than merged into — addToken has no way to
safely merge into an arbitrary existing shape it doesn't recognize.

"targetContainer" is preserved the same way: a repeat call that OMITS
it (the common case — most calls after the first one just want to add
another target's value, not touch targetContainer at all) inherits
whatever the existing declaration already has, rather than resetting it
back to the "none" default. Only an EXPLICIT targetContainer argument
overrides it. This matters because the underlying list positional arg
can't otherwise distinguish "caller didn't pass one" from "caller
wants none" — both look like a missing/falsy list element — so
"missing" is deliberately interpreted as "inherit," not "reset."

The "target" string is used DIRECTLY as a "match:" regex pattern, not
escaped — safe for this library's conventional target strings (env
names, optionally with a "-NN" sequence suffix — alphanumeric and
hyphens only, no regex metacharacters), but not literally guaranteed
safe for an arbitrary string. Not treated as worth solving with regex-
escaping machinery this library doesn't otherwise have a need for;
worth knowing if "target" ever becomes less constrained.

Applies the same invariants every other token gets: name-casing WARNING
(^[A-Z][A-Z0-9_]*$, same rule as crdkit.mergeTokens) and
targetContainer enum validation (ERROR + falls back to "none" if
invalid, same as crdkit.resolveValue.core — pre-validated here so a bad
value is caught at the point it's added, not silently deferred to
whenever something happens to reference it). Deliberately does NOT run
the reserved-name collision check crdkit.mergeTokens does — that's
specifically about protecting against untrusted CONSUMER input at the
initial merge; an integration calling this is trusted library-author
code, not something to defend against the same way.

Mutates ctx.tokens in place (same reference-passing trick as
crdkit.ensureDictKey — see crdkit's CLAUDE.md) — no return value.

Takes a LIST — `[ctx, name, value, targetContainer, target]` — same
convention as crdkit.resolveValue/substituteTokens above.

Expects a list: [ctx, name, value, targetContainer, target]
  ctx             - dict with (at least) "tokens" and "diag" keys
  name            - token name to add
  value           - the token's raw value TEXT for this exact target —
                    may contain "@ref@" markers, resolved lazily (see
                    above), same as any hand-declared token's value
  targetContainer - one of main/side-car/both/none, optional (default "none")
  target          - the EXACT target string "value" applies to (used as
                    a "match:" pattern — see above)
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

{{/* merge into whatever's already there for THIS name, touching only the
     match rule for THIS target — never overwrite the rest of an existing
     declaration (other targets' rules, or an already-set targetContainer
     this call doesn't mention) wholesale. */}}
{{- $existingMatch := list -}}
{{- $existingTargetContainer := "" -}}
{{- if hasKey $tokens $name -}}
  {{- $existing := index $tokens $name -}}
  {{- if and (kindIs "map" $existing) (hasKey $existing "value") (kindIs "map" $existing.value) (hasKey $existing.value "match") -}}
    {{- range $rule := $existing.value.match -}}
      {{- if not (hasKey $rule $target) -}}
        {{- $existingMatch = append $existingMatch $rule -}}
      {{- end -}}
    {{- end -}}
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

{{- $newMatch := prepend $existingMatch (dict $target $value) -}}
{{- $_ := set $tokens $name (dict "value" (dict "match" $newMatch) "targetContainer" $targetContainer) -}}
{{- end -}}

{{/*
Forces resolution (and caching, and diagnosis) of every token declaring
a valid targetContainer (main/side-car/both), for the given target —
the ONE deliberate exception to "only used tokens get resolved" (see
the file-level doc comment). A targetContainer-bearing token needs to
be valid and available for the downstream k8s controller to read
regardless of whether anything ALSO textually references it via
"@NAME@" — this is a separate, explicit, non-lazy trigger, kept apart
from crdkit.substituteTokens' marker-driven laziness on purpose rather
than folded into it, since the two triggers are genuinely different
things (textual usage vs. "this needs to exist for the controller").

Return value is ALWAYS empty by design — the point is entirely the
caching side-effect (crdkit.resolveValue writes its result onto the
token's own "_value" cache), not this call's own output. The internal
include's own return is explicitly captured into `$_` and discarded —
a bare `{{- include ... -}}` with nothing to receive it would otherwise
inject the included template's rendered YAML fragment directly into
whatever this define's caller is building, corrupting it. This bit
real output once already (crdkit.render's own call site, before this
comment existed) — don't drop the `$_ :=` when touching this again.

Takes a LIST — `[ctx, target]` — reuses the public crdkit.resolveValue
per matching token name rather than reimplementing resolution here.

Expects a list: [ctx, target]
*/}}
{{- define "crdkit.resolveTargetContainerTokens" -}}
{{- $ctx := index . 0 -}}
{{- $target := index . 1 -}}
{{- range $name, $raw := $ctx.tokens -}}
  {{- if and (kindIs "map" $raw) (has ($raw.targetContainer | default "none") (list "main" "side-car" "both")) -}}
    {{- $_ := include "crdkit.resolveValue" (list $ctx $name $target) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
