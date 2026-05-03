{{/*
Expand the name of the chart.
*/}}
{{- define "openclaw.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "openclaw.fullname" -}}
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
{{- define "openclaw.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openclaw.labels" -}}
helm.sh/chart: {{ include "openclaw.chart" . }}
{{ include "openclaw.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openclaw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openclaw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "openclaw.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openclaw.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the OpenClaw config hash for triggering pod restarts
*/}}
{{- define "openclaw.configHash" -}}
{{- include (print .Template.BasePath "/configmap.yaml") . | sha256sum | trunc 8 }}
{{- end }}

{{/*
Create the OAuth cookie secret
*/}}
{{- define "openclaw.oauthCookieSecret" -}}
{{- if .Values.oauthProxy.cookieSecret }}
{{- .Values.oauthProxy.cookieSecret }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}

{{/*
Gateway Auth Token (Persistent)
*/}}
{{- define "openclaw.gatewayToken" -}}
{{- if and .Values.openclaw.config.gateway.auth (hasKey .Values.openclaw.config.gateway.auth "token") }}
{{- .Values.openclaw.config.gateway.auth.token }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}

{{/*
ClawSuite image reference
*/}}
{{- define "openclaw.clawsuite.image" -}}
{{- if .Values.clawsuite.image.repository }}
{{- printf "%s:%s" .Values.clawsuite.image.repository .Values.clawsuite.image.tag }}
{{- else }}
{{- printf "image-registry.openshift-image-registry.svc:5000/%s/%s-clawsuite:%s" .Release.Namespace (include "openclaw.fullname" .) "latest" }}
{{- end }}
{{- end }}

{{/*
Check if we need to create BuildConfig
*/}}
{{- define "openclaw.clawsuite.needsBuild" -}}
{{- if and .Values.clawsuite.enabled (not .Values.clawsuite.image.repository) }}
true
{{- else }}
false
{{- end }}
{{- end }}

{{/*
OAuth secret checksum
*/}}
{{- define "openclaw.oauthSecretHash" -}}
{{- include (print .Template.BasePath "/secret.yaml") . | sha256sum | trunc 8 }}
{{- end }}

{{/*
User-defined secrets checksum (from secrets.yaml template)
*/}}
{{- define "openclaw.userSecretsHash" -}}
{{- include (print .Template.BasePath "/secrets.yaml") . | sha256sum | trunc 8 }}
{{- end }}
