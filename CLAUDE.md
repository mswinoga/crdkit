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
- **Helper signatures default to a `dict` with named keys**, never
  positional `list` args for anything with a variable number of params
  or where the order isn't obvious — a deliberate readability/order-
  independence choice, still the default for new helpers. There are
  now TWO deliberate, bounded classes of exception, both list-based:
  `crdkit.dictMerge`/`crdkit.listExtend` (variadic-path, mirrors
  Sprig's `dig` — see their own doc comments), and the token-resolution
  entry points a caller reaches for directly rather than through
  `crdkit.render` — `crdkit.resolveValue`, `crdkit.substituteTokens`,
  `crdkit.addToken`, `crdkit.resolveTargetContainerTokens` — which all
  take `ctx` as their first positional element (`[ctx, ...]`), pulling
  `tokens`/`diag` (and `env`, derived from `target` — see below) from
  it rather than as separate named params. This second exception was
  added deliberately, on request, to make the single most common call
  shape in this library (a token author or integration reaching for
  "resolve me this token" or "substitute markers into this text")
  short enough to write inline without a multi-line `dict` literal —
  weighed against the readability/order-independence argument above,
  and judged worth it specifically because these calls are so frequent
  and their argument order (ctx, then the thing being acted on, then
  target) is fixed and easy to remember, unlike a call site with
  several optional or same-typed params where named keys still win.
  Internal-only helpers not meant to be called directly by consumers or
  integration authors (`crdkit.resolveValue.core`,
  `crdkit.resolveChainedValue`, `crdkit.matchRules`,
  `crdkit.deriveTargetEnv`, `crdkit.mergeTokens`) stay dict-based — the
  list exception is specifically for the ergonomic, directly-called
  public surface, not the plumbing underneath it.
- **Diagnostics, never `fail()`.** Every helper that can fail takes a
  `diag` dict (`errors`/`warnings` lists) built once by the top-level
  caller and threaded through by reference. crdkit is consumed
  transitively by potentially many specific libraries, each consumed by
  many app repos — one author's mistake anywhere must never hard-abort
  a render.
- **The env family-tier map in `crdkit.resolveValue.core` is an
  org-specific assumption**, not a generic algorithm: `dev/test/qa/
  qam1/qap1/prod` → `DEV/TEST/QA/PROD`, and `DEV/TEST/QA` → `NONPROD`.
  It encodes one org's environment-naming convention. If crdkit is ever
  reused somewhere with a different taxonomy, this needs to become a
  parameter, not stay hardcoded.
- **`env` is never a parameter anywhere in the public token-resolution
  surface — it's ALWAYS derived from `target`, on demand, by the
  function itself (`crdkit.deriveTargetEnv`).** `crdkit.resolveValue`
  and `crdkit.substituteTokens` each derive their own `env` internally
  from the `target` they were given; nothing above them ever computes
  `env` and hands it in. This was a deliberate simplification (on
  request) over an earlier shape that took both `env` AND `target`
  explicitly — redundant, since `env` is always a pure function of
  `target`, and a real source of accidental mismatches (nothing
  enforced that a caller's `env` and `target` args actually agreed).
  The one place `env` still gets computed once, up front, and handed
  around as a plain variable is `crdkit.render`'s own use of it to seed
  the built-in `ENV` token (`crdkit.builtinTokens` needs a value to put
  under that key) — that's a different concern (defining a token's
  VALUE) from resolving one (which never needs the caller to already
  know env). Internal engine pieces (`crdkit.resolveValue.core`,
  `crdkit.resolveChainedValue`) still take an already-derived `env` as
  an explicit param — deliberately: they run inside recursion
  (chained `@ref@` resolution, once per marker in a substitution pass),
  and re-deriving `env` from `target` on every recursive step would
  re-run `crdkit.deriveTargetEnv`'s diagnostic ("target is required")
  redundantly. `crdkit.substituteTokens` derives `env` exactly ONCE per
  call (not once per marker), and only if the text actually contains at
  least one marker — see the `crdkit.renderDiagnostics` bullet below on
  the remaining, accepted edge case this doesn't fully close.
- **Resolution is LAZY, PER-TARGET, and MEMOIZED — a deliberate
  redesign, not the original shape of this library.** There is no
  "resolve every declared token up front" pass anymore, and no separate
  "resolved tokens" structure: `crdkit.mergeTokens` only merges raw
  declarations (plus runs collision/casing diagnostics) and its output
  IS `ctx.tokens` — a token only actually gets resolved (and only gets
  diagnosed for being malformed) the first time something needs its
  value: a `@NAME@` marker referencing it (`crdkit.substituteTokens`,
  or transitively through another token's chained value), or it
  declaring a `targetContainer` (the one deliberate non-lazy exception,
  see the `crdkit.resolveTargetContainerTokens` bullet below). A
  declared-but-never-used broken token produces NO diagnostic at all —
  an intentional trade, made because eager resolution can't cheaply
  support resolving the same token for a target other than the one
  driving the current render, which is the whole reason for this
  design (see the next bullet). The old "substitution runs after the
  chain, not before" ordering still holds and still matters for the
  same reason (integration-authored `@token@` references need to
  resolve too) — it's just that "resolution" and "substitution" are no
  longer two separate passes at all, only one on-demand one.
- **A token can be resolved for a target OTHER than the one driving the
  current render — this is the whole point of the redesign.**
  `crdkit.resolveValue` takes `[ctx, name, target]` explicitly (not "the
  current render's target implicitly" — there is no such thing; ctx
  carries a `target` field, but nothing defaults to it, every call
  names its own target), so anything needing to know e.g. what a token
  would resolve to under `qap1` while rendering `qa` can just call it
  with that target: `include "crdkit.resolveValue" (list $ctx "NAME"
  "qap1")`. Results are memoized onto the token's OWN raw declaration,
  under a reserved `_value` sub-key, keyed by target (see the
  `resolveValue.core` doc comment in `templates/_tokens.tpl` for the
  exact caching ladder: exact target
  first, always; then, for the non-`match:` case only, every
  env/family-tier/super-tier key walked en route gets cached too, so a
  later target sharing that env/family/tier is an instant hit). The one
  rule that keeps this safe: `match:` is ALWAYS evaluated fresh per
  exact target, never answered from a broader tier-cache hit populated
  by a DIFFERENT target — because `match:` tests the full target
  string and can legitimately distinguish e.g. `qap1-01` from `qap1-02`
  even though both share env `qap1`. Getting this backwards (checking a
  broader cache tier before a target-specific `match:` rule gets a
  chance to fire) was caught and fixed before landing — see
  `tests/tokens_test.yaml`'s "caching / multi-target semantics"
  section, which exists specifically to pin this down.
- **Chained `@ref@` resolution is target-scoped, all the way through,
  including cycle detection.** Resolving token A for target `qap1`
  resolves any token A depends on ALSO for `qap1`, not for whatever
  target is driving the overall render (`crdkit.resolveChainedValue`
  threads `env`/`target` through unchanged). Consequently, a cycle can
  exist under one target and not another if `match:` makes the
  dependency graph itself target-dependent (a token whose `match:` rule
  only chains to another token for one specific target string) — cycle
  detection uses an explicit in-progress-name stack scoped to ONE
  top-level `crdkit.resolveValue` call, never shared across separate
  calls for different targets. Also see the same test section referenced above.
- **A token added mid-chain (`crdkit.addToken`) is not special — it
  goes through the exact same lazy `crdkit.resolveValue` path as anything
  else, `@ref@` chaining included, the first time it's actually
  resolved.** Two designs were tried and rejected before landing here,
  worth knowing so they don't get reinvented: (1) an EARLIER,
  pre-redesign version of this library resolved eagerly, up front,
  before any chain ran — a token inserted mid-chain, after that one
  pass had already happened, never got picked up by it at all. (2) A
  version tried DURING this redesign resolved eagerly at addToken's own
  call site instead (via `crdkit.substituteTokens`, immediately) —
  better, but still broken for a real case: an integration's addToken
  call whose value references a token that a DIFFERENT integration
  only adds LATER in the same chain would resolve against
  `ctx.tokens` as it stood at THAT point, wrongly erroring on a
  reference that would have resolved fine had it stayed lazy ("several
  related tokens set one after another" was the reported scenario).
  The actual mechanism: `addToken` stores "value" as a `match:` rule
  keyed by the EXACT `target` string given — `{value: {match:
  [{"<target>": "<value>"}]}}` — so it resolves through the ordinary
  `match:` tier the first time something references it, by which point
  the FULL chain has run. See `tests/tokens_test.yaml`'s "an
  addToken-added token resolves lazily via its match: rule..." test,
  which exists specifically to keep this from regressing silently.
- **A resolved token's `value`/`targetContainer` never gets written
  back onto `ctx.tokens[NAME]` at the top level — only into the
  `_value` cache.** Reading `tokens.NAME.value` directly (rather than
  going through `crdkit.resolveValue`) gets you the RAW declaration,
  which for an env-varying dict is the whole `{default: ..., prod:
  ...}` shape, not a resolved scalar — this bit test-writing directly
  (assertions against the raw path silently read stale/wrong shape
  instead of erroring) before the fixture harness grew a `crossTargets`/
  `crossTargetNames` mechanism specifically to force-resolve a name for
  an arbitrary target and expose the real `{value, targetContainer}`
  struct for assertions (see `harness/templates/test.yaml`'s
  `crossResolved` output and `tests/tokens_test.yaml` for the pattern).
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
  "ENV") token DECLARATIONS are re-asserted twice, deliberately**: once
  during the initial merge (`crdkit.mergeTokens`), and again,
  unconditionally, in `crdkit.render` right after the integration chain
  finishes — specifically so a chain filter can't silently defeat the
  "these always win" guarantee by mutating `ctx.tokens`. The second
  reassertion is a wholesale reset of `ctx.tokens[name]` back to the
  ORIGINAL raw declaration (`{{- range $name, $raw := $system -}}
  {{- set $tokens $name $raw -}}{{- end -}}`, same for
  `builtinTokensRaw`), not a re-resolve — which also, as a side effect,
  wipes any `_value` cache a chain filter's tampering might have
  accumulated under a hijacked declaration. This is simpler than
  re-resolving and correct BECAUSE resolution is lazy: whatever needs
  the value resolves it fresh, correctly, the next time it's asked.
  Don't remove the second reassertion as "redundant" — it covers a
  different mistake/abuse surface than the first one (user-supplied
  tokens vs. chain-code mutation).
- **`crdkit.builtinTokens` keys are the reserved/built-in token name
  list — don't hardcode that list anywhere else.**
  `crdkit.mergeTokens` computes it as `append (keys $builtinTokens)
  "AT"`. Adding a new computed token (e.g. `ENV_UPPER: {{ .env |
  upper }}`) is enough on its own to make it both consumer-protected and
  chainable from other tokens — no second file to touch. Named
  `builtinTokens`, not `internalTokens` — "internal" wrongly implied
  hidden/inaccessible, when these are actually fully consumer-facing
  (`@ENV@` works anywhere); "builtin" matches the wording the
  diagnostic messages already used ("reserved built-in").
- **`builtinTokens` is folded into `crdkit.mergeTokens` the same way as
  every other source, and needs no special ordering care anymore.**
  Under the OLD eager-resolution design, a built-in token had to be
  folded in before the one upfront recursive `@ref@` pass ran, or
  cross-references to it broke non-deterministically (a real bug once,
  caused by Go's randomized map iteration order). That whole failure
  mode is gone under the lazy design: there is no upfront pass to order
  relative to — every token, `crdkit.builtinTokens` included, is looked
  up BY NAME on demand (`hasKey $tokens $refName`), so merge-map
  iteration order never enters into it. Nothing special is needed to
  add a new built-in token beyond putting it in `crdkit.builtinTokens`.
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
  a bare string** — `crdkit.resolveValue.core` is the one place that
  produces this shape, handling the ladder/`match:`/chaining resolution
  of the "value" half AND the `targetContainer` extraction/validation
  together, for a given name/target. A token's DECLARATION can still be
  a bare scalar or the env-dict shape — that's shorthand for `{value:
  <that>}` with `targetContainer` implied `"none"`, so every token
  declared before `targetContainer` existed still resolves exactly as
  before, just wrapped on the way out. The disambiguation between "bare
  env-dict declaration" and "wrapper dict with value/targetContainer" is
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
- **A resolved token's diagnostic messages name it by its BARE token
  name by default (`fieldName` defaults to `.name`), never a
  `"tokens.NAME"`-prefixed path.** `crdkit.resolveValue.core` accepts an
  optional `fieldName` override for a more specific message, but it's
  an internal-only param — the PUBLIC `crdkit.resolveValue` doesn't
  expose it at all (its list signature is `[ctx, name, target]`, no
  room for it), and nothing internally passes one either
  (`crdkit.substituteTokens`, `crdkit.resolveChainedValue`, and
  `crdkit.resolveTargetContainerTokens` all call `.core` unqualified).
  Expect `"no value for env 'prod' and no 'default' defined for
  'SOME_TOKEN'"`, not `"...for 'tokens.SOME_TOKEN'"`, in diagnostic
  text and in any test asserting against it.
- **Two author-mistake shapes are guarded against explicitly in
  `crdkit.resolveValue.core`, both found by deliberately thinking through
  edge cases rather than waiting for a bug report**: (1) `{targetContainer:
  "main"}` with no `value` key looks like a bare env-dict to the
  `hasKey $raw "value"` check (no "value" key present), so without a
  guard it silently falls into the ordinary ladder-resolution branch of
  `crdkit.resolveValue.core`, which tries to look up `"targetContainer"` as
  if it were an env/tier NAME —
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
  `main`/`side-car`/`both`/`none`** (crdkit.resolveValue.core and
  crdkit.addToken both enforce this identically). An invalid value
  records an ERROR (not a `fail()`) and falls back to `"none"`, so a
  downstream consumer of the rendered output never sees a garbage
  value — but the token's `value` still resolves normally regardless;
  only `targetContainer` is affected by the fallback.
- **Token names must be `UPPER_SNAKE_CASE` (`^[A-Z][A-Z0-9_]*$`),
  enforced as a WARNING, checked on EVERY token** — user-supplied,
  `system`, `defaults`, and `crdkit.builtinTokens` alike, in
  `crdkit.mergeTokens` (checked once, after the full merge, on
  every final key) and in `crdkit.addToken` (checked again for tokens
  contributed mid-chain, since those never pass through
  `mergeTokens`). This can only ever be a WARNING, never an ERROR
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
  `set $ctx.tokens NAME (...)` — it applies the same casing-WARNING and
  targetContainer-enum validation every other token gets. List-based,
  like the other directly-called token helpers: `[ctx, name, value,
  targetContainer, target]`. `target` is load-bearing here (not a
  future-reserved no-op): it's the exact string "value" gets stored
  against as a `match:` rule — see the "not special" bullet above for
  why `match:`, not eager resolution.
  A repeat `addToken` call for a name that already exists MERGES rather
  than clobbers: a call for a NEW target adds another `match:` entry
  alongside existing ones (nothing for other targets is lost); a call
  for the SAME `(name, target)` pair overwrites just that one entry, in
  place; an omitted `targetContainer` on a repeat call INHERITS
  whatever an earlier call already set, rather than resetting it back
  to `"none"` (there's no way to distinguish "caller didn't pass one"
  from "caller wants none" at the list-positional level, so "missing"
  is deliberately read as "inherit"). This matters because `ctx.tokens`
  is shared, mutable, chain-wide state — a naive `set` overwriting the
  WHOLE existing declaration on every call would silently destroy
  whatever a PRIOR addToken call (for a different target, in the same
  or an earlier integration) had already contributed. Only reaches for
  "replace outright" when the existing declaration isn't itself an
  addToken-produced `match:` shape (e.g. a consumer's own hand-declared
  token) — there's no safe way to merge into a shape it doesn't
  recognize. It deliberately does NOT run the reserved-name collision
  check `crdkit.mergeTokens` does — that check exists to protect
  against untrusted CONSUMER input at the initial merge; an integration
  calling `addToken` is trusted library-author code, a different trust
  boundary entirely.

## Testing

`harness/` + `tests/` (`make test`) exercise crdkit's own helpers
DIRECTLY — no `mycrd.render`-style wrapper, no apiVersion/kind, no
coupling to any specific library's token content. `harness/templates/
test.yaml` calls `crdkit.builtinTokens`/`mergeTokens`/
`resolveTargetContainerTokens`/`substituteTokens`,
`dictMerge`/`listExtend`/`ensureDictKey`, and `addToken` directly
against `.Values`, so a test case only needs to set
`target`/`tokens`/`system`/`defaults`/`structure` (token side),
`modelOps` (model side), `tokenOps` (mid-chain token contribution,
driving `crdkit.addToken`), or `crossTargets`/`crossTargetNames` (force
a name to resolve for an arbitrary target — just a plain target STRING,
not an `{env, target}` pair, since env is always derived from target
now — via `crdkit.resolveValue` directly, exposed as `crossResolved` —
the ONLY way to observe a resolved `{value, targetContainer}` struct
for a token that isn't otherwise "used" by this render, see the
lazy-resolution bullets above) — and assert on the rendered `tokens`/`structure`/
`crossResolved`/`model`/`diag`/`env` output. Added once `dictMerge`/
`listExtend` landed with zero committed coverage anywhere (their
multi-level behavior had only ever been checked in a throwaway scratch
chart) — this is the threshold the chart's own prior note about "no
test suite of its own" anticipated crossing.

**A test asserting on a token's resolved shape MUST first make it
"used"**, or the assertion fails against an absent/raw-declaration path
rather than testing what it meant to. Two ways to do that: reference it
via `structure.x: "@NAME@"` (checked against `structure.x` after
substitution — good when only the substituted VALUE matters), or via
`crossTargets`/`crossTargetNames` (checked against
`crossResolved.<target>.<NAME>.value`/`.targetContainer` — needed when
`targetContainer` matters too, or when asserting for a target other
than `.Values.target`). A token declaring a valid `targetContainer`
(`main`/`side-car`/`both`) is auto-resolved by
`crdkit.resolveTargetContainerTokens` without either of these — but
that only writes into the `_value` cache, so `tokens.NAME.value`/
`.targetContainer` at the top level still reads the raw, unresolved
declaration; `crossTargets` (or the exact-target `_value.<target>` path
directly) is still needed to read the RESOLVED struct back out. This
whole class of test bug (assertions quietly checking the wrong,
unresolved thing) is what most of the test suite's redesign-era rework
was about — see git history on `tests/tokens_test.yaml` if a similar
mistake shows up again.

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
