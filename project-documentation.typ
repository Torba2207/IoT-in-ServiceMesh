#set document(title: "IoT in a Service Mesh — Project Documentation", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm), numbering: "1")
#set text(font: "New Computer Modern", size: 11pt)
#set heading(numbering: "1.")
#show link: underline
#show heading.where(level: 1): it => { v(0.3cm); it; v(0.15cm) }

#let badge(c, t) = box(fill: c, inset: (x: 5pt, y: 2pt), radius: 3pt, text(fill: white, size: 9pt, t))
#let note(body) = block(fill: luma(240), inset: 9pt, radius: 3pt, width: 100%, body)
#let head-fill = (_, row) => if row == 0 { luma(220) } else { white }

#align(center)[
  #text(size: 22pt, weight: "bold")[IoT in a Service Mesh]
  #v(0.2cm)
  #text(size: 13pt, fill: gray)[A LoRaWAN IoT platform on MicroK8s, secured with Linkerd and delivered via GitOps]
  #v(0.2cm)
  #text(size: 10pt, fill: gray)[Oleksandr Nychyporchuk · 2026-06-11]
]

#v(0.4cm)
#line(length: 100%)
#v(0.3cm)

#outline(depth: 2, indent: auto)
#pagebreak()

= Overview

This project runs a complete *LoRaWAN IoT data pipeline* on a self-hosted Kubernetes
(MicroK8s) cluster. Physical Milesight sensors transmit over LoRa to a gateway; the
gateway forwards frames into the cluster, where they are decoded, stored, and visualised.

The distinguishing goal of the project is *not just to make the pipeline work, but to run
it inside a zero-trust service mesh*. Every pod-to-pod connection is mutually
authenticated and encrypted with mTLS by *Linkerd*, and every service is denied by
default unless an explicit authorization policy allows it. The entire platform is
declarative: it is described in Git and reconciled by *ArgoCD*, and it can be torn down
and rebuilt from scratch with a single `make` target.

== Technology at a glance

#table(
  columns: (auto, 1fr, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Component*], [*Role in the project*], [*Layer*],
  [MicroK8s], [Lightweight Kubernetes cluster (control plane + 2 workers)], [Platform],
  [Linkerd], [Service mesh: mTLS, identity, zero-trust authorization], [Mesh],
  [Linkerd Viz], [Observability: Prometheus metrics, Tap, dashboard], [Mesh],
  [ArgoCD], [GitOps continuous delivery — reconciles all apps from Git], [Delivery],
  [ChirpStack], [LoRaWAN Network + Application Server (v4)], [Application],
  [ChirpStack Gateway Bridge], [Translates Semtech UDP packet-forwarder ↔ MQTT], [Application],
  [Mosquitto], [MQTT broker between gateway-bridge and ChirpStack], [Application],
  [PostgreSQL / Redis], [ChirpStack persistence and device-session cache], [Data],
  [Node-RED], [Flow engine: MQTT → decode → PostgreSQL], [Application],
  [iot-stat-reader], [FastAPI backend exposing the stored uplinks], [Application],
  [iot-stat-frontend], [React + Tailwind dashboard (plots + table)], [Application],
  [Ansible + Make], [Automation: provision, deploy, tear down, bootstrap devices], [Automation],
)
#pagebreak()
= Architecture

== End-to-end data flow

```
 Milesight sensors (LoRa)
        │  radio
        ▼
 Milesight UG63 gateway
        │  Semtech UDP (packet forwarder) → NodePort 31700/UDP
        ▼
 chirpstack-gateway-bridge ──MQTT──► mosquitto ──MQTT──► chirpstack
        ▲                                                   │
        │                            decodes frame, runs JS payload codec
        │                                                   ▼
        │                           application uplink on MQTT topic
        │                                                   │
        │                                                   ▼
        └──────────────────────────────────────────► Node-RED  (subscribes)
                                                            │ INSERT
                                                            ▼
                                                       PostgreSQL  (device_uplinks)
                                                            ▲
                                                            │ SELECT
                                            iot-stat-reader (FastAPI)
                                                            ▲
                                                            │ /api  (nginx proxy)
                                            iot-stat-frontend (React)
```

Every arrow that crosses a pod boundary inside the cluster is transparently wrapped in
*mutual TLS* by the Linkerd proxy, and is allowed only because an explicit authorization
policy permits that specific client identity.

== The cluster

