{{/*
All token resolution logic — scope (public/internal) is declared per
template below, not uniformly for the file. Product-specific token
content (locked/default keys, values) is never referenced by name —
callers pass "system"/"defaults" dicts explicitly
(crdkit.tokens.merge.internal).

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
- A bare scalar (same value for every target) — crdkit.tokens.merge.internal
  normalizes it into `{default: <that>}` right after merging, so
  `ctx.tokens[NAME]` is ALWAYS a dict.
- Reserved dict keys (never target entries): the crdkit-internal keys
  "_value" (memoization cache), "_gen" (generation the cache belongs to)
  and "_generated" (values registered by crdkit.token.underlay), "match"
  (regex rules), and every ANNOTATION name the calling library passes to
  crdkit.render (crdkit.reservedKeys.internal). "default" is NOT
  reserved — it's an ordinary target entry that crdkit ALSO treats as a
  hardcoded fallback (see crdkit.resolveEntry.internal). Every other key
  IS a target entry.
- Annotations are static metadata on a declaration (e.g. an owner or an
  exposure marker). crdkit never interprets their names or values and
  never resolves them; a library reads them directly off
  `ctx.tokens[NAME]`.
- Internal keys written into a declaration by a consumer, defaults or
  system are stripped at merge time with a WARNING
  (crdkit.tokens.merge.internal).

Cache generations: `ctx.gen` is a counter bumped by every
crdkit.token.add / crdkit.token.underlay. A declaration's "_gen" records
the generation its "_value" cache was written under; on a mismatch the
cache is discarded wholesale before use (crdkit.resolveEntry.internal).
The current generation travels as the "gen" param through every
internal resolution template, like "reservedKeys".

A resolved VALUE can itself be structural, not just a scalar: once the
target-escalation ladder selects an entry, every STRING LEAF within it
is recursively substituted for "@ref@" markers
(crdkit.substituteStructure.internal) — a dict/list value comes back
with the same shape, markers replaced throughout. Non-string scalars
(bool/int/float) pass through unchanged.

Resolution RESULT shape: every public entry point below returns YAML
`{value: <resolved thing>}` — a single-key wrapper that exists ONLY
because Helm's `fromYaml`/`fromJson` cannot decode a bare top-level
scalar or list (verified empirically: it silently returns an error
dict instead of erroring loudly). Never read `ctx.tokens[NAME].value`
directly — that key doesn't exist on the declaration; always go
through crdkit.token.value.

Target model: "target" is an opaque string — could be a sequenced
instance, env, family, or tier; crdkit never inspects its shape.
Escalating to a broader target is delegated to a caller-supplied
"parentTarget" template (see crdkit.resolveEntry.internal) — crdkit
only walks it, never defines the taxonomy. crdkit.matchRules is
available for such a template to build pattern-based hops on. No
proactive "target is required" check — an unset target is only
diagnosed if something actually tries to resolve against it.

Dependency graph (who calls whom):

  crdkit.render (public) -> crdkit.reservedKeys.internal -> ctx.reservedKeys
                         -> crdkit.tokens.merge.internal -> ctx.tokens

  crdkit.tokens.substitute (public)
    -> crdkit.tokens.substituteMarkers.internal      (also called by crdkit.render)
         -> crdkit.token.value (public)
              -> crdkit.resolveEntry.internal
                   -> crdkit.matchRules
                   -> <parentTargetTemplate>       (caller-supplied hook)
                   -> crdkit.substituteStructure.internal
                        -> crdkit.substituteText.internal
                             -> crdkit.resolveEntry.internal   (cycle, per "@ref@" —
                                                                 bounded by "resolving")
                        -> (self, recursing into nested map/list values)
         -> crdkit.stringify.internal                (coerce for splicing into text)

  Every marker match uses crdkit.markerPattern.internal.

  crdkit.token.string / crdkit.tokenDef.string (public)
    -> crdkit.token.value / crdkit.tokenDef.value (public)
         -> crdkit.resolveEntry.internal (as above)
    -> crdkit.stringify.internal

  crdkit.token.add / crdkit.token.underlay (public) -- store raw
    declarations only, no engine dependency; bump ctx.gen

Three public "shapes": crdkit.token.* resolves a REAL, named token;
crdkit.tokenDef.* resolves an arbitrary structure (e.g. sourced from
consumer Values) using the same rules WITHOUT registering it in
ctx.tokens; crdkit.tokens.* operates on the whole registry (building it,
or substituting across an entire text blob). crdkit.resolveEntry.internal
is shared engine code used directly by BOTH crdkit.token.value and
crdkit.tokenDef.value — it deliberately isn't namespaced under either.
*/}}

