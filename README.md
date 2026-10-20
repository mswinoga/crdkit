# crdkit

Generic Helm **library chart**: target-aware token resolution/
substitution, a diagnostics accumulator (never `fail()`s — emits
`# ERROR:`/`# WARNING:`/`# INFO:` comments instead), and an integration-chain
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
- `tokenAnnotations`: list of token annotation names — metadata the
  library attaches to token declarations, e.g. an owning service
  (optional; see "Token model")
- `diag`: optional `{errors, warnings, infos}` seed; crdkit appends to it and
  emits everything (the library can record its own pre-render
  diagnostics there)
- `chain`: ordered list of fully-qualified integration template names
- `parentTargetTemplate`: fully-qualified template name implementing the
  library's own target-escalation taxonomy (optional; defaults to no
  escalation)
- `state`: optional dict whose keys are copied into `ctx` for the
  library's own integrations (e.g. normalized input); a key colliding
  with a crdkit `ctx` key records an `# ERROR:` and is ignored

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
- `crdkit.model.hasPath` — `(list model key1 ... keyN)` returns the plain
  string `true` when the path exists (each intermediate node a map), an
  empty string otherwise: `{{ if include "crdkit.model.hasPath" (list
  .ctx.model "spec" "services") }}`.
- `crdkit.diag.error` / `crdkit.diag.warning` / `crdkit.diag.info` —
  `(list diag message)` append `message` to `diag.errors` /
  `diag.warnings` / `diag.infos` in place and return `""` (INFO: a valid
  outcome worth reporting, never a problem); an integration passes `.ctx.diag`:
  `{{- include "crdkit.diag.error" (list .ctx.diag "service 'X' is misconfigured") -}}`.
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
{{- $substitutedText := include "crdkit.tokens.substituteMarkers.internal" (list $ctx ($model | toYaml) $target) -}}
{{- $substitutedModel := $substitutedText | replace "@AT@" "@" | fromYaml -}}
```

crdkit never reads `context.Values`, so there's nothing else to
substitute — whatever a library wanted from consumer `Values` is
already in `ctx.model` by the time this runs. The "possible typo"
unresolved-marker check runs over the same text, before `@AT@` becomes
`@`.

- A marker is `@<name>@`, the name made of `A-Z a-z 0-9 _ .`
  (`@[A-Za-z0-9_.]+@`, crdkit.markerPattern.internal — the one
  definition every marker match uses). A dotted name (`@SVC1.host@`)
  is a marker like any other.
- `@AT@` renders as a literal `@`, after every other marker: write
  `@AT@example.com@` for text that would otherwise read as a marker
  (`@example.com@` alone is one, reported as a possible typo when no
  token has that name).
- A token resolving to a structure is spliced as text: a list as its
  elements joined by `,` (no space; a dict/list element as JSON), a
  dict as JSON. `L: {default: [a, b]}` → `"hosts=@L@"` → `hosts=a,b`.

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
  └─ crdkit.tokens.substituteMarkers.internal  (crdkit.render calls it directly)
       └─ crdkit.token.value
            └─ crdkit.resolveEntry.internal   (shared by token.* and tokenDef.*)
                 └─ crdkit.substituteStructure.internal
                      └─ crdkit.substituteText.internal → crdkit.resolveEntry.internal (per "@ref@")
       └─ crdkit.stringify.internal            (coerce for splicing into text)
```

## Resolving/substituting tokens directly

```gotemplate
{{/* resolve one REAL token by name, for a given target */}}
{{- $resolved := include "crdkit.token.value" (list $ctx "DB_HOST" $target) | fromYaml -}}
{{/* $resolved is {value: "..."} — a string, or a dict/list if the
     token's entry for this target is itself structural */}}

{{/* same thing, but always as a string (a list joined by ",", a dict as JSON) */}}
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
  - every token annotation name passed to `crdkit.render`
  Every other key, including `default`, IS a target entry.
- Resolving a token (`crdkit.token.value`) returns a separate shape,
  `{value}` — the interpolated result for one name+target pair (a
  string, or a structure if the selected entry is itself one).

```yaml
tokens:
  DB_HOST:
    owner: payments            # a token annotation (library passed tokenAnnotations: [owner])
    default: "db.internal"     # goes through the normal dedicated-attribute/match/parentTarget resolution