The cluster is *MicroK8s* (Canonical's lightweight, snap-packaged Kubernetes), chosen for
its low footprint and trivial multi-node join model. It is provisioned by Ansible across
four VMs:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Host*], [*Address*], [*Role*],
  [`cp`], [`10.29.16.101`], [Control plane (also schedules workloads)],
  [`worker1`], [`10.29.16.102`], [Worker node],
  [`worker2`], [`10.29.16.103`], [Worker node],
  [`load-gen`], [`10.29.16.104`], [k6 load generator (testing, off-cluster)],
)

Enabled add-ons: `dns` (CoreDNS), `hostpath-storage` (PVCs for PostgreSQL and Node-RED),
and the `community` repository. The *Gateway API CRDs* are installed as a cluster-level
prerequisite for Linkerd's policy stack.

All application workloads live in a single namespace, `iot-system`. ArgoCD runs in
`argocd`, and Linkerd in `linkerd` / `linkerd-viz`.

= Linkerd — the service mesh

Linkerd is the heart of the project. It turns an ordinary set of pods into a
*zero-trust network* where traffic is encrypted, authenticated, and authorized without any
change to application code.

== Why Linkerd (and why a mesh at all)

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Benefit*], [*What it gives this project*],
  [*Automatic mTLS*], [Every meshed connection is mutually authenticated and encrypted with certificates Linkerd issues and rotates automatically — no app changes, no manual PKI.],
  [*Workload identity*], [Each pod gets a cryptographic identity derived from its Kubernetes ServiceAccount, e.g. `chirpstack.iot-system.serviceaccount.identity.linkerd.cluster.local`. Authorization is based on *who* the caller is, not just its IP.],
  [*Zero-trust authorization*], [A namespace-wide *deny-by-default* policy means nothing can talk to anything unless an explicit `Server` + `AuthorizationPolicy` allows it.],
  [*Observability*], [Golden metrics (success rate, RPS, latency) and live request inspection (Tap) for free, via Linkerd Viz.],
  [*Low overhead*], [Linkerd's data plane is a purpose-built *Rust micro-proxy* — far lighter and simpler than Envoy-based meshes (e.g. Istio), which matters on small self-hosted nodes.],
  [*Transparency*], [Injected as a sidecar; ChirpStack, Node-RED, etc. are completely unaware they are being meshed.],
)

== How Linkerd is installed

The control plane is installed from the Linkerd CLI and applied with `kubectl`
(idempotently — the automation skips installation if `linkerd-config` already exists):

```bash
linkerd install --crds | kubectl apply -f -      # CRDs (Server, policies, …)
linkerd install        | kubectl apply -f -      # control plane in ns 'linkerd'
linkerd check                                     # gate until healthy
```

The data-plane proxy in use is `cr.l5d.io/linkerd/proxy:edge-26.5.1`. Crucially, Linkerd
injects the proxy as a *native sidecar* (a Kubernetes init container with
`restartPolicy: Always`). This is why every application pod shows as `2/2 Ready`: the
proxy starts before the app container and is guaranteed to be running for the whole pod
lifecycle, including during other init containers.

== Meshing the namespace

Injection and policy are configured once, at the `iot-system` namespace level
(`manifests/bootstrap/iot-system-namespace.yaml`):

```yaml
metadata:
  name: iot-system
  annotations:
    linkerd.io/inject: enabled                       # mesh every pod here
    config.linkerd.io/default-inbound-policy: deny   # zero-trust default
    config.linkerd.io/opaque-ports: "1883"           # MQTT is raw TCP
```

- `linkerd.io/inject: enabled` — the proxy injector mutates every new pod in the
  namespace to add the sidecar.
- `default-inbound-policy: deny` — *the cornerstone of the security model*. With this set,
  an inbound connection to any meshed pod is rejected unless an `AuthorizationPolicy`
  explicitly allows it.
- `opaque-ports: "1883"` — see #link(<opaque>)[§ Opaque ports].

== The zero-trust authorization model

Under deny-by-default, access is granted by three kinds of resources working together:

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Resource*], [*Purpose*],
  [`Server`], [Marks a specific *port* on a set of pods as a protected target (and declares its protocol).],
  [`AuthorizationPolicy`], [Binds a `Server` to one or more *authentications* — i.e. "these clients may reach this Server".],
  [`MeshTLSAuthentication`], [Authenticates clients by *mTLS identity* (ServiceAccount). Used for internal service-to-service traffic.],
  [`NetworkAuthentication`], [Authenticates clients by *source network/CIDR*. Used to admit external (non-meshed, NodePort) traffic, typically `0.0.0.0/0`.],
)

