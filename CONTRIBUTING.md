# Contributing to crdkit

Generic engine for CR rendering: token resolution, diagnostics, the
integration-chain dispatcher. Zero knowledge of any specific CRD.
Libraries built on crdkit (e.g. mdeploy) depend on it via `file://`.

## Layout

- `templates/` — the engine.
- `tests/` — the test framework (`tests/stub`, `tests/suites`,
  `tests/fixtures`). See "Testing".
- `scripts/lint.sh` — template lint (text, boundary and extractor
  rules) for library templates, also run by mdeploy.
- `scripts/extract.py` — the call-graph extractor: `graph` (the
  workspace viewers), `lint` (the rules `lint.sh` forwards to) and
  `reference` (the committed `docs/defines.md`).
- `docs/defines.md` — the generated define reference; `make docs`
  rewrites it, `make test` diffs a fresh copy.

**Release tags**: `v<chart version>` (e.g. `v0.0.7`). Release order:
bump `version` in `Chart.yaml` → commit → tag `v<version>`.

`make` may be shadowed in some shells — if `make test` fails with
`function definition file not found`, use `command make <target>`
instead.

## Documentation conventions

Applies to CONTRIBUTING.md/README.md files and every template's doc comment.

**Style**
- Write all documentation in English (CONTRIBUTING.md, READMEs, doc
  comments, specs, plans).
- Be concise: short bullet/numbered points, not prose paragraphs.
- Document the CURRENT design only — no history (no "used to be X,"
  "an earlier version did Y," "removed because Z"). State the decision
  and, if needed, its rationale — drop everything about what came
  before it.
- This includes IMPLICIT history: don't describe a shape by what it
  ISN'T or NO LONGER HAS (e.g. "no 'value' key exists here") — describe
  only what it IS. A negation is fine only as an actionable warning at
  a call site (e.g. "never read `.value` here — resolve via X instead"),
  never as scene-setting about a shape's design.
- Give a short "why" for non-obvious architectural/implementation
  decisions; skip the rationale when the decision is self-evident.
- Never label a template or file as "new" (e.g. "(public, new)",
  "new `templates/_paths.tpl`") — in docs, specs, plans or doc comments.
  Name it plainly; specs and plans describe the target state.
- A doc comment names no define that calls it — `docs/defines.md` lists
  callers, calls and ctx effects. A ctx path is written with its `ctx.`
  root, and a slot's shape is stated only in `crdkit.render`'s comment.

**Per-template doc comments** — structure every `define`'s comment as:
1. **Header line**: `<template name> (<scope>)` — long comments push the
   `define` line out of view. The scope here is authoritative (see
   "Template scopes" below).
2. **Purpose**: a short plain-prose paragraph (no heading, no bullet)
   saying what the template is for; a `callback` also says what invokes
   it (e.g. "Invoked by crdkit's integration chain.").
3. **Interface**: exact parameter shape and return shape only.
4. **Implementation notes** (omit if nothing non-obvious applies):
   corner cases, warnings, invariants a caller must respect.

**Template scopes**: `public` (for libraries built on crdkit) or
`internal`.

- A public template lives in `templates/_<base>.tpl`, an internal one in
  `templates/_<base>.internal.tpl`; the file-level doc comment stays in
  the base file. Why: a reader of the base file sees only the API a
  library may call.

**`.internal` name suffix**: required on every internal template —
other libraries consume crdkit through many templates, so the name
itself must say what is off-limits at the call site.

**Inline comments** (inside the template body): one short line per
non-obvious "why" — never restate what the code already does.

Example skeleton:
```gotemplate
{{/*
crdkit.example.internal (internal)

Resolves X for Y.

Interface:
- Params (dict): { "a": <string>, "b": <dict> }
- Returns: <shape>

Implementation notes:
- <corner case, only if non-obvious>
*/}}
{{- define "crdkit.example.internal" -}}
...
{{- end -}}
```

## Template code conventions

- Static data a YAML-returning `define` emits (fixed lists/dicts) is
  written as literal YAML, not built with `list`/`dict` + `toYaml`:
  ```gotemplate
  value:
  - service
  - targetContainer
  ```
  Keep `| toYaml` for values built at render time; under a `value:`
  wrapper use `| toYaml | nindent 2` (a bare `value: {{ x | toYaml }}`
  is invalid YAML for a list, and `fromYaml` then silently returns an
  error dict).

