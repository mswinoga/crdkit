{{/*
crdkit.diag.error (public)

Records an error diagnostic: appends `message` to `diag.errors` in place.
Libraries and crdkit itself record every error through this template.

Interface:
- Params (list): [diag, message]
  - diag (dict): the `{errors, warnings, infos}` dict (a caller holding
    `ctx` passes `$ctx.diag`)
  - message (string)
- Returns: "" (a bare `include` is safe)
*/}}
{{- define "crdkit.diag.error" -}}
{{- $diag := index . 0 -}}
{{- $_ := set $diag "errors" (append (get $diag "errors" | default list) (index . 1)) -}}
{{- end -}}

{{/*
crdkit.diag.warning (public)

Records a warning diagnostic: appends `message` to `diag.warnings` in
place; every warning goes through this define.

Interface:
- Params (list): [diag, message]
  - diag (dict): the `{errors, warnings, infos}` dict (a caller holding
    `ctx` passes `$ctx.diag`)
  - message (string)
- Returns: "" (a bare `include` is safe)
*/}}
{{- define "crdkit.diag.warning" -}}
{{- $diag := index . 0 -}}
{{- $_ := set $diag "warnings" (append (get $diag "warnings" | default list) (index . 1)) -}}
{{- end -}}

{{/*
crdkit.diag.info (public)

Records an info diagnostic: appends `message` to `diag.infos` in place.
For a valid outcome worth reporting; never a problem, never aborts.

Interface:
- Params (list): [diag, message]
  - diag (dict): the `{errors, warnings, infos}` dict (a caller holding
    `ctx` passes `$ctx.diag`)
  - message (string)
- Returns: "" (a bare `include` is safe)

Implementation notes:
- Creates `diag.infos` when missing: a seed may carry any subset of
  the three lists.
*/}}
{{- define "crdkit.diag.info" -}}
{{- $diag := index . 0 -}}
{{- $_ := set $diag "infos" (append (get $diag "infos" | default list) (index . 1)) -}}
{{- end -}}

{{/*
crdkit.diag.lines (public)

Formats accumulated diagnostics as comment lines.

Interface:
- Params (dict): { "diag": <dict>, "levels": <list of
  error|warning|info, optional — default all> }
- Returns: plain text, one `# ERROR: <m>` / `# WARNING: <m>` /
  `# INFO: <m>` line per distinct message, joined by newline, no leading
  or trailing newline; "" when none.

Implementation notes:
- Level order is always ERROR → WARNING → INFO, whatever `levels`
  order; each level is de-duplicated (first occurrence wins).
- A missing list counts as empty; an unknown level name selects nothing
  and records no diagnostic (read-only helper).
*/}}
{{- define "crdkit.diag.lines" -}}
{{- $diag := ternary .diag (dict) (kindIs "map" .diag) -}}
{{- $levels := .levels | default (list "error" "warning" "info") -}}
{{- $out := list -}}
{{- if has "error" $levels -}}
  {{- range uniq (get $diag "errors" | default list) -}}
    {{- $out = append $out (printf "# ERROR: %s" .) -}}
  {{- end -}}
{{- end -}}
{{- if has "warning" $levels -}}
  {{- range uniq (get $diag "warnings" | default list) -}}
    {{- $out = append $out (printf "# WARNING: %s" .) -}}
  {{- end -}}
{{- end -}}
{{- if has "info" $levels -}}
  {{- range uniq (get $diag "infos" | default list) -}}
    {{- $out = append $out (printf "# INFO: %s" .) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end -}}

{{/*
crdkit.diag.count (public)

Counts distinct messages of one diagnostic level.

Interface:
- Params (dict): { "diag": <dict>, "level": error|warning|info }
- Returns: the count as text; a missing list or unknown level → "0", no
  diagnostic (read-only helper).
*/}}
{{- define "crdkit.diag.count" -}}
{{- $diag := ternary .diag (dict) (kindIs "map" .diag) -}}
{{- len (uniq (get $diag (printf "%ss" .level) | default list)) -}}
{{- end -}}
