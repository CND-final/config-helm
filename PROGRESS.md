# Cloud-Native Final Project — Progress

> Updated: 2026-06-01
> Track: Docker / Deployment / High Availability (HA) / Cloud HTTPS / Monitoring
> Independent of roundspring (backend) and Darius (CI testing)

---

## Repo / Track Overview

| Repo | Purpose | Status |
|------|---------|--------|
| `config-helm` | Kubernetes HA deployment (Helm + Zalando postgres-operator) | ✅ Done, pushed |
| `config-docker` | One-command Docker Compose deployment + GHCR | ✅ Done |
| **Render (cloud)** | Public access + real HTTPS (green lock) | ✅ **Done, live** |

---

## config-helm (K8s HA) — ✅ Done

### Architecture
```
namespace: config-man
├── frontend × 2   (nginx, NodePort 30080, PDB minAvailable=1)
├── backend  × 3   (Go API, port 3000, PDB minAvailable=2, liveness/readiness probe)
└── PostgreSQL HA  (Zalando operator)
      ├── postgres-0 ┐ master / standby decided dynamically by Patroni
      └── postgres-1 ┘ roles swap on failover
```

### Completed
- Helm chart works end-to-end, all pods Running
- backend × 3 + frontend × 2, stateless HA
- PostgreSQL HA: Zalando postgres-operator, master + standby; killing the master triggers automatic failover within tens of seconds (Patroni promotes the standby)
- PodDisruptionBudget: protects backend/frontend/postgres
- nginx injected via ConfigMap, proxy points to the correct K8s service name
- DATABASE_URL via secret, SSL (sslmode=require); username unified as `configman` (no underscore, to avoid the Zalando secret-name RFC 1123 restriction)
- demo toolkit:
  - `demo/ha-demo.sh`: **main script** (fully automated, no colors, press Enter after [1] to start)
    → injects three faults simultaneously: kill one backend pod + one frontend pod + DB master node
    → waits for recovery automatically, prints the master switch result (X -> Y)
    → DB master uses a normal delete (no --force) so Patroni fails over reliably (adding --force is hit-or-miss and may not switch)
  - `demo/DEMO.md`: full talk track + gotchas

### Key gotchas (useful on reinstall)
- **Bitnami postgresql-ha is deprecated**: image removed from Docker Hub (manifest unknown); switched to Zalando postgres-operator
- **Must delete PVCs on reinstall**: `helm uninstall` does not delete PVCs; a stale PVC with the old password causes backend `password authentication failed`. Full reset:
  ```
  helm uninstall config-man -n config-man
  kubectl delete postgresql config-man-postgres -n config-man
  kubectl delete pvc --all -n config-man
  kubectl get pvc -n config-man   # confirm empty
  helm install config-man . -n config-man
  ```
- **Leftover CRDs**: on operator reinstall CRD conflicts:
  ```
  kubectl delete crd postgresqls.acid.zalan.do
  kubectl delete crd operatorconfigurations.acid.zalan.do
  ```
- **Postgres connections require SSL**: Zalando's pg_hba.conf rejects unencrypted connections; DATABASE_URL must use `sslmode=require`
- **K8s env var cross-reference order**: when `DATABASE_URL` expands `$(DB_PASSWORD)`, `DB_PASSWORD` must be declared before `DATABASE_URL`

---

## config-docker (Docker Compose + GHCR) — ✅ Mostly done

### Completed
- GHCR push flow, public images: `ghcr.io/cnd-final/config-man-backend`, `-frontend`
- `make up-build` (build from source), `make pull` + `make up` (pull registry images)
- README + DOCKER.md complete
- feat/ghcr branch merged into main
- README fixes: removed the "CI not pushed" warning from Option B, added group-admin to demo accounts, bolded headings

### Local HTTPS (self-signed) — closed: not used for demo
- The local docker stack's `make certs` (mkcert) + proxy layer can serve `https://localhost`, but a self-signed cert on localhost is always flagged "not secure" by browsers unless the mkcert CA is installed on every demo machine.
- **Decision: the local stack does not prove HTTPS.** HTTPS is proven by the Render cloud deployment (real green lock). The local stack proves HA (K8s).
- The proxy / certs layer is local-only; dropped entirely when going to the cloud (Render does TLS termination itself).

### Todo
- [ ] frontend healthcheck (planned in session 2 but skipped; optional)

---

## Render Cloud HTTPS — ✅ Done, live

> Full setup in `config-docker/RENDER.md`

### Result
- HTTPS is a graded hard requirement (mentioned in class; most teams will do it); achieved via Render: real green lock, publicly reachable.
- Three Render services (all Free tier):
  - **frontend** Static Site (builds from the config-man repo, commit aligned to `c4b86d4`)
  - **backend** Web Service (uses the GHCR amd64 image `ghcr.io/cnd-final/config-man-backend:latest`)
  - **postgres** Render PostgreSQL (managed; backend auto-migrates + seeds on startup)
- Verified: login works, green lock with no warning.

### Live URLs
| Service | URL |
|---|---|
| Frontend | `https://config-man-frontend.onrender.com` |
| Backend | `https://config-man-backend.onrender.com` |
| Backend health | `https://config-man-backend.onrender.com/api/v1/health` |