## Purpose

Generic engine for CR rendering: token resolution, diagnostics,
integration-chain dispatch. No knowledge of any specific CRD, apiGroup,
kind, token content, or "environment"/"family"/"tier" concepts. See
`README.md` for usage; this file covers decisions not visible
from the templates alone.

## Design decisions

- Chart name isn't generic (e.g. not "common") — Helm merges `define`
  names across a chart and all transitive dependencies into one flat
  namespace, so a generic name risks collision with another dependency.
- Never hardcodes another chart's template name. Product-specific input
  (tokens, chain, taxonomy) arrives as explicit params from the caller's
  wrapper (`mdeploy.render`). `crdkit.render` emits `ctx.model` verbatim
  after substitution, without inspecting its shape; a specific library's
  "preamble" integration (first in `chain`) builds the CR shape —
  `apiVersion`/`kind`/labels/metadata/spec — from `ctx.root.Values`.
- Helper signatures default to `dict` with named keys. Exceptions:
  - `crdkit.dictMerge`/`crdkit.listExtend`/`crdkit.model.hasPath`:
    list-based, variadic path (mirrors Sprig's `dig`).
  - Directly-called token entry points (`crdkit.token.value`,
    `crdkit.token.string`, `crdkit.token.add`, `crdkit.token.underlay`,
    `crdkit.tokenDef.value`, `crdkit.tokenDef.string`, `crdkit.tokens.substitute`): list-based,
    `ctx` first, `target` always last and optional (defaults to
    `ctx.target`).
  - `crdkit.diag.error`/`crdkit.diag.warning`: list-based
    `[diag, message]`.
  - `parentTargetTemplate`: an externally-implemented hook, called with
    a fixed `{target, context}` shape.
- Internal-only helpers carry a `.internal` suffix:
  `resolveEntry.internal`,
  `substituteText.internal`, `substituteStructure.internal`,
  `tokens.substituteMarkers.internal`, `stringify.internal`,
  `tokens.merge.internal`, `reservedKeys.internal`,
  `regexValid.internal`, `tokenPrologue.internal`, `locate.internal`,
  `checkMemo.internal`, `snapshotCtx.internal`, and the `crdkit.schema.*.internal` helpers
  (`path`, `shape`, `perTarget`, `checkNode`, `scalarReason`, `walk`,
  `resolveAndCheck`, `valuesWalk`, `mdNode`, `mdSkeleton`, `mdRow`, `mdTable`, `mdType`, `mdDoc`, `mdCaseExample`, `generatedExample`, `order`, `orderedKeys`,
  `ref`, `examples`, `sectionProblem`, `sectionMarkdown`, `jsonNode`,
  `viewer`). Everything else
  (`matchRules`, `standardLabels`,
  `dictMerge`/`listExtend`/`ensureDictKey`/`model.hasPath`,
  `diag.error`/`diag.warning`,
  `token.value`/`token.string`/`token.add`/`token.underlay`,
  `tokenDef.value`/`tokenDef.string`, `tokens.substitute`,
  `integrations.chain`, `dependencyVersion`, `noParentTarget`, `render`,
  `name`, `schema.check`/`validate`/`validateValues`/`resolve`/`value`/`node`/
  `path`/`docs`/`jsonSchema`/`html`/`document`) is public.
- Diagnostics never call `fail()`. Every helper that can fail takes a
  `diag` dict (`errors`/`warnings`), threaded by reference — a single
  author mistake must never hard-abort a render. A diagnostic is
  recorded through `crdkit.diag.error`/`crdkit.diag.warning`.
  The deliberate exception is a specific library's final decision after
  the render: mdeploy's `mdeploy.render`, in deploy mode with errors, fails
  with the collected diagnostics. A second deliberate exception: a
  library-owned regex (schema `pattern`/`keys.pattern`) aborts —
  `crdkit.matchRules` uses `mustRegex*` there because a template cannot
  catch the error, and the non-`must` variants would make the pattern
  silently never match. A CONSUMER `match:` rule is validated first
  (`crdkit.regexValid.internal`) and an invalid one is an ERROR naming
  the rule, skipped — never a non-`must` match on an unchecked pattern.
  Apart from these two, crdkit and every helper only collect.
  `crdkit.render` takes an optional `diag` seed (`{errors, warnings,
  infos}`, any subset; missing lists are created); crdkit only
  transports seeded entries and emits them with its own.
- `crdkit.render` takes an optional `state` dict: its keys are copied
  into `ctx` (a key colliding with a crdkit `ctx` key → ERROR, ignored).
  Library-owned data for integrations; crdkit never reads it.
- Token annotations are a generic, library-supplied list of names
  (`crdkit.render`'s `tokenAnnotations` param) — metadata on token
  declarations, unrelated to Kubernetes annotations. crdkit stores them as
  reserved declaration keys and never interprets, resolves or validates
  a name or value. Libraries use `crdkit.token.annotate` /
  `crdkit.token.info` / `crdkit.token.names`; the declaration storage
  shape is not contract. Policy (validation, locking, widening) belongs to
  the library.
- No concept of "env"/"family"/"tier" — `target` is an opaque string. A
  specific library implements its own `@ENV@`-style token or "target
  required" check if it wants one (see mdeploy's `mdeploy.systemTokens`).

## Target escalation

- Driven by one caller-supplied hook, `parentTargetTemplate`
  (fully-qualified template name, e.g. `mdeploy.parentTarget`). Given
  `{target, context}`, returns the next rung or nothing.
  `crdkit.noParentTarget` (default) always returns nothing.
  `crdkit.matchRules` is available for such a template to build
  pattern-based hops on.
- Resolution order per token/target: exact-target `_value` cache hit
  (valid only for the current generation, see "Resolution model") →
  dedicated-attribute key → `match:` (against the exact original target
  only, never retried at an escalated rung) → walk
  `parentTargetTemplate` → `default`
  fallback (see "Token model details" below) → `_generated[<exact
  target>]` (values from `crdkit.token.underlay`, lowest priority) →
  "no value found" ERROR. `match:` must be checked before any
  cache-tier hit from the walk, or a broader cached rung could steal
  precedence from a target-specific `match:` rule.
- Caching: under `_value[<exact target>]` always; under every rung
  walked only when the selected entry holds no marker (a map/list:
  checked on its `toJson`). Rungs are shared across targets: a
  marker-holding entry substitutes per target, and a value found in
  `_generated` is per target — both cached under the exact target only,
  so each target resolved in one render gets its own value.
- **GOTCHA**: a bare `{{- index $map $target -}}` as a define's
  trailing, unassigned output, for a missing key, renders as the
  literal text `<no value>` (not an empty string) once it crosses an
  `include` boundary — genuine Go `text/template` behavior. Always
  guard with `hasKey` first in any `parentTargetTemplate`
  implementation.

## Resolution model

- Lazy, per-target, memoized. `crdkit.tokens.merge.internal` merges raw
  declarations only (`ctx.tokens`); a token resolves (and is diagnosed,
  if malformed) only when something needs it — a `@NAME@` marker or a
  chained reference.
- A resolved value can be a plain string OR a structure (dict/list) —
  every string LEAF gets `@ref@`-substituted recursively; non-string
  scalars (bool/int/float) pass through in their native type, unchanged.
- A structure spliced into text (a marker, `token.string`,
  `tokenDef.string`) goes through `crdkit.stringify.internal`, the one
  place deciding it: list → elements joined by `,` (no space; a
  dict/list element as JSON), dict → JSON. Applies to every token.
- `crdkit.token.value` and `crdkit.tokenDef.value` return
  `{value: <resolved thing>}` — a single-key wrapper that exists only because Helm's
  `fromYaml`/`fromJson` can't decode a bare top-level scalar or list
  (confirmed empirically: it silently returns an error dict instead of
  erroring loudly). `crdkit.token.string`, `crdkit.tokenDef.string` and
  `crdkit.tokens.substitute` return plain text.
- `crdkit.token.add` `[ctx, name, value, annotations?, target?]` stores
  a value as a dedicated attribute (key = exact target), merged into the
  token's existing entries, not resolved eagerly — an integration's
  value may reference a token another integration adds later in the
  chain. Repeat calls merge (new target → new key; same target →
  overwrite). `annotations` (dict) is merged over the existing ones; an
  omitted key is inherited. Checks only shape: a non-dict, non-nil
  `annotations` records an ERROR and is ignored (the value is still
  stored). No name check, no reserved-name collision check and no annotation-value validation —
  `token.add` callers are first-party library code, not untrusted
  consumer input.
- `crdkit.token.underlay` (same signature) stores the value under
  `_generated[<target>]` (a repeat call for a target overwrites) and
  sets each annotation only when the declaration lacks it; it creates a
  missing token. Same annotation check as `token.add`.
- Cache generations: `ctx.gen` (int, starts `0`) is bumped by every
  `token.add`/`token.underlay`. A declaration's `_gen` is the generation
  its `_value` cache was written under; on a mismatch
  `resolveEntry.internal` resets `_value` to `{}` before use (compared
  via `toString`, robust to int/int64/float64). Applies to
  `crdkit.tokenDef.*` structures too. The current generation travels as
  the `gen` param through every internal resolution helper, exactly like
  `reservedKeys`; a helper that forgets to forward either silently
  resolves with defaults.
- Chained `@ref@` resolution is target-scoped, including cycle
  detection — resolving A for `qap1` resolves A's dependencies for
  `qap1` too. Cycle detection uses an in-progress-name stack scoped to
  one top-level resolution. Structural recursion (walking into a
  resolved dict/list) carries no separate cycle risk of its own — it's
  finite literal YAML/JSON, not a graph with back-edges.
- `ctx` and `chain` are separate arguments by design: `ctx` is a shared,
  mutate-in-place accumulator; `chain` is a read-only list of names.
- The reserved-name collision check is case-sensitive (`apiGroup`
  doesn't collide with locked `API_GROUP`); mdeploy's schema rejects
  such a variable name before it becomes a token.

**Dependency graph** — see the file-level doc comment of
`templates/_tokens.tpl`.

## ctx.model and the integration chain

- `ctx.model` has no pre-declared shape. `crdkit.render` starts it as a
  bare `dict`; every field is created lazily via `crdkit.ensureDictKey`.
  Every integration must ensure a field exists before touching it,
  every time — chain order isn't something to depend on. A plain Sprig
  `set` on a missing/nil intermediate map hard-crashes the render with
  no diagnostic.
- Prefer `crdkit.dictMerge`/`crdkit.listExtend` over `crdkit.ensureDictKey`
  directly. Both take `[model, key1, ..., keyN, value]` (list-based,
  mirrors `dig`). `crdkit.dictMerge` also supports zero path keys
  (`[model, value]`, merges directly into `model`) — for setting several
  top-level scalar fields at once (e.g. `apiVersion`/`kind`).
  `listExtend` has no zero-key form — `ctx.model` is always a dict,
  never a list.
- `crdkit.model.hasPath` (`[model, key1, ..., keyN]`) returns the plain
  string `true` or an EMPTY string — never `false` (a non-empty string
  is truthy), no `{value: …}` wrapper (nothing is `fromYaml`-decoded).
  Every intermediate node must be a map.
- Chain order = call order: `crdkit.integrations.chain` calls each name
  in list order, in one flat loop; an integration never calls the next.
- Mutation and text-rendering must never mix in one `define`. Every
  model-mutating helper returns `""` — this is what makes a bare,
  uncaptured `{{- include ... -}}` safe. An integration's body should be
  100% mutating-helper calls; actual text output happens once, at the
  tail of `crdkit.render`.
- Locked ("system") token declarations are asserted once, at the
  initial merge — not re-asserted after the chain. The chain is
  trusted, first-party code; only a consumer's own `tokens:` map is the
  untrusted boundary (already protected: `system` declarations replace
  consumer ones wholesale).
- `crdkit.render` doesn't read `context.Values`, and emits exactly
  `{{ model | toYaml }}` — whatever the chain put into `ctx.model`,
  substituted, is the output verbatim. Mapping consumer
  `Values`/labels/spec into `ctx.model` is entirely a specific library's
  preamble's job (see mdeploy's `mdeploy.integrations.copy`).

## Values schema

Library-supplied schema (literal YAML), validated by crdkit; node shape
in the file-level doc comment of `templates/_schema.tpl`.

- One node key, `type`, names both shape and scalar type: `string` /
  `int` / `number` / `bool` / `scalar` (any scalar) / `map` / `list` /
  `any`. `crdkit.schema.shape.internal` is the one place mapping a type
  to its shape (`scalar`/`map`/`list`/`any`); every walker reads the
  shape through it, never `.type` directly.

- Two passes: `crdkit.schema.validate` (structural, before the chain;
  returns normalized values — defaults applied, failing nodes dropped)
  and `crdkit.schema.validateValues` (per-target values for one target,
  after the chain). `crdkit.schema.value` checks one field for any
  target; a shared `seen` dict reports each `path|target` once. Its
  `path` must be built with `crdkit.schema.path` (same spelling as the
  value pass, or de-duplication misses).
- `crdkit.schema.resolve` returns a subtree of the normalized values
  (addressed by `keys`, followed like `crdkit.schema.node`) with every
  per-target value resolved. It runs the value pass's walker
  (`crdkit.schema.valuesWalk.internal`) with an `out` dict, so the check
  and the copy can never disagree about which nodes are per-target.
  Why: a library mapping whole subtrees into the model needs token
  declarations resolved, not copied as dicts.
  - Map → dict of children, list → list, `any` and plain scalars as
    written; per-target values resolved and checked once per
    `path|target` (shared `seen`), an `int` / `number` / `bool` result
    converted.
  - No value found for the target → the key is omitted (the resolution
    ERROR is recorded); a value failing its check is kept as resolved,
    unconverted; a marker to a token that does not exist yet stays as
    text.
  - A node the structural pass would drop is dropped; `keys` addressing
    nothing, or an invalid schema, give `{}`.
- `crdkit.schema.resolveAndCheck.internal` returns a resolved string
  of an `int` / `number` / `bool` node converted to that type (`atoi`,
  `float64`, `eq "true"`) when it passes the "parses as" check — on
  every call, independent of `seen`, so a repeated call returns the
  same value. A failing value or one still holding a marker (e.g. left
  for the final substitution pass) is returned unconverted.
- Severities: shape mismatch / unmatched switch → WARNING, ERROR on a
  `required: true` node (the required check reads the input as written
  and would miss the drop); unknown key → WARNING; required / type /
  enum / pattern / markers or a map in a `static` value → ERROR; every value-pass
  violation → ERROR naming the target. Static values are type-checked
  strictly, resolved values "parses as".
- Per-target: every non-static scalar-type or `list` node may be a
  token declaration (a dict, so in a map field it would be ambiguous),
  except below a per-target node, where only markers are allowed
  (`crdkit.schema.perTarget.internal`, the one place deciding it; every
  walker threads `inTokens`). `static: true` (scalar types only) marks a
  value used as written: no markers, never per-target, never below a
  per-target node (self-check ERROR; a switch case's `by` key excepted,
  `checkNode.internal` threads `switchBy`). `type` is the type after
  substitution. Other omitted
  keys: `type` → self-check ERROR (except a switch node), `required`
  false, `static` false, map without `values` closed, `items` any.
- `switch` uses `by:`, never `on:` — Helm's `fromYaml` speaks YAML 1.1
  and turns an `on:`/`yes:`/`no:` KEY into `true`/`false`. Applies to
  every schema or data key a library writes in literal YAML.
- Results travel through an `out` dict, not YAML, inside the walker — a
  YAML round-trip per level would re-decode every value.
- A shared accumulator param (`seen`) is guarded with
  `ternary .seen (dict) (kindIs "map" .seen)`, never `.seen | default
  dict`: an empty dict is falsy, so `default` would replace the
  caller's shared dict with a fresh one.
- `pattern`/`keys.pattern` use `mustRegexMatch` — an invalid
  library-owned regex aborts. A key failing `keys.pattern` → ERROR,
  dropped with its value. A `keys` map key that is a YAML 1.1 boolean
  word (`y/n/yes/no/on/off/true/false`, any case) → ERROR naming the
  parsed key, dropped, checked before the pattern.
- Consumer `match:` rules are validated in the structural pass
  (`crdkit.regexValid.internal`); an invalid one is an ERROR naming
  `'<path>.match[<i>]'` and is dropped.
- `keys.label` (optional string) is a documentation-only placeholder for
  a key matched by `values` (e.g. `<ID>`; default `<key>`); the self-check
  verifies it is a string, validation ignores it.

### Documentation

`crdkit.schema.document` (`{format, schemaText, example?, sections?,
title?, htmlLink?, id?, diag}`) is the one entry point: it makes one
`crdkit.schema.jsonSchema` call and feeds the text to the renderer of
`format` — `json` (the JSON Schema itself), `html`
(`crdkit.schema.html`, templates/_viewer.tpl) or `md`
(`crdkit.schema.docs`). Renderers read the JSON Schema, never the DSL.

- The schema arrives as TEXT (`include` of the library's schema define,
  not `fromYaml`): key order exists only in the text. Why: `fromYaml`
  yields a Go map, which loses it. `crdkit.schema.order.internal` records
  the text position of every block-style key (indentation stack; flow
  maps and block scalars skipped); it surfaces as `x-crdkit-order`, and
  keys without a position (flow maps) sort alphabetically after the
  positioned ones.
- JSON Schema is draft-07. DSL keywords map one to one (`type`,
  `properties`, `required`, `additionalProperties`, `propertyNames`,
  `enum`, `pattern`, `default`, `doc` → `description`/
  `markdownDescription`); everything else crdkit adds is an
  `x-crdkit-*` extension (order, per-target, shared properties,
  sections) that editors ignore.
- Per-target nodes are `anyOf` [type, `tokenDeclaration`], `markers`
  added only where a marker could violate the type (`int`/`number`/
  `bool`, `enum`, `pattern`); a static string/scalar carries `not:
  {$ref: markers}` (draft-07 ignores keywords next to a `$ref`). A
  switch case is a complete, closed schema under
  `definitions["<node path>[<by>=<case>]"]`, selected by `allOf` `if/then`;
  properties identical in every case carry `x-crdkit-shared`.
- `example` (a dict) fills `examples` on every node from the values found
  at its path; an unreached node gets a generated example (`default`,
  else the first `enum`, else a value per type), marked as generated.
- `sections` (`{<node path>: [{title, doc?, columns?, rows?, code?}]}`)
  are library-written tables and code blocks, attached by node path
  (`*` = a `values` key, `[]` = list items, `[<by>=<value>]` = switch
  case, e.g. `application.services.*[type=greeter]`). crdkit never
  interprets one; a malformed section or unknown path → ERROR, dropped.
- The HTML page is self-contained (no external request, system fonts,
  light/dark via `prefers-color-scheme`); the JSON Schema is embedded as
  `<script type="application/json" id="crdkit-schema">` in a fixed
  viewer shell, so a schema change changes only that JSON.
- `id` (optional string, `jsonSchema` and `document`) is emitted as the
  root `$id` when non-empty; a non-string → ERROR, ignored. The viewer's
  root page and the Markdown show `# yaml-language-server:
  $schema=<$id>` as a copy-ready modeline. Why: a consumer copies it
  instead of assembling a tagged URL by hand.
- An invalid schema: `jsonSchema` records the self-check ERRORs and
  returns `{}`; an unknown `format` → ERROR, empty output.
- The editor copy is committed as `input.schema.json`, never
  `values.schema.json`: Helm validates a chart's own values against that
  name on every install/template, which would apply a library's schema to
  the wrong scope. Editors accept per-target declarations and markers
  unchecked; the render stays the authority.

## Token model details

- Author-facing scalar declarations are normalized by
  `crdkit.tokens.merge.internal` into `{default: <value>}` immediately
  after merging, so `ctx.tokens[NAME]` is always a dict.
- Reserved dict keys (never target entries; list computed once by
  `crdkit.reservedKeys.internal`, carried as `ctx.reservedKeys`):
  - crdkit-internal, never author-written: `_value` (memoization
    cache), `_gen` (cache generation), `_generated` (values from
    `token.underlay`).
  - `match` (ordered `{pattern: replacement}` rules).
  - every token annotation name from `crdkit.render`'s `tokenAnnotations` param.
  Every other key, including `default`, IS a target entry.
- A token annotation named like an internal key, `match` or `default`
  records an ERROR (`token annotation name '<n>' collides with a
  crdkit-reserved key and was ignored`) and is dropped — `default` stays
  a target entry.
- Internal keys found in a `tokens`/`defaults`/`system` declaration are
  removed at merge time with a WARNING per key.
- A `system` declaration REPLACES a consumer declaration of the same
  name wholesale (merge order: defaults deep-merged with user, then
  system keys set over the result) — a deep merge would leave the
  consumer's extra target entries active under a "locked" token.
- `default` is also a hardcoded, last-resort fallback: checked directly
  after the parentTarget walk is exhausted, regardless of taxonomy —
  `{default: "db.internal", owner: payments}` resolves for any
  target, even under `crdkit.noParentTarget`. Checked AFTER the walk,
  never before — a token can have both a `default` entry and a
  taxonomy-reachable one, and the more specific value must win.
- Marker syntax: `@[A-Za-z0-9_.]+@`, defined once by
  `crdkit.markerPattern`; every marker match (substitution,
  unresolved scan, schema checks, JSON Schema `markers`) uses it. The
  `.` lets a library namespace token names (`<ID>.<field>`) and lets
  its relative form (`@.x@`) count as a marker in the schema passes.
  Text like `@example.com@` is a marker too.
- `AT` is crdkit's one built-in token name: a consumer declaration of
  it is dropped with a WARNING. `@AT@` renders as a literal `@`,
  replaced after every other marker — the escape for text that needs
  `@WORD@` literally. `crdkit.render` substitutes through
  `crdkit.tokens.substituteMarkers.internal` (no `@AT@` pass), scans
  for unresolved markers, then replaces `@AT@`: an escaped marker is
  never reported as a possible typo.
- crdkit checks no token names: naming policy belongs to a library's
  values schema (mdeploy: `keys.pattern` on `environment`).
- Diagnostic messages name a token by its bare name, never a
  `"tokens.NAME"`-prefixed path.
- Any scalar produced by a YAML-emitting `define` must be `| quote`d,
  even when empty — an unquoted empty scalar parses as YAML `null`, and
  `nil` flowing into `tokens.substitute`'s `replace` is a hard template
  error.

## Testing

`command make test` runs `deps` (dependency update of `tests/stub`,
not transitive), the framework suites, the lint and the
`docs/defines.md` freshness diff (`make docs` rewrites the file).

### Framework

Layout:
- `tests/stub/` — chart `stub` (dependency crdkit `file://../..`): a
  minimal library on crdkit's public API, so a contract test is values
  only.
  - `templates/_stub.tpl`: `stub.render` passes every `crdkit.render`
    param from `.Values` (`tokens`, `target`, `system`, `state`,
    `annotations` → `tokenAnnotations`, `diag` seed when the key is
    present, `ladder` → `parentTargetTemplate: stub.parentTarget`);
    `schema` + `input` run `crdkit.schema.validate` first, as a library
    does; `reportSeed: true` appends `seed: {errors: <n>}` (the caller's
    seed after the render).
  - `stub.ops`, the only chain entry, runs `.Values.ops` in order:
    `put`/`listExtend`/`ensureDictKey`/`hasPath` (model helpers);
    `add`/`underlay`/`annotate` (token writes); `tokenValue`/`tokenString`
    (with `target?`); `tokenDef`; `substitute`; `matchRules`;
    `info`/`names`/`markers`/`markerPattern`; `diag`/`diagLines`/
    `diagCount`; `state`; and the schema ops `check`, `validate`,
    `validateValues`, `resolve`, `schemaValue`, `node`, `path`;
    `labels`/`dependencyVersion`/`name`. `at` writes the result at a
    model path, so the final substitution applies to it.
  - `templates/docs.yaml`: `stub.docs` renders
    `crdkit.schema.document` from `.Values.docs` (gated; no `docs` key →
    nothing), `text` + decoded `json`, through the adapter.
  - `templates/_adapter.tpl`: `test.withDiagnostics` prints the render,
    then its `# ERROR|WARNING|INFO:` lines as data under
    `diagnostics: {error, warning, info}` (a level key only when it has
    lines; no `diagnostics` key on a clean render).
  - `templates/cr.yaml`: the adapter around `stub.render`.
- `tests/fixtures/base.yaml` — `target: b-01`, ladder `b-01 → b → ALL`.
- `tests/suites/*_test.yaml` — `helm unittest tests/stub -f
  '../suites/*_test.yaml'`; `values: [../fixtures/base.yaml]` + `set:`
  per test.
- `docs/requirements.md` — the C- requirement catalogue.

Assert rules:
- `it:` starts with the C- ids it covers, then F-/TC- ids:
  `"C-3 F-12: …"`; traceability = `grep -r C-3 tests/`.
- Diagnostics: level = `diagnostics.<level>`; fragment = a quoted
  identifier as the message quotes it, via `exists` + jsonpath regex
  `diagnostics.error[?(@ =~ /'T'/)]`. Never full message text.
- Counts (`lengthEqual`) only when the count is the requirement.
- "No diagnostics" = `notExists: {path: diagnostics}`.
- Structure: the one leaf or item the requirement names; lists via
  `contains … any: true`, order only when order is the requirement.
- Never a literal chart version; never a snapshot assert.
- Open finding: the target-form test with `skip: {reason: "F-n open
  (<feature>)"}`; the fix deletes the `skip` line.
- `set:` and `values:` files are YAML 1.2 in helm-unittest (`on:` stays
  a string); Helm reads values files as YAML 1.1.

Lint `scripts/lint.sh [--fail-define <define>] [--pending <file>]
[--regex-check-define <define>] [--library] [--scopes <list>]
[--internal-suffix] [--peer <templates dir>]... <templates dir>`
(POSIX sh + awk + `python3`; `{{/* … */}}` comments skipped; every
file under the dir; `--scopes`, `--internal-suffix` and `--peer` are
forwarded to the extractor):
- Text rules: `accumulator-default-dict` (`.diag`/`.seen`/`.acc`/
  `.out`/`.memo` piped to `default dict`), `fail-outside-render` (`fail`
  outside `--fail-define`; crdkit allows none),
  `unguarded-trailing-index` (a line that is only `{{- index A K -}}`
  without a preceding `if hasKey A K`), `non-must-regex-user-pattern`
  (a `regex*` call whose pattern is not a literal, a `$<name>Re` local
  or `crdkit.markerPattern`). `--regex-check-define` allows a variable
  pattern inside that define — crdkit passes
  `crdkit.regexValid.internal`, the one validity probe.
- Boundary rules (`--library`; crdkit owns these internals and never
  passes it): `boundary-ctx-tokens` (`ctx.tokens`),
  `boundary-token-keys` (`"_value"`, `"_gen"`, `"_generated"`),
  `boundary-diag-lists` (`diag.errors|warnings|infos`),
  `boundary-marker-regex` (the marker character class) and
  `boundary-internal-call` (include/template of a `crdkit.*.internal`).
- Extractor rules (`scripts/extract.py lint`; `--scopes` lists the
  chart's scopes, `--internal-suffix` ties `.internal` to the
  `internal` scope, `--peer` names another chart's defines for the doc
  rules): `define-naming`, `output-writes-ctx`,
  `mutator-undeclared-write`, `dead-define`, `doc-unknown-define`,
  `doc-names-caller`.
- Output: `FAIL <rule> <file>:<line>: <text>`, `PENDING (<reason>) …`,
  `FIXED? (<reason>) <rule> <file>` (a pending entry without a hit),
  then one `lint.sh: <n> hits, <f> failed, <p> pending` summary counting
  both groups. Exit 0 clean, 1 on FAIL or `FIXED?`, 2 usage or a missing
  `python3`. Paths print as given: run from the repo root.
- `tests/lint.pending`: lines `<rule> <file> <F-id> (<feature>)` (`#`
  comments); a matching hit is PENDING; a fix deletes its line.
- A rule must have zero false positives on current code; a rule that
  cannot is dropped, never given an exception list.

Sharp edges:
- helm-unittest's `set:` cannot index arrays (`modelOps[0].op`) — set
  the whole array.
- helm-unittest creates an empty `__snapshot__/` beside every suite
  (git-ignored).
- `.helmignore` must exclude `tests/`, `scripts/` and
  `__snapshot__/` (`.gitignore` does not affect `helm package` /
  `helm dependency update`; without it a downstream dependency update
  repackages the whole tree). Helm rejects `**`; a pattern without an
  inner `/` matches at any depth.

## Open / deferred

How a rendered CR's fields beyond what a specific library's preamble
sets map into a real CRD spec shape — blocked on the target CRD being
known.
