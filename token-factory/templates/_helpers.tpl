{{- define "token-factory.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/part-of: token-factory
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* (list $ .Values.x.image): served through imageRegistry, Docker Hub when empty. */}}
{{- define "token-factory.image" -}}
{{- $root := index . 0 }}{{- $img := index . 1 -}}
{{- $repo := $img.repository }}{{- with $root.Values.imageRegistry }}{{ $repo = printf "%s/%s" . $repo }}{{ end -}}
{{- if $img.digest }}{{ $repo }}@{{ $img.digest }}{{ else }}{{ $repo }}:{{ $img.tag }}{{ end }}
{{- end }}

{{- define "token-factory.imagePullSecrets" -}}
{{- $secrets := .Values.imagePullSecrets | default list -}}
{{- if .Values.imageRegistry -}}
{{- $secrets = append $secrets (dict "name" "tokenfactory-registry") -}}
{{- end -}}
{{- with $secrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
