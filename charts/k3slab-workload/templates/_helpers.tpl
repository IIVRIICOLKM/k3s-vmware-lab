{{/* Common labels: which release, kind and model version produced an object. */}}
{{- define "k3slab.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
k3slab.io/kind: {{ .Values.kind }}
k3slab.io/model-version: {{ .Values.model.version | quote }}
{{- end -}}

{{/* GPU placement shared by both kinds. */}}
{{- define "k3slab.gpuPlacement" -}}
{{- with .Values.runtimeClassName }}
runtimeClassName: {{ . }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* Container resources: the requests from values plus the GPU limit. */}}
{{- define "k3slab.resources" -}}
resources:
  {{- with .Values.resources.requests }}
  requests:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if gt (int .Values.gpu) 0 }}
  limits:
    nvidia.com/gpu: {{ .Values.gpu }}
  {{- end }}
{{- end -}}
