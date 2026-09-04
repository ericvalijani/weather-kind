.PHONY: help up cluster image deploy status logs urls test smoke psql redis-cli \
        argocd argocd-password argocd-ui gitops template lint down clean \
        gitops-up gitops-down gitops-urls gitops-status

# Everything is overridable from the command line, e.g.
#   make deploy RELEASE=weather2 NAMESPACE=weather2
CLUSTER   ?= weather
NAMESPACE ?= weather
RELEASE   ?= weather
CHART     ?= charts/weather
VALUES    ?= charts/weather/values-kind.yaml
IMAGE     ?= weather:dev
GO_IMAGE  ?= golang:1.26-alpine

# Which cluster definition `make cluster` uses.
CLUSTER_CONFIG ?= kind/cluster.yaml

# The second cluster: Argo CD owns it, you never edit it by hand.
GITOPS_CLUSTER ?= weather-gitops
GITOPS_CONFIG  ?= kind/cluster-gitops.yaml
GITOPS_VALUES  ?= charts/weather/values-gitops.yaml

# Pinned, not floating - same version policy as the images.
ARGOCD_VERSION  ?= v3.5.2
ARGOCD_MANIFEST ?= https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml

# Your fork, used by `make gitops`.
REPO_URL ?= https://github.com/ericvalijani/weather-kind.git

# Every target names its cluster explicitly instead of trusting whatever
# kubectl's current context happens to be. `kind create cluster` switches
# that context, so after `make gitops-up` a bare `make image` would
# otherwise rebuild into the Argo CD cluster - which then reverts it.
KUBECTL ?= kubectl --context kind-$(CLUSTER)
HELM    ?= helm --kube-context kind-$(CLUSTER)

# Argo CD only belongs on the GitOps cluster, so its targets point there
# by default. Override ARGO_CLUSTER to install it somewhere else.
ARGO_CLUSTER ?= $(GITOPS_CLUSTER)
ARGO_KUBECTL ?= kubectl --context kind-$(ARGO_CLUSTER)

help:
	@echo "up               create cluster, build+load image, install chart"
	@echo "cluster          create the kind cluster only"
	@echo "image            rebuild the Go image and load it into the cluster"
	@echo "deploy           helm upgrade --install"
	@echo "status           pods, services and pvcs"
	@echo "logs             follow logs of all three weather pods"
	@echo "urls             what to open in the browser"
	@echo "test             go vet + go test in a throwaway container"
	@echo "template/lint    render and lint the chart without a cluster"
	@echo "psql/redis-cli   shell into the data layer"
	@echo "argocd           install Argo CD ($(ARGOCD_VERSION)) into ARGO_CLUSTER"
	@echo "argocd-password  the initial admin password"
	@echo "argocd-ui        port-forward the Argo CD UI to :8081"
	@echo "smoke            helm test the release (default cluster only)"
	@echo "gitops           apply the AppProject + Application"
	@echo "gitops-up        create the SECOND cluster and hand it to Argo CD"
	@echo "gitops-status    what Argo CD thinks the sync state is"
	@echo "gitops-urls      what to open for the GitOps cluster"
	@echo "gitops-down      delete the second cluster"
	@echo "down             delete the kind cluster"
	@echo "clean            uninstall the release, delete the namespace"

# ---- cluster lifecycle ----------------------------------------------
up:
	./kind/bootstrap.sh

cluster:
	kind create cluster --name $(CLUSTER) --config $(CLUSTER_CONFIG)

# Rebuild after a code change: build, copy into the nodes, restart the
# three app deployments. Named explicitly so Grafana and Prometheus are
# not cycled every time you touch a .go file.
image:
	docker build -t $(IMAGE) app
	kind load docker-image $(IMAGE) --name $(CLUSTER)
	$(KUBECTL) -n $(NAMESPACE) rollout restart \
		deploy/$(RELEASE)-api deploy/$(RELEASE)-store deploy/$(RELEASE)-consumer
	$(KUBECTL) -n $(NAMESPACE) rollout status deploy/$(RELEASE)-api --timeout=3m

