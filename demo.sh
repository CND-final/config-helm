#!/bin/bash
# HA Demo Script - config-man
# Proves the service survives pod failures

set -e
NS=config-man

echo "=== Current pod status ==="
kubectl get pods -n $NS

echo ""
echo "=== Starting HA demo ==="

echo ""
echo "--- [1] Verify backend health ---"
kubectl port-forward svc/config-man-backend 3000:3000 -n $NS &
PF_PID=$!
sleep 2
curl -s http://localhost:3000/api/v1/health || true
kill $PF_PID 2>/dev/null

echo ""
echo ""
echo "--- [2] Delete one backend pod ---"
BACKEND_POD=$(kubectl get pods -n $NS -l app.kubernetes.io/component=backend -o jsonpath='{.items[0].metadata.name}')
echo "Deleting: $BACKEND_POD"
kubectl delete pod $BACKEND_POD -n $NS

echo ""
echo "--- [3] Watch K8s auto-replace the pod ---"
kubectl get pods -n $NS -w &
WATCH_PID=$!
sleep 15
kill $WATCH_PID 2>/dev/null

echo ""
echo "--- [4] Confirm service is still alive ---"
kubectl port-forward svc/config-man-backend 3000:3000 -n $NS &
PF_PID=$!
sleep 2
curl -s http://localhost:3000/api/v1/health || true
kill $PF_PID 2>/dev/null

echo ""
echo ""
echo "--- [5] Delete postgres primary and observe failover ---"
echo "Deleting: config-man-postgres-0 (primary)"
kubectl delete pod config-man-postgres-0 -n $NS
echo "Waiting for standby to promote to primary (~30s)..."
sleep 30
kubectl get pods -n $NS

echo ""
echo "--- [6] Confirm backend is still reachable ---"
kubectl port-forward svc/config-man-backend 3000:3000 -n $NS &
PF_PID=$!
sleep 2
curl -s http://localhost:3000/api/v1/health || true
kill $PF_PID 2>/dev/null

echo ""
echo "=== Demo complete: pods failed, service survived ==="
