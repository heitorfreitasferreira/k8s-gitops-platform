KUBECONFIG ?= $(HOME)/.kube/talos-kubeconfig
export KUBECONFIG

INFRA := terraform/infra
PLATFORM := terraform/platform

.PHONY: up down infra platform destroy-platform destroy-infra

up: infra platform

infra:
	terraform -chdir=$(INFRA) init
	terraform -chdir=$(INFRA) apply
	terraform -chdir=$(INFRA) output -raw kubeconfig > "$(KUBECONFIG)"
	chmod 600 "$(KUBECONFIG)"

platform:
	terraform -chdir=$(PLATFORM) init
	terraform -chdir=$(PLATFORM) apply -var="minio_address=$$(terraform -chdir=$(INFRA) output -raw minio_ip)"

down: destroy-platform destroy-infra

destroy-platform:
	terraform -chdir=$(PLATFORM) destroy

destroy-infra:
	terraform -chdir=$(INFRA) destroy
