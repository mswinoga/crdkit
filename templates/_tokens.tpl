{{/*
Token resolution: the merge, lookup and substitution engine and the token
API; scope is per define.
- See CONTRIBUTING "Resolution model".
- See CONTRIBUTING "Target escalation".
- See CONTRIBUTING "Token model".
- Never read `ctx.tokens[NAME].value`: resolve through crdkit.token.value.
*/}}

{{/*
crdkit.matchRules (public)

Evaluates a target-escalation-style regex rule list against a subject
string; first match wins.

Interface:
- Params (dict): { "subject": <string>, "rules": <list of single-key
  {pattern: replacement} dicts, may be nil/empty>, "diag": <dict,
  optional>, "label": <string, optional> }
- Returns YAML: { "matched": <bool>, "value": <string> }

Implementation notes:
- Full-string anchored (`^(?:pattern)$`) — a rule matches the WHOLE
  subject, never a substring.
- "replacement" may reference capture groups via $1/$2/...
- Optional "diag" + "label": with them (consumer rules), each regex is
  validated first; an invalid rule records an ERROR naming the label and
  the regex, is skipped, and later rules are still tried — never a
  non-`must*` match on an unchecked pattern. Without "diag"
  (library-owned rules) an invalid regex aborts via mustRegex*.
*/}}
{{- define "crdkit.matchRules" -}}
{{- $subject := .subject -}}
{{- $rules := .rules | default (list) -}}
{{- $diag := .diag -}}
{{- $label := .label | default "" -}}
{{- $result := "" -}}
{{- $found := false -}}
{{- range $rule := $rules -}}
  {{- if not $found -}}
    {{- range $pattern, $repl := $rule -}}
      {{- $valid := true -}}
      {{- if $diag -}}
        {{- if not (include "crdkit.regexValid.internal" (dict "pattern" $pattern)) -}}
          {{- include "crdkit.diag.error" (list $diag (printf "'%s': match rule '%s' is not a valid regex — skipped" $label $pattern)) -}}
          {{- $valid = false -}}
        {{- end -}}
      {{- end -}}
      {{- if $valid -}}
        {{- $anchoredRe := printf "^(?:%s)$" $pattern -}}
        {{- if $diag -}}
          {{- if regexMatch $anchoredRe $subject -}}
            {{- $result = regexReplaceAll $anchoredRe $subject $repl -}}
            {{- $found = true -}}
          {{- end -}}
        {{- else -}}
          {{- if mustRegexMatch $anchoredRe $subject -}}
            {{- $result = mustRegexReplaceAll $anchoredRe $subject $repl -}}
            {{- $found = true -}}
          {{- end -}}
        {{- end -}}
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
- Params (dict): the `{target, context}` shape every "parentTarget"
  template receives; both unused.
- Returns: nothing.
*/}}
{{- define "crdkit.noParentTarget" -}}
{{- end -}}

{{/*
crdkit.markerPattern (public)

The one definition of a "@NAME@" marker; every marker match uses it.
See CONTRIBUTING "Token model".

Interface:
- Params: an empty dict, or `{group: true}`.
- Returns: the regex as plain text — `@[A-Za-z0-9_.]+@`, or
  `@([A-Za-z0-9_.]+)@` with `group: true` (the captured name).

Implementation notes:
- "." is part of a name, so a dotted name (`@A.b@`) and a library's
  relative form (`@.x@`) are markers too. Side effect: text like
  `@example.com@` is a marker — escape it with "@AT@".
*/}}
{{- define "crdkit.markerPattern" -}}
{{- if .group -}}
@([A-Za-z0-9_.]+)@
{{- else -}}
@[A-Za-z0-9_.]+@
{{- end -}}
{{- end -}}

{{/*
crdkit.markers (public)

Lists the marker names in a value's string leaves.

Interface:
- Params (dict): { "value": <any structure> }
- Returns YAML: { "value": [names] } — each name without its "@" pair.

Implementation notes:
- Map values are walked in sorted key order, list items in list order,
  map keys never; first occurrence wins and duplicates are dropped.
- "AT" is excluded (it is crdkit's escape, not a token reference); dotted
  and relative names (".x") are kept as written.
*/}}
{{- define "crdkit.markers" -}}
{{- $state := dict "names" (list) "seen" (dict) -}}
{{- include "crdkit.markersWalk.internal" (dict "value" .value "state" $state) -}}
{{- dict "value" $state.names | toYaml -}}
{{- end -}}

