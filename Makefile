# Full-stack automation for the IoT service-mesh platform.
#
#   make set_all_up   install Linkerd + Viz + ArgoCD, then sync every service
#   make teardown     remove all services, ArgoCD, Linkerd Viz and Linkerd
#   make status       show ArgoCD apps, iot-system pods and mesh edges
#
# Binaries are auto-detected; override on the command line, e.g.
#   make set_all_up LINKERD=~/Tools/linkerd/bin/linkerd KUBECTL=kubectl

KUBECTL ?= kubectl
LINKERD ?= $(shell command -v linkerd 2>/dev/null || echo $(HOME)/Tools/linkerd/bin/linkerd)
ANSIBLE ?= ansible-playbook

PB    := infrastructure/playbooks
INV   := -i localhost,
EXTRA := -e kubectl_bin=$(KUBECTL) -e linkerd_bin=$(LINKERD)

.PHONY: help set_all_up teardown status

help:
	@echo "Targets:"
	@echo "  make set_all_up   - install Linkerd, Linkerd Viz, ArgoCD; sync all services via ArgoCD"
	@echo "  make teardown     - remove all services, ArgoCD, Linkerd Viz and Linkerd"
	@echo "  make status       - ArgoCD apps + iot-system pods + mesh edges"
	@echo ""
	@echo "  KUBECTL=$(KUBECTL)"
	@echo "  LINKERD=$(LINKERD)"

set_all_up:
	$(ANSIBLE) $(INV) $(PB)/setup-all.yml $(EXTRA)

teardown:
	$(ANSIBLE) $(INV) $(PB)/teardown.yml $(EXTRA)

status:
	@$(KUBECTL) get applications -n argocd || true
	@echo
	@$(KUBECTL) get pods -n iot-system -o wide || true
	@echo
	@$(LINKERD) viz edges deployment -n iot-system || true
