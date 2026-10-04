#!/usr/bin/env bash
# Stop paying for GPUs.
#   ./scripts/teardown.sh pause     # scale vLLM to 0 so the GPU pool drains to 0 nodes
#   ./scripts/teardown.sh destroy   # delete everything Terraform created
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  pause)
    need kubectl
    log "Suspending autoscaler and scaling vLLM to zero"
    kubectl -n "$LLM_NAMESPACE" patch gpuautoscaler "${SVC}-stable" --type merge -p '{"spec":{"minReplicas":0,"maxReplicas":0}}' || true
    kubectl -n "$LLM_NAMESPACE" scale deploy -l app.kubernetes.io/instance="$RELEASE" --replicas=0
    log "GPU nodes will be removed by the cluster autoscaler in ~5-10 minutes"
    ;;
  destroy)
    need terraform
    read -r -p "Destroy ALL resources in infra/terraform? Type 'destroy' to confirm: " ans
    [[ "$ans" == "destroy" ]] || die "aborted"
    terraform -chdir="$ROOT/infra/terraform" destroy
    ;;
  *) echo "usage: $0 pause|destroy"; exit 2 ;;
esac
