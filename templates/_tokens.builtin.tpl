{{/*
Derives "env" from "target". Most CRDs built on crdkit use "target" AS
"env" directly, with no sequence suffix at all (e.g. "prod") — only a
minority need the extended "<env>-<seq>" form (seq = exactly two
digits, e.g. "prod-01") to distinguish multiple numbered instances of
the same env. Both are supported by the SAME rule, tried in order, no
opt-in/config needed: if "target" matches "<env>-<seq>", the captured
group is env; otherwise "target" IS env, verbatim, whatever it looks
like. The only remaining error case is "target" being unset entirely —
there is no longer a way to have a "malformed" non-empty target, since
anything not matching the extended form is simply treated as a literal
env name (this was NOT always true — an earlier version required every
target to match "<env>-<seq>" and rejected anything else, which broke
the common case; don't reintroduce that requirement).

Implemented via crdkit.matchRules (see _tokens.tpl) with a single,
fixed, library-controlled rule — so the "malformed pattern hard-fails"
behavior described there can never actually trigger here (this pattern
is tested and never changes at runtime).

Expects a dict: { "target": <string, may be empty/nil>, "diag": <dict> }
Returns the derived env string, or "" (with an ERROR recorded) if
target is missing.
*/}}
{{- define "crdkit.deriveTargetEnv" -}}
{{- $target := .target -}}
{{- $diag := .diag -}}
{{- if not $target -}}
  {{- $_ := set $diag "errors" (append $diag.errors "'target' is required (e.g. 'prod', or 'prod-01' for a sequenced target) but was not set") -}}
{{- else -}}
  {{- $m := include "crdkit.matchRules" (dict "subject" $target "rules" (list (dict "(.+)-[0-9]{2}" "$1"))) | fromYaml -}}
  {{- if $m.matched -}}
    {{- $m.value -}}
  {{- else -}}
    {{- $target -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Tokens computed by crdkit itself from render-time facts — NOT supplied
by a downstream specific library (that's "system"/"defaults", see
crdkit.resolveAllTokens in _tokens.tpl) and NOT consumer-editable.
Every key defined here is automatically a reserved/built-in token name,
same treatment as "AT" — see crdkit.resolveAllTokens, which computes
the reserved-name list as `append (keys $builtinTokens) "AT"` rather
than a hardcoded list, so adding a token here is enough; no other file
needs to change.

Outputs RAW declarations, same as "system"/"defaults" — a bare scalar
here means the same thing it does everywhere else (targetContainer
implied "none" once crdkit.resolveToken wraps it into the full struct);
this block doesn't need to know about the {value, targetContainer}
shape itself, it's just another source of raw declarations that gets
merged and resolved uniformly with everything else.

Owns calling crdkit.deriveTargetEnv itself, rather than having the
caller pre-compute "env" and hand it in — this block is the one place
that both DEFINES and COMPUTES every crdkit-owned token, so its own
input dict is exactly what crdkit.deriveTargetEnv expects and gets
passed straight through (`.`). Ordinary Sprig pipelines work here
exactly as in any other YAML-producing define block
(crdkit.systemTokens-style) — a derived value is just `{{ $env |
upper }}`; bind "env" to a variable once if more than one token derives
from it, rather than re-deriving it per token.

Token names here must be UPPER_SNAKE_CASE like any other (crdkit's own
naming-convention rule applies to itself too — see
crdkit.resolveAllTokens) — hence "ENV", not "env".

Expects a dict: { "target": <string, may be empty/nil>, "diag": <dict> }
(same shape crdkit.deriveTargetEnv expects).
*/}}
{{- define "crdkit.builtinTokens" -}}
{{- $env := include "crdkit.deriveTargetEnv" . -}}
{{/* quote deliberately: an empty derived env (malformed/missing target,
     already recorded as an ERROR by crdkit.deriveTargetEnv) must still
     render as ENV: "" — an empty scalar with no quotes parses as YAML
     null, not "", which then breaks crdkit.substituteTokens downstream
     (replace() requires a string, not nil). */}}
ENV: {{ $env | quote }}
{{- end -}}