{{/*
crdkit.markerPattern.internal (internal)

The one definition of a "@NAME@" marker; every marker match in crdkit
(substitution, unresolved-marker scan, schema checks, JSON Schema
`markers` pattern) uses it.

Interface:
- Params: none (pass an empty dict).
- Returns: the regex as plain text — `@[A-Za-z0-9_.]+@`.

Implementation notes:
- "." is part of a name, so a dotted name (`@A.b@`) and a library's
  relative form (`@.x@`) are markers too. Side effect: text like
  `@example.com@` is a marker — escape it with "@AT@".
*/}}
{{- define "crdkit.markerPattern.internal" -}}
@[A-Za-z0-9_.]+@
{{- end -}}

{{/*
crdkit.matchRules (public)

Evaluates a target-escalation-style regex rule list against a subject
string; first match wins.

Interface:
- Params (dict): { "subject": <string>, "rules": <list of single-key
  {pattern: replacement} dicts, may be nil/empty> }
- Returns YAML: { "matched": <bool>, "value": <string> }

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
crdkit.noParentTarget (public)

Default "parentTarget" template when a caller supplies none — no
escalation beyond the exact target.

Interface:
- Params (dict): { "target": <string>, "context": <root $> } — the
  shape every "parentTarget" template receives.
- Returns: nothing.
*/}}
{{- define "crdkit.noParentTarget" -}}
{{- end -}}

{{/*
crdkit.reservedKeys.internal (internal)

Computes the complete list of reserved (non-entry) keys: built-in crdkit
keys (_value, _gen, _generated, match) plus every annotation name that
does NOT collide; colliding annotation names are dropped with an ERROR.

Interface:
- Params (dict): { "annotations": <list of strings>, "diag": <dict> }
- Returns YAML: { "value": <list of reserved key names> }

Implementation notes:
- An annotation named like a built-in key OR "default" collides:
  "default" stays a target entry, so it can't also be an annotation.
- The list is computed once per render (crdkit.render) and handed to
  every resolution helper through ctx.reservedKeys.
*/}}
{{- define "crdkit.reservedKeys.internal" -}}
{{- $annotations := .annotations | default (list) -}}
{{- $diag := .diag -}}
{{- $collisionCheck := list "_value" "_gen" "_generated" "match" "default" -}}
{{- $result := list "_value" "_gen" "_generated" "match" -}}
{{- range $annot := $annotations -}}
  {{- if has $annot $collisionCheck -}}
    {{- $_ := set $diag "errors" (append $diag.errors (printf "annotation name '%s' collides with a crdkit-reserved key and was ignored" $annot)) -}}
  {{- else -}}
    {{- $result = append $result $annot -}}
  {{- end -}}
{{- end -}}
value: {{ $result | toYaml | nindent 2 }}
{{- end -}}

{{/*
crdkit.tokens.merge.internal (internal)

Merges system/default/user token declarations; applies collision,
internal-key and naming-convention diagnostics. Output becomes
ctx.tokens.

Interface:
- Params (dict): { "tokens": <raw user tokens, may be nil>, "diag":
  <dict>, "system": <dict>, "defaults": <dict> }
- Returns YAML: merged raw declarations map (not resolved).

Implementation notes:
- Merge order: defaults deep-merge with user (user keys win), then
  system keys are set wholesale (each system token REPLACES any consumer
  declaration with the same name, including all its keys).
- "AT" (crdkit's one reserved built-in token name) is stripped from
  user tokens, same treatment as a system-token collision.
- Normalizes every scalar declaration into `{default: <value>}` — see
  the file-level doc comment.
- Internal keys (`_value`, `_gen`, `_generated`) in any declaration are
  removed from a copy, each with a WARNING naming the token and key —
  only crdkit itself writes them.
- Token names are not checked: a naming policy belongs to the library
  (e.g. its values schema).
*/}}
{{- define "crdkit.tokens.merge.internal" -}}
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
{{- range $name, $decl := $system -}}
  {{- $_ := set $merged $name $decl -}}
{{- end -}}

