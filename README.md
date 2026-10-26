# crdkit

Generic Helm **library chart** for libraries that render one Custom
Resource: target-aware token resolution and substitution, a diagnostics
accumulator (it never `fail()`s; problems are `# ERROR:` / `# WARNING:`
/ `# INFO:` comments), an integration-chain dispatcher and a values
schema engine with generated documentation.

crdkit knows no CRD and no "environment"/"family"/"tier": `target` is an
opaque string. A specific library (e.g. `mdeploy`) supplies all of that
and wraps `crdkit.render`.

## Who should depend on this

A CRD-rendering library chart (`mdeploy` in this workspace), never an
app repo directly; app repos depend on the library (`mdeploy/README.md`).

<!-- example: docs/readme-examples/usage render=none -->
```yaml
# mdeploy's Chart.yaml
dependencies:
  - name: crdkit
    version: "0.2.1"
    repository: "file://../crdkit"
```
<!-- /example -->

## What a library supplies to `crdkit.render`

Everything product-specific arrives as a param; exact shape in
`crdkit.render`'s doc comment ([`docs/defines.md`](docs/defines.md#crdkit.render)).

- `tokens`, `system`, `defaults`: token declarations — the consumer's,
  the library's locked ones, the library's defaults.
- `chain`: the integration template names, called in order.
- `parentTargetTemplate`: the library's target-escalation hook
  (optional; default: no escalation).
- `tokenAnnotations`: names of library metadata on token declarations
  (e.g. an owning service).
- `diag`: optional seed `{errors, warnings, infos}`; crdkit appends and
  prints it after the model.
- `state`: keys copied into `ctx` for the library's integrations; a key
  colliding with a crdkit `ctx` key is an ERROR, ignored.
- `trace`: an optional caller-owned dict collecting one `ctx` snapshot
  per stage; `scripts/trace.sh` prints the changed leaves.
- `schemaChecks`: an optional dict also passed to
  `crdkit.schema.validate`, so the schema self-check runs once per
  render.
- crdkit never reads `.Values` and sets nothing of the CR's shape: the
  chain builds `ctx.model`, and the output is that model, substituted.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-1,
  C-2, C-3; [not used by mdeploy](docs/requirements.md#not-used-by-mdeploy-templates)
  — C-29, C-32, C-40.

## Integration chain and the model

<!-- sketch -->
```gotemplate
{{- define "mylib.integrations.preamble" -}}
{{- include "crdkit.dictMerge" (list .ctx.model (dict "apiVersion" "@API_GROUP@/v1" "kind" "SomeCR")) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" (dict "name" .ctx.root.Release.Name)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" "labels" (dig "metadata" "labels" (dict) .ctx.root.Values)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "metadata" "labels" (include "crdkit.standardLabels" (dict "context" .ctx.root) | fromYaml)) -}}
{{- include "crdkit.dictMerge" (list .ctx.model "spec" (.ctx.root.Values.spec | default dict)) -}}
{{- end -}}
```

- Every integration receives the shared `ctx` (`root`, `diag`, `model`,
  `tokens`, `target`, … plus the `state` keys) and mutates it in place;
  a field set by one integration is visible only to the ones after it.
- `ctx.model` starts empty. The library's first integration (by
  convention a "preamble") builds the CR shape; a missing preamble
  gives an empty-ish CR, not an error.
- Write the model with `crdkit.dictMerge` (zero or more keys),
  `crdkit.listExtend` and `crdkit.ensureDictKey`; test a path with
  `crdkit.model.hasPath` (`true` or empty).
- Record diagnostics with `crdkit.diag.error|warning|info [diag, msg]`
  (an integration passes `.ctx.diag`); read them with `crdkit.diag.lines`
  and `crdkit.diag.count`. INFO is a valid outcome worth reporting.
- These helpers return `""`, so a bare `{{- include … -}}` is safe; an
  integration never prints YAML itself.