```

- `default` is also a hardcoded, last-resort fallback — checked
  directly regardless of taxonomy, even under `crdkit.noParentTarget`.
  A token with no `default` key that can't resolve for a target
  produces the ordinary "no value found" diagnostic, lazily.
- Token annotations are static metadata: crdkit stores them, never resolves
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
- Token names are not checked: a library sets its naming policy in its
  values schema (e.g. a `keys.pattern` on the map variables live in).

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

## Values schema

`templates/_schema.tpl` validates a library's consumer values against a
schema the library supplies, normalizes them (defaults, dropped
invalid nodes), checks per-target values for a target, and generates the values
documentation (JSON Schema, HTML viewer, Markdown). crdkit owns the engine; the schema itself —
literal YAML, usually from the library's own defines — is the
library's.

### Schema DSL

A schema is a tree of **nodes**; each node is a dict.

| Key | Applies to | Meaning | Omitted |
|---|---|---|---|
| `type` | all | the value's shape and scalar type (see "Types") | self-check ERROR (a `switch` node is a map) |
| `doc` | all | Markdown text for the reference | allowed |
| `default` | all | value inserted when the key is absent | none |
| `required` | all | the key must be present | `false` |
| `enum` | scalar types | list of allowed values (compared as strings) | any |
| `pattern` | scalar types | regex on the value's string form, unanchored | any |
| `static` | scalar types | `true` → the value is used as written: a `@NAME@` marker is an ERROR, never per-target | `false` |
| `properties` | `map` | `{<key>: <node>}` for named keys | none |
| `values` | `map` | node for every key not in `properties` | closed: other keys → WARNING |
| `keys` | `map` | `{pattern: <regex>, label?: <string>}` for keys matched by `values`; `label` is a documentation-only placeholder for a matched key (e.g. `<ID>`) | any key |
| `items` | `list` | node for every element | `{type: any}` |
| `switch` | node | `{by: <key>, cases: {<value>: <node>}}` | — |
| `targetKeys` | all | list of target keys a token declaration at or below the node may use (not `default`/`match`: always allowed); inherited, a descendant's own replaces it | declarations open (any key) |
| `annotations` | scalar types, `list` | list of annotation keys a token declaration at this node may use | none |

Types:

| `type` | Shape | Accepts |
|---|---|---|
| `string` \| `int` \| `number` \| `bool` | scalar | a scalar of that type |
| `scalar` | scalar | any scalar (string, number or bool) |
| `map` | map | `properties` and/or `values`; with neither, no keys |
| `list` | list | every element checked against `items` |
| `any` | — | every value; nothing below it is checked |

- "Scalar types" are the first five rows; a key on a type it doesn't
  apply to is a self-check ERROR (`'enum' does not apply to type
  'map'`).
- A map of anything is `{type: map, values: {type: any}}`.

Switch:
- A node with `switch` validates a map against the case named by the
  value of its `by` key; each case is a complete node.
- Every case must declare the `by` key as a scalar type with `static:
  true` — the case is chosen before anything is resolved.
- No case for the value, or no `by` key → WARNING, node dropped.
- The key is `by`, never `on`: Helm's `fromYaml` speaks YAML 1.1 and
  reads an `on:`/`yes:`/`no:` KEY as a boolean.

Per-target values:
- A per-target node's value may be a plain value or a token declaration
  (`default`, target keys, `match`), resolved for a target exactly like
  a token (see "Target escalation").
- Per-target on every scalar type and `list` node — except a `static:
  true` scalar and any node below a per-target node (there, markers
  only).
- Only scalar types/`list`: a declaration is always a dict, so a dict
  in a scalar/list field is unambiguously a declaration
  (`{default: [a], prod: [a, b]}`); in a map field it would not be.
- At most one per-target node on any path from the root.
- Declaration keys: with `targetKeys` in effect (the node's own, else
  the nearest ancestor's), a declaration may use those keys, `default`,
  `match` (a list of single-key maps `{<regex>: <value>}`) and the
  node's `annotations`; anything else is an ERROR, key dropped. An
  exact target is not a key: it goes in `match`. Without `targetKeys`
  any key is a target entry.
- Only consumer values are checked (`crdkit.schema.validate`); library
  token declarations never pass through the schema.

Defaults and required:
- `default` (on a `properties` entry) is inserted, as written, when the
  key is absent — also after its value was dropped as invalid. It may
  be a token declaration.
- `required: true` and `default` exclude each other.
- A `null` value counts as absent.

Example:

```yaml
type: map
values: {type: any}                       # the consumer chart's own keys
properties:
  target:     {type: string, static: true, required: true, doc: "Render target."}
  renderMode: {type: scalar, static: true, enum: [validate, deploy], default: deploy}
  services:
    type: map
    keys: {pattern: "^[A-Z0-9_]+$"}
    values:
      switch:
        by: type
        cases:
          greeter:
            type: map
            properties:
              type:     {type: scalar, static: true, required: true}
              enabled:  {type: bool, static: true, default: true}
              greeting: {type: string, doc: "File content."}   # per-target
              ports:    {type: list, items: {type: int}}      # per-target list
