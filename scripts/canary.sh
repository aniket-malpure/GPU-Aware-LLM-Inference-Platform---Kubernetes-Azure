#!/usr/bin/env bash
# Canary rollout for a new vLLM image or model flags.
#
#   ./scripts/canary.sh deploy  <new-image-tag>   # start canary next to stable
#   ./scripts/canary.sh analyze                   # compare canary vs stable in Prometheus
#   ./scripts/canary.sh promote                   # stable := canary, remove canary
#   ./scripts/canary.sh rollback                  # remove canary, keep stable
#   ./scripts/canary.sh auto    <new-image-tag>   # deploy -> smoke -> soak -> analyze -> promote|rollback
#
# Gates (override with env):
#   MAX_ERROR_RATIO_FACTOR  canary error ratio may be at most this x stable (default 2)
#   MAX_TTFT_FACTOR         canary p95 TTFT may be at most this x stable  (default 1.25)
#   SOAK_SECONDS            how long canary takes live traffic before analysis (default 600)
source "$(dirname "$0")/lib.sh"
need kubectl helm curl python3 nc

MAX_ERROR_RATIO_FACTOR="${MAX_ERROR_RATIO_FACTOR:-2}"
MAX_TTFT_FACTOR="${MAX_TTFT_FACTOR:-1.25}"
SOAK_SECONDS="${SOAK_SECONDS:-600}"
HELM_ARGS=(-n "$LLM_NAMESPACE" --reuse-values ${VALUES_FILE:+-f "$VALUES_FILE"})

current_stable_tag() {
  helm get values "$RELEASE" -n "$LLM_NAMESPACE" -a -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])'
}
current_canary_tag() {
  helm get values "$RELEASE" -n "$LLM_NAMESPACE" -a -o json | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v["canary"]["image"]["tag"] or v["image"]["tag"])'
}

deploy() {
  local tag="${1:?usage: canary.sh deploy <image-tag>}"
  log "Stable is $(current_stable_tag); starting canary on $tag"
  helm upgrade "$RELEASE" "$CHART_DIR" "${HELM_ARGS[@]}" \
    --set canary.enabled=true --set canary.image.tag="$tag" --wait=false
  "$(dirname "$0")/smoke-test.sh" canary
}

analyze() {
  PROM_LOCAL_PORT=19090 port_forward "$PROM_NS" "$PROM_SVC" 19090 9090
  trap 'kill $PF_PID 2>/dev/null || true' RETURN
  local ns="namespace=\"$LLM_NAMESPACE\""
  local c_err s_err c_ttft s_ttft c_req
  c_req=$(prom_query "sum(increase(vllm:request_success_total{$ns,track=\"canary\"}[10m]))")
  c_err=$(prom_query "llm:request_error_ratio:rate5m{$ns,track=\"canary\"}")
  s_err=$(prom_query "llm:request_error_ratio:rate5m{$ns,track=\"stable\"}")
  c_ttft=$(prom_query "llm:ttft_seconds:p95_5m{$ns,track=\"canary\"}")
  s_ttft=$(prom_query "llm:ttft_seconds:p95_5m{$ns,track=\"stable\"}")
  log "canary requests(10m)=$c_req  error ratio canary=$c_err stable=$s_err  p95 TTFT canary=${c_ttft}s stable=${s_ttft}s"

  python3 - "$c_req" "$c_err" "$s_err" "$c_ttft" "$s_ttft" "$MAX_ERROR_RATIO_FACTOR" "$MAX_TTFT_FACTOR" <<'EOF'
import math, sys
req, ce, se, ct, st, ef, tf = (float(x) for x in sys.argv[1:])
fail = []
if math.isnan(req) or req < 20:
    fail.append(f"not enough canary traffic to judge ({req})")
ce = 0.0 if math.isnan(ce) else ce
se = 0.0 if math.isnan(se) else se
if ce > ef * max(se, 0.005):
    fail.append(f"error ratio {ce:.3%} > {ef}x stable ({se:.3%})")
if not math.isnan(ct) and not math.isnan(st) and st > 0 and ct > tf * st:
    fail.append(f"p95 TTFT {ct:.2f}s > {tf}x stable ({st:.2f}s)")
if fail:
    print("CANARY FAILED: " + "; ".join(fail))
    sys.exit(1)
print("CANARY PASSED")
EOF
}

promote() {
  local tag
  tag=$(current_canary_tag)
  log "Promoting $tag to stable"
  helm upgrade "$RELEASE" "$CHART_DIR" "${HELM_ARGS[@]}" \
    --set image.tag="$tag" --set canary.enabled=false --set canary.image.tag="" --wait=false
  kubectl -n "$LLM_NAMESPACE" rollout status "deploy/${SVC}-stable" --timeout="${ROLLOUT_TIMEOUT:-1800s}"
  "$(dirname "$0")/smoke-test.sh" stable
  log "Promotion complete"
}

rollback() {
  log "Rolling back: removing canary, stable stays on $(current_stable_tag)"
  helm upgrade "$RELEASE" "$CHART_DIR" "${HELM_ARGS[@]}" \
    --set canary.enabled=false --set canary.image.tag="" --wait=false
}

auto() {
  local tag="${1:?usage: canary.sh auto <image-tag>}"
  if ! deploy "$tag"; then rollback; die "canary failed smoke test"; fi
  log "Soaking canary for ${SOAK_SECONDS}s"
  sleep "$SOAK_SECONDS"
  if analyze; then promote; else rollback; die "canary rolled back"; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  deploy|analyze|promote|rollback|auto) "$cmd" "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
