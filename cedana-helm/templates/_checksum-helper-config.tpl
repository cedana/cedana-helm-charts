{{- define "cedana-helm.helper.config.checksum" -}}
{{- $config := dict -}}

{{- /* Direct values from .Values.config */ -}}
{{- $configKeysFromValuesConfig := list
  "clusterId"
  "url"
  "authToken"
  "sqsQueueUrl"
  "address"
  "protocol"
  "checkpointDir"
  "checkpointStreams"
  "checkpointStreamMemoryLimit"
  "checkpointCompression"
  "checkpointAsync"
  "gpuPoolSize"
  "gpuShmSize"
  "pluginsBuilds"
  "pluginsCriuVersion"
  "pluginsContainerdRuntimeVersion"
  "pluginsGpuVersion"
  "pluginsStreamerVersion"
  "profiling"
  "metrics"
  "logLevel"
  "awsAccessKeyId"
  "awsSecretAccessKey"
  "awsCredentialsMode"
  "awsRegion"
  "awsEndpoint"
  "preExistingSecret"
  "criuLogLevel"
-}}
{{- range $key := $configKeysFromValuesConfig -}}
  {{- if hasKey $.Values.config $key -}}
    {{- $_ := set $config $key (get $.Values.config $key) -}}
  {{- end -}}
{{- end -}}

{{- /* Values from .Values.hostConfig */ -}}
{{- if hasKey $.Values "hostConfig" -}}
  {{- if hasKey $.Values.hostConfig "containerdAddress" -}}
    {{- $_ := set $config "hostConfig-containerdAddress" (get $.Values.hostConfig "containerdAddress") -}}
  {{- end -}}
  {{- if hasKey $.Values.hostConfig "disableIoUring" -}}
    {{- $_ := set $config "hostConfig-disableIoUring" (get $.Values.hostConfig "disableIoUring") -}}
  {{- end -}}
  {{- if hasKey $.Values.hostConfig "shmConfig" -}}
    {{- if hasKey $.Values.hostConfig.shmConfig "enabled" -}}
      {{- $_ := set $config "hostConfig-shmConfig-enabled" (get $.Values.hostConfig.shmConfig "enabled") -}}
    {{- end -}}
    {{- if hasKey $.Values.hostConfig.shmConfig "size" -}}
      {{- $_ := set $config "hostConfig-shmConfig-size" (get $.Values.hostConfig.shmConfig "size") -}}
    {{- end -}}
    {{- if hasKey $.Values.hostConfig.shmConfig "minSize" -}}
      {{- $_ := set $config "hostConfig-shmConfig-minSize" (get $.Values.hostConfig.shmConfig "minSize") -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- if hasKey $.Values.daemonHelper "serviceAccount" -}}
  {{- $_ := set $config "daemonHelper-serviceAccount" $.Values.daemonHelper.serviceAccount -}}
{{- end -}}

{{- sha256sum (toJson $config) -}}
{{- end -}}