- Order is precedence: in the sketch, consumer labels first, standard
  labels win on collision, later integrations can override anything.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-4,
  C-5, C-6, C-27, C-39; [not used by mdeploy](docs/requirements.md#not-used-by-mdeploy-templates)
  — C-30.

## Substitution

<!-- example: docs/readme-examples/tokens-substitute -->
```yaml
# docs/readme-examples/tokens-substitute.yaml
target: prod-01
ladder: {qa-01: qa, prod-01: prod, qa: NONPROD, prod: ALL, NONPROD: ALL}
tokens:
  DB_HOST: {NONPROD: db.qa.acme.com, prod: db.acme.com}
```
```gotemplate
{{ include "crdkit.tokens.substitute" (list $ctx "@DB_HOST@ is up; mail ops@AT@acme.com") }}
```
```yaml
db.acme.com is up; mail ops@acme.com
```
<!-- /example -->

- One pass over every string of `ctx.model` after the chain; map keys
  are never substituted, non-string scalars pass through.
- A marker is `@<name>@`, the name of `A-Z a-z 0-9 _ .`
  (`crdkit.markerPattern`, the one definition); `crdkit.markers` lists
  the names in a value.
- A marker with no token stays as text, with a "possible typo" WARNING.
- `@AT@` is a literal `@`, replaced after every other marker:
  `ops@AT@acme.com` stays text even though `@acme.com@` would be a
  marker.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-7,
  C-17, C-38.

## Resolving tokens

Resolve one token for a target other than the render's own:

<!-- example: docs/readme-examples/token-value -->
```yaml
# docs/readme-examples/token-value.yaml
target: prod-01
ladder: {qa-01: qa, prod-01: prod, qa: NONPROD, prod: ALL, NONPROD: ALL}
tokens:
  DB_HOST:
    NONPROD: db.@ENV@.acme.com
    prod: db.acme.com
  ENV: {qa: qa, prod: prod}
```
```gotemplate
{{ include "crdkit.token.value" (list $ctx "DB_HOST" "qa-01") }}
```
```yaml
value: db.qa.acme.com
```
<!-- /example -->

`qa-01` walks `qa-01 → qa → NONPROD`; `@ENV@` resolves for the same target.

The same token as text (a list joins with `,`, a dict is JSON):

<!-- example: docs/readme-examples/token-string -->
```yaml
# docs/readme-examples/token-string.yaml
target: prod-01
ladder: {qa-01: qa, prod-01: prod, qa: NONPROD, prod: ALL, NONPROD: ALL}
tokens:
  HOSTS:
    default: [db-1.acme.com, db-2.acme.com]
    qa: [db.qa.acme.com]
```
```gotemplate
{{ include "crdkit.token.string" (list $ctx "HOSTS") }}
```
```yaml
db-1.acme.com,db-2.acme.com
```
<!-- /example -->

A structure from consumer values, resolved by the token rules without
being a token (markers inside still name real tokens):

<!-- example: docs/readme-examples/tokendef-value -->
```yaml
# docs/readme-examples/tokendef-value.yaml
target: prod-01
ladder: {qa-01: qa, prod-01: prod, qa: NONPROD, prod: ALL, NONPROD: ALL}
tokens:
  DB_HOST: {NONPROD: db.qa.acme.com, prod: db.acme.com}
```
```gotemplate
{{ include "crdkit.tokenDef.value" (list $ctx "myField" (dict "default" "generic" "prod" "special-@DB_HOST@")) }}
```
```yaml
value: special-db.acme.com
```
<!-- /example -->

- Entry points take `ctx` first and `target` last, optional (default:
  the render's target).
- `crdkit.token.value` / `crdkit.tokenDef.value` return `{value}` (a
  string or a structure, string leaves substituted); `*.string` and
  `crdkit.tokens.substitute` return text.
- Resolution is lazy and memoized per target: a token resolves (and is
  diagnosed) only when something uses it; adding a token invalidates
  earlier results.
- Order: exact-target key → `match:` rules (exact target only) →
  the library's parent walk → `default` → a generated value → ERROR
  "no value found".
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-11,
  C-13, C-16; [not used by mdeploy](docs/requirements.md#not-used-by-mdeploy-templates)
  — C-31.

## Target escalation

<!-- sketch -->
```gotemplate
{{- define "mylib.parentTarget" -}}
{{- $chain := dict "qa-01" "qa" "qa" "QA" "QA" "NONPROD" "prod-01" "prod" "prod" "PROD" -}}
{{- if hasKey $chain .target -}}
  {{- index $chain .target -}}
{{- end -}}
{{- end -}}
```

- The library passes the hook's name as `parentTargetTemplate`; crdkit
  calls it with `{target, context}` and walks until it returns nothing.
  `crdkit.matchRules` helps build pattern-based hops.
- Every rung is a plain key of the declaration; `match:` applies to the
  exact target only, before the walk.
- A rung that comes back to an earlier one is an ERROR.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-11,
  C-12, C-18; [not used by mdeploy](docs/requirements.md#not-used-by-mdeploy-templates)
  — C-33.

## Token model

<!-- sketch -->
```yaml
tokens:
  DB_HOST:
    owner: payments            # a token annotation (tokenAnnotations: [owner])
    default: "db.internal"
    prod: "db.acme.com"        # a target key
    match: [{"^qa-0[12]$": "db-qa-early.acme.com"}]
```

- A declaration is a scalar (every target) or a dict: target keys,
  `default`, `match`, the library's annotations; `_value`, `_gen`,
  `_generated` are crdkit's (written by a consumer: WARNING, removed).
- `system` declarations replace consumer ones of the same name
  wholesale; `AT` cannot be declared.
- Annotations are static metadata crdkit stores and never interprets;
  a library reads and writes them only through `crdkit.token.annotate`,
  `crdkit.token.info` and `crdkit.token.names`. An annotation named
  like a reserved key is an ERROR, ignored.
- crdkit checks no token names: a library sets its naming policy in its
  values schema (`keys.pattern`).
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-8,
  C-9, C-10, C-35, C-36, C-37.

### Adding tokens from an integration

A generated value (`crdkit.token.underlay`) is the lowest source: the
consumer's `qa` entry wins in `qa-01`, the generated value serves
`prod-01`:

<!-- example: docs/readme-examples/token-underlay target=qa-01,prod-01 -->
```yaml
# docs/readme-examples/token-underlay.yaml
target: prod-01
ladder: {qa-01: qa, prod-01: prod, qa: NONPROD, prod: ALL, NONPROD: ALL}
annotations: [owner]
tokens:
  DB_HOST: {NONPROD: db.qa.acme.com, prod: db.acme.com}
  DB_URL: {qa: "jdbc:custom-qa"}
```
```gotemplate
{{- include "crdkit.token.underlay" (list $ctx "DB_URL" "jdbc:@DB_HOST@" (dict "owner" "payments")) -}}
{{ include "crdkit.token.value" (list $ctx "DB_URL") }}
```
```yaml
# qa-01
value: jdbc:custom-qa
```
```yaml
# prod-01
value: jdbc:db.acme.com
```
<!-- /example -->

- `crdkit.token.add [ctx, name, value, annotations?, target?]` stores
  the value as the exact target's entry, resolved lazily (it may name a
  token a later integration adds); annotations merge over the existing
  ones.
- `crdkit.token.underlay` (same params) stores a generated value for the
  exact target, sets only missing annotations and creates a missing
  token.
- Non-dict annotations or an undeclared annotation key: ERROR, ignored.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-14,
  C-15.

## Values schema

crdkit validates a library's consumer values against a schema the
library supplies (literal YAML, usually its own define), normalizes
them, checks per-target values for a target and generates their
documentation (JSON Schema, HTML viewer, Markdown).

### Schema DSL

<!-- sketch -->
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

| Key | Applies to | Meaning | Omitted |
|---|---|---|---|
| `type` | all | shape and scalar type after substitution | self-check ERROR (a `switch` node is a map) |
| `doc` | all | Markdown text for the reference | allowed |
| `default` | all | value inserted when the key is absent (or dropped as invalid) | none |
| `required` | all | the key must be present | `false` |
| `enum` | scalar types | allowed values (compared as strings) | any |
| `pattern` | scalar types | regex on the string form, unanchored | any |
| `static` | scalar types | `true`: used as written — no marker, no token declaration | `false` |
| `properties` | `map` | `{<key>: <node>}` for named keys | none |
| `values` | `map` | node for every other key | closed: other keys → WARNING |
| `keys` | `map` | `{pattern, label?}` for the keys `values` matches; `label` names them in the docs (`<ID>`) | any key |
| `items` | `list` | node for every element | `{type: any}` |
| `switch` | node | `{by: <key>, cases: {<value>: <node>}, unless?: {key, value}}` | — |
| `targetKeys` | all | keys a token declaration at or below may use (plus `default`, `match`); inherited | declarations open |
| `annotations` | scalar types, `list` | annotation keys a declaration here may use | none |

| `type` | Shape | Accepts |
|---|---|---|
| `string` \| `int` \| `number` \| `bool` | scalar | a scalar of that type |
| `scalar` | scalar | any scalar |
| `map` | map | `properties` and/or `values`; with neither, no keys |
| `list` | list | every element checked against `items` |
| `any` | — | anything; nothing below it is checked |

- Per target: every non-`static` scalar or `list` node may hold a token
  declaration (resolved like a token); below such a node only markers.
- `switch` picks the case by the value of its `by` key (a static scalar
  in every case); no case or no key → WARNING, node dropped.
  `unless: {key, value}` checks a matching map as `by` + `key` only (a
  disabled entry may stay incomplete).
- Keys are `by` and `unless`, never `on`/`off`: Helm reads YAML 1.1, and
  a `keys` map key that is a YAML 1.1 boolean word is an ERROR.
- Only consumer values pass through the schema; library declarations
  never do. `null` counts as absent.
- The schema is self-checked before every pass; an invalid one skips
  validation and records each problem once. An invalid `pattern` aborts
  the render (library-owned); an invalid consumer `match:` regex is an
  ERROR, rule skipped.
- Messages: [`docs/diagnostics.md`](docs/diagnostics.md). Exact rules:
  [contract](docs/requirements.md#used-by-mdeploy) — C-19, C-20, C-21,
  C-22.

### Passes

The value of a subtree for one target, with per-target values resolved
and `int` nodes converted (`START` is `"600"`):

<!-- example: docs/readme-examples/schema-resolve -->
```yaml
# docs/readme-examples/schema-resolve.yaml
target: prod-01
ladder: {qa-01: qa, prod-01: prod, qa: NONPROD, prod: ALL, NONPROD: ALL}
tokens:
  START: "600"
schema:
  type: map
  properties:
    infra:
      type: map
      properties:
        maxInstances: {type: int}
        startTimeout: {type: int}
input:
  infra:
    maxInstances: {ALL: 2, prod: 6}
    startTimeout: "@START@"
```
```gotemplate
{{ include "crdkit.schema.resolve" (dict "ctx" $ctx "schema" $ctx.schema "values" $ctx.input "keys" (list "infra")) }}
```
```yaml
value:
  maxInstances: 6
  startTimeout: 600
```
<!-- /example -->

<!-- sketch -->
```
crdkit.schema.validate        values as written → normalized values        (before the chain)
crdkit.schema.validateValues  per-target values, for one target            (after the chain)
crdkit.schema.value           one field, any target, resolved + checked    (from an integration)
crdkit.schema.resolve         a values subtree, per-target values resolved (from an integration)
```

- `crdkit.schema.validate` checks shapes, keys, `required`, switches
  and static values strictly (`"5"` is no `int`), returns the values
  with defaults applied and failing nodes dropped, and leaves per-target
  values for later.
- `crdkit.schema.validateValues` resolves and checks every per-target
  value for one target ("parses as": `"5"` passes `int`); pass it the
  normalized values.
- `crdkit.schema.value` resolves one field for any target (e.g. `qap1`
  while rendering `qa`); take its node from `crdkit.schema.node` and its
  path from `crdkit.schema.path`.
- `crdkit.schema.resolve` returns a subtree resolved for the target: no
  value → key omitted (ERROR), a failing value kept unconverted.
- Share one `seen` dict across the value-pass calls: each
  `<path>|<target>` is checked and reported once.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-23,
  C-24, C-25, C-26.

### Templates

All take a dict; exact params and returns in each doc comment
([`docs/defines.md`](docs/defines.md)).

- `crdkit.schema.check` — the self-check (`true` or empty).
- `crdkit.schema.validate` — structural pass → `{value: <normalized>}`.
- `crdkit.schema.validateValues` — value pass for one target.
- `crdkit.schema.node` / `crdkit.schema.path` — a node and its values
  path for `keys`.
- `crdkit.schema.value` / `crdkit.schema.resolve` — one field / one
  subtree, resolved for a target.
- `crdkit.schema.document` — one documentation format (below).
- `path` (validate, validateValues) prefixes messages with the values'
  location in the consumer input (e.g. `application`).

<!-- sketch -->
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

One `crdkit.schema.document` call per format: `json` (JSON Schema,
draft-07), `html` (a self-contained viewer) or `md` (a Markdown
reference). The Markdown of a small schema:

<!-- example: docs/readme-examples/schema-docs-md lang=markdown -->
```yaml
# docs/readme-examples/schema-docs-md.yaml
target: prod-01
state:
  schemaText: |
    type: map
    doc: Example values.
    properties:
      target:     {type: string, static: true, required: true, doc: "Render target."}
      renderMode: {type: string, static: true, enum: [validate, deploy], default: deploy}
      replicas:   {type: int, doc: "Instances per target."}
```
```gotemplate
{{ include "crdkit.schema.document" (dict "format" "md" "schemaText" $ctx.schemaText "title" "My values" "diag" $ctx.diag) }}
```
````markdown
# My values

```yaml
target:  # string, required
renderMode:  # string
replicas:  # int, per target
```

## (root)

Example values.

| Key | Type | Per target | Default | Required | Description |
| --- | --- | --- | --- | --- | --- |
| `target` | string | no |  | yes | Render target. |
| `renderMode` | string, one of: validate, deploy | no | `"deploy"` |  |  |
| `replicas` | int | yes |  |  | Instances per target. |
````
<!-- /example -->

- Pass the schema as text (`include` of the schema define, not
  `fromYaml`): key order exists only in the text.
- `example` (values, a dict) fills the reference's examples; a node it
  does not reach gets a generated one, marked as such.
- `sections` (`{<node path>: [{title, doc?, columns?, rows?, code?}]}`)
  adds library-written tables and blocks to a node; a node path uses
  `*` for a `values` key, `[]` for list items, `[<by>=<value>]` for a
  switch case. A malformed section is an ERROR, dropped.
- `htmlLink` (md) links the HTML reference from the title; `id` becomes
  the JSON Schema `$id`.
- Problems go to `diag`, never into the text; an unknown format is an
  ERROR and renders nothing.
- Exact rules: [contract](docs/requirements.md#used-by-mdeploy) — C-28.

<!-- sketch -->
```gotemplate
{{- $diag := dict "errors" (list) "warnings" (list) -}}
{{- $args := dict "schemaText" (include "mylib.schema" .) "example" $example "sections" $sections "title" "My values" "diag" $diag -}}
{{ include "crdkit.schema.document" (merge (dict "format" "html") $args) }}
```

### Editor support

- Commit the `json` output as `input.schema.json` and point consumers
  at it with `# yaml-language-server: $schema=<URL>` in their values
  file; with `id` set to that URL, the viewer and the Markdown show the
  modeline ready to copy.
- Never name it `values.schema.json`: Helm validates a chart's own
  values against that file, so a library's copy would check the wrong
  scope.
- `x-crdkit-*` keywords are ignored by editors; strict validators (ajv
  `strict`) need `strict: false`.
- The render stays the authority; the editor is a typing aid:

| Situation | Render | Editor |
|---|---|---|
| unknown key / unknown case | WARNING, dropped | error |
| static scalar type | strict | strict |
| per-target declaration | resolved and checked per target | accepted unchecked |
| marker in a non-string scalar | checked after substitution | accepted unchecked |
| `enum` | compared as strings | compared as typed |
| `pattern` | RE2 | ECMA-262 (same for simple patterns) |

## Testing

`command make test` (needs the helm-unittest plugin:
`helm plugin install https://github.com/helm-unittest/helm-unittest`);
layout, rules and tools: `CONTRIBUTING.md` "Testing". Requirement
catalogue (C- ids the tests cite): `docs/requirements.md`. End to end,
crdkit also runs under mdeploy's tests (`../mdeploy/README.md`
"Testing").
