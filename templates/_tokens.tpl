{{/*
All generic token/env resolution logic lives in this file. Product-
specific token content (which keys are locked/defaulted, what values
they carry) is NEVER referenced here by name — callers pass their own
"system"/"defaults" dicts in explicitly (see crdkit.resolveAllTokens), so
this file has zero knowledge of any specific CRD library that depends on
crdkit.

Diagnostics: every helper below that can fail takes a "diag" dict (built
once by the caller as `dict "errors" (list) "warnings" (list)`) and
*appends* to it rather than calling `fail`. crdkit is consumed by many
downstream CRD libraries, each themselves consumed by many app repos, so
a single author mistake anywhere must never hard-abort a render — it
shows up as a `# ERROR:`/`# WARNING:` comment in the rendered output
instead.

Every RESOLVED token is a struct `{value, targetContainer}`, never a
bare string — see crdkit.resolveToken. A token's DECLARATION may still
be a bare scalar or the env-varying dict shape (shorthand for `{value:
<that>}`, targetContainer implied "none") — see crdkit.resolveToken for
the disambiguation rule.
*/}}

{{/*
Regex-based matching, shared by the "match:" tier in
crdkit.resolveTokenValue below AND by env derivation from "target" (see
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
Resolves a value that is either a scalar (returned as-is) or a dict
(looked up by env/target). Lookup order, first match wins:
  1. "match": an ordered list of {regex: value} rules evaluated against
     "target" (see crdkit.matchRules — full-string anchored, "value"
     may use capture groups from the pattern). Lets a token vary by
     something finer-grained than env (e.g. a specific numbered
     target instance or a family of them) without enumerating every
     target string as its own dict key.
  2. the exact env name (e.g. "qap1")
  3. the env's family tier, uppercased (e.g. "qap1" -> "QA")
  4. the family tier's super-tier ("DEV"/"TEST"/"QA" -> "NONPROD",
     "PROD" -> "PROD")
  5. "default"
If none match, an ERROR is recorded (not a fail()). Note tier 1 can
itself abort the render on a malformed regex — see crdkit.matchRules.

This resolves the "value" HALF of a token only — see crdkit.resolveToken
for the full {value, targetContainer} struct a token actually resolves
to.

Expects a dict: { "value": <raw>, "env": <string>, "target": <string, may be empty>, "diag": <dict>, "fieldName": <string for error messages> }
*/}}
{{- define "crdkit.resolveTokenValue" -}}
{{- $val := .value -}}
{{- $env := .env -}}
{{- $target := .target | default "" -}}
{{- $diag := .diag -}}
{{- $fieldName := .fieldName -}}

{{/* env -> family tier */}}
{{- $envFamily := dict "dev" "DEV" "test" "TEST" "qa" "QA" "qam1" "QA" "qap1" "QA" "prod" "PROD" -}}
{{/* family tier -> super tier */}}
{{- $familyTier := dict "DEV" "NONPROD" "TEST" "NONPROD" "QA" "NONPROD" "PROD" "PROD" -}}

{{- $penv := index $envFamily $env -}}
{{- $pnp := "" -}}
{{- if $penv -}}
  {{- $pnp = index $familyTier $penv -}}
{{- end -}}

{{- if kindIs "map" $val -}}
  {{- $matchResult := dict "matched" false "value" "" -}}
  {{- if hasKey $val "match" -}}
    {{- $matchResult = include "crdkit.matchRules" (dict "subject" $target "rules" $val.match) | fromYaml -}}
  {{- end -}}
  {{- if $matchResult.matched -}}
    {{- $matchResult.value -}}
  {{- else if hasKey $val $env -}}
    {{- index $val $env -}}
  {{- else if and $penv (hasKey $val $penv) -}}
    {{- index $val $penv -}}
  {{- else if and $pnp (hasKey $val $pnp) -}}
    {{- index $val $pnp -}}
  {{- else if hasKey $val "default" -}}
    {{- index $val "default" -}}
  {{- else -}}
    {{- $_ := set $diag "errors" (append $diag.errors (printf "no value for env '%s' and no 'default' defined for '%s'" $env $fieldName)) -}}
  {{- end -}}
{{- else -}}
  {{- $val -}}
{{- end -}}
{{- end -}}

