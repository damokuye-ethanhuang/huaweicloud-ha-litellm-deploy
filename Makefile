SHELL := /usr/bin/env bash
TF_DIR ?= terraform/examples/cce-ha
VERSION ?= 1.106.3
NAMESPACE ?= litellm

.DEFAULT_GOAL := help

.PHONY: help bootstrap init plan apply app-deploy remote-deploy smoke migrate mirror fmt \
	validate lint destroy package-chart skill-install

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Check the local toolchain and credentials
	./scripts/bootstrap.sh

init: ## terraform init for TF_DIR
	terraform -chdir=$(TF_DIR) init -upgrade

plan: ## terraform plan for TF_DIR (default: cce-ha)
	./scripts/deploy-infra.sh plan $(TF_DIR)

apply: ## terraform apply for TF_DIR
	./scripts/deploy-infra.sh apply $(TF_DIR)

app-deploy: ## Create the k8s Secret and helm upgrade --install (needs cluster access)
	./scripts/deploy.sh deploy-app

remote-deploy: ## Bundle + upload + deploy the app via the bastion
	./scripts/deploy.sh --remote all

smoke: ## Probe liveness, readiness and /v1/models
	./scripts/smoke-test.sh

migrate: ## Run the migration job manually (break-glass)
	./scripts/migrate.sh

mirror: ## Mirror the image into SWR (SWR_REGION, SWR_ORG required)
	./scripts/mirror-image.sh $(VERSION)

fmt: ## terraform fmt -recursive
	terraform fmt -recursive terraform

validate: ## Offline validation of every module, chart and script
	./scripts/lint.sh

lint: validate ## Alias for validate

destroy: ## Destroy TF_DIR (requires CONFIRM=yes)
	CONFIRM=yes ./scripts/destroy.sh $(TF_DIR)

skill-install: ## Symlink the repo skill into ~/.hermes/skills (single source of truth)
	mkdir -p "$$HOME/.hermes/skills/software-development"
	ln -sfn "$$(pwd)/skills/litellm-huaweicloud-deploy" \
		"$$HOME/.hermes/skills/software-development/litellm-huaweicloud-deploy"
	@echo "installed: $$HOME/.hermes/skills/software-development/litellm-huaweicloud-deploy"

package-chart: ## Package the Helm chart into dist/
	mkdir -p dist
	helm package charts/litellm --destination dist
