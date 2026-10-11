{{/*
Expand the name of the chart.
*/}}
{{- define "openwebui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "openwebui.fullname" -}}
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
{{- define "openwebui.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openwebui.labels" -}}
helm.sh/chart: {{ include "openwebui.chart" . }}
{{ include "openwebui.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openwebui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openwebui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "openwebui.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openwebui.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Ensure that config changes roll the deployment
*/}}
{{- define "openwebui.config-annotations" -}}
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
{{- end }}

{{/*
Template the semicolon-delimited base urls
*/}}
{{- define "openwebui.openai-api-base-urls" -}}
{{- $endpoints := list }}
{{- range $endpoint := .Values.configuration.vllmEndpoints }}
{{- $endpoints = append $endpoints $endpoint.endpoint }}
{{- end }}
{{- $endpoints | join ";" }}
{{- end }}

{{/*
Render the semicolon-delimited API tokens
*/}}
{{- define "openwebui.openai-api-keys" -}}
{{- $tokens := list }}
{{- range $endpoint := .Values.configuration.vllmEndpoints }}
{{- $tokens = append $tokens (default "" $endpoint.token) }}
{{- end }}
{{- $tokens | join ";" }}
{{- end }}
