# crdkit

A generic Helm **library chart** providing the reusable machinery behind
target-aware, token-substituted Custom Resource rendering: token
resolution (scalar/target-keyed dict, recursive `@ref@` substitution), a
diagnostics accumulator (never `fail()`s — collects `# ERROR:`/
`# WARNING:` comments instead), and a middleware-style "integration
chain" dispatcher.

crdkit has **no knowledge of any specific CRD** — and, deliberately, no
knowledge of "environments," "families," or "tiers" either. It doesn't
know an `apiVersion`, a `kind`, what tokens are locked/defaulted, what
integrations exist, or how a `target` string escalates to a broader one
— ALL of that is supplied by a specific library chart (e.g. `my-crd`)
that depends on crdkit and wraps `crdkit.render` with its own thin
entry point.

## Who should depend on this

Not app repos directly. crdkit is meant to sit underneath a **specific**
CRD-rendering library chart (`my-crd` is the example in this workspace),
which app repos then depend on. See `my-crd/README.md` for the
consumer-facing contract.

```yaml
# my-crd's Chart.yaml
dependencies:
  - name: crdkit
    version: "0.0.0"
    repository: "file://../crdkit"
```

## What a specific library must supply to `crdkit.render`

`crdkit.render` takes everything product-specific as an explicit dict —
see the doc comment on `templates/_render.tpl` for the full parameter
list. In short: `system`/`defaults` token dicts, `chain` — an ordered
list of **fully-qualified** template names (`"mycrd.integration.foo"`)
implementing the integration-filter interface described in
`templates/_chain.tpl` — and `parentTargetTemplate`, a single fully-qualified
template name implementing the specific library's own target-escalation
taxonomy (see "Target escalation" below). `parentTargetTemplate` is optional
and defaults to no escalation at all if omitted.

Notably absent: `apiVersion`/`kind`/`labels`/anything about the CR's
actual shape. crdkit.render doesn't take any of that, doesn't compute
any of it, and never reads `context.Values` itself — the ENTIRE
`ctx.model` is built by whichever integrations a specific library puts
in its `chain` (by convention, a "preamble" integration, first in the
list). See "Building ctx.model" below.

## Integration chain mutation caveats

Integration filters receive a shared `ctx` (`root`/`diag`/`model`/
`tokens`/`target`) mutated in place across the whole traversal — same
discipline as the diagnostics accumulator. If a filter mutates
`ctx.tokens`, prefer `crdkit.addToken` (list-based: `(list $ctx
"DERIVED_VAR" "value" "targetContainer" $someTarget)`) over mutating it
by hand — it applies the same name-casing and targetContainer
validation every other token gets. Regardless of how a token gets added:

- **Visibility is order-dependent.** A token set partway through the
  chain is only visible to code that runs after that point in the
  traversal (per the onion/middleware ordering), not retroactively.
- **Resolution is lazy, so there's no "resolver pass" to miss.** A
  token added mid-chain via `crdkit.addToken` is stored as a DEDICATED
  ATTRIBUTE — a literal key equal to the exact `target` it was given —
  the same shape a consumer could have hand-declared — so the first
  time something actually references it (a `@NAME@` marker, or a
  declared `targetContainer`), it goes through the normal on-demand
  resolution path, `@ref@` chaining included. It does NOT need to be
  pre-resolved before inserting it — deliberately: an integration's
  value may reference a token another integration only adds LATER in
  the chain, and resolving eagerly at the `addToken` call site would
  wrongly fail on that. Calling `addToken` again for the same name adds
  another target's key rather than replacing the token outright — see
  crdkit's CLAUDE.md for the exact merge rules (per-target entries,
  `targetContainer` inheritance across calls).