{{/*
Resolves ONE raw token declaration into the full struct every resolved
token has: `{value, targetContainer}` — never a bare string. A
declaration may be:
  - a bare scalar or the env-varying dict (crdkit.resolveTokenValue's
    shape) — shorthand for `{value: <that>}`, targetContainer implied
    "none" (not exposed to any container by the downstream k8s
    controller — see targetContainer below).
  - a wrapper dict `{value: <scalar-or-env-dict>, targetContainer:
    <string>}` — used when a token needs to declare targetContainer.
Disambiguated by `hasKey $raw "value"`: no env-dict special key
(env names, family/super-tiers, "default", "match") is ever named
"value", so this is unambiguous and fully backward compatible — every
token declared before targetContainer existed still resolves exactly
as before, just now wrapped in the struct on the way out.

Two author mistakes this guards against explicitly, both because the
"is this a wrapper or an env-dict" check is a single `hasKey` test with
no room for a third interpretation:
  - `targetContainer` declared WITHOUT `value` (e.g. `{targetContainer:
    "main"}` alone) looks like a bare env-dict to the check above (no
    "value" key), so without a guard it would fall through to
    crdkit.resolveTokenValue, which would try to look up "targetContainer"
    as if it were an env/tier NAME — producing a confusing, unrelated
    "no value for env" error that never mentions the real mistake. This
    is caught explicitly and reported once, clearly, before that
    happens.
  - `value` declared ALONGSIDE other keys (e.g. `{value: "x", prod:
    "y"}`) silently ignores everything but `value` once the wrapper
    shape is detected — "prod" here is never consulted, no env/tier
    resolution happens on it. That's not a bug (the wrapper shape wins
    unconditionally by design) but it's a plausible mistake, so it's
    called out with a WARNING rather than silently discarded.

targetContainer says which container(s) in the rendered CR's managed
workload the downstream k8s controller should materialize this token as
an env var into — crdkit does NOT create env vars itself, it only
carries this field through to the rendered output for the controller to
read (see the still-open TODO in crdkit.render about wiring model/token
output into the real CRD shape). Valid values: "main", "side-car",
"both", or "none" (default when omitted — not exposed as an env var by
the controller at all, i.e. a plain text-substitution-only token). An
invalid value records an ERROR (not a fail()) and falls back to "none"
so downstream consumers never see a garbage value.

Expects a dict: { "raw": <raw declaration>, "env": <string>, "target": <string, may be empty>, "diag": <dict>, "fieldName": <string for error messages> }
Returns YAML: { "value": <resolved string>, "targetContainer": <string> }
*/}}
{{- define "crdkit.resolveToken" -}}
{{- $raw := .raw -}}
{{- $diag := .diag -}}
{{- $fieldName := .fieldName -}}
{{- $valueRaw := $raw -}}
{{- $targetContainer := "none" -}}
{{- if and (kindIs "map" $raw) (hasKey $raw "value") -}}
  {{- $valueRaw = $raw.value -}}
  {{- if hasKey $raw "targetContainer" -}}
    {{- $targetContainer = $raw.targetContainer -}}
  {{- end -}}
  {{- $extraKeys := list -}}
  {{- range $k, $_ := $raw -}}
    {{- if not (has $k (list "value" "targetContainer")) -}}
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
{{- $resolvedValue := include "crdkit.resolveTokenValue" (dict "value" $valueRaw "env" .env "target" .target "diag" $diag "fieldName" $fieldName) -}}
value: {{ $resolvedValue | quote }}
targetContainer: {{ $targetContainer | quote }}
{{- end -}}

