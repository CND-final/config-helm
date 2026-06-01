# Cloud-Native 期末專案 — 進度

> 更新日期：2026-06-01
> 戰線：Docker / 部署 / 高可用性（HA）/ 雲端 HTTPS / 監控
> 獨立於 roundspring（backend）與 Darius（CI 測試）

---

## 兩條 repo 戰線總覽

| Repo | 用途 | 狀態 |
|------|------|------|
| `config-helm` | Kubernetes HA 部署（Helm + Zalando postgres-operator） | ✅ 完成、已 push |
| `config-docker` | Docker Compose 一鍵部署 + GHCR | ✅ 完成 |
| **Render 雲端** | 公開對外 + 真 HTTPS（綠鎖）| ✅ **完成、已上線** |

---

## config-helm（K8s HA）— ✅ 完成

### 架構
```
namespace: config-man
├── frontend × 2   (nginx, NodePort 30080, PDB minAvailable=1)
├── backend  × 3   (Go API, port 3000, PDB minAvailable=2, liveness/readiness probe)
└── PostgreSQL HA  (Zalando operator)
      ├── postgres-0 ┐ master / standby 由 Patroni 動態決定
      └── postgres-1 ┘ failover 時兩者角色互換
```

### 已完成
- Helm chart 跑通，所有 pod Running
- backend × 3 + frontend × 2，stateless HA
- PostgreSQL HA：Zalando postgres-operator，master + standby，殺 master 約數十秒內自動 failover（Patroni 提升 standby）
- PodDisruptionBudget：backend/frontend/postgres 都有保護
- nginx 用 ConfigMap 注入，proxy 指向正確的 K8s service name
- DATABASE_URL 走 secret，SSL（sslmode=require），username 統一用 `configman`（無底線，避開 Zalando secret name RFC 1123 限制）
- demo toolkit：
  - `demo/ha-demo.sh`：**主力腳本**（全自動、無顏色、[1] 後按 Enter 開始）
    → 同時注入三故障：殺一個 backend pod + 一個 frontend pod + DB master 節點
    → 自動等待恢復、印出 master 切換結果（X -> Y）
    → DB master 用正常 delete（不加 --force），讓 Patroni 可靠 failover（加 --force 會碰運氣不切換）
  - `demo/DEMO.md`：完整講稿 + gotchas

### 重要踩坑紀錄（之後重裝會用到）
- **Bitnami postgresql-ha 廢棄**：image 已從 Docker Hub 移除（manifest unknown），改用 Zalando postgres-operator
- **重裝必刪 PVC**：`helm uninstall` 不刪 PVC，舊 PVC 殘留舊密碼會導致 backend `password authentication failed`。完整重置流程：
  ```
  helm uninstall config-man -n config-man
  kubectl delete postgresql config-man-postgres -n config-man
  kubectl delete pvc --all -n config-man
  kubectl get pvc -n config-man   # 確認清空
  helm install config-man . -n config-man
  ```
- **CRD 殘留**：重裝 operator 撞 CRD conflict 時：
  ```
  kubectl delete crd postgresqls.acid.zalan.do
  kubectl delete crd operatorconfigurations.acid.zalan.do
  ```
- **postgres 連線要 SSL**：Zalando 的 pg_hba.conf 拒絕無加密連線，DATABASE_URL 必須 `sslmode=require`
- **K8s env var 互引用順序**：`DATABASE_URL` 用 `$(DB_PASSWORD)` 展開時，`DB_PASSWORD` 必須在 `DATABASE_URL` 之前宣告

---

## config-docker（Docker Compose + GHCR）— ✅ 基本完成

### 已完成
- GHCR push 流程，image 為 public：`ghcr.io/cnd-final/config-man-backend`、`-frontend`
- `make up-build`（從原始碼 build）、`make pull` + `make up`（拉 registry image）
- README + DOCKER.md 文件完整
- feat/ghcr 分支已 merge 進 main
- README 修正：Option B 移除「CI 未推送」警告、demo accounts 補 group-admin、標題加粗

### 本機 HTTPS（self-signed）— 結案：不拿來 demo
- 本機 docker 版 `make certs`（mkcert）+ proxy 那層可跑出 `https://localhost`，但 self-signed 在 localhost 永遠被瀏覽器標「不安全」，除非每台 demo 機都裝 mkcert CA。
- **決策：本機版不負責證 HTTPS**。HTTPS 改由 Render 雲端版證明（真綠鎖）。本機版負責 HA（K8s）。
- proxy / certs 那層只是本機自帶，上雲時整層丟掉（Render 自己做 TLS termination）。

### 待辦
- [ ] frontend healthcheck（session 2 規劃但跳過，可有可無）

---

## Render 雲端 HTTPS — ✅ 完成、已上線

> 完整設定見 `config-docker/RENDER.md`

### 結果
- HTTPS 是評分硬要求（上課提過、多數組會做），已用 Render 達成：真綠鎖、對外可訪問。
- 三個 Render service（全 Free tier）：
  - **frontend** Static Site（連 config-man repo build，commit 已對齊 `c4b86d4`）
  - **backend** Web Service（吃 GHCR amd64 image `ghcr.io/cnd-final/config-man-backend:latest`）
  - **postgres** Render PostgreSQL（managed，backend 開機自動 migrate + seed）
- 已驗證：登入成功、綠鎖無警告。

### 上線網址
| Service | URL |
|---|---|
| Frontend | `https://config-man-frontend.onrender.com` |
| Backend | `https://config-man-backend.onrender.com` |
| Backend health | `https://config-man-backend.onrender.com/api/v1/health` |