{{/* Normalize scalars into {default: <value>} — safe to mutate $merged
     while ranging over it since this only updates EXISTING keys. */}}
{{- range $name, $raw := $merged -}}
  {{- if not (kindIs "map" $raw) -}}
    {{- $_ := set $merged $name (dict "default" $raw) -}}
  {{- end -}}
{{- end -}}

{{/* internal keys are crdkit-managed; strip on a copy so the caller's input maps are never mutated. */}}
{{- range $name := keys $merged -}}
  {{- $decl := index $merged $name -}}
  {{- range $key := (list "_value" "_gen" "_generated") -}}
    {{- if hasKey $decl $key -}}
      {{- $_ := set $diag "warnings" (append $diag.warnings (printf "token '%s' declares crdkit-internal key '%s'; it was removed" $name $key)) -}}
      {{- $decl = omit $decl $key -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $merged $name $decl -}}
{{- end -}}

{{- $merged | toYaml -}}
{{- end -}}

{{/*
crdkit.resolveEntry.internal (internal)

Runs the target-escalation ladder against "def", selects one entry, then
recursively substitutes "@ref@" markers throughout it
(crdkit.substituteStructure.internal). The engine behind both
crdkit.token.value (a real, named token) and crdkit.tokenDef.value (an
arbitrary structure, resolved by the same rules without being registered
in ctx.tokens). "fieldId" labels diagnostics only. Memoized onto "def"
itself under "_value", keyed by target, valid for one generation
("_gen").

Interface:
- Params (dict): { "fieldId": <string>, "def": <declaration or scalar>,
  "tokens": <live tokens map, for resolving @ref@ markers inside the
  resolved value>, "target": <string>, "diag": <dict>,
  "parentTargetTemplate": <fully-qualified template name>, "root":
  <caller's root context>, "resolving": <list, internal cycle
  detection>, "reservedKeys": <list of non-entry key names, optional —
  defaults to the built-in crdkit keys>, "gen": <current cache
  generation, optional — defaults to 0> }
- Returns YAML: { "value": <resolved string, or a dict/list with every
  string leaf's markers resolved> }

Implementation notes:
- Resolution order:
  1. exact-target `_value` cache hit — valid only when the declaration's
     `_gen` equals "gen" (compared via `toString`, robust to int/int64/
     float64 after a YAML round-trip); on a mismatch `_value` is reset
     to an empty dict and `_gen` set to "gen" first.
  2. dedicated attribute — a literal key (other than a reserved key)
     equal to the target string exactly.
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
  6. `_generated[<exact target>]` — values registered by
     crdkit.token.underlay; lowest priority, so a consumer always wins,
     even with its own `default`. Applies to the exact target only (never
     to a rung) and is cached ONLY under `_value[<target>]`: rungs are
     shared across targets, `_generated` is per target.
  7. none of the above: the "no value found" ERROR.
- A "def" that's a bare scalar (not a dict) has nowhere to attach a
  `_value` cache, so it's resolved fresh every call — cheap, since
  there's no ladder to walk.
- Annotations are never inspected here beyond being excluded from the
  target entries via "reservedKeys".
- Guards one author mistake: no value found for the target — ERROR.
  "Unknown token referenced" is the caller's concern (see
  crdkit.token.value) — "def" is handed over already resolved-to-exist.
*/}}
{{- define "crdkit.resolveEntry.internal" -}}
{{- $fieldId := .fieldId -}}
{{- $raw := .def -}}
{{- $tokens := .tokens -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $parentTargetTemplate := .parentTargetTemplate -}}
{{- $root := .root -}}
{{- $resolving := .resolving | default (list) -}}
{{- $reservedKeys := .reservedKeys | default (list "_value" "_gen" "_generated" "match") -}}
{{- $gen := .gen | default 0 -}}

{{- $isDict := kindIs "map" $raw -}}

{{- $cacheable := $isDict -}}
{{- $cache := dict -}}
{{- if $cacheable -}}
  {{- if not (hasKey $raw "_value") -}}
    {{- $_ := set $raw "_value" (dict) -}}
  {{- end -}}
  {{/* a cache written under another generation may be stale (a token was added/underlaid since) — drop it wholesale. */}}
  {{- if ne (toString (index $raw "_gen" | default 0)) (toString $gen) -}}
    {{- $_ := set $raw "_value" (dict) -}}
  {{- end -}}
  {{- $_ := set $raw "_gen" $gen -}}
  {{- $cache = $raw._value -}}
{{- end -}}

{{- $cacheValid := and $cacheable (hasKey $cache $target) -}}

