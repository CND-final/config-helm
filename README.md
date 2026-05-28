# config-man Helm Chart

部署 config-man 系統（backend、frontend、postgres）到 Kubernetes。

## 快速上手

### 步驟 1：安裝 chart

```bash
# 設定 postgres 密碼並安裝
helm install config-man . \
  --set postgres.credentials.password=your-secure-password \
  --namespace default

# 或用 values override 檔
cp values.yaml my-values.yaml
# 編輯 my-values.yaml，填入 postgres.credentials.password
helm install config-man . -f my-values.yaml
```

> **注意**：`postgres.credentials.password` 必須明確設定，chart 預設值為 `CHANGE_ME`，部署到正式環境前請務必替換。

### 步驟 2：驗證部署

```bash
# 確認所有 pod 運行中
kubectl get pods -l app.kubernetes.io/instance=config-man

# 確認 services
kubectl get svc -l app.kubernetes.io/instance=config-man

# 確認 PDB 已套用
kubectl get pdb -l app.kubernetes.io/instance=config-man

# 瀏覽 frontend（NodePort 30080）
# Docker Desktop: http://localhost:30080

# 確認 backend health
kubectl port-forward svc/config-man-backend 3000:3000
curl http://localhost:3000/api/v1/health
```

### 步驟 3：HA demo（驗證服務不中斷）

```bash
# 在另一個 terminal 持續打 health check
while true; do curl -s http://localhost:30080 > /dev/null && echo "OK $(date)" || echo "FAIL $(date)"; sleep 1; done

# 刪掉一個 backend pod，觀察 K8s 自動重建、服務不中斷
kubectl delete pod -l app.kubernetes.io/component=backend --wait=false

# 看 pod 重建過程
kubectl get pods -l app.kubernetes.io/component=backend -w

# PDB 保護：嘗試 drain node（應被 PDB 阻擋直到有足夠健康 pod）
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

## Secret 說明

`templates/secret.yaml` 產生的 Secret 包含：

| Key               | 說明                         | 預設值       |
|-------------------|------------------------------|--------------|
| `POSTGRES_PASSWORD` | Postgres 密碼              | `CHANGE_ME`  |
| `DB_HOST`         | Postgres service DNS 名稱    | 自動產生     |
| `DB_PORT`         | Postgres port                | `5432`       |
| `DB_NAME`         | 資料庫名稱                   | `configman`  |
| `DB_USER`         | 資料庫使用者                 | `configman`  |

部署時透過 `--set postgres.credentials.password=<your-password>` 設定密碼，勿將明文密碼提交進 git。

## 解除安裝

```bash
helm uninstall config-man

# PVC 不會自動刪除（保護資料），需手動清理
kubectl delete pvc config-man-postgres-pvc
```
