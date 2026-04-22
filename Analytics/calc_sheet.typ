#set page(paper: "a4", margin: 2cm)
#set text(font: "Linux Libertine", size: 11pt)
#set heading(numbering: "1.")
#set par(justify: true)

#align(center)[
  #text(size: 18pt, weight: "bold")[IoT Cloud-Native System Sizing Report] \
  #v(1em)
  #text(size: 12pt)[Analytical Baseline for Service Mesh Infrastructure Provisioning]
]

#v(2em)

= Benchmark Assumptions & Load Profile

The designed architecture integrates a full IoT stack (ChirpStack, Node-RED, InfluxDB) within a Kubernetes-based Service Mesh (Linkerd). To properly size the environment, we establish an Expected Throughput target for the system. 
During the live demonstration, a simulated fleet of LoRaWAN sensors will generate a continuous stream of telemetry data.

*Target Load Profile ($lambda$):*
- *Telemetry Ingestion:* 50 Requests Per Second (RPS) generated synthetically or via physical gateways.
- *Message Size:* Average payload of 2 KB (JSON with LoRaWAN metadata).

*Infrastructure Overhead (Linkerd Service Mesh):*
Linkerd utilizes a lightweight Rust-based micro-proxy (Linkerd2-proxy) injected into every pod. We allocate a static overhead per instance: $approx 50$ MB RAM and $approx 50m$ CPU.

= Analytical Formulas

*1. Expected CPU Capacity (Millicores):*
$ "CPU"_m = ((lambda times W_"app") times K_"overhead") + "CPU"_"mesh" $
Where $W_"app"$ is the processing time in milliseconds, $K_"overhead" = 1.2$ (context switching buffer), and $"CPU"_"mesh" = 50m$.

*2. Expected RAM Footprint (Megabytes):*
$ M_"total" = M_"base" + (M_"req" times lambda) + W S S + M_"mesh" $
Where $M_"base"$ is the runtime footprint, $W S S$ is the Working Set Size (critical for databases like InfluxDB), and $M_"mesh" = 50$ MB.

= Service Target Capacities (Per Instance)

== ChirpStack (Network Server)
- *Technology:* Golang (Compiled, highly concurrent).
- *Benchmark Target:* $lambda = 50$ RPS, $W_"app" = 2$ ms.
- *CPU:* 
$ (50 times 2 times 1.2) + 50m = 120m + 50m = 170m $
- *RAM:* 
#align(center)[$50$ MB + $50$ MB (Mesh) = $100$ MB.]

- *Provisioning Target:* 300m CPU / 256Mi RAM.

== Eclipse Mosquitto (MQTT Broker)
- *Technology:* C (Extremely lightweight).
- *Benchmark Target:* $lambda = 50$ RPS, $W_"app" = 1$ ms.
- *CPU:* 
$ (50 times 1 times 1.2) + 50m = 60m + 50m = 110m $
- *RAM:* 

#align(center)[$20$ MB + $50$ MB (Mesh) = $70$ MB.]

- *Provisioning Target:* 200m CPU / 128Mi RAM.

== Node-RED (Low-Code ETL)
- *Technology:* Node.js (V8 Engine).
- *Benchmark Target:* $lambda = 50$ RPS, $W_"app" = 5$ ms.
- *CPU:* 
$ (50 times 5 times 1.2) + 50m = 300m + 50m = 350m $
- *RAM:* 
#align(center)[$150$ MB (V8 Base) + Payload Buffer ($50 times 1$ MB) + $50$ MB = $250$ MB.]

- *Provisioning Target:* 500m CPU / 512Mi RAM.

== InfluxDB (Time-Series Database)
- *Technology:* Golang (Memory-bound due to indexing).
- *Benchmark Target:* Heavy Write/Read operations.
- *CPU:* Minimum required for indexing $approx 500m$ + $50m$ (Mesh).
- *RAM:* $250$ MB (Base) + $W S S$ ($500$ MB) + $50$ MB = $800$ MB.
- *Provisioning Target:* 1000m CPU / 1536Mi RAM.

== PostgreSQL & Redis (ChirpStack State & Cache)
- *Provisioning Target (PostgreSQL):* 500m CPU / 512Mi RAM.
- *Provisioning Target (Redis):* 200m CPU / 128Mi RAM.
- *(Both include the 50 MB Linkerd sidecar overhead).*

= Provisioning Summary

#v(1em)

#figure(
  table(
    columns: (auto, auto, auto, 1fr),
    fill: (x, y) => if y == 0 { luma(230) } else { none },
    inset: 8pt,
    align: horizon,
    
    [ *Component* ], [ *CPU Target* ], [ *RAM Target* ], [ *Benchmark Notes* ],
    [ ChirpStack ], [ 300m ], [ 256Mi ], [ Evaluates LoRaWAN frame decryption and device routing. ],
    [ Mosquitto ], [ 200m ], [ 128Mi ], [ Sub-millisecond routing overhead. C-based efficiency. ],
    [ Node-RED ], [ 500m ], [ 512Mi ], [ Data transformation (ETL). V8 Engine footprint. ],
    [ InfluxDB ], [ 1000m ], [ 1536Mi ], [ Time-Series storage. High WSS requirement for fast Grafana queries. ],
    [ PostgreSQL ], [ 500m ], [ 512Mi ], [ Relational data (Tenants, Gateways, Device Profiles). ],
    [ Redis ], [ 200m ], [ 128Mi ], [ In-memory cache for frame deduplication. ],
    [ Grafana ], [ 300m ], [ 256Mi ], [ HTTP GUI visualization overhead. ]
  ),
  caption: [Recommended Sizing Requirements per Instance (IoT Environment)]
)

= Final Cluster Infrastructure Requirements

To deploy the entire IoT suite alongside Kubernetes (K3s/MicroK8s) and the Linkerd Service Mesh control plane, the underlying virtual machines must account for both application targets and OS daemons.

*Data Plane Total App Aggregation:*
Total Workloads: ~3000m CPU (3 vCPUs) and ~3328Mi RAM (3.3 GB).
Safety Buffer (30%): ~4 vCPUs and ~4.5 GB RAM.

#v(1em)

#figure(
  table(
    columns: (auto, auto, auto, auto, 1fr),
    fill: (x, y) => if y == 0 { luma(230) } else { none },
    inset: 8pt,
    align: horizon,
    
    [ *Node Pool* ], [ *Count* ], [ *vCPU* ], [ *RAM* ], [ *Purpose & Justification* ],
    [ *Control Plane* ], [ 1 ], [ 2 ], [ 4 GB ], [ Master node. Runs the Kubernetes API server, Dqlite/etcd, and the Linkerd Control Plane. ],
    [ *Worker Nodes* ], [ 2 ], [ 2 ], [ 4 GB ], [ Data nodes. Run the actual IoT workloads (ChirpStack, Node-RED, DBs) and sidecar proxies. ],
    [ *Load Gen* ], [ 1 ], [ 2 ], [ 2 GB ], [ Optional external VM to run a Python script or Node-RED instance simulating 50 LoRaWAN gateways. ]
  ),
  caption: [Final Hardware Provisioning Summary for K3s/MicroK8s Cluster]
)

#v(1em)
*Total Infrastructure Required:* 4 Virtual Machines (Totaling 8 vCPUs and 14 GB RAM).