deploy:
	$(HELM) upgrade --install $(RELEASE) $(CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--values $(VALUES) --wait --timeout 10m

down:
	kind delete cluster --name $(CLUSTER)

# Uninstall the app but keep the cluster.
clean:
	$(HELM) uninstall $(RELEASE) --namespace $(NAMESPACE) || true
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found

# ---- day to day ------------------------------------------------------
status:
	$(KUBECTL) -n $(NAMESPACE) get pods,svc,pvc

# Only the Go pods. Use `kubectl logs` directly for postgres/rabbitmq.
logs:
	$(KUBECTL) -n $(NAMESPACE) logs -f --tail=100 --prefix \
		-l 'app.kubernetes.io/component in (api,store,consumer)'

urls:
	@echo "UI          http://localhost:8080"
	@echo "Grafana     http://localhost:3000    (admin / devpassword)"
	@echo "Prometheus  http://localhost:9090"
	@echo "RabbitMQ    http://localhost:15672   (admin / devpassword)"

psql:
	$(KUBECTL) -n $(NAMESPACE) exec -it sts/$(RELEASE)-postgres -- \
		sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

redis-cli:
	$(KUBECTL) -n $(NAMESPACE) exec -it deploy/$(RELEASE)-redis -- redis-cli

# ---- chart checks (no cluster needed) --------------------------------
template:
	helm template $(RELEASE) $(CHART) --values $(VALUES)

lint:
	helm lint $(CHART) --values $(VALUES)

# ---- does the running release actually work? ------------------------
# Renders and installs cleanly is not the same as works. This runs the
# test hook pod, which walks api -> store -> postgres for real.
# Only for the default cluster and CI. On the GitOps cluster Argo CD
# applies rendered manifests, so there is no helm release to test -
# use `make gitops-status` and the UI on :8082 there.
# --logs prints the smoke pod's own output inline. Without it a failure
# only says the pod failed, and the hook-delete-policy may already have
# removed the pod by the time you go looking for it.
smoke:
	$(HELM) test $(RELEASE) --namespace $(NAMESPACE) --timeout 5m --logs

# The Go source imports weather/genproto, which only exists after protoc
# runs - so tests run in a throwaway container that generates it first,
# exactly like the Docker build does.
# --user keeps generated files (go.sum, genproto/) owned by you instead
# of root; HOME and GOCACHE must then point somewhere writable.
#
# $(CURDIR), not $(PWD): make computes CURDIR itself, while PWD is
# inherited from the shell and can be a logical path (a symlinked
# directory, an automounted home). Docker resolves the mount source on
# the host and silently CREATES AN EMPTY DIRECTORY when it does not
# exist - so a wrong path does not fail, it mounts nothing, and the
# first symptom is protoc reporting that proto/weather.proto is
# missing. The guard above turns that into a clear message.
test:
	@test -f app/proto/weather.proto \
	  || { echo "app/proto/weather.proto not found - run make from the repo root"; exit 1; }
	docker run --rm -v "$(CURDIR)/app:/src" -w /src \
		--user "$(shell id -u):$(shell id -g)" \
		-e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOPATH=/tmp/go \
		$(GO_IMAGE) sh -c '\
		apk add --no-cache protobuf protobuf-dev git && \
		go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 && \
		go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2 && \
		export PATH=$$PATH:/tmp/go/bin && \
		protoc --go_out=. --go_opt=module=weather \
		       --go-grpc_out=. --go-grpc_opt=module=weather proto/weather.proto && \
		go mod tidy && go vet ./... && go test ./... -v'

# ---- the second cluster (GitOps track) -------------------------------
# Why a second cluster: the Application syncs with selfHeal: true, so
# Argo CD reverts anything that is not in git - including the weather:dev
# image `make image` just loaded. The two workflows get one cluster each.
#
# On 8GB, run one at a time. `docker stop <node-container>` parks a
# cluster with its volumes intact; `docker start` brings it back, which
# is much cheaper than deleting and recreating it.
gitops-up:
	@kind get clusters 2>/dev/null | grep -qx $(GITOPS_CLUSTER) \
		|| kind create cluster --name $(GITOPS_CLUSTER) --config $(GITOPS_CONFIG)
	$(MAKE) argocd
	$(MAKE) gitops
	@echo
	@echo "Argo CD owns this cluster now - it pulls the GHCR image pinned in"
	@echo "$(GITOPS_VALUES). Do not helm/kubectl edit it by hand; selfHeal"
	@echo "will revert you. To ship: merge CI's image-bump pull request."
	@$(MAKE) gitops-urls

gitops-status:
	$(ARGO_KUBECTL) -n argocd get applications.argoproj.io weather \
		-o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

gitops-urls:
	@echo "UI          http://localhost:8082"
	@echo "RabbitMQ    http://localhost:15673   (admin / devpassword)"
	@echo "Argo CD     make argocd-ui, then https://localhost:8081 (admin)"
	@echo "            password: make argocd-password"

gitops-down:
	kind delete cluster --name $(GITOPS_CLUSTER)

# ---- GitOps ----------------------------------------------------------
argocd:
	$(ARGO_KUBECTL) create namespace argocd --dry-run=client -o yaml | $(ARGO_KUBECTL) apply -f -
	$(ARGO_KUBECTL) apply -n argocd -f $(ARGOCD_MANIFEST)
	$(ARGO_KUBECTL) -n argocd rollout status deploy/argocd-server --timeout=10m

argocd-password:
	@$(ARGO_KUBECTL) -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

argocd-ui:
	@echo "then open https://localhost:8081 (user: admin)"
	$(ARGO_KUBECTL) -n argocd port-forward svc/argocd-server 8081:443

# Point the Application at your own repo, then register it.
# Both files need patching, not just the Application: the AppProject's
# sourceRepos is an allow-list, so an Application pointing at a repo the
# project does not list is refused with
#   application repo ... is not permitted in project 'weather'
# They are applied separately because two YAML files piped together
# without a --- separator are not a valid stream.
gitops:
	sed 's|https://github.com/ericvalijani/weather-kind.git|$(REPO_URL)|' \
		gitops/argocd/project.yaml | $(ARGO_KUBECTL) apply -f -
	sed 's|https://github.com/ericvalijani/weather-kind.git|$(REPO_URL)|' \
		gitops/argocd/application.yaml | $(ARGO_KUBECTL) apply -f -
