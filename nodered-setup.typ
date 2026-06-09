#set document(title: "Node-RED Deployment in IoT Service Mesh", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm))
#set text(font: "New Computer Modern", size: 11pt)
#set heading(numbering: "1.")
#show link: underline

#align(center)[
  #text(size: 20pt, weight: "bold")[Node-RED Deployment in IoT Service Mesh]
  #v(0.3cm)
  #text(size: 12pt, fill: gray)[MicroK8s + Linkerd · iot-system namespace · MQTT → Postgres pipeline]
  #v(0.2cm)
  #text(size: 10pt, fill: gray)[2026-06-09]
]

#v(0.5cm)
#line(length: 100%)
#v(0.5cm)

= Overview

This document covers the deployment of Node-RED into the `iot-system` namespace of the existing MicroK8s + Linkerd cluster. Node-RED serves as the data processing layer between the MQTT broker (Mosquitto) and the storage layer (PostgreSQL), subscribing to ChirpStack uplink events and transforming LoRaWAN device payloads into structured database records.

The namespace enforces strict mTLS with a *deny-by-default* inbound policy inherited from the ChirpStack setup. The Node-RED service account identity had to match an entry already anticipated in the MQTT Linkerd policy.

= Files Created

== Kubernetes Manifests

All manifests live under `infrastructure/manifests/nodered/`.

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*File*], [*Purpose*],
  [`pvc.yaml`], [PersistentVolumeClaim — 5 Gi on `microk8s-hostpath`. Stores Node-RED flows, context, and installed nodes across pod restarts.],
  [`nodered.yaml`], [ServiceAccount `node-red`, ConfigMap with `settings.js`, Deployment (1 replica), ClusterIP Service `nodered:1880` for internal traffic, NodePort Service `nodered-ui:31880` for external UI access.],
  [`linkerd-policy.yaml`], [Linkerd `Server` for port 1880, `MeshTLSAuthentication` for the `node-red` service account identity, `AuthorizationPolicy` granting Node-RED access to PostgreSQL, and `AuthorizationPolicy` granting external clients access to the UI.],
)

== Ansible Playbook

`infrastructure/playbooks/05-install-nodered.yaml` — copies manifests to the control plane and applies them in order: PVC → Deployment → Linkerd policies. Waits for rollout before applying policies.

= Key Design Decisions

== ServiceAccount Name

The MQTT Linkerd policy (`infrastructure/manifests/mqtt/linkerd-policy.yaml`) already contained a pre-registered identity for Node-RED:
```
node-red.iot-system.serviceaccount.identity.linkerd.cluster.local
```

The ServiceAccount *must* be named `node-red` (not `nodered`) for the mTLS identity to match. The existing `allow-iot-system-to-mosquitto` `AuthorizationPolicy` covers Mosquitto access automatically — no additional policy entry is needed.

== Persistent Storage

Node-RED stores flows as JSON files in `/data`. A 5 Gi PVC on `microk8s-hostpath` is sufficient for a university demo — flows, installed npm packages, and context data combined are unlikely to exceed a few hundred megabytes. The PVC is a managed folder on the node filesystem, not a separate logical volume.

The PVC is mounted at `/data` and the `settings.js` ConfigMap is overlaid at `/data/settings.js` via `subPath` mount — Kubernetes handles both simultaneously without conflict.

== settings.js

Node-RED is configured with:
- UI on `0.0.0.0:1880` (all interfaces)
- No admin authentication (demo environment)
- `localfilesystem` context storage (persists flow variables across restarts)
- Projects feature disabled
- `functionGlobalContext` exposes the Node.js `os` module only — `jsonwebtoken` was intentionally excluded as it is not pre-installed in the Node-RED image and would crash the process on startup

== Two Services

Two separate Services expose Node-RED:
- `nodered` (ClusterIP) — for internal mesh-to-mesh communication
- `nodered-ui` (NodePort `:31880`) — for direct browser access from outside the cluster

= Problems & Solutions

== Problem 1 — Malformed PVC Spec

*Symptom:* `kubectl apply` rejected `pvc.yaml` with:
```
strict decoding error: unknown field "spec.resources.storage"
```

