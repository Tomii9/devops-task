{{/*
Generate the full name: <release>-<chart> truncated to 63 chars.
Kubernetes names must be ≤63 characters (DNS label limit).
*/}}
{{- define "helloapp.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
These follow the Kubernetes recommended label conventions:
  https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
*/}}
{{- define "helloapp.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels — used by Deployments and Services to match pods.
Must be a STABLE subset of the common labels (cannot change between upgrades).
*/}}
{{- define "helloapp.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name — uses chart name if created, "default" otherwise.
*/}}
{{- define "helloapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "helloapp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