{{- if $cacheValid -}}
value: {{ index $cache $target | toYaml | nindent 2 }}
{{- else -}}
  {{- $found := false -}}
  {{- $rawValue := "" -}}
  {{- $rungsWalked := list $target -}}
  {{- $current := $target -}}
  {{- $fromGenerated := false -}}

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
      {{/* lowest priority: a generated value exists for the EXACT target only (never for a rung). */}}
      {{- if and (not $found) (not $cycleDetected) (hasKey $raw "_generated") -}}
        {{- $generated := index $raw "_generated" -}}
        {{- if and (kindIs "map" $generated) (hasKey $generated $target) -}}
          {{- $rawValue = index $generated $target -}}
          {{- $found = true -}}
          {{- $fromGenerated = true -}}
        {{- end -}}
      {{- end -}}
      {{- if and (not $found) (not $cycleDetected) -}}
        {{- $_ := set $diag "errors" (append $diag.errors (printf "no value found for '%s' — target chain exhausted at '%s' starting from '%s'" $fieldId $current $target)) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- $substituted := include "crdkit.substituteStructure.internal" (dict "value" $rawValue "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" (append $resolving $fieldId) "reservedKeys" $reservedKeys "gen" $gen) | fromYaml -}}
  {{- $resolvedValue := $substituted.value -}}
  {{- if $cacheable -}}
    {{/* rungs are shared across targets but _generated is per target: a generated value must not leak into rung caches. */}}
    {{- if $fromGenerated -}}
      {{- $_ := set $cache $target $resolvedValue -}}
    {{- else -}}
      {{- range $rung := $rungsWalked -}}
        {{- $_ := set $cache $rung $resolvedValue -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
value: {{ $resolvedValue | toYaml | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
crdkit.substituteStructure.internal (internal)

Recursively walks "value": a string is substituted via
crdkit.substituteText.internal; a map/list is walked entry-by-entry
(same recursion, one level down); any other scalar passes through
unchanged.

Interface:
- Params (dict): { "value": <any>, "tokens": <live tokens map>,
  "target": <string>, "diag": <dict>, "parentTargetTemplate":
  <fully-qualified template name>, "root": <caller's root context>,
  "resolving": <list of names in progress>, "reservedKeys": <list>,
  "gen": <int> }
- Returns YAML: { "value": <"value", with every string leaf's "@ref@"
  markers substituted> }

Implementation notes:
- This is what lets a token's (or crdkit.tokenDef.value's "def") value
  be an arbitrary structure, not just a scalar — reserved keys
  (internal keys, "match", annotations) only mean anything at the OUTER
  declaration level inspected by crdkit.resolveEntry.internal; once a
  value is selected and handed here, every key is ordinary data.
- No cycle risk from the structural recursion itself — it's finite
  literal YAML/JSON, not a graph with back-edges. Cycle detection
  ("resolving") only matters for named "@ref@" cross-references, which
  crdkit.substituteText.internal already guards.
*/}}
{{- define "crdkit.substituteStructure.internal" -}}
{{- $value := .value -}}
{{- $tokens := .tokens -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $parentTargetTemplate := .parentTargetTemplate -}}
{{- $root := .root -}}
{{- $resolving := .resolving -}}
{{- $reservedKeys := .reservedKeys -}}
{{- $gen := .gen -}}
{{- if kindIs "string" $value -}}
  {{- $substituted := include "crdkit.substituteText.internal" (dict "text" $value "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" $resolving "reservedKeys" $reservedKeys "gen" $gen) -}}
value: {{ $substituted | toYaml | nindent 2 }}
{{- else if kindIs "map" $value -}}
  {{- $result := dict -}}
  {{- range $k, $v := $value -}}
    {{- $sub := include "crdkit.substituteStructure.internal" (dict "value" $v "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" $resolving "reservedKeys" $reservedKeys "gen" $gen) | fromYaml -}}
    {{- $_ := set $result $k $sub.value -}}
  {{- end -}}
value: {{ $result | toYaml | nindent 2 }}
{{- else if kindIs "slice" $value -}}
  {{- $result := list -}}
  {{- range $item := $value -}}
    {{- $sub := include "crdkit.substituteStructure.internal" (dict "value" $item "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" $resolving "reservedKeys" $reservedKeys "gen" $gen) | fromYaml -}}
    {{- $result = append $result $sub.value -}}
  {{- end -}}
value: {{ $result | toYaml | nindent 2 }}
{{- else -}}
value: {{ $value | toYaml | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
crdkit.substituteText.internal (internal)

Substitutes "@ref@" markers within a single string leaf, for the SAME
target as the value being substituted into.

Interface:
- Params (dict): { "text": <string>, "tokens": <live tokens map>,
  "target": <string>, "diag": <dict>, "parentTargetTemplate":
  <fully-qualified template name>, "root": <caller's root context>,
  "resolving": <list of names in progress, non-empty>,
  "reservedKeys": <list>, "gen": <int> }
- Returns: text with every "@NAME@" reference substituted.

Implementation notes:
- Cycle detection: "resolving" is the in-progress name stack for THIS
  top-level resolution/target — referencing a name already on it
  records an ERROR and leaves that one marker unexpanded (rather than
  recursing infinitely), so the rest of the value still resolves.
- "@AT@" is never treated as a token reference here — handled once,
  separately, by crdkit.tokens.substitute's final pass.
- A referenced token resolving to a STRUCTURE is spliced as text by
  crdkit.stringify.internal (list → ","-joined, dict → JSON).
*/}}
{{- define "crdkit.substituteText.internal" -}}
{{- $text := .text -}}
{{- $tokens := .tokens -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- $parentTargetTemplate := .parentTargetTemplate -}}
{{- $root := .root -}}
{{- $resolving := .resolving -}}
{{- $reservedKeys := .reservedKeys -}}
{{- $gen := .gen -}}
{{- $markers := regexFindAll (include "crdkit.markerPattern.internal" (dict)) $text -1 -}}
{{- range $marker := $markers -}}
  {{- $refName := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $refName "AT") (hasKey $tokens $refName) -}}
    {{- if has $refName $resolving -}}
      {{- $_ := set $diag "errors" (append $diag.errors (printf "token '%s' references '@%s@', which is already being resolved — cycle (direct or indirect self-reference)" (last $resolving) $refName)) -}}
    {{- else -}}
      {{- $refResolved := include "crdkit.resolveEntry.internal" (dict "fieldId" $refName "def" (index $tokens $refName) "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" $resolving "reservedKeys" $reservedKeys "gen" $gen) | fromYaml -}}
      {{- $text = $text | replace $marker (include "crdkit.stringify.internal" (dict "resolved" $refResolved) | fromYaml).text -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $text -}}
{{- end -}}

