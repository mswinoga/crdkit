{{ include "crdkit.schema.resolve" (dict "ctx" $ctx "schema" $ctx.schema "values" $ctx.input "keys" (list "infra")) }}
