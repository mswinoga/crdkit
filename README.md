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
invalid nodes), checks per-target values for a target, and renders a
Markdown values reference. crdkit owns the engine; the schema itself —
literal YAML, usually from the library's own defines — is the
library's.

### Schema DSL

A schema is a tree of **nodes**; each node is a dict.

| Key | Applies to | Meaning | Omitted |
|---|---|---|---|
| `kind` | all | `scalar` \| `map` \| `list` \| `any` | self-check ERROR (a `switch` node is a map) |
| `doc` | all | Markdown text for the reference | allowed |
| `default` | all | value inserted when the key is absent | none |
| `required` | all | the key must be present | `false` |
| `type` | `scalar` | `string` \| `int` \| `number` \| `bool` | any scalar |
| `enum` | `scalar` | list of allowed values (compared as strings) | any |
| `pattern` | `scalar` | regex on the value's string form, unanchored | any |
| `markers` | `scalar` | `false` → a `@NAME@` marker is an ERROR | `true` |
| `tokens` | `scalar`, `list` | `true` → the value may be a token declaration | `true` (see below) |
| `properties` | `map` | `{<key>: <node>}` for named keys | none |
| `values` | `map` | node for every key not in `properties` | closed: other keys → WARNING |
| `keys` | `map` | `{pattern: <regex>}` for keys matched by `values` | any key |
| `items` | `list` | node for every element | `{kind: any}` |
| `switch` | node | `{by: <key>, cases: {<value>: <node>}}` | — |

Kinds:
- `scalar` — string, number or bool.
- `map` — `properties` and/or `values`; with neither, it accepts no
  keys.
- `list` — every element checked against `items`.
- `any` — accepts every value; nothing below it is checked. A map of
  anything is `{kind: map, values: {kind: any}}`.

Switch:
- A node with `switch` validates a map against the case named by the
  value of its `by` key; each case is a complete node.
- Every case must declare the `by` key as `kind: scalar, markers:
  false` — the case is chosen before anything is resolved.
- No case for the value, or no `by` key → WARNING, node dropped.
- The key is `by`, never `on`: Helm's `fromYaml` speaks YAML 1.1 and
  reads an `on:`/`yes:`/`no:` KEY as a boolean.

Per-target values (`tokens`):
- A per-target node's value may be a plain value or a token declaration
  (`default`, target keys, `match`), resolved for a target exactly like
  a token (see "Target escalation").
- Per-target by default on `scalar` and `list` — except a `markers:
  false` scalar (static) and any node below a per-target node. An
  explicit `tokens: false` opts out.
- Only `scalar`/`list`: a declaration is always a dict, so a dict in a
  scalar/list field is unambiguously a declaration
  (`{default: [a], prod: [a, b]}`); in a map field it would not be.
- At most one per-target node on any path from the root.

Defaults and required:
- `default` (on a `properties` entry) is inserted, as written, when the
  key is absent — also after its value was dropped as invalid. It may
  be a token declaration.
- `required: true` and `default` exclude each other.
- A `null` value counts as absent.

Example:

```yaml
kind: map
values: {kind: any}                       # the consumer chart's own keys
properties:
  target:     {kind: scalar, type: string, markers: false, required: true, doc: "Render target."}
  renderMode: {kind: scalar, markers: false, enum: [validate, deploy], default: deploy}
  services:
    kind: map
    keys: {pattern: "^[A-Z][A-Z0-9_-]*$"}
    values:
      switch:
        by: type
        cases:
          greeter:
            kind: map
            properties:
              type:     {kind: scalar, markers: false, required: true}
              enabled:  {kind: scalar, type: bool, markers: false, default: true}
              greeting: {kind: scalar, type: string, doc: "File content."}   # per-target
              ports:    {kind: list, items: {kind: scalar, type: int}}      # per-target list
```

### Self-check

`crdkit.schema.check` runs before every pass; an invalid schema skips
validation (values pass through unchanged). Each problem →
`# ERROR: schema invalid: <schema path>: <reason>`, recorded once
however often the schema is checked:
- a schema that failed to parse (Helm's `fromYaml` error dict);
- unknown node key, unknown `kind`/`type`, a key on a kind it doesn't
  apply to, a non-bool flag, a non-list `enum`, malformed
  `keys`/`switch`;
- `tokens: true` on `map`/`any`, below a per-target node, or with
  `markers: false`; `default` with `required: true`;
- a switch case not declaring its `by` key as a static scalar.

An invalid regex in `pattern`/`keys.pattern` aborts the render
(`mustRegexMatch`), like a `match:` rule.

### Passes

```
crdkit.schema.validate        values as written → normalized values      (before the chain)
crdkit.schema.validateValues  per-target values, for one target          (after the chain)
crdkit.schema.value           one field, any target, resolved + checked  (from an integration)
```

Structural pass (`crdkit.schema.validate`):
- Checks kinds, unknown keys, `required`, switches, `keys.pattern`, and
  `type`/`enum`/`pattern`/`markers` of static values.
- Returns `{value: <normalized>}`: defaults applied, every failing node
  dropped (so its default applies instead).
- Leaves per-target values for the value pass: a token declaration is
  kept as written; a string holding `@NAME@` markers skips
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
- Pass the same `seen` dict to `crdkit.schema.validateValues` and every
  `crdkit.schema.value` call: each `<path>|<target>` pair is checked and
  reported once. Build `path` with `crdkit.schema.path` (same `keys` as
  `crdkit.schema.node`), so it is spelled as the value pass spells it.

### Diagnostics

Paths are dotted values paths; a key containing `.` goes in brackets,
list elements are indexed: `services["a.b"].ports[0]`.

| Check | Level | Message |
|---|---|---|
| kind mismatch | WARNING | `'<path>' must be a map — ignored` |
| unknown key | WARNING | `'<path>' is not a known key — ignored` |
| key pattern | ERROR | `key '<path>' must match '<re>' — ignored` |
| switch, no key | WARNING | `'<path>' has no '<by>' — ignored` |
| switch, no case | WARNING | `'<path>.<by>' has unknown value '<v>' — ignored` |
| required | ERROR | `'<path>' is required` |
| type / enum / pattern | ERROR | `'<path>' must be of type 'int' — ignored` |
| markers | ERROR | `'<path>' must not contain '@NAME@' markers — ignored` |
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
| `crdkit.schema.value` | `{ctx, node, def, path, target?, seen?}` | YAML `{value: <resolved>}` |
| `crdkit.schema.path` | `{keys, path?}` | the dotted path as text |
| `crdkit.schema.docs` | `{schema, title?}` | Markdown text |

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

### Markdown reference

`crdkit.schema.docs` renders `# <title>` (default `Values`), one table
for the root, then one `## <path> with <by>: <case>` table per switch
case:

```markdown
| Key | Kind | Per target | Default | Required | Description |
| --- | --- | --- | --- | --- | --- |
| `renderMode` | scalar, one of: validate, deploy | no | `"deploy"` |  |  |
| `services.<key>` | map, by `type`: greeter |  |  |  |  |
| `target` | scalar (string) | no |  | yes | Render target. |
```

- Per target: `yes` (may be a token declaration), `markers` (may hold
  `@NAME@` markers), `no` (static).
- A `values` child shows as `<path>.<key>`, list items as `<path>[]`.
- Keys are sorted alphabetically — Go maps keep no order.

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