{{/*
crdkit.stringify.internal (internal)

Coerces an already-resolved value for embedding into a text blob (a
"@NAME@" marker's replacement, or a direct *.string entry point).

Interface:
- Params (dict): { "resolved": <already-decoded {value: <any>} dict> }
- Returns YAML: { "text": <string> }

Implementation notes:
- string → as-is; bool/int/float → `toString`; list → every element
  stringified (a scalar as above, a nil as an empty string, a dict/list
  element as JSON), joined by "," (no space); dict → JSON (`toJson`).
- Shared by crdkit.token.string, crdkit.tokenDef.string,
  crdkit.tokens.substituteMarkers.internal and
  crdkit.substituteText.internal — one place decides what "give me this
  as text" means.
*/}}
{{- define "crdkit.stringify.internal" -}}
{{- $v := .resolved.value -}}
{{- if kindIs "string" $v -}}
text: {{ $v | quote }}
{{- else if kindIs "map" $v -}}
text: {{ $v | toJson | quote }}
{{- else if kindIs "slice" $v -}}
  {{- $parts := list -}}
  {{- range $element := $v -}}
    {{- if or (kindIs "map" $element) (kindIs "slice" $element) -}}
      {{- $parts = append $parts (toJson $element) -}}
    {{- else if kindIs "invalid" $element -}}
      {{- $parts = append $parts "" -}}
    {{- else -}}
      {{- $parts = append $parts (toString $element) -}}
    {{- end -}}
  {{- end -}}
text: {{ join "," $parts | quote }}
{{- else -}}
text: {{ $v | toString | quote }}
{{- end -}}
{{- end -}}