The cluster currently defines *9 `Server`s* and *13 `AuthorizationPolicy`s*. The resulting
access matrix:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Server (port)*], [*Proto*], [*Who is allowed (and how)*],
  [`postgres-server` (5432)], [opaque], [mTLS identities: `chirpstack`, `iot-stat-reader`, `nodered`],
  [`redis-server` (6379)], [opaque], [mTLS identity: `chirpstack`],
  [`mosquitto-mqtt` (1883)], [opaque], [mTLS identities: `mqtt-client`, `chirpstack`, `gateway-bridge`, `node-red`],
  [`chirpstack-api` (8080)], [opaque], [mTLS `chirpstack` (internal) *and* network `0.0.0.0/0` (UI/gRPC)],
  [`iot-stat-reader-http` (8000)], [HTTP/1], [network `0.0.0.0/0` (external API)],
  [`iot-stat-frontend-http` (80)], [HTTP/1], [network `0.0.0.0/0` (external UI)],
  [`nodered-ui` (1880)], [HTTP/1], [network `0.0.0.0/0` (external editor)],
  [`proxy-admin` (4191)], [HTTP/1], [mTLS identities: `prometheus`, `tap` (Viz scraping)],
  [`proxy-tap` (4190)], [HTTP/2], [mTLS identity: `tap` (live request inspection)],
)

#note[
  *Defense in depth.* A service is reachable from outside the cluster only if it has
  *both* a `NodePort` Service (the network path) *and* an `AuthorizationPolicy` admitting
  the source network. The internal data stores (PostgreSQL, Redis, Mosquitto) have
  *neither* an external `0.0.0.0/0` rule *nor* a NodePort — they are restricted to specific
  mesh identities only, so even a compromised in-cluster pod cannot reach them unless it
  holds an authorized identity.
]

== Opaque ports <opaque>

By default Linkerd treats a port as HTTP and performs L7 processing. That is wrong for
*non-HTTP TCP* and for *gRPC over the same port as gRPC-web*. Such ports are marked
*opaque*, so Linkerd treats them as raw TCP — still mTLS-encrypted and still subject to
`AuthorizationPolicy`, but without L7 parsing:

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Port*], [*Why opaque*],
  [`1883` (Mosquitto)], [MQTT is a binary TCP protocol, not HTTP. Set namespace-wide via `opaque-ports`.],
  [`5432` / `6379`], [PostgreSQL and Redis wire protocols are binary TCP.],
  [`8080` (chirpstack-api)], [Serves *both* the browser's grpc-web (HTTP/1) *and* native gRPC (HTTP/2). A single L7 protocol setting can't carry both; opaque lets both pass. This was essential for the device-bootstrap script, which uses native gRPC.],
)

== Verifying the mesh

```bash
linkerd check                              # control plane + data plane health
linkerd viz edges deployment -n iot-system # every edge must show SECURED √ (mTLS)
linkerd viz stat deploy -n iot-system      # golden metrics; MESHED column = N/N
kubectl get authorizationpolicy -n iot-system
kubectl get server,meshtlsauthentication,networkauthentication -n iot-system
```

= Linkerd Viz — observability

Linkerd Viz is the observability extension. It bundles a *Prometheus* instance that
scrapes each proxy, a *Tap* API for live request inspection, a metrics API, and a web
dashboard.

Because the namespace is deny-by-default, Viz cannot scrape or tap until it is explicitly
allowed. The policy in `manifests/observability/linkerd-viz-policy.yaml` exposes two
internal proxy ports and authorizes the Viz service accounts:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Server*], [*Port*], [*Authorized identity*],
  [`proxy-admin`], [4191], [`prometheus` + `tap` (linkerd-viz) — metrics scrape],
  [`proxy-tap`], [4190], [`tap` (linkerd-viz) — live traffic frames],
)

The `Server` resources use an empty `podSelector`, so a single pair of rules covers every
pod in the namespace. The dashboard is reached locally via
`linkerd viz dashboard`.

= ArgoCD — GitOps delivery

== Why GitOps

The whole platform is described declaratively in this repository; ArgoCD continuously
reconciles the live cluster to match Git. The benefits: a single source of truth, drift
detection, auditable history, and — combined with the automation — full reproducibility.

== How it is wired

Each workload directory under `infrastructure/manifests/` is one ArgoCD `Application`
(`infrastructure/argocd/apps.yaml`). All five point at the same repository and the `dev`
branch, but different sub-paths:

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Application*], [*Source path*],
  [`chirpstack`], [`infrastructure/manifests/chirpstack`],
  [`mqtt`], [`infrastructure/manifests/mqtt`],
  [`nodered`], [`infrastructure/manifests/nodered`],
  [`iot-stat-reader`], [`infrastructure/manifests/iot-stat-reader`],
  [`iot-stat-frontend`], [`infrastructure/manifests/iot-stat-frontend`],
)

