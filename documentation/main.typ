#set document(title: "IoT in a Service Mesh — Project Documentation", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm), numbering: "1")
#set text(font: "New Computer Modern", size: 11pt)
#set par(justify: true)
#set heading(numbering: "1.")
#show link: underline
#show heading.where(level: 1): it => { v(0.3cm); it; v(0.15cm) }

// helpers
#let note(body) = block(fill: luma(240), inset: 9pt, radius: 3pt, width: 100%, body)
#let head-fill = (_, row) => if row == 0 { luma(220) } else { white }

// A real figure backed by a file in documentation/images/.
#let figpic(path, cap) = figure(image(path, width: 100%), caption: cap)

// Placeholder, for figures whose screenshot has not been captured yet.
// Once the file exists, swap `figplace` for `figpic`.
#let figplace(path, cap, h: 5.5cm) = figure(
  rect(width: 100%, height: h, stroke: (paint: gray, dash: "dashed"), fill: luma(247))[
    #align(center + horizon)[
      #text(fill: gray, size: 10pt)[Screenshot placeholder \ add #raw(path)]
    ]
  ],
  caption: cap,
)

#align(center)[
  #v(2cm)
  #text(size: 24pt, weight: "bold")[IoT in a Service Mesh]
  #v(0.3cm)
  #text(size: 13pt, fill: gray)[A LoRaWAN sensor platform running on MicroK8s,
  secured end-to-end with Linkerd and delivered through GitOps]
  #v(1cm)
  #text(size: 11pt)[Oleksandr Nychyporchuk]
  #v(0.1cm)
  #text(size: 10pt, fill: gray)[Project documentation]
]

#v(1cm)
#line(length: 100%)
#v(0.3cm)

#outline(depth: 2, indent: auto)
#pagebreak()

= Introduction

This project is a LoRaWAN data pipeline running on a Kubernetes cluster. Physical Milesight
sensors send readings over radio to a gateway, which forwards them into the cluster, where
the frames are decoded, stored in PostgreSQL and shown on a web dashboard.

Everything in the cluster runs inside a zero-trust service mesh built with *Linkerd*: pods
communicate only where an explicit policy allows it, and that traffic is automatically
mutually authenticated and encrypted with mTLS. The platform is declarative end to end,
described in this Git repository and reconciled by *ArgoCD*, so it can be rebuilt from
scratch with a single command.

This document covers the architecture, hardware, virtual machines, technology stack, the
design decisions behind our manifests, the automation, and a set of proofs that the
security model works.

= Architecture

== End-to-end data flow

A reading travels through the system like this:

```
 Milesight sensors (WS101 / WS202 / WS302)
        |  LoRa radio (EU868)
        v
 Milesight UG63 gateway
        |  Semtech UDP packet-forwarder  ->  NodePort 31700/UDP
        v
 chirpstack-gateway-bridge --MQTT--> mosquitto --MQTT--> chirpstack
        ^                                                    |
        |                       decrypts + dedups the frame, |
        |                       runs the JS payload codec     v
        |                            decoded uplink published on MQTT
        |                                                    |
        |                                                    v
        +------------------------------------------> Node-RED  (subscribes)
                                                            | INSERT
                                                            v
                                                     PostgreSQL (device_uplinks)
                                                            ^
                                                            | SELECT
                                          iot-stat-reader (FastAPI)
                                                            ^
                                                            | /api (nginx reverse proxy)
                                          iot-stat-frontend (React dashboard)
```

Every arrow in that diagram that crosses a pod boundary inside the cluster is wrapped in
mutual TLS by the Linkerd sidecar, and is only allowed because an authorization policy
names the specific client identity. The application code is unaware any of this is
happening.

== Logical view

