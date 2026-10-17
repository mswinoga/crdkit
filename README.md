# crdkit

Generic Helm **library chart**: target-aware token resolution/
substitution, a diagnostics accumulator (never `fail()`s — emits
`# ERROR:`/`# WARNING:` comments instead), and an integration-chain
dispatcher.

crdkit has no knowledge of any specific CRD, and no concept of
"environment"/"family"/"tier". All of that is supplied by a specific
library chart (e.g. `my-crd`) that depends on crdkit and wraps
`crdkit.render`.

## Who should depend on this

Not app repos directly — crdkit sits underneath a **specific**
CRD-rendering library chart (`my-crd` in this workspace), which app
repos depend on instead. See `my-crd/README.md` for the consumer
contract.

```yaml
# my-crd's Chart.yaml
dependencies:
  - name: crdkit
    version: "0.0.0"
    repository: "file://../crdkit"
```

## What a specific library supplies to `crdkit.render`

Everything product-specific, as an explicit dict param — see
`templates/_render.tpl`'s doc comment for the full list:
- `system`/`defaults` token dicts
- `annotations`: list of annotation names the library attaches to token
  declarations (optional; see "Token model")
- `diag`: optional `{errors, warnings}` seed; crdkit appends to it and
  emits everything (the library can record its own pre-render
  diagnostics there)
- `chain`: ordered list of fully-qualified integration template names
- `parentTargetTemplate`: fully-qualified template name implementing the
  library's own target-escalation taxonomy (optional; defaults to no
  escalation)

Not a param at all: `apiVersion`/`kind`/labels/anything about the CR's
shape. `crdkit.render` never reads `context.Values` — the chain builds
the entire `ctx.model` itself (by convention, a "preamble" integration
first in the list). See "Building ctx.model" below.

## Integration chain

Integrations receive a shared `ctx` (`root`/`diag`/`model`/`tokens`/
`target`/`reservedKeys`/`gen`), mutated in place across the traversal.

- Visibility is order-dependent: a token/model field set partway
  through the chain is only visible to code running after that point
  (onion/middleware ordering).
- A token added mid-chain via `crdkit.token.add` is stored as a
  dedicated attribute (literal key = exact target) and resolved
  lazily, the same as a hand-declared token — not resolved at
  add-time, so it can reference a token another integration adds later
  in the chain.
- `crdkit.token.underlay` registers a GENERATED value instead — lowest
  priority, see "Generated values" below.
- Locked ("system") tokens are protected against a consumer's own
  `tokens:` map: a system declaration REPLACES a consumer declaration of
  the same name wholesale (`crdkit.tokens.merge.internal`) — not against
  the chain, which is trusted, first-party code.

## Building ctx.model

`crdkit.render` starts `ctx.model` as an empty dict and never touches it
again — the chain populates it entirely, via
`crdkit.dictMerge`/`listExtend`/`ensureDictKey`. That includes
`apiVersion`, `kind`, labels, `metadata.name`, `spec` — none of it is
crdkit's concern.

```gotemplate
{{- define "mycrd.integrations.preamble" -}}
{{- include "crdkit.dictMerge" (list .ctx.model (dict "apiVersion" "@API_GROUP@/v1" "kind" "SomeCR")) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" (dict "name" .ctx.root.Release.Name)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" "labels" (dig "metadata" "labels" (dict) .ctx.root.Values)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" "labels" (include "crdkit.standardLabels" (dict "context" .ctx.root) | fromYaml)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "spec" (.ctx.root.Values.spec | default dict)) -}}
{{- include "crdkit.integrations.chain" . -}}
{{- end -}}
```

- `crdkit.dictMerge` with an empty path (`(list model value)`) merges
  directly into the target — see `templates/_model.tpl`.
- Order is the precedence policy: consumer labels first,
  `crdkit.standardLabels` second (wins on collision), then the rest of
  the chain (which can still override anything).
- `crdkit.render` doesn't check that `apiVersion`/`kind` got set — a
  missing preamble just produces an empty-ish CR, not an error.
- `ctx.model` values can contain `"@TOKEN@"` markers — substituted in
  the same pass as everything else (see "Substitution" below).
