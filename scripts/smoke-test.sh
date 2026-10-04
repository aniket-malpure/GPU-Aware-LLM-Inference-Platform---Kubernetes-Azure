#!/usr/bin/env bash
# Verifies one track end to end: health, model list, a real completion.
#   ./scripts/smoke-test.sh [stable|canary]
source "$(dirname "$0")/lib.sh"
need kubectl curl python3 nc

TRACK="${1:-stable}"
PORT="${SMOKE_PORT:-18000}"
MODEL="${MODEL:-llama-3-8b}"

log "Waiting for $TRACK pods to be ready"
kubectl -n "$LLM_NAMESPACE" rollout status "deploy/${SVC}-${TRACK}" --timeout="${ROLLOUT_TIMEOUT:-1500s}"

port_forward "$LLM_NAMESPACE" "${SVC}-${TRACK}" "$PORT" 8000
trap 'kill $PF_PID 2>/dev/null || true' EXIT
BASE="http://127.0.0.1:$PORT"

curl -sf "$BASE/health" >/dev/null || die "/health failed"
log "health ok"

curl -sf "$BASE/v1/models" | python3 -c "import json,sys; ids=[m['id'] for m in json.load(sys.stdin)['data']]; assert '$MODEL' in ids, ids; print('models:', ids)"

RESP=$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}],\"max_tokens\":8,\"temperature\":0}") \
  || die "chat completion failed"
echo "$RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); t=r['choices'][0]['message']['content']; assert t.strip(), 'empty completion'; print('completion:', t.strip())"

log "smoke test passed for $TRACK"