The platform splits into four layers. The *platform layer* is the MicroK8s cluster itself.
The *mesh layer* is Linkerd plus its Viz observability extension. The *delivery layer* is
ArgoCD. The *application layer* is the LoRaWAN stack (ChirpStack, its gateway bridge,
Mosquitto, PostgreSQL, Redis) together with our own glue and presentation services
(Node-RED, iot-stat-reader, iot-stat-frontend). All application workloads live in one
namespace, `iot-system`; ArgoCD runs in `argocd` and Linkerd in `linkerd` / `linkerd-viz`.

#figure(image("images/architecture.png", height: 13cm),
  caption: [Component and traffic overview. Sensors and the gateway feed the LoRaWAN
  stack; every link inside the `iot-system` namespace is mTLS-secured by Linkerd.])

= Hardware

== IoT devices

We use three Milesight LoRaWAN sensors, all joining the network with OTAA and all running on
the EU868 band. They are deliberately different so the dashboard has both numeric and
categorical data to show. Each sensor has its own JavaScript payload codec, registered in
ChirpStack through its device profile, which turns the raw binary uplink into named fields.

#table(
  columns: (auto, auto, 1fr, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Device*], [*Model*], [*What it reports*], [*Uplink*],
  [Button-1], [Milesight WS101], [Button press events (single / double / long press), plus battery and device status], [on press],
  [PIR&Light Sensor], [Milesight WS202], [Motion (PIR) and daylight state, plus battery], [~5 min],
  [Sound Level Sensor], [Milesight WS302], [Sound level (LAeq), plus battery and device status], [~1 min],
)

The full device registration, including the DevEUI / JoinEUI of each unit and its profile,
is kept in `infrastructure/chirpstack/devices.yaml`:

#table(
  columns: (auto, auto, auto, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Name*], [*DevEUI*], [*Profile*], [*Codec*],
  [Button-1], [`24e124535c271986`], [WS101 Button], [`ws101-decoder.js`],
  [PIR&Light Sensor], [`24e124538c421853`], [WS202 PIR Light], [`ws202-decoder.js`],
  [Sound Level Sensor], [`24e124743d186530`], [WS302 Sound Level], [`ws302-decoder.js`],
)

The per-device OTAA application keys (`APPKEY_<DEVEUI>`) are not stored in the repository.
They live in a gitignored `.env` file and are handed to the provisioning script at runtime.

#figpic("images/chirpstack_device_profiles.png",
  [The three device profiles in the ChirpStack console, each bound to its JavaScript
  payload codec.])

== LoRaWAN gateway

The radio side terminates on a *Milesight UG63* (UG63-868M) gateway, registered in
ChirpStack with gateway ID `24e124fffef8026e`. It runs the standard Semtech UDP
packet-forwarder and points it at the cluster. We set its statistics interval to 30 seconds
in the gateway configuration; ChirpStack uses that interval to decide whether the gateway is
online, and if it is left at the default the gateway shows as offline even while frames keep
arriving.

The gateway reaches the cluster through a single UDP NodePort (31700), which is the only
inbound entry point for radio traffic.

= Infrastructure

== Virtual machines

The cluster runs on four VMs on the `10.29.16.0/24` network. Three of them form the MicroK8s
cluster; the fourth is a separate load generator we use for testing and keep off the cluster
on purpose.

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Host*], [*Address*], [*Role*],
  [`cp`], [`10.29.16.101`], [Control plane; also schedules workloads],
  [`worker1`], [`10.29.16.102`], [Worker node],
  [`worker2`], [`10.29.16.103`], [Worker node],
  [`load-gen`], [`10.29.16.104`], [k6 load generator, not part of the cluster],
)

== The Kubernetes cluster

