# Monitoring & Reliability

This document describes the monitoring setup for config-man on Kubernetes: Prometheus
collects metrics, Grafana visualizes them, and a single integrated dashboard observes how
the high-availability (HA) mechanisms behave under fault.

---

## 1. Monitoring architecture

```
Kubernetes cluster
├── kube-prometheus-stack (Helm chart, namespace: monitoring)
│     ├── Prometheus        ← collects + stores time-series metrics (scrape interval 5s)
│     ├── Grafana           ← dashboards
│     └── kube-state-metrics ← K8s object state (replica counts, pod restarts...)
└── prometheus-postgres-exporter (namespace: monitoring)
      └── connects to the master service (config-man-postgres), exports DB metrics
```

- **Prometheus**: scrapes each source every 5 seconds, stores as time-series data.
- **Grafana**: reads Prometheus, renders the "config-man HA Demo" dashboard.
- **postgres-exporter**: connects to `config-man-postgres` (master service) as the superuser,
  exporting replication state, transaction throughput, etc.; its ServiceMonitor carries the
  `release: monitoring` label so Prometheus includes it automatically.

### Install steps (reproducible)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 1. Install the stack (trimmed config in monitoring-values.yaml)
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring-values.yaml

# 2. Install postgres-exporter (config in pg-exporter-values.yaml)
helm install pg-exporter prometheus-community/prometheus-postgres-exporter \
  -n monitoring -f pg-exporter-values.yaml

# 3. Open Grafana (user admin / password from values)
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# Browse to http://localhost:3000 → import config-man-ha-dashboard.json
```

Key points in `monitoring-values.yaml`: disable Alertmanager and node-exporter (unused /
won't run on single-node Docker Desktop), set scrape interval to 5s, and lower each
component's resource requests to fit a single machine.

---

## 2. Which metrics, and why

Metric selection centers on a single goal: **proving high availability** — i.e. "when a
fault occurs, how does the system stay up and recover automatically." We monitor not the
binary "is it alive" but the dynamic process of fault and recovery. The dashboard has six panels:

| Panel | Metric | Why monitor it |
|-------|--------|----------------|
| **Ready Replicas by Service** | `kube_pod_status_ready` per service | Direct HA evidence. When a backend/frontend pod is killed, the line drops then is restored by K8s — proving stateless self-healing. |
| **PostgreSQL Up** | `pg_up` | Whether the DB is reachable. The most basic availability metric. |
| **Replication Slots Active (DB failover)** | `pg_replication_slots_active` | Shows the currently **active standby** (the side being replicated to). During failover it briefly drops to 0 (replication breaks), then the new standby takes over at 1 — the clearest visual evidence of DB failover. |
| **DB Commits / Rollbacks Rate** | `rate(pg_stat_database_xact_commit/​rollback)` | Transaction throughput. Drops during failover and rebounds afterward, reflecting "service interrupted then recovered". |
| **Pod Restarts (cumulative)** | `kube_pod_container_status_restarts_total` | Container-level cumulative restart count, reflecting liveness-probe-triggered restarts. |
| **CPU / Memory by Pod** *(removed)* | — | On single-node Docker Desktop, cAdvisor live container resource metrics are unavailable (see limitations), so this panel was removed. |

---

## 3. Reading the Replication Slots panel correctly (important — read before demo)

This panel is the easiest to misread. Follow the rule below or it won't line up with the
terminal output.

**Core rule: the line at 1 is the currently active *standby* (the side being replicated to), NOT the master.**

Why: a replication slot is created on the master and named after the standby; `active=1`
means "that standby is connected to the master and receiving data." So:

- When the master changes, the standby changes too → the active line switches accordingly.
- At the moment of failover: the existing replication connection breaks, the line **briefly
  drops to 0**; once the new standby reconnects it returns to 1.

**Worked example** (cross-check against the terminal's `master: X -> Y`):

```
Before fault: master = postgres-0  → standby = postgres-1 → line config_man_postgres_1 = 1
Failover:     replication breaks, line briefly drops to 0
After fault:  master = postgres-1  → standby = postgres-0 → line config_man_postgres_0 = 1
```

> Common mistake: do NOT treat "the node whose line is at 1" as the master. It is the **standby**.
> Always determine the master from the **terminal output** or
> `kubectl get pods -l application=spilo -L spilo-role`; the slot line only corroborates
> "did replication break, and who is the standby".

---

## 4. Running the demo

### Window layout (minimal, 2 windows)
- **Window 1 (browser, full-screen)**: the Grafana "config-man HA Demo" dashboard.
- **Window 2 (terminal)**: runs the demo script.

> A separate persistent `kubectl port-forward svc/monitoring-grafana 3000:80` window is also
> needed to keep the Grafana connection alive (can be minimized).

### Run
```bash
wsl bash demo/ha-demo.sh
```

Script flow:
1. **[1] Pre-fault state + explanation** → pauses; press Enter to start (explain the architecture here).
2. **[2] Inject faults simultaneously**: kill one backend pod + one frontend pod + the DB master node.
   - backend/frontend use a force delete (stateless, recreated immediately).
   - the DB master uses a **normal delete (no --force)** so Patroni has time to detect and promote the standby.
3. **[3] Automatic recovery**: wait for backend/frontend to restore replicas and Patroni to promote a new master.
4. **[4] Post-fault state**: shows replica counts restored and the master switched (X -> Y).

### What to watch per panel

| Fault | Panel | Behavior |
|-------|-------|----------|
| backend pod killed | Ready Replicas (green) | line drops from 3 to 2, back to 3 in seconds |
| frontend pod killed | Ready Replicas (yellow) | line drops from 2 to 1, back to 2 in seconds |
| **DB master fault** | **Replication Slots Active** | line briefly drops to 0, another line takes over to 1 |
| DB service interruption/recovery | DB Commits / Rollbacks | throughput drops then rebounds |
| failover proof | **terminal [4]** | `master: postgres-X -> postgres-Y` |

> The strongest evidence of DB failover is the **master switch in the terminal** (100% certain);
> Replication Slots and DB Commits are visual corroboration.
> Note: postgres pods are recreated very fast, so **the postgres line in Ready Replicas usually
> won't show a dip** (the brief gap is skipped by the 5s scrape) — this is normal; watch
> Replication Slots for DB faults instead.

---

## 5. Environment limitations (honest notes, may be asked)

This monitoring runs on **single-node Docker Desktop K8s**, with two known limitations, both
caused by the environment and not misconfiguration:

1. **node-exporter cannot run**: on Docker Desktop on Windows, node-exporter needs to mount
   host filesystem paths (/proc, /sys), but K8s runs inside a VM where the paths don't line up,
   so the pod ends up in CrashLoopBackOff. Disabled. Impact: node-level hardware metrics
   (node CPU/memory utilization %) are unavailable — but on a single node inside a VM, these
   have no reference value anyway.

2. **cAdvisor container live resource metrics unavailable**: same root cause, leaving per-pod
   live CPU/memory usage without data, so that panel was removed.

**Standard answer**:
> "We're on a single node, running inside the Docker Desktop VM, so node- and container-level
> live resource metrics can't be collected in this environment and have no reference value here.
> We monitor the metrics directly tied to **high availability** — replica counts, replication
> state, DB failover, and transaction throughput — all of which work."

> Note: node-exporter / cAdvisor work fine on a real multi-node cloud cluster, where resource
> utilization metrics can be filled in; this is purely a local single-machine limitation.