{{/*
Merges system/default/user tokens, applies collision + naming-convention
warnings, and delegates to recursive (@token@-reference) resolution.

"system" and "defaults" are supplied by the CALLER (a specific CRD
library's own render wrapper, e.g. mycrd.render) as already-rendered
dicts of RAW declarations — crdkit has no template-name knowledge of any
specific library, by design, so it cannot `include` a "systemTokens"/
"defaultTokens" define itself. "builtinTokens" (crdkit.builtinTokens) is
also a dict of raw declarations, same as the others — it doesn't need
special-case handling here despite being crdkit-owned.

Merge order, later wins: defaults -> user tokens -> system -> builtin
(crdkit.builtinTokens — computed facts like "ENV", most authoritative
of all). Sprig's plain `merge` gives PRIORITY TO THE FIRST (destination)
argument on key collisions — i.e. earlier args win, not later ones — so
it cannot express "later wins" directly; `mergeOverwrite` is used
instead, which lets each subsequent source overwrite matching keys
already in the destination.

"builtinTokens" is folded in HERE, before crdkit.resolveTokensRecursive
runs — not bolted on afterward — specifically so a regular token can
safely chain off "@ENV@" (or any other built-in token) through the SAME
iterative @ref@ resolution everything else goes through, deterministically.
An earlier version injected "env" only after recursion finished, which
made cross-references to it depend on Go's randomized map iteration
order in the final substitution pass — don't reintroduce that.

The built-in "AT" token name, plus every key crdkit.builtinTokens
defines, is reserved and never allowed into the user tokens map, same
treatment as a system-token collision.

Every FINAL token name (user + system + defaults + builtin, i.e. every
key about to be resolved) is checked against `^[A-Z][A-Z0-9_]*$` — a
non-conforming name records a WARNING (not an ERROR: it still resolves
and renders normally, this is a readability convention, not a hard
requirement — see crdkit's CLAUDE.md for why it can only ever be a
warning given this library's no-fail() rule). Applies uniformly to
system/builtin token names too, not just user-supplied ones — there's
no special exemption for library-authored tokens; they're expected to
already comply.

Expects a dict: { "tokens": <raw tokens map, may be nil>, "env": <string>, "target": <string, may be empty>, "diag": <dict>, "system": <dict>, "defaults": <dict>, "builtinTokens": <dict> }
*/}}
{{- define "crdkit.resolveAllTokens" -}}
{{- $userTokens := .tokens | default dict -}}
{{- $env := .env -}}
{{- $target := .target -}}
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

{{- include "crdkit.resolveTokensRecursive" (dict "tokens" $merged "env" $env "target" $target "diag" $diag) -}}
{{- end -}}

{{/*
Resolves each token (crdkit.resolveToken) first, then iteratively
substitutes @token@ references WITHIN the tokens map's VALUES until a
fixed point — bounded by len(tokens)+1 passes, which is sufficient for
any acyclic dependency graph of that size regardless of fan-in/fan-out,
since only the longest reference chain matters. targetContainer is
inert metadata, carried through unchanged — only "value" ever
participates in @ref@ substitution.

Any token still containing an unresolved @name@ reference to a KNOWN
token name after the full iteration budget indicates a cycle -> recorded
as an ERROR, not a fail(). Returns a YAML-serialized dict:
name -> {value, targetContainer}. Does NOT apply the built-in "@AT@" ->
"@" substitution — that happens exactly once, at the very end of
crdkit.render (via crdkit.substituteTokens's applyAt flag), so "@AT@"
can't be misread as part of another marker mid-resolution.

Expects a dict: { "tokens": <raw tokens map>, "env": <string>, "target": <string, may be empty>, "diag": <dict> }
*/}}
{{- define "crdkit.resolveTokensRecursive" -}}
{{- $tokensRaw := .tokens -}}
{{- $env := .env -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $maxIter := add (len $tokensRaw) 1 -}}

{{- $current := dict -}}
{{- range $name, $raw := $tokensRaw -}}
  {{- $resolved := include "crdkit.resolveToken" (dict "raw" $raw "env" $env "target" $target "diag" $diag "fieldName" (printf "tokens.%s" $name)) | fromYaml -}}
  {{- $current = set $current $name $resolved -}}
{{- end -}}