We chose *MicroK8s* (Canonical's snap-packaged Kubernetes) because it is light enough to run
comfortably on these VMs and because joining extra nodes is a single command. The control
plane also runs workloads, so all three cluster nodes are schedulable.

On top of the base install we enable three add-ons: `dns` (CoreDNS), `hostpath-storage`
(which backs the PersistentVolumeClaims for PostgreSQL and Node-RED) and the `community`
repository. We also install the Kubernetes *Gateway API* CRDs at cluster level, because
Linkerd's policy stack depends on them being present.

= Technology stack

#table(
  columns: (auto, 1fr, auto),
  stroke: 0.5pt,
  fill: head-fill,
  [*Component*], [*Role in the project*], [*Layer*],
  [MicroK8s], [Lightweight Kubernetes cluster (1 control plane + 2 workers)], [Platform],
  [Linkerd], [Service mesh: mTLS, workload identity, zero-trust authorization], [Mesh],
  [Linkerd Viz], [Observability: Prometheus, Tap, dashboard], [Mesh],
  [ArgoCD], [GitOps delivery; reconciles every application from Git], [Delivery],
  [ChirpStack v4], [LoRaWAN Network + Application Server], [Application],
  [ChirpStack Gateway Bridge], [Semtech UDP packet-forwarder to MQTT], [Application],
  [Eclipse Mosquitto], [MQTT broker between gateway-bridge and ChirpStack], [Application],
  [PostgreSQL / Redis], [ChirpStack storage and device-session cache], [Data],
  [Node-RED], [Flow engine: MQTT to PostgreSQL], [Application],
  [iot-stat-reader], [FastAPI service exposing the stored uplinks], [Application],
  [iot-stat-frontend], [React + Tailwind dashboard (Vite build, nginx serve)], [Application],
  [Ansible + Make], [Provisioning, deployment, teardown, device bootstrap], [Automation],
)

= Design decisions

This section reads our decisions back out of the manifests, rather than describing the tools
in the abstract. Each one is something we could change in YAML and see the effect of.

== One meshed, deny-by-default namespace

Everything application-related lives in `iot-system`, and the namespace itself carries the
security posture as annotations (`manifests/bootstrap/iot-system-namespace.yaml`):

```yaml
metadata:
  name: iot-system
  annotations:
    linkerd.io/inject: enabled                       # mesh every pod here
    config.linkerd.io/default-inbound-policy: deny   # zero-trust default
    config.linkerd.io/opaque-ports: "1883"           # MQTT is raw TCP
```

Setting these once on the namespace means we never repeat them per workload. `inject:
enabled` makes Linkerd add its sidecar to every new pod automatically, which is why each
application pod runs as `2/2`. `default-inbound-policy: deny` is the important one: with it,
any inbound connection to any pod is refused unless an `AuthorizationPolicy` explicitly
allows it. Nothing is reachable by accident.

== Authorization as explicit allow-lists

Because the default is deny, access has to be granted on purpose. We do that with four kinds
of Linkerd resources working together. A `Server` marks a port on a set of pods as a
protected target. An `AuthorizationPolicy` binds that `Server` to one or more
authentications. A `MeshTLSAuthentication` identifies callers by their mesh identity (their
Kubernetes ServiceAccount), and a `NetworkAuthentication` identifies them by source network.
In total the manifests define *9 `Server`s, 13 `AuthorizationPolicy`s, 5
`MeshTLSAuthentication`s and 4 `NetworkAuthentication`s*. The resulting access matrix is:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Server (port)*], [*Proto*], [*Who may connect, and how*],
  [`postgres-server` (5432)], [opaque], [mTLS identities: `chirpstack`, `iot-stat-reader`, `nodered`],
  [`redis-server` (6379)], [opaque], [mTLS identity: `chirpstack`],
  [`mosquitto-mqtt` (1883)], [opaque], [mTLS identities: `mqtt-client`, `chirpstack`, `gateway-bridge`, `node-red`],
  [`chirpstack-api` (8080)], [opaque], [mTLS `chirpstack` (internal) and network `0.0.0.0/0` (UI/gRPC)],
  [`iot-stat-reader-http` (8000)], [HTTP/1], [network `0.0.0.0/0` (external API)],
  [`iot-stat-frontend-http` (80)], [HTTP/1], [network `0.0.0.0/0` (external UI)],
  [`nodered-ui` (1880)], [HTTP/1], [network `0.0.0.0/0` (external editor)],
  [`proxy-admin` (4191)], [HTTP/1], [mTLS identities: `prometheus`, `tap`],
  [`proxy-tap` (4190)], [HTTP/2], [mTLS identity: `tap`],
)

