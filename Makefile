SHELL := /usr/bin/env bash
TF_DIR ?= terraform/examples/cce-ha
VERSION ?= 1.106.3
NAMESPACE ?= litellm

.DEFAULT_GOAL := help

# Every target delegates to scripts/deploy.sh or a single-purpose script; the
# Makefile is a convenience layer and must not re-implement any logic.
.PHONY: help bootstrap creds creds-clear creds-check handoff handoff-clean init preflight plan apply-infra deploy-app remote-deploy verify \
	smoke migrate mirror fmt validate lint destroy package-chart skill-install arch audit

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Check the local toolchain and credentials
	./scripts/bootstrap.sh

creds: ## Store AK/SK in secrets/hw.env (hidden input)
	./scripts/creds.sh set

creds-clear: ## Remove AK/SK from disk and from this shell check
	./scripts/creds.sh clear

creds-check: ## Fail if live credentials are still configured
	./scripts/creds.sh check

handoff: ## Show what a customer must provide, and where each item goes
	python3 ./scripts/handoff.py form

handoff-clean: ## Back up, then clear every customer value (run after a test)
	python3 ./scripts/handoff.py scrub
	python3 ./scripts/handoff.py check

init: ## terraform init for TF_DIR
	terraform -chdir=$(TF_DIR) init -upgrade

preflight: ## Validate deploy-inputs.yaml and render out/
	./scripts/deploy.sh preflight

plan: ## Save a Terraform plan for review (changes nothing)
	./scripts/deploy.sh plan

apply-infra: ## Apply the saved plan (review it first)
	@./scripts/deploy.sh apply-infra

apply-stream: ## Apply with live per-resource progress (same plan gate)
	./scripts/deploy.sh apply-stream

deploy-app: ## Secret + helm upgrade (needs cluster access; use remote-deploy outside the VPC)
	./scripts/deploy.sh deploy-app

remote-deploy: ## Bundle, upload and deploy via the bastion (no cluster access needed here)
	./scripts/deploy.sh --remote all

verify: ## Readiness, model list and fallback check
	./scripts/deploy.sh --remote verify

ingress: ## Converge the CCE ELB Ingress and prove the VIP serves
	./scripts/deploy.sh ingress

verify-ui: ## Fetch /ui/ HTML and a screenshot through the bastion
	./scripts/deploy.sh verify-ui

smoke: ## Probe liveness, readiness and /v1/models against the gateway
	./scripts/smoke-test.sh

migrate: ## Run schema migrations as a one-off job (break-glass)
	./scripts/migrate.sh

mirror: ## Mirror the image into SWR (SWR_REGION, SWR_ORG required)
	./scripts/mirror-image.sh $(VERSION)

fmt: ## terraform fmt -recursive
	terraform fmt -recursive terraform

audit: ## Pre-publication scan: credentials, PII, git history
	./scripts/audit-secrets.py

validate: ## Offline validation: modules, chart, monitoring assets, docs links, shell
	./scripts/lint.sh

lint: validate ## Alias for validate

destroy: ## Destroy TF_DIR (requires CONFIRM=yes; deletes the database)
	CONFIRM=yes ./scripts/destroy.sh $(TF_DIR)

skill-install: ## Symlink the repo skill into ~/.hermes/skills (single source of truth)
	mkdir -p "$$HOME/.hermes/skills/software-development"
	ln -sfn "$$(pwd)/skills/litellm-huaweicloud-deploy" \
		"$$HOME/.hermes/skills/software-development/litellm-huaweicloud-deploy"
	@echo "installed: $$HOME/.hermes/skills/software-development/litellm-huaweicloud-deploy"

arch: ## Regenerate docs/architecture.html from the topology
	python3 ./scripts/draw-architecture-html.py

package-chart: ## Package the Helm chart into dist/
	mkdir -p dist
	helm package charts/litellm --destination dist
