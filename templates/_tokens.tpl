{{/*
All token resolution logic — scope (public/internal) is declared per
template below, not uniformly for the file. Product-specific token
content (locked/default keys, values) is never referenced by name —
callers pass "system"/"defaults" dicts explicitly
(crdkit.mergeTokens.internal).

Diagnostics: every helper that can fail takes a "diag" dict
(`{errors, warnings}`, both lists) and appends to it instead of calling
`fail` — a single author mistake must never hard-abort a render.

Resolution is lazy, per-target, and memoized:
- A token resolves (and is diagnosed, if malformed) only when
  something needs it — a "@NAME@" marker referencing it.
- A declared-but-never-used broken token produces no diagnostic.
- Resolving the same token for a target OTHER than the one driving the
  current render is a first-class, cheap operation (not a re-render).

Token declaration shape (what a consumer/integration writes/reads on
`ctx.tokens[NAME]`):
- A bare scalar (same value for every target) — crdkit.mergeTokens.internal
  normalizes it into `{default: <that>}` right after merging, so
  `ctx.tokens[NAME]` is ALWAYS a dict.
- Reserved dict keys: "targetContainer", "_value" (memoization cache),
  "match" (regex rules). "default" is NOT reserved — it's an ordinary
  target entry that crdkit ALSO treats as a hardcoded fallback (see
  crdkit.resolveValue.internal). Every other key IS a target entry.

Resolution RESULT shape (what crdkit.resolveTokenValue /
crdkit.resolveTokenDefinition / .internal RETURN, distinct from a
token's own declaration above): `{value, targetContainer}` — "value"
only exists here, as the interpolated string for one resolution. Never
read `ctx.tokens[NAME].value` — that field doesn't exist on the
declaration; always go through crdkit.resolveTokenValue.

Target model: "target" is an opaque string — could be a sequenced
instance, env, family, or tier; crdkit never inspects its shape.
Escalating to a broader target is delegated to a caller-supplied
"parentTarget" template (see crdkit.resolveValue.internal) — crdkit
only walks it, never defines the taxonomy. crdkit.matchRules is
available for such a template to build pattern-based hops on. No
proactive "target is required" check — an unset target is only
diagnosed if something actually tries to resolve against it.
*/}}

{{/*
Scope: public

Interface:
- Params (dict): { "subject": <string>, "rules": <list of single-key
  {pattern: replacement} dicts, may be nil/empty> }
- Returns YAML: { "matched": <bool>, "value": <string> }
- Evaluates a target-escalation-style regex rule list against a
  subject string; first match wins.

Implementation notes:
- Full-string anchored (`^(?:pattern)$`) — a rule matches the WHOLE
  subject, never a substring.
- "replacement" may reference capture groups via $1/$2/...
- Uses `must*` regex variants deliberately: a malformed pattern aborts
  the render (a Helm template error), not a diagnostic — the one
  scoped exception to "never fail()," since Go templates can't catch
  and downgrade a `must*` error.
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
Scope: public

Interface:
- Params (dict): { "target": <string>, "context": <root $> } — the
  shape every "parentTarget" template receives.
- Returns: nothing.
- Default "parentTarget" template when a caller supplies none — no
  escalation beyond the exact target.
*/}}
{{- define "crdkit.noParentTarget" -}}
{{- end -}}

