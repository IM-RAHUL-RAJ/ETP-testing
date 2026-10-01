{{- define "associate-stack.id" -}}
{{- required "Set associateId to a unique DNS-safe value for this associate" .Values.associateId | lower | trunc 30 | trimSuffix "-" -}}
{{- end -}}

{{- define "associate-stack.image" -}}
{{- printf "%s/%s:%s" .Values.image.registry .imageName .Values.image.tag -}}
{{- end -}}

{{- define "associate-stack.labels" -}}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: trading-platform
app.kubernetes.io/instance: {{ include "associate-stack.id" . | quote }}
{{- end -}}