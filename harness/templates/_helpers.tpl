{{/*
harness.parentTarget (internal)

Test-only "parentTarget" implementation, playing the role a real
specific library's own template would play (e.g. "mycrd.parentTarget")
— see crdkit.render's "parentTargetTemplate" param. Entirely data-driven so
individual test cases can opt into a target-escalation chain just by
setting values, with no need to define a bespoke template per test:
.Values.parentTargetMap is a flat {rung: nextRung} dict, walked one hop
at a time by crdkit's own resolution engine. A test that never sets
parentTargetMap gets an empty map, so every lookup misses — no
escalation at all, same as crdkit.noParentTarget.

Interface:
- Params (dict): { "target": <string, the current rung>, "context": <root $> }
  — the shape every "parentTarget" template receives.
- Returns: the next rung from `.Values.parentTargetMap`, or nothing.

Implementation notes:
GOTCHA, worth knowing before writing any OTHER "parentTarget" template:
a bare `{{- index $map $target -}}` as a define block's trailing output,
for a KEY THAT'S MISSING from a `map[string]interface{}`, renders as the
literal 10-character text "<no value>" — NOT an empty string — when
invoked through `include`. Verified empirically (a hex dump of the
"empty" result showed the ASCII bytes for "<no value>", not zero
bytes) after this exact mistake produced a real bug here: crdkit's own
walk (crdkit.resolveEntry.internal) treated that string as a genuine next
rung, walked to it, got "<no value>" AGAIN next iteration, and tripped
its own cycle detector — a real diagnostic, not a hang, but a
confusing one, for what should have been "no escalation configured."
The fix is the explicit `hasKey` guard below; never rely on a bare
`index` call being empty for a missing key when it's the last thing a
template emits.
*/}}
{{- define "harness.parentTarget" -}}
{{- $target := .target -}}
{{- $root := .context -}}
{{- $map := $root.Values.parentTargetMap | default dict -}}
{{- if hasKey $map $target -}}
  {{- index $map $target -}}
{{- end -}}
{{- end -}}
