{{- define "rbac.subjects" -}}
{{- range .groups }}
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: {{ . }}
{{- end }}
{{- range .users }}
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: {{ . }}
{{- end }}
{{- range .serviceAccounts }}
- kind: ServiceAccount
  name: {{ .name }}
  {{- if .namespace }}
  namespace: {{ .namespace }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "rbac.namespace" -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .name }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{- define "rbac.role-binding" -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
{{- if .role }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ .role }}
{{- else if .clusterRole }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ .clusterRole }}
{{- end }}
{{- $subjects := include "rbac.subjects" . }}
{{- if $subjects }}
subjects:
{{- $subjects }}
{{- else }}
subjects: []
{{- end }}
{{- end -}}

{{- define "rbac.normalized-resource-id" -}}
{{- if eq "nvidia.com/gpu" . -}}
gpu
{{- else if hasPrefix "nvidia.com/mig" . -}}
mig-{{ regexSplit "\\." . -1 | last }}
{{- else -}}
unk
{{- end -}}
{{- end -}}

{{- define "rbac.hardware-profile" -}}
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  annotations:
    opendatahub.io/dashboard-feature-visibility: "[]"
    opendatahub.io/disabled: "false"
    {{- with .displayName }}
    opendatahub.io/display-name: {{ . }}
    {{- end }}
    opendatahub.io/managed: "false"
    {{- with .description }}
    opendatahub.io/description: {{ . }}
    {{- end }}
  name: {{ .name | default "default" }}
  namespace: {{ .namespace | default "redhat-ods-applications" }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  identifiers:
    - identifier: cpu
      displayName: CPU
      resourceType: CPU
      minCount: 1
      maxCount: {{ .cpu }}
      defaultCount: 2
    - identifier: memory
      displayName: Memory
      resourceType: Memory
      minCount: 2Gi
      maxCount: {{ .mem }}
      defaultCount: 8Gi
    {{- with .gpu }}
    - identifier: {{ .identifier }}
      {{- with .displayName }}
      displayName: {{ . }}
      {{- end }}
      resourceType: Accelerator
      minCount: 1
      maxCount: {{ .max }}
      defaultCount: 1
    {{- end }}
  scheduling:
    type: Queue
    kueue:
      localQueueName: {{ .localQueue | default "default" }}
      priorityClass: {{ .priorityClass | default "None" }}
{{- end }}