#note[
  *Defense in depth.* A service can be reached from outside the cluster only if it has both a
  NodePort (the network path) and an authorization policy that admits the source network. The
  data stores (PostgreSQL, Redis, Mosquitto) have neither a NodePort nor a `0.0.0.0/0` rule.
  They are restricted to specific mesh identities, so even a compromised pod inside the
  cluster cannot reach them unless it holds an authorized identity.
]

== Opaque ports for non-HTTP traffic

By default Linkerd assumes a port speaks HTTP and tries to parse it at layer 7. That is wrong
for binary protocols, so we mark those ports *opaque*. They are still encrypted with mTLS and
still subject to authorization; Linkerd just treats them as raw TCP.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Port*], [*Why we made it opaque*],
  [`1883` (Mosquitto)], [MQTT is a binary TCP protocol. Set namespace-wide via `opaque-ports`.],
  [`5432` / `6379`], [The PostgreSQL and Redis wire protocols are binary.],
  [`8080` (chirpstack-api)], [It serves both browser grpc-web (HTTP/1) and native gRPC (HTTP/2). One L7 setting cannot carry both, so opaque lets both through. We needed native gRPC for the device-bootstrap script.],
)

== Keeping credentials out of Git

No password or key is committed. Two Kubernetes Secrets (`chirpstack-secret` and
`postgres-credentials`) are created by the setup playbook from the gitignored `.env`, before
ArgoCD deploys the workloads that mount them. If we let ArgoCD bring ChirpStack up first, its
pod would get stuck in `CreateContainerConfigError` for a missing secret, so the ordering is
deliberate. Device OTAA keys live only in `.env` as well.

== Self-seeding, reproducible workloads

A few workloads do small setup steps themselves so a fresh cluster needs no manual touch-up:

- *PostgreSQL* runs an `init.sql` ConfigMap on first boot that creates our `device_uplinks`
  table and a `new_uplink` notify trigger, alongside ChirpStack's own schema.
- *Node-RED* has a seed init container that copies the committed `flows.json` into a fresh
  `/data` volume and installs the PostgreSQL palette node, guarded so it never overwrites
  existing data. The database password reaches the flow as an environment variable from the
  `postgres-credentials` Secret, so no credential is stored in the flow itself.
- *iot-stat-frontend* is served by nginx, which also reverse-proxies `/api` to the in-cluster
  `iot-stat-reader`. The browser only ever talks to the frontend origin, so there is no CORS
  setup and no backend URL baked into the build. The upstream is resolved lazily through
  cluster DNS so the pod does not crash-loop if the backend is briefly missing.

#figpic("images/nodered-gui.png",
  [The Node-RED flow: subscribe to ChirpStack's decoded uplinks over MQTT, reshape each
  message, and insert it into the `device_uplinks` table.])

== Exposed surface

Only five things are reachable from outside the cluster, and they are exactly the ones we
intend to expose:

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

== GitOps with conservative sync

Each workload directory under `infrastructure/manifests/` is one ArgoCD `Application`, all
pointing at this repository. The sync policy is `automated` but with `prune: false` and
`selfHeal: false`: ArgoCD applies new commits, but it never deletes resources that were
removed from Git and never reverts manual changes on the cluster. For a teaching project that
we poke at by hand, that is safer than full self-healing. The `Application` registrations, the
namespace and the Viz policy are applied once by the setup playbook, because they must exist
before ArgoCD can sync anything into the namespace.

#figpic("images/argocd_applications.png",
  [ArgoCD: all five applications reconciled to Synced / Healthy.])

= Automation

