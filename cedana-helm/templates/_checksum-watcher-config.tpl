{{- define "cedana-helm.watcher.config.checksum" -}}
{{- $config := dict -}}

{{- /* Values from .Values.config the dynamo-watcher reads through the ConfigMap and Secret */ -}}
{{- $configKeysFromValuesConfig := list
  "clusterId"
  "url"
  "authToken"
  "logLevel"
  "checkpointDir"
-}}
{{- range $key := $configKeysFromValuesConfig -}}
  {{- if hasKey $.Values.config $key -}}
    {{- $_ := set $config $key (get $.Values.config $key) -}}
  {{- end -}}
{{- end -}}

{{- if hasKey $.Values.dynamoWatcher "createLoadBalancer" -}}
  {{- $_ := set $config "dynamoWatcher-createLoadBalancer" $.Values.dynamoWatcher.createLoadBalancer -}}
{{- end -}}

{{- sha256sum (toJson $config) -}}
{{- end -}}
