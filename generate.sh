#!/usr/bin/env bash
#
# Recreates the weather-kind tree from scratch.
#
#   ./generate.sh [target-directory]     # default: weather-kind
#
# It only ever creates: no rm, no truncation of anything it did not
# write. Running it into an existing directory overwrites the files it
# knows about and leaves everything else alone.
#
# app/genproto/ is deliberately absent - the gRPC stubs are generated
# inside the Docker build (see app/Dockerfile) and by `make test`.
set -euo pipefail

TARGET="${1:-weather-kind}"
mkdir -p "$TARGET"
cd "$TARGET"

mkdir -p ".github/workflows" "app" "app/proto" "charts/weather" "charts/weather/files" "charts/weather/templates" "charts/weather/templates/tests" "gitops" "gitops/argocd" "kind"

cat > ".gitignore" <<'KINDGEN_EOF'
# Local kubeconfig exports, if you ever write one out
kubeconfig
*.kubeconfig

# Helm packaging output
*.tgz
charts/*/charts/

# Generated gRPC stubs - produced inside the Docker build, never committed
app/genproto/

# Editor / OS noise
.DS_Store
.idea/
.vscode/
KINDGEN_EOF

cat > "HANDOFF.md" <<'KINDGEN_EOF'
# HANDOFF - weather-kind (Kubernetes / kind track, v1)

Written for whoever opens this repo next, including future me. It covers
what exists, why it looks the way it does, what actually broke on the way
here, and what to be careful with.

---

## 1. What this is

The Docker Compose weather stack, ported to a real Kubernetes cluster
running locally in Docker via **kind**, packaged as a **Helm chart**, with
an optional **Argo CD** GitOps track.

The Go application is byte-for-byte the same as the compose track. That
was the point: the app should not know or care whether it runs under
compose or Kubernetes. All that changed is where its environment
variables point (`weather-postgres` instead of `postgres`, etc.) and who
sets them (a ConfigMap + Secret instead of `.env`).

```
./kind/bootstrap.sh   ->  cluster + image + release, then open localhost:8080
```

---

## 2. Decisions, and why

**Helm chart, not raw manifests.** Nine components each needing the same
labels, the same env, and release-derived hostnames. Raw YAML would mean
copy-paste with a find-and-replace footgun. The chart also means two
releases in two namespaces work without editing anything.

**NodePort + kind `extraPortMappings`, not an ingress controller.** This
is the biggest divergence from the standard kind tutorial, and it is
deliberate. While checking versions I found that **ingress-nginx has been
retired**: best-effort maintenance ended in March 2026 and there will be
no further releases, bug fixes or security fixes. Existing charts and
images still download, so a tutorial built on it *appears* to work — it
just quietly ships an unmaintained, internet-adjacent component. Since
kind can map node ports straight to `localhost`, an ingress controller
buys nothing here. Ports: 30080→8080 (UI), 30300→3000 (Grafana),
30900→9090 (Prometheus), 31567→15672 (RabbitMQ UI).
`templates/ingress.yaml` still exists but is `enabled: false` and
defaults to `className: traefik` for anyone who installs a maintained
controller themselves.

**StatefulSets for Postgres and RabbitMQ, Deployment for everything
else.** They own volumes and their identity matters. Prometheus and
Grafana keep a PVC but use `strategy: Recreate`, because a ReadWriteOnce
volume cannot be attached to the old and new pod simultaneously — with
the default RollingUpdate the new pod hangs in `Pending` forever.

**Redis with no volume at all.** `--save "" --appendonly no`. It caches
`latest:<city>` with a 120s TTL. Persisting a cache with a 2-minute TTL
is pure ceremony.

**Scrape config and Grafana datasource inline in templates, not in
`files/`.** Their targets contain the release name
(`weather-store:9091`), and `.Files.Get` does not run the template
engine. So `files/` holds only genuinely static assets: `init.sql` and
the dashboard JSON.

**No auto-updater, again.** The compose track lost Watchtower when it
was archived in Dec 2025, and nothing replaced it here. Argo CD's
`selfHeal` reverts *manual cluster edits* back to git; it does not chase
new image tags. Deploying stays a decision.

**Three nodes (1 control-plane + 2 workers).** One node would be lighter,
but then you never see scheduling, node affinity or a pod landing
somewhere surprising — which is half of what a local cluster is for. It
fits in 8 GB with the resource requests set as they are.

---

## 3. Traps that cost time (do not re-learn these)

**Postgres 18 data directory.** Postgres 18 expects its mount at
`/var/lib/postgresql`, not `/var/lib/postgresql/data`. Mount the old path
and the container refuses to start, complaining about data in an unused
mount. `postgres.mountPath` in values exists so nobody "tidies" it back.

**`relation "cities" does not exist`.** `files/init.sql` only runs when
the volume is genuinely empty. If a PVC predates a schema change, the new
table never appears and store crash-loops. Fix: `make clean && make
deploy` (this deletes the namespace and its PVCs — that is the point).
In the compose track this was a stale named volume; the failure mode is
identical, only the noun changed.

**fsGroup on the monitoring pods.** kind's local-path provisioner hands
out root-owned directories. Grafana runs as uid 472 and Prometheus as
65534, so without `securityContext.fsGroup` both fail on first write with
a permission error that looks like a config problem. RabbitMQ needs 999
for the same reason.

**`kind load` is not optional.** kind nodes run their own containerd, so
`docker build` on the host is invisible to the cluster. Without
`kind load docker-image`, pods sit in `ImagePullBackOff` trying to pull
`weather:dev` from Docker Hub, where it does not exist. This is also why
the chart uses `pullPolicy: IfNotPresent` — `Always` would break the
local flow entirely.

**A re-run of `bootstrap.sh` used to keep the old code.** `helm upgrade`
is a no-op when nothing in the chart changed, so the pods happily kept
the previously loaded `weather:dev` even though a new one had just been
loaded into the nodes. The script now detects an existing release and
restarts the three app deployments; `make image` does the same. If you
ever see your change not taking effect, that is the mechanism to check.

**Editing values used to have no effect on running pods.** Env comes
from the ConfigMap and Secret via `envFrom`, and Kubernetes does not
restart anything when those objects change — so `helm upgrade` after
editing `app.fetchInterval` reported success while every pod kept the old
value. The api, store, consumer and Grafana pod templates now carry a
`checksum/config` annotation over the rendered config, which changes the
pod template and forces a rollout. Same class of bug as the stale image;
both were silent, which is what made them worth hunting.

**Liveness probes could kill pods that were starting correctly.** store
retries Postgres for up to 60s before it serves HTTP, and the api waits
up to 60s for the store's first city list. The liveness probe (30s delay,
20s period, 3 failures) would fire at ~70s and restart a pod that was
simply still booting on a cold cluster. Both now have a `startupProbe`
(5s x 36 = 3 minutes of grace); liveness only takes over once startup
succeeds.

**Restarting by label was too broad.** `rollout restart deploy -l
app.kubernetes.io/part-of=weather` also cycled Grafana and Prometheus on
every code change. Both `make image` and the script now name the three
app deployments explicitly.

**Host ports 80/443 are no longer mapped.** They were, for a future
ingress controller, but a host that already runs anything on port 80
makes `kind create cluster` fail outright — an unused convenience
breaking the one command that has to work. `kind/cluster.yaml` documents
how to add them back if you enable ingress.

**CI Go version must equal `go.mod`.** `go.mod` says `go 1.26`; the
workflow pins `1.26`. Any older toolchain in CI fails on the first
command, every run.

**`helm lint` proves almost nothing.** It passes happily on templates
that render invalid Kubernetes objects. `helm template` and read the
output — that is what caught an indentation slip in the label blocks.

**`gofmt` proves nothing about correctness either.** Carried over from
the compose track: a rename once left three stale call sites in a
gofmt-clean file. Any rename gets an AST/`go vet` pass over the whole
package, not a formatter.

**`./generate.sh --force` used to fail.** The flag was read positionally
(`$1` = directory, `$2` = flag), so passing only `--force` made it the
directory name, and `mkdir -- force` then died on an unknown option. It
now parses arguments in a loop, accepts `--force` in any position, and
supports `-h`.

**`make test` left root-owned files in the repo.** The target bind-mounts
`app/` into a `golang:1.26-alpine` container, which runs as root, so
`go mod tidy` and protoc wrote `go.sum` and `genproto/` as root on the
host — after which your editor and the next `docker build` both hit
permission errors. It now passes `--user $(id -u):$(id -g)` with `HOME`,
`GOCACHE` and `GOPATH` pointed at `/tmp` so the toolchain still has
somewhere writable.

**Generator safety.** The old `generate.sh` opened with `rm -rf "$ROOT"`,
which is a career-limiting line if you ever run it in the wrong
directory. This one takes an optional target directory, refuses to write
into a non-empty one without `--force`, and never deletes anything.

---

## 4. Known limitations (honest list)

- **Single replica for every stateful component.** Postgres, Redis and
  RabbitMQ are one pod each. Scaling `store` or `consumer` up is safe;
  scaling the data layer needs operators (CloudNativePG, the RabbitMQ
  cluster operator) and is out of scope.
- **`app.replicas.api` above 1 duplicates work.** Every api pod runs its
  own fetch loop, so N pods means N calls to Open-Meteo and N published
  messages per interval. Readings are idempotent enough that nothing
  breaks, but it is wasteful. Splitting the fetch loop into a CronJob
  would be the correct fix.
- **Dev credentials are in `values.yaml`.** `admin`/`devpassword`, in
  plain text, rendered into a Secret. Fine for a laptop; for anything
  shared, use sealed-secrets or an external secret store.
- **Argo CD cannot build the image.** On a local cluster the image is
  loaded by hand, so "GitOps" covers manifests only. The real loop needs
  a registry (CI already pushes to GHCR) and the tag pinned in git.
- **No NetworkPolicies, no PodSecurity admission, no TLS.** Everything
  is plain HTTP inside one namespace.
- **No alerting.** Prometheus scrapes and Grafana draws; nothing pages.
- **Prometheus retention is whatever fits 2Gi**, and Grafana's own PVC is
  1Gi. On a long-running cluster they will fill.

---

## 5. Where things live

| Need | File |
| --- | --- |
| Change a hostname, port, image or credential | `charts/weather/values.yaml` |
| Local-only overrides | `charts/weather/values-kind.yaml` |
| Cluster shape and host port mappings | `kind/cluster.yaml` |
| One-command bring-up | `kind/bootstrap.sh` |
| Everything you type day to day | `Makefile` (`make help`) |
| DB schema and seeded cities | `charts/weather/files/init.sql` |
| Dashboard JSON | `charts/weather/files/grafana-dashboard-weather.json` |
| The spec this was built from | `PROMPT.md` |
| Recreate the whole tree | `generate.sh` |

---

## 6. First hour for someone new

```bash
./kind/bootstrap.sh          # ~3-4 min cold, mostly image pulls
make status                   # everything Running / Ready?
open http://localhost:8080    # UI with the three seeded cities
make logs                     # watch the fetch -> publish -> store chain
```

Then prove you can change something:

```bash
curl -X POST http://localhost:8080/cities -d 'city=Shiraz'
vim app/http_handlers.go && make image     # build, load, restart
make template | less                        # see what Helm actually sends
```

And when you want the GitOps track:

```bash
make gitops-up      # creates cluster 2, installs Argo CD, registers the app
make gitops REPO_URL=https://github.com/<you>/weather-kind.git
make argocd-password && make argocd-ui
```

`make gitops-up` is the entry point, not `make argocd`. Since the review
pass that gave every target an explicit `--context`, the Argo CD targets
point at `ARGO_CLUSTER` (`weather-gitops`) by default - so `make argocd`
on its own fails with a missing-context error until that cluster exists.
`make gitops-up` creates it first, then installs, then registers.

---

## 7. If it is broken

1. `make status` — which pod is unhappy?
2. `kubectl -n weather describe pod <name>` — events explain scheduling,
   volume and image failures. Read the bottom first.
3. `kubectl -n weather logs <pod>` — app-level failures.
4. `ImagePullBackOff` -> `make image`.
5. Postgres or store crash-looping on schema -> `make clean && make deploy`.
6. Nothing at `localhost:8080` -> was the cluster created with
   `kind/cluster.yaml`? Without its `extraPortMappings` the NodePorts are
   unreachable from the host.
7. Nuclear option, ~4 minutes: `make down && ./kind/bootstrap.sh`.

---

## 8. Environment notes

Built and intended for Ubuntu with Docker Engine (no Docker Desktop),
8 GB RAM. Requires `docker`, `kind`, `kubectl`, `helm` on PATH —
`bootstrap.sh` checks for all four before doing anything.

Behind network filtering, the Docker daemon needs the VPN for image
pulls (Docker Hub, ghcr.io, quay.io, raw.githubusercontent.com for the
Argo CD manifest). Open-Meteo, the actual data source, works without
one — so once the images are local, the stack runs VPN-free.

---

## 9. Version pins (checked at build time)

| Thing | Version | Note |
| --- | --- | --- |
| kind node image | `kindest/node:v1.37.0` | current; v1.36.4 also supported |
| Helm | >= 4.2.4 | Helm 3.21.x works; bug fixes ended Jul 2026, security fixes to Nov 2026 |
| Argo CD | v3.5.2 | only the 3 newest minors get patches |
| Postgres | 18.4-alpine | note the data-dir change |
| Redis | 8.8.0-alpine | |
| RabbitMQ | 4.3.2-management-alpine | management UI included |
| Prometheus | v3.12.0 | |
| Grafana | 13.1.0 | |
| Go | 1.26 | must match `go.mod` and CI |
| ingress-nginx | **not used** | retired; unmaintained since Mar 2026 |

Before bumping any of these, re-run the checks in `PROMPT.md` §0:
current stable, still maintained, and no breaking path/flag changes.

---

## 10. GitOps track (added after v1)

The auto-deploy story, and why it is shaped the way it is.

### 10.1 The gap Argo CD does not close by itself

Argo CD syncs **the chart from git**. It does not watch GHCR, so pushing a new
image changes nothing: git is identical, so the desired state is identical. For
auto-deploy, *something has to write the new image reference into git*. Here that
is CI's `bump` job (`.github/workflows/ci.yml`), which opens a pull request
pinning the digest into `charts/weather/values-gitops.yaml`. Merging is the
deploy.

Three options were considered:

1. **CI commits the reference back** (chosen). No extra controller, works with
   branch protection, and the deploy is a reviewable diff.
2. **Argo CD Image Updater.** A second controller that polls the registry and
   writes back itself. No CI changes, but another component to pin, another Git
   credential in a Secret, and another thing to debug when nothing deploys.
3. **`:latest` + `pullPolicy: Always` + restart.** No history, no rollback, no
   way to answer "what is running?" - structurally the same shape as the
   Watchtower incident that got Watchtower removed from the Compose track.

### 10.2 Why it is a second cluster

`selfHeal: true` means Argo CD actively reverts anything that does not match git.
On the dev cluster it would undo `make image` seconds after it finished, because
a locally built `weather:dev` is not something git can describe. The two
workflows are mutually exclusive per cluster, so they get one cluster each:
`weather` for iteration, `weather-gitops` for reconciliation.

`kind/bootstrap.sh --argocd` still works and now prints a warning when it is
pointed at the `weather` cluster.

### 10.3 Digest, not tag

`weather.image` in `_helpers.tpl` prefers `image.digest` over `image.tag`. A tag
can be overwritten and moved; a digest is content-addressed and cannot. So the
question "which build is live?" has exactly one answer, and `make gitops-status`
shows the git revision that answer came from.

Side effect worth knowing: a docs-only commit rebuilds to the *same* digest, so
the `bump` job produces no diff and no pull request. That is what stops the
merge -> build -> bump loop without needing `[skip ci]`.

### 10.4 Traps in this track (do not re-learn these)

- **Host port collisions.** Two kind clusters cannot map the same host port; the
  second one fails at `kind create cluster`. `cluster-gitops.yaml` uses 8082 /
  3001 / 9091 / 15673. The api is on 8082 rather than 8081 because `make
  argocd-ui` port-forwards the Argo CD UI to 8081.
- **GHCR package must be Public**, or the cluster cannot pull the image and you
  get `ImagePullBackOff` with an auth error. There is no `imagePullSecret` in the
  chart; adding one is the alternative.
- **"Allow GitHub Actions to create and approve pull requests"** must be enabled
  in repository settings, or `bump` fails with a 403 that mentions nothing about
  the setting.
- **`prometheus.enabled: false` and `grafana.enabled: false` on this cluster** are
  a memory decision, not a preference: Argo CD's own pods need roughly 400Mi.
  Turn them on if you have the RAM.
- **This cluster needs the internet.** Every sync pulls from `ghcr.io`, so the
  VPN has to be up. The dev cluster stays fully offline-capable.
- **Do not `helm upgrade` or `kubectl edit` the GitOps cluster.** selfHeal will
  revert it and the Argo CD UI will show you as drift. That is the feature.

### 10.5 `make smoke` / the chart test hook

`charts/weather/templates/tests/api-smoke.yaml` is a `helm.sh/hook: test` pod. It
checks api `/healthz`, store `/healthz`, and api `/cities`, and fails if the city
list comes back empty - which is the failure a `/healthz` check cannot see,
because api can be perfectly healthy while its gRPC link to store is broken.

It reuses the app image rather than pinning a curl image: it is already on the
node (so nothing is pulled, and it works offline), and it is one less version to
keep updated. The base is Alpine, so busybox `wget` is there.

CI's `e2e` job runs the same hook, replacing the old hand-rolled port-forward and
`curl`. One definition of "it works", used in both places.

### 10.6 Renovate

`renovate.json` covers what standard managers miss: `kindest/node` in both
cluster files, `ARGOCD_VERSION` in the Makefile and `bootstrap.sh`, and the
protoc plugin versions that are pinned identically in three places. Minor and
patch image bumps are batched; majors and `kindest/node` always get their own
pull request, because a major bump here is a behaviour change, not a version
string change - see the Postgres 18 data-directory trap in section 3.

### 10.7 Traps found in the review pass after the GitOps track landed

Three bugs, all of them created by the mere existence of a second cluster.
They are fixed; this is here so they are not reintroduced.

**1. `make` targets trusted the current kubectl context.**
`kind create cluster` switches the context as a side effect, so after
`make gitops-up` the shell pointed at `kind-weather-gitops`. A following
`make image` would then build, `kind load` into the *default* cluster (that
flag was already explicit), and `rollout restart` on the *GitOps* cluster -
restarting pods there to pull the same GHCR digest, while the freshly built
code sat unused in the other cluster. Nothing errors; you just debug a change
that never deployed. Now every recipe goes through `$(KUBECTL)` / `$(HELM)`,
which carry `--context kind-$(CLUSTER)`, and Argo CD's targets go through
`$(ARGO_KUBECTL)` with `ARGO_CLUSTER ?= $(GITOPS_CLUSTER)`. `gitops-up` no
longer runs `kubectl config use-context` at all - a build tool should not
reach out and change the state of your shell.

**2. `bootstrap.sh` decided "was this already installed?" before it had a
cluster.** The `helm status` probe sat above `create_cluster`, so it answered
for whatever context was current. With the GitOps cluster active it answered
"no release" for the dev cluster, which skips `restart_app` - which is exactly
the stale-image bug that check exists to prevent (a re-run loads a new
`weather:dev`, Helm sees no manifest change, pods keep the old image). Moved
below `create_cluster`, which is what pins the context.

**3. The `helm test` pod would have been applied by Argo CD.** Argo CD renders
the chart with `helm template` and applies the output; its Helm-hook mapping
covers `pre-install`/`post-install`/etc. and ignores `test-success` and
`test-failure`, but plain `helm.sh/hook: test` (the Helm 3 spelling this chart
uses) is not in that table. An unrecognised hook is not a hook, so the pod
would have been synced as an ordinary resource, re-run on every sync, and a
failure would have shown up as the Application being `Degraded`. It now also
carries `argocd.argoproj.io/hook: Skip`, which Argo CD honours unambiguously:
never applied. `helm test` still finds it, because Helm reads its own
annotation and ignores Argo CD's.

Related, and not a bug but worth stating: **`make smoke` only works on the
default cluster and in CI.** It is `helm test`, and there is no Helm release on
the GitOps cluster - Argo CD applied manifests, it did not install a release.
There, `make gitops-status` plus the UI on `http://localhost:8082` is the check.

### 10.8 Running one cluster at a time

8GB does not comfortably hold both. `docker stop`/`docker start` on the node
containers parks a cluster with images, volumes and PVC data intact - see
"Running one cluster at a time" in the README for the exact container names
(`weather-control-plane`, `weather-worker`, `weather-worker2`, and
`weather-gitops-control-plane`). Two things surprise people: the host ports
(8080, 3000, 9090, 15672) are only bound while the containers run, and pods
take 30-90s to come back after a start. Neither is a fault.

### 10.9 Two first-sync blockers in the Argo CD manifests

Both of these would have made the *first* `make gitops-up` fail, and both fail
with an Argo CD message that reads like a permissions bug rather than a config
mistake.

**1. `clusterResourceWhitelist: []` blocked namespace creation.** The
Application syncs with `CreateNamespace=true`, and Argo CD validates that
creation against the AppProject's cluster-resource allow-list. An empty list is
not "no cluster-scoped objects in the chart", it is "no cluster-scoped objects
at all", so the sync failed with `Namespace "weather" is not permitted in
project "weather"`. On the dev cluster this never showed up because
`helm --create-namespace` makes the namespace, and on the GitOps cluster
nothing else creates it. The project now allows exactly `{group: "", kind:
Namespace}` and nothing more.

**2. `make gitops REPO_URL=...` only patched the Application.** The AppProject's
`sourceRepos` is also an allow-list. Patching the Application to point at your
fork while the project still listed the original repo produced
`application repo ... is not permitted in project 'weather'`. The target now
runs the same `sed` over both files. They are applied as two separate commands
on purpose: piping two YAML files into one `kubectl apply` without a `---`
separator is not a valid stream, it is one document with duplicate keys.

General lesson for this track: an Argo CD AppProject is two allow-lists and a
destination, and *empty means deny*. If a sync fails with "not permitted in
project", read `project.yaml` before reading anything else.

### 10.10 Pins nothing was watching, and a values file nothing was checking

None of these broke the tree as it stands. They were all traps set for a future
change, which is the kind that costs the most time to diagnose.

**`kindest/node` was pinned in five places and managed in four.** The custom
manager matched `kind/cluster*.yaml`, but CI's e2e job pins `node_image`
separately. A Kubernetes bump would have updated both clusters and left CI
validating a version nobody runs - the exact drift the pinning exists to
prevent. The manager now covers `ci.yml` too; the existing `image:` pattern
already matches `node_image:`, since it is a substring.

**CI's `GO_VERSION` was unmanaged while its group-mates were not.** `go.mod` is
handled by the gomod manager and `golang:1.26-alpine` by the dockerfile manager,
so a grouped "go toolchain" bump would have moved both and left `GO_VERSION` at
1.26 - producing a pull request that fails immediately with `go.mod requires
go >= 1.27`. Safe, but pre-broken on arrival, and the comment above that line
already says all three must move together. It now has a custom manager using
the `golang-version` datasource, with the version trimmed to major.minor to
match how it is written.

**The `helm` and `kind` binary versions were unmanaged.** `azure/setup-helm` and
`helm/kind-action` take their versions as `with:` inputs, and the
`github-actions` manager only reads `uses:` refs. Both now have custom managers
(`helm/helm` and `kubernetes-sigs/kind`, via github-releases). Note that `kind`
and `kindest/node` version independently - do not group them.

**Nothing validated `values-gitops.yaml`.** The `chart` job linted and rendered
only `values-kind.yaml`, and `e2e` installs with `--set` overrides. Yet
`values-gitops.yaml` is the only values file a *machine* writes to: the bump job
seds a digest into it. A corrupted write would have passed every check and
surfaced as an Argo CD `ComparisonError` on the cluster. The `chart` job now
lints and renders it as well, and the bump job re-renders the chart after its
own `sed` and greps for `@<digest>` in the output - proving both that the chart
still renders and that the digest reached the pod spec, before anyone is asked
to merge.

Also corrected while in there: `NOTES.txt` advertised Grafana and Prometheus
unconditionally (wrong on the GitOps cluster, where both are off) and printed
the dev cluster's host ports as if they were universal; and
`cluster-gitops.yaml` claimed the ports were "shifted by one", which they are
not - the api is on 8082 precisely because 8081 belongs to the Argo CD UI, as
the next paragraph of the same comment said. The two host ports that map to
disabled services are now documented as deliberate: kind cannot add port
mappings to an existing cluster, so keeping them means enabling monitoring
later needs no rebuild.

**Standing rule this pass suggests:** every version string in this repo should
be matched by exactly one manager. When adding a pin, grep for how many places
it appears before assuming a standard manager sees it.

**Escaping note for whoever edits `renovate.json` next:** a regex needing a
literal double quote inside a JSON string is two escaping layers deep and easy
to get wrong (it broke this file once during this very edit). `[^0-9]*` or a
character class spans the quote without quoting it - prefer that.

### 10.11 Three small ones, and why the first was not small

**Section 6's GitOps quickstart still said `make argocd` first.** That was right
when Argo CD went on whichever cluster your context happened to point at. It has
been wrong since the review pass that gave every target an explicit `--context`:
the Argo CD targets now default to `ARGO_CLUSTER` (`weather-gitops`), so
`make argocd` before that cluster exists fails with a missing-context error, and
the first thing a new reader does is hit it. `make gitops-up` is the entry
point. Worth noting the shape of this bug: fixing the context bug in pass 5 was
correct, and it silently invalidated a code sample four sections away. Grep the
docs for a command whenever you change what that command does.

**`make help` omitted `clean`, `argocd-password` and `argocd-ui`.** They existed,
were documented in the README, and were invisible in the one place you look
when you have forgotten the command. The help text also said `argocd` installs
"into the cluster", which is no longer specific enough to be true - it says
`ARGO_CLUSTER` now. The verification script now diffs `make help` against the
real target list, so a target added without a help line fails the check.

**`make smoke` hid its own failure output.** `helm test` without `--logs` reports
only that the pod failed, and `hook-delete-policy` may have deleted the pod
before you can read it - so the one command whose entire job is to tell you what
broke told you the least. Added `--logs`. CI already dumped the logs explicitly,
which is why this never showed up there.

### 10.12 bootstrap.sh still assumed there was only one cluster

Two leftovers from before the second cluster existed. Both were in the one
script that a new reader runs first.

**It applied the Application before the AppProject.** `kubectl apply -f
gitops/argocd/` walks the directory alphabetically, so `application.yaml` went
first and Argo CD rejected it - `Application referencing project weather which
does not exist` - until the project landed a moment later and the next sync
cleaned it up. Self-healing, but it puts a real error in the log of a script
whose whole promise is that it just works. Both files are now applied
explicitly, project first, matching what `make gitops` already did.

**Its closing summary always printed the dev cluster's URLs.** The script takes
`CLUSTER`, `CLUSTER_CONFIG` and `VALUES` from the environment precisely so it
can bring up the GitOps cluster too - but the summary was a fixed heredoc, so
running it that way ended by advertising ports 8080/3000/9090/15672, of which
the first is the wrong cluster's and two are components `values-gitops.yaml`
switches off. It now prints that list only for the default cluster and points
anywhere else at `make gitops-urls`. Same bug that was in `NOTES.txt`; this
copy was missed because the script hardcodes what the chart templates.

### 10.13 Three bugs the first real run found

Eight static review passes did not catch any of these. All three needed a
machine with docker, kind, helm and a GitHub repo attached.

**`make smoke` failed against a perfectly healthy release.** The pod fetched
`/cities`, got five cities back, printed them, and then said `no cities
returned` and exited 1. The test grepped for `"name"`; `cityCoord` in
`city_cache.go` carries no json tags, so `encoding/json` emits the Go field
names - `"Name"`, `"Lat"`, `"Lon"`. The assertion, not the app, was wrong. Note
which way this failure points: a test that says "broken" about something that
works costs more than no test, because the next person debugs the wrong end.
The pattern now matches `"Name"`. If json tags are ever added to `cityCoord`,
this line has to change with them.

**`make test` reported `proto/weather.proto: No such file or directory`.** The
file is there. The target mounted `$(PWD)/app`, and `PWD` comes from the shell,
so it can be a logical path - a symlinked directory, an automounted home. Docker
resolves the mount source on the host and, when it does not exist, *creates an
empty directory* rather than failing. So the mount succeeded, `/src` was empty,
`go install` still worked (network, not disk), and the first thing to touch a
repo file - protoc - reported a missing proto. It now uses `$(CURDIR)`, which
make computes itself, and checks `app/proto/weather.proto` exists before
starting the container.

**CI's failure diagnostics became the failure.** The e2e job's `Dump state on
failure` step ran `kubectl` with no `|| true`. When the cluster is not up,
kubectl exits 1, so that step turned red - and it was the only red step, with
`The connection to the server localhost:8080 was refused` as the entire visible
cause. Every line now ends in `|| true` and the step is `continue-on-error`, so
the step that actually broke stays the red one.

Benign, for reference: the consumer logs `addReading: rpc error: code =
DeadlineExceeded` once or twice at startup. It is publishing before store has
finished connecting to Postgres; RabbitMQ redelivers and the reading lands a few
seconds later. Consistent with the log showing `stored id=1` right after.

### 10.14 Two more from the first real run

**A passing smoke test reported failure.** `helm test` printed `Phase:
Succeeded` and then `make smoke` exited 1 with `unable to get pod logs for
weather-smoke: pods "weather-smoke" not found`. Two of my own changes
collided: `--logs` (added so a failing test shows its output) and
`helm.sh/hook-delete-policy: ...,hook-succeeded` (which deletes the pod the
instant it passes). Helm deleted the pod, then went looking for its logs.
Fix: drop `hook-succeeded`. `before-hook-creation` still guarantees one pod at
a time, and the pod that stays behind is exactly what `--logs` needs. Second
time in three passes that the test harness, not the app, was the liar.

**CI's e2e job never got a cluster.** Not our chart, not our image - kind
itself:

    x Starting control-plane
    ERROR: failed to create cluster: failed to init node with kubeadm
    error: your configuration file uses an old API spec: "kubeadm.k8s.io/v1beta3"

kind generates the kubeadm config and chooses its API version from the target
Kubernetes release - v1beta3 through 1.35.x, v1beta4 from 1.36.0 - and v1beta4
support landed after kind v0.31.0. Kubernetes 1.37 removed v1beta3. So the
workflow's `version: v0.31.0` and `node_image: kindest/node:v1.37.0` were
mutually exclusive, while the same node image worked locally because the local
kind is newer. CI now pins v0.33.0, and README's Versions section states the
pairing.

What this cost, and the lesson: eleven static passes could not have found it.
`helm lint`, `helm template`, YAML and JSON validation, cross-file grep - all
pass, because nothing in any file is malformed. The incompatibility exists only
between a binary version and an image version, and only surfaces when something
really calls `kubeadm init`. Two independently correct pins, wrong together.
This is what `renovate.json`'s custom managers are for: one watches `version:`
under `helm/kind-action`, another watches `kindest/node` in both
`kind/cluster.yaml` and `ci.yml`, so the pair moves together instead of
drifting apart.
KINDGEN_EOF

cat > "Makefile" <<'KINDGEN_EOF'
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
KINDGEN_EOF

cat > "PROMPT.md" <<'KINDGEN_EOF'
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
KINDGEN_EOF

cat > "README.md" <<'KINDGEN_EOF'
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

One pairing to respect: the **kind CLI must be v0.32.0 or newer** for
the v1.37.0 node image. kind writes the kubeadm config, and only
v0.32+ writes the v1beta4 format that Kubernetes 1.37 accepts - older
kind fails at `kubeadm init` with `old API spec: kubeadm.k8s.io/v1beta3`
before the control plane ever starts. Check with `kind version`. CI
pins v0.33.0 in `.github/workflows/ci.yml` for the same reason.

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
KINDGEN_EOF

cat > "renovate.json" <<'KINDGEN_EOF'
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "timezone": "Asia/Tehran",
  "schedule": ["before 9am on monday"],
  "prConcurrentLimit": 3,
  "labels": ["dependencies"],
  "packageRules": [
    {
      "description": "Patch and minor bumps of the data layer are safe to batch; CI installs the chart in a real kind cluster before any of them can merge.",
      "matchDatasources": ["docker"],
      "matchUpdateTypes": ["minor", "patch"],
      "groupName": "container images"
    },
    {
      "description": "Majors get their own PR. Postgres 18 moved its data directory - a major bump here is a behaviour change, never a version string change.",
      "matchDatasources": ["docker"],
      "matchUpdateTypes": ["major"],
      "labels": ["dependencies", "breaking"],
      "groupName": null
    },
    {
      "description": "The kind node image decides the Kubernetes version. Always alone, always read the kind release notes first.",
      "matchPackageNames": ["kindest/node"],
      "groupName": null,
      "labels": ["dependencies", "kubernetes"]
    },
    {
      "description": "Go toolchain: go.mod, the Dockerfile builder and CI's GO_VERSION must move together or CI fails on the first run.",
      "matchPackageNames": ["go", "golang", "golang/go"],
      "groupName": "go toolchain"
    },
    {
      "description": "Actions are low risk and noisy; batch them.",
      "matchManagers": ["github-actions"],
      "groupName": "github actions"
    }
  ],
  "customManagers": [
    {
      "description": "kindest/node, which no standard manager understands. Both cluster files AND ci.yml: the e2e job pins node_image separately, and if it lags behind, CI validates a Kubernetes version nobody runs.",
      "customType": "regex",
      "managerFilePatterns": [
        "/^kind/cluster.*\\.yaml$/",
        "/^\\.github/workflows/ci\\.yml$/"
      ],
      "matchStrings": ["image:\\s*(?<depName>kindest/node):(?<currentValue>v[0-9.]+)"],
      "datasourceTemplate": "docker"
    },
    {
      "description": "Argo CD, pinned in the Makefile and installed from a versioned manifest URL.",
      "customType": "regex",
      "managerFilePatterns": ["/^Makefile$/", "/^kind/bootstrap.sh$/"],
      "matchStrings": ["ARGOCD_VERSION\\s*[?:]?=\\s*\"?(?<currentValue>v[0-9.]+)\"?", "ARGOCD_VERSION:-(?<currentValue>v[0-9.]+)"],
      "depNameTemplate": "argoproj/argo-cd",
      "datasourceTemplate": "github-releases"
    },
    {
      "description": "protoc plugin versions, pinned identically in the Makefile, the Dockerfile and CI.",
      "customType": "regex",
      "managerFilePatterns": [
        "/^Makefile$/",
        "/^app/Dockerfile$/",
        "/^\\.github/workflows/ci\\.yml$/"
      ],
      "matchStrings": ["(?<depName>google\\.golang\\.org/[^@\\s]+)@(?<currentValue>v[0-9.]+)"],
      "datasourceTemplate": "go"
    },
    {
      "description": "CI's Go version. No standard manager sees it, and it has to move together with go.mod and the Dockerfile builder - otherwise the toolchain PR arrives with setup-go on the old version and the first step fails with 'go.mod requires go >= ...'. Trimmed to major.minor to match how it is written.",
      "customType": "regex",
      "managerFilePatterns": ["/^\\.github/workflows/ci\\.yml$/"],
      "matchStrings": ["GO_VERSION:[^0-9]*(?<currentValue>[0-9]+\\.[0-9]+)"],
      "depNameTemplate": "go",
      "datasourceTemplate": "golang-version",
      "extractVersionTemplate": "^(?<version>[0-9]+\\.[0-9]+)"
    },
    {
      "description": "The helm binary CI installs. This is a `with:` input, so the github-actions manager - which only reads `uses:` refs - never touches it.",
      "customType": "regex",
      "managerFilePatterns": ["/^\\.github/workflows/ci\\.yml$/"],
      "matchStrings": ["azure/setup-helm@v[0-9]+\\n\\s+with:\\n\\s+version: (?<currentValue>v[0-9.]+)"],
      "depNameTemplate": "helm/helm",
      "datasourceTemplate": "github-releases"
    },
    {
      "description": "The kind binary CI installs, same blind spot as helm. Note this is kind itself, not kindest/node - the two version independently.",
      "customType": "regex",
      "managerFilePatterns": ["/^\\.github/workflows/ci\\.yml$/"],
      "matchStrings": ["helm/kind-action@v[0-9]+\\n\\s+with:\\n\\s+version: (?<currentValue>v[0-9.]+)"],
      "depNameTemplate": "kubernetes-sigs/kind",
      "datasourceTemplate": "github-releases"
    }
  ]
}
KINDGEN_EOF

cat > ".github/workflows/ci.yml" <<'KINDGEN_EOF'
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  # Must match go.mod and app/Dockerfile. A CI runner on an older
  # toolchain than the module requires fails on the very first run.
  GO_VERSION: "1.26"

jobs:
  # ---- 1. the Go code -------------------------------------------------
  test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: app
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
      - name: Install protoc and plugins
        run: |
          sudo apt-get update
          sudo apt-get install -y protobuf-compiler
          go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11
          go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
          echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"
      - name: Generate gRPC stubs
        run: |
          protoc --go_out=. --go_opt=module=weather \
                 --go-grpc_out=. --go-grpc_opt=module=weather \
                 proto/weather.proto
      - name: Vet and test
        run: |
          go mod tidy
          go vet ./...
          go test ./...

  # ---- 2. the chart ---------------------------------------------------
  chart:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@v4
        with:
          version: v4.2.4
      - name: Lint and render
        run: |
          helm lint charts/weather --values charts/weather/values-kind.yaml
          helm template weather charts/weather \
            --values charts/weather/values-kind.yaml > /dev/null
          # values-gitops.yaml needs this more than values-kind.yaml does,
          # not less: it is the one values file a machine writes to (the
          # bump job seds a digest into it). Unchecked, a bad write shows
          # up as an Argo CD ComparisonError on the cluster instead of a
          # red check on the pull request.
          helm lint charts/weather --values charts/weather/values-gitops.yaml
          helm template weather charts/weather \
            --values charts/weather/values-gitops.yaml > /dev/null

  # ---- 3. does it actually run on Kubernetes? -------------------------
  # A real kind cluster in CI, so a broken manifest fails here instead of
  # on the laptop.
  e2e:
    needs: [test, chart]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@v4
        with:
          version: v4.2.4
      # These two versions are one pin, not two. kind generates the
      # kubeadm config itself and picks the API version from the target
      # Kubernetes release: v1beta3 up to 1.35.x, v1beta4 from 1.36.0 -
      # and that v1beta4 support landed after kind v0.31.0. Kubernetes
      # 1.37 removed v1beta3 outright, so kind v0.31.0 with this node
      # image fails at `kubeadm init` with "old API spec" and the
      # cluster never starts. Bump both together or neither.
      - uses: helm/kind-action@v1
        with:
          version: v0.33.0
          node_image: kindest/node:v1.37.0
          cluster_name: weather-ci
      - name: Build and load image
        run: |
          docker build -t weather:ci app
          kind load docker-image weather:ci --name weather-ci
      - name: Install chart
        run: |
          helm upgrade --install weather charts/weather \
            --namespace weather --create-namespace \
            --set image.tag=ci \
            --set nodePorts.enabled=false \
            --wait --timeout 10m
      # The chart's own test hook, so CI and `make smoke` check exactly
      # the same thing: api -> store gRPC -> Postgres, not just /healthz.
      - name: Smoke test the release
        run: helm test weather --namespace weather --timeout 5m
      - name: Smoke test output
        if: always()
        run: kubectl -n weather logs weather-smoke || true
      # Diagnostics only. Every line ends in `|| true`: if the cluster
      # never came up, kubectl exits 1 here and THIS step becomes the
      # only red one in the run, hiding the step that actually failed.
      - name: Dump state on failure
        if: failure()
        continue-on-error: true
        run: |
          kubectl -n weather get pods -o wide || true
          kubectl -n weather describe pods || true
          kubectl -n weather logs -l app.kubernetes.io/part-of=weather --all-containers --tail=100 || true
          kubectl get nodes -o wide || true

  # ---- 4. publish -----------------------------------------------------
  build-and-push:
    needs: e2e
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    permissions:
      contents: read
      packages: write
    # Passed to the bump job below. This is the digest of what was
    # actually pushed - the one thing a tag cannot be trusted to tell you.
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=latest
            type=sha,format=short
      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          context: ./app
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  # ---- 5. hand the new image to GitOps --------------------------------
  # Argo CD deploys what git says, and git does not change when a new
  # image is pushed - so something has to write the new reference back.
  # That is this job. It opens a pull request instead of pushing to main:
  # you get a diff to approve, branch protection still applies, and CI
  # does not trigger itself in a loop.
  #
  # Requires: Settings -> Actions -> General -> "Allow GitHub Actions to
  # create and approve pull requests". Without it this job fails with a
  # 403 and nothing else explains why.
  bump:
    needs: build-and-push
    runs-on: ubuntu-latest
    if: github.event_name == 'push'
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - name: Pin the digest that was just pushed
        env:
          DIGEST: ${{ needs.build-and-push.outputs.digest }}
        run: |
          test -n "$DIGEST" || { echo "build-and-push produced no digest" >&2; exit 1; }
          sed -i -E "s|^(  digest: ).*|\1\"$DIGEST\"|" charts/weather/values-gitops.yaml
          grep -n '  digest:' charts/weather/values-gitops.yaml
      # Prove the edit produced a chart that still renders, and that the
      # digest actually reached the pod spec, before asking anyone to merge.
      - uses: azure/setup-helm@v4
        with:
          version: v4.2.4
      - name: Check the chart renders with the new digest
        env:
          DIGEST: ${{ needs.build-and-push.outputs.digest }}
        run: |
          helm template weather charts/weather \
            --values charts/weather/values-gitops.yaml \
            | grep -qF "@$DIGEST" \
            || { echo "rendered manifests do not reference $DIGEST" >&2; exit 1; }
      # No change means the image content did not change (the digest is
      # content-addressed, so a docs-only commit rebuilds to the same
      # digest). In that case this action does nothing at all, which is
      # what stops the merge -> build -> bump loop.
      - name: Open the deploy pull request
        uses: peter-evans/create-pull-request@v7
        with:
          branch: deploy/image-digest
          delete-branch: true
          commit-message: "deploy: pin image ${{ needs.build-and-push.outputs.digest }}"
          title: "deploy: pin image digest"
          labels: deploy
          body: |
            CI built and pushed a new image. Merging this pull request is
            what deploys it: Argo CD syncs `charts/weather` on the
            `weather-gitops` cluster and rolls the three app deployments.

            - digest: `${{ needs.build-and-push.outputs.digest }}`
            - commit: ${{ github.sha }}

            The digest is immutable, so what gets deployed is exactly
            what the checks above passed on.
KINDGEN_EOF

cat > "app/.dockerignore" <<'KINDGEN_EOF'
genproto/
*.md
KINDGEN_EOF

cat > "app/Dockerfile" <<'KINDGEN_EOF'
# ---- build stage: generate gRPC stubs + compile ----
FROM golang:1.26-alpine AS build
RUN apk add --no-cache protobuf protobuf-dev git
ENV GOBIN=/go/bin
ENV PATH="/go/bin:${PATH}"
WORKDIR /src

RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 \
 && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2

COPY go.mod ./
COPY proto ./proto
RUN protoc --go_out=. --go_opt=module=weather \
           --go-grpc_out=. --go-grpc_opt=module=weather \
           proto/weather.proto

COPY *.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 go build -trimpath -o /weather .

# ---- runtime stage ----
FROM alpine:3.24
RUN apk add --no-cache ca-certificates wget
COPY --from=build /weather /weather
ENTRYPOINT ["/weather"]
KINDGEN_EOF

cat > "app/api.go" <<'KINDGEN_EOF'
package main

import (
	"fmt"
	"log"
	"time"

	pb "weather/genproto"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// apiConfig is every environment-derived setting runAPI needs, gathered in
// one place so the rest of this file reads configuration once, up front,
// instead of calling getenv() scattered throughout.
type apiConfig struct {
	amqpURL   string
	queue     string
	interval  time.Duration
	storeAddr string // gRPC address, e.g. "weather-store:9090"
	storeHTTP string // REST base URL, e.g. "http://weather-store:9091"
}

func loadAPIConfig() apiConfig {
	return apiConfig{
		amqpURL: fmt.Sprintf("amqp://%s:%s@%s:%s/",
			getenv("RABBITMQ_DEFAULT_USER", "admin"),
			getenv("RABBITMQ_DEFAULT_PASS", ""),
			getenv("AMQP_HOST", "rabbitmq"),
			getenv("AMQP_PORT", "5672")),
		queue:     getenv("QUEUE", "weather.readings"),
		interval:  mustDuration("FETCH_INTERVAL", "300s"),
		storeAddr: getenv("STORE_ADDR", "weather-store:9090"),
		storeHTTP: getenv("STORE_HTTP_ADDR", "http://weather-store:9091"),
	}
}

// runAPI is the entire life of the `api` mode, top to bottom: load config,
// connect to store, make sure we know the current city list, then start
// the two things that run forever - the HTTP server and the fetch loop.
//
// Each step below is its own small function purely so this one reads like
// a table of contents. If you want the details of any one step, go to that
// function - you shouldn't need to read this whole thing to understand any
// single part of it.
func runAPI() {
	cfg := loadAPIConfig()

	conn := mustDialStore(cfg.storeAddr)
	defer conn.Close()
	store := pb.NewWeatherStoreClient(conn)

	waitForInitialCityList(cfg.storeHTTP)
	go refreshCityListPeriodically(cfg.storeHTTP)
	go serveHTTP(store, cfg.storeHTTP)

	runFetchLoop(cfg)
}

// mustDialStore opens the gRPC connection to weather-store. "must" because
// there's nothing sensible to do if this fails at startup - api can't work
// at all without a store client, so we fail loudly and let Docker's
// restart policy try again.
func mustDialStore(addr string) *grpc.ClientConn {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("api: cannot create store client: %v", err)
	}
	return conn
}

// waitForInitialCityList blocks until store answers with a real city list,
// so the very first fetch cycle has actual cities to work with instead of
// an empty one. Retries because store itself might still be starting -
// Docker starts containers in parallel, it doesn't wait for dependencies
// to be fully ready by default.
func waitForInitialCityList(storeHTTP string) {
	const attempts = 30
	const delay = 2 * time.Second

	for i := 0; i < attempts; i++ {
		if list, err := listCities(storeHTTP); err == nil {
			setCities(list)
			return
		}
		time.Sleep(delay)
	}
	log.Printf("api: could not reach store for initial city list after %d attempts, starting with an empty list", attempts)
}

// refreshCityListPeriodically keeps the in-memory cache in sync with
// Postgres for as long as the process runs. This is what makes a city
// added directly in the database (outside this app's own UI) eventually
// show up here too, without a restart. Intended to run in its own
// goroutine (`go refreshCityListPeriodically(...)`) - it never returns.
func refreshCityListPeriodically(storeHTTP string) {
	const interval = 30 * time.Second
	for {
		time.Sleep(interval)
		if list, err := listCities(storeHTTP); err == nil {
			setCities(list)
		}
	}
}

// runFetchLoop is the heartbeat of the whole app: every FETCH_INTERVAL,
// fetch and publish weather for whatever cities are currently tracked.
// Never returns - this is meant to be the last thing runAPI calls.
func runFetchLoop(cfg apiConfig) {
	log.Printf("api: fetch loop every %s", cfg.interval)
	for {
		publishAll(cfg.amqpURL, cfg.queue, getCities())
		time.Sleep(cfg.interval)
	}
}
KINDGEN_EOF

cat > "app/city_cache.go" <<'KINDGEN_EOF'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// cityCoord is a city name plus the coordinates Open-Meteo needs to fetch
// its weather. This is the one shared "city" shape used everywhere in the
// api binary - the cache below, the HTTP calls to store, and the JSON sent
// to the browser all use this same struct.
type cityCoord struct {
	Name string
	Lat  float64
	Lon  float64
}

// parseCities turns the CITIES env var format ("Name:lat:lon,Name:lat:lon")
// into a slice of cityCoord. Used exactly once, by store, to seed the
// database on the very first boot (see seedCities in store.go) - nothing
// in api.go should ever call this to build its working city list; that
// always comes from the database (see listCities below).
//
// Malformed entries (wrong number of ":"-separated parts) are silently
// skipped rather than crashing the whole app over one typo in .env.
func parseCities(s string) []cityCoord {
	var out []cityCoord
	for _, part := range strings.Split(s, ",") {
		fields := strings.Split(strings.TrimSpace(part), ":")
		if len(fields) != 3 {
			continue
		}
		lat, _ := strconv.ParseFloat(fields[1], 64)
		lon, _ := strconv.ParseFloat(fields[2], 64)
		out = append(out, cityCoord{Name: fields[0], Lat: lat, Lon: lon})
	}
	return out
}

// --- in-memory cache -------------------------------------------------------
//
// activeCities is api's own local copy of "which cities are we tracking."
// It exists purely so the fetch loop and the HTTP handlers don't have to
// make a network call to store every single time they need the list.
//
// The database (via store's /cities endpoint) is always the source of
// truth. This cache is refreshed from the database - at startup, every 30
// seconds, and immediately whenever a city is added through the UI - it is
// never the other way around. If you're tempted to update activeCities by
// hand (e.g. "just append the new city"), don't: re-read from the database
// instead, so the cache can never drift from what's actually stored.

var (
	citiesMu     sync.RWMutex
	activeCities []cityCoord
)

// getCities returns a snapshot of the current city list. It copies the
// slice before returning it so callers can't accidentally mutate the
// cache's backing array through the returned slice.
func getCities() []cityCoord {
	citiesMu.RLock()
	defer citiesMu.RUnlock()
	out := make([]cityCoord, len(activeCities))
	copy(out, activeCities)
	return out
}

// setCities replaces the cached list wholesale. Always call this with a
// list that just came from the database (listCities below) - never with a
// hand-edited copy of the old list.
func setCities(cities []cityCoord) {
	citiesMu.Lock()
	activeCities = cities
	citiesMu.Unlock()
}

// --- talking to store's /cities endpoint ------------------------------------
//
// store owns the `cities` table in Postgres and is the only thing allowed
// to touch it directly (same rule as weather_readings). api reaches it
// through store's small REST surface on :9091, not gRPC - these two
// functions are the entire interface.

// listCities reads the full, current city list straight from the database.
// This is the only way api's cache ever learns about a city - whether it
// was added through this app's own UI or inserted directly with psql.
func listCities(storeHTTP string) ([]cityCoord, error) {
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(storeHTTP + "/cities")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("store /cities: status %d", resp.StatusCode)
	}
	var cities []cityCoord
	if err := json.NewDecoder(resp.Body).Decode(&cities); err != nil {
		return nil, err
	}
	return cities, nil
}

// addCityToStore asks store to persist a new city (name + coordinates
// already resolved by geocodeCity). store does the actual
// INSERT ... ON CONFLICT DO UPDATE - this function just makes the HTTP call
// and turns a non-200 response into a Go error.
func addCityToStore(storeHTTP string, c cityCoord) error {
	body, _ := json.Marshal(c)
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(storeHTTP+"/cities", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("store /cities: status %d: %s", resp.StatusCode, strings.TrimSpace(string(errBody)))
	}
	return nil
}
KINDGEN_EOF

cat > "app/city_cache_test.go" <<'KINDGEN_EOF'
package main

import (
	"fmt"
	"sync"
	"testing"
)

func TestGetSetCities(t *testing.T) {
	setCities(nil) // start from a known, empty state
	if got := getCities(); len(got) != 0 {
		t.Fatalf("expected empty cache, got %d cities", len(got))
	}

	want := []cityCoord{
		{Name: "Tehran", Lat: 35.6892, Lon: 51.3890},
		{Name: "Paris", Lat: 48.8566, Lon: 2.3522},
	}
	setCities(want)

	got := getCities()
	if len(got) != len(want) {
		t.Fatalf("expected %d cities, got %d", len(want), len(got))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("city %d: expected %+v, got %+v", i, want[i], got[i])
		}
	}
}

// TestGetCitiesReturnsACopy is the whole reason getCities copies the
// slice before returning it: a caller mutating what it got back must
// never be able to corrupt the cache's own backing array.
func TestGetCitiesReturnsACopy(t *testing.T) {
	setCities([]cityCoord{{Name: "Tehran", Lat: 35.6892, Lon: 51.3890}})

	got := getCities()
	got[0].Name = "Corrupted"

	again := getCities()
	if again[0].Name != "Tehran" {
		t.Fatalf("cache was corrupted through a returned slice: got %q", again[0].Name)
	}
}

// TestConcurrentCityCacheAccess exercises the cache the way this app
// actually uses it: one path periodically replacing the whole list
// (refreshCityListPeriodically), many others reading it at the same time
// (every HTTP request). Run with `go test -race` to actually catch a
// broken mutex - without -race this test can pass even if the locking
// were wrong.
func TestConcurrentCityCacheAccess(t *testing.T) {
	var wg sync.WaitGroup

	for w := 0; w < 5; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				setCities([]cityCoord{
					{Name: fmt.Sprintf("writer-%d-city-%d", id, i), Lat: 1, Lon: 2},
				})
			}
		}(w)
	}

	for r := 0; r < 5; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				_ = getCities()
			}
		}()
	}

	wg.Wait()
}
KINDGEN_EOF

cat > "app/consumer.go" <<'KINDGEN_EOF'
package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	pb "weather/genproto"

	amqp "github.com/rabbitmq/amqp091-go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// runConsumer is the entire life of the `consumer` mode: connect to store
// (gRPC) and RabbitMQ, then sit in a loop forever, taking each message off
// the queue and asking store to persist it. This is the only thing api's
// fetch loop is decoupled from - if store or RabbitMQ is briefly down, api
// keeps fetching from Open-Meteo and queuing messages; consumer just picks
// up the backlog once things recover, nothing gets silently dropped by api
// itself. (Whether the queue itself can lose messages is a different,
// separate question - see the auto-ack note near the bottom of this file.)
func runConsumer() {
	amqpURL := "amqp://" + getenv("RABBITMQ_DEFAULT_USER", "admin") + ":" +
		getenv("RABBITMQ_DEFAULT_PASS", "") + "@" +
		getenv("AMQP_HOST", "rabbitmq") + ":" + getenv("AMQP_PORT", "5672") + "/"
	queue := getenv("QUEUE", "weather.readings")
	storeAddr := getenv("STORE_ADDR", "weather-store:9090")

	// gRPC connections don't actually dial immediately - grpc.NewClient
	// just prepares the client, the real connection attempt happens lazily
	// on the first call. So this can't fail just because store isn't up
	// yet; that would only surface later, on the first AddReading call.
	conn, err := grpc.NewClient(storeAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("consumer: cannot create store client: %v", err)
	}
	defer conn.Close()
	client := pb.NewWeatherStoreClient(conn)

	// RabbitMQ, unlike gRPC above, connects eagerly - amqp.Dial actually
	// opens a TCP connection right away, so it genuinely can fail if
	// RabbitMQ isn't ready yet. Retry with the same pattern used
	// throughout this project (30 attempts, 2s apart) rather than crash
	// and rely on Docker to restart us into the same race condition.
	var mq *amqp.Connection
	for i := 0; i < 30; i++ {
		mq, err = amqp.Dial(amqpURL)
		if err == nil {
			break
		}
		log.Printf("consumer: waiting for rabbitmq: %v", err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("consumer: cannot connect rabbitmq: %v", err)
	}
	defer mq.Close()

	ch, err := mq.Channel()
	if err != nil {
		log.Fatalf("consumer: channel: %v", err)
	}
	defer ch.Close()

	// Declaring the queue here too (api also declares it before publishing)
	// is intentional, not redundant - RabbitMQ's queue declaration is
	// idempotent, and this way consumer works correctly even if it happens
	// to start up before api ever has.
	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		log.Fatalf("consumer: queue declare: %v", err)
	}

	// auto-ack=true (the third `true` below) means RabbitMQ considers a
	// message delivered - and removes it from the queue - the moment it's
	// handed to this process, before we've actually stored it anywhere.
	// If this process crashes between receiving a message and finishing
	// the AddReading call below, that one reading is lost. Fine for a
	// weather app polling every few minutes; would be worth switching to
	// manual ack (only acknowledging after AddReading succeeds) for
	// anything where losing a message actually matters.
	msgs, err := ch.Consume(queue, "", true, false, false, false, nil)
	if err != nil {
		log.Fatalf("consumer: consume: %v", err)
	}

	log.Println("consumer: waiting for messages")
	for d := range msgs {
		var r reading
		if err := json.Unmarshal(d.Body, &r); err != nil {
			log.Printf("consumer: bad message: %v", err)
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		resp, err := client.AddReading(ctx, &pb.Reading{
			City:         r.City,
			Latitude:     r.Latitude,
			Longitude:    r.Longitude,
			TemperatureC: r.TemperatureC,
			WindspeedKph: r.WindspeedKph,
			ObservedAt:   r.ObservedAt,
			Source:       r.Source,
		})
		cancel()
		if err != nil {
			log.Printf("consumer: addReading: %v", err)
			continue
		}
		log.Printf("consumer: stored id=%d city=%s", resp.Id, r.City)
	}
}
KINDGEN_EOF

cat > "app/go.mod" <<'KINDGEN_EOF'
module weather

go 1.26

require (
	github.com/lib/pq v1.10.9
	github.com/prometheus/client_golang v1.23.2
	github.com/rabbitmq/amqp091-go v1.12.0
	github.com/redis/go-redis/v9 v9.21.0
	google.golang.org/grpc v1.82.0
	google.golang.org/protobuf v1.36.11
)
KINDGEN_EOF

cat > "app/http_handlers.go" <<'KINDGEN_EOF'
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	pb "weather/genproto"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// apiServer bundles what the HTTP handlers below need. Grouping these two
// values here (instead of each handler being an anonymous closure that
// captures whatever variables happen to be in scope in serveHTTP) means
// every handler's dependencies are explicit and each one can be read - and
// tested - on its own.
type apiServer struct {
	store     pb.WeatherStoreClient // gRPC client to weather-store
	storeHTTP string                // e.g. "http://weather-store:9091"
}

// serveHTTP wires up every route and starts listening. This is the only
// exported entry point from this file - everything else here is a method
// on apiServer that some route below points to.
func serveHTTP(store pb.WeatherStoreClient, storeHTTP string) {
	s := &apiServer{store: store, storeHTTP: storeHTTP}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/readings/latest", s.handleReadingsLatest)
	mux.HandleFunc("/cities", s.handleCities)
	mux.HandleFunc("/", s.handleIndex)

	addr := ":" + getenv("API_PORT", "8080")
	log.Println("api: http on", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("api: http server: %v", err)
	}
}

// handleHealthz is what the Docker healthcheck in docker-compose.yml polls.
func (s *apiServer) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("ok"))
}

// handleIndex serves the single-page UI (search box + add-city form). The
// page itself is entirely static HTML/CSS/JS - see ui_page.go - it talks
// back to this server only through the JSON endpoints below.
func (s *apiServer) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(weatherUIHTML))
}

// --- GET /readings/latest ---------------------------------------------------

// handleReadingsLatest answers "what's the current weather", either for one
// city (?city=Paris) or for every tracked city (no query string - used by
// nothing right now except manual testing/curl, since the UI always asks
// for one city at a time).
func (s *apiServer) handleReadingsLatest(w http.ResponseWriter, r *http.Request) {
	names := s.cityNamesFromRequest(r)

	out := []reading{}
	for _, name := range names {
		if rd, found := s.getLatestFromStore(name); found {
			out = append(out, rd)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// cityNamesFromRequest decides which cities handleReadingsLatest should
// look up: just the one named in ?city=, or the entire tracked list.
func (s *apiServer) cityNamesFromRequest(r *http.Request) []string {
	if q := r.URL.Query().Get("city"); q != "" {
		return []string{q}
	}
	var names []string
	for _, c := range getCities() {
		names = append(names, c.Name)
	}
	return names
}

// getLatestFromStore asks weather-store (over gRPC) for the newest reading
// it has for one city. The bool return is "did we actually get a reading",
// not "did the call succeed" - a city with no data yet is not an error.
func (s *apiServer) getLatestFromStore(name string) (reading, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := s.store.GetLatest(ctx, &pb.GetLatestRequest{City: name})
	if err != nil {
		log.Printf("api: getLatest %s: %v", name, err)
		return reading{}, false
	}
	if !resp.Found || resp.Reading == nil {
		return reading{}, false
	}

	return reading{
		City:         resp.Reading.City,
		Latitude:     resp.Reading.Latitude,
		Longitude:    resp.Reading.Longitude,
		TemperatureC: resp.Reading.TemperatureC,
		WindspeedKph: resp.Reading.WindspeedKph,
		ObservedAt:   resp.Reading.ObservedAt,
		Source:       resp.Reading.Source,
	}, true
}

// --- GET/POST /cities --------------------------------------------------------

// handleCities just dispatches to the GET or POST version - kept tiny on
// purpose so the two very different jobs ("list what we have" vs. "resolve
// and add something new") don't end up tangled in one function.
func (s *apiServer) handleCities(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.handleCitiesGet(w, r)
	case http.MethodPost:
		s.handleCitiesPost(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleCitiesGet returns the currently tracked cities - straight from the
// in-memory cache (city_cache.go), which is itself always sourced from the
// database, never from CITIES.
func (s *apiServer) handleCitiesGet(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(getCities())
}

// handleCitiesPost is the "+ Add city" flow from the UI. The request body
// is just {"name": "Paris"} - the user never supplies coordinates - so this
// is the one place that ties together geocoding, persisting, and getting
// an immediate first reading, in that order:
//
//  1. resolve the name to coordinates (geocodeCity)
//  2. persist it (addCityToStore -> store -> Postgres)
//  3. re-read the full list from the database, so the cache reflects
//     reality instead of being hand-patched with the one new entry
//  4. fetch and store a reading right away, so the user isn't staring at
//     "no data yet" until the next scheduled FETCH_INTERVAL cycle
//
// Step 4 failing (e.g. Open-Meteo hiccups) does not fail the request - the
// city is already saved by that point, and it'll just pick up a reading on
// the next regular cycle instead.
func (s *apiServer) handleCitiesPost(w http.ResponseWriter, r *http.Request) {
	name, err := decodeCityName(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	city, err := geocodeCity(name)
	if err != nil {
		http.Error(w, "could not resolve city: "+err.Error(), http.StatusBadRequest)
		return
	}

	if err := addCityToStore(s.storeHTTP, city); err != nil {
		http.Error(w, "could not save city: "+err.Error(), http.StatusBadGateway)
		return
	}

	s.refreshCitiesFromDB()
	s.fetchAndStoreNow(city)

	log.Printf("api: city added: %s (%.4f, %.4f)", city.Name, city.Lat, city.Lon)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(city)
}

// decodeCityName pulls {"name": "..."} out of the request body, rejecting
// anything blank or malformed before it ever reaches geocoding.
func decodeCityName(r *http.Request) (string, error) {
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		return "", errProvideCityName
	}
	name := strings.TrimSpace(body.Name)
	if name == "" {
		return "", errProvideCityName
	}
	return name, nil
}

var errProvideCityName = httpError("provide a city name")

// httpError is just a tiny named string type so decodeCityName's error can
// double as the exact text http.Error sends to the client - no separate
// "wrap it, then unwrap it for the message" step needed for a case this
// simple.
type httpError string

func (e httpError) Error() string { return string(e) }

// refreshCitiesFromDB re-reads the full city list from the database and
// replaces the cache with it. Called right after adding a city so the new
// one is visible immediately, instead of waiting for the periodic 30s
// refresh in runAPI (api.go).
func (s *apiServer) refreshCitiesFromDB() {
	if list, err := listCities(s.storeHTTP); err == nil {
		setCities(list)
	}
}

// fetchAndStoreNow fetches one city's current weather and writes it
// straight to the database via the same gRPC AddReading call the normal
// consumer pipeline uses - this is the "don't make them wait 5 minutes"
// shortcut described on handleCitiesPost above.
func (s *apiServer) fetchAndStoreNow(c cityCoord) {
	rd, err := fetchOne(c)
	if err != nil {
		log.Printf("api: immediate fetch for %s failed: %v", c.Name, err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = s.store.AddReading(ctx, &pb.Reading{
		City:         rd.City,
		Latitude:     rd.Latitude,
		Longitude:    rd.Longitude,
		TemperatureC: rd.TemperatureC,
		WindspeedKph: rd.WindspeedKph,
		ObservedAt:   rd.ObservedAt,
		Source:       rd.Source,
	})
	if err != nil {
		log.Printf("api: immediate reading store for %s: %v", c.Name, err)
		return
	}

	tempGauge.WithLabelValues(rd.City).Set(rd.TemperatureC)
	windGauge.WithLabelValues(rd.City).Set(rd.WindspeedKph)
	publishedTotal.Inc()
}
KINDGEN_EOF

cat > "app/http_handlers_test.go" <<'KINDGEN_EOF'
package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDecodeCityName(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		want    string
		wantErr bool
	}{
		{name: "valid name", body: `{"name":"Paris"}`, want: "Paris"},
		{name: "trims whitespace", body: `{"name":"  Tokyo  "}`, want: "Tokyo"},
		{name: "empty name", body: `{"name":""}`, wantErr: true},
		{name: "whitespace-only name", body: `{"name":"   "}`, wantErr: true},
		{name: "missing name field", body: `{}`, wantErr: true},
		{name: "malformed JSON", body: `{not json`, wantErr: true},
		{name: "empty body", body: ``, wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/cities", strings.NewReader(tc.body))
			got, err := decodeCityName(req)

			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got name %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("expected %q, got %q", tc.want, got)
			}
		})
	}
}

// TestErrProvideCityNameMessage pins the exact error text, since
// decodeCityName's error doubles as what http.Error sends straight to the
// client (see handleCitiesPost) - a future edit changing this message
// without meaning to would otherwise go unnoticed.
func TestErrProvideCityNameMessage(t *testing.T) {
	if errProvideCityName.Error() != "provide a city name" {
		t.Fatalf("unexpected error message: %q", errProvideCityName.Error())
	}
}
KINDGEN_EOF

cat > "app/main.go" <<'KINDGEN_EOF'
package main

import (
	"log"
	"os"
	"time"
)

// getenv returns the env var or a default when unset/empty.
func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// mustDuration parses a duration env var (e.g. "300s") or dies.
func mustDuration(key, def string) time.Duration {
	d, err := time.ParseDuration(getenv(key, def))
	if err != nil {
		log.Fatalf("invalid duration for %s: %v", key, err)
	}
	return d
}

// One binary, three roles selected by MODE.
func main() {
	switch getenv("MODE", "") {
	case "store":
		runStore()
	case "api":
		runAPI()
	case "consumer":
		runConsumer()
	default:
		log.Fatal("set MODE=store|api|consumer")
	}
}
KINDGEN_EOF

cat > "app/metrics.go" <<'KINDGEN_EOF'
package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Prometheus metrics shared across modes (registered on the default registry).
var (
	tempGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "weather_temperature_celsius",
		Help: "Latest observed temperature in Celsius by city.",
	}, []string{"city"})

	windGauge = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "weather_windspeed_kph",
		Help: "Latest observed windspeed in km/h by city.",
	}, []string{"city"})

	publishedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "weather_readings_published_total",
		Help: "Total readings published to the queue by the api.",
	})

	storedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "weather_readings_stored_total",
		Help: "Total readings written to Postgres by the store.",
	})
)
KINDGEN_EOF

cat > "app/parse_test.go" <<'KINDGEN_EOF'
package main

import "testing"

func TestParseCities(t *testing.T) {
	got := parseCities("Tehran:35.6892:51.3890,Berlin:52.52:13.405")
	if len(got) != 2 {
		t.Fatalf("expected 2 cities, got %d", len(got))
	}
	if got[0].Name != "Tehran" {
		t.Errorf("expected first city Tehran, got %q", got[0].Name)
	}
	if got[1].Lat != 52.52 {
		t.Errorf("expected Berlin lat 52.52, got %v", got[1].Lat)
	}
}

func TestParseCitiesSkipsMalformed(t *testing.T) {
	got := parseCities("Bad,Tokyo:35.6762:139.6503,")
	if len(got) != 1 {
		t.Fatalf("expected 1 valid city, got %d", len(got))
	}
	if got[0].Name != "Tokyo" {
		t.Errorf("expected Tokyo, got %q", got[0].Name)
	}
}
KINDGEN_EOF

cat > "app/store.go" <<'KINDGEN_EOF'
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net"
	"time"

	pb "weather/genproto"

	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
)

// storeServer implements the WeatherStore gRPC service (AddReading,
// GetLatest below). This is the only thing in the whole project that
// talks to Postgres and Redis directly for weather readings - api and
// consumer only ever reach that data through this gRPC interface. (The
// `cities` table is a separate, simpler case - see store_http.go.)
type storeServer struct {
	pb.UnimplementedWeatherStoreServer
	db  *sql.DB
	rdb *redis.Client
	ttl time.Duration
}

// runStore is the entire life of the `store` mode: connect to Postgres,
// connect to Redis, seed the cities table on first boot, then start both
// servers - the REST one (store_http.go) in the background, the gRPC one
// in the foreground.
func runStore() {
	db := mustConnectPostgres()

	rdb := redis.NewClient(&redis.Options{Addr: getenv("REDIS_ADDR", "redis:6379")})
	srv := &storeServer{db: db, rdb: rdb, ttl: mustDuration("CACHE_TTL", "120s")}
	seedCities(db, getenv("CITIES", ""))

	go serveStoreHTTP(db)

	serveGRPC(srv)
}

// mustConnectPostgres retries the connection up to 30 times, 2 seconds
// apart, before giving up. This matters because Docker Compose starts
// containers in parallel by default - by the time this process starts,
// the postgres container may exist but Postgres itself might not have
// finished initializing yet. "must" because there's nothing useful this
// service can do without a database.
func mustConnectPostgres() *sql.DB {
	dsn := "host=" + getenv("PGHOST", "postgres") +
		" port=" + getenv("PGPORT", "5432") +
		" user=" + getenv("POSTGRES_USER", "weather") +
		" password=" + getenv("POSTGRES_PASSWORD", "") +
		" dbname=" + getenv("POSTGRES_DB", "weatherdb") +
		" sslmode=disable"

	const attempts = 30
	const delay = 2 * time.Second

	var db *sql.DB
	var err error
	for i := 0; i < attempts; i++ {
		db, err = sql.Open("postgres", dsn)
		if err == nil {
			err = db.Ping()
		}
		if err == nil {
			log.Println("store: connected to postgres")
			return db
		}
		log.Printf("store: waiting for postgres: %v", err)
		time.Sleep(delay)
	}
	log.Fatalf("store: cannot connect to postgres: %v", err)
	return nil // unreachable - log.Fatalf exits the process
}

// serveGRPC starts the WeatherStore gRPC server and blocks forever (or
// until it fails). Meant to be the last thing runStore calls.
func serveGRPC(srv *storeServer) {
	lis, err := net.Listen("tcp", ":9090")
	if err != nil {
		log.Fatalf("store: listen: %v", err)
	}
	g := grpc.NewServer()
	pb.RegisterWeatherStoreServer(g, srv)
	log.Println("store: gRPC on :9090")
	if err := g.Serve(lis); err != nil {
		log.Fatalf("store: serve: %v", err)
	}
}

// AddReading is the write path: insert into Postgres (the permanent
// record), then best-effort refresh the Redis cache. If the cache write
// fails, that's not treated as an error - GetLatest below will just fall
// back to Postgres on its next call, so a Redis hiccup here never loses
// the actual reading.
func (s *storeServer) AddReading(ctx context.Context, r *pb.Reading) (*pb.AddReadingResponse, error) {
	var id int64
	err := s.db.QueryRowContext(ctx,
		`INSERT INTO weather_readings
		 (city, latitude, longitude, temperature_c, windspeed_kph, observed_at, source)
		 VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
		r.City, r.Latitude, r.Longitude, r.TemperatureC, r.WindspeedKph, r.ObservedAt, r.Source,
	).Scan(&id)
	if err != nil {
		return nil, err
	}

	if b, e := json.Marshal(r); e == nil {
		s.rdb.Set(ctx, "latest:"+r.City, b, s.ttl)
	}

	storedTotal.Inc()
	log.Printf("store: saved id=%d city=%s temp=%.1f", id, r.City, r.TemperatureC)
	return &pb.AddReadingResponse{Id: id}, nil
}

// GetLatest is the read path: Redis first (the fast, common case), and
// only fall back to Postgres on a cache miss. A miss happens either
// because CACHE_TTL expired naturally, or because Redis was restarted and
// lost its data - Postgres being the permanent record means neither case
// ever actually loses a reading, just costs one extra query.
func (s *storeServer) GetLatest(ctx context.Context, req *pb.GetLatestRequest) (*pb.GetLatestResponse, error) {
	if v, err := s.rdb.Get(ctx, "latest:"+req.City).Result(); err == nil {
		var r pb.Reading
		if json.Unmarshal([]byte(v), &r) == nil {
			return &pb.GetLatestResponse{Reading: &r, Found: true}, nil
		}
	}

	var r pb.Reading
	var observed time.Time
	err := s.db.QueryRowContext(ctx,
		`SELECT city, latitude, longitude, temperature_c, windspeed_kph, observed_at, source
		 FROM weather_readings WHERE city=$1 ORDER BY observed_at DESC LIMIT 1`, req.City).
		Scan(&r.City, &r.Latitude, &r.Longitude, &r.TemperatureC, &r.WindspeedKph, &observed, &r.Source)
	if err == sql.ErrNoRows {
		return &pb.GetLatestResponse{Found: false}, nil
	}
	if err != nil {
		return nil, err
	}

	r.ObservedAt = observed.Format(time.RFC3339)
	return &pb.GetLatestResponse{Reading: &r, Found: true}, nil
}

// seedCities inserts the initial CITIES list into the cities table once,
// so the very first boot has something to show before anyone adds a city
// through the UI. Safe to call on every startup, not just the first one -
// ON CONFLICT DO NOTHING means re-running this against an already-seeded
// database is a harmless no-op.
func seedCities(db *sql.DB, csv string) {
	for _, c := range parseCities(csv) {
		_, err := db.Exec(
			`INSERT INTO cities (name, latitude, longitude) VALUES ($1,$2,$3)
			 ON CONFLICT (name) DO NOTHING`, c.Name, c.Lat, c.Lon)
		if err != nil {
			log.Printf("store: seed city %s: %v", c.Name, err)
		}
	}
}
KINDGEN_EOF

cat > "app/store_http.go" <<'KINDGEN_EOF'
package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// storeHTTPServer is store's small REST surface - separate from the gRPC
// service in store.go. Three routes, all on :9091:
//
//	/healthz  - polled by the Docker healthcheck in docker-compose.yml
//	/metrics  - scraped by Prometheus
//	/cities   - the only place in this whole project that runs SQL
//	            against the `cities` table (api reaches it over plain
//	            HTTP, not gRPC, since it's simple key-value-ish data with
//	            no need for a typed contract)
type storeHTTPServer struct {
	db *sql.DB
}

// serveStoreHTTP wires up the three routes and listens forever. Meant to
// be started with `go serveStoreHTTP(db)` from runStore, alongside the
// gRPC server.
func serveStoreHTTP(db *sql.DB) {
	s := &storeHTTPServer{db: db}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/cities", s.handleCities)

	log.Println("store: health+metrics on :9091")
	if err := http.ListenAndServe(":9091", mux); err != nil {
		log.Printf("store: health server: %v", err)
	}
}

func (s *storeHTTPServer) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// handleCities dispatches to the GET or POST version - same "keep it tiny"
// reasoning as apiServer.handleCities in http_handlers.go.
func (s *storeHTTPServer) handleCities(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.handleCitiesGet(w, r)
	case http.MethodPost:
		s.handleCitiesPost(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handleCitiesGet returns every row in the cities table, alphabetically.
// This is what api's listCities (city_cache.go) calls to refresh its cache.
func (s *storeHTTPServer) handleCitiesGet(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`SELECT name, latitude, longitude FROM cities ORDER BY name`)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	out := []cityCoord{}
	for rows.Next() {
		var c cityCoord
		if err := rows.Scan(&c.Name, &c.Lat, &c.Lon); err == nil {
			out = append(out, c)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// handleCitiesPost inserts a new city, or updates its coordinates if the
// name already exists (ON CONFLICT ... DO UPDATE) - so re-adding "Paris"
// twice is harmless, it just refreshes the stored coordinates rather than
// erroring. The caller (api's addCityToStore) is expected to have already
// resolved the name to coordinates via geocoding before this is ever
// called - this endpoint trusts the coordinates it's given.
func (s *storeHTTPServer) handleCitiesPost(w http.ResponseWriter, r *http.Request) {
	var c cityCoord
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil || c.Name == "" {
		http.Error(w, "invalid city payload", http.StatusBadRequest)
		return
	}

	_, err := s.db.Exec(
		`INSERT INTO cities (name, latitude, longitude) VALUES ($1,$2,$3)
		 ON CONFLICT (name) DO UPDATE SET latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude`,
		c.Name, c.Lat, c.Lon)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("store: city added/updated: %s (%.4f, %.4f)", c.Name, c.Lat, c.Lon)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(c)
}
KINDGEN_EOF

cat > "app/ui_page.go" <<'KINDGEN_EOF'
package main

// weatherUIHTML is the entire frontend: one static page (HTML + CSS + JS),
// no build step, no framework. It only talks back to this server through
// the plain JSON endpoints in http_handlers.go (GET/POST /cities, GET
// /readings/latest) - kept in its own file so the Go logic files above
// don't have hundreds of lines of markup interrupting them.
const weatherUIHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Weather stack</title>
<style>
  :root {
    --bg: #0f1420;
    --panel: #161d2e;
    --panel-2: #1d2740;
    --border: #2a3550;
    --text: #e8ecf5;
    --muted: #8b96b3;
    --accent: #4fc3f7;
    --accent-2: #29b6f6;
    --ok: #4ade80;
    --err: #f87171;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    background: radial-gradient(circle at 20% -10%, #1b2540 0%, var(--bg) 55%);
    color: var(--text);
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
    display: flex;
    justify-content: center;
    padding: 4rem 1.25rem;
  }
  .card {
    width: 100%;
    max-width: 460px;
  }
  h1 {
    font-size: 1.5rem;
    font-weight: 600;
    margin: 0 0 .3rem;
    letter-spacing: -.01em;
  }
  .sub {
    color: var(--muted);
    font-size: .9rem;
    margin: 0 0 1.75rem;
  }
  .search-wrap {
    position: relative;
  }
  .search-box {
    display: flex;
    align-items: center;
    gap: .6rem;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: .75rem 1rem;
    transition: border-color .15s;
  }
  .search-box:focus-within {
    border-color: var(--accent);
  }
  .search-box svg { flex-shrink: 0; color: var(--muted); }
  .search-box input {
    flex: 1;
    background: none;
    border: none;
    outline: none;
    color: var(--text);
    font-size: 1rem;
  }
  .search-box input::placeholder { color: var(--muted); }
  .dropdown {
    position: absolute;
    top: calc(100% + 8px);
    left: 0;
    right: 0;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 12px 32px rgba(0,0,0,.4);
    z-index: 5;
    display: none;
  }
  .dropdown.open { display: block; }
  .dropdown-item {
    padding: .7rem 1rem;
    cursor: pointer;
    font-size: .95rem;
    display: flex;
    justify-content: space-between;
    color: var(--text);
  }
  .dropdown-item:hover, .dropdown-item.active {
    background: var(--panel-2);
  }
  .dropdown-item .coords {
    color: var(--muted);
    font-size: .8rem;
  }
  .dropdown-item.add {
    color: var(--accent);
    font-weight: 500;
  }
  .dropdown-item.add .coords {
    color: var(--accent);
    opacity: .7;
  }
  .result {
    margin-top: 1.75rem;
    background: linear-gradient(160deg, var(--panel-2), var(--panel));
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 1.5rem;
    display: none;
  }
  .result.show { display: block; }
  .result .city {
    font-size: 1.1rem;
    font-weight: 600;
  }
  .result .temp {
    font-size: 3rem;
    font-weight: 700;
    line-height: 1.1;
    margin: .4rem 0;
    background: linear-gradient(90deg, var(--accent), var(--accent-2));
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  .result .meta {
    color: var(--muted);
    font-size: .85rem;
    display: flex;
    gap: 1.25rem;
    margin-top: .5rem;
  }
  .msg {
    margin-top: 1rem;
    font-size: .9rem;
    min-height: 1.2rem;
  }
  .msg.error { color: var(--err); }
  .msg.ok { color: var(--ok); }
  .msg.loading { color: var(--muted); }
</style>
</head>
<body>
  <div class="card">
    <h1>Weather stack</h1>
    <p class="sub">Search a city, or add a new one to start tracking it</p>

    <div class="search-wrap">
      <div class="search-box">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="7"></circle>
          <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
        </svg>
        <input id="q" type="text" placeholder="Search city, e.g. Tehran" autocomplete="off">
      </div>
      <div id="dropdown" class="dropdown"></div>
    </div>

    <div id="msg" class="msg"></div>

    <div id="result" class="result">
      <div class="city" id="r-city"></div>
      <div class="temp" id="r-temp"></div>
      <div class="meta">
        <span id="r-wind"></span>
        <span id="r-time"></span>
      </div>
    </div>
  </div>

<script>
let allCities = [];
let activeIndex = -1;

const q = document.getElementById('q');
const dropdown = document.getElementById('dropdown');
const msg = document.getElementById('msg');
const result = document.getElementById('result');

function setMsg(text, kind) {
  msg.textContent = text || '';
  msg.className = 'msg' + (kind ? ' ' + kind : '');
}

async function loadCities() {
  try {
    const res = await fetch('/cities');
    allCities = (await res.json()) || [];
  } catch (e) {
    setMsg('Could not load city list: ' + e.message, 'error');
  }
}

function renderDropdown(filter) {
  const term = (filter || '').trim();
  const lower = term.toLowerCase();
  const matches = allCities.filter(c => c.Name.toLowerCase().includes(lower));
  activeIndex = -1;

  if (matches.length === 0) {
    if (!term) {
      dropdown.classList.remove('open');
      dropdown.innerHTML = '';
      return;
    }
    // No known city matches - offer to add it.
    dropdown.innerHTML =
      '<div class="dropdown-item add" data-add="' + term + '">' +
        '<span>+ Add "' + term + '"</span>' +
        '<span class="coords">new city</span>' +
      '</div>';
    dropdown.classList.add('open');
    dropdown.querySelector('.dropdown-item').addEventListener('click', () => addCity(term));
    return;
  }

  dropdown.innerHTML = matches.map((c, i) =>
    '<div class="dropdown-item" data-name="' + c.Name + '" data-i="' + i + '">' +
      '<span>' + c.Name + '</span>' +
      '<span class="coords">' + c.Lat.toFixed(2) + ', ' + c.Lon.toFixed(2) + '</span>' +
    '</div>'
  ).join('');
  dropdown.classList.add('open');
  dropdown.querySelectorAll('.dropdown-item').forEach(el => {
    el.addEventListener('click', () => {
      q.value = el.dataset.name;
      dropdown.classList.remove('open');
      lookup(el.dataset.name);
    });
  });
}

async function addCity(name) {
  dropdown.classList.remove('open');
  result.classList.remove('show');
  setMsg('Looking up "' + name + '" and fetching its temperature...', 'loading');
  try {
    const res = await fetch('/cities', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || ('status ' + res.status));
    }
    const city = await res.json();
    await loadCities();
    q.value = city.Name;
    await lookup(city.Name);
  } catch (e) {
    setMsg('Could not add city: ' + e.message, 'error');
  }
}

async function lookup(name) {
  const city = (name || q.value).trim();
  if (!city) return;
  result.classList.remove('show');
  setMsg('Looking up ' + city + '...', 'loading');
  try {
    const res = await fetch('/readings/latest?city=' + encodeURIComponent(city));
    if (!res.ok) throw new Error('status ' + res.status);
    const data = await res.json();
    if (!data || data.length === 0) {
      setMsg('No data yet for "' + city + '". Only configured cities have readings.', 'error');
      return;
    }
    const r = data[0];
    document.getElementById('r-city').textContent = r.city;
    document.getElementById('r-temp').textContent = r.temperature_c.toFixed(1) + '°C';
    document.getElementById('r-wind').textContent = 'Wind ' + r.windspeed_kph.toFixed(0) + ' km/h';
    document.getElementById('r-time').textContent = r.observed_at.replace('T', ' ');
    result.classList.add('show');
    setMsg('', '');
  } catch (e) {
    setMsg('Error: ' + e.message, 'error');
  }
}

q.addEventListener('input', () => renderDropdown(q.value));
q.addEventListener('focus', () => renderDropdown(q.value));
q.addEventListener('keydown', (e) => {
  const items = Array.from(dropdown.querySelectorAll('.dropdown-item'));
  if (e.key === 'ArrowDown' && items.length) {
    e.preventDefault();
    activeIndex = Math.min(activeIndex + 1, items.length - 1);
    items.forEach((el, i) => el.classList.toggle('active', i === activeIndex));
  } else if (e.key === 'ArrowUp' && items.length) {
    e.preventDefault();
    activeIndex = Math.max(activeIndex - 1, 0);
    items.forEach((el, i) => el.classList.toggle('active', i === activeIndex));
  } else if (e.key === 'Enter') {
    e.preventDefault();
    const chosen = (activeIndex >= 0 && items[activeIndex]) ? items[activeIndex] : items[0];
    if (chosen && chosen.dataset.add) {
      addCity(chosen.dataset.add);
    } else if (chosen && chosen.dataset.name) {
      q.value = chosen.dataset.name;
      dropdown.classList.remove('open');
      lookup(chosen.dataset.name);
    } else {
      dropdown.classList.remove('open');
      lookup();
    }
  } else if (e.key === 'Escape') {
    dropdown.classList.remove('open');
  }
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('.search-wrap')) dropdown.classList.remove('open');
});

loadCities();
</script>
</body>
</html>`
KINDGEN_EOF

cat > "app/weather_fetch.go" <<'KINDGEN_EOF'
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// reading is one weather observation for one city. This is what gets
// published to RabbitMQ, what store persists to Postgres, and what
// /readings/latest returns to the browser - the JSON tags below are the
// public API shape, so change them with care.
type reading struct {
	City         string  `json:"city"`
	Latitude     float64 `json:"latitude"`
	Longitude    float64 `json:"longitude"`
	TemperatureC float64 `json:"temperature_c"`
	WindspeedKph float64 `json:"windspeed_kph"`
	ObservedAt   string  `json:"observed_at"`
	Source       string  `json:"source"`
}

// geocodeCity turns a plain city name (whatever the user typed in the
// search box) into coordinates, using Open-Meteo's free geocoding API - no
// account or API key needed. It returns only the single best match; if the
// name is ambiguous ("Springfield") this just picks whichever result the
// API ranks first rather than asking the user to disambiguate.
func geocodeCity(name string) (cityCoord, error) {
	endpoint := "https://geocoding-api.open-meteo.com/v1/search?count=1&name=" + url.QueryEscape(name)
	client := http.Client{Timeout: 10 * time.Second}

	resp, err := client.Get(endpoint)
	if err != nil {
		return cityCoord{}, err
	}
	defer resp.Body.Close()

	var parsed struct {
		Results []struct {
			Name      string  `json:"name"`
			Latitude  float64 `json:"latitude"`
			Longitude float64 `json:"longitude"`
			Country   string  `json:"country"`
		} `json:"results"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return cityCoord{}, err
	}
	if len(parsed.Results) == 0 {
		return cityCoord{}, fmt.Errorf("no match found for %q", name)
	}

	first := parsed.Results[0]
	return cityCoord{Name: first.Name, Lat: first.Latitude, Lon: first.Longitude}, nil
}

// fetchOne calls Open-Meteo's forecast API for a single city and returns
// its current conditions. This is the one function that actually knows the
// shape of Open-Meteo's forecast response - everywhere else in this
// codebase deals with the simpler `reading` struct instead.
func fetchOne(c cityCoord) (reading, error) {
	endpoint := fmt.Sprintf(
		"https://api.open-meteo.com/v1/forecast?latitude=%f&longitude=%f&current_weather=true",
		c.Lat, c.Lon)

	client := http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(endpoint)
	if err != nil {
		return reading{}, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var parsed struct {
		CurrentWeather struct {
			Temperature float64 `json:"temperature"`
			Windspeed   float64 `json:"windspeed"`
			Time        string  `json:"time"`
		} `json:"current_weather"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return reading{}, err
	}

	return reading{
		City:         c.Name,
		Latitude:     c.Lat,
		Longitude:    c.Lon,
		TemperatureC: parsed.CurrentWeather.Temperature,
		WindspeedKph: parsed.CurrentWeather.Windspeed,
		ObservedAt:   parsed.CurrentWeather.Time,
		Source:       "open-meteo",
	}, nil
}

// publishAll is the regular fetch cycle: for every city currently being
// tracked, fetch its weather from Open-Meteo and publish it onto the
// RabbitMQ queue for weather-consumer to pick up and store. One failed
// city (a bad network blip, Open-Meteo briefly down) just gets logged and
// skipped - it doesn't abort the whole cycle for every other city.
//
// A fresh AMQP connection is opened on every call rather than kept open
// between cycles - simple, and fine at the default 5-minute interval. Worth
// revisiting (a persistent connection) if FETCH_INTERVAL is ever set much
// shorter than that.
func publishAll(amqpURL, queue string, cities []cityCoord) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		log.Printf("api: amqp dial: %v", err)
		return
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		log.Printf("api: channel: %v", err)
		return
	}
	defer ch.Close()

	if _, err := ch.QueueDeclare(queue, true, false, false, false, nil); err != nil {
		log.Printf("api: queue declare: %v", err)
		return
	}

	for _, c := range cities {
		rd, err := fetchOne(c)
		if err != nil {
			log.Printf("api: fetch %s: %v", c.Name, err)
			continue
		}

		body, _ := json.Marshal(rd)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err = ch.PublishWithContext(ctx, "", queue, false, false, amqp.Publishing{
			ContentType: "application/json",
			Body:        body,
		})
		cancel()
		if err != nil {
			log.Printf("api: publish %s: %v", c.Name, err)
			continue
		}

		tempGauge.WithLabelValues(rd.City).Set(rd.TemperatureC)
		windGauge.WithLabelValues(rd.City).Set(rd.WindspeedKph)
		publishedTotal.Inc()
		log.Printf("api: published %s temp=%.1f", rd.City, rd.TemperatureC)
	}
}
KINDGEN_EOF

cat > "app/proto/weather.proto" <<'KINDGEN_EOF'
syntax = "proto3";
package weather;
option go_package = "weather/genproto;genproto";

message Reading {
  string city = 1;
  double latitude = 2;
  double longitude = 3;
  double temperature_c = 4;
  double windspeed_kph = 5;
  string observed_at = 6;
  string source = 7;
}

message AddReadingResponse { int64 id = 1; }
message GetLatestRequest { string city = 1; }
message GetLatestResponse {
  Reading reading = 1;
  bool found = 2;
}

service WeatherStore {
  rpc AddReading(Reading) returns (AddReadingResponse);
  rpc GetLatest(GetLatestRequest) returns (GetLatestResponse);
}
KINDGEN_EOF

cat > "charts/weather/Chart.yaml" <<'KINDGEN_EOF'
apiVersion: v2
name: weather
description: Multi-service weather stack (Go store/api/consumer + Postgres, Redis, RabbitMQ, Prometheus, Grafana)
type: application

# version    = chart version, bump on any template/values change
# appVersion = the Go application image tag this chart was written against
version: 0.1.0
appVersion: "dev"

kubeVersion: ">=1.30.0-0"

maintainers:
  - name: ericvalijani
KINDGEN_EOF

cat > "charts/weather/values-gitops.yaml" <<'KINDGEN_EOF'
# Overrides for the GitOps cluster (kind/cluster-gitops.yaml).
#
# Argo CD reads THIS file, not values-kind.yaml. The difference that
# matters: the image comes from GHCR and is pinned by digest, because
# nothing here is built locally or side-loaded with `kind load`.

image:
  # Must be lowercase and must match the GHCR package name, which is
  # ghcr.io/<owner>/<repo> from the CI workflow.
  repository: ghcr.io/ericvalijani/weather-kind

  # Used only until CI has pinned a digest below. `latest` is a moving
  # target on purpose here: it is the bootstrap value, not the steady
  # state.
  tag: latest

  # The steady state. CI's `bump` job opens a pull request that fills
  # this in with the digest it just pushed, e.g.
  #   digest: "sha256:9f86d0818..."
  # A digest cannot be moved or overwritten the way a tag can, so what
  # Argo CD deploys is exactly what CI built. When this is non-empty it
  # wins and `tag` is ignored (see weather.image in _helpers.tpl).
  digest: ""

  # Safe with a digest: the reference is immutable, so a cached image is
  # by definition the right one.
  pullPolicy: IfNotPresent

app:
  # The default, unlike values-kind.yaml. This cluster is meant to sit
  # there and be reconciled, not to fill up with data while you watch.
  fetchInterval: 300s

nodePorts:
  enabled: true

ingress:
  enabled: false

# Off to leave room for Argo CD's five pods on an 8GB machine. This
# cluster is for watching deployments happen, and the dev cluster still
# has the full monitoring stack. Set either to true if you want them.
prometheus:
  enabled: false

grafana:
  enabled: false
KINDGEN_EOF

cat > "charts/weather/values-kind.yaml" <<'KINDGEN_EOF'
# Overrides used for the local kind cluster.
# `make deploy` passes this file with -f, on top of values.yaml.
#
# Kept deliberately thin: if a setting is the same everywhere, it belongs
# in values.yaml, not here.

image:
  repository: weather
  tag: dev
  pullPolicy: IfNotPresent

app:
  # Shorter than the 300s default so a fresh cluster fills up with data
  # while you are still looking at it.
  fetchInterval: 120s

nodePorts:
  enabled: true

ingress:
  enabled: false
KINDGEN_EOF

cat > "charts/weather/values.yaml" <<'KINDGEN_EOF'
# Default values for the weather chart.
# Every image tag is pinned on purpose - no "latest" anywhere.

# ---- application image (one image, three MODEs) ----------------------
image:
  repository: weather
  tag: dev
  # Set this and `tag` is ignored (see weather.image in _helpers.tpl).
  # Empty here because weather:dev is built locally and side-loaded with
  # `kind load` - it has no registry digest. The GitOps track pins one:
  # see values-gitops.yaml, which CI keeps up to date.
  digest: ""
  # IfNotPresent is what makes `kind load docker-image` work: the image
  # already exists on the node, so the kubelet must not try to pull it.
  pullPolicy: IfNotPresent

# ---- application settings (become a ConfigMap) -----------------------
app:
  apiPort: 8080
  fetchInterval: 300s
  cacheTtl: 120s
  queue: weather.readings
  # Seeds the cities table on the very first boot only. After that the
  # database is the single source of truth.
  cities: "Tehran:35.6892:51.3890,Berlin:52.5200:13.4050,Tokyo:35.6762:139.6503"
  replicas:
    api: 1
    store: 1
    consumer: 1

# ---- data layer ------------------------------------------------------
postgres:
  image: postgres:18.4-alpine
  user: weather
  password: devpassword
  database: weatherdb
  # Postgres 18 expects the volume at /var/lib/postgresql, NOT at
  # /var/lib/postgresql/data like every pre-18 tutorial shows.
  mountPath: /var/lib/postgresql
  storage: 2Gi

redis:
  image: redis:8.8.0-alpine

rabbitmq:
  image: rabbitmq:4.3.2-management-alpine
  user: admin
  password: devpassword
  storage: 1Gi

# ---- monitoring ------------------------------------------------------
prometheus:
  enabled: true
  image: prom/prometheus:v3.12.0
  scrapeInterval: 15s
  storage: 2Gi

grafana:
  enabled: true
  image: grafana/grafana:13.1.0
  user: admin
  password: devpassword
  storage: 1Gi

# ---- how you reach the cluster --------------------------------------
# NodePorts are the default because they line up with the
# extraPortMappings in kind/cluster.yaml - no ingress controller needed.
nodePorts:
  enabled: true
  api: 30080
  grafana: 30300
  prometheus: 30900
  rabbitmq: 31567

# Optional. Only turn this on after installing an ingress controller
# yourself (see README - ingress-nginx is retired, Traefik is the
# maintained option). Requires a hosts-file entry for the host below.
ingress:
  enabled: false
  className: traefik
  host: weather.local
  annotations: {}

# ---- resources (sized for an 8GB laptop) -----------------------------
resources:
  app:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      memory: 128Mi
  data:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 512Mi

# Kind ships the local-path provisioner as the default StorageClass, so
# leaving this empty is correct for a kind cluster.
storageClassName: ""
KINDGEN_EOF

cat > "charts/weather/files/grafana-dashboard-weather.json" <<'KINDGEN_EOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "panels": [
    {
      "type": "timeseries",
      "title": "Temperature (C) by city",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "celsius" }, "overrides": [] },
      "targets": [ { "expr": "weather_temperature_celsius", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Windspeed (km/h) by city",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 0 },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "targets": [ { "expr": "weather_windspeed_kph", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Readings rate: published vs stored",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 9 },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "targets": [
        { "expr": "rate(weather_readings_published_total[5m])", "refId": "A", "legendFormat": "published" },
        { "expr": "rate(weather_readings_stored_total[5m])", "refId": "B", "legendFormat": "stored" }
      ]
    }
  ],
  "schemaVersion": 39,
  "tags": ["weather"],
  "templating": { "list": [] },
  "time": { "from": "now-6h", "to": "now" },
  "timepicker": {},
  "title": "Weather Overview",
  "uid": "weather-overview",
  "version": 1
}
KINDGEN_EOF

cat > "charts/weather/files/init.sql" <<'KINDGEN_EOF'
CREATE TABLE IF NOT EXISTS weather_readings (
    id            BIGSERIAL PRIMARY KEY,
    city          TEXT NOT NULL,
    latitude      DOUBLE PRECISION,
    longitude     DOUBLE PRECISION,
    temperature_c DOUBLE PRECISION,
    windspeed_kph DOUBLE PRECISION,
    observed_at   TIMESTAMPTZ,
    source        TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weather_city_time
    ON weather_readings (city, observed_at DESC);

CREATE TABLE IF NOT EXISTS cities (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    latitude   DOUBLE PRECISION NOT NULL,
    longitude  DOUBLE PRECISION NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
KINDGEN_EOF

cat > "charts/weather/templates/NOTES.txt" <<'KINDGEN_EOF'
weather {{ .Chart.Version }} deployed as release {{ .Release.Name }} in namespace {{ .Release.Namespace }}.

Watch it come up:
  kubectl -n {{ .Release.Namespace }} get pods -w

{{ if .Values.nodePorts.enabled -}}
Open (kind maps these NodePorts to localhost). The host ports below are
the default cluster's; the GitOps cluster maps the same NodePorts to
8082, 3001, 9091 and 15673 - see kind/cluster-gitops.yaml.
  UI          http://localhost:8080
{{ if .Values.grafana.enabled -}}
  Grafana     http://localhost:3000     ({{ .Values.grafana.user }} / value of grafana.password)
{{ end -}}
{{ if .Values.prometheus.enabled -}}
  Prometheus  http://localhost:9090
{{ end -}}
  RabbitMQ    http://localhost:15672    ({{ .Values.rabbitmq.user }} / value of rabbitmq.password)
{{- else -}}
NodePorts are disabled, so reach the UI with a port-forward:
  kubectl -n {{ .Release.Namespace }} port-forward svc/{{ include "weather.fullname" . }}-api {{ .Values.app.apiPort }}:{{ .Values.app.apiPort }}
{{- end }}

{{ if .Values.ingress.enabled -}}
Ingress is enabled for host {{ .Values.ingress.host }} (class {{ .Values.ingress.className }}).
It only works if a matching ingress controller is installed in this cluster.
{{- end }}

Seeded cities (first boot only, the database is the source of truth after that):
  {{ .Values.app.cities }}
KINDGEN_EOF

cat > "charts/weather/templates/_helpers.tpl" <<'KINDGEN_EOF'
{{/*
Shared naming + labels. Four helpers, that's the whole file:

  weather.fullname   -> resource name prefix (the release name)
  weather.labels     -> labels every resource gets
  weather.selector   -> the subset used as pod selectors (must stay stable)
  weather.image      -> the app image reference (digest wins over tag)
*/}}

