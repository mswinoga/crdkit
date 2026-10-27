# crdkit contract

Living catalogue of crdkit's contract with the libraries built on it.
Test names cite these ids: every `it:` starts with the ids it covers
(`grep -r <id> tests/`). Ids are stable: never renumbered or reused.

- Entry: `**<id>** · <class> — <behavior>`.
- Class:
  - `contract` — public crdkit↔library behavior, tested;
  - `incidental` — exists, not guaranteed, untested by rule.
- Diagnostics: `E` = `# ERROR:`, `W` = `# WARNING:`, `I` = `# INFO:`.
  A diagnostic is identified by its level, the name/path it names and
  the quoted fragment; the rest of the wording is incidental.
- `Open: <F-/Q- id> (<feature>)` — crdkit 0.1.0 still behaves
  differently; the entry states the target. The named feature
  (`docs/<feature>/`) fixes it and deletes the marker; its tests are
  committed with `skip:` / `# pending:`. Ids refer to
  `../docs/architecture-review/` (workspace) (F- findings, Q- decisions).

## Contracts

- **C-1** · contract — `crdkit.render {context, tokens, target, system,
  defaults, parentTargetTemplate, chain, tokenAnnotations, diag, state,
  trace?, schemaChecks?}` → CR YAML + diagnostics; never reads `.Values`; `ctx.model`
  is built only by the chain.
- **C-2** · contract — `state` keys are copied into ctx; a key colliding
  with a crdkit ctx key → E naming the key, "collides with a crdkit ctx
  key"; ignored.
- **C-3** · contract — The `diag` seed is transported and appended to in
  place, an empty seed included; missing lists are created; diagnostics
  are emitted after the model.
- **C-4** · contract — Chain: integrations are called in list order with
  the shared, mutable ctx; visibility is order-dependent.
- **C-5** · contract — `crdkit.dictMerge [model, k1..kN, value]`: creates
  missing levels, `mergeOverwrite` at the end (N ≥ 0); returns `""`.
- **C-6** · contract — `crdkit.diag.error|warning|info [diag, msg]`
  append in place, creating the level's list when missing; return `""`.
- **C-7** · contract — One substitution pass over the model after the
  chain; typo scan before `@AT@`; marker grammar `@[A-Za-z0-9_.]+@`.
  Substituted values are kept verbatim: quotes and newlines survive and
  never alter the model's structure.
- **C-8** · contract — Token declarations: scalar → `{default: v}`;
  reserved keys `_value`, `_gen`, `_generated`, `match`, every
  annotation; consumer-written internal keys → W naming the token and
  key, "crdkit-internal key"; removed.
- **C-9** · contract — `system` declarations replace consumer ones
  wholesale (W naming the token, "reserved by the library"); `AT` cannot
  be redefined.
- **C-10** · contract — `tokenAnnotations`: reserved, stored, never
  resolved; a name equal to `_value|_gen|_generated|match|default` → E
  naming it, "collides with a crdkit-reserved key"; ignored.
- **C-11** · contract — Resolution order: exact-target key → `match`
  (exact target) → parent walk (one key per rung) → `default` →
  `_generated[exact target]` → E "no value found".
- **C-12** · contract — `parentTargetTemplate` receives `{target,
  context}`, returns the next rung or empty; a revisited rung → E naming
  the rung and start target, "cycles back to".
- **C-13** · contract — Resolution is lazy and memoized;
  `token.add`/`underlay` invalidate earlier results. Observable only as
  re-resolution after C-14/C-15; cache shape and rung caching are not
  contract.
- **C-14** · contract — `crdkit.token.add [ctx, name, value,
  annotations?, target?]`: exact-target entry, annotations merged over;
  non-dict annotations → E naming the token, "annotations must be a
  dict"; an undeclared annotation key → E naming the token and key,
  "not a token annotation"; ignored.
- **C-15** · contract — `crdkit.token.underlay`: lowest-priority
  generated value for the exact target; annotations only where absent;
  an undeclared annotation key → E, dropped; creates the token.
- **C-16** · contract — `crdkit.token.string` / `token.value` `[ctx,
  name, target?]`; `value` returns `{value}`; unknown name → E naming it,
  "unknown token".
- **C-17** · contract — `crdkit.tokens.substitute [ctx, text, target?]`
  replaces known markers and `@AT@`; unknown markers untouched.
- **C-18** · contract — `crdkit.matchRules {subject, rules, diag?,
  label?}` → `{matched, value}`, full-string anchored, first match wins;
  a non-string replacement (number, bool) is its string form.
  With `diag`, an invalid consumer regex → E naming the label and the
  rule, the rule skipped (validity checked before matching); no template
  abort. Without `diag` (library-owned rules) an invalid regex aborts.
  Schema `pattern`/`keys.pattern` still abort.