- **Locked tokens are NOT re-asserted after the chain.** `crdkit.mergeTokens.internal`
  merges `system` last, protecting locked tokens against the untrusted
  boundary that actually matters — a consumer's own `tokens:` map. The
  chain itself is trusted, first-party library code (my-crd's own
  integrations, not application-repo input), so crdkit doesn't defend
  locked tokens against it, the same way it doesn't defend anything else
  in `ctx.model` against the chain that owns `ctx.model` in the first
  place. (An earlier version of this library DID re-assert after the
  chain — removed as unnecessary defense against trusted code once this
  distinction was made explicit; see crdkit's CLAUDE.md.)

## Building ctx.model

`crdkit.render` starts `ctx.model` as an empty dict and never touches it
again itself — the chain is the ONLY thing that populates it, via the
ordinary `crdkit.dictMerge`/`listExtend`/`ensureDictKey` mutation
primitives, with no special-cased field. That includes things you might
expect crdkit to know about — `apiVersion`, `kind`, labels, `metadata.name`,
`spec` — none of it is crdkit's concern. A specific library's own
"preamble" integration (by convention, first in `chain`) is where all of
that gets set, typically by pulling whatever it needs straight out of
`ctx.root.Values` itself:

```gotemplate
{{- define "mycrd.integration.preamble" -}}
{{- include "crdkit.dictMerge" (list .ctx.model (dict "apiVersion" "@API_GROUP@/v1" "kind" "SomeCR")) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" (dict "name" .ctx.root.Release.Name)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" "labels" (dig "metadata" "labels" (dict) .ctx.root.Values)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" "labels" (include "crdkit.standardLabels" (dict "context" .ctx.root) | fromYaml)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "spec" (.ctx.root.Values.spec | default dict)) -}}
{{- include "crdkit.integrations.chain" . -}}
{{- end -}}
```

(`crdkit.dictMerge` with an EMPTY path — `(list model value)` — merges
its dict directly into the target, no nesting; see its own doc comment
in `templates/_model.tpl`.) Ordering here IS the precedence policy:
consumer labels are merged first, `crdkit.standardLabels` second so it
overwrites any accidental collision with a consumer-supplied key, then
the rest of the chain (`crdkit.integrations.chain`) runs LAST and can
still deliberately override any of it — nothing here is a protected,
"always wins" guarantee; it's just ordinary mutation order, the same as
everywhere else in this library. A different specific library is free to
order this differently (e.g. apply `standardLabels` after its whole
chain, so nothing can override it) — crdkit has no opinion either way.

crdkit no longer checks that `apiVersion`/`kind` (or anything else) got
set — a specific library forgetting to wire its preamble in just means
those fields are absent from the output; crdkit isn't the layer that
decides what makes a CR "valid."

`ctx.model` can contain `"@TOKEN@"` markers anywhere, exactly like any
consumer value — `crdkit.render` substitutes the WHOLE model in one pass
after the chain finishes (see "Substitution" below), so a preamble can
write `"@API_GROUP@/v1"` instead of a resolved literal and let a locked
token drive it — see `my-crd`'s `mycrd.integration.preamble` for the
real version of the example above.

**Every integration define must be side-effect only — no literal text
of its own.** `crdkit.ensureDictKey`/`dictMerge`/`listExtend`/`addToken`
are all built to return an empty string unconditionally, which is what
makes a bare `{{- include ... -}}` (no captured return) safe inside an
integration. Don't have an integration print YAML directly instead of
setting a model field — `crdkit.render`'s own tail end is the ONE place
actual output happens, after the whole chain has finished mutating
`$model`. See crdkit's CLAUDE.md for the bug this exact mistake caused
once already.

## Substitution: one pass over the whole model

`crdkit.render` runs exactly one `toYaml`/`substituteTokens`/`fromYaml`
round-trip, over `ctx.model` as a whole, after the chain has finished:

```gotemplate
{{- $substitutedText := include "crdkit.substituteTokens" (list $ctx ($model | toYaml) $target) -}}
{{- $substitutedModel := $substitutedText | fromYaml -}}
```

Since crdkit.render no longer reads `context.Values` itself, there's
nothing else to substitute separately — whatever a specific library
wanted from consumer `Values` was already folded into `ctx.model` by its
own preamble (see "Building ctx.model" above) before this point, so one
pass over `model` alone covers everything. The "possible typo"
unresolved-marker check runs over this same substituted text.

## Resolution model

Token resolution is **lazy, per-target, and memoized** — there's no
"resolve everything up front" step, and no eager exception for anything
anymore (an earlier version force-resolved `targetContainer`-bearing
tokens regardless of textual reference; removed — see crdkit's CLAUDE.md
for why). A token only gets resolved (and only gets diagnosed if
malformed) the first time something actually needs its value: a
`@NAME@` marker referencing it. A token that's declared but never used
produces no diagnostic at all, even if it's malformed — an accepted
trade for the thing this design exists to enable: resolving the SAME
token for a target *other than* the one driving the current render
(e.g. computing what a value would be under `qap1` while rendering
`qa`) is a first-class, cheap operation, not a second full re-render.
Results are cached onto the token's own declaration as they're
computed, so repeat lookups (same or different target) are fast.

## Resolving/substituting tokens directly

Most of the time you don't call these yourself — `crdkit.render` (or,
inside an integration, a `@NAME@` marker left in `ctx.model`) drives
resolution for you. When you DO need to reach in directly (an
integration that needs a token's actual value to make a decision, or
code resolving a token for a target other than the one driving the
current render), two entry points take a **list**, not a dict — the one
other deliberate exception to crdkit's usual "always a dict with named
keys" rule, alongside `dictMerge`/`listExtend`:

