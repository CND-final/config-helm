# HA Demo Guide — config-man

A three-screen live demonstration that the system survives pod failures with
zero (or near-zero) downtime.

## What this proves

| Part | Action | Proves |
|------|--------|--------|
| 1 | Kill a **backend** pod | Stateless HA — 3 replicas, PDB keeps ≥2 alive, K8s auto-replaces in ~8s |
| 2 | Kill the **PostgreSQL primary** | Stateful HA — Zalando operator promotes standby to primary in ~30s, no data loss |

---

## Screen layout

Arrange three windows side by side (plus one small driver terminal):

```
┌─────────────────────────┬─────────────────────────┐
│  ① 瀏覽器                │  ② Terminal B           │
│  http://localhost:30080 │  kubectl get pods -w    │
│  (登入、停在資料頁)       │  (看 pod 死掉重生)      │
├─────────────────────────┼─────────────────────────┤
│  ② health-monitor       │  ④ Driver terminal      │
│    .html                │  ha-demo.sh             │
│  ( 時間軸全綠)           │  (按 Enter 推進)        │
└─────────────────────────┴─────────────────────────┘
```

**Role split:** you drive the browser and click around to show real usage;
`ha-demo.sh` handles the kubectl actions and pauses for your narration.

---

## Setup (run before the audience arrives)

Make sure the release is up and all pods are `Running`:

```bash
kubectl get pods -n config-man
```

Open three terminals + a browser.

**Terminal A — continuous health probe:**
```bash
bash watch-health.sh
```
You should see a steady stream of `✅ UP (HTTP 200)`. If you see `❌ DOWN`,
fix it before the demo — the NodePort/proxy path isn't working.

**Terminal B — live pod status:**
```bash
kubectl get pods -n config-man -w
```

**Browser:**
Open `http://localhost:30080`, log in as `admin@config-man.local`
(password: `password`), and navigate to a page that shows real data.

**Driver terminal:**
```bash
bash ha-demo.sh
```
Press Enter to advance through each step at your own pace.

---

## Run order & talking points

### Part 1 — Backend (stateless)
1. Driver kills one backend pod.
2. Point at **Terminal B**: the pod terminates, a new one is created.
3. Point at **Terminal A**: the probe never left `✅ UP`.
4. **Say:** *"Three replicas, the disruption budget guarantees at least two are
   always serving. The user never noticed."*

### Part 2 — PostgreSQL primary (stateful)
1. Driver kills `config-man-postgres-0` (the primary).
2. **Say:** *"This is the hard part — a database has state. We run a primary and
   a standby. I just killed the primary."*
3. Wait ~30s. The Zalando operator promotes the standby.
4. **Say the trade-off honestly:** *"There's a brief switch-over window where
   writes can fail for a few seconds. That's the HA trade-off — we get no data
   loss and automatic recovery, not zero-second cutover. Zero-second needs
   multi-master, which is far more complex."*
5. In the **browser**, reload a data page — records are still there.
6. **Say:** *"The standby is now primary. The old primary rejoined as standby.
   No data lost."*

### Closing
Point at Terminal A's `down=` counter.
**Say:** *"We killed a stateless pod and the database primary. Down count: zero.
Pods failed — the service survived."*

---

## Notes & gotchas

- **Health endpoint scope:** `/api/v1/health` may not query the DB. If so, the
  probe can stay `✅ UP` even during the postgres switch-over. That's why Part 2
  also reloads a **real data page** in the browser — that's the true end-to-end
  proof the database recovered.
- **The 30s window is normal.** Don't hide it; explain it. Evaluators respect a
  demonstrated understanding of the trade-off more than a suspiciously perfect run.
- **Reset between rehearsals:** after killing the primary, roles swap
  (`postgres-1` becomes primary). This is fine — the next run just kills whoever
  is primary. To check current roles:
  ```bash
  kubectl get pods -n config-man -L spilo-role
  ```
- **If a backend pod won't come back:** check the Zalando secret name still
  matches `backend-deployment.yaml` (username `configman`).

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