{{- define "weather.fullname" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "weather.labels" -}}
app.kubernetes.io/name: weather
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: weather
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "weather.selector" -}}
app.kubernetes.io/name: weather
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
One place that decides how the app image is referenced.

image.digest wins when set, because a digest is immutable: nobody can
move it the way a tag can be overwritten, so "which build is running?"
has exactly one answer. CI's bump job writes it into values-gitops.yaml.

Falls back to repository:tag, which is what the local kind cluster uses
(weather:dev is built and side-loaded, it has no digest in a registry).
*/}}
{{- define "weather.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}
KINDGEN_EOF

cat > "charts/weather/templates/api.yaml" <<'KINDGEN_EOF'
# weather-api: MODE=api. The fetch loop plus the public HTTP surface
# (UI at "/", /readings/latest, /cities, /healthz, /metrics).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "weather.fullname" . }}-api
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: api
spec:
  replicas: {{ .Values.app.replicas.api }}
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: api
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: api
      annotations:
        # All env comes from the ConfigMap + Secret, and Kubernetes does
        # NOT restart pods when those change. Hashing the rendered config
        # into the pod template is what makes `helm upgrade` actually
        # roll the pods after you edit values.yaml.
        checksum/config: {{ include (print .Template.BasePath "/config.yaml") . | sha256sum }}
    spec:
      containers:
        - name: api
          image: "{{ include "weather.image" . }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          env:
            - name: MODE
              value: api
          envFrom:
            - configMapRef:
                name: {{ include "weather.fullname" . }}-env
            - secretRef:
                name: {{ include "weather.fullname" . }}-secrets
          ports:
            - name: http
              containerPort: {{ .Values.app.apiPort }}
          # The api blocks on the store's first city list (up to 60s on a
          # cold cluster). A startup probe gives it that time; without it
          # the liveness probe kills a pod that is starting up correctly.
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            {{- toYaml .Values.resources.app | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-api
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: api
spec:
  # NodePort by default: kind/cluster.yaml maps 30080 -> localhost:8080,
  # which is why no ingress controller is needed to open the UI.
  type: {{ if .Values.nodePorts.enabled }}NodePort{{ else }}ClusterIP{{ end }}
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: api
  ports:
    - name: http
      port: {{ .Values.app.apiPort }}
      targetPort: http
      {{- if .Values.nodePorts.enabled }}
      nodePort: {{ .Values.nodePorts.api }}
      {{- end }}
KINDGEN_EOF

cat > "charts/weather/templates/config.yaml" <<'KINDGEN_EOF'
# Every non-secret env var the three Go modes read, in one ConfigMap -
# the Kubernetes equivalent of the compose track's single .env file.
#
# Service names are built from the release name, so the app never has to
# hardcode "weather-postgres": Helm fills it in.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "weather.fullname" . }}-env
  labels:
    {{- include "weather.labels" . | nindent 4 }}
data:
  PGHOST: {{ include "weather.fullname" . }}-postgres
  PGPORT: "5432"
  POSTGRES_DB: {{ .Values.postgres.database | quote }}
  POSTGRES_USER: {{ .Values.postgres.user | quote }}

  AMQP_HOST: {{ include "weather.fullname" . }}-rabbitmq
  AMQP_PORT: "5672"
  QUEUE: {{ .Values.app.queue | quote }}
  RABBITMQ_DEFAULT_USER: {{ .Values.rabbitmq.user | quote }}

  REDIS_ADDR: {{ include "weather.fullname" . }}-redis:6379
  CACHE_TTL: {{ .Values.app.cacheTtl | quote }}

  STORE_ADDR: {{ include "weather.fullname" . }}-store:9090
  STORE_HTTP_ADDR: {{ printf "http://%s-store:9091" (include "weather.fullname" .) | quote }}
  API_PORT: {{ .Values.app.apiPort | quote }}
  FETCH_INTERVAL: {{ .Values.app.fetchInterval | quote }}
  CITIES: {{ .Values.app.cities | quote }}
---
# Dev credentials. Fine for a laptop cluster; for anything real, use a
# sealed secret / external secret store instead of chart values.
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "weather.fullname" . }}-secrets
  labels:
    {{- include "weather.labels" . | nindent 4 }}
type: Opaque
stringData:
  POSTGRES_PASSWORD: {{ .Values.postgres.password | quote }}
  RABBITMQ_DEFAULT_PASS: {{ .Values.rabbitmq.password | quote }}
  GRAFANA_PASSWORD: {{ .Values.grafana.password | quote }}
---
# The Postgres schema. Mounted into the postgres container's
# /docker-entrypoint-initdb.d, which the image only runs on a genuinely
# empty data directory.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "weather.fullname" . }}-initdb
  labels:
    {{- include "weather.labels" . | nindent 4 }}
data:
  init.sql: |
{{ .Files.Get "files/init.sql" | indent 4 }}
KINDGEN_EOF

cat > "charts/weather/templates/consumer.yaml" <<'KINDGEN_EOF'
# weather-consumer: MODE=consumer. Drains the queue and writes through
# store's gRPC. No ports, no service - nothing ever calls it.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "weather.fullname" . }}-consumer
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: consumer
spec:
  replicas: {{ .Values.app.replicas.consumer }}
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: consumer
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: consumer
      annotations:
        checksum/config: {{ include (print .Template.BasePath "/config.yaml") . | sha256sum }}
    spec:
      containers:
        - name: consumer
          image: "{{ include "weather.image" . }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          env:
            - name: MODE
              value: consumer
          envFrom:
            - configMapRef:
                name: {{ include "weather.fullname" . }}-env
            - secretRef:
                name: {{ include "weather.fullname" . }}-secrets
          resources:
            {{- toYaml .Values.resources.app | nindent 12 }}
KINDGEN_EOF

cat > "charts/weather/templates/grafana.yaml" <<'KINDGEN_EOF'
{{- if .Values.grafana.enabled }}
# Grafana, provisioned on first boot: one Prometheus datasource and one
# starter dashboard. Nothing to click through in the UI to get a graph.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "weather.fullname" . }}-grafana-provisioning
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: grafana
data:
  datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        access: proxy
        url: {{ printf "http://%s-prometheus:9090" (include "weather.fullname" .) }}
        isDefault: true
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "weather.fullname" . }}-grafana-dashboards
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: grafana
data:
  weather.json: |
{{ .Files.Get "files/grafana-dashboard-weather.json" | indent 4 }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "weather.fullname" . }}-grafana
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: grafana
spec:
  accessModes: ["ReadWriteOnce"]
  {{- with .Values.storageClassName }}
  storageClassName: {{ . | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.grafana.storage | quote }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "weather.fullname" . }}-grafana
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: grafana
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: grafana
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: grafana
      annotations:
        # Provisioning is mounted from ConfigMaps, so the same rule as the
        # app pods applies: hash it or an edited datasource never lands.
        # Hashes the values, not this file - including a template from
        # inside itself would recurse forever.
        checksum/config: {{ toYaml .Values.grafana | sha256sum }}
        checksum/dashboard: {{ .Files.Get "files/grafana-dashboard-weather.json" | sha256sum }}
    spec:
      # The image runs as uid 472.
      securityContext:
        fsGroup: 472
      containers:
        - name: grafana
          image: {{ .Values.grafana.image | quote }}
          imagePullPolicy: IfNotPresent
          env:
            - name: GF_SECURITY_ADMIN_USER
              value: {{ .Values.grafana.user | quote }}
            - name: GF_SECURITY_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "weather.fullname" . }}-secrets
                  key: GRAFANA_PASSWORD
            - name: GF_USERS_ALLOW_SIGN_UP
              value: "false"
          ports:
            - name: http
              containerPort: 3000
          readinessProbe:
            httpGet:
              path: /api/health
              port: http
            initialDelaySeconds: 15
            periodSeconds: 15
          volumeMounts:
            - name: provisioning-datasources
              mountPath: /etc/grafana/provisioning/datasources
              readOnly: true
            - name: provisioning-dashboards
              mountPath: /etc/grafana/provisioning/dashboards
              readOnly: true
            - name: dashboards
              mountPath: /var/lib/grafana/dashboards
              readOnly: true
            - name: data
              mountPath: /var/lib/grafana
          resources:
            {{- toYaml .Values.resources.data | nindent 12 }}
      volumes:
        # Same ConfigMap mounted twice, one key each, because Grafana
        # expects datasources and dashboard providers in two directories.
        - name: provisioning-datasources
          configMap:
            name: {{ include "weather.fullname" . }}-grafana-provisioning
            items:
              - key: datasource.yaml
                path: datasource.yaml
        - name: provisioning-dashboards
          configMap:
            name: {{ include "weather.fullname" . }}-grafana-provisioning
            items:
              - key: dashboards.yaml
                path: dashboards.yaml
        - name: dashboards
          configMap:
            name: {{ include "weather.fullname" . }}-grafana-dashboards
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "weather.fullname" . }}-grafana
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-grafana
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: grafana
spec:
  type: {{ if .Values.nodePorts.enabled }}NodePort{{ else }}ClusterIP{{ end }}
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: grafana
  ports:
    - name: http
      port: 3000
      targetPort: http
      {{- if .Values.nodePorts.enabled }}
      nodePort: {{ .Values.nodePorts.grafana }}
      {{- end }}
{{- end }}
KINDGEN_EOF

