{{/* Validate the users list. */}}
{{- define "coco-agents.validate" -}}
{{- range $user := .Values.users | default list -}}
{{- if not $user.name -}}
{{- fail "each user must have a name" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Standard labels. Call with (dict "root" $ "name" <user name>). */}}
{{- define "coco-agents.labels" -}}
{{- $root := .root -}}
{{- $name := .name -}}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
app.kubernetes.io/part-of: coco-agents
saw.pattern.io/user: {{ $name }}
{{- end -}}