{{/*
crdkit.token.value (public)

Resolves a REAL token, registered under "name" in ctx.tokens.

Interface:
- Params (list): [ctx, name, target?]
  - ctx: dict with "tokens"/"diag"/"parentTargetTemplate"/"target"
    keys, plus "reservedKeys" and "gen" (both optional)
  - name: token name to resolve
  - target: optional — defaults to ctx.target; pass explicitly only to
    resolve for a target OTHER than the render's own
- Returns YAML: { "value": <resolved string, or a dict/list with every
  string leaf's markers resolved> }

Implementation notes:
- List-based (not dict) — deliberate exception for this frequently-
  called, fixed-shape entry point (see crdkit.dictMerge/listExtend for
  the other).
- "unknown token '%s' referenced" is diagnosed HERE, not in
  crdkit.resolveEntry.internal — this is the one caller that does a
  name-based lookup, so it's the one that can tell "unknown" apart from
  "declared but unresolvable."
- Always needs `| fromYaml` then `.value` on the caller's side — unlike
  crdkit.token.string, which needs neither. The wrapper is required
  HERE because the resolved value can be any kind (string/dict/list/
  bool/...), and Helm's `fromYaml` can only decode a top-level map;
  crdkit.token.string skips it entirely because a plain string needs no
  decoding at all.
*/}}
{{- define "crdkit.token.value" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 2) (index . 2) -}}
  {{- $target = index . 2 -}}
{{- end -}}
{{- if not (hasKey $ctx.tokens $name) -}}
{{- $_ := set $ctx.diag "errors" (append $ctx.diag.errors (printf "unknown token '%s' referenced" $name)) -}}
value: ""
{{- else -}}
{{- include "crdkit.resolveEntry.internal" (dict "fieldId" $name "def" (index $ctx.tokens $name) "tokens" $ctx.tokens "target" $target "diag" $ctx.diag "parentTargetTemplate" $ctx.parentTargetTemplate "root" $ctx.root "reservedKeys" $ctx.reservedKeys "gen" $ctx.gen) -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.token.string (public)

Resolves a REAL token and coerces the result to text (see
crdkit.stringify.internal) — for use outside the usual "@NAME@" marker
mechanism, when the caller wants the value directly.

Interface:
- Params (list): [ctx, name, target?] — same as crdkit.token.value
- Returns: plain string.

Implementation notes:
- A structured result comes back as text: list → ","-joined, dict →
  JSON (crdkit.stringify.internal).
*/}}
{{- define "crdkit.token.string" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $target := "" -}}
{{- if gt (len .) 2 -}}
  {{- $target = index . 2 -}}
{{- end -}}
{{- $resolved := include "crdkit.token.value" (list $ctx $name $target) | fromYaml -}}
{{- (include "crdkit.stringify.internal" (dict "resolved" $resolved) | fromYaml).text -}}
{{- end -}}

{{/*
crdkit.tokenDef.value (public)

Resolves an arbitrary structure using the exact same target- escalation
rules as a real token, without requiring it to be registered under a
name in ctx.tokens.

Interface:
- Params (list): [ctx, fieldId, def, target?]
  - ctx: dict with "tokens"/"diag"/"parentTargetTemplate"/"target"
    keys, plus "reservedKeys" and "gen" (both optional)
  - fieldId: label used in diagnostics — required, since "def" has no
    name of its own
  - def: a structure sourced from consumer Values, shaped like a token
    declaration (scalar, or dict with default/target-keys/match) — NOT
    registered in ctx.tokens
  - target: optional — defaults to ctx.target
- Returns YAML: { "value": <resolved string, or a dict/list with every
  string leaf's markers resolved> }

Implementation notes:
- Any `@ref@` marker in the resolved value is still looked up in the
  REAL ctx.tokens — "def" is never itself a token namespace.
*/}}
{{- define "crdkit.tokenDef.value" -}}
{{- $ctx := index . 0 -}}
{{- $fieldId := index . 1 -}}
{{- $def := index . 2 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 3) (index . 3) -}}
  {{- $target = index . 3 -}}
{{- end -}}
{{- include "crdkit.resolveEntry.internal" (dict "fieldId" $fieldId "def" $def "tokens" $ctx.tokens "target" $target "diag" $ctx.diag "parentTargetTemplate" $ctx.parentTargetTemplate "root" $ctx.root "reservedKeys" $ctx.reservedKeys "gen" $ctx.gen) -}}
{{- end -}}

