{{- define "cedana-helm.manager.config.checksum" -}}
{{- $config := dict -}}

{{- /* Direct values from .Values.config */ -}}
{{- $configKeysFromValuesConfig := list
  "sqsQueueUrl"
  "clusterId"
  "url"
  "authToken"
  "metrics"
  "logLevel"
-}}
{{- range $key := $configKeysFromValuesConfig -}}
  {{- if hasKey $.Values.config $key -}}
    {{- $_ := set $config $key (get $.Values.config $key) -}}
  {{- end -}}
{{- end -}}

{{- sha256sum (toJson $config) -}}
{{- end -}}

