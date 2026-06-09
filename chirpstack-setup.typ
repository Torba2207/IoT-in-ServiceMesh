#set document(title: "ChirpStack Deployment in IoT Service Mesh", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm))
#set text(font: "New Computer Modern", size: 11pt)
#set heading(numbering: "1.")
#show link: underline

#align(center)[
  #text(size: 20pt, weight: "bold")[ChirpStack Deployment in IoT Service Mesh]
  #v(0.3cm)
  #text(size: 12pt, fill: gray)[MicroK8s + Linkerd · EU868 · UG63-868M Gateway]
  #v(0.2cm)
  #text(size: 10pt, fill: gray)[2026-06-08 → 2026-06-09]
]

#v(0.5cm)
#line(length: 100%)
#v(0.5cm)

= Overview

This document summarises the deployment of ChirpStack v4 (LoRaWAN network server) into the `iot-system` namespace of a MicroK8s cluster running Linkerd as the service mesh. The namespace enforces strict mTLS with a *deny-by-default* inbound policy, which introduced several non-obvious problems documented below.

#v(0.3cm)

*Cluster nodes:*

#table(
  columns: (auto, auto, auto),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Role*], [*Hostname*], [*IP*],
  [Control Plane], [cp-node], [10.29.16.101],
  [Worker], [worker-1], [10.29.16.102],
  [Worker], [worker-2], [10.29.16.103],
  [Load Generator], [load-gen], [10.29.16.104],
)

#v(0.3cm)

*Gateway:* Milesight UG63-868M · Semtech UDP Packet Forwarder · EU868

= Files Created

== Kubernetes Manifests

All manifests live under `infrastructure/manifests/chirpstack/`.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*File*], [*Purpose*],
  [`postgres.yaml`], [PostgreSQL 15 StatefulSet with 5 Gi PVC, init extensions (`pg_trgm`, `hstore`), Service. Credentials in a Secret.],
  [`redis.yaml`], [Redis 7 Deployment (no persistence — ephemeral session store), Service.],
  [`gateway-bridge.yaml`], [ChirpStack Gateway Bridge v4. ClusterIP for internal MQTT, NodePort UDP `:31700` for the physical UG63 gateway.],
  [`chirpstack.yaml`], [ChirpStack v4 Deployment with EU868 region config, MQTT integration, API on `:8080`. NodePort `:30080` for UI access. Secret injected via `CHIRPSTACK__API__SECRET` env var.],
  [`linkerd-policy.yaml`], [Linkerd `Server` + `MeshTLSAuthentication` + `AuthorizationPolicy` resources for ChirpStack API, PostgreSQL, and Redis.],
)

== Modified Files

- `infrastructure/manifests/mqtt/linkerd-policy.yaml` — corrected the trust domain suffix in all identity strings (see §4.3).

== Ansible Playbook

`infrastructure/playbooks/04-install-chirpstack.yaml` — originally written to SSH into the control plane and run `microk8s kubectl`. Abandoned: `kubectl` is configured locally and manifests are applied directly.

= Key Design Decisions

== Secret Management

The ChirpStack API secret is stored in a `.env` file at the project root:
```
CHIRPSTACK_API_SECRET=<random-string>
```

The Ansible playbook extracts it with `lookup("file", ...)` and creates a Kubernetes Secret at deploy time:
```bash
kubectl create secret generic chirpstack-secret \
  --from-literal=api-secret='<value>' \
  --namespace=iot-system \
  --dry-run=client -o yaml | kubectl apply -f -
```

