{{/*
Internal helpers of templates/_tokens.tpl — see its file-level doc
comment for the overview and dependency graph.
*/}}


{{/*
crdkit.annotationKey.internal (internal)

Reports whether a key names a declared token annotation.

Interface:
- Params (dict): { "ctx": <ctx>, "key": <string> }
- Returns: "true" when the key is a declared annotation, "" otherwise.

Implementation notes:
- The annotation names are ctx.reservedKeys minus the built-in reserved
  keys; a colliding declaration was dropped at merge time, so it is not
  an annotation here either.
*/}}
{{- define "crdkit.annotationKey.internal" -}}
{{- $key := .key -}}
{{- if not (has $key (list "_value" "_gen" "_generated" "match")) -}}
  {{- if has $key (.ctx.reservedKeys | default (list)) -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.markersWalk.internal (internal)

Collects marker names from a value's string leaves into
`state.names`/`state.seen`. Invoked by crdkit.markers.

Interface:
- Params (dict): { "value": <any structure>, "state": {"names": <list>,
  "seen": <dict>} }
- Returns: "" (mutates `state`).
*/}}
{{- define "crdkit.markersWalk.internal" -}}
{{- $state := .state -}}
{{- $v := .value -}}
{{- if kindIs "string" $v -}}
  {{- range $m := regexFindAll (include "crdkit.markerPattern" (dict)) $v -1 -}}
    {{- $name := trimSuffix "@" (trimPrefix "@" $m) -}}
    {{- if and (ne $name "AT") (not (hasKey $state.seen $name)) -}}
      {{- $_ := set $state.seen $name true -}}
      {{- $_ := set $state "names" (append $state.names $name) -}}
    {{- end -}}
  {{- end -}}
{{- else if kindIs "map" $v -}}
  {{- range $k := keys $v | sortAlpha -}}
    {{- include "crdkit.markersWalk.internal" (dict "value" (index $v $k) "state" $state) -}}
  {{- end -}}
{{- else if kindIs "slice" $v -}}
  {{- range $e := $v -}}
    {{- include "crdkit.markersWalk.internal" (dict "value" $e "state" $state) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.reservedKeys.internal (internal)

Computes the complete list of reserved (non-entry) keys: built-in crdkit
keys (_value, _gen, _generated, match) plus every token annotation name
that does NOT collide; colliding names are dropped with an ERROR.

Interface:
- Params (dict): { "tokenAnnotations": <list of strings>, "diag": <dict> }
- Returns YAML: { "value": <list of reserved key names> }

Implementation notes:
- A token annotation named like a built-in key OR "default" collides:
  "default" stays a target entry, so it can't also be an annotation.
- The list is computed once per render (crdkit.render) and handed to
  every resolution helper through ctx.reservedKeys.
*/}}
{{- define "crdkit.reservedKeys.internal" -}}
{{- $annotations := .tokenAnnotations | default (list) -}}
{{- $diag := .diag -}}
{{- $collisionCheck := list "_value" "_gen" "_generated" "match" "default" -}}
{{- $result := list "_value" "_gen" "_generated" "match" -}}
{{- range $annot := $annotations -}}
  {{- if has $annot $collisionCheck -}}
    {{- include "crdkit.diag.error" (list $diag (printf "token annotation name '%s' collides with a crdkit-reserved key and was ignored" $annot)) -}}
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
    {{- include "crdkit.diag.warning" (list $diag (printf "token '%s' is reserved by the library and was overridden back to the library value" $name)) -}}
  {{- else if has $name $builtins -}}
    {{- include "crdkit.diag.warning" (list $diag (printf "token '%s' is a reserved built-in and cannot be redefined; the user-supplied value was ignored" $name)) -}}
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
      {{- include "crdkit.diag.warning" (list $diag (printf "token '%s' declares crdkit-internal key '%s'; it was removed" $name $key)) -}}
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
     key (or cache) at each rung. `match:` must be checked before any
     cache-tier hit from the walk, or a broader cached rung could steal
     precedence from a target-specific `match:` rule.
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
- Caching: the result is cached under the exact target always, and
  under every rung walked only when the selected entry holds no marker
  (a map/list: checked on its `toJson`) — a marker-free entry
  substitutes to the same value for every target reaching that rung. A
  marker-holding entry (`_generated` too) is cached under the exact
  target only: its substitution depends on the target, so another
  target re-walks the ladder.
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
            {{- include "crdkit.diag.error" (list $diag (printf "target escalation chain for '%s' cycles back to '%s' while resolving from '%s'" $fieldId $next $target)) -}}
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
        {{- include "crdkit.diag.error" (list $diag (printf "no value found for '%s' — target chain exhausted at '%s' starting from '%s'" $fieldId $current $target)) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- $substituted := include "crdkit.substituteStructure.internal" (dict "value" $rawValue "tokens" $tokens "target" $target "diag" $diag "parentTargetTemplate" $parentTargetTemplate "root" $root "resolving" (append $resolving $fieldId) "reservedKeys" $reservedKeys "gen" $gen) | fromYaml -}}
  {{- $resolvedValue := $substituted.value -}}
  {{- if $cacheable -}}
    {{- $rawText := $rawValue -}}
    {{- if or (kindIs "map" $rawValue) (kindIs "slice" $rawValue) -}}
      {{- $rawText = toJson $rawValue -}}
    {{- end -}}
    {{- $hasMarker := and (kindIs "string" $rawText) (regexMatch (include "crdkit.markerPattern" (dict)) $rawText) -}}
    {{/* rungs are shared across targets: a generated value (per target) or a marker-holding entry (substituted per target) must not leak into rung caches. */}}
    {{- if or $fromGenerated $hasMarker -}}
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
{{- $markers := regexFindAll (include "crdkit.markerPattern" (dict)) $text -1 -}}
{{- range $marker := $markers -}}
  {{- $refName := trimSuffix "@" (trimPrefix "@" $marker) -}}
  {{- if and (ne $refName "AT") (hasKey $tokens $refName) -}}
    {{- if has $refName $resolving -}}
      {{- include "crdkit.diag.error" (list $diag (printf "token '%s' references '@%s@', which is already being resolved — cycle (direct or indirect self-reference)" (last $resolving) $refName)) -}}
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
{{- $markers := regexFindAll (include "crdkit.markerPattern" (dict)) $text -1 -}}
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
crdkit.substituteValue.internal (internal)

