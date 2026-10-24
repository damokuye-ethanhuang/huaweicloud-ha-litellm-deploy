SHELL := /usr/bin/env bash
TF_DIR ?= terraform/examples/cce-ha
VERSION ?= 1.106.3
NAMESPACE ?= litellm

.DEFAULT_GOAL := help

.PHONY: help bootstrap init plan apply app-deploy smoke migrate mirror fmt validate lint \
	sync-config check-config-sync destroy package-chart

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

app-deploy: ## Create the k8s Secret and helm upgrade --install the gateway
	./scripts/deploy-app.sh

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

sync-config: ## Copy config/litellm-config.yaml into the chart
	cp config/litellm-config.yaml charts/litellm/files/litellm-config.yaml

check-config-sync: ## Fail if the chart config drifted
	./scripts/check-config-sync.sh

destroy: ## Destroy TF_DIR (requires CONFIRM=yes)
	CONFIRM=yes ./scripts/destroy.sh $(TF_DIR)

package-chart: ## Package the Helm chart into dist/
	mkdir -p dist
	helm package charts/litellm --destination dist