cat > "charts/weather/templates/ingress.yaml" <<'KINDGEN_EOF'
{{- if .Values.ingress.enabled }}
# Optional. Only useful once an ingress controller is installed in the
# cluster (see README: ingress-nginx was retired in March 2026, Traefik
# is the maintained option). Without a controller this object is inert.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "weather.fullname" . }}
  labels:
    {{- include "weather.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className | quote }}
  rules:
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "weather.fullname" . }}-api
                port:
                  number: {{ .Values.app.apiPort }}
{{- end }}
KINDGEN_EOF

cat > "charts/weather/templates/postgres.yaml" <<'KINDGEN_EOF'
# Postgres: the permanent record. StatefulSet (not Deployment) because it
# owns a volume and its identity matters.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "weather.fullname" . }}-postgres
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
spec:
  serviceName: {{ include "weather.fullname" . }}-postgres
  replicas: 1
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: postgres
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: postgres
      annotations:
        # Recreates the pod when init.sql changes. Note this does NOT
        # re-run the schema: the image only executes initdb scripts on a
        # genuinely empty data directory. A schema change needs a fresh
        # volume (make clean && make deploy).
        checksum/initdb: {{ .Files.Get "files/init.sql" | sha256sum }}
    spec:
      containers:
        - name: postgres
          image: {{ .Values.postgres.image | quote }}
          imagePullPolicy: IfNotPresent
          env:
            - name: POSTGRES_USER
              value: {{ .Values.postgres.user | quote }}
            - name: POSTGRES_DB
              value: {{ .Values.postgres.database | quote }}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "weather.fullname" . }}-secrets
                  key: POSTGRES_PASSWORD
          ports:
            - name: postgres
              containerPort: 5432
          volumeMounts:
            # Postgres 18 moved its expected mount point here from
            # /var/lib/postgresql/data. Mounting the old path makes the
            # container refuse to start.
            - name: data
              mountPath: {{ .Values.postgres.mountPath | quote }}
            - name: initdb
              mountPath: /docker-entrypoint-initdb.d
              readOnly: true
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: postgres
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            {{- toYaml .Values.resources.data | nindent 12 }}
      volumes:
        - name: initdb
          configMap:
            name: {{ include "weather.fullname" . }}-initdb
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- with .Values.storageClassName }}
        storageClassName: {{ . | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.postgres.storage | quote }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-postgres
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
spec:
  type: ClusterIP
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
KINDGEN_EOF

cat > "charts/weather/templates/prometheus.yaml" <<'KINDGEN_EOF'
{{- if .Values.prometheus.enabled }}
# Prometheus. The scrape config is templated (not a static file) so the
# targets follow the release name automatically.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "weather.fullname" . }}-prometheus
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: prometheus
data:
  prometheus.yml: |
    global:
      scrape_interval: {{ .Values.prometheus.scrapeInterval }}

    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ["localhost:9090"]

      - job_name: weather-api
        static_configs:
          - targets: ["{{ include "weather.fullname" . }}-api:{{ .Values.app.apiPort }}"]

      - job_name: weather-store
        static_configs:
          - targets: ["{{ include "weather.fullname" . }}-store:9091"]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "weather.fullname" . }}-prometheus
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: prometheus
spec:
  accessModes: ["ReadWriteOnce"]
  {{- with .Values.storageClassName }}
  storageClassName: {{ . | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.prometheus.storage | quote }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "weather.fullname" . }}-prometheus
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: prometheus
spec:
  replicas: 1
  # Recreate, not RollingUpdate: a ReadWriteOnce volume can't be attached
  # to an old and a new pod at the same time.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: prometheus
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: prometheus
      annotations:
        checksum/config: {{ toYaml .Values.prometheus | sha256sum }}
    spec:
      # The image runs as uid 65534 (nobody).
      securityContext:
        fsGroup: 65534
      containers:
        - name: prometheus
          image: {{ .Values.prometheus.image | quote }}
          imagePullPolicy: IfNotPresent
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
          ports:
            - name: http
              containerPort: 9090
          readinessProbe:
            httpGet:
              path: /-/ready
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
              readOnly: true
            - name: data
              mountPath: /prometheus
          resources:
            {{- toYaml .Values.resources.data | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: {{ include "weather.fullname" . }}-prometheus
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "weather.fullname" . }}-prometheus
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-prometheus
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: prometheus
spec:
  type: {{ if .Values.nodePorts.enabled }}NodePort{{ else }}ClusterIP{{ end }}
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: prometheus
  ports:
    - name: http
      port: 9090
      targetPort: http
      {{- if .Values.nodePorts.enabled }}
      nodePort: {{ .Values.nodePorts.prometheus }}
      {{- end }}
{{- end }}
KINDGEN_EOF

