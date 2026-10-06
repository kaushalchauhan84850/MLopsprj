SHELL := /bin/bash

.PHONY: cluster deploy-all forward smoke retrain build-push clean

cluster:            ## create a local kind cluster
	bash scripts/create-kind-cluster.sh

deploy-all:         ## build images + deploy the whole stack
	bash scripts/deploy-all.sh

forward:            ## port-forward Grafana/Prometheus/Alertmanager/Analyzer
	bash scripts/port-forward.sh

smoke:              ## trigger demo incidents
	bash scripts/smoke-test.sh

retrain:            ## force an immediate retraining run
	kubectl -n ai-ops delete job ai-trainer-manual --ignore-not-found
	kubectl -n ai-ops create job ai-trainer-manual --image=$$(kubectl -n ai-ops get cronjob ai-trainer -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}') -- python -m src.trainer.train

build-push:         ## build+push to a remote registry: make build-push REG=ghcr.io/me
	@[ -n "$$REG" ] || (echo "usage: make build-push REG=<registry[/prefix]> [TAG=latest]"; exit 1)
	bash scripts/build-push.sh "$$REG" "$${TAG:-latest}"

clean:              ## uninstall everything from the cluster
	bash scripts/clean.sh