### Key settings (gotchas)
- **backend port**: Render expects the service to listen on its assigned port; set `CONFIG_MAN_PORT=10000`, which the backend reads directly from env — **no code change**.
- **image arch**: Render runs amd64, so the image must be amd64. Rebuilt with `docker build --platform linux/amd64` to be sure.
- **frontend rewrite (replaces nginx)**: the frontend calls the relative path `/api`; Render has no nginx, so two **Rewrite** rules are used (order: `/api/*` first, then `/*` → `/index.html`). A rewrite is a server-side proxy → same-origin, no CORS.
- **DATABASE_URL**: use Render Postgres's **Internal URL** (only reachable within the same region); paste as-is first, add `?sslmode=require` if an SSL error appears.
- **backend image does not auto-deploy**: image-based services need a manual deploy; the Git-connected frontend auto-deploys.

### Demo-day notes
- **Cold start**: a free Web Service spins down after ~15 min idle; waking takes 30–60s. **Wake the backend by hitting the health endpoint right before the demo.**
- **Postgres expires in 30 days** (free tier is deleted), so don't provision too early. Within seven days of the demo, currently safe.

### Known minor cosmetic issues (do not affect grading)
- The cloud frontend sometimes leaves an empty trailing `?` in the URL on certain actions (purely cosmetic, a frontend app behavior unrelated to deployment). It disappeared after aligning to the latest commit; rooting it out would require changing config-man frontend code — low value, left as-is.
- SPA refresh returns to the home page (the fallback rule works fine; this is the frontend not persisting the route, not a deployment issue).

---

## Monitoring & Reliability (Prometheus + Grafana) — ✅ Done

> Full setup in `config-helm/monitoring/MONITORING.md`
> Maps to the grading item "Operations & Reliability (10%): present a monitoring dashboard; which metrics and why is up to you"

### Architecture
- `kube-prometheus-stack` (Helm, namespace `monitoring`): Prometheus collects metrics (scrape 5s) + Grafana dashboards + kube-state-metrics
- `prometheus-postgres-exporter`: connects to the master service, exports DB replication/transaction metrics
- Grafana dashboard "config-man HA Demo": `config-man-ha-dashboard.json` (importable directly)

### Six panels + why each metric (centered on "proving HA")
| Panel | Metric | Why |
|---|---|---|
| Ready Replicas | `kube_pod_status_ready` | Kill a backend/frontend pod → replica count drops then is restored, evidence of stateless self-healing |
| PostgreSQL Up | `pg_up` | DB reachability |
| Replication Slots Active | `pg_replication_slots_active` | Drops to 0 during failover then another slot takes over — the clearest visual evidence of DB failover |
| DB Commits/Rollbacks | `rate(xact_commit/rollback)` | Transaction throughput; reflects service interruption and recovery |
| Pod Restarts | `kube_pod_container_status_restarts_total` | Cumulative container restarts |
| ~~CPU/Memory by Pod~~ | (removed) | cAdvisor metrics unavailable on Docker Desktop |

### Important gotchas / clarifications
- **node-exporter does not run on Docker Desktop on Windows** (mounting host filesystem paths fails with a symlink error → CrashLoopBackOff); disabled via `nodeExporter.enabled: false`. Node/container-level live resource metrics are therefore unavailable — but on a single-node VM environment these have no reference value anyway.
- **The Replication Slots line at 1 is the standby (the side being replicated to), NOT the master!** After failover, when master = postgres-1, the active slot is postgres-0 (the new standby). Always determine the master from the terminal output / `spilo-role`; the slot line only corroborates replication state.
- **The ServiceMonitor must carry the `release: monitoring` label**, otherwise Prometheus won't scrape the exporter.
- **postgres-exporter connection requires sslmode=require** (same Zalando SSL restriction as on the K8s side).

### Demo setup
- 2 windows: left terminal runs `demo/ha-demo.sh`, right browser full-screen on Grafana.
- Strongest evidence of DB failover = the master switch in the terminal (100%); Grafana is visual corroboration.

---

## TODO (remaining)

1. ~~Decide HTTPS route~~ ✅ Went with Render, live
2. ~~Render deployment~~ ✅ All three services running, login works, green lock
3. ~~Monitoring dashboard (Operations 10%)~~ ✅ Prometheus + Grafana done
4. **Commit docs into repos**:
   - `config-docker/docs/RENDER.md`
   - `config-helm/monitoring/MONITORING.md` + `config-man-ha-dashboard.json` + values example files
5. **Demo rehearsal**:
   - HA + monitoring demo: run `demo/ha-demo.sh`, confirm the three fault injections, Grafana panels react, and the master switches
   - HTTPS demo: wake the Render backend beforehand, then show the green lock + login live
6. **(Optional)** the cloud trailing `?` has self-resolved; add the frontend healthcheck

---

## Demo accounts (password: `password`)

| Email | Role |
|-------|------|
| `admin@config-man.local` | System Admin |
| `project-admin@config-man.local` | Project Admin |
| `group-admin@config-man.local` | Group Admin |
| `developer@config-man.local` | Developer |
| `reviewer@config-man.local` | Reviewer |
| `viewer@config-man.local` | Viewer |