cat > "charts/weather/templates/rabbitmq.yaml" <<'KINDGEN_EOF'
# RabbitMQ: decouples the api's fetch loop from the consumer's writes.
# StatefulSet for the same reason as Postgres - it keeps a volume.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "weather.fullname" . }}-rabbitmq
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: rabbitmq
spec:
  serviceName: {{ include "weather.fullname" . }}-rabbitmq
  replicas: 1
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: rabbitmq
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: rabbitmq
    spec:
      # The image runs as uid 999; fsGroup makes the mounted volume
      # writable for it.
      securityContext:
        fsGroup: 999
      containers:
        - name: rabbitmq
          image: {{ .Values.rabbitmq.image | quote }}
          imagePullPolicy: IfNotPresent
          env:
            - name: RABBITMQ_DEFAULT_USER
              value: {{ .Values.rabbitmq.user | quote }}
            - name: RABBITMQ_DEFAULT_PASS
              valueFrom:
                secretKeyRef:
                  name: {{ include "weather.fullname" . }}-secrets
                  key: RABBITMQ_DEFAULT_PASS
          ports:
            - name: amqp
              containerPort: 5672
            - name: management
              containerPort: 15672
          readinessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "ping"]
            initialDelaySeconds: 20
            periodSeconds: 15
            timeoutSeconds: 10
          volumeMounts:
            - name: data
              mountPath: /var/lib/rabbitmq
          resources:
            {{- toYaml .Values.resources.data | nindent 12 }}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- with .Values.storageClassName }}
        storageClassName: {{ . | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.rabbitmq.storage | quote }}