The whole platform is driven from a root `Makefile`. Provisioning the nodes is the only step
that touches the machines over SSH; everything else runs locally against the cluster API
using our own `kubectl` and `linkerd`.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: head-fill,
  [*Target*], [*What it does*],
  [`make setup_mk8s`], [Provision MicroK8s on the VMs over SSH: install snap, enable add-ons, join workers, set up the load generator, install the Gateway API CRDs.],
  [`make set_all_up`], [Local: install Linkerd, then Viz, create the namespace and Viz policy, create the secrets from `.env`, install ArgoCD, register and sync all five apps.],
  [`make setup_everything`], [`setup_mk8s` then `set_all_up` then `bootstrap_chirpstack`: the full platform in one command.],
  [`make bootstrap_chirpstack`], [Provision the ChirpStack tenant, application, device profiles with codecs, gateway and devices. Idempotent; `DRY_RUN=true` previews.],
  [`make teardown`], [Remove all services, ArgoCD, Linkerd Viz and Linkerd. The VMs themselves are left alone.],
  [`make nodered_export`], [Snapshot the live Node-RED flows back into Git, with the password sanitized.],
  [`make status`], [ArgoCD apps, `iot-system` pods and mesh edges at a glance.],
)

== Provisioning the cluster (`setup-microk8s.yaml`)

This playbook is the one that runs over SSH, against the `microk8s_cluster` inventory group.
It installs snapd and MicroK8s on every node, adds the user to the `microk8s` group, and waits
for the node to report ready. On the control plane it enables the `dns`, `hostpath-storage`
and `community` add-ons. Worker nodes are joined one at a time (`serial: 1`) because joining
them in parallel can trigger dqlite race conditions; the control plane mints a fresh join
token for each. The load generator gets k6 installed from its official apt repository.
Finally the playbook exports the MicroK8s kubeconfig and installs the Gateway API CRDs that
Linkerd needs.

== Bringing up the mesh and apps (`setup-all.yml`)

This playbook runs locally (`connection: local`). It starts with preflight checks that
`kubectl` can reach the cluster and the `linkerd` CLI is present. Linkerd is not idempotent
about reinstalling, so the playbook first checks for the `linkerd-config` ConfigMap and only
installs the CRDs and control plane if it is absent; either way it runs `linkerd check` as a
gate before moving on. The same pattern installs Linkerd Viz. It then applies the namespace
and the Viz authorization policy, creates the two secrets from `.env` (failing early with a
clear message if `.env` is missing), and installs ArgoCD with a server-side apply (the
ApplicationSet CRD is too large for the client-side annotation that a plain apply would use).
After ArgoCD's core components are ready it registers the five `Application`s, triggers an
immediate sync for each instead of waiting for the poll, and finally blocks until every
application reports `Synced/Healthy`.

== Provisioning devices (`bootstrap-chirpstack.yml`)

ChirpStack itself is configured by `infrastructure/chirpstack/bootstrap.py`, a declarative and
idempotent provisioner. It reads `devices.yaml` (tenant, application, device profiles with
their JS codecs, gateway and devices) and the OTAA keys from the environment, then reconciles
ChirpStack over native gRPC. It logs in as admin to get its own API token, so we never have to
pre-create a key. This is the reason the `chirpstack-api` port is opaque in the mesh, since the
script speaks native gRPC. The playbook builds a virtualenv for the script, retries the
bootstrap a few times (ChirpStack has no readiness probe, so the API may not be up immediately
after `set_all_up`), and can run in dry-run mode.

#figpic("images/chirpstack_dashboard.png",
  [The ChirpStack tenant dashboard after bootstrap: the gateway shows online and the
  devices and data-rate usage are tracked.])

== Teardown (`teardown.yml`)

Teardown reverses the setup and tolerates anything already being gone
(`--ignore-not-found`, `failed_when: false`), so it is safe to run repeatedly. It removes the
ArgoCD applications, deletes the whole `iot-system` namespace (taking all workloads, services,
policies and secrets with it), uninstalls Viz and the Linkerd control plane, and deletes the
`argocd` namespace. The cluster nodes are untouched, so `make set_all_up` rebuilds everything
from Git and `.env` afterwards.