Sync policy: `automated` with `prune: false` and `selfHeal: false` — ArgoCD applies new
commits automatically, but never deletes resources removed from Git and never reverts
manual drift. The destination is the *in-cluster* API (`https://kubernetes.default.svc`),
so no external cluster credential is needed.

#note[
  *Bootstrap vs. GitOps.* The `apps.yaml` registrations, the `iot-system` namespace, and
  the Viz policy are applied *once by the setup playbook* (they must exist before ArgoCD
  can sync into the namespace). Everything inside each app's path is then managed by
  ArgoCD. Secrets are deliberately *not* in Git (see #link(<secrets>)[§ Secrets]).
]

= The application stack

== ChirpStack (LoRaWAN server)

*What:* ChirpStack v4 is an open-source LoRaWAN Network + Application Server. It manages
tenants, gateways, device profiles and devices; it handles OTAA joins, deduplicates and
decrypts uplinks, runs JavaScript payload codecs, and publishes decoded application
uplinks to MQTT.

*Why:* it is the de-facto open-source LoRaWAN stack and exposes a complete gRPC/REST API,
which makes declarative device provisioning possible.

*How:* deployed as a Deployment backed by:
- *PostgreSQL* (`StatefulSet`, hostpath PVC) — all ChirpStack state plus the project's
  custom `device_uplinks` table and `new_uplink` notify trigger, created by an
  `init.sql` ConfigMap on first boot.
- *Redis* — device-session and frame cache.
- *ChirpStack Gateway Bridge* — converts the gateway's Semtech UDP packet-forwarder
  protocol to ChirpStack's MQTT events. Exposed on `NodePort 31700/UDP` so the physical
  gateway can reach it.

The admin UI / gRPC API is exposed on `NodePort 30080`.

== Mosquitto (MQTT broker)

*What / why:* Eclipse Mosquitto is the MQTT broker that sits between the gateway-bridge
and ChirpStack (and is also where Node-RED subscribes to application uplinks). ChirpStack's
architecture is MQTT-centric, so a broker is required.

*How:* a small Deployment on port `1883`, internal-only (no NodePort), reachable solely by
the four authorized mesh identities. The port is opaque (raw TCP) in the mesh.

== Node-RED (flow engine)

*What:* Node-RED is a low-code flow engine. Here it subscribes to ChirpStack's decoded
application uplinks over MQTT, reshapes each message, and inserts it into the
`device_uplinks` PostgreSQL table.

*Why:* it makes the "MQTT → database" glue visual and easily editable, and ships a large
node palette (including PostgreSQL).

*How:* Deployment with a hostpath PVC for `/data`. Two project-specific touches make it
fully reproducible:
- A *seed init container* copies the committed `flows.json` into a fresh `/data` and
  installs the `node-red-contrib-postgresql` palette node (guarded so existing data is
  never overwritten).
- The PostgreSQL password is read from an *environment variable* injected from the
  `postgres-credentials` Secret (`passwordFieldType: env` in the flow), so no credential
  is stored in the flow or in Git.

The editor is exposed on `NodePort 31880`. The deployment uses the `Recreate` strategy
because the `/data` PVC is `ReadWriteOnce`.

== iot-stat-reader (backend API)

*What:* a small *FastAPI* service that reads the stored data and serves it as JSON
(`/devices`, `/uplinks`, `/uplinks/stream` SSE, …). *Why:* a clean, decoupled API for the
frontend, independent of ChirpStack's own API.

*How:* a Deployment connecting to PostgreSQL with credentials from the
`postgres-credentials` Secret; image `ghcr.io/torba2207/iot-stat-reader`. Exposed on
`NodePort 31800`.

== iot-stat-frontend (dashboard)

*What:* a *React + Tailwind* single-page app (built with Vite, served by nginx) with two
pages — time-series plots per device (numeric *and* categorical fields, e.g. button
press / daylight state) and a table of the 50 most recent uplinks.

*How:* multi-stage image (`node` build → `nginx` serve). nginx serves the SPA and
*reverse-proxies `/api`* to the in-cluster `iot-stat-reader`, so the browser only ever
talks to the frontend origin (no CORS, no API URL baked in). The upstream is resolved
lazily via the cluster DNS so the pod never crash-loops if the backend is briefly absent.
Exposed on `NodePort 31900`.

= Security posture

== Exposed surface