*Cause:* The initial draft placed `storage` directly under `resources` instead of under `resources.requests`:
```yaml
# Wrong
resources:
  storage: 5Gi

# Correct
resources:
  requests:
    storage: 5Gi
```

*Fix:* Added the `requests` level. Playbook re-run succeeded immediately.

== Problem 2 — Invalid settings.js References

*Cause:* The initial `settings.js` ConfigMap included:
```js
functionGlobalContext: {
  jwtDecode: require('jsonwebtoken').decode
}
```
`jsonwebtoken` is not bundled in `nodered/node-red:latest`. Node-RED evaluates `settings.js` at startup — a missing `require` causes an immediate fatal error before the HTTP server starts.

*Fix:* Removed `jwtDecode` from `functionGlobalContext`. Can be re-added after installing the package via the Node-RED palette manager or a custom image.

== Problem 3 — Redundant and Incorrect Mosquitto Policy

*Cause:* The initial `linkerd-policy.yaml` included an `AuthorizationPolicy` for Mosquitto access using `kind: Service` as the `targetRef`:
```yaml
targetRef:
  group: ""
  kind: Service
  name: mosquitto
```
Linkerd `AuthorizationPolicy` does not accept Kubernetes Service as a `targetRef` — it requires a Linkerd `Server` resource. Additionally, this policy was entirely redundant because `allow-iot-system-to-mosquitto` in the MQTT policy already covers the `node-red` identity.

*Fix:* Removed the entry entirely.

= Final Architecture

```
[UG63-868M Gateway]
       |  UDP :31700 (NodePort, bypasses Linkerd)
       v
[chirpstack-gateway-bridge]  (iot-system, meshed)
       |  MQTT tcp://mosquitto:1883  (mTLS)
       v
[mosquitto]  (iot-system, meshed, opaque port 1883)
       |
       +---> subscribed by [chirpstack]   (mTLS)
       |
       +---> subscribed by [node-red]     (mTLS)
              |
              |  Transform LoRaWAN uplink payload
              |
              v
           [postgres]  StatefulSet, 5 Gi PVC  (mTLS)

[chirpstack]  (iot-system, meshed)
       |  postgres://chirpstack@postgres:5432  (mTLS)
       |  redis://redis:6379                   (mTLS)
```

= Access Points

#table(
  columns: (auto, auto, auto),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Service*], [*Address*], [*Notes*],
  [Node-RED UI], [`http://10.29.16.101:31880`], [No authentication (demo)],
  [Node-RED (internal)], [`nodered.iot-system:1880`], [mTLS only, for mesh services],
  [ChirpStack UI], [`http://10.29.16.101:30080`], [`admin` / `admin`],
  [Gateway Bridge UDP], [`10.29.16.101:31700`], [UG63 Packet Forwarder target],
)

= Building the MQTT → PostgreSQL Flow

This section is a step-by-step guide for creating the uplink processing flow inside the Node-RED UI. The resulting flow subscribes to ChirpStack device uplink events on Mosquitto, transforms the JSON payload, and inserts a row into PostgreSQL.

Target canvas layout:
```
[mqtt in] → [Transform uplink] → [postgresql]
                    |
                    └──────────→ [debug]
```

== Step 1 — Install the PostgreSQL Palette Node

The default Node-RED image does not include a PostgreSQL output node.

+ Open `http://10.29.16.101:31880`
+ Click *☰ → Manage palette → Install* tab
+ Search for `node-red-contrib-postgresql` and click *Install*
+ Wait \~30 s for installation to complete, then close the palette manager

== Step 2 — Create the Database Table

Before wiring the database node, create the target table. Run from your local machine:

```bash
kubectl exec -n iot-system statefulset/postgres -- \
  psql -U chirpstack -d chirpstack -c "
    CREATE TABLE IF NOT EXISTS device_uplinks (
      id          BIGSERIAL PRIMARY KEY,
      device_eui  TEXT NOT NULL,
      device_name TEXT,
      received_at TIMESTAMPTZ NOT NULL,
      f_port      SMALLINT,
      payload     JSONB
    );
  "
```

== Step 3 — Add the MQTT-in Node

+ Drag *mqtt in* from the left panel onto the canvas
+ Double-click it → click the pencil icon next to *Server* to add a new broker:
  - *Host:* `mosquitto` · *Port:* `1883` · *Client ID:* `node-red`
  - Click *Add*
