# Contributing to crdkit

Generic engine for CR rendering: token resolution, diagnostics, the
integration chain, the values schema and its docs. Usage:
`README.md`; per-define contracts: the doc comments
([`docs/defines.md`](docs/defines.md)); rules: `docs/requirements.md`.

## Read for your task

| Task                                       | Sections                                                                                                                         |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| change token resolution                    | [Resolution model](#resolution-model), [Target escalation](#target-escalation), [Token model](#token-model), [Testing](#testing) |
| change the values schema or its docs       | [Values schema](#values-schema), [Schema documentation](#schema-documentation), [Testing](#testing)                              |
| add or change a public define              | [Design decisions](#design-decisions), [Shared conventions](#shared-conventions), [Testing](#testing)                            |
| change the render / chain contract         | [Render and the integration chain](#render-and-the-integration-chain), [Design decisions](#design-decisions)                     |
| add a lint or extractor rule               | [Lint and generators](#lint-and-generators), [Testing facts](#testing-facts)                                                     |
| write tests                                | [Testing](#testing), [Testing facts](#testing-facts)                                                                             |
| write docs (README examples, doc comments) | [Writing](#writing), [Doc comments](#doc-comments), [README examples](#readme-examples)                                          |
| release                                    | workspace [Workspace rules](../CLAUDE.md#workspace-rules) (bump → `make docs` → commit → tag on `main`)                          |

## Layout

- `templates/` — the engine: public defines in `templates/_<base>.tpl`,
  internal ones in `templates/_<base>.internal.tpl`.
- `tests/` — `tests/stub` (test chart), `tests/suites`, `tests/fixtures`,
  `tests/lint.pending`. See "Testing".
- `scripts/lint.sh` — template lint, also run by mdeploy.
- `scripts/extract.py` — `graph` (workspace call-graph viewers), `lint`,
  `reference` (`docs/defines.md`), `diagnostics` (`docs/diagnostics.md`).
- `scripts/examples.py` — README example blocks from
  `docs/readme-examples/<stem>.{yaml,tpl}`.
- `scripts/trace.sh` — readable diff of a render `trace`.
- `docs/requirements.md` — the C- requirement catalogue.
- `docs/defines.md`, `docs/diagnostics.md` — generated; `make docs`
  rewrites them and the README examples, `make test` fails when stale.
- Dependency updates, `command make`, release: workspace `../CLAUDE.md`.

## Shared conventions

Both repos (mdeploy links this section).

### Writing

- English, terse bullets (README: guide style, short paragraphs
  allowed). Current design only: no history, no "used to be", no
  describing a shape by what it lacks (a negation only as a call-site
  warning, e.g. "never read `.value` here — resolve via X"). Never label
  anything "new". A short "why" only for non-obvious decisions.
- One hand-written owner per fact; a fact derivable from code is
  generated; every other layer links to the owner:
  - consumer-visible rule (conditions, diagnostics, counts) →
    `docs/requirements.md`; README: outline + link;
  - usage (concepts, values, examples) → README;
  - maintainer fact (design, invariants across defines, layout,
    workflow) → the repo's CONTRIBUTING;
  - define-local contract and corner cases → the doc comment;
  - callers, callees, ctx effects → `docs/defines.md`; message texts →
    `docs/diagnostics.md` (both generated).
- A ctx path keeps its `ctx.` root; a slot's shape is stated only in the
  comment of the define that seeds it (`crdkit.render`, a library's
  render).
- Inline comments: one line per non-obvious why, never restating code.

### Doc comments

- Every `define`, in order:
  1. header `<name> (<scope>)` (the scope is authoritative);
  2. purpose, at most 2 lines (a callback also says what invokes it);
  3. `Interface:` exact params and return shape (every non-callback
     define); dict params as `- Params (dict): { "k": <…>, … }`, every
     key the body reads, optional ones marked;
  4. `Implementation notes:` only this define's corner cases.
- Behavior spanning defines (precedence, ordering, caching) lives in
  CONTRIBUTING: the comment says `See CONTRIBUTING "<heading>"`
  (`See crdkit CONTRIBUTING "<heading>"` from a library).
- Never name a define that calls this one; never restate a shape owned
  elsewhere.
- The file-level doc comment lives in the base file.

<!-- sketch -->
```gotemplate
{{/*
crdkit.<name>.internal (internal)

Resolves X for Y.

Interface:
- Params (dict): { "a": <string>, "b": <dict, optional> }
- Returns: <shape>

Implementation notes:
- <corner case, only if non-obvious>
*/}}
```

### README examples

- Every fenced README block is generated between example markers or
  preceded by `<!-- sketch -->`:

  <!-- sketch -->
  ```
  <!-- example: docs/readme-examples/<stem> [target=a,b] [show=p1,p2] [render=none] [lang=<l>] -->
  …generated…
  <!-- /example -->
  ```

- Inputs are hand-written in `docs/readme-examples/`: `<stem>.yaml`
  (values) and, for crdkit, `<stem>.tpl` (a snippet using only `$ctx`
  and literals: no `define`, no `.Values` / `.ctx.root`, no library
  define; one snippet = one output). A version goes in as
  `@CHART_VERSION@` with `render=none`.
- `make docs` rewrites the blocks, `make test` (mdeploy: `run.sh docs`)
  fails on a stale block, a render failure or any diagnostic. Block
  shapes and rendering: the `scripts/examples.py` header.

### Helm / Go template facts

- `fromYaml`/`fromJson` cannot decode a bare scalar or list and silently
  return an error dict: wrap as `value: …`; under `value:` use
  `| toYaml | nindent 2`.
- Static data in a YAML-returning define is literal YAML, not
  `list`/`dict` + `toYaml`:

  <!-- sketch -->
  ```gotemplate
  value:
  - service
  - targetContainer
  ```

- Quote every scalar a YAML-emitting define produces (`| quote`), even
  empty: an unquoted empty scalar is `null`, a hard error in `replace`.
- Boolean-ish defines return `true` or an EMPTY string, never `false`
  (a non-empty string is truthy).
- `{{ index $m $k }}` as a define's trailing output renders
  `<no value>` for a missing key across `include`: guard with `hasKey`.
- `set` on a missing/nil intermediate map crashes the render with no
  diagnostic: ensure every level first (crdkit: `crdkit.dictMerge`,
  `crdkit.listExtend`, `crdkit.ensureDictKey`).
- A shared accumulator param (`seen`, `out`, `diag`) is guarded with
  `ternary .seen (dict) (kindIs "map" .seen)`, never `default dict`: an
  empty dict is falsy and would be replaced.
- Mutating defines return `""`; mutation and text output never mix in
  one define.
- `.Values | toYaml | fromYaml` before `dig` or map operations (Helm's
  `chartutil.Values` fails `dig`'s type assertion).
- Helm's `fromYaml` and values files are YAML 1.1: keys `on`, `off`,
  `yes`, `no` become booleans — use `by:`, avoid such IDs. A crdkit
  `keys` map key that is `y/n/yes/no/on/off/true/false` (any case) is an
  ERROR naming the parsed key (`'<path>.true'`).
- Consumer regexes: validity first (`regexMatch (printf "(?:%s)|" $re)
  ""` is true iff it compiles; `crdkit.regexValid.internal`); invalid →
  ERROR naming it, rule skipped; never a non-`must` match on an
  unchecked pattern. Library-owned patterns (schema `pattern` /
  `keys.pattern`, a library's constants): `mustRegex*`, abort.
- `fail` only in a library's final render decision; everything else
  records a diagnostic.
- Helm merges `define` names of a chart and all its dependencies into
  one namespace: every name carries the chart prefix.

### Testing facts

- `it:` names start with the C-/R- ids of `docs/requirements.md`, then
  F-/TC- ids; traceability = `grep -r <id> tests/`.
- Diagnostics: level `diagnostics.<level>`, a quoted fragment as the
  message quotes it, via `exists` + jsonpath regex
  (`diagnostics.error[?(@ =~ /'T'/)]`); never the full text.
- `lengthEqual` only when the count is the requirement; a clean render
  = `notExists: {path: diagnostics}`; one leaf or item per requirement;
  lists via `contains … any: true`, order only when it is the
  requirement.
- Never `matchSnapshot`; never a literal chart version in an assert.
- Open finding: the target-form test with `skip: {reason: "F-n open
  (<feature>)"}` (mdeploy fixtures: `# pending: F-n (<feature>)`); the
  fix deletes the marker; a passing pending check fails as `FIXED?`.
- `# ERROR:` / `# WARNING:` / `# INFO:` lines reach helm-unittest
  through the adapter `test.withDiagnostics` (`diagnostics.{error,
  warning, info}`; no `diagnostics` key on a clean render).
- helm-unittest: `set:` cannot index arrays (`a[0].b`) — set the whole
  array; the chart `name:` may differ from its dir; a test without
  `template:` runs against every suite template; the first line of a
  multi-line `fail` is dropped before matching; `failedTemplate` has no
  negative match; it creates an empty `__snapshot__/` beside each suite
  (git-ignored).
- helm-unittest reads `set:` and `values:` files as YAML 1.2: a passing
  test does not prove a YAML 1.1 key survives; such cases go through
  `helm template -f` (mdeploy `tests/run.sh invalid`).
- `.helmignore` (every chart) excludes `tests/`, `scripts/`, `docs/`,
  `__snapshot__/` (mdeploy: `/docs/`, anchored); never `**` (`helm
  package` rejects it).
- Lint and extractor rules: zero false positives on current code, else
  the rule is dropped — never an exception list. Open hits:
  `tests/lint.pending` lines `<rule> <file> <F-id or step> (<feature>)`;
  a fix deletes its line.

## Design decisions

- Chart name `crdkit`, every define prefixed `crdkit.`; never a
  hardcoded template name of another chart: product input (tokens,
  chain, taxonomy) arrives as params of the library's wrapper.
- Scopes: `public` (for libraries) or `internal`. Every internal define
  ends `.internal` and lives in `*.internal.tpl`: libraries call crdkit
  through many defines, so the name says at the call site what is
  off-limits. The public set: `docs/defines.md` index.
- Signatures: a `dict` with named keys, except
  - `crdkit.dictMerge`, `crdkit.listExtend`, `crdkit.model.hasPath`:
    `[model, k1..kN, value?]`, like `dig` (`dictMerge` also takes zero
    keys; `listExtend` does not: the model is a dict);
  - the token entry points (`crdkit.token.value|string|add|underlay|annotate|info`,
    `crdkit.tokenDef.value|string`, `crdkit.tokens.substitute`): a list,
    `ctx` first, `target` last and optional (default `ctx.target`);
  - `crdkit.diag.error|warning|info`: `[diag, message]`;
  - the `parentTargetTemplate` hook: `{target, context}`.
- Never `fail()`: every problem is a diagnostic in the threaded `diag`
  (one author mistake never aborts a render). The two aborts: a
  library's final decision after the render (mdeploy's deploy mode) and
  a library-owned regex (`mustRegex*`: a template cannot catch the
  error, and a non-`must` match would silently never match).
- `target` is opaque: no env/family/tier; a library builds its own
  taxonomy (`parentTargetTemplate`) and its own `@ENV@`-style tokens.
- Token annotations are a library-supplied list of names (unrelated to
  Kubernetes annotations): crdkit stores them as reserved declaration
  keys and never interprets them; the declaration storage shape is not
  contract; policy (validation, locking, widening) is the library's.
- `ctx` and `chain` are separate params: `ctx` is the shared mutable
  accumulator, `chain` a read-only list of names.

## Render and the integration chain

- `crdkit.render` (params and ctx slots: its doc comment) merges the
  tokens, starts `ctx.model` as an empty dict, runs the chain, then the
  final pass: `crdkit.tokens.substituteMarkers.internal` over every
  string leaf → the unresolved-marker scan ("possible typo") → `@AT@` →
  `@`. Output = `model | toYaml` plus the diagnostic lines; crdkit never
  reads `.Values`.
- `state` keys are copied into `ctx` (a crdkit key → ERROR, ignored);
  crdkit never reads them. The `diag` seed is transported and appended
  to. `trace` (caller-owned) receives one snapshot per stage; no `trace`
  → no snapshot.
- `crdkit.integrations.chain` calls each name in list order in one loop;
  an integration never calls the next and must ensure every field it
  touches, every time — chain order is no guarantee of shape.
- An integration's body is mutating-helper calls only; text is emitted
  once, by `crdkit.render`.
- Locked (`system`) declarations are asserted once, at the merge: the
  chain is trusted first-party code; only the consumer's `tokens` are
  the untrusted boundary.

## Target escalation

- One caller hook, `parentTargetTemplate`: `{target, context}` → the
  next rung or nothing; default `crdkit.noParentTarget`.
  Implementations guard map lookups with `hasKey` (see "Helm / Go
  template facts").
- Order per token and target: `_value[<exact target>]` (current
  generation only) → the exact-target key → `match:` (exact target only)
  → the walk → `default` → `_generated[<exact target>]` → ERROR "no
  value found". `match:` precedes every cached rung: a broader cached
  rung would otherwise steal precedence from a target-specific rule.
- Caching: always under `_value[<exact target>]`; under each walked rung
  only when the selected entry holds no marker (a map/list: checked on
  its `toJson`). Rungs are shared across targets; a marker-holding entry
  and a generated value are per target, so they are cached under the
  exact target only.
- `default` is checked after the walk, never before: a token may have
  both, and the taxonomy-reachable value is the more specific one.

## Resolution model

- Lazy, per target, memoized: `crdkit.tokens.merge.internal` merges raw
  declarations only; a token resolves (and is diagnosed) when a marker
  or a chained reference needs it.
- A resolved value may be a structure: string leaves substituted
  recursively, non-string scalars keep their type. Splicing into text
  (a marker, `*.string`) goes through `crdkit.stringify.internal`, the
  one place deciding it: list → `,`-joined (a dict/list element as
  JSON), dict → JSON.
- Generations: `ctx.gen` (starts `0`) is bumped by every
  `crdkit.token.add` / `crdkit.token.underlay`; a declaration's `_gen`
  stamps its `_value`; on a mismatch `resolveEntry.internal` resets
  `_value` (compared via `toString`: int/int64/float64). Applies to
  `crdkit.tokenDef.*` structures. Every internal resolution helper
  forwards `gen` and `reservedKeys`; one that forgets silently resolves
  with defaults.
- `crdkit.token.add` stores the exact target's entry unresolved (it may
  reference a token a later integration adds); repeat calls merge.
  `crdkit.token.underlay` stores `_generated[<target>]`. Both check only
  the annotations' shape and keys — callers are first-party library
  code; `crdkit.token.annotate` sets keys without a generation bump.
- Chained references resolve for the same target; cycle detection is an
  in-progress-name stack per top-level resolution. Walking a resolved
  structure has no cycle risk (finite YAML/JSON).

## Token model

- Merge: `defaults` deep-merged with the consumer's `tokens`, then each
  `system` declaration replaces its name wholesale (a deep merge would
  leave consumer target entries active under a locked token). Scalars
  → `{default: v}`, so every `ctx.tokens` entry is a dict.
- Reserved keys (`crdkit.reservedKeys.internal`, once, as
  `ctx.reservedKeys`): `_value`, `_gen`, `_generated` (written by a
  consumer, defaults or system: WARNING per key, removed), `match`,
  every annotation name. Every other key, `default` included, is a
  target entry; an annotation named like a reserved key or `default` →
  ERROR, dropped.
- Marker grammar `@[A-Za-z0-9_.]+@`, only in `crdkit.markerPattern`;
  every marker match uses it. The `.` lets a library namespace names
  (`<ID>.<field>`) and makes a relative `@.x@` a marker in the schema
  passes.
- `AT` is the one built-in name (`@AT@` → `@`, after every other
  marker); a declaration of it → WARNING, dropped. The typo scan runs
  before `@AT@` is replaced, so an escaped marker is never reported.
- No name checks (naming policy is a library's schema); the reserved-key
  collision check is case-sensitive. Messages name a token bare, never
  `tokens.NAME`.

## Values schema

Node shape: `templates/_schema.tpl` file comment; the DSL for library
authors: README "Schema DSL".

- `type` names shape and scalar type after substitution;
  `crdkit.schema.shape.internal` is the one type → shape map; walkers
  read the shape through it, never `.type`.
- Passes: `crdkit.schema.validate` (structural, before the chain;
  defaults applied, failing nodes dropped) and
  `crdkit.schema.validateValues` (per-target values for one target,
  after the chain). `crdkit.schema.value` checks one field; a shared
  `seen` reports each `path|target` once, so its `path` must come from
  `crdkit.schema.path` (same spelling as the value pass).
- `crdkit.schema.resolve` runs the value pass's walker
  (`crdkit.schema.valuesWalk.internal` with an `out` dict): the check
  and the copy can never disagree about which nodes are per-target.
  Walkers pass results through `out`, never YAML (a round-trip per level
  would re-decode every value).
- `crdkit.schema.resolveAndCheck.internal` converts a passing
  `int|number|bool` string (`atoi`, `float64`, `eq "true"`) on every
  call, independent of `seen`; a failing value or one with a marker
  stays unconverted.
- Severities: shape mismatch / unmatched switch → WARNING, ERROR on a
  `required: true` node (the required check reads the input as written
  and would miss the drop); unknown key → WARNING; everything else, and
  every value-pass violation (naming the target), → ERROR. Static
  values are checked strictly, resolved ones "parses as". Texts:
  `docs/diagnostics.md`.
- Per-target: `crdkit.schema.perTarget.internal` decides; walkers thread
  `inTokens`. A token declaration is a dict, so only scalar and `list`
  nodes may be per-target (in a map field it would be ambiguous).
  `static: true` below a per-target node is a self-check ERROR except a
  switch case's `by` key (`checkNode.internal` threads `switchBy`).
- Declaration keys: `targetKeys` (inherited, a descendant's own
  replaces it) and the node's `annotations`; checked by
  `crdkit.schema.checkDeclaration.internal` in the structural pass only.
  JSON Schema: a `$ref` to a shared `targetDeclaration[N][.<annotation>]`
  definition; readers take the keys from it
  (`crdkit.schema.jsonDeclaration.internal`), never from a per-node copy.
- `switch.unless`: a hit (`toJson` equal) is checked as `by` + `key`
  only, other keys dropped silently (`crdkit.schema.switchCase.internal`,
  both walkers); JSON `if` gets `<key>: {not: {const}}`.
- `keys` map keys that are YAML 1.1 boolean words are checked before
  `keys.pattern`; consumer `match:` regexes in the structural pass
  (`crdkit.regexValid.internal`).

### Schema documentation

- `crdkit.schema.document` makes one `crdkit.schema.jsonSchema` call and
  feeds its text to the renderer; renderers read JSON Schema only.
- The schema arrives as text: `fromYaml` yields a Go map without key
  order. `crdkit.schema.order.internal` records each block-style key's
  position (indentation stack; flow maps and block scalars skipped) as
  `x-crdkit-order`; unpositioned keys sort alphabetically after.
- Draft-07; `x-crdkit-*` only for what standard keywords cannot say,
  never derivable data: type from `type` (`jsonType.internal`),
  per-target from a declaration `$ref` (`jsonPerTarget.internal`;
  `x-crdkit-perTarget` stored only as `"no"`), `markdownDescription`
  only when it differs, `examples` only on the root and scalars.
- Per-target node = `anyOf [type, <declaration>]`, plus `markers` only
  on `int|number|bool` or an `enum`/`pattern` string; a non-per-target
  node of that kind `anyOf [type, markers]`; a static string/scalar
  `not: {$ref: markers}` (draft-07 ignores keywords next to a `$ref`).
  Switch cases: `definitions["<path>[<by>=<case>]"]` via `allOf`
  `if/then`; properties identical in every case: `x-crdkit-shared`.
- HTML: a fixed self-contained shell (no external request, system fonts,
  `prefers-color-scheme`) with the schema in `<script
  id="crdkit-schema">` and a view model in `<script id="crdkit-view">`
  (`crdkit.schema.viewModel.internal`: one item per tree row, one record
  per switch), so a schema change changes only the embeds. The JS
  renders, filters and searches the view model and derives nothing.
- `id` → root `$id` and the copy-ready modeline (a consumer copies it
  instead of assembling a tagged URL).

## Testing

`command make test` = `deps` (`tests/stub` dependency update) + the
suites + the lint + the freshness of `docs/defines.md`,
`docs/diagnostics.md` and the README examples. Needs the helm-unittest
plugin (`helm plugin install
https://github.com/helm-unittest/helm-unittest`) and `python3` (lint,
examples). End to end, crdkit also runs under mdeploy's tests
(`../mdeploy/CONTRIBUTING.md` "Testing").

### Framework

- `tests/stub/` — chart `stub` (crdkit `file://../..`), a minimal
  library on crdkit's public API, so a contract test is values only.
  - `tests/stub/templates/_stub.tpl`: `stub.render` maps values to
    `crdkit.render` params; `stub.ops`, the only chain entry, runs
    `.Values.ops` (one op per public define; `at` = the model path the
    result is written to, so the final substitution applies; `{tpl, at}`
    runs a README snippet). Both lists: the doc comments.
  - `tests/stub/templates/docs.yaml`: `stub.docs` → `crdkit.schema.document`
    from `.Values.docs` (gated).
  - `tests/stub/templates/_adapter.tpl`: `test.withDiagnostics`;
    `tests/stub/templates/cr.yaml`: the adapter around `stub.render`.
- `tests/fixtures/base.yaml` — `target: b-01`, ladder `b-01 → b → ALL`.
- `tests/suites/*_test.yaml` — `helm unittest tests/stub -f
  '../suites/*_test.yaml'`, `values: [../fixtures/base.yaml]` + `set:`.
- Rules: "Testing facts".

### Lint and generators

- `scripts/lint.sh` — text rules, the boundary group (`--library`, for a
  library's templates; crdkit owns these internals and never passes
  it), then `scripts/extract.py lint`. crdkit passes
  `--regex-check-define crdkit.regexValid.internal` (the one validity
  probe), `--scopes public,internal --internal-suffix`, `--doc-rules`,
  its Markdown files, `--requirements`/`--tests` and `--readme`
  (Makefile). Rules, flags, output and exit codes: the script headers.
  Paths print as given: run from the repo root.
- `scripts/extract.py reference|diagnostics` — the generated
  `docs/defines.md` (index, ctx slots, one section per define) and
  `docs/diagnostics.md` (one row per diag call); deterministic, no line
  numbers.
- `scripts/examples.py render|check` — "README examples".
- `scripts/trace.sh [<file>|-]` — `+`/`-`/`~` leaves per stage of a
  `trace` (`helm template … --set trace=true | yq -o json '.trace' |
  scripts/trace.sh`).

## Open / deferred

How a rendered CR's fields beyond a library's preamble map into a real
CRD spec — blocked on the target CRD being known.
