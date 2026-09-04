#!/usr/bin/env bash
# Bring the whole stack up on a fresh kind cluster, in one command.
#
#   ./kind/bootstrap.sh          # cluster + image + helm release
#   ./kind/bootstrap.sh --argocd # ... plus Argo CD and the GitOps app
#
# Every step is idempotent: run it again after a change and it does the
# right thing instead of complaining.
set -euo pipefail

CLUSTER="${CLUSTER:-weather}"
NAMESPACE="${NAMESPACE:-weather}"
RELEASE="${RELEASE:-weather}"
IMAGE="${IMAGE:-weather:dev}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.2}"
# Overridable so the same script can bring up the GitOps cluster, which
# has its own host ports and its own values file.
CLUSTER_CONFIG="${CLUSTER_CONFIG:-kind/cluster.yaml}"
VALUES="${VALUES:-charts/weather/values-kind.yaml}"

# Run from the project root no matter where the script is called from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

require() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 1; }
	done
}

create_cluster() {
	if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
		log "cluster '$CLUSTER' already exists, keeping it"
	else
		log "creating kind cluster '$CLUSTER'"
		kind create cluster --name "$CLUSTER" --config "$CLUSTER_CONFIG"
	fi
	kubectl config use-context "kind-${CLUSTER}" >/dev/null
}

build_and_load() {
	log "building $IMAGE"
	docker build -t "$IMAGE" app

	# kind nodes have their own containerd, so a locally built image has to
	# be copied in. This is why the chart uses pullPolicy: IfNotPresent -
	# there is no registry to pull weather:dev from.
	log "loading $IMAGE into the cluster"
	kind load docker-image "$IMAGE" --name "$CLUSTER"
}

deploy() {
	log "installing helm release '$RELEASE'"
	helm upgrade --install "$RELEASE" charts/weather \
		--namespace "$NAMESPACE" --create-namespace \
		--values "$VALUES" \
		--wait --timeout 10m
}

# On a re-run nothing in the chart has changed, so helm makes no changes
# and the pods keep running the OLD image - even though a new weather:dev
# was just loaded. Restarting the three app deployments is what makes
# `./kind/bootstrap.sh` pick up code changes.
restart_app() {
	log "restarting app pods so they pick up the new image"
	kubectl -n "$NAMESPACE" rollout restart \
		"deploy/${RELEASE}-api" "deploy/${RELEASE}-store" "deploy/${RELEASE}-consumer"
	kubectl -n "$NAMESPACE" rollout status "deploy/${RELEASE}-api" --timeout=5m
}

install_argocd() {
	log "installing Argo CD $ARGOCD_VERSION"
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd \
		-f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

	log "waiting for Argo CD to become ready"
	kubectl -n argocd rollout status deploy/argocd-server --timeout=10m

	# The Application syncs with selfHeal, so from here on git decides
	# what runs. On the dev cluster that fights `make image`; the intended
	# home for this is the second cluster (`make gitops-up`).
	if [[ "$CLUSTER" == "weather" ]]; then
		log "WARNING: Argo CD on the dev cluster will revert 'make image'"
		echo "    selfHeal reverts anything that is not in git, including a"
		echo "    locally built weather:dev. Use 'make gitops-up' instead to"
		echo "    run the GitOps track on its own cluster."
	fi

	log "registering the weather Application"
	# Project first, explicitly. `kubectl apply -f <dir>` walks the
	# directory alphabetically, so application.yaml would be applied
	# before project.yaml and Argo CD would reject the Application with
	# "Application referencing project weather which does not exist"
	# until the next sync. Same order as `make gitops`.
	kubectl apply -f gitops/argocd/project.yaml
	kubectl apply -f gitops/argocd/application.yaml

	echo
	echo "Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8081:443"
	echo "admin password: make argocd-password"
}

summary() {
	log "done"
	kubectl -n "$NAMESPACE" get pods

	# These URLs are only right for the default cluster. Another cluster
	# (CLUSTER=weather-gitops) has its own host port mappings, and
	# values-gitops.yaml turns Grafana and Prometheus off - so printing
	# this list there would send you to four ports, two of which nothing
	# is listening on.
	if [[ "$CLUSTER" == "weather" ]]; then
		cat <<'EOS'

Open:
  UI          http://localhost:8080
  Grafana     http://localhost:3000    (admin / devpassword)
  Prometheus  http://localhost:9090
  RabbitMQ    http://localhost:15672   (admin / devpassword)
EOS
	else
		echo
		echo "Cluster '$CLUSTER' uses its own host ports and values file."
		echo "Run 'make gitops-urls' for what to open."
	fi
}

main() {
	require docker kind kubectl helm

	create_cluster

	# Was the release already there? Decides whether a restart is needed.
	# This has to come after create_cluster, which is what points kubectl
	# and helm at "$CLUSTER": with the GitOps cluster as the current
	# context, the answer would be about the wrong cluster and the
	# stale-image restart below would be skipped.
	local existed=no
	if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
		existed=yes
	fi

	build_and_load
	deploy
	if [[ "$existed" == "yes" ]]; then
		restart_app
	fi
	if [[ "${1:-}" == "--argocd" ]]; then
		install_argocd
	fi
	summary
}

main "$@"
