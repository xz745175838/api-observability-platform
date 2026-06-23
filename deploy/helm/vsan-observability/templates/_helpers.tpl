{{/*
Expand the name of the chart.
*/}}
{{- define "vsan-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "vsan-observability.fullname" -}}
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

{{- define "vsan-observability.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Target namespace: Release.Namespace wins when installing with -n; fallback to values.
*/}}
{{- define "vsan-observability.namespace" -}}
{{- .Release.Namespace }}
{{- end }}

{{- define "vsan-observability.labels" -}}
helm.sh/chart: {{ include "vsan-observability.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{- define "vsan-observability.componentLabels" -}}
{{ include "vsan-observability.labels" . }}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* Service DNS helpers */}}
{{- define "vsan-observability.kafka.brokers" -}}
{{- printf "%s:%d" .Values.kafka.service.name (.Values.kafka.service.port | int) -}}
{{- end }}

{{- define "vsan-observability.influxdb.url" -}}
{{- printf "http://%s:%d" .Values.influxdb.service.name (.Values.influxdb.service.port | int) -}}
{{- end }}

{{- define "vsan-observability.collector.metricsTarget" -}}
{{- printf "%s:%d" .Values.collector.service.name (.Values.collector.service.port | int) -}}
{{- end }}

{{- define "vsan-observability.processor.metricsTarget" -}}
{{- printf "%s:%d" .Values.processor.service.name (.Values.processor.service.port | int) -}}
{{- end }}

{{- define "vsan-observability.prometheus.url" -}}
{{- printf "http://%s:%d" .Values.prometheus.service.name (.Values.prometheus.service.port | int) -}}
{{- end }}

{{- define "vsan-observability.image" -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end }}

{{/*
Pod anti-affinity: spread replicas across nodes.
Usage: include "vsan-observability.podAntiAffinity" (list . "collector" "vsan-collector")
  - arg2: values key (collector | processor | kafka)
  - arg3: pod label "app" value
*/}}
{{- define "vsan-observability.podAntiAffinity" -}}
{{- $root := index . 0 -}}
{{- $componentKey := index . 1 -}}
{{- $appLabel := index . 2 -}}
{{- $componentCfg := index $root.Values $componentKey | default dict -}}
{{- $override := default dict $componentCfg.podAntiAffinity -}}
{{- $cfg := mergeOverwrite (deepCopy $root.Values.global.podAntiAffinity) $override -}}
{{- if $cfg.enabled }}
affinity:
  podAntiAffinity:
    {{- if eq $cfg.type "hard" }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values:
                - {{ $appLabel | quote }}
        topologyKey: {{ $cfg.topologyKey | default "kubernetes.io/hostname" }}
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: {{ $cfg.weight | default 100 }}
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - {{ $appLabel | quote }}
          topologyKey: {{ $cfg.topologyKey | default "kubernetes.io/hostname" }}
    {{- end }}
{{- end }}
{{- end }}

{{/*
Render container resources block (requests + limits required for prod quota discipline).
*/}}
{{- define "vsan-observability.resources" -}}
{{- $res := . -}}
resources:
  requests:
    cpu: {{ required "resources.requests.cpu is required" $res.requests.cpu | quote }}
    memory: {{ required "resources.requests.memory is required" $res.requests.memory | quote }}
  limits:
    cpu: {{ required "resources.limits.cpu is required" $res.limits.cpu | quote }}
    memory: {{ required "resources.limits.memory is required" $res.limits.memory | quote }}
{{- end }}
