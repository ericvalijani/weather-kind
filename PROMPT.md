# PROMPT.md - weather-kind

This is the spec the project is generated from. Hand it (plus
`generate.sh`) to any capable model or engineer and the same tree should
come out. It is the Kubernetes/kind sibling of the Docker Compose track.

---

## 0. Ground rules (read before writing any file)

1. **Simple, readable code wins.** Go stays boringly procedural: small
   files, one job each, no frameworks, no DI containers, no clever
   generics. Bash stays short: `set -euo pipefail`, a few named
   functions, comments that say *why*. If a reader has to scroll to
   understand one behaviour, it is too clever.
2. **Comment the non-obvious, not the obvious.** `# increment i` is
   noise. `# Postgres 18 moved its data dir` is the comment that saves
   an hour.
3. **Pin every version. Never `:latest`.** A pinned tag that is a year
   old is better than a floating tag that silently breaks.
4. **Version policy (do this at generation time, not from memory):**
   look up the current stable release of every component before pinning
   it, and prefer versions still inside their support window.
5. **Maintenance check (mandatory).** Before depending on any
   third-party component, verify it is still maintained. Two examples
   that shaped this project:
   - `containrrr/watchtower` was archived in Dec 2025 -> no auto-updater
     anywhere in either track.
   - **ingress-nginx was retired**; best-effort maintenance ended
     March 2026, with no further releases, bug fixes or security fixes.
     The default kind tutorial uses it. This project must **not**. Use
     NodePort + kind `extraPortMappings` as the default ingress path,
     and offer an optional, disabled-by-default `Ingress` for people who
     install a maintained controller (Traefik) themselves.
6. **Breaking-change check.** For each pinned image, check whether the
   major version changed paths, defaults or flags. Postgres 18 moving
   its data directory from `/var/lib/postgresql/data` to
   `/var/lib/postgresql` is the canonical trap: mount the old path and
   the container refuses to start.
7. **Semantic consistency, not just formatting.** `gofmt` passing means
   nothing about correctness. After any rename, verify every call site
   in the package still resolves (parse the AST or at minimum `go vet`
   the whole package). Same for Helm: `helm lint` passing does not mean
   the rendered manifests are valid - always `helm template` and read
   the output.
8. **Generator safety.** `generate.sh` must never `rm -rf` its target.
   It takes an optional directory argument, refuses to write into a
   non-empty directory unless `--force` is passed, and otherwise only
   creates files.
9. **Everything must work offline after the first pull.** No component
   may require a paid API key. The weather source is Open-Meteo (free,
   keyless).

---

## 1. What to build

A small weather pipeline on a local Kubernetes cluster:

- One Go binary, three run modes selected by `MODE`: `api`, `store`,
  `consumer`.
- Postgres (history), Redis (latest-value cache), RabbitMQ (queue).
- Prometheus scraping the Go app, Grafana with a provisioned datasource
  and one dashboard.
- Packaged as a **Helm chart**, deployed to a **kind** cluster, with an
  optional **Argo CD** GitOps track.

The Go application is intentionally **identical to the compose track**.
Do not rewrite it for Kubernetes: the only thing that changes is where
the hostnames in the environment point.

---

## 2. Repository layout to produce

```
app/                                Go source + Dockerfile (unchanged)
  main.go metrics.go api.go city_cache.go weather_fetch.go
  http_handlers.go ui_page.go store.go store_http.go consumer.go
  parse_test.go city_cache_test.go http_handlers_test.go
  proto/weather.proto  go.mod  Dockerfile  .dockerignore
charts/weather/
  Chart.yaml values.yaml values-kind.yaml
  templates/_helpers.tpl config.yaml postgres.yaml redis.yaml
            rabbitmq.yaml store.yaml api.yaml consumer.yaml
            prometheus.yaml grafana.yaml ingress.yaml NOTES.txt
  files/init.sql files/grafana-dashboard-weather.json
kind/cluster.yaml kind/bootstrap.sh
gitops/argocd/project.yaml gitops/argocd/application.yaml gitops/README.md
.github/workflows/ci.yml
Makefile .gitignore README.md PROMPT.md generate.sh HANDOFF.md
```