{{/*
Scope: internal

Interface:
- Params (dict): { "tokens": <raw user tokens, may be nil>, "diag":
  <dict>, "system": <dict>, "defaults": <dict> }
- Returns YAML: merged raw declarations map (not resolved).
- Merges system/default/user token declarations; applies collision +
  naming-convention diagnostics. Output becomes ctx.tokens.

Implementation notes:
- Merge order, later wins: defaults -> user -> system (locked).
  `mergeOverwrite` is used since Sprig's `merge` gives priority to the
  FIRST argument.
- "AT" (crdkit's one reserved built-in token name) is stripped from
  user tokens, same treatment as a system-token collision.
- Normalizes every scalar declaration into `{default: <value>}` — see
  the file-level doc comment.
- Every final token name is checked against `^[A-Z][A-Z0-9_]*$` — a
  WARNING (not ERROR) on mismatch, applied uniformly including
  system/default names.
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

{{/* Normalize scalars into {default: <value>} — safe to mutate $merged
     while ranging over it since this only updates EXISTING keys. */}}
{{- range $name, $raw := $merged -}}
  {{- if not (kindIs "map" $raw) -}}
    {{- $_ := set $merged $name (dict "default" $raw) -}}
  {{- end -}}
{{- end -}}

{{- range $name := keys $merged -}}
  {{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" $name) -}}
    {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token name '%s' should be UPPER_SNAKE_CASE for readability" $name)) -}}
  {{- end -}}
{{- end -}}

{{- $merged | toYaml -}}
{{- end -}}

{{/*
Scope: internal

Interface:
- Params (dict): { "fieldId": <string>, "def": <declaration or scalar>,
  "tokens": <live tokens map, for resolving @ref@ markers inside the
  resolved value>, "target": <string>, "diag": <dict>,
  "parentTargetTemplate": <fully-qualified template name>, "root":
  <caller's root context>, "resolving": <list, internal cycle
  detection> }
- Returns YAML: { "value": <resolved string>, "targetContainer":
  <string> }
- Resolves one declaration ("def"), for one target — the engine behind
  both crdkit.resolveTokenValue (a real, named token) and
  crdkit.resolveTokenDefinition (an arbitrary structure, resolved by
  the same rules without being registered in ctx.tokens). "fieldId" is
  used only to label diagnostics. Memoized onto "def" itself under
  "_value", keyed by target.

Implementation notes:
- Resolution order:
  1. exact-target `_value` cache hit.
  2. dedicated attribute — a literal key (other than "targetContainer"/
     "_value"/"match") equal to the target string exactly.
  3. `match:` — regex rules tried once, against the exact target only
     (never retried at an escalated rung).
  4. walk `parentTargetTemplate` one rung at a time, checking a literal
     key (or cache) at each rung; every rung visited gets cached.
     `match:` must be checked before any cache-tier hit from the walk,
     or a broader cached rung could steal precedence from a
     target-specific `match:` rule.
  5. `default` fallback, checked directly, after the walk is
     exhausted — regardless of taxonomy. Must run after the walk (not
     before), since "def" can have both a `default` entry and a
     taxonomy-reachable one, and the more specific value must win.
- A "def" that's a bare scalar (not a dict) has nowhere to attach a
  `_value` cache, so it's resolved fresh every call — cheap, since
  there's no ladder to walk.
- A declared value may be any scalar type (string/bool/int/float/...) —
  coerced to its string representation before substitution, since
  markers are substituted into text.
- Any `@ref@` marker in a resolved value is ALWAYS looked up in
  "tokens" (the real token registry) — never in "def" itself, even when
  resolving an anonymous structure via crdkit.resolveTokenDefinition.
  Substituted recursively (crdkit.resolveChainedValue.internal), for
  the SAME target — with cycle detection scoped to this one resolution.
- Guards one author mistake: invalid `targetContainer` — ERROR, falls
  back to "none" (the value still resolves). "Unknown token referenced"
  is the caller's concern (see crdkit.resolveTokenValue) — "def" is
  handed over already resolved-to-exist, there's no name left to be
  "unknown" here.
*/}}
{{- define "crdkit.resolveValue.internal" -}}
{{- $fieldId := .fieldId -}}
{{- $raw := .def -}}
{{- $tokens := .tokens -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $parentTargetTemplate := .parentTargetTemplate -}}
{{- $root := .root -}}
{{- $resolving := .resolving | default (list) -}}
{{- $reservedKeys := list "targetContainer" "_value" "match" -}}

{{- $isDict := kindIs "map" $raw -}}
{{- $targetContainer := "none" -}}
{{- if and $isDict (hasKey $raw "targetContainer") -}}
  {{- $targetContainer = $raw.targetContainer -}}
{{- end -}}
{{- $validContainers := list "main" "side-car" "both" "none" -}}
{{- if not (has $targetContainer $validContainers) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "invalid targetContainer '%s' for '%s' — must be one of main/side-car/both (or omitted)" $targetContainer $fieldId)) -}}
  {{- $targetContainer = "none" -}}
{{- end -}}

{{- $cacheable := $isDict -}}
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

  {{- if not $isDict -}}
    {{- $rawValue = $raw -}}
    {{- $found = true -}}
  {{- else -}}
    {{- if and (not (has $target $reservedKeys)) (hasKey $raw $target) -}}
      {{- $rawValue = index $raw $target -}}
      {{- $found = true -}}
    {{- end -}}
    {{- if and (not $found) (hasKey $raw "match") -}}
      {{- $matchResult := include "crdkit.matchRules" (dict "subject" $target "rules" $raw.match) | fromYaml -}}
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
            {{- $_ := set $diag "errors" (append $diag.errors (printf "target escalation chain for '%s' cycles back to '%s' while resolving from '%s'" $fieldId $next $target)) -}}
            {{- $stop = true -}}
            {{- $cycleDetected = true -}}
          {{- else -}}
            {{- $visited = append $visited $next -}}
            {{- $rungsWalked = append $rungsWalked $next -}}
            {{- if and $cacheable (hasKey $cache $next) -}}
              {{- $rawValue = index $cache $next -}}
              {{- $found = true -}}
              {{- $stop = true -}}
            {{- else if and (not (has $next $reservedKeys)) (hasKey $raw $next) -}}
              {{- $rawValue = index $raw $next -}}
              {{- $found = true -}}
              {{- $stop = true -}}
            {{- else -}}
              {{- $current = $next -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
      {{/* skip "no value found" once a cycle is already reported — a more informative message was already recorded above. */}}
      {{- if and (not $found) (not $cycleDetected) (hasKey $raw "default") -}}
        {{- $rawValue = index $raw "default" -}}
        {{- $found = true -}}
      {{- end -}}
      {{- if and (not $found) (not $cycleDetected) -}}
        {{- $_ := set $diag "errors" (append $diag.errors (printf "no value found for '%s' — target chain exhausted at '%s' starting from '%s'" $fieldId $current $target)) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- $resolvedValue := include "crdkit.resolveChainedValue.internal" (dict "text" (toString $rawValue) "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" (append $resolving $fieldId)) -}}
  {{- if $cacheable -}}
    {{- range $rung := $rungsWalked -}}
      {{- $_ := set $cache $rung $resolvedValue -}}
    {{- end -}}
  {{- end -}}
value: {{ $resolvedValue | quote }}
targetContainer: {{ $targetContainer | quote }}
{{- end -}}
{{- end -}}

{{/*
Scope: public

Interface:
- Params (list): [ctx, name, target?]
  - ctx: dict with "tokens"/"diag"/"parentTargetTemplate"/"target" keys
  - name: token name to resolve
  - target: optional — target to resolve for, defaults to ctx.target;
    pass explicitly only to resolve for a target OTHER than the
    render's own
- Returns YAML: { "value": <resolved string>, "targetContainer":
  <string> }
- Resolves a REAL token, registered under "name" in ctx.tokens.

Implementation notes:
- List-based (not dict) — deliberate exception for this frequently-
  called, fixed-shape entry point (see crdkit.dictMerge/listExtend for
  the other).
- "unknown token '%s' referenced" is diagnosed HERE, not in
  crdkit.resolveValue.internal — this is the one caller that does a
  name-based lookup, so it's the one that can tell "unknown" apart from
  "declared but unresolvable."
*/}}
{{- define "crdkit.resolveTokenValue" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 2) (index . 2) -}}
  {{- $target = index . 2 -}}
{{- end -}}
{{- if not (hasKey $ctx.tokens $name) -}}
{{- $_ := set $ctx.diag "errors" (append $ctx.diag.errors (printf "unknown token '%s' referenced" $name)) -}}
value: ""
targetContainer: "none"
{{- else -}}
{{- include "crdkit.resolveValue.internal" (dict "fieldId" $name "def" (index $ctx.tokens $name) "tokens" $ctx.tokens "target" $target "diag" $ctx.diag "parentTargetTemplate" $ctx.parentTargetTemplate "root" $ctx.root) -}}
{{- end -}}
{{- end -}}

{{/*
Scope: public

Interface:
- Params (list): [ctx, fieldId, def, target?]
  - ctx: dict with "tokens"/"diag"/"parentTargetTemplate"/"target" keys
  - fieldId: label used in diagnostics — required, since "def" has no
    name of its own
  - def: a structure sourced from consumer Values, shaped like a token
    declaration (scalar, or dict with default/target-keys/match/
    targetContainer) — NOT registered in ctx.tokens
  - target: optional — defaults to ctx.target
- Returns YAML: { "value": <resolved string>, "targetContainer":
  <string> }
- Resolves an arbitrary structure using the exact same target-
  escalation rules as a real token, without requiring it to be
  registered under a name in ctx.tokens.

Implementation notes:
- Any `@ref@` marker in the resolved value is still looked up in the
  REAL ctx.tokens — "def" is never itself a token namespace.
- "targetContainer" is still extracted/validated as an incidental part
  of the shared algorithm; a caller that doesn't care about it (the
  common case for this entry point) simply ignores it in the return.
*/}}
{{- define "crdkit.resolveTokenDefinition" -}}
{{- $ctx := index . 0 -}}
{{- $fieldId := index . 1 -}}
{{- $def := index . 2 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 3) (index . 3) -}}
  {{- $target = index . 3 -}}
{{- end -}}
{{- include "crdkit.resolveValue.internal" (dict "fieldId" $fieldId "def" $def "tokens" $ctx.tokens "target" $target "diag" $ctx.diag "parentTargetTemplate" $ctx.parentTargetTemplate "root" $ctx.root) -}}
{{- end -}}

{{/*
Scope: internal

Interface:
- Params (dict): { "text": <string>, "tokens": <live tokens map>,
  "target": <string>, "diag": <dict>, "parentTargetTemplate":
  <fully-qualified template name>, "root": <caller's root context>,
  "resolving": <list of names in progress, non-empty> }
- Returns: text with every "@NAME@" reference substituted.
- Recursively substitutes "@ref@" markers within a single value
  string, for the SAME target as the value being substituted into.

Implementation notes:
- Cycle detection: "resolving" is the in-progress name stack for THIS
  top-level resolution/target — referencing a name already on it
  records an ERROR and leaves that one marker unexpanded (rather than
  recursing infinitely), so the rest of the value still resolves.
- "@AT@" is never treated as a token reference here — handled once,
  separately, by crdkit.substituteTokens' final pass.
- A `@ref@` always names a REAL token in "tokens" — this is the one
  place markers get resolved, whether the enclosing value came from a
  named token or from crdkit.resolveTokenDefinition's "def".
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
      {{- $refResolved := include "crdkit.resolveValue.internal" (dict "fieldId" $refName "def" (index $tokens $refName) "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" $resolving) | fromYaml -}}
      {{- $text = $text | replace $marker $refResolved.value -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $text -}}
{{- end -}}

{{/*
Scope: public

Interface:
- Params (list): [ctx, text, target?]
  - target: optional — defaults to ctx.target
- Returns: text with every "@NAME@" marker resolved, and "@AT@"
  replaced with a literal "@".
- Replaces "@NAME@" markers in an arbitrary text block by resolving
  each referenced token on demand — this is what makes a token "used."

Implementation notes:
- A marker naming something that isn't a known token is left
  untouched — the caller is responsible for a "possible typo"
  diagnostic against whatever's left over.
- "@AT@" is replaced last, after every other substitution, so it can't
  be misread as part of another marker mid-resolution.
*/}}
{{- define "crdkit.substituteTokens" -}}
{{- $ctx := index . 0 -}}
{{- $text := index . 1 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 2) (index . 2) -}}
  {{- $target = index . 2 -}}
{{- end -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}
{{- $parentTargetTemplate := $ctx.parentTargetTemplate -}}
{{- $markers := regexFindAll "@[A-Za-z0-9_]+@" $text -1 -}}
{{- range $marker := $markers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $name "AT") (hasKey $tokens $name) -}}
    {{- $resolved := include "crdkit.resolveValue.internal" (dict "fieldId" $name "def" (index $tokens $name) "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $ctx.root) | fromYaml -}}
    {{- $text = $text | replace $marker $resolved.value -}}
  {{- end -}}
{{- end -}}
{{- $text = $text | replace "@AT@" "@" -}}
{{- $text -}}
{{- end -}}

{{/*
Scope: public

Interface:
- Params (list): [ctx, name, value, targetContainer, target?]
  - ctx: dict with "tokens"/"diag"/"target" keys
  - name: token name to add
  - value: raw value text for this exact target (may contain "@ref@"
    markers, resolved lazily)
  - targetContainer: main/side-car/both/none, optional (default "none")
  - target: exact target string "value" applies to — optional, defaults
    to ctx.target
- Returns: nothing (mutates ctx.tokens in place).
- Injects one derived token into a live tokens map — the addToken
  counterpart to crdkit.dictMerge/listExtend for ctx.model.

Implementation notes:
- Stores "value" as a dedicated attribute (literal key = target),
  merged into the token's existing entries — NOT resolved at add-time,
  so a value can reference a token another integration adds later in
  the chain.
- A repeat call for an existing name MERGES: new target → new key;
  same target → overwrite; omitted targetContainer → inherits the
  prior one (not reset to "none"). If the existing declaration isn't a
  dict, it's replaced outright.
- Any existing "_value" cache is always dropped on write.
- Skips the reserved-name collision check
  (crdkit.mergeTokens.internal's) — that protects against untrusted
  consumer input; addToken callers are trusted, first-party code.
*/}}
{{- define "crdkit.addToken" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $value := index . 2 -}}
{{- $rawTargetContainer := index . 3 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 4) (index . 4) -}}
  {{- $target = index . 4 -}}
{{- end -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}
{{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" $name) -}}
  {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token name '%s' should be UPPER_SNAKE_CASE for readability" $name)) -}}
{{- end -}}

{{- $decl := dict -}}
{{- $existingTargetContainer := "" -}}
{{- if hasKey $tokens $name -}}
  {{- $existing := index $tokens $name -}}
  {{- if kindIs "map" $existing -}}
    {{- $decl = omit $existing "_value" "targetContainer" -}}
    {{- if hasKey $existing "targetContainer" -}}
      {{- $existingTargetContainer = $existing.targetContainer -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $targetContainer := $rawTargetContainer | default $existingTargetContainer | default "none" -}}
{{- $validContainers := list "main" "side-car" "both" "none" -}}
{{- if not (has $targetContainer $validContainers) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "invalid targetContainer '%s' for token '%s' — must be one of main/side-car/both (or omitted)" $targetContainer $name)) -}}
  {{- $targetContainer = "none" -}}
{{- end -}}

{{- $_ := set $decl $target $value -}}
{{- $_ := set $decl "targetContainer" $targetContainer -}}
{{- $_ := set $tokens $name $decl -}}
{{- end -}}
