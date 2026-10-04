{{- define "vllm.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vllm.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vllm.labels" -}}
app.kubernetes.io/name: {{ include "vllm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "vllm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vllm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Pod template shared by both tracks.
Call with: dict "root" $ "track" "stable|canary" "tag" "<image tag>" "extraArgs" (list)
*/}}
{{- define "vllm.podTemplate" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
metadata:
  labels:
    {{- include "vllm.selectorLabels" $root | nindent 4 }}
    track: {{ .track }}
  annotations:
    vllm/model: {{ $v.model.name | quote }}
spec:
  terminationGracePeriodSeconds: 60
  nodeSelector:
    {{- toYaml $v.nodeSelector | nindent 4 }}
  tolerations:
    {{- toYaml $v.tolerations | nindent 4 }}
  affinity:
    # Spread replicas across GPU nodes so one eviction cannot take them all.
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                {{- include "vllm.selectorLabels" $root | nindent 18 }}
  containers:
    - name: vllm
      image: "{{ $v.image.repository }}:{{ .tag }}"
      imagePullPolicy: {{ $v.image.pullPolicy }}
      args:
        - --model={{ $v.model.name }}
        - --served-model-name={{ $v.model.servedName }}
        - --host=0.0.0.0
        - --port=8000
        - --max-model-len={{ $v.model.maxModelLen }}
        - --gpu-memory-utilization={{ $v.model.gpuMemoryUtilization }}
        - --max-num-seqs={{ $v.model.maxNumSeqs }}
        - --dtype={{ $v.model.dtype }}
        - --tensor-parallel-size={{ $v.gpu.count }}
        - --disable-log-requests
        {{- if $v.model.quantization }}
        - --quantization={{ $v.model.quantization }}
        {{- end }}
        {{- range $v.model.extraArgs }}
        - {{ . }}
        {{- end }}
        {{- range .extraArgs }}
        - {{ . }}
        {{- end }}
      env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: {{ $v.model.hfTokenSecret.name }}
              key: {{ $v.model.hfTokenSecret.key }}
        - name: HF_HOME
          value: /models
        - name: VLLM_TRACK
          value: {{ .track }}
      ports:
        - name: http
          containerPort: 8000
      startupProbe:
        httpGet: {path: /health, port: http}
        periodSeconds: {{ $v.probes.startup.periodSeconds }}
        failureThreshold: {{ $v.probes.startup.failureThreshold }}
      readinessProbe:
        httpGet: {path: /health, port: http}
        periodSeconds: {{ $v.probes.readiness.periodSeconds }}
      livenessProbe:
        httpGet: {path: /health, port: http}
        periodSeconds: {{ $v.probes.liveness.periodSeconds }}
        failureThreshold: {{ $v.probes.liveness.failureThreshold }}
      lifecycle:
        preStop:
          # Give the Service time to drop this endpoint before vLLM exits,
          # so in-flight streams finish instead of erroring.
          exec:
            command: ["sh", "-c", "sleep 20"]
      resources:
        requests:
          {{- toYaml $v.resources.requests | nindent 10 }}
          nvidia.com/gpu: {{ $v.gpu.count }}
        limits:
          {{- toYaml $v.resources.limits | nindent 10 }}
          nvidia.com/gpu: {{ $v.gpu.count }}
      volumeMounts:
        - name: models
          mountPath: /models
        - name: shm
          mountPath: /dev/shm
  volumes:
    - name: models
      {{- if $v.modelCache.enabled }}
      persistentVolumeClaim:
        claimName: {{ include "vllm.fullname" $root }}-models
      {{- else }}
      emptyDir: {}
      {{- end }}
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: {{ $v.shmSize }}
{{- end -}}