---

## 3. The Go application (keep it simple)

Single package `main`, module `weather`, Go 1.26. One file per concern:

| File | Contents |
| --- | --- |
| `main.go` | `MODE` switch, `getenv`, `mustDuration` |
| `api.go` | config load, gRPC dial to store, city-list refresh, fetch loop |
| `city_cache.go` | `cityCoord{Name,Lat,Lon}`, `parseCities`, get/set/list, add-to-store |
| `weather_fetch.go` | `reading` struct, `geocodeCity`, `fetchOne`, `publishAll` |
| `http_handlers.go` | routes `/`, `/healthz`, `/metrics`, `/readings/latest`, `/cities` (GET + POST) |
| `ui_page.go` | the HTML page as one string constant |
| `store.go` | Postgres connect with retry, gRPC server :9090, `AddReading`, `GetLatest`, `seedCities` |
| `store_http.go` | tiny REST surface on :9091 (health + city list for the api) |
| `consumer.go` | AMQP consume with retry, forward via gRPC |
| `metrics.go` | four Prometheus collectors, nothing more |

Rules that keep it readable:

- Retries are explicit loops (`for i := 0; i < 30; i++ { ... 2s }`), not
  a backoff library.
- Errors are logged with context and either retried or fatal. No
  wrapped-error trees.
- The gRPC stubs in `app/genproto/` are **generated during the Docker
  build** by `protoc`; they are never committed and are gitignored. Any
  CI job or local test target must generate them first.

Metrics to expose: `weather_temperature_celsius`,
`weather_windspeed_kph`, `weather_readings_published_total`,
`weather_readings_stored_total`.

---

## 4. Cluster (`kind/cluster.yaml`)

- `kindest/node:v1.37.0`, one control-plane + two workers (so scheduling
  and node affinity behave like a real cluster).
- `extraPortMappings` on the control-plane node:
  `30080->8080`, `30300->3000`, `30900->9090`, `31567->15672`, plus
  `80->80` and `443->443` for people who later install a controller.
- Label the control-plane `ingress-ready=true` via a kubeadm patch, so
  an optional controller can be scheduled without editing the cluster.

---

## 5. Helm chart requirements

- `apiVersion: v2`, `kubeVersion: ">=1.30.0-0"`.
- Three helpers only: `weather.fullname`, `weather.labels`,
  `weather.selector`. Standard `app.kubernetes.io/*` labels plus
  `app.kubernetes.io/component: <api|store|consumer|postgres|redis|rabbitmq|prometheus|grafana>`.
- **All hostnames derive from the release name.** Nothing hardcodes
  `weather-postgres`; `config.yaml` builds it with `include
  "weather.fullname"`. Two releases in two namespaces must both work.
- One ConfigMap (`-env`) for non-secret env, one Secret (`-secrets`) for
  the three dev passwords, one ConfigMap (`-initdb`) carrying
  `files/init.sql`. App workloads pull both with `envFrom`.
- Postgres and RabbitMQ are `StatefulSet`s with `volumeClaimTemplates`.
  Prometheus and Grafana are `Deployment`s with a PVC and
  `strategy: Recreate` (a ReadWriteOnce volume cannot be attached to old
  and new pods at once).
- Redis has **no** volume: `redis-server --save "" --appendonly no`. It
  is a cache; losing it costs one Postgres query.
- Give the data pods the right `fsGroup` or they cannot write to a
  freshly provisioned local-path volume: Grafana 472, Prometheus 65534,
  RabbitMQ 999.
- Probes: `pg_isready` for Postgres, `redis-cli ping` for Redis,
  `rabbitmq-diagnostics ping` for RabbitMQ, `GET /healthz` for api
  (:8080) and store (:9091). The consumer has no ports and therefore no
  probes - do not invent one.
- Prometheus scrape config and the Grafana datasource are **inline in
  templates**, not static files, because their targets contain the
  release name. `files/` holds only genuinely static assets consumed via
  `.Files.Get`.