---
# In-cluster service: AMQP stays internal.
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-rabbitmq
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: rabbitmq
spec:
  type: ClusterIP
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: rabbitmq
  ports:
    - name: amqp
      port: 5672
      targetPort: amqp
    - name: management
      port: 15672
      targetPort: management
{{- if .Values.nodePorts.enabled }}
---
# Separate NodePort service so only the management UI is exposed to the
# host (http://localhost:15672), never the AMQP port.
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-rabbitmq-ui
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: rabbitmq
spec:
  type: NodePort
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: rabbitmq
  ports:
    - name: management
      port: 15672
      targetPort: management
      nodePort: {{ .Values.nodePorts.rabbitmq }}
{{- end }}
KINDGEN_EOF

cat > "charts/weather/templates/redis.yaml" <<'KINDGEN_EOF'
# Redis: cache of the latest reading per city. No volume on purpose -
# a wiped cache costs one extra Postgres query, nothing more.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "weather.fullname" . }}-redis
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: redis
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: redis
    spec:
      containers:
        - name: redis
          image: {{ .Values.redis.image | quote }}
          imagePullPolicy: IfNotPresent
          # Persistence off: this is a cache, not a database.
          args: ["redis-server", "--save", "", "--appendonly", "no"]
          ports:
            - name: redis
              containerPort: 6379
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 3
            periodSeconds: 10
          resources:
            {{- toYaml .Values.resources.app | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-redis
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  type: ClusterIP
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: redis
  ports:
    - name: redis
      port: 6379
      targetPort: redis
KINDGEN_EOF

cat > "charts/weather/templates/store.yaml" <<'KINDGEN_EOF'
# weather-store: MODE=store. gRPC on 9090, small REST surface on 9091.
# The only workload allowed to talk to Postgres and Redis directly.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "weather.fullname" . }}-store
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: store
spec:
  replicas: {{ .Values.app.replicas.store }}
  selector:
    matchLabels:
      {{- include "weather.selector" . | nindent 6 }}
      app.kubernetes.io/component: store
  template:
    metadata:
      labels:
        {{- include "weather.labels" . | nindent 8 }}
        app.kubernetes.io/component: store
      annotations:
        checksum/config: {{ include (print .Template.BasePath "/config.yaml") . | sha256sum }}
    spec:
      containers:
        - name: store
          image: "{{ include "weather.image" . }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          env:
            - name: MODE
              value: store
          envFrom:
            - configMapRef:
                name: {{ include "weather.fullname" . }}-env
            - secretRef:
                name: {{ include "weather.fullname" . }}-secrets
          ports:
            - name: grpc
              containerPort: 9090
            - name: http
              containerPort: 9091
          # store retries Postgres for up to 60s and only then starts
          # serving HTTP, so give startup its own budget.
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            {{- toYaml .Values.resources.app | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "weather.fullname" . }}-store
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: store
spec:
  type: ClusterIP
  selector:
    {{- include "weather.selector" . | nindent 4 }}
    app.kubernetes.io/component: store
  ports:
    - name: grpc
      port: 9090
      targetPort: grpc
    - name: http
      port: 9091
      targetPort: http
KINDGEN_EOF

cat > "charts/weather/templates/tests/api-smoke.yaml" <<'KINDGEN_EOF'
# `helm test` target: proves the deployed release actually answers, not
# just that it rendered. Run it with `make smoke` (or `helm test`), and
# CI runs it as the e2e smoke step.
#
# It reuses the application image instead of pinning a curl image: that
# image is already on the node, so there is nothing to pull (which also
# means this works offline), and it is one less version to keep updated.
# The base is alpine, so busybox wget is available.
#
# The checks walk the whole read path on purpose:
#   1. api /healthz     - the api process is up
#   2. store /healthz   - store is up and reachable through its Service
#   3. api /cities      - api -> store gRPC -> Postgres actually works
# A green /healthz with a broken gRPC link is the failure this catches.
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "weather.fullname" . }}-smoke
  labels:
    {{- include "weather.labels" . | nindent 4 }}
    app.kubernetes.io/component: smoke-test
  annotations:
    helm.sh/hook: test
    # Argo CD renders the chart with `helm template` and applies the
    # result, so it does not honour Helm's test hook - it would treat
    # this pod as an ordinary resource and re-run it on every sync.
    # Skip means Argo CD never applies this manifest at all.
    argocd.argoproj.io/hook: Skip
    # Delete a leftover pod from a previous run before creating this one,
    # and keep the pod afterwards - on a pass as well as on a failure.
    #
    # hook-succeeded is deliberately NOT here. With it, Helm deleted the
    # pod the moment the test passed, and `helm test --logs` (see `make
    # smoke`) then failed with `pods "weather-smoke" not found` - a
    # PASSING test reported as an error. before-hook-creation alone still
    # means only one pod ever exists: the next run removes it first. The
    # cost is one Completed pod visible in `make status` between runs,
    # which is also what makes the logs readable after the fact.
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  restartPolicy: Never
  containers:
    - name: smoke
      image: "{{ include "weather.image" . }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -eu
          api="{{ include "weather.fullname" . }}-api:{{ .Values.app.apiPort }}"
          store="{{ include "weather.fullname" . }}-store:9091"

          echo "GET $api/healthz"
          wget -qO- "http://${api}/healthz"
          echo

          echo "GET $store/healthz"
          wget -qO- "http://${store}/healthz"
          echo

          echo "GET $api/cities"
          cities="$(wget -qO- "http://${api}/cities")"
          echo "$cities"

          # An empty list means api reached store but the seed never
          # landed - a real failure, and invisible to /healthz.
          #
          # Match "Name", capitalised: cityCoord in city_cache.go has no
          # json tags, so encoding/json uses the Go field names verbatim.
          # Grepping for lowercase "name" failed against a perfectly
          # healthy release - the endpoint answered with five cities and
          # this test still called it empty.
          case "$cities" in
            *'"Name"'*) echo "smoke test ok" ;;
            *) echo "no cities returned" >&2; exit 1 ;;
          esac
      resources:
        {{- toYaml .Values.resources.app | nindent 8 }}