```gotemplate
{{/* resolve one token by name, for a given target */}}
{{- $resolved := include "crdkit.resolveValue" (list $ctx "DB_HOST" $target) | fromYaml -}}
{{/* $resolved is {value: "...", targetContainer: "..."} */}}

{{/* substitute every "@NAME@" marker in a text blob, for a given target */}}
{{- $substituted := include "crdkit.substituteTokens" (list $ctx "@DB_HOST@ is up" $target) -}}
```

Both take `ctx` first (pulling `tokens`/`diag`/`parentTargetTemplate` from it)
and `target` last. Nothing defaults from `ctx.target` implicitly —
every call names the target it wants, which is what makes resolving
for a target *other than* the current render's (see "Resolution model"
above) exactly as easy as the common case, not a special path.
`crdkit.addToken` follows the same convention: `(list $ctx
"DERIVED_VAR" "computed-value" "main" $target)` — see the "Integration
chain mutation caveats" section above.

## Target escalation

crdkit has no concept of "environment," "family," or "tier" — `target`
is an opaque string. A token can declare a value for the EXACT target
string (a "dedicated attribute" — a literal key in its value-dict), a
`match:` regex rule tested against the exact target, or nothing at all,
in which case crdkit asks the specific library's own `parentTarget`
template what the next broader target is, and tries again there,
repeating until a value is found or the template says there's nothing
further:

```gotemplate
{{/* mycrd.parentTarget — a client library's own taxonomy */}}
{{- define "mycrd.parentTarget" -}}
{{- $target := .target -}}
{{- $chain := dict "qa-01" "qa" "qa" "QA" "QA" "NONPROD" "prod-01" "prod" "prod" "PROD" -}}
{{- if hasKey $chain $target -}}
  {{- index $chain $target -}}
{{- end -}}
{{- end -}}
```

```yaml
# mycrd.render passes this to crdkit.render:
parentTargetTemplate: "mycrd.parentTarget"
```

Then `tokens.REGION: {NONPROD: "us-east-1"}`, rendered with
`target: qa-01`, resolves by walking `qa-01 → qa → QA → NONPROD` — three
hops, none of which crdkit knows the meaning of, all of which get
cached so a later `prod-01`-family lookup sharing a rung is instant.
Every rung is a *plain literal key* — regex only ever applies to the
EXACT original target, once, before any escalation starts (see
crdkit's CLAUDE.md for the full resolution order and why that ordering
matters for correctness).

**GOTCHA when writing your own `parentTarget` template**: a bare
`{{- index $map $target -}}` as the LAST, unassigned thing a `define`
block emits renders as the literal text `<no value>` for a missing key
— not an empty string — once returned through `include`. Always guard
with `hasKey` first (as in the example above); crdkit's own test
harness got bitten by this exact mistake once. See crdkit's CLAUDE.md
for the full story.

## Token model

Every resolved token is `{value, targetContainer}`, not a bare string —
a token's *declaration* can still be a plain scalar or a target-keyed
dict (literal target strings, plus an optional `match:`), which is
shorthand for `{value: <that>}` with `targetContainer` implied `"none"`.
Declare `targetContainer` explicitly when a token should be picked up
by a downstream k8s controller as a container env var:

```yaml
tokens:
  DB_HOST:
    value: "db.internal"       # still goes through the normal dedicated-attribute/match/parentTarget resolution
    targetContainer: main      # one of: main, side-car, both, none (default)
```

crdkit does not create the env var itself, and doesn't currently surface
a resolved `targetContainer` into the rendered output anywhere either —
that wiring doesn't exist yet; a specific library wanting it would build
an integration that reads targetContainer-bearing tokens itself (via
`crdkit.resolveValue`) and writes them into `ctx.model` in whatever
shape its downstream controller expects. An invalid `targetContainer`
records an `# ERROR:` and falls back to `"none"`; the token's `value`
still resolves normally.

Every token name (yours, `system`, and `defaults`) is expected to be
`UPPER_SNAKE_CASE` — a non-conforming name still works, but records a
`# WARNING:`.

## Local testing

```sh
make test   # helm unittest harness -f '../tests/*_test.yaml' — install
            # the plugin first if needed:
            #   helm plugin install https://github.com/helm-unittest/helm-unittest
```

`harness/` + `tests/` exercise crdkit's own helpers directly (token
resolution, `dictMerge`/`listExtend`/`ensureDictKey`), independent of
any specific library's token content or CRD shape. See `CLAUDE.md`'s
"Testing" section for the calling convention and three sharp edges hit
while building it.

crdkit is also exercised end-to-end through `../my-crd/harness`, which
depends on `my-crd`, which depends on this chart — see
`../my-crd/README.md`.
