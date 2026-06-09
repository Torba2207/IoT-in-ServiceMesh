#set document(title: "Linkerd Viz — Observability Setup", author: "Oleksandr Nychyporchuk")
#set page(paper: "a4", margin: (x: 2.5cm, y: 2.5cm))
#set text(font: "New Computer Modern", size: 11pt)
#set heading(numbering: "1.")
#show link: underline

#align(center)[
  #text(size: 20pt, weight: "bold")[Linkerd Viz — Observability Setup]
  #v(0.3cm)
  #text(size: 12pt, fill: gray)[MicroK8s + Linkerd · iot-system namespace · Prometheus + Tap fix]
  #v(0.2cm)
  #text(size: 10pt, fill: gray)[2026-06-10]
]

#v(0.5cm)
#line(length: 100%)
#v(0.5cm)

= Overview

Linkerd Viz is the observability extension for Linkerd. It ships Prometheus, a metrics API, a Tap server, and a web dashboard. After deploying the `iot-system` workloads, the dashboard showed no metrics (`-` in every column) and Tap was non-functional.

The cause was the namespace-wide *deny-by-default* inbound policy blocking Prometheus from scraping the Linkerd proxy admin port and Tap from connecting to the proxy tap port.

= Problem — Prometheus and Tap Blocked by deny-by-default

== Symptom

Running `linkerd viz stat deploy -n iot-system` returned empty results for all deployments:

```
NAME                        MESHED   SUCCESS   RPS   LATENCY_P50   ...
chirpstack                     1/1         -     -             -
chirpstack-gateway-bridge      1/1         -     -             -
mosquitto                      1/1         -     -             -
nodered                        1/1         -     -             -
redis                          1/1         -     -             -
```

The Linkerd proxy logs on every pod flooded with denials every 10 seconds:

```
Request denied server.name=deny
  client_id: prometheus.linkerd-viz.serviceaccount.identity.linkerd.cluster.local
  client.ip: 10.1.235.130
```

== Root Cause

The `iot-system` namespace has:
```yaml
annotations:
  config.linkerd.io/default-inbound-policy: deny
```

This blocks *all* inbound connections to every port on every pod unless an explicit `Server` + `AuthorizationPolicy` pair exists. The Linkerd proxy exposes two internal ports that Viz needs:

#table(
  columns: (auto, auto, 1fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Port*], [*Name*], [*Purpose*],
  [`4191`], [Admin], [Prometheus scrapes metrics here every 10 s],
  [`4190`], [Tap], [Tap server streams live traffic frames from here],
)

Neither port had a `Server` resource defined, so both fell through to the default deny policy.

= Fix

== File Created

`infrastructure/manifests/observability/linkerd-viz-policy.yaml`

This file lives in the new `observability/` directory, which will also hold Grafana manifests later.

== Resources Applied

```yaml
# Expose proxy admin port on all pods in the namespace
Server/proxy-admin          port: 4191   proxyProtocol: HTTP/1
Server/proxy-tap            port: 4190   proxyProtocol: HTTP/2

# Trust both prometheus and tap service accounts from linkerd-viz
MeshTLSAuthentication/linkerd-viz-identity
  identities:
    - prometheus.linkerd-viz.serviceaccount.identity.linkerd.cluster.local
    - tap.linkerd-viz.serviceaccount.identity.linkerd.cluster.local

# Grant access
AuthorizationPolicy/allow-prometheus-scrape  →  proxy-admin  (via linkerd-viz-identity)
AuthorizationPolicy/allow-tap               →  proxy-tap    (via linkerd-viz-identity)
```

Both `Server` resources use `podSelector: matchLabels: {}` — an empty label selector that matches *all* pods in the namespace, so a single pair of resources covers every workload.

== Apply Command

```bash
kubectl apply -f infrastructure/manifests/observability/linkerd-viz-policy.yaml
```

== Verification

After applying, `linkerd viz stat` immediately showed live metrics:

```
NAME                        MESHED   SUCCESS      RPS   LATENCY_P50   LATENCY_P95   LATENCY_P99   TCP_CONN
chirpstack                     1/1   100.00%   0.2rps           1ms           2ms           2ms          3
chirpstack-gateway-bridge      1/1   100.00%   0.3rps           1ms           1ms           1ms          1
mosquitto                      1/1   100.00%   0.2rps           1ms           1ms           1ms          9
nodered                        1/1   100.00%   0.2rps           1ms           2ms           2ms          5
redis                          1/1   100.00%   0.2rps           1ms           1ms           1ms          9
```

Zero new proxy denial log entries appeared after the 10-second Prometheus scrape interval.

= Accessing the Linkerd Dashboard

== Prerequisites

`kubectl` must be configured locally (not via SSH). The dashboard command uses `kubectl port-forward` under the hood.

== Launch

Run this on your *local machine* (not on the control plane over SSH). The command uses `kubectl port-forward` internally and needs your local kubeconfig.

```fish
~/Tools/linkerd/bin/linkerd viz dashboard &
```

The command port-forwards several Viz services to `localhost` and prints the URL:

```
Linkerd dashboard available at:
http://localhost:50750
Grafana dashboard available at:
http://localhost:50750/grafana
```

Open `http://localhost:50750` in your browser.

== What You Can See

#table(
  columns: (auto, 1fr),
  stroke: 0.5pt,
  fill: (_, row) => if row == 0 { luma(220) } else { white },
  [*Dashboard section*], [*What it shows*],
  [Namespaces], [Per-namespace success rate, RPS, latency — pick `iot-system`],
  [Deployments], [Per-deployment golden metrics (success rate, RPS, p50/p95/p99 latency, TCP connections)],
  [Pods], [Per-pod metrics, live readiness],
  [Tap], [Live stream of individual requests between services — filter by namespace, deployment, or pod],
  [Routes], [Per-route breakdown if `ServiceProfile` resources are defined],
)

== Stop the Dashboard

```fish
# find and kill the background port-forward
kill %1
# or if you lost track of the job:
pkill -f "linkerd viz dashboard"
```

= Notes

- The Linkerd binary on this machine is at `~/Tools/linkerd/bin/linkerd`, *not* `/usr/local/bin/linkerd` (the CHEATSHEET.md path is stale).
- Prometheus is managed by Linkerd Viz itself — no separate Prometheus deployment is needed.
- If you deploy Grafana separately later, point it at the Viz Prometheus: `http://prometheus.linkerd-viz:9090`.
