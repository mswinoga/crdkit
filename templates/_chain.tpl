{{/*
Generic middleware-style dispatcher for "integration" filters owned by
whatever specific CRD library depends on crdkit. Each chain entry is a
fully-qualified template name (e.g. "mycrd.integration.database") — the
caller's own naming — so crdkit never needs to know or guess another
chart's naming convention.

Each integration define receives the SAME ctx object for the whole
traversal and is expected to:
  1. do any "pre" work (mutate ctx.model / ctx.tokens as needed)
  2. call back into crdkit.integrations.chain, passing along whatever
     chain remains, to let filters further down the chain run
  3. do any "post" work, once step 2 returns

The first name in "chain" is OUTERMOST: its post-phase runs last, seeing
everything every filter below it did — same wrapping order as a typical
middleware/onion stack.

ctx (root/diag/model/tokens) is passed through UNCHANGED and must never
be rebuilt or copied here — it's a shared, mutate-in-place accumulator,
same discipline as $diag elsewhere in this library. "chain" is the
opposite: an ordinary, never-mutated value that's simply narrowed via
`rest` on each recursive call. Mixing those two mutation disciplines
into one object is exactly what to avoid, which is why "chain" is kept
as a sibling argument here rather than folded into ctx.

Expects a dict: { "chain": <list of fully-qualified template names>, "ctx": <dict as above> }
*/}}
{{- define "crdkit.integrations.chain" -}}
{{- $ctx := .ctx -}}
{{- $chain := .chain -}}
{{- if $chain -}}
  {{- include (first $chain) (dict "ctx" $ctx "chain" (rest $chain)) -}}
{{- end -}}
{{- end -}}
