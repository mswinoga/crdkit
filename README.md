# crdkit

A generic Helm **library chart** providing the reusable machinery behind
env-aware, token-substituted Custom Resource rendering: token resolution
(scalar/dict-per-env, recursive `@ref@` substitution), a diagnostics
accumulator (never `fail()`s — collects `# ERROR:`/`# WARNING:` comments
instead), and a middleware-style "integration chain" dispatcher.

crdkit has **no knowledge of any specific CRD**. It doesn't know an
`apiVersion`, a `kind`, what tokens are locked/defaulted, or what
integrations exist — all of that is supplied by a specific library chart
(e.g. `my-crd`) that depends on crdkit and wraps `crdkit.render` with its
own thin entry point.

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
list. In short: `system`/`defaults` token dicts, `apiVersion`/`kind`, and
`chain` — an ordered list of **fully-qualified** template names
(`"mycrd.integration.foo"`) implementing the integration-filter
interface described in `templates/_chain.tpl`.

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
  token added mid-chain via `crdkit.addToken` is stored as a `match:`
  rule keyed by the exact `target` it was given — the same shape a
  consumer could have hand-declared — so the first time something
  actually references it (a `@NAME@` marker, or a declared
  `targetContainer`), it goes through the normal on-demand resolution
  path, `@ref@` chaining included. It does NOT need to be pre-resolved
  before inserting it — deliberately: an integration's value may
  reference a token another integration only adds LATER in the chain,
  and resolving eagerly at the `addToken` call site would wrongly fail
  on that. Calling `addToken` again for the same name adds another
  `match:` entry rather than replacing the token outright — see
  crdkit's CLAUDE.md for the exact merge rules (per-target entries,
  `targetContainer` inheritance across calls).
- **Locked tokens are re-asserted after the chain**, unconditionally, so
  `system` tokens can't be silently overridden by chain code either —
  same guarantee as against user-supplied tokens, just enforced a second
  time at the end of `crdkit.render`.

## Resolution model

Token resolution is **lazy, per-target, and memoized** — there's no
"resolve everything up front" step. A token only gets resolved (and
only gets diagnosed if malformed) the first time something actually
needs its value: a `@NAME@` marker referencing it, or it declaring a
`targetContainer` (see `crdkit.resolveTargetContainerTokens`, the one
deliberate exception — a `targetContainer`-bearing token needs to be
valid for a downstream controller regardless of whether anything else
textually references it). A token that's declared but never used
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

Both take `ctx` first (pulling `tokens`/`diag` from it) and `target`
last — never `env`: env is always derived from `target` internally
(`crdkit.deriveTargetEnv`), so it's never asked for twice. Nothing
defaults from `ctx.target` implicitly — every call names the target it
wants, which is what makes resolving for a target *other than* the
current render's (see "Resolution model" above) exactly as easy as the
common case, not a special path. `crdkit.addToken` follows the same
convention: `(list $ctx "DERIVED_VAR" "computed-value" "main" $target)`
— see the "Integration chain mutation caveats" section above.

## Token model

Every resolved token is `{value, targetContainer}`, not a bare string —
a token's *declaration* can still be a plain scalar or the familiar
env-varying dict (`default`/`<env>`/`match`), which is shorthand for
`{value: <that>}` with `targetContainer` implied `"none"`. Declare
`targetContainer` explicitly when a token should be picked up by a
downstream k8s controller as a container env var:

```yaml
tokens:
  DB_HOST:
    value: "db.internal"       # still goes through the normal env/tier/match/default resolution
    targetContainer: main      # one of: main, side-car, both, none (default)
```

crdkit does not create the env var itself — it only resolves the value
and carries `targetContainer` through to the rendered output for a
controller to read. An invalid `targetContainer` records an `# ERROR:`
and falls back to `"none"`; the token's `value` still resolves normally.

Every token name (yours, `system`, `defaults`, and crdkit's own
`crdkit.builtinTokens`) is expected to be `UPPER_SNAKE_CASE` — a
non-conforming name still works, but records a `# WARNING:`.

## Local testing

```sh
make test   # helm unittest harness -f '../tests/*_test.yaml' — install
            # the plugin first if needed:
            #   helm plugin install https://github.com/helm-unittest/helm-unittest
```

`harness/` + `tests/` exercise crdkit's own helpers directly (token
resolution, `dictMerge`/`listExtend`/`ensureDictKey`), independent of
any specific library's token content or CRD shape. See `CLAUDE.md`'s
"Testing" section for the calling convention and two sharp edges hit
while building it.

crdkit is also exercised end-to-end through `my-crd-test`, which
depends on `my-crd`, which depends on this chart — see
`my-crd-test/README.md`.
