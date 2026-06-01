# 監控與可靠性 (Monitoring & Reliability)

本文件說明 config-man 在 Kubernetes 上的監控方案：用 Prometheus 收集指標、
Grafana 視覺化，並透過一個整合儀表板觀察高可用 (HA) 機制在故障時的行為。

---

## 一、監控架構

```
Kubernetes 叢集
├── kube-prometheus-stack (Helm chart，namespace: monitoring)
│     ├── Prometheus        ← 收集 + 儲存時序指標 (scrape interval 5s)
│     ├── Grafana           ← 視覺化儀表板
│     └── kube-state-metrics ← K8s 物件狀態 (副本數、pod 重啟次數…)
└── prometheus-postgres-exporter (namespace: monitoring)
      └── 連到 master service (config-man-postgres)，輸出 DB 指標
```

- **Prometheus**：每 5 秒抓一次各來源的指標，存成時序資料。
- **Grafana**：讀 Prometheus，畫成儀表板「config-man HA Demo」。
- **postgres-exporter**：以超級使用者連線 `config-man-postgres` (master service)，
  輸出複製狀態、交易吞吐等 DB 指標；ServiceMonitor 帶 `release: monitoring`
  標籤讓 Prometheus 自動納入收集。

### 安裝重點 (可重現)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 1. 安裝 stack（精簡設定見 monitoring-values.yaml）
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring-values.yaml

# 2. 安裝 postgres-exporter（設定見 pg-exporter-values.yaml）
helm install pg-exporter prometheus-community/prometheus-postgres-exporter \
  -n monitoring -f pg-exporter-values.yaml

