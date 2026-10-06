.PHONY: help preflight init fmt validate plan apply predestroy destroy verify

help: ## Show this help
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

preflight: ## Check tools, access, quota and run terraform validate + plan
	./scripts/preflight.sh

init: ## terraform init
	terraform init

fmt: ## Format all Terraform files
	terraform fmt -recursive

validate: ## terraform validate
	terraform validate

plan: ## terraform plan
	terraform plan

apply: preflight ## Preflight, then create the cluster
	terraform apply

predestroy: ## Remove load balancers/disks created by Kubernetes
	./scripts/predestroy.sh

destroy: ## Full teardown: predestroy, terraform destroy, verify
	./scripts/destroy.sh

verify: ## Check GCP for leftovers
	./scripts/verifydestroy.sh
