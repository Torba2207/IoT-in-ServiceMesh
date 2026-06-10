#set document(title: "ArgoCD — GitOps Setup", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm))
#set text(font: "New Computer Modern", size: 11pt)
#set heading(numbering: "1.")
#show link: underline

#align(center)[
  #text(size: 20pt, weight: "bold")[ArgoCD — GitOps Setup]
  #v(0.3cm)
  #text(size: 12pt, fill: gray)[MicroK8s + ArgoCD v3.4.3 · argocd namespace · App-per-manifest-dir]
  #v(0.2cm)
  #text(size: 10pt, fill: gray)[2026-06-10]
]

#v(0.5cm)
#line(length: 100%)
#v(0.5cm)

= Overview

ArgoCD is the GitOps controller for the cluster. It continuously watches the Git repository and reconciles the live cluster state against the manifests stored under `infrastructure/manifests/`. Each workload directory becomes one ArgoCD `Application`; when a commit lands on the `dev` branch, ArgoCD pulls it and applies the changes automatically.

The repo holds four applications, all pointing at the same repository and branch but different manifest sub-paths:

#table(
  columns: (auto, 1fr, auto),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Application*], [*Source path*], [*Namespace*],
  [`chirpstack`], [`infrastructure/manifests/chirpstack`], [`iot-system`],
  [`mqtt`], [`infrastructure/manifests/mqtt`], [`iot-system`],
  [`nodered`], [`infrastructure/manifests/nodered`], [`iot-system`],
  [`iot-stat-reader`], [`infrastructure/manifests/iot-stat-reader`], [`iot-system`],
)

= Installation

ArgoCD runs in its own `argocd` namespace, installed from the upstream stable manifest. This is a one-time bootstrap done by hand (it is *not* managed by ArgoCD itself).

```bash
# Create the namespace and install ArgoCD (stable channel)
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for the core components to come up
kubectl rollout status deploy/argocd-server -n argocd
```

The control plane is MicroK8s, so the Application `destination.server` points at the MicroK8s API endpoint `https://10.29.16.101:16443` rather than the in-cluster alias.

= Registering the Applications

== Manifest

All four `Application` objects live in a single file: `infrastructure/argocd/apps.yaml`. Each entry follows the same shape — only `name` and `path` change:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: chirpstack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Torba2207/IoT-in-ServiceMesh.git
    targetRevision: dev
    path: infrastructure/manifests/chirpstack
  destination:
    server: https://10.29.16.101:16443
    namespace: iot-system
  syncPolicy:
    automated:
      enabled: true
      prune: false
      selfHeal: false
```

== Apply Command

Registering (or updating) all applications is a single apply against the `argocd` namespace:

```bash
kubectl apply -f infrastructure/argocd/apps.yaml
```

Once registered, ArgoCD takes over: it clones the repo, renders the manifests under each `path`, and applies them to `iot-system`.

== Sync Policy Explained

The `syncPolicy.automated` block decides how aggressively ArgoCD reconciles. All four apps use the same conservative settings:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Field*], [*Value*], [*Effect*],
  [`enabled`], [`true`], [Auto-apply new commits on `dev` — no manual sync needed for normal changes.],
  [`prune`], [`false`], [Resources deleted from Git are *not* removed from the cluster. They linger as `OutOfSync` until removed by hand. Safety net against accidental deletes.],
  [`selfHeal`], [`false`], [Live drift (e.g. a manual `kubectl edit`) is *not* reverted. ArgoCD only acts on Git changes, not cluster changes.],
)

#block(
  fill: luma(240),
  inset: 8pt,
  radius: 3pt,
  width: 100%,
)[
  *Trade-off to remember:* with `prune: false` + `selfHeal: false`, ArgoCD will happily show an app as `OutOfSync` forever without fixing it — e.g. an orphaned `Service` left behind after its manifest was deleted from Git. This is by design (safe), but it means a permanent yellow status until you clean it up manually or trigger a sync.
]

= Checking ArgoCD Status

== All Applications at a Glance

```bash
kubectl get applications -n argocd
```

```
NAMESPACE   NAME              SYNC STATUS   HEALTH STATUS
argocd      chirpstack        Synced        Healthy
argocd      iot-stat-reader   Synced        Healthy
argocd      mqtt              Synced        Healthy
argocd      nodered           Synced        Healthy
```

Two independent columns matter:

- *Sync status* — does the live cluster match Git? (`Synced` / `OutOfSync`)
- *Health status* — are the workloads actually running? (`Healthy` / `Progressing` / `Degraded`)

== Drill Into One Application

```bash
# Sync policy currently in effect
kubectl get application chirpstack -n argocd -o jsonpath='{.spec.syncPolicy}'