#note[
  *One physical caveat on rebuild.* Tearing down ChirpStack wipes its device-session store.
  Real OTAA sensors still hold their old session and keep sending data frames, which the fresh
  server rejects until the devices re-join (on a power-cycle or after their rejoin threshold).
  That is a property of LoRaWAN, not of our automation.
]

= Verification and proofs

This is the part that backs up the security claims. The goal is to show three things: that
traffic between pods is genuinely encrypted on the wire, that the deny-by-default policy
actually rejects callers we did not authorize, and that Linkerd itself reports both the
encryption and the authorization on real requests. The exact commands behind each proof are
in `CHEATSHEET.md`.

== Proof A: traffic is encrypted on the wire

Inside a meshed pod there are two network hops. The application talks to its own Linkerd proxy
over loopback (`lo`), in cleartext, on the application's own port. The proxy then talks to the
remote pod's proxy over the real network interface (`eth0`), and that hop is TLS, arriving at
the proxy's inbound port 4143. So if we capture both interfaces inside the destination pod and
search for a known marker string, it should appear on `lo` and never on `eth0`.

We publish an MQTT message carrying the marker `SECRET-PAYLOAD-12345` from an authorized
client, then capture inside the `mosquitto` pod:

```bash
# (1) loopback: app <-> proxy. The marker is readable.
tcpdump -l -n -i lo   -A 'tcp port 1883' | grep SECRET-PAYLOAD     # prints the message
# (2) on the wire: proxy <-> remote proxy. Encrypted, marker never appears.
tcpdump -l -n -i eth0 -A 'tcp port 4143' | grep SECRET-PAYLOAD     # stays silent
```

The first command prints the payload; the second prints nothing. The same capture opened in
Wireshark shows the on-the-wire side as `TLSv1.3` `Application Data`, and the handshake carries
both a client and a server certificate, which is the "mutual" in mutual TLS.

#figpic("images/tcpdump_app_to_proxy.png",
  [Loopback (`lo`) capture inside the mosquitto pod: the marker `SECRET-PAYLOAD-12345`
  is plainly readable on the app-to-proxy hop.])

#figpic("images/tcpdump_proxy_to_remoteproxy.png",
  [The same traffic on the network interface (`eth0`, port 4143): 420 packets are
  captured, but the `grep` for the marker matches nothing. The payload is encrypted.])

#figpic("images/TLS_mqtt_mosquitto.png",
  [The on-the-wire capture opened in Wireshark: the stream is `TLSv1.3` Application
  Data, with no readable MQTT content.])

== Proof B: the policy discards unauthorized callers

`mosquitto`'s authorization policy only admits four identities. To show that anything else is
rejected, we run a pod on the `default` ServiceAccount, which is meshed (so it has a valid mesh
identity) but is not on the allow-list, and have it try to publish:

```
$ kubectl exec -n iot-system rogue -c rogue -- \
    mosquitto_pub -h mosquitto -t demo/secret -m SHOULD-BE-BLOCKED
Error: The connection was lost
command terminated with exit code 7
```

The connection is reset before any MQTT frame is exchanged. The destination proxy logs exactly
why:

```
INFO inbound:server{port=4143}: linkerd_app_inbound::policy::tcp: Connection denied
     server.name=mosquitto-mqtt
     tls=Some(Established { client_id: ...Name("default.iot-system.serviceaccount...") })
```

The detail that matters here: `tls=Established` means mTLS *succeeded* and the caller was
positively identified as the `default` service account. The connection was still denied,
because identity and authorization are separate layers. A valid mesh identity is not enough;
the policy has to name it. The proxy's metrics confirm the split, with the deny counter
incrementing for the unauthorized identity while the allow counter climbs for the legitimate
clients:

```
inbound_tcp_authz_allow_total{... client_id="mqtt-client.iot-system..."}  2339
inbound_tcp_authz_deny_total {... client_id="default.iot-system..."}         1
```

#figpic("images/unauthorized_client_rogue.png",
  [The unauthorized `rogue` pod (running on the `default` ServiceAccount) tries to
  publish and fails with `Error: The connection was lost`, exit code 7.])

