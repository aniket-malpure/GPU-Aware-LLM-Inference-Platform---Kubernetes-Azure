#!/usr/bin/env bash
# Build/push is done by CI; this applies the manifests with the right image.
#   ./scripts/deploy-controller.sh <tag>
source "$(dirname "$0")/lib.sh"
need kubectl terraform

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-latest}"
ACR="${ACR_LOGIN_SERVER:-$(terraform -chdir="$ROOT/infra/terraform" output -raw acr_login_server)}"
IMAGE="$ACR/gpu-autoscaler:$TAG"

log "Applying CRD and RBAC"
kubectl apply -f "$ROOT/controller/config/crd.yaml"
kubectl wait --for=condition=Established crd/gpuautoscalers.inference.llmplatform.dev --timeout=60s
kubectl apply -f "$ROOT/controller/config/rbac.yaml"

log "Deploying controller image $IMAGE"
sed "s#ACR_LOGIN_SERVER/gpu-autoscaler:latest#$IMAGE#" "$ROOT/controller/config/deployment.yaml" | kubectl apply -f -
kubectl -n gpu-autoscaler rollout status deploy/gpu-autoscaler --timeout=180s
