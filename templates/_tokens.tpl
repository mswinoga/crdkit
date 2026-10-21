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
  Each target gets its own value, also within one render: a rung cache
  holds only marker-free entries, so a marker-holding entry
  (`@LOGICAL_ENV@`, a per-target token) is substituted per target
  (crdkit.resolveEntry.internal).

Token declaration shape (what a consumer/integration writes/reads on
`ctx.tokens[NAME]`):
- A bare scalar (same value for every target) — crdkit.tokens.merge.internal
  normalizes it into `{default: <that>}` right after merging, so
  `ctx.tokens[NAME]` is ALWAYS a dict.
- Reserved dict keys (never target entries): the crdkit-internal keys
  "_value" (memoization cache), "_gen" (generation the cache belongs to)
  and "_generated" (values registered by crdkit.token.underlay), "match"
  (regex rules), and every TOKEN ANNOTATION name the calling library
  passes to crdkit.render as `tokenAnnotations`
  (crdkit.reservedKeys.internal). "default" is NOT
  reserved — it's an ordinary target entry that crdkit ALSO treats as a
  hardcoded fallback (see crdkit.resolveEntry.internal). Every other key
  IS a target entry.
- Token annotations are static metadata on a declaration (e.g. an owner or an
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
{{- include "crdkit.diag.error" (list $ctx.diag (printf "unknown token '%s' referenced" $name)) -}}
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
  {{- include "crdkit.diag.error" (list $diag (printf "crdkit.token.add for '%s': annotations must be a dict — ignored" $name)) -}}
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
  {{- include "crdkit.diag.error" (list $diag (printf "crdkit.token.underlay for '%s': annotations must be a dict — ignored" $name)) -}}
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