#figpic("images/denial_log_proof_b.png",
  [The destination proxy log: the connection is denied for the `mosquitto-mqtt` server
  even though `tls=Established` identified the caller as the `default` service account.])

#figpic("images/deny_counter_proof_b.png",
  [The proxy's authorization counters: the deny counter increments for the unauthorized
  identity while the allow counters climb for the four legitimate clients.])

#note[
  Because MQTT runs on an opaque (raw TCP) port, denial happens at the connection level: the
  proxy resets the TCP connection during the authorization check, before a single MQTT frame is
  sent. There is no "rejected frame" to look at, there is a refused connection. For an HTTP
  service the same denial would instead be a per-request `403`.
]

== Proof C: Linkerd's own attestation

The first two proofs look at the wire and at the policy. The third uses Linkerd's own view to
confirm that the everyday, authorized traffic is both encrypted and correctly authorized.

`linkerd viz edges` lists every connection in the namespace and whether it is secured. Every
edge shows the secured mark:

```
SRC                        DST         ...  SECURED
nodered                    mosquitto   ...  √
chirpstack                 redis       ...  √
chirpstack-gateway-bridge  mosquitto   ...  √
...                                         (every edge √)
```

`linkerd viz tap` goes down to individual requests. On a real request from the frontend to the
reader, Linkerd reports that the request rode mTLS, names the verified client identity, and
names the policy that authorized it:

```
req ... tls=true :method=GET :path=/
    src_client_id=iot-stat-frontend.iot-system.serviceaccount.identity.linkerd.cluster.local
    dst_authz_name=allow-external-to-iot-stat-reader
```

For contrast, traffic that comes from outside the mesh (for example the kubelet's health probe,
which originates on the node) is tapped as `tls=no_tls_from_remote`, which makes the meshed and
non-meshed paths easy to tell apart.

#figpic("images/linkerd_mtls_meshed_edge.png",
  [`linkerd viz edges`: every pod-to-pod edge in `iot-system` is reported as secured.])

#figpic("images/tls_is_true__verified_client_identity__authorizing_policy.png",
  [`linkerd viz tap`: a single request showing `tls=true`, the verified client identity
  and the authorizing policy.])

#figpic("images/linkerd-viz-gui.png",
  [The Linkerd Viz dashboard for the `iot-system` namespace: every workload is meshed
  (1/1) with a 100% success rate.])

== Proof D: the pipeline actually carries data

Finally, the security would be pointless if no data flowed. Real uplinks land in the
`device_uplinks` table, which we can count directly:

```bash
kubectl exec -n iot-system postgres-0 -c postgres -- \
  psql -U chirpstack -d chirpstack -c "SELECT count(*) FROM device_uplinks;"
```

and the dashboard renders them as per-device time series and a recent-uplinks table.

#figpic("images/iot-stats-frontend.png",
  [The iot-stat-frontend dashboard (Plots): per-device time series for the three sensors,
  including categorical fields such as button press and daylight state.])

#figpic("images/iot-stats-frontend-uplinks.png",
  [The Uplinks view: the most recent decoded uplinks as stored in `device_uplinks`.])

= Operations quick reference

```bash
# health
kubectl get applications -n argocd
kubectl get pods -n iot-system
linkerd viz edges deployment -n iot-system          # mTLS at a glance

# exposed surface (should be only the five intended NodePorts)
kubectl get svc -n iot-system | grep -E 'NodePort'

# the authorization model
kubectl get server,authorizationpolicy -n iot-system
kubectl get meshtlsauthentication,networkauthentication -n iot-system

# data pipeline
kubectl exec -n iot-system postgres-0 -c postgres -- \
  psql -U chirpstack -d chirpstack -c "SELECT count(*) FROM device_uplinks;"
```

#v(0.5cm)
#line(length: 100%)
#align(center)[#text(size: 9pt, fill: gray)[End of document]]
