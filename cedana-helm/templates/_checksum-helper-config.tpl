{{- define "cedana-helm.helper.config.checksum" -}}
{{- $config := dict -}}

{{- /* Direct values from .Values.config */ -}}
{{- $configKeysFromValuesConfig := list
  "clusterId"
  "url"
  "authToken"
  "address"
  "protocol"
  "checkpointDir"
  "checkpointStreams"
  "checkpointCompression"
  "gpuPoolSize"
  "gpuFreezeType"
  "gpuShmSize"
  "gpuLdLibPath"
  "pluginsBuilds"
  "pluginsNativeVersion"
  "pluginsCriuVersion"
  "pluginsContainerdRuntimeVersion"
  "pluginsGpuVersion"
  "pluginsStreamerVersion"
  "metrics"
  "profiling"
  "logLevel"
  "awsAccessKeyId"
  "awsRegion"
  "awsEndpoint"
  "containerdAddress"
-}}
{{- range $key := $configKeysFromValuesConfig -}}
  {{- if hasKey $.Values.config $key -}}
    {{- $_ := set $config $key (get $.Values.config $key) -}}
  {{- end -}}
{{- end -}}

{{- /* Values from .Values.shmConfig */ -}}
{{- if hasKey $.Values "shmConfig" -}}
  {{- if hasKey $.Values.shmConfig "enabled" -}}
    {{- $_ := set $config "shm-config-enabled" (get $.Values.shmConfig "enabled") -}}
  {{- end -}}
  {{- if hasKey $.Values.shmConfig "size" -}}
    {{- $_ := set $config "shm-config-size" (get $.Values.shmConfig "size") -}}
  {{- end -}}
  {{- if hasKey $.Values.shmConfig "minSize" -}}
    {{- $_ := set $config "shm-config-min-size" (get $.Values.shmConfig "minSize") -}}
  {{- end -}}
{{- end -}}

{{- sha256sum (toJson $config) -}}
{{- end -}}

