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
`tokens`) mutated in place across the whole traversal — same discipline
as the diagnostics accumulator. If a filter mutates `ctx.tokens`, prefer
`crdkit.addToken` (dict "tokens" $ctx.tokens "name" "DERIVED_VAR"
"value" ... "targetContainer" ...) over mutating it by hand — it applies
the same name-casing and targetContainer validation every other token
gets. Regardless of how a token gets added:

- **Visibility is order-dependent.** A token set partway through the
  chain is only visible to code that runs after that point in the
  traversal (per the onion/middleware ordering), not retroactively.
- **No re-run of the recursive resolver.** `@ref@`-within-tokens
  resolution happens once, before the chain starts. A token inserted
  mid-chain must already be fully resolved — it won't get a second
  fixed-point pass.
- **Locked tokens are re-asserted after the chain**, unconditionally, so
  `system` tokens can't be silently overridden by chain code either —
  same guarantee as against user-supplied tokens, just enforced a second
  time at the end of `crdkit.render`.

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
