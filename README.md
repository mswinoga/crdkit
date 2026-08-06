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
`target`), mutated in place across the traversal.

- Visibility is order-dependent: a token/model field set partway
  through the chain is only visible to code running after that point
  (onion/middleware ordering).
- A token added mid-chain via `crdkit.addToken` is stored as a
  dedicated attribute (literal key = exact target) and resolved
  lazily, the same as a hand-declared token — not resolved at
  add-time, so it can reference a token another integration adds later
  in the chain.
- Locked tokens are protected against a consumer's own `tokens:` map
  (merged last in `crdkit.mergeTokens.internal`) — not against the
  chain, which is trusted, first-party code.

## Building ctx.model

`crdkit.render` starts `ctx.model` as an empty dict and never touches it
again — the chain populates it entirely, via
`crdkit.dictMerge`/`listExtend`/`ensureDictKey`. That includes
`apiVersion`, `kind`, labels, `metadata.name`, `spec` — none of it is
crdkit's concern.

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
  `ensureDictKey`/`addToken` all return `""`, so a bare, uncaptured
  `{{- include ... -}}` is safe. Don't print literal YAML from inside
  an integration.

## Substitution

One `toYaml`/`substituteTokens`/`fromYaml` round-trip, over `ctx.model`
as a whole, after the chain finishes:

```gotemplate
{{- $substitutedText := include "crdkit.substituteTokens" (list $ctx ($model | toYaml) $target) -}}
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
the token's own declaration, so resolving the same token for a
*different* target (e.g. `qap1` while rendering `qa`) is cheap.

## Resolving/substituting tokens directly

```gotemplate
{{/* resolve one token by name, for a given target */}}
{{- $resolved := include "crdkit.resolveValue" (list $ctx "DB_HOST" $target) | fromYaml -}}
{{/* $resolved is {value: "...", targetContainer: "..."} */}}

{{/* substitute every "@NAME@" marker in a text blob, for a given target */}}
{{- $substituted := include "crdkit.substituteTokens" (list $ctx "@DB_HOST@ is up" $target) -}}
```

Both take `ctx` first, `target` last — nothing defaults from
`ctx.target`, so resolving for a target other than the current render's
is no different from the common case. `crdkit.addToken` follows the
same convention: `(list $ctx "DERIVED_VAR" "computed-value" "main"
$target)`.

## Target escalation

`target` is an opaque string. A token resolves via, in order: a
dedicated attribute (literal key = exact target), a `match:` regex rule
(tested once, against the exact target), or by walking the library's
own `parentTargetTemplate` — repeating until a value is found or the
template returns nothing.

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
  a dict. Reserved dict keys: `targetContainer`, `_value` (memoization
  cache, internal), `match`. Every other key, including `default`, IS a
  target entry.
- Resolving a token (`crdkit.resolveValue`) returns a separate shape,
  `{value, targetContainer}` — the interpolated result for one
  name+target pair.

```yaml
tokens:
  DB_HOST:
    targetContainer: main      # one of: main, side-car, both, none (default)
    default: "db.internal"     # goes through the normal dedicated-attribute/match/parentTarget resolution
```

- `default` is also a hardcoded, last-resort fallback — checked
  directly regardless of taxonomy, even under `crdkit.noParentTarget`.
  A token with no `default` key that can't resolve for a target
  produces the ordinary "no value found" diagnostic, lazily.
- crdkit doesn't create the env var itself, and doesn't currently
  surface a resolved `targetContainer` into the output — a specific
  library wanting that would build an integration that reads such
  tokens (via `crdkit.resolveValue`) and writes them into `ctx.model`
  itself.
- An invalid `targetContainer` records an `# ERROR:` and falls back to
  `"none"`; the token's value still resolves.
- Token names are expected to be `UPPER_SNAKE_CASE` — non-conforming
  names still work, but record a `# WARNING:`.

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
