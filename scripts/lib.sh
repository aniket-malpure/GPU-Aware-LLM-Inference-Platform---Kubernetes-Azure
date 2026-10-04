#!/usr/bin/env bash
# Shared helpers. Source this file; do not run it.
set -euo pipefail

LLM_NAMESPACE="${LLM_NAMESPACE:-llm}"
RELEASE="${RELEASE:-llm}"
CHART_DIR="${CHART_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charts/vllm-inference}"
# shellcheck disable=SC2034  # used by scripts that source this file
SVC="${RELEASE}-vllm-inference"
PROM_SVC="${PROM_SVC:-kube-prometheus-stack-prometheus}"
PROM_NS="${PROM_NS:-monitoring}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing required tool: $c"; done; }

# port_forward <namespace> <svc> <local> <remote>  -> sets PF_PID
port_forward() {
  kubectl -n "$1" port-forward "svc/$2" "$3:$4" >/dev/null 2>&1 &
  # shellcheck disable=SC2034
  PF_PID=$!
  for _ in $(seq 1 30); do
    if nc -z 127.0.0.1 "$3" 2>/dev/null; then return 0; fi
    sleep 1
  done
  die "port-forward to $1/$2 did not come up"
}

# prom_query <promql>  -> prints a single float (sum of vector), "nan" if empty
prom_query() {
  curl -sfG "http://127.0.0.1:${PROM_LOCAL_PORT:-19090}/api/v1/query" --data-urlencode "query=$1" |
    python3 -c 'import json,sys
r=json.load(sys.stdin)["data"]["result"]
print(sum(float(x["value"][1]) for x in r) if r else "nan")'
}
