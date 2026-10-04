#!/usr/bin/env bash
# One-time cluster setup after `terraform apply`.
#
#   export HF_TOKEN=hf_xxx           # Hugging Face token with Llama 3 access
#   ./scripts/bootstrap.sh
#
# Installs: NVIDIA device plugin, DCGM exporter, kube-prometheus-stack,
# alert rules + dashboard, the GPUAutoscaler controller, and the vLLM release.
source "$(dirname "$0")/lib.sh"
need az kubectl helm terraform

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
: "${HF_TOKEN:?set HF_TOKEN to a Hugging Face token that can read the model}"

log "Reading Terraform outputs"
RG=$(terraform -chdir="$TF_DIR" output -raw resource_group_name)
AKS=$(terraform -chdir="$TF_DIR" output -raw aks_cluster_name)
ACR=$(terraform -chdir="$TF_DIR" output -raw acr_login_server)

log "Fetching kubeconfig for $AKS"
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing

log "Adding Helm repos"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

# AKS installs the NVIDIA driver on GPU nodes; the device plugin advertises
# nvidia.com/gpu so pods can request it.
log "Installing NVIDIA device plugin"
helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  -n nvidia-device-plugin --create-namespace \
  --set-json 'nodeSelector={"accelerator":"nvidia"}' \
  --set-json 'tolerations=[{"operator":"Exists"}]' \
  --wait

log "Installing kube-prometheus-stack"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n "$PROM_NS" --create-namespace \
  -f "$ROOT/monitoring/kube-prometheus-stack-values.yaml" \
  --wait --timeout 10m

log "Installing DCGM exporter (GPU utilization, memory, XID errors)"
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  -n "$PROM_NS" \
  --set-json 'nodeSelector={"accelerator":"nvidia"}' \
  --set-json 'tolerations=[{"operator":"Exists"}]' \
  --set serviceMonitor.enabled=true \
  --set-json 'serviceMonitor.additionalLabels={"release":"kube-prometheus-stack"}'

log "Applying alert rules and Grafana dashboard"
kubectl apply -f "$ROOT/monitoring/prometheus-rules.yaml"
kubectl apply -f "$ROOT/monitoring/grafana/dashboard-configmap.yaml"

log "Deploying GPUAutoscaler controller"
"$ROOT/scripts/deploy-controller.sh" "${CONTROLLER_TAG:-latest}"

log "Creating namespace $LLM_NAMESPACE and Hugging Face secret"
kubectl create namespace "$LLM_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$LLM_NAMESPACE" create secret generic hf-token \
  --from-literal=token="$HF_TOKEN" --dry-run=client -o yaml | kubectl apply -f -

log "Installing vLLM release (first GPU node takes ~5 min to provision)"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$LLM_NAMESPACE" \
  ${VALUES_FILE:+-f "$VALUES_FILE"}

log "Done. Next:"
cat <<EOF
  kubectl -n $LLM_NAMESPACE get pods -w
  ./scripts/smoke-test.sh
  kubectl -n $PROM_NS port-forward svc/kube-prometheus-stack-grafana 3000:80   # dashboard "LLM Inference - vLLM on AKS"
  ACR: $ACR
EOF
