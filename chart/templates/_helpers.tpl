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

{{/*
Format ingress host for an extra chain.
If host starts with a PR prefix (e.g. 'pr-1-', 'p1-', 'p-1-'), maintain the PR prefix first:
e.g. pr-1-tiny-key-s-server.jskw.dev -> pr-1-c1-tiny-key-s-server.jskw.dev
Otherwise:
e.g. tiny-key-s-server.jskw.dev -> c1-tiny-key-s-server.jskw.dev
*/}}
{{- define "tiny-key-s-server.chainHost" -}}
  {{- $chain := .chain -}}
  {{- $host := .host -}}
  {{- $prPrefix := regexFind "^p(r)?-?[0-9]+-" $host -}}
  {{- if $prPrefix -}}
    {{- $rest := trimPrefix $prPrefix $host -}}
    {{- printf "%s%s-%s" $prPrefix $chain $rest -}}
  {{- else -}}
    {{- printf "%s-%s" $chain $host -}}
  {{- end -}}
{{- end -}}

{{/*
Format ingress host for mitmweb UI.
e.g. pr-2-tiny-key-s-server.jskw.dev -> pr-2-mitm-tiny-key-s-server.jskw.dev
Otherwise:
e.g. tiny-key-s-server.jskw.dev -> mitm-tiny-key-s-server.jskw.dev
*/}}
{{- define "tiny-key-s-server.mitmHost" -}}
  {{- $host := .host -}}
  {{- $prPrefix := regexFind "^p(r)?-?[0-9]+-" $host -}}
  {{- if $prPrefix -}}
    {{- $rest := trimPrefix $prPrefix $host -}}
    {{- printf "%smitm-%s" $prPrefix $rest -}}
  {{- else -}}
    {{- printf "mitm-%s" $host -}}
  {{- end -}}
{{- end -}}
