SHELL := /bin/bash
TF := terraform -chdir=infra/terraform
TAG ?= latest

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## ---------- Infrastructure ----------
tf-init: ## terraform init
	$(TF) init

tf-plan: ## terraform plan
	$(TF) plan -out=tfplan

tf-apply: ## terraform apply the saved plan
	$(TF) apply tfplan

bootstrap: ## Install GPU plugin, monitoring, controller, vLLM (needs HF_TOKEN)
	./scripts/bootstrap.sh

## ---------- Controller ----------
controller-test: ## go vet + unit tests
	cd controller && go mod tidy && go vet ./... && go test -race -cover ./...

controller-image: ## Build controller image in ACR (TAG=...)
	az acr build -r $$($(TF) output -raw acr_name) -t gpu-autoscaler:$(TAG) controller

controller-deploy: ## Apply CRD, RBAC, controller (TAG=...)
	./scripts/deploy-controller.sh $(TAG)

controller-run-local: ## Run controller against current kubeconfig in dry-run mode
	cd controller && go run ./cmd/controller --kubeconfig $$HOME/.kube/config \
	  --prometheus-url http://localhost:9090 --dry-run --log-level debug

## ---------- Serving ----------
chart-lint: ## helm lint + template
	helm lint charts/vllm-inference
	helm template llm charts/vllm-inference -n llm > /dev/null

smoke: ## Smoke test the stable track
	./scripts/smoke-test.sh stable

port-forward: ## Expose vLLM on localhost:8000
	kubectl -n llm port-forward svc/llm-vllm-inference 8000:8000

grafana: ## Expose Grafana on localhost:3000
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

## ---------- Load testing ----------
loadtest: ## 50 concurrent streams for 5 min (needs port-forward)
	python3 loadtest/loadtest.py --concurrency 50 --duration 300 --out loadtest/results-50.json

loadtest-ramp: ## Ramp 5->50 to watch the autoscaler react
	python3 loadtest/loadtest.py --ramp 5,10,25,50 --step-seconds 180 --out loadtest/results-ramp.json

loadtest-mock: ## Exercise the load test locally without a GPU
	@python3 loadtest/mock_server.py --port 18000 & PID=$$!; sleep 1; \
	python3 loadtest/loadtest.py --url http://127.0.0.1:18000 --concurrency 20 --requests 100 --max-tokens 16; \
	kill $$PID

## ---------- Releases ----------
canary: ## Canary a new vLLM tag end to end (NEW_TAG=...)
	./scripts/canary.sh auto $(NEW_TAG)

canary-rollback: ## Remove the canary immediately
	./scripts/canary.sh rollback

## ---------- Cost control ----------
pause: ## Scale vLLM to zero and let GPU nodes drain
	./scripts/teardown.sh pause

destroy: ## Delete all Azure resources
	./scripts/teardown.sh destroy
