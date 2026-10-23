{{/*
Expand the name of the chart.
*/}}
{{- define "tiny-key-s-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Return list of extra chains derived from env.ROOTS, env.CHAINS, or env.ROOT_S_BYTES.
If 1 chain: [c1]
If >=2 chains: [c1, c2, ..., all]
If 0 chains: []
*/}}
{{- define "tiny-key-s-server.extraChains" -}}
  {{- $raw := "" -}}
  {{- if .Values.env -}}
    {{- $raw = or .Values.env.ROOTS .Values.env.CHAINS .Values.env.ROOT_S_BYTES "" -}}
  {{- end -}}
  {{- $chains := list -}}
  {{- if $raw -}}
    {{- range $idx, $item := splitList "," (toString $raw) -}}
      {{- $name := trim $item -}}
      {{- if hasPrefix "0x" $name -}}
        {{- $name = printf "c%d" (add $idx 1) -}}
      {{- end -}}
      {{- if $name -}}
        {{- $chains = append $chains $name -}}
      {{- end -}}
    {{- end -}}
    {{- if gt (len $chains) 1 -}}
      {{- $chains = append $chains "all" -}}
    {{- end -}}
  {{- end -}}
  {{- toJson $chains -}}
{{- end -}}