KINDGEN_EOF

cat > "gitops/README.md" <<'KINDGEN_EOF'
# GitOps track (Argo CD)

`make up` is the fast path: build, load, `helm upgrade`. This folder is the
slower, more honest path — the cluster follows git, not your terminal.

It runs on its **own kind cluster**, `weather-gitops`. That is not tidiness:
the `Application` syncs with `selfHeal: true`, so Argo CD reverts anything that
is not in git — including the `weather:dev` image `make image` just side-loaded.
One cluster per workflow.

## Install

```bash
make gitops-up              # create the cluster, install Argo CD, register the app
make gitops-status          # sync + health + the live revision
make argocd-password        # initial admin password
make argocd-ui              # port-forward, then open https://localhost:8081
make gitops-down            # delete the cluster
```

Point it at your own fork first, either by editing `application.yaml` and
`project.yaml` or with `make gitops REPO_URL=https://github.com/<you>/weather-kind.git`.

What gets applied:

| File | What it does |
| --- | --- |
| `project.yaml` | An `AppProject` that limits the app to namespace `weather` and namespaced resources only |
| `application.yaml` | The `Application`: this repo, `charts/weather`, **`values-gitops.yaml`**, auto-sync with prune + self-heal |

## How the image gets there

Argo CD syncs *manifests from git*. It cannot build your Go code, and it does
not watch GHCR — a new image alone changes nothing, because git is unchanged.