Only the following are reachable from outside the cluster (NodePort on any node IP); they
are exactly the intended exceptions, everything else is mesh-internal:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Service*], [*NodePort*], [*Reason*],
  [chirpstack-gateway-bridge], [`31700/UDP`], [Receives frames from the LoRa gateway],
  [chirpstack-ui], [`30080`], [ChirpStack admin console + gRPC],
  [nodered-ui], [`31880`], [Node-RED editor],
  [iot-stat-reader], [`31800`], [Backend API],
  [iot-stat-frontend], [`31900`], [User dashboard],
)

PostgreSQL, Redis and Mosquitto have *no* NodePort and are identity-restricted in the mesh
— they cannot be reached from outside, nor from unauthorized pods inside.

== Secrets <secrets>

No credential is committed to Git. Two Secrets are created from a gitignored `.env` by the
setup playbook, *before* ArgoCD deploys the workloads that consume them:

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Secret*], [*Contents (source: `.env`)*],
  [`chirpstack-secret`], [`api-secret` ← `CHIRPSTACK_API_SECRET`],
  [`postgres-credentials`], [`POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`],
)

Device OTAA keys (`APPKEY_<DEVEUI>`) also live only in `.env` and are passed to the
device-bootstrap at runtime.

= Automation

Everything is driven from a root `Makefile`; the cluster nodes are touched over SSH only
for provisioning, while mesh/app operations run locally against the cluster API.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Target*], [*What it does*],
  [`make setup_mk8s`], [Provision MicroK8s on the nodes (Ansible/SSH): install, add-ons, worker join, k6, Gateway API CRDs.],
  [`make set_all_up`], [Local: install Linkerd → Viz → namespace → secrets from `.env` → ArgoCD → register + sync all apps.],
  [`make setup_everything`], [`setup_mk8s` + `set_all_up` + `bootstrap_chirpstack` — full platform in one command.],
  [`make bootstrap_chirpstack`], [Provision ChirpStack tenant, application, profiles+codecs, gateway, devices and keys (idempotent).],
  [`make teardown`], [Remove all services, ArgoCD, Linkerd Viz and Linkerd (cluster nodes untouched).],
  [`make nodered_export`], [Snapshot the live Node-RED flows back into Git (password sanitised).],
  [`make status`], [ArgoCD apps + pods + mesh edges at a glance.],
)

== ChirpStack device bootstrap

`infrastructure/chirpstack/bootstrap.py` is a declarative, idempotent provisioner. It reads
`devices.yaml` (tenant, application, device profiles with JS codecs, gateway, devices) and
the OTAA keys from the environment, then reconciles ChirpStack over *native gRPC*. It
self-logs-in (admin) to obtain an API token, so no pre-created key is needed — which is
why the `chirpstack-api` port had to be opaque in the mesh.

= Reproducibility — teardown and rebuild

A deliberate design property is that the whole platform can be destroyed and rebuilt from
Git + `.env` alone:

```bash
make teardown          # wipes iot-system, ArgoCD, Linkerd, Viz
make set_all_up        # rebuilds mesh + ArgoCD + all services
make bootstrap_chirpstack   # re-provisions LoRaWAN devices
```

On rebuild, the `device_uplinks` table self-creates (init.sql), Node-RED self-seeds its
flow and palette node, the secrets are recreated from `.env`, and ChirpStack devices are
re-provisioned — with no manual cluster steps.

#note[
  *One physical caveat.* Tearing down ChirpStack wipes its device-session store. Real OTAA
  sensors still hold their previous session and keep sending *data* frames (which the fresh
  server rejects as "no device-session for dev_addr") until they *re-join* — which happens
  on a power-cycle or after their unacknowledged-uplink rejoin threshold. This is a
  property of LoRaWAN, not of the automation.
]

= Operations quick reference

```bash
# health
kubectl get applications -n argocd
kubectl get pods -n iot-system
linkerd viz edges deployment -n iot-system        # mTLS proof

# exposed surface (should be only the 5 intended NodePorts)
kubectl get svc -n iot-system | grep -E 'NodePort'

# authorization model
kubectl get server,authorizationpolicy -n iot-system
kubectl get networkauthentication -n iot-system    # 0.0.0.0/0 only on the 4 public HTTP svcs

# data pipeline
kubectl exec -n iot-system postgres-0 -c postgres -- \
  psql -U chirpstack -d chirpstack -c "SELECT count(*) FROM device_uplinks;"
```

#v(0.5cm)
#line(length: 100%)
#align(center)[#text(size: 9pt, fill: gray)[End of document]]
