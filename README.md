# weather-kind

The same small weather stack as the Docker Compose version, but running on
a real Kubernetes cluster: **kind** (Kubernetes in Docker) + **Helm** +
optional **Argo CD** GitOps.

One Go binary runs in three modes; Postgres, Redis and RabbitMQ sit behind
it; Prometheus and Grafana watch it. Nothing here is a toy abstraction —
it is the same objects you would use on a managed cluster, just small.

```bash
git clone <your fork> && cd weather-kind
./kind/bootstrap.sh          # cluster + image + release, ~3-4 min cold
open http://localhost:8080
```

---

## What runs

| Component | Mode / image | In-cluster address | On your laptop |
| --- | --- | --- | --- |
| api | `MODE=api` | `weather-api:8080` | http://localhost:8080 |
| store | `MODE=store` | `weather-store:9090` (gRPC), `:9091` (REST) | — |
| consumer | `MODE=consumer` | — | — |
| Postgres | `postgres:18.4-alpine` | `weather-postgres:5432` | `make psql` |
| Redis | `redis:8.8.0-alpine` | `weather-redis:6379` | `make redis-cli` |
| RabbitMQ | `rabbitmq:4.3.2-management-alpine` | `weather-rabbitmq:5672` | http://localhost:15672 |
| Prometheus | `prom/prometheus:v3.12.0` | `weather-prometheus:9090` | http://localhost:9090 |
| Grafana | `grafana/grafana:13.1.0` | `weather-grafana:3000` | http://localhost:3000 |

Cluster: `kindest/node:v1.37.0`, 1 control-plane + 2 workers.
Dev credentials everywhere: `admin` / `devpassword` (Postgres user
`weather` / `devpassword`).

## How data moves

```
                Open-Meteo (public API, no key)
                          |
                     [ api pod ]  MODE=api
                     fetch loop every 120s
                          |  publish JSON
                   [ RabbitMQ: weather.readings ]
                          |  consume
                   [ consumer pod ]  MODE=consumer
                          |  gRPC AddReading
                     [ store pod ]  MODE=store
                        /        \
            Postgres (history)   Redis (latest:<city>, 120s TTL)
                        \        /
                     [ api pod ] reads back
                          |
           browser UI  +  /metrics  ->  Prometheus  ->  Grafana
```

The api never touches Postgres or Redis itself. Only `store` does. That is
why `store` is the only workload with database credentials in its
environment that actually get used.

## Why NodePorts and not an Ingress controller

`kind/cluster.yaml` maps container ports straight to your host:

```
30080 -> localhost:8080    api / UI
30300 -> localhost:3000    Grafana
30900 -> localhost:9090    Prometheus
31567 -> localhost:15672   RabbitMQ management
```

The services are `NodePort`, so there is **no ingress controller to
install, break, or keep up to date**. That is a deliberate choice: the
usual kind tutorial uses ingress-nginx, and ingress-nginx was retired —
best-effort maintenance ended in **March 2026**, with no further
releases, bug fixes or security fixes. Building the default path on a
retired component would have been the wrong call.

If you do want host-based routing, install a maintained controller
(Traefik) yourself and flip the chart on:

```bash
helm upgrade weather charts/weather -n weather \
  --values charts/weather/values-kind.yaml \
  --set ingress.enabled=true --set ingress.className=traefik
echo "127.0.0.1 weather.local" | sudo tee -a /etc/hosts
```

## Layout

```
app/                     Go source (unchanged from the compose track) + Dockerfile
charts/weather/
  Chart.yaml
  values.yaml            all defaults, commented
  values-kind.yaml       the handful of local overrides
  values-gitops.yaml     overrides for the GitOps cluster: GHCR image by digest
  templates/             one file per component, plus _helpers.tpl and NOTES.txt
  templates/tests/       the `helm test` smoke pod (`make smoke`)
  files/                 init.sql and the Grafana dashboard JSON
kind/
  cluster.yaml           3-node default cluster + port mappings
  cluster-gitops.yaml    1-node second cluster, its own host ports
  bootstrap.sh           create -> build -> load -> install
gitops/argocd/           AppProject + Application (optional track)
renovate.json            how the pinned versions get update pull requests
.github/workflows/ci.yml go test, helm lint, kind e2e, GHCR push
Makefile                 every command you actually type
PROMPT.md                the spec this project was generated from
generate.sh              recreates this entire tree from scratch
HANDOFF.md               what was built, what broke, what to watch
```

## Commands