- Every integration must be side-effect only — `dictMerge`/`listExtend`/
  `ensureDictKey`/`token.add` all return `""`, so a bare, uncaptured
  `{{- include ... -}}` is safe. Don't print literal YAML from inside
  an integration.

## Substitution

One `toYaml`/`tokens.substitute`/`fromYaml` round-trip, over `ctx.model`
as a whole, after the chain finishes:

```gotemplate
{{- $substitutedText := include "crdkit.tokens.substitute" (list $ctx ($model | toYaml) $target) -}}
{{- $substitutedModel := $substitutedText | fromYaml -}}
```

crdkit never reads `context.Values`, so there's nothing else to
substitute — whatever a library wanted from consumer `Values` is
already in `ctx.model` by the time this runs. The "possible typo"
unresolved-marker check runs over the same text.

## Resolution model

Lazy, per-target, memoized. A token resolves (and is diagnosed, if
malformed) only the first time something needs it — a `@NAME@` marker.
Declared-but-unused tokens produce no diagnostic. Results cache onto
the token's own declaration (`_value`, keyed by target), so resolving
the same token for a *different* target (e.g. `qap1` while rendering
`qa`) is cheap.

The cache is generation-stamped: `ctx.gen` is bumped by every
`crdkit.token.add` / `crdkit.token.underlay`, and a declaration's `_gen`
records the generation its `_value` belongs to. A mismatch discards the
cache before use, so a token resolved before a mutation is re-resolved
afterwards — also for `crdkit.tokenDef.*` structures.

A resolved value isn't limited to a scalar: it can be a dict/list too,
with every string leaf recursively `@ref@`-substituted (non-string
scalars pass through as their native type). `crdkit.token.*` resolves a
real, named token; `crdkit.tokenDef.*` resolves an arbitrary structure
(e.g. sourced from consumer `Values`) by the same rules without
registering it in `ctx.tokens`; `crdkit.tokens.*` operates on the whole
registry:

```
crdkit.tokens.substitute
  └─ crdkit.token.value
       └─ crdkit.resolveEntry.internal        (shared by token.* and tokenDef.*)
            └─ crdkit.substituteStructure.internal
                 └─ crdkit.substituteText.internal → crdkit.resolveEntry.internal (per "@ref@")
  └─ crdkit.stringify.internal                 (coerce for splicing into text)
```

## Resolving/substituting tokens directly

```gotemplate
{{/* resolve one REAL token by name, for a given target */}}
{{- $resolved := include "crdkit.token.value" (list $ctx "DB_HOST" $target) | fromYaml -}}
{{/* $resolved is {value: "..."} — a string, or a dict/list if the
     token's entry for this target is itself structural */}}

{{/* same thing, but always as a string (errors + "" if structural) */}}
{{- $asString := include "crdkit.token.string" (list $ctx "DB_HOST" $target) -}}

{{/* resolve an arbitrary structure sourced from consumer Values —
     not registered under a name in ctx.tokens — using the exact
     same escalation rules as a real token */}}
{{- $def := dict "default" "generic" "prod" "special-@DB_HOST@" -}}
{{- $resolved := include "crdkit.tokenDef.value" (list $ctx "myField" $def $target) | fromYaml -}}
{{/* any "@ref@" inside $def is still looked up in the REAL ctx.tokens,
     never in $def itself */}}

{{/* substitute every "@NAME@" marker in a text blob, for a given target */}}
{{- $substituted := include "crdkit.tokens.substitute" (list $ctx "@DB_HOST@ is up" $target) -}}
```

All entry points take `ctx` first, `target` last and OPTIONAL — omit it
(or pass `""`) to resolve for the current render's own `ctx.target`;
pass it explicitly only to resolve for a target other than the one
driving the render. `crdkit.token.add` and `crdkit.token.underlay`
follow the same convention, with an optional annotations dict before
`target`: `(list $ctx "DERIVED_VAR" "computed-value" (dict "owner" "svc") $target)`.

## Target escalation

`target` is an opaque string. A token resolves via, in order: a
dedicated attribute (literal key = exact target), a `match:` regex rule
(tested once, against the exact target), or by walking the library's
own `parentTargetTemplate` — repeating until a value is found or the
template returns nothing. After the walk, `default` is the fallback;
after that, a generated value for the exact target (`_generated`, see
"Generated values"); after that, the "no value found" diagnostic.

