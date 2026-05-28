# config-helm

> Kubernetes HA deployment for [config-man](https://github.com/CND-final/config-man)
> using Helm + Zalando postgres-operator.

## Architecture

```
namespace: config-man
│
├── frontend × 2 pod  (nginx, NodePort 30080)
│     └── PodDisruptionBudget: minAvailable=1
│
├── backend × 3 pod   (Go API, port 3000)
│     └── PodDisruptionBudget: minAvailable=2
│         liveness/readiness probe
│
└── PostgreSQL HA (Zalando operator)
      ├── postgres-0  primary
      └── postgres-1  standby (auto failover)
```

## Prerequisites

| Tool | Version |
|------|---------|
| Docker Desktop | 4.x |
| Kubernetes (Docker Desktop built-in) | enabled |
| kubectl | 1.28+ |
| Helm | 3.x |

Enable Kubernetes in Docker Desktop:
Settings → Kubernetes → Enable Kubernetes → Apply & Restart

## Quick Start

### Step 1 — Add Helm repos

```bash
helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
helm repo update
```

### Step 2 — Install Zalando postgres-operator

```bash
helm install postgres-operator postgres-operator-charts/postgres-operator --namespace postgres-operator --create-namespace
```

Verify:
```bash
kubectl get pods -n postgres-operator
```
Wait until `postgres-operator-xxx` is `Running`.

### Step 3 — Install config-man

```bash
git clone https://github.com/CND-final/config-helm.git
cd config-helm
helm install config-man . \
  --namespace config-man \
  --create-namespace
```

### Step 4 — Verify

```bash
kubectl get pods -n config-man
```

Expected output:
```
config-man-backend-xxx    1/1   Running   (× 3)
config-man-frontend-xxx   1/1   Running   (× 2)
config-man-postgres-0     1/1   Running   ← primary
config-man-postgres-1     1/1   Running   ← standby
# Note: primary/standby roles may swap after a failover
```

Open http://localhost:30080 in your browser.

Demo accounts (password: `password`):

| Email | Role |
|-------|------|
| `admin@config-man.local` | System Admin |
| `project-admin@config-man.local` | Project Admin |
| `developer@config-man.local` | Developer |
| `reviewer@config-man.local` | Reviewer |
| `viewer@config-man.local` | Viewer |

## HA Demo

Run the demo script to prove the system survives pod failures:

```bash
# Linux / macOS / WSL2
./demo.sh

# Windows Git Bash
bash demo.sh
```

What it does:
1. Confirms all pods are healthy
2. Deletes a backend pod → K8s auto-replaces it in ~8 seconds
3. Deletes postgres primary → standby auto-promotes in ~30 seconds
4. Confirms service is still alive after each failure

## Uninstall

```bash
helm uninstall config-man -n config-man
helm uninstall postgres-operator -n postgres-operator
kubectl delete namespace config-man
kubectl delete namespace postgres-operator
```
