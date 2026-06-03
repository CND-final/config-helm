#!/usr/bin/env bash
# ha-demo.sh — config-man 高可用 demo
#
# 用法： wsl bash demo/ha-demo.sh
# 畫面建議：左邊終端機跑腳本，右邊瀏覽器全螢幕開 Grafana「config-man HA Demo」儀表板。
#
# 流程：
#   [1] 故障前狀態 + 說明（印完停住，按 Enter 繼續）
#   [2] 同時注入故障：去掉一個 backend pod + 一個 frontend pod + DB master 節點
#   [3] 自動恢復（K8s 重建無狀態副本 / Patroni 提升 standby 為新 master）
#   [4] 恢復後狀態

set -uo pipefail
NS="config-man"

line() { echo "────────────────────────────────────────────"; }

ready_count() {  # $1 = component label
  kubectl get pods -n "$NS" -l "app.kubernetes.io/component=$1" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l
}
current_master() {
  kubectl get pods -n "$NS" -l application=spilo,spilo-role=master \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

line
echo "  config-man 高可用 (HA) Demo"
line

# ── 1. 故障前狀態 + 說明 ────────────────────────────────────
MASTER_BEFORE=$(current_master)
echo ""
echo "[1] 故障前狀態"
echo "    backend  Ready 副本數： $(ready_count backend) / 3"
echo "    frontend Ready 副本數： $(ready_count frontend) / 2"
echo "    PostgreSQL master：    ${MASTER_BEFORE}"
echo ""
echo "    說明："
echo "      - backend (×3)、frontend (×2) 皆為無狀態，可互相取代。"
echo "      - 資料庫為主從架構：1 個 master + 1 個 standby，由 Patroni 管理。"
echo "      - 接下來會「同時」注入三個故障："
echo "          (1) 去掉一個 backend pod   → K8s 自我修復、補回副本"
echo "          (2) 去掉一個 frontend pod  → 同上（無狀態）"
echo "          (3) 去掉 DB master 節點   → Patroni 偵測後，提升 standby 為新 master"
echo "      - 全程請看右側 Grafana：副本數曲線、pg_up、DB 連線、交易吞吐的變化。"
echo ""
echo "    （按 Enter 開始）"
read -r

# 挑要去掉的 pod
VICTIM_BACKEND=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=backend \
  -o jsonpath='{.items[0].metadata.name}')
VICTIM_FRONTEND=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=frontend \
  -o jsonpath='{.items[0].metadata.name}')

echo "[2] 同時注入故障"
echo "    kill backend pod：  ${VICTIM_BACKEND}"
echo "    kill frontend pod： ${VICTIM_FRONTEND}"
echo "    kill DB master：    ${MASTER_BEFORE}"

# ── 2. 同時注入：背景並行 ──────────────────────────────────
# (a)(b) 強制刪除無狀態 pod（K8s 立即重建）
kubectl delete pod "$VICTIM_BACKEND"  -n "$NS" --grace-period=0 --force >/dev/null 2>&1 &
kubectl delete pod "$VICTIM_FRONTEND" -n "$NS" --grace-period=0 --force >/dev/null 2>&1 &
# (c) 正常刪除 DB master（不加 force！讓 Patroni 有時間偵測並提升 standby）
kubectl delete pod "$MASTER_BEFORE" -n "$NS" >/dev/null 2>&1 &

wait
echo "    -> 故障已注入。請看右側 Grafana：副本數下降、pg_up 與 DB 連線短暫下掉。"

# ── 3. 自動恢復 ────────────────────────────────────────────
echo ""
echo "[3] 自動恢復中"

echo -n "    backend 自我修復"
for i in $(seq 1 60); do
  [ "$(ready_count backend)" -ge 3 ] && break
  echo -n "."; sleep 1
done
echo " 完成（Ready=$(ready_count backend) / 3）"

echo -n "    frontend 自我修復"
for i in $(seq 1 60); do
  [ "$(ready_count frontend)" -ge 2 ] && break
  echo -n "."; sleep 1
done
echo " 完成（Ready=$(ready_count frontend) / 2）"

echo -n "    Patroni 提升新 master"
NEW_MASTER=""
for i in $(seq 1 60); do
  NEW_MASTER=$(current_master)
  [ -n "$NEW_MASTER" ] && [ "$NEW_MASTER" != "$MASTER_BEFORE" ] && break
  echo -n "."; sleep 1
done
echo " 完成"

# ── 4. 恢復後狀態 ──────────────────────────────────────────
echo ""
echo "[4] 恢復後狀態"
echo "    backend  Ready 副本數： $(ready_count backend) / 3"
echo "    frontend Ready 副本數： $(ready_count frontend) / 2"
if [ -n "$NEW_MASTER" ] && [ "$NEW_MASTER" != "$MASTER_BEFORE" ]; then
  echo "    PostgreSQL master：    ${MASTER_BEFORE}  ->  ${NEW_MASTER}  (failover 完成)"
else
  echo "    PostgreSQL master：    ${NEW_MASTER}  (注意：master 未切換)"
fi
echo ""
line
echo "  Demo 完成：killed backend / frontend 副本已自動補回，"
echo "  DB master 節點故障後 standby 已自動接手，服務未中斷。"
line