- Services: everything `ClusterIP` except api, Grafana, Prometheus and a
  separate RabbitMQ-management service, which become `NodePort` when
  `nodePorts.enabled` (default true). AMQP itself is never exposed.
- `values.yaml` is the documentation surface: commented, grouped
  (`image`, `app`, `postgres`, `redis`, `rabbitmq`, `prometheus`,
  `grafana`, `nodePorts`, `ingress`, `resources`, `storageClassName`).
  `values-kind.yaml` holds only local overrides.
- Resource requests must fit an 8 GB laptop: ~25m/32Mi for app pods,
  ~50m/128Mi for data pods, modest limits.
- `NOTES.txt` prints the URLs and credentials that actually apply, based
  on whether NodePorts or ingress are enabled.

---

## 6. Bash requirements

`kind/bootstrap.sh`:

- `set -euo pipefail`, `cd` to the project root from `BASH_SOURCE`.
- Functions: `require`, `create_cluster`, `build_and_load`, `deploy`,
  `install_argocd`, `summary`, `main`.
- Idempotent: reuses an existing cluster, `helm upgrade --install`.
- `docker build` then `kind load docker-image` - explain in a comment
  that kind nodes have their own containerd, which is why the chart uses
  `pullPolicy: IfNotPresent` for a tag that exists in no registry.
- `--argocd` flag additionally installs Argo CD and applies `gitops/`.

`generate.sh`: see rule 8. Mechanically emits the tree with
`cat > file <<'WEATHER_EOF'` blocks, skips `app/genproto/`, `chmod +x`s
the scripts, prints next steps.

`Makefile`: overridable variables at the top, `help` as the first
target, and targets `up cluster image deploy status logs urls test
template lint psql redis-cli argocd argocd-password argocd-ui gitops
down clean`. Real tabs, and `$$` for shell variables.

---

## 7. GitOps track

- `AppProject weather` scoping the app to namespace `weather` and
  namespaced resources only (`clusterResourceWhitelist: []`).
- `Application weather`: this repo, `charts/weather`,
  `valueFiles: [values-kind.yaml]`, `automated` sync with `prune` and
  `selfHeal`, `CreateNamespace=true`, `ServerSideApply=true`.
- Argo CD pinned (`v3.5.2`) via its `manifests/install.yaml`.
- `gitops/README.md` must be honest about the one real limitation: Argo
  CD syncs manifests, it does not build images, so a locally loaded
  `weather:dev` tag is a dev shortcut and the real loop is
  `CI -> GHCR -> image tag in git -> sync`.

---

## 8. CI

Four jobs, in order: `test` (protoc + `go vet` + `go test` on Go 1.26,
matching `go.mod`), `chart` (`helm lint` + `helm template`), `e2e` (real
kind cluster, build, load, `helm install --wait`, curl `/healthz`, dump
pod state on failure), `build-and-push` (GHCR, `latest` + short SHA, gha
cache, push events only).

The Go version in CI **must** equal the one in `go.mod`. A mismatch
fails every run on the first line.

---

## 9. Docs to write

- `README.md`: quickstart, component/port/version table, ASCII data-flow
  diagram, why NodePort instead of ingress-nginx, layout, commands,
  hands-on curl section, troubleshooting table, version note.
- `HANDOFF.md`: what exists, decisions and their reasons, every bug hit
  during the build and its fix, known limitations, and what a newcomer
  should do first.

---

## 10. Verification before declaring done

1. `generate.sh` into an empty directory, then `diff -r` against the
   original tree - must be identical.
2. `bash -n` (and `shellcheck` if available) on every `.sh`.
3. `gofmt -l app` clean, and an AST check that every identifier used in
   the package is defined in it.
4. Every non-templated YAML parses.
5. `helm lint` and `helm template` succeed, and the rendered output is
   read, not merely exit-code-checked.

---

## Addendum: the GitOps / auto-deploy track

Everything above describes the stack itself. This addendum specifies the
auto-deploy layer added on top of it.

### Requirements