```bash
make help          # every target with a one-line description
make up            # create the cluster, build+load the image, install the chart (idempotent, safe to re-run)
make image         # after editing Go: rebuild weather:dev, kind load it, restart api/store/consumer only
make deploy        # after editing the chart: helm upgrade --install, no image rebuild
make status        # pods, services and PVCs in one screen - the first thing to run when something looks wrong
make logs          # tail api, store and consumer together, prefixed by pod, to watch fetch -> publish -> store
make test          # go vet + go test in a golang container, so protoc and the gRPC stubs need nothing installed locally
make template      # render the chart to stdout without touching a cluster - what Helm would actually send
make lint          # helm lint: chart structure and values, not whether the manifests are valid Kubernetes
make psql          # interactive psql inside the postgres pod, already connected to the weather database
make smoke         # helm test: hits api /healthz, store /healthz, then api /cities - proves the gRPC path works end to end
make clean         # uninstall the release and delete the namespace, keeping the cluster (PVCs go too)
make down          # delete the whole kind cluster, including its images and volumes
```

And for the optional GitOps cluster:

```bash
make gitops-up       # create the weather-gitops cluster, install Argo CD, register the Application - the one entry point
make gitops-status   # is it Synced and Healthy, and which git revision is actually live?
make gitops-urls     # host ports for cluster 2 (8082/15673 - Grafana and Prometheus are off there)
make argocd-ui       # port-forward the Argo CD UI to https://localhost:8081 (leave it running)
make argocd-password # the generated admin password, for the UI above
make gitops         # point the Application at your fork: make gitops REPO_URL=...
make gitops-down    # delete cluster 2 and leave the dev cluster alone
```

`make template` and `make lint` use the dev values. To check what Argo CD
will actually render, pass the other file:
`make template VALUES=charts/weather/values-gitops.yaml`. CI checks both.

## Try it

```bash
# health and latest readings
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readings/latest | head -40

# add a city by name - geocoded via Open-Meteo, then persisted
curl -s -X POST http://localhost:8080/cities -d 'city=Shiraz'
curl -s http://localhost:8080/cities

# adding a city also triggers an immediate fetch for it, so you don't
# have to wait out the interval to see a new row

# app metrics, then the same series in Prometheus
curl -s http://localhost:8080/metrics | grep weather_
```

In Grafana the dashboard **Weather** is already provisioned against the
Prometheus datasource — no clicking through setup.

## Editing the app

```bash
vim app/api.go
make image      # build + kind load + rollout restart
make logs
```

There is no live reload and no auto-updater in the cluster on purpose:
deploying is a decision, not a background process.

## Cities and state

`app.cities` in values seeds the `cities` table **on first boot only**.
After that Postgres is the source of truth, and the api refreshes its list
from `store` periodically. Adding a city with `POST /cities` is permanent;
changing `app.cities` later does nothing to an existing database.

To start genuinely clean:

```bash
make clean      # uninstall release + delete namespace (PVCs go too)
make deploy
```

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `ImagePullBackOff` on api/store/consumer | `weather:dev` was never loaded into the nodes → `make image` |
| Postgres pod crash-loops complaining about a data dir | Postgres 18 mounts at `/var/lib/postgresql`, not `.../data` — do not change `postgres.mountPath` |
| `relation "cities" does not exist` | The PVC predates `files/init.sql`; init only runs on an empty volume → `make clean && make deploy` |
| Pods `Pending` on a fresh cluster | kind's local-path provisioner is still starting, or 8 GB RAM is tight — `kubectl -n weather describe pod ...` |
| `curl localhost:8080` refused | `nodePorts.enabled=false`, or the cluster was created without `kind/cluster.yaml` |
| Image pull timeouts behind sanctions/filtering | VPN on the Docker daemon; Open-Meteo itself needs no VPN |

## Versions

Everything is pinned, nothing is `:latest`. Checked at build time:
kind node v1.37.0, Helm >= 4.2.4 (Helm 3.21.x still works, security
fixes until Nov 2026), Argo CD v3.5.2, Go 1.26 (matching `go.mod`).
Re-check before bumping — see PROMPT.md for the version policy.

## GitOps track (optional, second cluster)

The default workflow above is imperative: you run `make image`, Helm changes the
cluster. The GitOps track inverts that - **git decides what runs**, and Argo CD
keeps the cluster matching it.

It lives on a **second kind cluster** on purpose. The Argo CD Application syncs
with `selfHeal: true`, which reverts anything that is not in git - including the
`weather:dev` image `make image` just side-loaded. One cluster per workflow:

| | `weather` (default) | `weather-gitops` |
| --- | --- | --- |
| Start it | `make up` | `make gitops-up` |
| Image | local `weather:dev`, `kind load`ed | `ghcr.io/<you>/weather-kind` by digest |
| Values | `charts/weather/values-kind.yaml` | `charts/weather/values-gitops.yaml` |
| Deploy by | `make image` | merging CI's image-digest pull request |
| Monitoring | Prometheus + Grafana | off, to leave room for Argo CD |
| UI | `http://localhost:8080` | `http://localhost:8082` |
| RabbitMQ | `http://localhost:15672` | `http://localhost:15673` |

