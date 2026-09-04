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
