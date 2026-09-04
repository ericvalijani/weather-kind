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