The Secret is referenced in the Deployment as `CHIRPSTACK__API__SECRET` (Linkerd's double-underscore TOML override format), which overrides `[api].secret` in `chirpstack.toml`.

== Opaque Ports

The `iot-system` namespace sets `config.linkerd.io/opaque-ports: "1883"`. Ports 5432 and 6379 are in Linkerd's *global* opaque list, so they remain opaque for all pods regardless of the namespace override.

== Proxy Readiness

ChirpStack (a compiled Rust binary) starts in milliseconds and immediately opens database connections. With Linkerd's `linkerd-init` already in place, outbound traffic is redirected to the proxy port before the proxy reports ready — causing the first connection to fail. Fixed with:
```yaml
annotations:
  config.linkerd.io/proxy-await: "enabled"
```

= Problems & Solutions

== Problem 1 — Wrong ChirpStack Startup Arguments

*Symptom:* Pod crashes immediately with `Error: Not a directory (os error 20)`.

*Cause:* The manifest passed the full file path to `-c`:
```yaml
args: ["-c", "/etc/chirpstack/chirpstack.toml"]
```
ChirpStack v4 expects `-c` to point to a *directory*, not a file. It reads all `*.toml` files inside it.

*Fix:*
```yaml
args: ["-c", "/etc/chirpstack"]
```

== Problem 2 — Namespace Deny-by-Default Policy

*Symptom:* Every pod-to-pod connection was silently dropped (immediate `connection closed`). No errors appeared in the target application logs — only in the Linkerd proxy logs.

*Cause:* The `iot-system` namespace was created with:
```yaml
annotations:
  config.linkerd.io/default-inbound-policy: deny
```
This means *every port on every pod* requires an explicit `Server` + `AuthorizationPolicy` pair. Without one, Linkerd closes the connection immediately at the proxy level — before the application ever sees it.

*Fix:* Add a `Server` resource for each port that needs to be reachable, plus an `AuthorizationPolicy` granting access.

*Diagnostic command:*
```bash
kubectl logs -n iot-system <pod> -c linkerd-proxy | grep "Connection denied"
```

== Problem 3 — Proxy Startup Race Condition

*Symptom:* ChirpStack crashed on the very first postgres connection with `connection closed`, even with correct policies in place. The postgres proxy logs showed the denial.

*Cause:* Both the application container and the `linkerd-proxy` sidecar start simultaneously. ChirpStack initialises its connection pool and attempts a migration in under 1 ms. The Linkerd proxy hasn't finished its mTLS handshake with the control plane yet, so the outbound connection is not wrapped in mTLS — and the postgres `Server` policy denies it.

*Fix:*
```yaml
annotations:
  config.linkerd.io/proxy-await: "enabled"
```
This makes the Linkerd proxy delay the application container's traffic until the proxy is fully initialised. (Supported in Linkerd edge-26.5.5 with native sidecars enabled.)

== Problem 4 — Wrong Identity Trust Domain

*Symptom:* After all policies were in place, MQTT connections from ChirpStack to Mosquitto were still denied. The mosquitto proxy log showed:
```
Connection denied ... client_id: chirpstack-gateway-bridge
  .iot-system.serviceaccount.identity.linkerd.cluster.local
```

*Cause:* The Linkerd config shows `identityTrustDomain: cluster.local`, which looks like the identity suffix should be `cluster.local`. In practice, Linkerd composes the full identity as:

```
<serviceaccount>.<namespace>.serviceaccount.identity.linkerd.<trustdomain>
```

So with `trustDomain = cluster.local`, the correct suffix is `linkerd.cluster.local`, *not* `cluster.local`.

The existing mosquitto policy had the right format from day one. During debugging this was mistakenly "corrected" to `cluster.local`, which broke all policies and had to be reverted.

*Correct identity format:*
```
chirpstack.iot-system.serviceaccount.identity.linkerd.cluster.local
```

*Diagnostic command:*
```bash
kubectl logs -n iot-system <pod> -c linkerd-proxy | grep "client_id"
```
This shows the *actual* identity the peer presents — use it verbatim in `MeshTLSAuthentication`.

= Final Architecture

```
[UG63-868M Gateway]
       |  UDP :31700 (NodePort, bypasses Linkerd)
       v
[chirpstack-gateway-bridge]  (iot-system, meshed)
       |  MQTT tcp://mosquitto:1883  (mTLS via Linkerd)
       v
[mosquitto]  (iot-system, meshed, opaque port 1883)
       |
       +---> subscribed by [chirpstack]  (mTLS)
       |
[chirpstack]  (iot-system, meshed)
       |  postgres://chirpstack@postgres:5432  (mTLS)
       |  redis://redis:6379               (mTLS)
       v
[postgres]  StatefulSet, 5 Gi PVC
[redis]     Deployment, ephemeral
```

= Access Points

#table(
  columns: (auto, auto, auto),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Service*], [*Address*], [*Notes*],
  [ChirpStack UI], [`http://10.29.16.101:30080`], [Default: `admin` / `admin`],
  [Gateway Bridge UDP], [`10.29.16.101:31700`], [Point UG63 Packet Forwarder here],
  [ChirpStack API (internal)], [`chirpstack.iot-system:8080`], [gRPC + HTTP, mTLS only],
)

= Next Steps

+ *Change the default password* in the ChirpStack UI immediately after first login.
+ *Register the UG63 gateway* in ChirpStack UI → Gateways → Add Gateway (use the gateway EUI from the device label).
+ *Register the IoT device* → Applications → Add Application → Add Device. Write the payload codec (JavaScript) for your specific device.
+ *Deploy Node-RED* in `iot-system`, subscribe to MQTT topic `application/+/device/+/event/up`.
+ *Deploy InfluxDB or PostgreSQL* for time-series storage, wire Node-RED to write into it.
+ *Deploy Grafana* pointed at the database for dashboards.
