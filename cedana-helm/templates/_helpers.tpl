{{/*
Expand the name of the chart.
*/}}
{{- define "cedana-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Validate and return the helper AWS credentials mode. */}}
{{- define "cedana-helm.awsCredentialsMode" -}}
{{- $mode := default "static" .Values.config.awsCredentialsMode -}}
{{- if not (has $mode (list "static" "eksPodIdentity" "ambient")) -}}
{{- fail (printf "config.awsCredentialsMode must be one of static, eksPodIdentity, or ambient; got %q" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end }}

{{/* Validate and return the GCS credentials mode. */}}
{{- define "cedana-helm.gcsCredentialsMode" -}}
{{- $mode := default "ambient" .Values.config.gcsCredentialsMode -}}
{{- if not (has $mode (list "ambient" "serviceAccount")) -}}
{{- fail (printf "config.gcsCredentialsMode must be one of ambient or serviceAccount; got %q" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end }}

{{/* The GCS variables of the helper and the health check. */}}
{{- define "cedana-helm.gcsEnv" -}}
- name: CEDANA_GCS_CREDENTIALS_MODE
  value: {{ include "cedana-helm.gcsCredentialsMode" . | quote }}
{{- if eq (include "cedana-helm.gcsCredentialsMode" .) "serviceAccount" }}
- name: CEDANA_GCS_SERVICE_ACCOUNT_KEY
  valueFrom:
    secretKeyRef:
      name: {{ template "cedana-helm.secretName" . }}
      key: gcs-service-account-key
      optional: true
{{- end }}
- name: CEDANA_GCS_EMULATOR_HOST
  valueFrom:
    configMapKeyRef:
      name: {{ template "cedana-helm.configMapName" . }}
      key: gcs-emulator-host
      optional: true
{{- end }}

{{/* Create the name of the dedicated helper service account. */}}
{{- define "cedana-helm.daemonHelperServiceAccountName" -}}
{{- if .Values.daemonHelper.serviceAccount.create -}}
{{- required "daemonHelper.serviceAccount.name must be set" .Values.daemonHelper.serviceAccount.name -}}
{{- else -}}
{{- required "daemonHelper.serviceAccount.name must be set when create is false" .Values.daemonHelper.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cedana-helm.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cedana-helm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cedana-helm.labels" -}}
helm.sh/chart: {{ include "cedana-helm.chart" . }}
{{ include "cedana-helm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cedana-helm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cedana-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cedana-helm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cedana-helm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return secret name to be used based on provided values.
*/}}
{{- define "cedana-helm.secretName" -}}
{{- default "cedana-secrets" .Values.config.preExistingSecret -}}
{{- end -}}

# Config map helper
{{- define "cedana-helm.configMapName" -}}
{{- default "cedana-config" .Values.config.preExistingSecret -}}
{{- end -}}

{{/* Create the name of the CSX ConfigMap. */}}
{{- define "cedana-helm.csxConfigMapName" -}}
cedana-csx-config
{{- end -}}

{{/*
Determine if Prometheus is enabled
*/}}
{{- define "cedana-helm.prometheusEnabled" -}}
{{- $prometheusEnabled := false -}}
{{- if and (hasKey .Values "clusterMetrics") (hasKey .Values.clusterMetrics "prometheus") (hasKey .Values.clusterMetrics.prometheus "enabled") -}}
  {{- $prometheusEnabled = .Values.clusterMetrics.prometheus.enabled -}}
{{- end -}}
{{- if and .Values.clusterMetrics .Values.clusterMetrics.enabled $prometheusEnabled -}}true{{- end -}}
{{- end -}}

{{/*
Determine if Vector is enabled
*/}}
{{- define "cedana-helm.vectorEnabled" -}}
{{- $vectorEnabled := false -}}
{{- if and (hasKey .Values "clusterMetrics") (hasKey .Values.clusterMetrics "vector") (hasKey .Values.clusterMetrics.vector "enabled") -}}
  {{- $vectorEnabled = .Values.clusterMetrics.vector.enabled -}}
{{- end -}}
{{- if and .Values.clusterMetrics .Values.clusterMetrics.enabled $vectorEnabled -}}true{{- end -}}
{{- end -}}
