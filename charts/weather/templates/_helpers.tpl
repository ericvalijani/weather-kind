{{/*
Shared naming + labels. Four helpers, that's the whole file:

  weather.fullname   -> resource name prefix (the release name)
  weather.labels     -> labels every resource gets
  weather.selector   -> the subset used as pod selectors (must stay stable)
  weather.image      -> the app image reference (digest wins over tag)
*/}}

{{- define "weather.fullname" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "weather.labels" -}}
app.kubernetes.io/name: weather
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: weather
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "weather.selector" -}}
app.kubernetes.io/name: weather
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
One place that decides how the app image is referenced.

image.digest wins when set, because a digest is immutable: nobody can
move it the way a tag can be overwritten, so "which build is running?"
has exactly one answer. CI's bump job writes it into values-gitops.yaml.

Falls back to repository:tag, which is what the local kind cluster uses
(weather:dev is built and side-loaded, it has no digest in a registry).
*/}}
{{- define "weather.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}