{{/*
crdkit.token.annotate (public)

Sets token annotation keys on an existing declaration.

Interface:
- Params (list): [ctx, name, annotations]
  - ctx: dict with "tokens"/"diag"/"reservedKeys" keys
  - name: token name
  - annotations: dict of annotation key-value pairs
- Returns: "" (mutates the declaration in place; no `ctx.gen` bump —
  annotations never affect resolution).

Implementation notes:
- Existing keys are overwritten.
- Unknown token, non-dict `annotations`, or a key that is not a declared
  token annotation → ERROR, that input ignored (a key alone is dropped).
*/}}
{{- define "crdkit.token.annotate" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $annotations := index . 2 -}}
{{- if not (hasKey $ctx.tokens $name) -}}
  {{- include "crdkit.diag.error" (list $ctx.diag (printf "crdkit.token.annotate: unknown token '%s' — ignored" $name)) -}}
{{- else if not (kindIs "map" $annotations) -}}
  {{- include "crdkit.diag.error" (list $ctx.diag (printf "crdkit.token.annotate for '%s': annotations must be a dict — ignored" $name)) -}}
{{- else -}}
  {{- $decl := index $ctx.tokens $name -}}
  {{- range $k, $v := $annotations -}}
    {{- if include "crdkit.annotationKey.internal" (dict "ctx" $ctx "key" $k) -}}
      {{- $_ := set $decl $k $v -}}
    {{- else -}}
      {{- include "crdkit.diag.error" (list $ctx.diag (printf "crdkit.token.annotate for '%s': '%s' is not a token annotation — ignored" $name $k)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.token.info (public)

Reads a declaration's token annotations.

Interface:
- Params (list): [ctx, name]
- Returns YAML: { "exists": <bool>, "annotations": {<key>: <value>} } —
  only declared annotation keys that the declaration carries; a missing
  token gives `exists: false` and empty annotations; no diagnostic.
*/}}
{{- define "crdkit.token.info" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $found := dict -}}
{{- if hasKey $ctx.tokens $name -}}
  {{- $decl := index $ctx.tokens $name -}}
  {{- if kindIs "map" $decl -}}
    {{- range $key := $ctx.reservedKeys | default (list) -}}
      {{- if and (include "crdkit.annotationKey.internal" (dict "ctx" $ctx "key" $key)) (hasKey $decl $key) -}}
        {{- $_ := set $found $key (index $decl $key) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
exists: {{ hasKey $ctx.tokens $name }}
annotations:
{{ $found | toYaml | indent 2 }}
{{- end -}}

{{/*
crdkit.token.names (public)

Lists token names, optionally filtered by an annotation value.

Interface:
- Params (dict): { "ctx": <ctx>, "annotation": <name, optional>,
  "equals": <value, optional> }
- Returns YAML: { "value": [names, sorted] }.

Implementation notes:
- `annotation` alone keeps names whose declaration carries that key;
  `equals` additionally requires `toString` equality with the value.
*/}}
{{- define "crdkit.token.names" -}}
{{- $ctx := .ctx -}}
{{- $annotation := .annotation | default "" -}}
{{- $equals := .equals -}}
{{- $hasEquals := hasKey . "equals" -}}
{{- $names := list -}}
{{- range $name, $decl := $ctx.tokens -}}
  {{- $keep := true -}}
  {{- if $annotation -}}
    {{- $keep = and (kindIs "map" $decl) (hasKey $decl $annotation) -}}
    {{- if and $keep $hasEquals (ne (toString (index $decl $annotation)) (toString $equals)) -}}
      {{- $keep = false -}}
    {{- end -}}
  {{- end -}}
  {{- if $keep -}}{{- $names = append $names $name -}}{{- end -}}
{{- end -}}
{{- dict "value" ($names | sortAlpha) | toYaml -}}
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
- Always needs `| fromYaml` then `.value` on the caller's side: the
  resolved value can be any kind (string/dict/list/bool/...), and
  Helm's `fromYaml` can only decode a top-level map. A text-only caller
  skips the wrapper, because a plain string needs no decoding.
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

Resolves a real token as text, for a caller that wants the value
outside a marker. See CONTRIBUTING "Resolution model".

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

Resolves an arbitrary structure by the token rules, without registering
it in ctx.tokens.

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
    {{- if include "crdkit.annotationKey.internal" (dict "ctx" $ctx "key" $k) -}}
      {{- $_ := set $decl $k $v -}}
    {{- else -}}
      {{- include "crdkit.diag.error" (list $diag (printf "crdkit.token.add for '%s': '%s' is not a token annotation — ignored" $name $k)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $_ := set $decl $target $value -}}
{{- $_ := set $ctx "gen" (add1 $ctx.gen) -}}
{{- $_ := set $tokens $name $decl -}}
{{- end -}}

{{/*
crdkit.token.underlay (public)

Registers a generated value, a token's lowest-priority source; creates
the token if missing. See CONTRIBUTING "Target escalation".

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
{{- $prologue := dict -}}
{{- include "crdkit.tokenPrologue.internal" (dict "ctx" $ctx "args" . "verb" "crdkit.token.underlay" "holder" $prologue) -}}
{{- $name := $prologue.name -}}
{{- $decl := $prologue.declaration -}}
{{- if and $prologue.rawAnnotations $prologue.annotationsValid -}}
  {{- range $k, $v := $prologue.rawAnnotations -}}
    {{- if not (include "crdkit.annotationKey.internal" (dict "ctx" $ctx "key" $k)) -}}
      {{- include "crdkit.diag.error" (list $ctx.diag (printf "crdkit.token.underlay for '%s': '%s' is not a token annotation — ignored" $name $k)) -}}
    {{- else if not (hasKey $decl $k) -}}
      {{- $_ := set $decl $k $v -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $generated := dict -}}
{{- if and (hasKey $decl "_generated") (kindIs "map" (index $decl "_generated")) -}}
  {{- $generated = index $decl "_generated" -}}
{{- end -}}
{{- $_ := set $generated $prologue.target $prologue.value -}}
{{- $_ := set $decl "_generated" $generated -}}
{{- $_ := set $ctx "gen" (add1 $ctx.gen) -}}
{{- $_ := set $ctx.tokens $name $decl -}}
{{- end -}}