{{- range $i := until (int $maxIter) -}}
  {{- $next := dict -}}
  {{- range $name, $tok := $current -}}
    {{- $substitutedValue := include "crdkit.substituteTokens" (dict "text" $tok.value "tokens" $current "applyAt" false) -}}
    {{- $next = set $next $name (dict "value" $substitutedValue "targetContainer" $tok.targetContainer) -}}
  {{- end -}}
  {{- $current = $next -}}
{{- end -}}

{{- range $name, $tok := $current -}}
  {{- range $refName, $_ := $tokensRaw -}}
    {{- if contains (printf "@%s@" $refName) $tok.value -}}
      {{- $_ := set $diag "errors" (append $diag.errors (printf "token '%s' still references '@%s@' after %d resolution passes — likely a cycle (direct or indirect self-reference)" $name $refName $maxIter)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $current | toYaml -}}
{{- end -}}

{{/*
Replaces @tokenName@ markers in a text block with resolved values from a
struct-shaped tokens dict (name -> {value, targetContainer} — see
crdkit.resolveToken). Only "value" is ever substituted in;
targetContainer never appears in rendered text. If applyAt is true, also
replaces the built-in @AT@ marker with a literal '@' — do this only on
the FINAL pass (see crdkit.resolveTokensRecursive doc above, and
crdkit.render).

Expects a dict: { "text": <string>, "tokens": <struct-shaped dict>, "applyAt": <bool> }
*/}}
{{- define "crdkit.substituteTokens" -}}
{{- $text := .text -}}
{{- $tokens := .tokens -}}
{{- range $name, $tok := $tokens -}}
  {{- $marker := printf "@%s@" $name -}}
  {{- $text = $text | replace $marker $tok.value -}}
{{- end -}}
{{- if .applyAt -}}
  {{- $text = $text | replace "@AT@" "@" -}}
{{- end -}}
{{- $text -}}
{{- end -}}

{{/*
Mutates a LIVE resolved-tokens dict (ctx.tokens) by adding one new
already-resolved entry — the counterpart to crdkit.dictMerge/listExtend
for ctx.model, but for tokens: an integration that wants to contribute a
derived token (e.g. computed from something in ctx.model) calls this
instead of hand-rolling `set $ctx.tokens NAME (dict "value" ...
"targetContainer" ...)` itself.

Applies the same invariants every other token gets: name-casing WARNING
(^[A-Z][A-Z0-9_]*$, same rule as crdkit.resolveAllTokens) and
targetContainer enum validation (ERROR + falls back to "none" if
invalid, same as crdkit.resolveToken). Deliberately does NOT run the
reserved-name collision check crdkit.resolveAllTokens does — that's
specifically about protecting against untrusted CONSUMER input at the
initial merge; an integration calling this is trusted library-author
code, not something to defend against the same way.

Mutates $tokens in place (same reference-passing trick as
crdkit.ensureDictKey — see crdkit's CLAUDE.md) — no return value.

Expects a dict: { "tokens": <live tokens dict>, "name": <string>, "value": <string>, "targetContainer": <string, optional, default "none">, "diag": <dict> }
*/}}
{{- define "crdkit.addToken" -}}
{{- $tokens := .tokens -}}
{{- $name := .name -}}
{{- $diag := .diag -}}
{{- $targetContainer := .targetContainer | default "none" -}}
{{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" $name) -}}
  {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token name '%s' should be UPPER_SNAKE_CASE for readability" $name)) -}}
{{- end -}}
{{- $validContainers := list "main" "side-car" "both" "none" -}}
{{- if not (has $targetContainer $validContainers) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "invalid targetContainer '%s' for token '%s' — must be one of main/side-car/both (or omitted)" $targetContainer $name)) -}}
  {{- $targetContainer = "none" -}}
{{- end -}}
{{- $_ := set $tokens $name (dict "value" .value "targetContainer" $targetContainer) -}}
{{- end -}}