So CI writes the deploy back into git:

```
git push (app code)
   |
   +-> test -> chart -> e2e (real kind cluster + helm test) -> build-and-push
   |
   +-> bump  ->  pull request pinning the new digest in values-gitops.yaml
                    |
                 you review the diff and merge
                    |
                 Argo CD syncs  ->  the three app deployments roll
```

The reference is a **digest**, not a tag. A tag can be overwritten and moved; a
digest is content-addressed, so what Argo CD deploys is byte-for-byte what CI
tested. `weather.image` in `_helpers.tpl` uses `image.digest` when it is set and
falls back to `repository:tag` otherwise — which is how the dev cluster keeps
working with its locally built `weather:dev`.

It is a pull request rather than a push to `main` so the deploy is a diff you
approve and branch protection still applies. A docs-only commit rebuilds to the
same digest, produces no diff, and therefore opens no pull request — that is
what stops a merge → build → bump loop, with no `[skip ci]` needed.

## Two settings on your fork

1. The GHCR package must be **Public**, or the cluster cannot pull the image and
   the pods sit in `ImagePullBackOff`. There is no `imagePullSecret` in the chart.
2. Settings → Actions → General → **Allow GitHub Actions to create and approve
   pull requests**, or the `bump` job fails with a 403 that explains nothing.

