# CLAUDE.md — crdkit

## Purpose

Generic engine underneath one or more specific CR-rendering library
charts (e.g. `../my-crd`). Owns token resolution, diagnostics, standard
labels, and the integration-chain dispatcher. Deliberately has **zero**
knowledge of any specific CRD, apiGroup, kind, or token content — see
`README.md` for the mechanism itself; this file is about decisions and
assumptions that aren't visible just by reading the templates.

## Decisions worth knowing before changing this repo

- **Why a separate chart at all**: extracted from what was originally a
  single `crd` library so the resolution/diagnostics/chaining machinery
  can be reused by multiple, independently-versioned specific CRD
  libraries instead of being copy-pasted per CRD. That split — and the
  reasoning behind every decision below — came out of a design
  conversation that isn't reproduced anywhere in code comments.
- **Name is deliberately not "common".** Helm merges `define` names from
  a chart and *all* its transitive dependencies into one flat, global
  template namespace at render time — a same-named library pulled in
  from two different sources (e.g. Bitnami's `common` chart, if some
  consumer happens to depend on both) is a real collision risk, not
  just a style nit.
- **Never hardcode another chart's template name.** This is the one
  rule that keeps crdkit reusable. `crdkit.render` and everything it
  calls only ever `include`s `crdkit.*` defines; every product-specific
  input (system/default tokens, apiVersion/kind, the integration chain)
  arrives as an explicit dict param from the caller's own thin wrapper
  (see `my-crd`'s `mycrd.render`). If new code here wants to `include`
  a non-`crdkit.*` name, that logic belongs in the specific library
  instead.
- **Helper signatures always take a `dict` with named keys**, never
  positional `list` args — a deliberate readability/order-independence
  choice. Keep new helpers consistent with it.
- **Diagnostics, never `fail()`.** Every helper that can fail takes a
  `diag` dict (`errors`/`warnings` lists) built once by the top-level
  caller and threaded through by reference. crdkit is consumed
  transitively by potentially many specific libraries, each consumed by
  many app repos — one author's mistake anywhere must never hard-abort
  a render.
- **The env family-tier map in `crdkit.resolveTokenValue` is an
  org-specific assumption**, not a generic algorithm: `dev/test/qa/
  qam1/qap1/prod` → `DEV/TEST/QA/PROD`, and `DEV/TEST/QA` → `NONPROD`.
  It encodes one org's environment-naming convention. If crdkit is ever
  reused somewhere with a different taxonomy, this needs to become a
  parameter, not stay hardcoded.
- **Token substitution timing is deliberately two-phase and easy to get
  backwards.** Tokens resolve to a flat map FIRST, in isolation
  (recursive `@ref@` fixed-point against the tokens map alone,
  independent of the rest of the values tree). But the pass that
  substitutes `@name@` markers INTO the rest of the structure runs
  LAST, after the integration chain completes — not before. If
  substitution ran before the chain, integration-authored `@token@`
  references (e.g. a filter appending `"@databaseHost@"` into
  `ctx.model`) would never get resolved.
- **`ctx` (root/diag/model/tokens) and `chain` are kept as separate
  arguments on purpose** — resist merging them into one dict. `ctx`'s
  contents are a shared, mutate-in-place accumulator for the whole
  traversal (same discipline as `$diag` elsewhere). `chain` is the
  opposite: an ordinary value that must never be mutated in place, only
  narrowed via `rest` per call. Folding `chain` into `ctx` would mix
  those two disciplines inside one object — exactly the kind of thing a
  future contributor gets wrong by pattern-matching against the
  neighboring keys.
- **`ctx.model` has NO pre-declared shape anywhere — not in crdkit, not
  in any specific library.** `crdkit.render` initializes it as a bare
  `dict` and never adds fields to it itself. Every field, including
  "labels" (the one field crdkit itself reads, at the very end), is
  created lazily on first touch via `crdkit.ensureDictKey` — a generic,
  reusable "set this key to a default if absent" helper. This is
  deliberate: a central pre-declared shape (whether owned by crdkit or
  by a specific library) would require every integration to know about
  every OTHER integration's fields just to avoid clobbering a shared
  init list — the decentralized version means each integration is
  fully self-sufficient about its own corner of `model`.
  Consequence: **every** integration must ensure a `ctx.model` field
  exists before touching it for the first time, EVERY time, even for a
  field it's confident an earlier integration in the chain already
  created — chain order isn't something to depend on for this. Sprig's
  `set` has no `dig`-style "auto-vivify missing intermediate maps"
  equivalent: `set $model.labels "k" "v"` hard-crashes the whole render
  (no diagnostic) if `labels` is absent/nil (`wrong type for value;
  expected map[string]interface {}; got interface {}`), or even earlier
  if `model` itself is absent/nil (`nil pointer evaluating interface
  {}.labels`) — verified directly, not assumed. What makes
  `crdkit.ensureDictKey` work as a *reusable* helper despite Go
  templates only being able to return rendered text: it doesn't need to
  return anything — it's called with the live `model` map as an
  argument and mutates it via `set` from inside the `include`, which
  stays visible to the caller afterward because maps are reference
  types even when passed inside a wrapping `dict` literal (also
  verified empirically, not assumed — this is the one trick that makes
  "no central shape" viable at all instead of forcing pre-declaration).
- **Prefer `crdkit.dictMerge`/`crdkit.listExtend` over calling
  `crdkit.ensureDictKey` directly** for the two shapes that cover almost
  every real case: "this field (possibly nested several levels deep) is
  a map, add entries to it" and "...is a list, add items to it." Both
  walk an arbitrary-depth path from a root, creating each missing level
  as an empty dict along the way, then operate on the dict/list at the
  end of it. There's no scalar-key `dictSet` alongside `dictMerge` on
  purpose — `dictMerge (list model "labels" (dict "key" "value"))`
  covers that case for the cost of one `dict` wrapper, and two
  overlapping helpers where one is always expressible via the other
  isn't worth maintaining.
- **`crdkit.dictMerge`/`crdkit.listExtend` take a LIST, not a dict —
  the one deliberate exception to crdkit's "always dict with named
  keys" rule.** Shape: `[model, key1, ..., keyN, value]` (at least one
  key). This mirrors Sprig's own `dig`, which is similarly variadic-path
  and positional rather than named — a variable-length path doesn't fit
  the "named dict key" convention any more cleanly than `dig`'s own
  signature would, and smuggling a list-of-keys into one named dict
  value would be worse on both counts. Note the arg order is the
  *reverse* of `dig`'s: `dig` ends with the dict being read (`key1
  ... keyN default $dict` — you're reading, so the source is last);
  these start with the dict being written to (`model key1 ... keyN
  value` — you're anchored at a root and writing, so the root is
  first). Only the FINAL path segment gets the dict-merge/list-append
  treatment; every segment before it is walked as an ordinary
  `crdkit.ensureDictKey` + descend, exactly like a single-level call
  would do at the top. Requires at least one path key — too short a
  list is a template-authoring bug (an integration author's mistake,
  not consumer input), so it's an ordinary template error, not a
  diagnostic; see the "Diagnostics, never fail()" entry above for where
  that line is drawn — it protects against END-CONSUMER mistakes, not
  against a library's own developers miscalling an internal helper.
  The mechanical asymmetry between the two is still real at the final
  step: `dictMerge` mutates the nested map in place via `index`
  (verified: `mergeOverwrite (index $current $key) $value` persists
  without a `set`, same as plain `set` does on a map). `listExtend`
  can't do that — Sprig's `concat` (like `append`) always returns a NEW
  slice rather than mutating in place, so its final step needs an
  explicit `set` back onto the second-to-last level; this is
  transparent to callers, but matters if you're ever tempted to write a
  third helper by hand instead of reusing these.
- **Chain order = wrapping order.** The first name in `chain` is
  outermost — its post-phase (the code after the recursive `include`
  call inside an integration define) runs LAST, after everything below
  it has run. Same ordering as a typical middleware/onion stack; not
  obvious without reading `crdkit.integrations.chain`'s doc comment.
- **Locked ("system") AND computed (`crdkit.builtinTokens`, e.g.
  "ENV") tokens are re-asserted twice, deliberately**: once during the
  initial merge (`crdkit.resolveAllTokens`), and again, unconditionally,
  in `crdkit.render` right after the integration chain finishes —
  specifically so a chain filter can't silently defeat the "these
  always win" guarantee by mutating `ctx.tokens`. Don't remove the
  second reassertion as "redundant" — it covers a different
  mistake/abuse surface than the first one (user-supplied tokens vs.
  chain-code mutation).
- **`crdkit.builtinTokens` keys are the reserved/built-in token name
  list — don't hardcode that list anywhere else.**
  `crdkit.resolveAllTokens` computes it as `append (keys $builtinTokens)
  "AT"`. Adding a new computed token (e.g. `ENV_UPPER: {{ .env |
  upper }}`) is enough on its own to make it both consumer-protected and
  chainable from other tokens — no second file to touch. Named
  `builtinTokens`, not `internalTokens` — "internal" wrongly implied
  hidden/inaccessible, when these are actually fully consumer-facing
  (`@ENV@` works anywhere); "builtin" matches the wording the
  diagnostic messages already used ("reserved built-in").
- **`builtinTokens` is folded into the merge BEFORE
  `crdkit.resolveTokensRecursive` runs, not bolted on after.** This
  matters: it's what lets an ordinary token safely reference `@ENV@` (or
  any future built-in token) through the same iterative `@ref@`
  resolution as everything else, deterministically. An earlier version
  spliced `env` into the resolved map only after recursion finished —
  that made cross-references to it depend on Go's *randomized* map
  iteration order in the final substitution pass (worked by luck, not
  design). Don't reintroduce a post-hoc splice for a new built-in token;
  put it in `crdkit.builtinTokens` and let the normal merge order carry
  it.
- **Any scalar produced by a YAML-emitting `define` block here must be
  `| quote`d, even (especially) when it might be empty.** `env: {{ .env
  }}` with an empty `.env` renders as `env:` with nothing after the
  colon — valid YAML, but that parses as `null`, not `""`. A `nil`
  flowing into `crdkit.substituteTokens`'s `replace` call is a hard
  template error (`wrong type for value; expected string; got
  interface {}`), not a graceful diagnostic — this bit
  `crdkit.builtinTokens` in exactly this way when `env` was empty
  (malformed `target`) before `| quote` was added. `crdkit.matchRules`
  already did this correctly (`value: {{ $result | quote }}`); match
  that pattern in any new helper that emits a possibly-empty scalar.
- **`crdkit.render` only wires `model.labels` into the output today.**
  Whatever OTHER fields a specific library's integrations populate on
  `model` are accumulated but not merged into `spec` anywhere —
  deliberately deferred (see the `TODO` in `templates/_render.tpl`)
  until a specific library's real CRD spec shape is known, at which
  point that library (not crdkit) decides how its own fields map in.
  Don't treat those fields as dead code; they're waiting on a decision
  nobody has made yet, not on an implementation gap.
- **Every RESOLVED token is a struct `{value, targetContainer}`, never
  a bare string.** This is a real, deliberate generalization of the
  data model, not just a naming change: `crdkit.resolveTokenValue`
  still resolves just the "value" half (scalar-or-env-dict, unchanged
  logic); `crdkit.resolveToken` wraps that into the full struct a token
  actually resolves to. A token's DECLARATION can still be a bare
  scalar or the env-dict shape — that's shorthand for `{value: <that>}`
  with `targetContainer` implied `"none"`, so every token declared
  before `targetContainer` existed still resolves exactly as before,
  just wrapped on the way out. The disambiguation between "bare env-dict
  declaration" and "wrapper dict with value/targetContainer" is
  `hasKey $raw "value"` — safe because no env-dict special key (env
  names, family/super-tiers, "default", "match") is ever named "value".
  Consequence for anything touching resolved tokens: `crdkit.substituteTokens`
  extracts `.value` per entry when replacing `@NAME@` markers —
  `targetContainer` never appears in rendered text, it's metadata for a
  downstream k8s controller to read, not something crdkit substitutes
  or interprets itself (crdkit doesn't create env vars; it only carries
  the field through — see the `TODO` above about the still-unresolved
  "how does anything besides labels reach the output" question, which
  this reopens for token-level output, not just model-level).
- **Two author-mistake shapes are guarded against explicitly in
  `crdkit.resolveToken`, both found by deliberately thinking through
  edge cases rather than waiting for a bug report**: (1) `{targetContainer:
  "main"}` with no `value` key looks like a bare env-dict to the
  `hasKey $raw "value"` check (no "value" key present), so without a
  guard it silently falls into `crdkit.resolveTokenValue`, which tries
  to look up `"targetContainer"` as if it were an env/tier NAME —
  producing a confusing "no value for env" error that never mentions
  the real mistake. Caught explicitly now, with a clear ERROR naming
  it. (2) `{value: "x", prod: "y"}` — once the wrapper shape is
  detected, everything except `value`/`targetContainer` is silently
  ignored by design (no partial "env-dict AND wrapper" hybrid is
  supported), which is easy to not notice; now records a WARNING
  listing exactly which keys were ignored. Both are tested in
  `tests/tokens_test.yaml`'s "edge cases" section.
- **Known, accepted gap: the reserved-name collision check is
  case-sensitive, so a differently-cased near-miss of a locked name
  bypasses it entirely** — `tokens.apiGroup` does NOT collide with a
  locked `API_GROUP` (different dict keys), so it resolves as its own
  independent token with the user's value, not discarded. The only
  diagnostic that fires is the ordinary casing WARNING, not a
  collision one. This is a real, narrow consequence of the naming
  convention being WARNING-only rather than enforced — see the
  "GOTCHA" test in `tests/tokens_test.yaml` for a working
  demonstration. Not treated as a bug to fix (that would mean either
  making collision detection case-insensitive, which has its own
  surprise potential, or making the naming convention a hard
  requirement, which contradicts the "never fail()" rule) — just
  something to know about.
- **`targetContainer` is validated against a fixed 4-value enum —
  `main`/`side-car`/`both`/`none`** (crdkit.resolveToken and
  crdkit.addToken both enforce this identically). An invalid value
  records an ERROR (not a `fail()`) and falls back to `"none"`, so a
  downstream consumer of the rendered output never sees a garbage
  value — but the token's `value` still resolves normally regardless;
  only `targetContainer` is affected by the fallback.
- **Token names must be `UPPER_SNAKE_CASE` (`^[A-Z][A-Z0-9_]*$`),
  enforced as a WARNING, checked on EVERY token** — user-supplied,
  `system`, `defaults`, and `crdkit.builtinTokens` alike, in
  `crdkit.resolveAllTokens` (checked once, after the full merge, on
  every final key) and in `crdkit.addToken` (checked again for tokens
  contributed mid-chain, since those never pass through
  `resolveAllTokens`). This can only ever be a WARNING, never an ERROR
  or a hard rejection — a non-conforming token still resolves and
  renders exactly as it would otherwise, per this library's "never
  `fail()`" rule (see above); it's a readability convention with a
  diagnostic nudge, not a hard requirement enforced at the type level.
  `crdkit.builtinTokens`' own `ENV` (not `env`) exists specifically so
  the library doesn't trip its own warning on every single render.
- **`crdkit.addToken` is the mid-chain counterpart to `crdkit.dictMerge`/
  `listExtend`, but for `ctx.tokens` instead of `ctx.model`.** An
  integration contributing a derived token (e.g. computed from
  something in `ctx.model`) should call this rather than hand-rolling
  `set $ctx.tokens NAME (dict "value" ... "targetContainer" ...)` —
  it applies the same casing-WARNING and targetContainer-enum
  validation every other token gets. It deliberately does NOT run the
  reserved-name collision check `crdkit.resolveAllTokens` does — that
  check exists to protect against untrusted CONSUMER input at the
  initial merge; an integration calling `addToken` is trusted
  library-author code, a different trust boundary entirely.

## Testing

`harness/` + `tests/` (`make test`) exercise crdkit's own helpers
DIRECTLY — no `mycrd.render`-style wrapper, no apiVersion/kind, no
coupling to any specific library's token content. `harness/templates/
test.yaml` calls `crdkit.builtinTokens`/`resolveAllTokens`/
`substituteTokens`, `dictMerge`/`listExtend`/`ensureDictKey`, and
`addToken` directly against `.Values`, so a test case only needs to set
`target`/`tokens`/`system`/`defaults`/`structure` (token side),
`modelOps` (model side), or `tokenOps` (mid-chain token contribution,
driving `crdkit.addToken`) and assert on the rendered `tokens`/
`structure`/`model`/`diag`/`env` output. Added once `dictMerge`/
`listExtend` landed with zero committed coverage anywhere (their
multi-level behavior had only ever been checked in a throwaway scratch
chart) — this is the threshold the chart's own prior note about "no
test suite of its own" anticipated crossing.

Two sharp edges hit while building this, worth knowing before adding
more tests:

- **The harness chart's `name:` in `Chart.yaml` MUST match its
  directory name (`harness`).** It was initially named `crdkit-harness`
  (directory `harness`) and every `helm unittest` run produced a
  spurious second failure per test — "template
  harness/charts/crdkit/templates/X.yaml not exists" — helm-unittest
  appears to also probe the dependency subchart for a same-named
  template when the parent chart's declared name doesn't match its
  directory. Fixing the name to match the directory (same convention
  `my-crd`/`my-crd-test` already followed) made the phantom failures
  disappear entirely. If a future rename ever reintroduces this
  mismatch, expect this exact symptom back.
- **`set:`'s dotted-path parser doesn't reliably handle array-bracket
  indices** (`modelOps[0].op: ensureDictKey`, `tokens.foo.match[0].
  pattern: value`) — even though the IDENTICAL path string works
  correctly via plain `helm template --set`. Under helm-unittest it
  silently produces an empty/malformed structure (`unknown path
  model.foo`, or `nil pointer evaluating interface {}.op` on the next
  read) rather than an error pointing at the cause. The reliable form:
  set the whole array as ONE nested YAML value under its single
  top-level key — `set: { modelOps: [{op: ensureDictKey, key: foo,
  default: ["first"]}] }` — rather than flattening it into dotted
  paths. Every array-shaped `set:` value in this chart's tests
  (`tests/model_test.yaml` entirely, the `match:` cases in
  `tests/tokens_test.yaml`) uses this form for exactly this reason;
  `my-crd-test`'s existing `target-match.yaml` fixture sidestepped
  the same issue a different way (an external `values:` file) before
  this was understood as a general `set:` limitation rather than
  something specific to regex-metacharacter keys.

## Open / deferred (not implemented here)

- No decision has been made on how `model`'s non-label fields map into
  a real CRD spec — blocked on an actual target CRD shape being known.