```

### Self-check

`crdkit.schema.check` runs before every pass; an invalid schema skips
validation (values pass through unchanged). Each problem →
`# ERROR: schema invalid: <schema path>: <reason>`, recorded once
however often the schema is checked:
- a schema that failed to parse (Helm's `fromYaml` error dict);
- unknown node key, an unknown or omitted `type`, a key on a type it
  doesn't apply to, a non-bool flag, a non-list `enum`, malformed
  `keys`/`switch`;
- `static` on a type other than a scalar type; `default` with
  `required: true`;
- a switch case not declaring its `by` key as a static scalar.

An invalid regex in `pattern`/`keys.pattern` aborts the render
(`mustRegexMatch`), like a `match:` rule.

### Passes

```
crdkit.schema.validate        values as written → normalized values      (before the chain)
crdkit.schema.validateValues  per-target values, for one target          (after the chain)
crdkit.schema.value           one field, any target, resolved + checked  (from an integration)
crdkit.schema.resolve         a values subtree, per-target values resolved (from an integration)
```

Structural pass (`crdkit.schema.validate`):
- Checks shapes, unknown keys, `required`, switches, `keys.pattern`, and
  `type`/`enum`/`pattern`/`markers` of static values.
- Returns `{value: <normalized>}`: defaults applied, every failing node
  dropped (so its default applies instead).
- Leaves per-target values for the value pass: a token declaration is
  kept as written (its keys checked when `targetKeys` are in effect); a
  string holding `@NAME@` markers skips
  `type`/`enum`/`pattern`.
- `type` is checked strictly on values as written (`"5"` is not an
  `int`; Helm decodes every number as float64, so an integral number
  is).

Value pass (`crdkit.schema.validateValues`):
- Resolves every per-target value (`crdkit.tokenDef.value`, field id =
  values path) and substitutes every string holding markers
  (`crdkit.tokens.substitute`), for one target, then checks the result.
- Checks "parses as": a native value or a string spelling the type
  (`"5"` and `"@BASE@0"` → `"40"` pass `int`; `true|false` pass
  `bool`; every scalar passes `string`).
- Skips a value whose resolution already recorded an ERROR (e.g. "no
  value found") or left a marker unresolved.
- Only follows what the structural pass keeps; pass it normalized
  values.
- Resolution substitutes markers at call time — tokens added later are
  not seen — and caches onto the declarations in the values (`_value`/
  `_gen`).

Single field (`crdkit.schema.value`):
- For library code that needs a field's value for a target other than
  the render's own (`qap1` while rendering `qa`): resolves it and checks
  it for that target. A static value is returned as written.
- Takes the field's node from `crdkit.schema.node`, which follows
  `properties`/`values`/list indices/switches through the values and
  makes the node's per-target state explicit.
- Returns a resolved string of an `int` / `number` / `bool` node
  converted to that type when it passes the check (`"@PORT@"` →
  `8080`, not `"8080"`), on every call; a value failing the check, or
  still holding a marker, comes back unconverted; `string` / `scalar`
  nodes come back as resolved.
- Pass the same `seen` dict to `crdkit.schema.validateValues` and every
  `crdkit.schema.value` call: each `<path>|<target>` pair is checked and
  reported once. Build `path` with `crdkit.schema.path` (same `keys` as
  `crdkit.schema.node`), so it is spelled as the value pass spells it.

Subtree (`crdkit.schema.resolve`):
- For library code that copies whole subtrees of the normalized values
  into the model: returns the subtree at `keys` (`[]` = root; same
  addressing as `crdkit.schema.node`) with every per-target value
  resolved for the target. Params: `{ctx, schema, values, keys?,
  target?, seen?}`; returns YAML `{value: <subtree>}`, `{}` when `keys`
  address nothing or the schema is invalid.
- Per-target nodes and strings with markers are resolved and checked
  like `crdkit.schema.validateValues` does (same walker, same `seen`),
  an `int` / `number` / `bool` result converted; `any` nodes and plain
  values are copied as written.
- No value for the target: the key is omitted (ERROR recorded). A value
  failing its check stays as resolved, unconverted. A marker to a token
  that does not exist yet stays as text for the final substitution pass.

```yaml
# values                              # resolve, keys [infra], target prod
infra:                                value:
  maxInstances: {ALL: 2, prod: 6}       maxInstances: 6
  startTimeout: "@START@"               startTimeout: 600   # START: "600", int node
```

### Diagnostics

Paths are dotted values paths; a key containing `.` goes in brackets,
list elements are indexed: `services["a.b"].ports[0]`.

| Check | Level | Message |
|---|---|---|
| shape mismatch | WARNING | `'<path>' must be a map — ignored` |
| unknown key | WARNING | `'<path>' is not a known key — ignored` |
| key pattern | ERROR | `key '<path>' must match '<re>' — ignored` |
| switch, no key | WARNING | `'<path>' has no '<by>' — ignored` |
| switch, no case | WARNING | `'<path>.<by>' has unknown value '<v>' — ignored` |
| required | ERROR | `'<path>' is required` |
| type / enum / pattern | ERROR | `'<path>' must be of type 'int' — ignored` |
| markers in a static value | ERROR | `'<path>' must not contain '@NAME@' markers — ignored` |
| declaration key | ERROR | `'<path>.<key>' is not a target key — ignored; allowed: <keys>; an exact target goes in 'match'` |
| declaration `match` | ERROR | `'<path>.match' must be a list of single-key maps {<regex>: <value>} — ignored` |
| value pass | ERROR | `'<path>' for target '<t>' must be of type 'int' — got '<v>'` |

In the value pass every violation except an unknown key is an ERROR.

### Templates

All take a dict.

| Template | Params | Returns |
|---|---|---|
| `crdkit.schema.check` | `{schema, diag}` | `true` or an empty string |
| `crdkit.schema.validate` | `{schema, values, diag, path?}` | YAML `{value: <normalized>}` |
| `crdkit.schema.validateValues` | `{ctx, schema, values, path?, target?, seen?}` | nothing |
| `crdkit.schema.node` | `{schema, values, keys}` | YAML `{value: <node>}` or `{}` |
| `crdkit.schema.resolve` | `{ctx, schema, values, keys?, target?, seen?}` | YAML `{value: <subtree>}` or `{}` |
| `crdkit.schema.value` | `{ctx, node, def, path, target?, seen?}` | YAML `{value: <resolved>}` |
| `crdkit.schema.path` | `{keys, path?}` | the dotted path as text |
| `crdkit.schema.document` | `{format, schemaText, example?, sections?, title?, htmlLink?, id?, diag}` | the text of one format (`json`, `html`, `md`) |
| `crdkit.schema.jsonSchema` | `{schemaText, example?, sections?, title?, id?, diag}` | JSON Schema text (draft-07) |
| `crdkit.schema.html` | `{schema, title?}` — `schema` is the JSON Schema text | HTML page |
| `crdkit.schema.docs` | `{schema, title?, htmlLink?}` — `schema` is the JSON Schema text | Markdown text |

- `path`: values path prefix of `values` in the consumer's input (e.g.
  `application`); messages are relative to the root otherwise.
- `target` defaults to `ctx.target`.
- `seen`: pass a dict you keep; an empty one is fine.

```gotemplate
{{- $schema := include "mylib.schema" . | fromYaml -}}
{{- $values := .Values | toYaml | fromYaml -}}
{{- $input := (include "crdkit.schema.validate" (dict "schema" $schema "values" $values "diag" $diag) | fromYaml).value -}}

{{/* later, from an integration */}}
{{- include "crdkit.schema.validateValues" (dict "ctx" .ctx "schema" $schema "values" $input "seen" $seen) -}}
{{- $node := (include "crdkit.schema.node" (dict "schema" $schema "values" $input "keys" (list "services" "APP" "greeting")) | fromYaml).value -}}
{{- $path := include "crdkit.schema.path" (dict "keys" (list "services" "APP" "greeting")) -}}
{{- $greeting := (include "crdkit.schema.value" (dict "ctx" .ctx "node" $node "def" $input.services.APP.greeting "path" $path "target" "qap1" "seen" $seen) | fromYaml).value -}}
```

### Documentation

`crdkit.schema.document` is the entry point: one call per format, each
making one `crdkit.schema.jsonSchema` call and feeding its text to the
renderer.

| `format` | Output | Renderer |
|---|---|---|
| `json` | JSON Schema, draft-07 | `crdkit.schema.jsonSchema` |
| `html` | one self-contained page | `crdkit.schema.html` |
| `md` | Markdown reference | `crdkit.schema.docs` |

- Params: `schemaText` (the schema as YAML text), `example`, `sections`,
  `title`, `htmlLink` (`md` only), `diag`. An unknown `format` records
  an ERROR and returns an empty string.
- The schema is passed as text because key order exists only there;
  the library's schema define is `include`d, not `fromYaml`-ed.
- `htmlLink`: URL of the HTML reference, linked from the Markdown title.
- `example`: example values (a dict, usually `.Values` of an example
  file). Every node gets `examples`, the values found at its path
  (through a `values` map: every entry; through a switch: the entries
  whose `by` key equals the case value). A node the example does not
  reach shows a generated example, marked as generated: `default`, else
  the first `enum` value, else a value per type.
- `sections`: `{<node path>: [{title, doc?, columns?, rows?, code?}]}`
  adds library-written tables and YAML blocks to a node. A node path is
  a values path with `*` for a `values` key, `[]` for list items and
  `[<by>=<value>]` for a switch case
  (`application.services.*[type=greeter]`). crdkit never interprets a
  section; a malformed one or an unknown path records an ERROR and is
  dropped.
- `keys.label` (schema) names a matched key in the tree, tables and
  skeleton (`<ID>`; default `<key>`).

```gotemplate
{{- $diag := dict "errors" (list) "warnings" (list) -}}
{{- $args := dict "schemaText" (include "mylib.schema" .) "example" $example "sections" $sections "title" "My values" "diag" $diag -}}
{{ include "crdkit.schema.document" (merge (dict "format" "html") $args) }}
```

### JSON Schema

`crdkit.schema.jsonSchema` turns the schema text into a draft-07 JSON
Schema for editors and the viewer; the DSL maps keyword by keyword
(`type`, `properties`, `required`, `additionalProperties`,
`propertyNames`, `enum`, `pattern`, `default`, `doc` →
`description`/`markdownDescription`).
- Key order is emitted as `x-crdkit-order`; flow-map keys sort
  alphabetically after the positioned ones.
- Per-target nodes are `anyOf` [type, `tokenDeclaration`, `markers`];
  with `targetKeys` in effect the declaration branch references a
  shared definition per key set and annotations (`targetDeclaration`,
  `targetDeclaration2`, …, `.<annotation>` appended): key names closed
  (`propertyNames` enum: target keys, `default`, `match`, annotations),
  `match` a list of single-key objects, values untyped (the value pass
  checks them per target), and the node carries
  `x-crdkit-targetKeys` / `x-crdkit-annotations`; the Markdown links
  its Per target cell to a final "Token declarations" section, the
  viewer lists the keys;
  a marker-accepting `int`/`number`/`bool`, or `string`/`scalar` with
  `enum` or `pattern`, is `anyOf` [type, `markers`]; `static: true` on a
  `string`/`scalar` adds a `not` pattern.
- A switch case is a complete, closed schema under
  `definitions["<node path>[<by>=<case>]"]`, selected by `allOf`
  `if/then`; properties identical in every case (two or more) carry
  `x-crdkit-shared`.
- `examples` and `x-crdkit-sections` come from `example` and `sections`.
- `id` (string, optional) becomes the root `$id`: the URL the committed
  file is served from, ideally pinned to a release tag (convention
  `v<chart version>`). Empty or absent → no `$id`; a non-string records an ERROR and is ignored.
- An invalid schema records the self-check ERRORs and returns `{}`.

Editor use:
- Commit the JSON as `input.schema.json` and point consumers at it with
  `# yaml-language-server: $schema=<URL>` in their values file. With
  `id` set to that URL, the viewer's root page and the Markdown show the
  ready-to-copy modeline.
- Never name it `values.schema.json`: Helm validates a chart's own
  values against that file on every install and template, so a library
  chart's copy would be applied to the subchart scope instead of the
  consumer's root.
- `x-crdkit-*` keywords are ignored by editors; strict validators (ajv
  `strict`) reject them — use `strict: false`.

Editor vs render (the render stays the authority; the editor is a typing
aid):

| Situation | Render | Editor |
|---|---|---|
| unknown key / unknown case | WARNING, dropped | error |
| static scalar type | strict | strict |
| per-target declaration | resolved and checked per target | accepted unchecked |
| marker in a non-string scalar | checked after substitution | accepted unchecked |
| `enum` | compared as strings | compared as typed |
| `pattern` | RE2 | ECMA-262 (same for the DSL's simple patterns) |

### HTML reference

`crdkit.schema.html` renders the JSON Schema text as one self-contained
page: no external request, system fonts, light and dark through
`prefers-color-scheme`, opens from disk.
- The schema is embedded as `<script type="application/json"
  id="crdkit-schema">`; the viewer shell is fixed, so a schema or
  example change changes only the embedded JSON.
- A tree of keys in schema order (type, required, per-target, default,
  first line of `doc`), switch cases as rows with their own pages,
  search, and a URL fragment per node path.
- Generated examples follow the same rules as the Markdown.
- With a `$id`, the root page shows the editor modeline.

### Markdown reference

`crdkit.schema.docs` renders the JSON Schema text:

- `# <title>` (default: the schema's title) and, with `htmlLink`, a link
  to the HTML reference;
- with a `$id` in the schema, an "Editor support" block holding the
  modeline `# yaml-language-server: $schema=<$id>`;
- a commented YAML skeleton: keys in schema order, type, `required` and
  `per target` as trailing comments, switch cases as `# <by>: <value>`
  blocks;
- one `## <path>` section per map node: its doc and a table of its keys,
  with only the columns that have content;
- one `## <node path>` section per switch case: doc, keys table (shared
  keys marked), the example (matching `example` entries wrapped in their
  ancestor keys, or a generated one marked `(generated)`), its
  sections.

```markdown
| Key | Type | Per target | Default | Required | Description |
| --- | --- | --- | --- | --- | --- |
| `target` | string | no |  | yes | Render target. |
| `renderMode` | string, one of: validate, deploy | no | `"deploy"` |  |  |
| `services` | map, keys match `^[A-Z]+$` |  |  |  | Services by ID. |
```

- Per target: `yes` (may be a token declaration), `markers` (may hold
  `@NAME@` markers), `no` (static).

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