This cluster also pulls from the internet on every sync, so it needs the VPN up.
The dev cluster stays fully offline-capable.

## No auto-updater on purpose

Nothing here watches a registry and redeploys by itself (the compose track's
Watchtower was archived in Dec 2025, after it removed containers it then failed
to recreate). `selfHeal` reverts *drift from git* — it does not chase new image
tags. A deploy is always a commit someone merged.

## Differences from the dev cluster

| | `weather` | `weather-gitops` |
| --- | --- | --- |
| Values | `values-kind.yaml` | `values-gitops.yaml` |
| Image | `weather:dev`, `kind load`ed | GHCR, pinned by digest |
| Prometheus / Grafana | on | off, to leave room for Argo CD |
| UI | `http://localhost:8080` | `http://localhost:8082` |
| RabbitMQ | `http://localhost:15672` | `http://localhost:15673` |

Host ports cannot overlap — a taken port makes `kind create cluster` fail
outright. The api is on 8082 rather than 8081 because `make argocd-ui`
port-forwards the Argo CD UI to 8081. On 8GB, run one cluster at a time:
`docker stop` the idle node container parks it with its volumes intact.

## Useful checks

```bash
make gitops-status                               # the short version
kubectl -n argocd describe application weather   # sync + health detail
kubectl -n weather get pods
```

If the app is `OutOfSync` forever, it is almost always one of:

1. `repoURL` still points at someone else's repo (patch it with `make gitops REPO_URL=...`).
2. The chart renders an object the `AppProject` does not allow (check `describe`).
3. `image.digest` is still empty and `tag: latest` refers to a package that is
   private or was never pushed — pods `ImagePullBackOff`, app health `Degraded`.
4. You edited the cluster by hand. selfHeal reverted you; that is the feature.

Note that `make smoke` does **not** work here: it is `helm test`, and Argo CD
applied rendered manifests rather than installing a Helm release, so there is
no release to test. The chart's smoke pod also carries
`argocd.argoproj.io/hook: Skip` so Argo CD never applies it. Use
`make gitops-status` and `http://localhost:8082` to check this cluster.
KINDGEN_EOF

cat > "gitops/argocd/application.yaml" <<'KINDGEN_EOF'
# The GitOps entry point: Argo CD watches this repo and keeps the cluster
# matching charts/weather.
#
# Before applying, set repoURL to your own fork/clone URL - or run
#   make gitops REPO_URL=https://github.com/<you>/weather-kind.git
# which patches it for you.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: weather
  namespace: argocd
  finalizers:
    # Deleting the Application then also deletes what it created.
    - resources-finalizer.argocd.argoproj.io
spec:
  project: weather
  source:
    repoURL: https://github.com/ericvalijani/weather-kind.git
    targetRevision: main
    path: charts/weather
    helm:
      valueFiles:
        # NOT values-kind.yaml. That file points at weather:dev, which
        # only exists inside the dev cluster because `kind load` put it
        # there - Argo CD has no way to produce it. values-gitops.yaml
        # pulls the GHCR image that CI built, pinned by digest.
        - values-gitops.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: weather
  syncPolicy:
    automated:
      # prune: delete resources removed from git
      # selfHeal: revert manual kubectl edits back to what git says
      #
      # selfHeal is why this belongs on the weather-gitops cluster and
      # not the dev one: it will undo a `make image` rollout within
      # seconds, because that image is not what git says. Install this
      # with `make gitops-up`, which creates the second cluster first.
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  # Keep a short history so rollbacks are quick but etcd stays small.
  revisionHistoryLimit: 5
KINDGEN_EOF

cat > "gitops/argocd/project.yaml" <<'KINDGEN_EOF'
# A dedicated AppProject instead of using "default": it scopes what the
# weather Application is allowed to touch, which is the whole point of
# having projects at all.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: weather
  namespace: argocd
spec:
  description: Weather stack (kind + Helm + Argo CD track)
  sourceRepos:
    - https://github.com/ericvalijani/weather-kind.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: weather
  # Almost nothing cluster-scoped - but Namespace has to be allowed.
  # The Application syncs with CreateNamespace=true, and Argo CD checks
  # that creation against this list: with an empty list the first sync
  # on a fresh cluster fails with
  #   Namespace "weather" is not permitted in project "weather"
  # and nothing else in this repo creates that namespace.
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
KINDGEN_EOF

cat > "kind/bootstrap.sh" <<'KINDGEN_EOF'
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
KINDGEN_EOF

cat > "kind/cluster-gitops.yaml" <<'KINDGEN_EOF'
# Second kind cluster: the GitOps / Argo CD track.
#
# Why a separate cluster at all: the Argo CD Application syncs with
# selfHeal enabled, which means it actively reverts anything that does
# not match git. On the dev cluster that would undo `make image` a few
# seconds after you run it. So the two workflows get one cluster each:
#
#   weather          `make up`   - local weather:dev image, you edit it
#   weather-gitops   `make gitops-up` - GHCR image by digest, git decides
#
# Host ports differ from the dev cluster's so both can run at the same
# time. A port that is already taken makes `kind create cluster` fail
# outright, which is why they cannot overlap.
#
#   http://localhost:8082  -> weather-api      (NodePort 30080)
#   http://localhost:3001  -> grafana          (NodePort 30300)
#   http://localhost:9091  -> prometheus       (NodePort 30900)
#   http://localhost:15673 -> rabbitmq mgmt    (NodePort 31567)
#
# The api is on 8082, not 8081, because 8081 is where `make argocd-ui`
# port-forwards the Argo CD UI. Two things on one host port is the same
# failure as two clusters on one host port.
#
# Grafana and Prometheus are disabled in values-gitops.yaml, so 3001 and
# 9091 currently map to NodePorts nothing listens on. That is deliberate:
# kind cannot add port mappings to a cluster that already exists, so
# keeping them means flipping prometheus.enabled or grafana.enabled to
# true needs no cluster rebuild. The cost is two held host ports.
#
# One control-plane and no workers, unlike kind/cluster.yaml: this
# cluster exists to watch Argo CD reconcile, not to study scheduling,
# and Argo CD itself needs ~400Mi on top of the stack. On an 8GB laptop
# run one cluster at a time - `docker stop`/`docker start` the node
# container keeps its volumes, which is much cheaper than recreating.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: weather-gitops

nodes:
  - role: control-plane
    image: kindest/node:v1.37.0
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8082
        protocol: TCP
      - containerPort: 30300
        hostPort: 3001
        protocol: TCP
      - containerPort: 30900
        hostPort: 9091
        protocol: TCP
      - containerPort: 31567
        hostPort: 15673
        protocol: TCP
KINDGEN_EOF

cat > "kind/cluster.yaml" <<'KINDGEN_EOF'
# Kind cluster for the weather stack.
#
# One control-plane + two workers, so scheduling, node affinity and
# rollouts behave like a real (small) cluster instead of a single box.
#
# extraPortMappings publish the NodePorts the Helm chart creates onto
# localhost, so no ingress controller is required to click around the UIs:
#
#   http://localhost:8080  -> weather-api      (NodePort 30080)
#   http://localhost:3000  -> grafana          (NodePort 30300)
#   http://localhost:9090  -> prometheus       (NodePort 30900)
#   http://localhost:15672 -> rabbitmq mgmt    (NodePort 31567)
#
# Ports 80/443 are deliberately NOT mapped: on a normal Ubuntu box
# something is often already listening there, and a busy host port makes
# `kind create cluster` fail outright. If you later install an ingress
# controller and set ingress.enabled=true, add them here and recreate
# the cluster:
#
#   - containerPort: 80
#     hostPort: 80
#     protocol: TCP
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: weather

nodes:
  - role: control-plane
    image: kindest/node:v1.37.0
    kubeadmConfigPatches:
      # Label the node so an ingress controller (if you add one) can be
      # pinned here with a nodeSelector.
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
      - containerPort: 30300
        hostPort: 3000
        protocol: TCP
      - containerPort: 30900
        hostPort: 9090
        protocol: TCP
      - containerPort: 31567
        hostPort: 15672
        protocol: TCP

  - role: worker
    image: kindest/node:v1.37.0
  - role: worker
    image: kindest/node:v1.37.0
KINDGEN_EOF

chmod +x "generate.sh" 2>/dev/null || true
chmod +x "kind/bootstrap.sh" 2>/dev/null || true

echo "weather-kind generated in $TARGET"
echo "next: cd $TARGET && make up"
