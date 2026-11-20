{{- define "token-factory.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/part-of: token-factory
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "token-factory.image" -}}
{{- if .digest }}{{ .repository }}@{{ .digest }}{{ else }}{{ .repository }}:{{ .tag }}{{ end }}
{{- end }}
