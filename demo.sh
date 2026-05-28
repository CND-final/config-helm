#!/bin/bash
# HA Demo Script - config-man
# 展示：kill pod 後服務不死

set -e
NS=config-man

echo "=== 目前 pod 狀態 ==="
kubectl get pods -n $NS

echo ""
echo "=== 開始 HA demo ==="

echo ""
echo "--- [1] 確認 backend health ---"
kubectl port-forward svc/config-man-backend 3000:3000 -n $NS &
PF_PID=$!
sleep 2
curl -s http://localhost:3000/api/v1/health
kill $PF_PID 2>/dev/null

echo ""
echo "--- [2] 刪掉一個 backend pod ---"
BACKEND_POD=$(kubectl get pods -n $NS -l app.kubernetes.io/component=backend -o jsonpath='{.items[0].metadata.name}')
echo "刪除: $BACKEND_POD"
kubectl delete pod $BACKEND_POD -n $NS

echo ""
echo "--- [3] 觀察 K8s 自動補回 pod ---"
kubectl get pods -n $NS -w &
WATCH_PID=$!
sleep 15
kill $WATCH_PID 2>/dev/null

echo ""
echo "--- [4] 確認服務仍然存活 ---"
kubectl port-forward svc/config-man-backend 3000:3000 -n $NS &
PF_PID=$!
sleep 2
curl -s http://localhost:3000/api/v1/health
kill $PF_PID 2>/dev/null

echo ""
echo "--- [5] 刪掉 postgres primary，觀察 failover ---"
echo "刪除: config-man-postgres-0 (primary)"
kubectl delete pod config-man-postgres-0 -n $NS
echo "等待 standby 升為 primary（約 30 秒）..."
sleep 30
kubectl get pods -n $NS

echo ""
echo "--- [6] 確認 backend 仍可連線 ---"
kubectl port-forward svc/config-man-backend 3000:3000 -n $NS &
PF_PID=$!
sleep 2
curl -s http://localhost:3000/api/v1/health
kill $PF_PID 2>/dev/null

echo ""
echo "=== Demo 完成：pod 死了，服務沒死 ==="