```bash
make gitops-up        # create the cluster, install Argo CD, register the app
make gitops-status    # sync + health + which revision is live
make argocd-password  # admin password
make argocd-ui        # port-forward, then https://localhost:8081
make gitops-down      # delete the second cluster
```

**On 8GB, run one cluster at a time.** `docker stop` the idle cluster's node
container parks it with its volumes intact; `docker start` brings it back. That is
much cheaper than deleting and recreating.

### How a change reaches the GitOps cluster

```
git push (app code)
   |
   +-> CI: test -> chart -> e2e (real kind cluster + helm test) -> build-and-push
   |
   +-> CI: bump  ->  opens a PR that pins the new digest in values-gitops.yaml
                        |
                     you review the diff and merge
                        |
                     Argo CD syncs  ->  three app deployments roll
```

The image is pinned by **digest**, not tag: a tag can be overwritten and moved, a
digest cannot, so what Argo CD deploys is byte-for-byte what CI tested. Set
`image.digest` and `image.tag` is ignored (see `weather.image` in `_helpers.tpl`).

Before the first sync works you need two settings on your fork:

1. The GHCR package must be **Public** (Packages -> weather-kind -> Package
   settings), or the cluster cannot pull it without credentials.
2. Settings -> Actions -> General -> **Allow GitHub Actions to create and approve
   pull requests**, or the `bump` job fails with a 403.

Also note this cluster genuinely pulls from the internet on every sync, so it is
the one part of the project that needs your VPN to be up and is useless offline.

## Running one cluster at a time

On 8GB you do not want both clusters running at once (the default cluster is
three nodes plus Prometheus and Grafana; the GitOps cluster is one node plus
Argo CD, roughly 400Mi on its own). You do not have to delete one to use the
other - a kind "cluster" is just Docker containers, so you can park it:

```bash
# see what exists and what is running
kind get clusters
docker ps -a --filter name=weather --format '{{.Names}}\t{{.Status}}'

# park the default cluster (3 containers: control-plane + 2 workers)
docker stop weather-control-plane weather-worker weather-worker2

# wake the GitOps cluster (1 container)
docker start weather-gitops-control-plane

# and the other way round
docker stop weather-gitops-control-plane
docker start weather-control-plane weather-worker weather-worker2
```

What survives a stop/start: the node containers keep their names, volumes,
loaded images (`weather:dev` stays loaded), PVC data, and their kubeconfig
entries. Nothing needs recreating.

Things worth knowing:

- **Give it a minute.** After `docker start`, the API server and then the pods
  come back in stages. `make status` will show `Pending`/`NotReady` for 30-90s.
  If a pod is stuck much longer, `kubectl -n weather delete pod <name>` is safe -
  every workload is managed by a Deployment or StatefulSet.
- **Host ports are only bound while the container runs.** `http://localhost:8080`
  is dead the moment you stop the default cluster; that is expected, not a bug.
  This is also why the two clusters use different host ports - if the ports
  collided, `kind create cluster` for the second one would fail outright.
- **You do not need to fix your kubectl context.** Every `make` target passes
  `--context kind-<cluster>` explicitly, so `make status` always means the
  default cluster and `make gitops-status` always means the GitOps one, no
  matter which context `kubectl config current-context` reports. For raw
  `kubectl` commands you type yourself, either switch with
  `kubectl config use-context kind-weather` or pass `--context`.
- **Parked is not free.** Stopped containers still hold their disk images and
  volumes. `make down` / `make gitops-down` is what actually reclaims the space.

If you would rather only ever have one cluster on disk, that works too:
`make down` before `make gitops-up`, and `make gitops-down` before `make up`.
Recreating a cluster costs a few minutes; parking costs seconds.

## Checking a running release

```bash
make smoke     # helm test: api /healthz, store /healthz, api /cities
```

This is for the default cluster (and CI). The GitOps cluster has no helm
release to test - Argo CD applies rendered manifests - so check that one with
`make gitops-status` and `http://localhost:8082` instead.

`helm lint` and `helm template` only prove the chart renders. `make smoke` runs a
test-hook pod inside the cluster that walks api -> store gRPC -> Postgres, so an
empty city list or a broken gRPC link fails loudly instead of hiding behind a
green `/healthz`. CI runs the same hook in its `e2e` job.

## Dependency updates

`renovate.json` configures Renovate to open pull requests for the pinned
versions in this repo. Standard managers cover the container images, Go
modules and the `uses:` refs in CI; custom managers cover the five pins no
standard manager can see: `kindest/node` (in both cluster files *and* CI's
`node_image`), `ARGOCD_VERSION`, the protoc plugin pins, CI's `GO_VERSION`,
and the `helm`/`kind` binary versions CI installs as `with:` inputs.
Enable the Renovate app on the fork and it starts proposing bumps; CI's `e2e` job
installs each one into a real cluster before you merge. Majors get their own PR -
Postgres 18 moving its data directory is exactly the kind of change a grouped
batch would have hidden.
