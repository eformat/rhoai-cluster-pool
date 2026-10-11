{{- define "kueue.cohort" -}}
apiVersion: kueue.x-k8s.io/v1beta1
kind: Cohort
metadata:
  name: {{ .name }}
spec:
  resourceGroups:
    {{- range .resourceGroups }}
    - coveredResources:
        {{- $resources := list }}
        {{- range $flavor, $quotas := .flavors }}
          {{- $resources = concat $resources (keys $quotas) | uniq | sortAlpha }}
        {{- end }}
        {{- toYaml $resources | nindent 8 }}
      flavors:
        {{- range $flavor, $quotas := .flavors }}
        - name: {{ $flavor }}
          resources:
            {{- range $name, $quota := $quotas }}
            - name: {{ $name }}
              nominalQuota: {{ quote $quota }}
            {{- end }}
        {{- end }}
    {{- end }}
{{- end }}

{{- define "kueue.cluster-queue" -}}
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: {{ .name }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with .cohort }}
  cohort: {{ . }}
  {{- end }}
  {{- if .namespaceSelector }}
  namespaceSelector:
    {{- toYaml .namespaceSelector | nindent 4 }}
  {{- else }}
  namespaceSelector: {} # match all.
  {{- end }}
  {{- with .preemption }}
  preemption:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .flavorFungibility }}
  flavorFungibility:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .queueingStrategy }}
  queueingStrategy: {{ . }}
  {{- end }}
  {{- with .stopPolicy }}
  stopPolicy: {{ . }}
  {{- end }}
  resourceGroups:
    {{- range .resourceGroups }}
    - coveredResources:
        {{- $resources := list }}
        {{- range $flavor, $quotas := .flavors }}
          {{- $resources = concat $resources (keys $quotas) | uniq | sortAlpha }}
        {{- end }}
        {{- toYaml $resources | nindent 8 }}
      flavors:
        {{- range $flavor, $quotas := .flavors }}
        - name: {{ $flavor }}
          resources:
            {{- range $name, $quota := $quotas }}
            - name: {{ $name }}
              nominalQuota: {{ quote $quota }}
            {{- end }}
        {{- end }}
    {{- end }}
{{- end }}

{{- define "kueue.local-queue" -}}
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  {{- with .labels }}
  labels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    argocd.argoproj.io/sync-wave: "1"
spec:
  clusterQueue: {{ .clusterQueue }}
{{- end }}

{{- define "kueue.calculate-resources" -}}
{{- $return := dict }}
{{- /* Iterate through all resource flavors available */}}
{{- range $flavor, $resources := .Values.totalResources }}
  {{- $_ := set $return $flavor dict }}
  {{- $total := deepCopy $resources }}
  {{- /* Iterate through all reservations in that flavor */}}
  {{- range $user, $reservation := get $.Values.reservations $flavor }}
    {{- $userRes := dict }}
    {{- /* Iterate through each resource reservation type */}}
    {{- range $res_res, $res_ct := $reservation }}
      {{- /* Pass through non-resource metadata keys like "until" */}}
      {{- if eq $res_res "until" }}
        {{- $_ := set $userRes "until" $res_ct }}
      {{- /* Abort early if reservation is set to 0 to enable quick values changes */}}
      {{- else if ne $res_ct 0.0 }}
        {{- /* Calculate the share of CPU/Memory associated with this reservation */}}
        {{- $remaining := get $resources $res_res }}
        {{- $res_share := mulf $res_ct $remaining.share }}
        {{- $res_cpu := floor (mulf $res_share $total.cpu) }}
        {{- $res_mem := floor (mulf $res_share $total.memory) }}
        {{- /* Any earlier loop iterations on other resource types might also have reserved CPU/memory */}}
        {{- $user_current_cpu := get $userRes "cpu" | default 0 }}
        {{- $user_current_mem := get $userRes "memory" | default 0 }}
        {{- $_ := set $userRes "cpu" (add $res_cpu $user_current_cpu) }}
        {{- $_ := set $userRes "memory" (add $res_mem $user_current_mem) }}
        {{- $_ := set $userRes $res_res $res_ct }}
        {{- /* Save off the user reservation values */}}
        {{- $_ := set (get $return $flavor) $user $userRes }}
        {{- /* Subtract the user reservation values from the total remaining resources */}}
        {{- $_ := set $remaining "count" (sub $remaining.count $res_ct) }}
        {{- $_ := set $resources "cpu" (sub $resources.cpu $res_cpu) }}
        {{- $_ := set $resources "memory" (sub $resources.memory $res_mem) }}
      {{- end }}{{/* End of early exit */}}
    {{- end }}{{/* End of resource reservation type iteration */}}
  {{- end }}{{/* End of user-per-flavor iteration */}}
  {{- range $k, $v := $resources }}
    {{- /* Within our flavor's remaining resources, strip the GPUs down to a count instead of count + share */}}
    {{- if and (kindIs "map" $v) (hasKey $v "count") }}
      {{- $_ := set $resources $k $v.count }}
    {{- end }}
  {{- end }}
  {{- /* Save the remaining resource for the flavor in our return dict */}}
  {{- $_ := set (get $return $flavor) "remaining" $resources }}
{{- end }}{{/* End of flavor iteration through totalResources */ -}}
{{ toJson $return }}
{{- end -}}