Builds a copy of a value with every string leaf substituted; map keys
are data. Invoked by crdkit.render's final pass.

Interface:
- Params (dict): { "ctx": <ctx>, "value": <any>, "holder": <dict>,
  "unresolved": <dict marker -> true> }
- Returns: ""; writes the substituted copy to `holder.value`.

Implementation notes:
- Builds new maps/lists instead of mutating: a subtree may alias `state`
  data or another subtree and a second visit would re-read an
  `@AT@`-escaped leaf as a marker.
- Each leaf's leftover markers (before `@AT@` becomes "@") are collected
  into `unresolved` for the typo scan.
*/}}
{{- define "crdkit.substituteValue.internal" -}}
{{- $holder := .holder -}}
{{- $v := .value -}}
{{- if kindIs "string" $v -}}
  {{- $text := include "crdkit.tokens.substituteMarkers.internal" (list .ctx $v) -}}
  {{- range $m := regexFindAll (include "crdkit.markerPattern" (dict)) $text -1 -}}
    {{- $_ := set $.unresolved $m true -}}
  {{- end -}}
  {{- $_ := set $holder "value" ($text | replace "@AT@" "@") -}}
{{- else if kindIs "map" $v -}}
  {{- $out := dict -}}
  {{- range $k, $e := $v -}}
    {{- $h := dict -}}
    {{- include "crdkit.substituteValue.internal" (dict "ctx" $.ctx "value" $e "holder" $h "unresolved" $.unresolved) -}}
    {{- $_ := set $out $k $h.value -}}
  {{- end -}}
  {{- $_ := set $holder "value" $out -}}
{{- else if kindIs "slice" $v -}}
  {{- $out := list -}}
  {{- range $e := $v -}}
    {{- $h := dict -}}
    {{- include "crdkit.substituteValue.internal" (dict "ctx" $.ctx "value" $e "holder" $h "unresolved" $.unresolved) -}}
    {{- $out = append $out $h.value -}}
  {{- end -}}
  {{- $_ := set $holder "value" $out -}}
{{- else -}}
  {{- $_ := set $holder "value" $v -}}
{{- end -}}
{{- end -}}