{{/*
crdkit.tokenDef.string (public)

Resolves an arbitrary structure and coerces the result to text (see
crdkit.stringify.internal).

Interface:
- Params (list): [ctx, fieldId, def, target?] — same as
  crdkit.tokenDef.value
- Returns: plain string.

Implementation notes:
- A structured result comes back as text: list → ","-joined, dict →
  JSON (crdkit.stringify.internal).
*/}}
{{- define "crdkit.tokenDef.string" -}}
{{- $ctx := index . 0 -}}
{{- $fieldId := index . 1 -}}
{{- $def := index . 2 -}}
{{- $target := "" -}}
{{- if gt (len .) 3 -}}
  {{- $target = index . 3 -}}
{{- end -}}
{{- $resolved := include "crdkit.tokenDef.value" (list $ctx $fieldId $def $target) | fromYaml -}}
{{- (include "crdkit.stringify.internal" (dict "resolved" $resolved) | fromYaml).text -}}
{{- end -}}

{{/*
crdkit.tokens.substitute (public)

Replaces "@NAME@" markers in an arbitrary text block by resolving each
referenced token on demand — this is what makes a token "used."

Interface:
- Params (list): [ctx, text, target?]
  - target: optional — defaults to ctx.target
- Returns: text with every "@NAME@" marker resolved, and "@AT@"
  replaced with a literal "@".

Implementation notes:
- A marker naming something that isn't a known token is left
  untouched — the caller is responsible for a "possible typo"
  diagnostic against whatever's left over.
- "@AT@" is replaced last, after every other substitution, so it can't
  be misread as part of another marker mid-resolution.
*/}}
{{- define "crdkit.tokens.substitute" -}}
{{- include "crdkit.tokens.substituteMarkers.internal" . | replace "@AT@" "@" -}}
{{- end -}}

{{/*
crdkit.tokens.substituteMarkers.internal (internal)

crdkit.tokens.substitute without the final "@AT@" pass — for
crdkit.render, which scans the result for unresolved markers before
"@AT@" becomes "@" (an escaped `@AT@example.com@` is never reported).

Interface:
- Params (list): [ctx, text, target?] — same as crdkit.tokens.substitute
- Returns: text with every "@NAME@" marker of a known token resolved;
  "@AT@" untouched.

Implementation notes:
- A marker naming a token that resolves to a STRUCTURE is spliced as
  text by crdkit.stringify.internal (list → ","-joined, dict → JSON).
*/}}
{{- define "crdkit.tokens.substituteMarkers.internal" -}}
{{- $ctx := index . 0 -}}
{{- $text := index . 1 -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 2) (index . 2) -}}
  {{- $target = index . 2 -}}
{{- end -}}
{{- $tokens := $ctx.tokens -}}
{{- $markers := regexFindAll (include "crdkit.markerPattern.internal" (dict)) $text -1 -}}
{{- range $marker := $markers -}}
  {{- $name := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $name "AT") (hasKey $tokens $name) -}}
    {{- $resolved := include "crdkit.token.value" (list $ctx $name $target) | fromYaml -}}
    {{- $text = $text | replace $marker (include "crdkit.stringify.internal" (dict "resolved" $resolved) | fromYaml).text -}}
  {{- end -}}
{{- end -}}
{{- $text -}}
{{- end -}}

{{/*
crdkit.token.add (public)

Injects one derived token into a live tokens map — the crdkit.token.add
counterpart to crdkit.dictMerge/listExtend for ctx.model.

Interface:
- Params (list): [ctx, name, value, annotations?, target?]
  - ctx: dict with "tokens"/"diag"/"target"/"gen" keys
  - name: token name to add
  - value: raw value for this exact target (may contain "@ref@"
    markers, or be a structure — resolved lazily like any other value)
  - annotations: dict of annotation key-value pairs, optional — merged
    over existing annotations (a key present in both uses the new value;
    missing keys are inherited). Non-dict non-nil values record an ERROR
    but do not prevent the value from being stored. crdkit.token.add
    callers are trusted, first-party library code (no annotation values
    are validated).
  - target: exact target string "value" applies to — optional, defaults
    to ctx.target
- Returns: nothing (mutates ctx.tokens in place, bumps ctx.gen).

Implementation notes:
- Stores "value" as a dedicated attribute (literal key = target),
  merged into the token's existing entries — NOT resolved at add-time,
  so a value can reference a token another integration adds later in
  the chain.
- A repeat call for an existing name MERGES: new target → new key;
  same target → overwrite. Annotations are merged (new keys and
  overwrites present in both). The cache keys (_value, _gen) are dropped
  on write; _generated (see crdkit.token.underlay) is kept — an entry
  added here for a target beats the generated value for that target.
- Bumps ctx.gen to invalidate resolution caches — resolveEntry.internal
  checks _gen against the current generation to detect stale cache.
- Skips the reserved-name collision check
  (crdkit.tokens.merge.internal's) — that protects against untrusted
  consumer input; crdkit.token.add callers are trusted, first-party
  code.
*/}}
{{- define "crdkit.token.add" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $value := index . 2 -}}
{{- $rawAnnotations := "" -}}
{{- if gt (len .) 3 -}}
  {{- $rawAnnotations = index . 3 -}}
{{- end -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 4) (index . 4) -}}
  {{- $target = index . 4 -}}
{{- end -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}

{{- if and $rawAnnotations (not (kindIs "map" $rawAnnotations)) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "crdkit.token.add for '%s': annotations must be a dict — ignored" $name)) -}}
{{- end -}}