### 關鍵設定（踩坑紀錄）
- **backend port**：Render 期望服務 listen 在它指定的 port，設 `CONFIG_MAN_PORT=10000`，backend 直接讀 env，**不用改 code**。
- **image 架構**：Render 跑 amd64，image 必須 amd64。曾用 `docker build --platform linux/amd64` 重 build + push 確保。
- **frontend rewrite（取代 nginx）**：前端打相對路徑 `/api`，Render 無 nginx，改用兩條 **Rewrite** 規則（順序：`/api/*` 在前、`/*`→`/index.html` 在後）。Rewrite 是 server-side proxy，同源、無 CORS。
- **DATABASE_URL**：用 Render Postgres 的 **Internal URL**（同 region 才連得到）；先原樣貼，SSL 報錯再加 `?sslmode=require`。
- **backend image 不會 auto-deploy**：image-based service 要手動 deploy；frontend 連 Git 則會 auto-deploy。

### Demo 當天注意
- **冷啟動**：free Web Service 閒置 ~15 分鐘休眠，喚醒要 30–60s。**demo 前先打一發 health 端點喚醒 backend**。
- **Postgres 30 天到期**（free tier 會被刪），別太早開。距 demo 七天內，目前安全。

### 已知小瑕疵（不影響評分）
- 雲端前端某些操作網址尾巴會多一個空 `?`（純外觀，前端 app 行為，與部署無關）。對齊最新 commit 後重測;要根治需改 config-man 前端碼，CP 值低，暫放。
- SPA 重新整理會回首頁（fallback 規則正常，是前端未持久化路由的行為，非部署問題）。

---

## 監控與可靠性（Prometheus + Grafana）— ✅ 完成

> 完整設定見 `config-helm/MONITORING.md`
> 對應評分「運維與可靠性（10%）：應呈現監控儀表板，監控哪些指標、原因自行安排」

### 架構
- `kube-prometheus-stack`（Helm，namespace `monitoring`）：Prometheus 收指標（scrape 5s）+ Grafana 出儀表板 + kube-state-metrics
- `prometheus-postgres-exporter`：連 master service，輸出 DB 複製/交易指標
- Grafana 儀表板「config-man HA Demo」：`config-man-ha-dashboard.json`（可直接 import）

### 六個面板 + 監控原因（圍繞「證明 HA」）
| 面板 | 指標 | 原因 |
|---|---|---|
| Ready Replicas | `kube_pod_status_ready` | 殺 backend/frontend pod → 副本掉再補回，無狀態自癒證據 |
| PostgreSQL Up | `pg_up` | DB 可連線性 |
| Replication Slots Active | `pg_replication_slots_active` | failover 時掉到 0 再接手，DB failover 最清楚的視覺證據 |
| DB Commits/Rollbacks | `rate(xact_commit/rollback)` | 交易吞吐，反映服務中斷再恢復 |
| Pod Restarts | `kube_pod_container_status_restarts_total` | container 重啟累計 |
| ~~CPU/Memory by Pod~~ | （已移除） | cAdvisor 在 Docker Desktop 抓不到 |

### 重要踩坑 / 釐清
- **node-exporter 在 Docker Desktop on Windows 跑不起來**（掛載宿主機路徑 symlink 失敗 → CrashLoopBackOff），已 `nodeExporter.enabled: false` 關閉。節點/容器即時資源指標因此無資料 —— 單機 VM 環境本就無參考價值。
- **Replication Slots 線=1 的是 standby（被複製方），不是 master！** failover 後 master=postgres-1 時，活躍 slot 是 postgres-0（新 standby）。判斷 master 一律以終端機 / `spilo-role` 為準，slot 線只佐證複製狀態。
- **ServiceMonitor 要帶 `release: monitoring` label**，Prometheus 才會收 exporter。
- **postgres-exporter 連線要 sslmode=require**（同 K8s 那邊的 Zalando SSL 限制）。

### Demo 配置
- 2 視窗：左終端機跑 `demo/ha-demo.sh`、右瀏覽器全螢幕 Grafana。
- DB failover 最強證據 = 終端機 master 切換（100%）；Grafana 為視覺佐證。

---

## TODO（剩餘）

1. ~~拍板 HTTPS 路線~~ ✅ 走 Render，已完成上線
2. ~~Render 部署~~ ✅ 三個 service 都跑通、登入成功、綠鎖正常
3. ~~監控儀表板（運維 10%）~~ ✅ Prometheus + Grafana 完成
4. **commit 文件進 repo**：
   - `config-docker/docs/RENDER.md`
   - `config-helm/MONITORING.md` + `config-man-ha-dashboard.json` + monitoring/pg-exporter values 檔
5. **demo 彩排**：
   - HA + 監控 demo：跑 `demo/ha-demo.sh`，確認三故障注入、Grafana 各面板有反應、master 切換
   - HTTPS demo：demo 前先喚醒 Render backend，當眾指綠鎖 + 登入
6. **（可選）** 雲端尾巴 `?` 已自動消失；frontend healthcheck 補上

---

## Demo 帳號（密碼皆為 `password`）

| Email | Role |
|-------|------|
| `admin@config-man.local` | System Admin |
| `project-admin@config-man.local` | Project Admin |
| `group-admin@config-man.local` | Group Admin |
| `developer@config-man.local` | Developer |
| `reviewer@config-man.local` | Reviewer |
| `viewer@config-man.local` | Viewer |