```gotemplate
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

`tokens.REGION: {NONPROD: "us-east-1"}`, rendered with `target: qa-01`,
resolves by walking `qa-01 → qa → QA → NONPROD` — every rung visited
gets cached, so a later `prod-01`-family lookup sharing a rung is
instant. Every rung is a plain literal key; `match:` only ever applies
to the exact original target, before any escalation.

**GOTCHA**: a bare `{{- index $map $target -}}` as the last, unassigned
thing a `define` emits renders as the literal text `<no value>` for a
missing key — not an empty string. Always guard with `hasKey` first (as
above).

## Token model

- A token DECLARATION is a plain scalar (same value for every target) or
  a dict. Reserved dict keys (never target entries):
  - crdkit-internal: `_value` (memoization cache), `_gen` (cache
    generation), `_generated` (generated values)
  - `match` (ordered regex rules)
  - every annotation name passed to `crdkit.render`
  Every other key, including `default`, IS a target entry.
- Resolving a token (`crdkit.token.value`) returns a separate shape,
  `{value}` — the interpolated result for one name+target pair (a
  string, or a structure if the selected entry is itself one).

```yaml
tokens:
  DB_HOST:
    owner: payments            # an annotation (library passed annotations: [owner])
    default: "db.internal"     # goes through the normal dedicated-attribute/match/parentTarget resolution
```

- `default` is also a hardcoded, last-resort fallback — checked
  directly regardless of taxonomy, even under `crdkit.noParentTarget`.
  A token with no `default` key that can't resolve for a target
  produces the ordinary "no value found" diagnostic, lazily.
- Annotations are static metadata: crdkit stores them, never resolves
  or validates them, and never knows their names. A library reads them
  directly off the declaration (`ctx.tokens.DB_HOST.owner`) and owns
  any policy (validation, locking). An annotation name equal to a
  crdkit-internal key, `match` or `default` records an `# ERROR:` and
  is ignored. A target equal to an annotation name is not a target
  entry.
- A resolved value reaches `ctx.model` for free — an integration can
  write e.g. `variables: {DB_HOST: "@DB_HOST@"}`, and it resolves in
  crdkit.render's single substitution pass, same as any other model
  field.
- Internal keys written in a consumer, defaults or system declaration
  are removed at merge time with a `# WARNING:`.
- Token names are expected to be `UPPER_SNAKE_CASE` — non-conforming
  names still work, but record a `# WARNING:`.

### Adding tokens from an integration

`(list $ctx name value annotations? target?)`, both `crdkit.token.add`
and `crdkit.token.underlay`:

- `crdkit.token.add` stores `value` as the entry for the exact target
  and MERGES `annotations` over the declaration's existing ones (an
  omitted key is inherited). Non-dict annotations record an `# ERROR:`;
  the value is still stored.
- `crdkit.token.underlay` stores `value` as a generated value (below)
  and sets each annotation only when the declaration doesn't have it.
  Creates the token if missing.

### Generated values

`crdkit.token.underlay` registers values in `_generated[<target>]`,
the lowest-priority source: consulted only after the exact target,
`match`, the parent walk and `default` all found nothing, so a consumer
declaration always wins, including with its own `default`. A generated
value applies to its exact target only and is cached under that target
alone (parent-walk rungs are shared across targets). A second underlay
for the same target overwrites the first.

```gotemplate
{{- include "crdkit.token.underlay" (list .ctx "DB_URL" "jdbc:@DB_HOST@" (dict "owner" "payments")) -}}
```

## Local testing

```sh
make test   # helm unittest harness -f '../tests/*_test.yaml'
            # install the plugin first if needed:
            #   helm plugin install https://github.com/helm-unittest/helm-unittest
```

`harness/` + `tests/` exercise crdkit's own helpers directly,
independent of any specific library's token content or CRD shape — see
`CLAUDE.md`'s "Testing" section for sharp edges.

crdkit is also exercised end-to-end through `../my-crd/harness` — see
`../my-crd/README.md`.
