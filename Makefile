# Full-stack automation for the IoT service-mesh platform.
#
#   make setup_everything  provision MicroK8s, then install the mesh + apps
#   make setup_mk8s        provision the MicroK8s cluster (nodes, addons, CRDs)
#   make set_all_up        install Linkerd + Viz + ArgoCD, then sync every service
#   make teardown          remove all services, ArgoCD, Linkerd Viz and Linkerd
#   make status            show ArgoCD apps, iot-system pods and mesh edges
#
# Binaries/paths are auto-detected; override on the command line, e.g.
#   make set_all_up LINKERD=~/Tools/linkerd/bin/linkerd KUBECTL=kubectl
#   make setup_mk8s SSH_KEY=~/.ssh/id_rsa INVENTORY=infrastructure/inventory.ini

KUBECTL ?= kubectl
LINKERD ?= $(shell command -v linkerd 2>/dev/null || echo $(HOME)/Tools/linkerd/bin/linkerd)
ANSIBLE ?= ansible-playbook

# setup_mk8s talks to the real nodes over SSH; set_all_up/teardown run locally.
INVENTORY ?= infrastructure/inventory.ini
SSH_KEY   ?= $(HOME)/Documents/PG/Projects/.sshkeys/iot_sm

PB    := infrastructure/playbooks
INV   := -i localhost,
EXTRA := -e kubectl_bin=$(KUBECTL) -e linkerd_bin=$(LINKERD)

.PHONY: help setup_everything setup_mk8s set_all_up teardown status nodered_export

help:
	@echo "Targets:"
	@echo "  make setup_everything - provision MicroK8s, then install mesh + ArgoCD + sync all services"
	@echo "  make setup_mk8s       - provision the MicroK8s cluster (nodes, addons, Gateway API CRDs)"
	@echo "  make set_all_up       - install Linkerd, Linkerd Viz, ArgoCD; sync all services via ArgoCD"
	@echo "  make teardown         - remove all services, ArgoCD, Linkerd Viz and Linkerd"
	@echo "  make status           - ArgoCD apps + iot-system pods + mesh edges"
	@echo "  make nodered_export   - snapshot live Node-RED flows back into git (sanitized)"
	@echo ""
	@echo "  KUBECTL=$(KUBECTL)"
	@echo "  LINKERD=$(LINKERD)"
	@echo "  INVENTORY=$(INVENTORY)"
	@echo "  SSH_KEY=$(SSH_KEY)"

# Provision the cluster (remote, over SSH) then bring up the mesh + apps (local).
setup_everything:
	$(MAKE) setup_mk8s
	$(MAKE) set_all_up

setup_mk8s:
	$(ANSIBLE) -i $(INVENTORY) --private-key $(SSH_KEY) infrastructure/setup-microk8s.yaml

set_all_up:
	$(ANSIBLE) $(INV) $(PB)/setup-all.yml $(EXTRA)

teardown:
	$(ANSIBLE) $(INV) $(PB)/teardown.yml $(EXTRA)

nodered_export:
	@KUBECTL=$(KUBECTL) bash infrastructure/scripts/nodered-export.sh

status:
	@$(KUBECTL) get applications -n argocd || true
	@echo
	@$(KUBECTL) get pods -n iot-system -o wide || true
	@echo
	@$(LINKERD) viz edges deployment -n iot-system || true