- **C-19** · contract — Schema DSL (node keys `type`, `doc`, `default`,
  `required`, `enum`, `pattern`, `static`, `properties`, `values`,
  `keys{pattern,label}`, `items`, `switch{by,cases,unless}`,
  `targetKeys`, `annotations`) and its self-check (E "schema invalid"
  with path and reason, once; an invalid schema skips validation); a
  declaration `match` rule's regex is checked too (E naming
  `'<path>.match[<i>]'`, rule dropped).
- **C-20** · contract — Per-target rule: scalar/list nodes at the topmost
  level on a path, not `static`; at most one per path; `targetKeys`
  inherited.
- **C-21** · contract — `switch.unless`: a hit is checked as `by` + `key`
  only, other keys dropped silently.
- **C-22** · contract — `crdkit.schema.validate {schema, values, diag,
  path?}` → `{value: normalized}`; a `keys` map key that is a YAML 1.1
  boolean word (`y/n/yes/no/on/off/true/false`, any case) → E naming the
  parsed path, dropped; `match` rules' regexes are checked here.
- **C-23** · contract — `crdkit.schema.validateValues {ctx, schema,
  values, path?, target?, seen?}`: value pass, each `<path>|<target>`
  once via shared `seen`; skips values whose resolution already recorded
  an ERROR.
- **C-24** · contract — `crdkit.schema.value {ctx, node, def | token,
  path, target?, seen?}`: one field resolved + checked, `int|number|bool`
  converted on every call; `token` is always resolved as
  `crdkit.token.value` does, diagnostics naming `path`, then the same
  conversion; diagnostics (resolution and check) once per `seen` entry.
- **C-25** · contract — `crdkit.schema.resolve {ctx, schema, values,
  keys?, target?, seen?}`: subtree with per-target values resolved; no
  value → key omitted; unknown-token markers left.
- **C-26** · contract — `crdkit.schema.node {schema, values, keys}`
  (follows switches, adds `perTarget`) and `crdkit.schema.path {keys,
  path?}` (`a.b`, `a["b.c"]`, `a[0]`).
- **C-27** · contract — `crdkit.standardLabels {context}`,
  `crdkit.dependencyVersion {name, context}` (`unknown` if absent).
- **C-28** · contract — Docs pipeline: `crdkit.schema.document {format
  json|html|md, schemaText, example?, sections?, title?, htmlLink?, id?,
  diag}`; unknown format → E; key order from the schema text; sections
  by node path, malformed → E, dropped; HTML self-contained. Callable
  from a library's templates (a library generates its docs through it).
- **C-29** · contract — `defaults` param of `crdkit.render` (a library
  may pass `{}` and put its library tokens in `system`).
- **C-30** · contract — `crdkit.listExtend`, `crdkit.ensureDictKey`,
  `crdkit.model.hasPath`.
- **C-31** · incidental — `crdkit.tokenDef.value|string` (used internally
  by the schema value pass), `crdkit.token.value` called directly.
- **C-32** · contract — `crdkit.name`, `crdkit.noParentTarget` (default
  `parentTargetTemplate`), `crdkit.integrations.chain {chain, ctx,
  trace?}` (with `trace`, one snapshot per stage).
- **C-33** · contract — Exact-target literal keys in token declarations
  (libraries closing keys via `targetKeys` leave them to library code).
- **C-34** · incidental — `crdkit/values.schema.json` is `{}`: the
  crdkit chart constrains no values.
- **C-35** · contract — `crdkit.token.annotate [ctx, name,
  annotations]`: sets each declared annotation key (overwrite), no
  resolution effect; unknown token / non-dict / undeclared key → E,
  ignored.
- **C-36** · contract — `crdkit.token.info [ctx, name]` → `{exists,
  annotations}` (declared keys present on the declaration only; missing
  token → `exists: false`, no diagnostic).
- **C-37** · contract — `crdkit.token.names {ctx, annotation?, equals?}`
  → `{value: [names, sorted]}`.
- **C-38** · contract — `crdkit.markerPattern {group?}` (the one marker
  regex) and `crdkit.markers {value}` → `{value: [names]}` (string
  leaves only, map keys excluded, first-occurrence dedup, `AT` excluded).
- **C-39** · contract — `crdkit.diag.lines {diag, levels?}` (ERROR →
  WARNING → INFO, de-duplicated, no leading/trailing newline) and
  `crdkit.diag.count {diag, level}` (distinct count).
- **C-40** · incidental — `crdkit.render` `trace` and
  `scripts/trace.sh`: developer tooling, untested by rule.
