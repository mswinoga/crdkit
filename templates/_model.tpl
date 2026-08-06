{{/*
Ensures $model has "key" set, initializing it to "default" if absent —
mutates $model IN PLACE. Maps are reference types: a map passed as an
include argument, even nested inside a wrapping dict literal, is still
the SAME underlying map the caller holds, so a `set` here is visible to
the caller once this include returns (verified empirically, not
assumed — see crdkit's CLAUDE.md).

This is what lets any integration safely touch a ctx.model field
without a central, pre-declared "model shape" existing ANYWHERE:
crdkit doesn't know it, and no specific library has to enumerate it
either. Each integration lazily ensures exactly the field(s) it needs,
right before it needs them — fully decentralized, plugin-style. crdkit
itself uses this same helper for "labels" (the one field it reads
itself, in crdkit.render) rather than special-casing it — there is no
field, including "labels", that's pre-initialized by anyone in advance.

For the two common shapes — "this field is a map, add entries to it" /
"this field is a list, add items to it" — prefer crdkit.dictMerge /
crdkit.listExtend below, which wrap this exact ensure-then-mutate
pattern in one call. Reach for this one directly only for a shape
neither of those covers.

Expects a dict: { "model": <live model dict>, "key": <string>, "default": <zero value, e.g. (list) or (dict)> }
*/}}
{{- define "crdkit.ensureDictKey" -}}
{{- $model := .model -}}
{{- $key := .key -}}
{{- if not (hasKey $model $key) -}}
  {{- $_ := set $model $key .default -}}
{{- end -}}
{{- end -}}

{{/*
Walks a MULTI-LEVEL path from $model, creating an empty dict at each
level that doesn't already exist (crdkit.ensureDictKey), then merges
"value" into the dict at the end of that path — incoming keys win on
collision (mergeOverwrite, not plain merge: this is "add/update these
entries", not "fill in only what's missing").

Takes a LIST, not a dict, deliberately breaking crdkit's usual "dict
with named keys" convention: [model, key1, key2, ..., keyN, value] —
first element is the root to walk from, last is the dict to merge in,
everything between is the path (at least one key). This mirrors Sprig's
own `dig` (also variadic-path, also positional) rather than trying to
smuggle a variable-length path into one named dict value, which would
be worse on both readability and honesty about what varies. Note the
root comes FIRST here and the target dict comes LAST, the reverse of
`dig`'s own arg order — `dig` is a read ending at a target ($dict is
what you're reading, so it's last); this is a write starting from a
root ($model is where you're anchored, so it's first).

Only the FINAL path segment's dict is merged into (via `index`, mutated
in place — same reference trick as crdkit.ensureDictKey, verified in
crdkit's CLAUDE.md); every path segment before it is walked via
ensureDictKey + reassigning the "current" pointer to descend one level.

ZERO path keys is a valid, deliberately supported degenerate case:
`[model, value]` merges "value" directly into "model" itself — no
nesting, no `ensureDictKey` walk needed at all. This is the right call
whenever an integration wants to set several independent TOP-LEVEL
scalar fields on `ctx.model` in one shot — e.g. `apiVersion`/`kind` (see
`my-crd`'s `mycrd.integration.preamble`) — rather than reaching for
`crdkit.ensureDictKey` directly per field. Requires at least `[model,
value]` (2 elements) — this is an internal template-authoring contract
between integrations and crdkit, not consumer-facing input, so an
integration author passing fewer gets an ordinary template error, not a
diagnostic; see crdkit's CLAUDE.md on where that line is drawn.

Expects a list: [model, key1, ..., keyN, value] (N >= 0)
*/}}
{{- define "crdkit.dictMerge" -}}
{{- $args := . -}}
{{- $model := first $args -}}
{{- $value := last $args -}}
{{- $path := initial (rest $args) -}}
{{- if not $path -}}
  {{- $_ := mergeOverwrite $model $value -}}
{{- else -}}
  {{- $current := $model -}}
  {{- range $key := initial $path -}}
    {{- include "crdkit.ensureDictKey" (dict "model" $current "key" $key "default" (dict)) -}}
    {{- $current = index $current $key -}}
  {{- end -}}
  {{- $finalKey := last $path -}}
  {{- include "crdkit.ensureDictKey" (dict "model" $current "key" $finalKey "default" (dict)) -}}
  {{- $_ := mergeOverwrite (index $current $finalKey) $value -}}
{{- end -}}
{{- end -}}

{{/*
Walks a MULTI-LEVEL path from $model exactly like crdkit.dictMerge
above (same list-argument shape, same dig-inspired reasoning) — but the
FINAL path segment is ensured to be a LIST, not a dict, and "value"
(itself a list) is appended onto the end of it via Sprig's `concat`.

UNLIKE crdkit.dictMerge, this keeps the "at least one path key"
requirement strictly — there's no zero-key degenerate case here, on
purpose: `ctx.model` itself is always a dict (`crdkit.render`
initializes it as a bare `dict`, never a list — see crdkit's CLAUDE.md),
so "append directly into model" is never a meaningful operation the way
"merge directly into model" is for crdkit.dictMerge. Always at least one
path key naming the LIST field being appended to.

Unlike crdkit.dictMerge's final step, this DOES need an explicit `set`
back onto the second-to-last level: `concat` (like `append`) always
returns a NEW slice rather than mutating in place — lists can't be
extended by reference the way maps can be merged by reference. See
crdkit's CLAUDE.md for this map-vs-list asymmetry. Every path segment
BEFORE the final one is still walked as an ordinary dict level, same as
crdkit.dictMerge.

Expects a list: [model, key1, ..., keyN, value] (N >= 1, value is a list)
*/}}
{{- define "crdkit.listExtend" -}}
{{- $args := . -}}
{{- $model := first $args -}}
{{- $value := last $args -}}
{{- $path := initial (rest $args) -}}
{{- $current := $model -}}
{{- range $key := initial $path -}}
  {{- include "crdkit.ensureDictKey" (dict "model" $current "key" $key "default" (dict)) -}}
  {{- $current = index $current $key -}}
{{- end -}}
{{- $finalKey := last $path -}}
{{- include "crdkit.ensureDictKey" (dict "model" $current "key" $finalKey "default" (list)) -}}
{{- $_ := set $current $finalKey (concat (index $current $finalKey) $value) -}}
{{- end -}}