# Source repo / path / branch + the revision ArgoCD last reconciled
kubectl get application chirpstack -n argocd \
  -o jsonpath='Repo: {.spec.source.repoURL}{"\n"}Path: {.spec.source.path}{"\n"}Rev:  {.status.sync.revision}{"\n"}'

# Per-resource sync status (find exactly what is OutOfSync)
kubectl get application chirpstack -n argocd \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name}: {.status}{"\n"}{end}'

# Only the OutOfSync resources
kubectl get application chirpstack -n argocd \
  -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}{"\n"}{end}'
```

== Last Sync Operation

Useful to confirm whether the most recent auto-sync actually succeeded and which commit it applied:

```bash
kubectl get application chirpstack -n argocd \
  -o jsonpath='Phase:    {.status.operationState.phase}{"\n"}Message:  {.status.operationState.message}{"\n"}Revision: {.status.operationState.operation.sync.revision}{"\n"}Finished: {.status.operationState.finishedAt}{"\n"}'
```

```
Phase:    Succeeded
Message:  successfully synced (all tasks run)
Revision: ca7dd9d1b7167deed59b6e01a3564c2a17ab8905
Finished: 2026-06-10T10:38:18Z
```

== Controller / Pod Health

```bash
kubectl get pods -n argocd
```

The core components that should all be `Running`:

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Pod*], [*Role*],
  [`argocd-application-controller-0`], [Reconciles apps against Git — the heart of the sync loop],
  [`argocd-repo-server`], [Clones the repo and renders manifests],
  [`argocd-server`], [API + web UI],
  [`argocd-applicationset-controller`], [Generates Applications from templates (if used)],
  [`argocd-redis`], [Cache for the controller and repo-server],
  [`argocd-dex-server`], [SSO / auth],
  [`argocd-notifications-controller`], [Sends sync/health notifications],
)

= Common Operations

== Force a Refresh / Manual Sync

ArgoCD polls Git on an interval (default \~3 min, since there is no GitHub webhook configured). To skip the wait and reconcile immediately:

```bash
# Trigger a sync via the Application object
kubectl -n argocd patch app chirpstack --type merge -p '{"operation":{"sync":{}}}'
```

If the ArgoCD CLI is installed, the equivalent is `argocd app sync chirpstack` (and `argocd app get chirpstack` to inspect).

== Clearing OutOfSync Drift

Because `prune: false`, a resource removed from Git stays live and keeps the app `OutOfSync`. Delete the orphan by hand to restore `Synced`:

```bash
kubectl delete svc <orphan-name> -n iot-system
```

Alternatively, set `prune: true` in `apps.yaml` so ArgoCD removes deleted resources automatically — at the cost of losing the safety net.

== Accessing the Web UI

Run on your *local machine* (uses `kubectl port-forward`, needs your local kubeconfig):

```fish
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

Then open `https://localhost:8080`. The initial admin password is stored in a secret:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in as user `admin` with that password.

= Notes

- *Polling delay is normal.* After pushing a commit, the app stays `OutOfSync` until ArgoCD's next poll (\~3 min). It is not broken — add a GitHub webhook if faster syncs are needed.
- *Bootstrap is manual.* ArgoCD itself is installed by hand; only the four `iot-system` workloads are GitOps-managed. ArgoCD does not manage its own installation.
- *Branch is `dev`.* All applications track `targetRevision: dev`, not `main`. Changes must land on `dev` to be picked up.
- *`prune` and `selfHeal` are both off* — deliberate safety. Expect to clean up deleted resources and revert manual edits yourself.