# 3. 開 Grafana（帳號 admin / 密碼見 values）
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# 瀏覽器開 http://localhost:3000 → 匯入 config-man-ha-dashboard.json
```

`monitoring-values.yaml` 的精簡重點：關閉 Alertmanager 與 node-exporter
(在 Docker Desktop 單機環境用不到 / 跑不起來)、scrape interval 設 5s、
降低各元件 resource request 以適應單機。

---

## 二、監控哪些指標，以及原因

指標選擇圍繞單一目標：**證明高可用** —— 也就是「故障發生時，系統如何維持服務、
如何自動恢復」。監控的不是「有沒有活著」的二元狀態，而是故障與恢復的動態過程。
儀表板共五個面板：

| 面板 | 指標 | 為什麼監控 |
|------|------|-----------|
| **Ready Replicas by Service** | `kube_pod_status_ready` 各服務 Ready pod 數 | HA 的直接證據。殺掉一個 backend/frontend pod 時，線會下掉再被 K8s 補回，證明無狀態服務的自我修復。 |
| **PostgreSQL Up** | `pg_up` | 資料庫是否可連線。最基本的可用性指標。 |
| **Replication Slots Active (DB failover)** | `pg_replication_slots_active` | 顯示當前**活躍的 standby**（被複製的一方）。failover 時短暫掉到 0（複製中斷），再由新 standby 接手回 1，是 DB failover 最清楚的視覺證據。 |
| **DB Commits / Rollbacks Rate** | `rate(pg_stat_database_xact_commit/​rollback)` | 交易吞吐。failover 期間掉落、恢復後回升，反映「服務中斷再恢復」。 |
| **Pod Restarts (cumulative)** | `kube_pod_container_status_restarts_total` | container 層級的累計重啟次數，反映 liveness 探針觸發的重啟。 |


---

## 三、Replication Slots 面板的正確解讀

**線在 1 的那條，代表當前「活躍的 standby」（被複製的一方），不是 master。**

原因：replication slot 由 master 建立、以 standby 命名，`active=1` 表示
「該 standby 正連著 master 收資料」。所以：

- master 換人時，standby 也換人 → 活躍的那條線跟著換。
- failover 瞬間：原複製連線中斷，線**短暫掉到 0**；新 standby 接上後回到 1。

**對照範例**（與終端機 `master: X -> Y` 對照驗證）：

```
故障前： master = postgres-0  → standby = postgres-1 → 線 config_man_postgres_1 = 1
failover：複製中斷，線短暫掉到 0
故障後： master = postgres-1  → standby = postgres-0 → 線 config_man_postgres_0 = 1
```

> 易錯點：不要把「線在 1 的節點」當成 master。它是 **standby**。
> 判斷 master 一律以**終端機輸出**或 `kubectl get pods -l application=spilo -L spilo-role` 為準，
> Grafana 的 slot 線只是輔助佐證「複製有沒有中斷、standby 是誰」。

---

## 四、Demo 操作

### 畫面配置（最簡，2 個視窗）
- **視窗 1（瀏覽器，全螢幕）**：Grafana「config-man HA Demo」儀表板。
- **視窗 2（終端機）**：執行 demo 腳本。

> 另需一個常駐的 `kubectl port-forward svc/monitoring-grafana 3000:80`
> 視窗維持 Grafana 連線（可最小化）。

### 執行
```bash
wsl bash demo/ha-demo.sh
```

腳本流程：
1. **[1] 故障前狀態 + 說明** → 印完停住，按 Enter 開始（趁此講解架構）。
2. **[2] 同時注入故障**：殺一個 backend pod + 一個 frontend pod + DB master 節點。
   - backend/frontend 用強制刪除（無狀態，立即重建）。
   - DB master 用**正常刪除（不加 --force）**，讓 Patroni 有時間偵測並提升 standby。
3. **[3] 自動恢復**：等 backend/frontend 補回副本、Patroni 提升新 master。
4. **[4] 恢復後狀態**：顯示副本數已回滿、master 已切換 (X -> Y)。

### 各面板 demo 時看什麼

| 故障 | 看哪個面板 | 現象 |
|------|-----------|------|
| backend 殺 pod | Ready Replicas（綠線） | 線從 3 掉到 2，數秒後回 3 |
| frontend 殺 pod | Ready Replicas（黃線） | 線從 2 掉到 1，數秒後回 2 |
| **DB master 故障** | **Replication Slots Active** | (觀察不到)線短暫掉到 0，另一條接手回 1 |
| DB 服務中斷恢復 | DB Commits / Rollbacks | 吞吐掉落後回升 |
| failover 鐵證 | **終端機 [4]** | `master: postgres-X -> postgres-Y` |

> DB failover 的最強證據是**終端機的 master 切換**（100% 確定），
> Replication Slots 與 DB Commits 為視覺佐證。
> 注意：postgres pod 重建極快，**Ready Replicas 的 postgres 線通常抓不到下掉**
> （5s 取樣跳過了短暫空窗），這是正常的；DB 故障改看 Replication Slots。

---

## 五、環境限制（誠實說明，可能被問到）

本專案的監控跑在 **Docker Desktop 單節點 K8s**，有兩個已知限制，皆為環境造成、
非設定錯誤：

1. **node-exporter 無法運作**：在 Docker Desktop on Windows 上，node-exporter
   需掛載宿主機檔案系統路徑（/proc、/sys），但 K8s 跑在 VM 內路徑對不上，
   pod 會 CrashLoopBackOff。已停用。影響：節點層級硬體指標（節點 CPU/記憶體
   使用率%）無法取得 —— 但單節點且在 VM 內，這些指標本就無參考價值。

2. **cAdvisor 容器即時資源指標抓不到**：同源問題，導致 per-pod 的即時 CPU/記憶體
   用量無資料，故移除該面板。

**標準答法**：
> 「我們是單節點、且跑在 Docker Desktop 的 VM 裡，節點與容器層級的即時資源
> 指標在這個環境抓不到，也沒有參考價值。我們監控的是與**高可用**直接相關的
> 指標 —— 副本數、複製狀態、DB failover、交易吞吐，這些都正常運作。」

> 補充：node-exporter / cAdvisor 在真正的多節點雲端叢集上可正常運作，
> 屆時資源使用率指標即可補齊；這純粹是本機單機環境的限制。
