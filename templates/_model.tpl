{{/*
crdkit.ensureDictKey (public)

Ensures $model has "key" set, initializing it to "default" if absent.

Interface:
- Params (dict): { "model": <live model dict>, "key": <string>,
  "default": <zero value, e.g. (list) or (dict)> }
- Returns: nothing (mutates $model in place).

Implementation notes:
- Maps are reference types: a map passed as an include argument, even
  nested inside a wrapping dict literal, is still the SAME underlying
  map the caller holds — a `set` here is visible to the caller once
  this include returns.
- This is what lets any integration touch a ctx.model field without a
  central, pre-declared "model shape" — no field is pre-initialized.
- For "field is a map, add entries" or "field is a list, add items" a
  merge/extension helper fits better; reach for this only for a shape
  neither covers.
*/}}
{{- define "crdkit.ensureDictKey" -}}
{{- $model := .model -}}
{{- $key := .key -}}
{{- if not (hasKey $model $key) -}}
  {{- $_ := set $model $key .default -}}
{{- end -}}
{{- end -}}

{{/*
crdkit.dictMerge (public)

Merges "value" into the dict at a path of $model, creating missing
levels as empty dicts (incoming keys win on collision).

Interface:
- Params (list): [model, key1, ..., keyN, value] (N >= 0)
  - model: root dict to walk from
  - key1..keyN: path (may be empty)
  - value: dict to merge in at the end of the path
- Returns: nothing (mutates $model in place).

Implementation notes:
- List-based (dig-style, variadic path) rather than dict-with-named-
  keys — mirrors Sprig's `dig`, but reversed arg order (`dig` reads, so
  the target dict is last there too, but the source it reads FROM is
  last; this WRITES, so the root it's anchored to is first).
- Zero path keys (`[model, value]`) is a supported degenerate case:
  merges "value" directly into "model", no nesting — for setting
  several independent top-level scalar fields in one shot (e.g.
  apiVersion/kind). Requires at least `[model, value]` (2 elements);
  fewer is a template-authoring bug (ordinary template error, not a
  diagnostic).
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
crdkit.listExtend (public)

Same as crdkit.dictMerge, but the final path segment is ensured to be a
LIST, and "value" is appended via `concat`.

Interface:
- Params (list): [model, key1, ..., keyN, value] (N >= 1, value is a
  list)
- Returns: nothing (mutates $model in place).

Implementation notes:
- No zero-key case (unlike dictMerge) — `ctx.model` is always a dict,
  never a list, so "append directly into model" isn't meaningful.
- `concat` (like `append`) returns a NEW slice rather than mutating in
  place, so the final step needs an explicit `set` back onto the
  second-to-last level — unlike dictMerge's final step, which mutates
  the target map in place via `index`.
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

{{/*
crdkit.model.hasPath (public)

Reports whether every key of a path exists in $model, each intermediate
node being a map.

Interface:
- Params (list): [model, key1, ..., keyN] (N >= 0) — same shape as the
  path of Sprig's `dig`
- Returns: the plain string "true" when the path exists, an EMPTY string
  otherwise. Usable directly as
  `{{ if include "crdkit.model.hasPath" (list $model "a" "b") }}`.

Implementation notes:
- NEVER return "false": a non-empty string is truthy in Go templates,
  so every `if` over the result would pass.
- No `{value: …}` wrapper: the wrapper exists only for results decoded
  with `fromYaml`; a presence flag needs no decoding.
- A key whose value is nil or empty still counts as present.
- A path through a scalar or list is missing.
- Never mutates `model`; never records diagnostics.
*/}}
{{- define "crdkit.model.hasPath" -}}
{{- $node := first . -}}
{{- $found := true -}}
{{- range $key := rest . -}}
  {{- if $found -}}
    {{- if kindIs "map" $node -}}
      {{- if hasKey $node $key -}}
        {{- $node = index $node $key -}}
      {{- else -}}
        {{- $found = false -}}
      {{- end -}}
    {{- else -}}
      {{- $found = false -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if $found -}}true{{- end -}}
{{- end -}}