{{- $decl := dict -}}
{{- if hasKey $tokens $name -}}
  {{- $existing := index $tokens $name -}}
  {{- if kindIs "map" $existing -}}
    {{- $decl = omit $existing "_value" "_gen" -}}
  {{- end -}}
{{- end -}}

{{- if and $rawAnnotations (kindIs "map" $rawAnnotations) -}}
  {{- range $k, $v := $rawAnnotations -}}
    {{- $_ := set $decl $k $v -}}
  {{- end -}}
{{- end -}}

{{- $_ := set $decl $target $value -}}
{{- $_ := set $ctx "gen" (add1 $ctx.gen) -}}
{{- $_ := set $tokens $name $decl -}}
{{- end -}}

{{/*
crdkit.token.underlay (public)

Registers a GENERATED value: the lowest-priority source for a token,
consulted only after every consumer-declared source (exact target,
match, parent walk, default) found nothing. Creates the token if it does
not exist.

Interface:
- Params (list): [ctx, name, value, annotations?, target?]
  - ctx: dict with "tokens"/"diag"/"target"/"gen" keys
  - name: token name
  - value: generated value for this exact target (may contain "@ref@"
    markers, or be a structure — resolved lazily like any other value)
  - annotations: dict of annotation key-value pairs, optional — each key
    is set only when the declaration does not already have it. Non-dict
    non-nil values record an ERROR and are ignored.
  - target: exact target string "value" applies to — optional, defaults
    to ctx.target
- Returns: nothing (mutates ctx.tokens in place, bumps ctx.gen).

Implementation notes:
- Stores "value" under `_generated[target]`, overwriting any earlier
  generated value for that target. A generated value applies to its
  exact target only and is cached under that target alone.
- Annotations never overwrite: an existing annotation (e.g. one the
  consumer declared) wins over the generated one.
- Bumps ctx.gen to invalidate resolution caches.
- Annotations check matches crdkit.token.add; callers are trusted,
  first-party code.
*/}}
{{- define "crdkit.token.underlay" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $value := index . 2 -}}
{{- $rawAnnotations := "" -}}
{{- if gt (len .) 3 -}}
  {{- $rawAnnotations = index . 3 -}}
{{- end -}}
{{- $target := $ctx.target -}}
{{- if and (gt (len .) 4) (index . 4) -}}
  {{- $target = index . 4 -}}
{{- end -}}
{{- $tokens := $ctx.tokens -}}
{{- $diag := $ctx.diag -}}

{{- if and $rawAnnotations (not (kindIs "map" $rawAnnotations)) -}}
  {{- $_ := set $diag "errors" (append $diag.errors (printf "crdkit.token.underlay for '%s': annotations must be a dict — ignored" $name)) -}}
{{- end -}}

{{- $decl := dict -}}
{{- if hasKey $tokens $name -}}
  {{- $existing := index $tokens $name -}}
  {{- if kindIs "map" $existing -}}
    {{- $decl = omit $existing "_value" "_gen" -}}
  {{- end -}}
{{- end -}}

{{- if and $rawAnnotations (kindIs "map" $rawAnnotations) -}}
  {{- range $k, $v := $rawAnnotations -}}
    {{- if not (hasKey $decl $k) -}}
      {{- $_ := set $decl $k $v -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $generated := dict -}}
{{- if and (hasKey $decl "_generated") (kindIs "map" (index $decl "_generated")) -}}
  {{- $generated = index $decl "_generated" -}}
{{- end -}}
{{- $_ := set $generated $target $value -}}
{{- $_ := set $decl "_generated" $generated -}}
{{- $_ := set $ctx "gen" (add1 $ctx.gen) -}}
{{- $_ := set $tokens $name $decl -}}
{{- end -}}