1. **A second kind cluster** defined in `kind/cluster-gitops.yaml`, named
   `weather-gitops`, one control-plane node and no workers, with host ports
   shifted so it can coexist with the dev cluster: api 8082, Grafana 3001,
   Prometheus 9091, RabbitMQ 15673. The api must not use 8081, which is reserved
   for the Argo CD UI port-forward.
2. **`charts/weather/values-gitops.yaml`**, read by Argo CD instead of
   `values-kind.yaml`. It points `image.repository` at
   `ghcr.io/<owner>/weather-kind`, carries an `image.digest` field that CI fills
   in, and disables Prometheus and Grafana to leave room for Argo CD.
3. **A `weather.image` helper** in `_helpers.tpl` that renders
   `repository@digest` when `image.digest` is set and `repository:tag` otherwise.
   All three app Deployments use it. The dev track keeps working unchanged
   because `digest` is empty in `values.yaml`.
4. **The Argo CD Application** (`gitops/argocd/application.yaml`) syncs
   `values-gitops.yaml` with `automated: {prune: true, selfHeal: true}`, and is
   documented as belonging on the second cluster only.
5. **CI writes the deploy back to git.** `build-and-push` exposes the pushed
   digest as a job output; a `bump` job pins it into `values-gitops.yaml` and
   opens a pull request via `peter-evans/create-pull-request`. Merging the pull
   request is the deploy. No direct push to `main`, no `[skip ci]` needed - a
   content-identical rebuild yields the same digest and therefore no diff.
6. **A chart test hook** at `templates/tests/api-smoke.yaml`
   (`helm.sh/hook: test`) that checks api `/healthz`, store `/healthz`, and api
   `/cities`, failing on an empty city list. It reuses the app image so nothing
   extra is pulled. Exposed as `make smoke` and used as CI's `e2e` smoke step,
   replacing the previous port-forward plus `curl`.
7. **`renovate.json`** with custom managers for `kindest/node` in the cluster
   files, `ARGOCD_VERSION` in the Makefile and `bootstrap.sh`, and the protoc
   plugin pins. Minor/patch image updates batched; majors and `kindest/node`
   isolated.
8. **Make targets**: `gitops-up`, `gitops-down`, `gitops-status`, `gitops-urls`,
   `smoke`. `kind/bootstrap.sh` honours `CLUSTER_CONFIG` and `VALUES` overrides
   and warns if Argo CD is installed onto the dev cluster.

### Explicitly out of scope

Argo CD Image Updater (a second controller to pin and debug), `:latest` with
`pullPolicy: Always` (no history, no rollback), sync waves (the app's retry loops
already make start order irrelevant), Argo CD Notifications, sealed/external
secrets, image scanning and signing, per-PR preview environments, HPA and
PodDisruptionBudgets. Each is a reasonable next step; none is needed for this to
work, and every one of them costs memory or moving parts on an 8GB laptop.

- Never rely on kubectl's current context. Every Makefile recipe must name its
  cluster with `--context kind-<cluster>`, and no target may run
  `kubectl config use-context` - two clusters exist and `kind create cluster`
  moves the context behind your back.
- The `helm test` pod must carry `argocd.argoproj.io/hook: Skip` so Argo CD
  never applies it, and the docs must say that `make smoke` is for the default
  cluster and CI only.
- Document how to run one cluster at a time by parking the other with
  `docker stop`/`docker start`, with the exact node container names.
- Every pinned version must be matched by exactly one Renovate manager,
  including the ones no standard manager sees: `kindest/node` in the cluster
  files *and* in CI's `node_image`, `ARGOCD_VERSION`, the protoc plugins, CI's
  `GO_VERSION`, and the `helm`/`kind` binary versions passed as `with:` inputs.
- CI must lint and render every values file, `values-gitops.yaml` included - it
  is the file the bump job edits automatically, so it is the most likely to be
  corrupted and the least likely to be read.
- The bump job must re-render the chart after writing the digest and confirm the
  digest appears in the rendered output.
- NOTES.txt must not advertise components that are disabled, and must say that
  host ports differ between the two clusters.