+ Back in the node config:
  - *Topic:* `application/+/device/+/event/up`
  - *QoS:* `0`
  - *Output:* `a parsed JSON object`
+ Click *Done*

The `+` wildcards match any application ID and any device EUI. ChirpStack publishes all device uplinks here because `topic_prefix = "application"` is set in `chirpstack.toml`.

== Step 4 — Add the Function Node

+ Drag *function* onto the canvas and connect it to the MQTT-in node
+ Double-click it, name it `Transform uplink`
+ Paste the following into the function body:

```js
const payload = msg.payload;

msg.params = [
    payload.deviceInfo?.devEui   ?? "unknown",
    payload.deviceInfo?.deviceName ?? "unknown",
    payload.time ?? new Date().toISOString(),
    payload.fPort ?? 0,
    JSON.stringify(payload.object ?? payload.data ?? {})
];

return msg;
```

+ Click *Done*

`payload.object` contains the decoded payload when a JavaScript codec is configured in ChirpStack. `payload.data` is the raw base64-encoded bytes when no codec is set. The function prefers the decoded form.

== Step 5 — Add the PostgreSQL Node

+ Drag *postgresql* onto the canvas and connect it to the Function node
+ Double-click it → click the pencil icon next to *Database* to add a new connection:
  - *Host:* `postgres` · *Port:* `5432`
  - *Database:* `chirpstack`
  - *Username:* `chirpstack` · *Password:* `chirpstack`
  - *SSL:* off
  - Click *Add*
+ Set the *Query* field to:

```sql
INSERT INTO device_uplinks (device_eui, device_name, received_at, f_port, payload)
VALUES ($1, $2, $3, $4, $5)
```

+ Set *Inputs* to `msg.params`
+ Click *Done*

== Step 6 — Add a Debug Node

+ Drag *debug* onto the canvas and connect it to the Function node output (in parallel with the PostgreSQL node)
+ Set *Output* to `complete msg object`
+ The *Debug* panel (bug icon, top right) will show every incoming uplink in real time — useful for verifying payload structure before writing a codec

== Step 7 — Deploy

Click the red *Deploy* button (top right). The MQTT-in node should show *connected* underneath it within a few seconds.

== Verifying the Flow

Before real devices are connected, the flow can be tested end-to-end by publishing a fake uplink directly into Mosquitto using `mosquitto_pub` from inside the broker pod:

```bash
kubectl exec -n iot-system deployment/mosquitto -- mosquitto_pub \
  -h localhost -p 1883 \
  -t "application/test-app/device/aabbccddeeff0011/event/up" \
  -m '{
    "deviceInfo": {
      "devEui": "aabbccddeeff0011",
      "deviceName": "test-sensor"
    },
    "time": "2026-06-09T18:00:00Z",
    "fPort": 1,
    "object": {"temperature": 22.5, "humidity": 60}
  }'
```

Then confirm the row landed in the database:

```bash
kubectl exec -n iot-system statefulset/postgres -- \
  psql -U chirpstack -d chirpstack -c \
  "SELECT device_eui, device_name, received_at, f_port, payload
   FROM device_uplinks
   ORDER BY received_at DESC
   LIMIT 5;"
```

Expected output:
```
    device_eui    | device_name |      received_at       | f_port |                payload
------------------+-------------+------------------------+--------+---------------------------------------
 aabbccddeeff0011 | test-sensor | 2026-06-09 18:00:00+00 |      1 | {"humidity": 60, "temperature": 22.5}
```

== Exporting and Versioning the Flow

Once the flow is working, export it to keep it in version control:

+ *☰ → Export → Download* — saves `flows.json` locally
+ Commit it to the repository under `infrastructure/manifests/nodered/flows.json`

This file can later be used to seed the PVC via an init container for fully reproducible deployments.

= Next Steps

+ *Register a LoRaWAN device* in ChirpStack UI and send a test uplink to verify the end-to-end pipeline.
+ *Write a payload codec* in ChirpStack (JavaScript) so `payload.object` contains structured fields instead of raw base64.
+ *Export and commit* `flows.json` after the flow is stable (see §6.8).
+ *Deploy Grafana* in `iot-system`, pointed at PostgreSQL, for dashboard visualisation.
