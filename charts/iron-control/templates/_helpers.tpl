{{- define "iron-control.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "iron-control.fullname" -}}
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

{{- define "iron-control.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "iron-control.labels" -}}
helm.sh/chart: {{ include "iron-control.chart" . }}
{{ include "iron-control.selectorLabels" . }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "iron-control.selectorLabels" -}}
app.kubernetes.io/name: {{ include "iron-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "iron-control.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "iron-control.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "iron-control.secretName" -}}
{{- default (include "iron-control.fullname" .) .Values.secrets.existingSecret }}
{{- end }}

{{- define "iron-control.image" -}}
{{- printf "%s:%s" (required "image.repository is required" .Values.image.repository) (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Env entries shared by the web, jobs, and migration workloads. */}}
{{- define "iron-control.commonEnv" -}}
- name: IRON_CONTROL_DB_HOST
  value: {{ required "database.host is required" .Values.database.host | quote }}
- name: IRON_CONTROL_DB_PORT
  value: {{ .Values.database.port | quote }}
- name: RAILS_LOG_LEVEL
  value: {{ .Values.config.logLevel | quote }}
- name: RAILS_MAX_THREADS
  value: {{ .Values.config.railsMaxThreads | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* envFrom entries shared by the web, jobs, and migration workloads. */}}
{{- define "iron-control.commonEnvFrom" -}}
- secretRef:
    name: {{ include "iron-control.secretName" . }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}
