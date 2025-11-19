# AI Processing Platform - System Architecture Design

> 系統設計面試作業 - AI 任務處理平台

## 📋 專案簡介

這是一個完整的 AI 處理平台系統架構設計，包含語音轉文字（STT）、大型語言模型（LLM）文字摘要，以及結果查詢等服務。本專案展示了高併發、可擴展、可維運的雲端原生架構設計。

## 📁 專案結構

```
ai_test_02/
├── ARCHITECTURE.md                    # 📖 完整架構設計文件
├── README.md                          # 本文件
├── docker-compose.yml                 # Docker Compose 配置
├── init-db.sql                        # 資料庫初始化腳本
├── demo.sh                            # 互動式 Demo 腳本
├── integrated_demo.sh                 # 自動化 Demo 腳本
├── harvard.wav                        # 測試音檔
│
├── services/
│   ├── api-service/                   # API 服務 (Node.js)
│   ├── stt-worker/                    # STT Worker (Python)
│   └── llm-worker/                    # LLM Worker (Python)
│
└── monitoring/                        # 監控配置
    ├── prometheus.yml
    └── grafana-datasources.yml
```

詳細架構設計請參閱 **[ARCHITECTURE.md](ARCHITECTURE.md)**

## 🚀 快速開始

### 前置需求

- Docker 20.10+
- Docker Compose 2.0+
- 至少 4GB 可用記憶體

### 啟動系統

有兩種啟動模式可選：

#### 模式 1: 基本模式（不含 MinIO，預設）

適合快速測試、開發環境。

```bash
# 1. 克隆專案
git clone <repository-url>
cd ai_test_02

# 2. 啟動基本服務（不含 MinIO）
docker-compose up -d
```

#### 模式 2: 完整模式（包含 MinIO）

支援真實檔案上傳功能。

```bash
# 1. 克隆專案
git clone <repository-url>
cd ai_test_02

# 2. 設定環境變數啟用 MinIO
export ENABLE_MINIO=true

# 3. 啟動所有服務（包含 MinIO）
docker-compose --profile minio up -d
```

**初始化 MinIO bucket**（僅首次需要）:
```bash
docker exec ai-platform-minio mc alias set myminio http://localhost:9000 admin admin123456
docker exec ai-platform-minio mc mb myminio/audio-files
docker exec ai-platform-minio mc anonymous set download myminio/audio-files
```

### 運行 Demo

```bash
# 互動式 Demo（逐步展示各個功能）
./demo.sh

# 自動化 Demo（完整流程自動執行，包含 MinIO 上傳）
./integrated_demo.sh
```

### 查看日誌與狀態

```bash
# 查看所有服務日誌
docker-compose logs -f

# 查看特定服務日誌
docker-compose logs -f api-service

# 檢查服務狀態
docker-compose ps
```

### 服務端點

| 服務 | URL | 說明 |
|------|-----|------|
| API Service | http://localhost:8080 | REST API 主服務 |
| MinIO Console | http://localhost:9001 | 物件儲存管理介面 (admin/admin123456) |
| MinIO API | http://localhost:9000 | S3 相容 API |
| RabbitMQ Management | http://localhost:15672 | 訊息佇列管理介面 (admin/admin123) |
| Prometheus | http://localhost:9090 | 指標收集與查詢 |
| Grafana | http://localhost:3000 | 監控儀表板 (admin/admin123) |
| PostgreSQL | localhost:5432 | 資料庫 (admin/admin123) |
| Redis | localhost:6379 | 快取服務 |

## 🧪 測試 API

### 1. 健康檢查

```bash
# 存活檢查
curl http://localhost:8080/health/live

# 就緒檢查（含依賴服務檢查）
curl http://localhost:8080/health/ready
```

### 2. 上傳音檔（新功能！）

```bash
# 上傳音檔到 MinIO
curl -X POST http://localhost:8080/api/v1/upload \
  -F "audio=@path/to/your/audio.mp3"
```

**回應範例**:
```json
{
  "success": true,
  "data": {
    "audio_url": "http://minio:9000/audio-files/audio/1234567890-audio.mp3",
    "public_url": "http://localhost:9000/audio-files/audio/1234567890-audio.mp3",
    "file_key": "audio/1234567890-audio.mp3",
    "size": 1024567,
    "mimetype": "audio/mpeg",
    "original_name": "audio.mp3"
  }
}
```

### 3. 創建任務（使用 MinIO 上傳的檔案）

```bash
# 先上傳檔案取得 audio_url
UPLOAD_RESPONSE=$(curl -s -X POST http://localhost:8080/api/v1/upload \
  -F "audio=@harvard.wav")
AUDIO_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.audio_url')

# 創建任務
curl -X POST http://localhost:8080/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d "{
    \"user_id\": \"00000000-0000-0000-0000-000000000001\",
    \"audio_url\": \"$AUDIO_URL\",
    \"audio_duration\": 30
  }"
```

### 4. 查詢任務狀態

```bash
# 替換 {task_id} 為實際的任務 ID
curl http://localhost:8080/api/v1/tasks/{task_id}
```

**回應範例**:
```json
{
  "success": true,
  "data": {
    "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "user_id": "00000000-0000-0000-0000-000000000001",
    "status": "completed",
    "audio_url": "https://example.com/audio/demo.mp3",
    "transcription": "Welcome to our AI processing platform...",
    "summary": "This audio discusses the AI processing platform's demo capabilities...",
    "created_at": "2024-11-14T12:10:00.000Z",
    "completed_at": "2024-11-14T12:10:15.000Z"
  },
  "cached": false
}
```

### 5. 列出所有任務

```bash
curl "http://localhost:8080/api/v1/tasks?user_id=00000000-0000-0000-0000-000000000001&limit=10"
```

### 6. 查看統計資訊

```bash
curl http://localhost:8080/api/v1/stats
```

**回應範例**:
```json
{
  "success": true,
  "data": {
    "completed": "5",
    "failed": "0",
    "pending": "2",
    "processing": "1",
    "total": "8",
    "avg_duration_seconds": "12.5"
  },
  "period": "last_24_hours"
}
```

## 🔍 監控與觀測

### Prometheus

訪問 http://localhost:9090 查看指標

**常用查詢**:
```promql
# API 請求速率
rate(http_requests_total[5m])

# 任務成功率
rate(tasks_total{status="completed"}[5m]) / rate(tasks_total[5m]) * 100

# API 延遲 P95
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

### Grafana

1. 訪問 http://localhost:3000
2. 登入 (admin/admin123)
3. 創建儀表板，使用上述 Prometheus 查詢

### RabbitMQ

訪問 http://localhost:15672 查看訊息佇列狀態

- 佇列深度
- 消費者數量
- 訊息處理速率

## 🔧 系統架構

### 核心組件

1. **API Service (Node.js)** - REST API、任務管理、快取層、MinIO 上傳
2. **STT Worker (Python)** - Mock 語音轉文字處理
3. **LLM Worker (Python)** - Mock 文字摘要處理
4. **PostgreSQL** - 任務狀態與結果持久化
5. **Redis** - 結果快取與限流
6. **RabbitMQ** - 非同步任務佇列
7. **MinIO** - S3 相容物件儲存（可選）

### 處理流程

```
使用者上傳 → MinIO (音檔儲存) → API Service → RabbitMQ (STT Queue)
                                       ↓
                                  PostgreSQL (任務記錄)

STT Worker ← RabbitMQ (STT Queue) → 處理語音轉文字 → PostgreSQL (STT 結果)
                                                          ↓
                                                   RabbitMQ (LLM Queue)

LLM Worker ← RabbitMQ (LLM Queue) → 處理文字摘要 → PostgreSQL + Redis (快取)
                                                          ↓
使用者查詢 ← API Service ← Redis/PostgreSQL
```

## 📊 效能測試

### 壓力測試範例

```bash
# 使用 Apache Bench 測試 API
ab -n 1000 -c 10 -p task.json -T application/json http://localhost:8080/api/v1/tasks

# 使用 wrk 測試
wrk -t4 -c100 -d30s http://localhost:8080/health/ready
```

### 預期效能

- API 回應時間: P95 < 200ms
- 任務處理時間: 5-15 秒 (STT + LLM)
- 吞吐量: 100+ 任務/分鐘 (單機)

## 🛠️ 開發與除錯

### 進入容器

```bash
# API Service
docker-compose exec api-service sh

# STT Worker
docker-compose exec stt-worker sh

# PostgreSQL
docker-compose exec postgres psql -U admin -d ai_platform
```

### 查看資料庫

```bash
docker-compose exec postgres psql -U admin -d ai_platform

# 查看任務
SELECT id, status, created_at FROM tasks ORDER BY created_at DESC LIMIT 10;

# 查看 STT 結果
SELECT task_id, LEFT(transcription, 50) as transcription_preview FROM stt_results;

# 查看 LLM 摘要
SELECT task_id, LEFT(summary, 50) as summary_preview FROM llm_summaries;
```

### 清理資料

```bash
# 停止並刪除所有容器
docker-compose down

# 刪除所有資料（包含 volumes）
docker-compose down -v

# 重新啟動
docker-compose up -d
```

## 🔧 故障排除 (Troubleshooting)

### 服務無法啟動

#### 問題: `docker-compose up` 失敗
```bash
# 1. 檢查 Docker 守護程序是否運行
docker info

# 2. 檢查端口是否被佔用
netstat -tulpn | grep -E '(5432|6379|5672|8080|3000|9090|15672)'
# macOS/Windows:
lsof -i :8080  # 檢查特定端口

# 3. 查看詳細錯誤日誌
docker-compose logs [service-name]

# 4. 重新構建服務
docker-compose build --no-cache
docker-compose up -d
```

#### 問題: .env 文件未找到
```bash
# 從範例創建 .env 文件
cp .env.example .env

# 編輯並更新密碼
vim .env  # 或使用你偏好的編輯器

# 使用 make 命令（推薦）
make setup
```

### 資料庫連接錯誤

#### 問題: `connection refused` 或資料庫無法連接
```bash
# 1. 檢查 PostgreSQL 是否健康
docker-compose exec postgres pg_isready -U admin

# 2. 查看 PostgreSQL 日誌
docker-compose logs postgres

# 3. 驗證連接字符串
echo $DATABASE_URL

# 4. 手動測試連接
docker-compose exec postgres psql -U admin -d ai_platform -c "SELECT 1;"

# 5. 重啟資料庫
docker-compose restart postgres
```

#### 問題: 資料庫初始化失敗
```bash
# 1. 查看初始化日誌
docker-compose logs postgres | grep -A 20 "init-db.sql"

# 2. 刪除並重新創建資料庫
docker-compose down postgres
docker volume rm ai_test_02_postgres_data
docker-compose up -d postgres

# 3. 使用 make 命令重置資料庫
make db-reset
```

### Worker 無法處理任務

#### 問題: 任務卡在 "pending" 狀態
```bash
# 1. 檢查 Worker 是否運行
docker-compose ps | grep worker

# 2. 查看 Worker 日誌
docker-compose logs stt-worker-1 stt-worker-2
docker-compose logs llm-worker-1 llm-worker-2

# 3. 檢查 RabbitMQ 佇列
# 訪問 http://localhost:15672 (admin/admin123)
# 查看佇列中的消息數和消費者數

# 4. 檢查佇列深度（CLI）
docker-compose exec rabbitmq rabbitmqctl list_queues

# 5. 重啟 Workers
docker-compose restart stt-worker-1 stt-worker-2 llm-worker-1 llm-worker-2
```

#### 問題: Workers 不斷重啟
```bash
# 1. 查看崩潰日誌
docker-compose logs --tail=100 stt-worker-1

# 2. 檢查資源使用
docker stats

# 3. 檢查依賴服務是否健康
docker-compose exec postgres pg_isready
docker-compose exec rabbitmq rabbitmq-diagnostics ping

# 4. 增加啟動延遲（臨時解決方案）
# 編輯 worker.py，增加 sleep 時間
```

### API 錯誤

#### 問題: 502 Bad Gateway 或 API 無回應
```bash
# 1. 檢查 API 服務狀態
docker-compose ps api-service

# 2. 查看 API 日誌
docker-compose logs -f api-service

# 3. 健康檢查
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready

# 4. 檢查依賴服務
make health

# 5. 重啟 API 服務
docker-compose restart api-service
```

#### 問題: 429 Too Many Requests (限流)
```bash
# 調整限流設置
# 編輯 .env 文件:
RATE_LIMIT_MAX_REQUESTS=1000  # 增加限制

# 重啟服務
docker-compose restart api-service
```

### Redis 連接問題

#### 問題: Redis connection refused
```bash
# 1. 檢查 Redis 是否運行
docker-compose ps redis

# 2. 測試 Redis 連接
docker-compose exec redis redis-cli ping
# 應該返回 "PONG"

# 3. 查看 Redis 日誌
docker-compose logs redis

# 4. 重啟 Redis
docker-compose restart redis
```

### RabbitMQ 問題

#### 問題: RabbitMQ Management UI 無法訪問
```bash
# 1. 檢查端口映射
docker-compose ps rabbitmq

# 2. 檢查防火牆
# Linux:
sudo ufw status
# macOS: 系統偏好設定 > 安全性與隱私 > 防火牆

# 3. 使用 CLI 檢查
docker-compose exec rabbitmq rabbitmqctl status

# 4. 訪問 URL
http://localhost:15672
# 帳號: admin
# 密碼: 查看 .env 中的 RABBITMQ_DEFAULT_PASS
```

### 記憶體/CPU 使用過高

#### 問題: 系統資源不足
```bash
# 1. 查看資源使用
docker stats

# 2. 減少 Worker 副本數
# 編輯 docker-compose.yml，減少 worker 數量

# 3. 調整資源限制
# 在 docker-compose.yml 中修改 deploy.resources.limits

# 4. 清理未使用的資源
docker system prune -a
docker volume prune

# 5. 增加 Docker Desktop 記憶體
# Docker Desktop > Settings > Resources > Memory
# 建議: 至少 4GB，推薦 8GB
```

### 日誌查看技巧

```bash
# 實時查看所有服務日誌
make logs

# 查看特定服務日誌
make logs SERVICE=api-service

# 查看最近 100 行日誌
docker-compose logs --tail=100 api-service

# 查看錯誤日誌
docker-compose logs | grep -i error

# 查看時間戳日誌
docker-compose logs -t api-service

# 導出日誌到文件
docker-compose logs > logs.txt
```

### 常見錯誤訊息

| 錯誤訊息 | 原因 | 解決方案 |
|---------|-----|---------|
| `ECONNREFUSED` | 服務未啟動或端口錯誤 | 檢查服務狀態，驗證端口配置 |
| `EADDRINUSE` | 端口已被佔用 | 關閉佔用端口的程序或更改端口 |
| `no space left on device` | 磁盤空間不足 | 清理 Docker 資源: `docker system prune -a` |
| `connection timeout` | 網路問題或服務響應慢 | 增加超時時間，檢查網路連接 |
| `permission denied` | 文件權限問題 | 修改文件權限: `chmod +x script.sh` |
| `database "ai_platform" does not exist` | 資料庫未初始化 | 重啟 postgres: `make db-reset` |

### 性能優化建議

```bash
# 1. 清理舊的容器和映像
docker system prune -a --volumes

# 2. 使用 BuildKit 加速構建
export DOCKER_BUILDKIT=1
docker-compose build

# 3. 增加資料庫連接池
# 編輯 services/api-service/index.js
# 修改 Pool 的 max 值

# 4. 啟用 Redis 持久化
# 編輯 docker-compose.yml
# 修改 redis command 參數

# 5. 監控資源使用
make health
docker stats
```

### 需要進一步協助？

如果以上解決方案無法解決問題:

1. **查看完整日誌**: `docker-compose logs > debug.log`
2. **檢查環境變數**: `docker-compose config`
3. **驗證 Docker 版本**: `docker version && docker-compose version`
4. **重新開始**: `make clean && make up`
5. **提交 Issue**: 附上錯誤日誌和系統資訊

## 📖 完整架構文件

請參閱 [ARCHITECTURE.md](ARCHITECTURE.md) 獲取完整的系統架構設計，包含:

- ✅ 詳細架構圖 (Mermaid)
- ✅ 任務循序圖
- ✅ 技術選型與理由
- ✅ 可擴展性設計
- ✅ 容錯機制
- ✅ 安全性考量
- ✅ 監控與可觀測性
- ✅ 部署拓撲 (Dev/Staging/Prod)
- ✅ CI/CD 流程
- ✅ 成本優化策略

## 🎯 架構亮點

### 1. 雲端原生設計
- 容器化部署 (Docker)
- 微服務架構
- 水平擴展能力
- 服務間解耦

### 2. 高可用性
- 多副本部署
- 健康檢查與自動重啟
- 資料備份與恢復
- 優雅關閉 (Graceful Shutdown)

### 3. 可觀測性
- Prometheus 指標收集
- Grafana 視覺化
- 結構化日誌
- 分散式追蹤就緒

### 4. 效能優化
- Redis 快取層
- 資料庫索引優化
- 非同步任務處理
- 連接池管理

### 5. 安全性
- 輸入驗證
- SQL Injection 防護
- 錯誤處理
- 敏感資訊保護

## 🔜 未來擴展

### 短期目標
- [ ] 整合真實 STT API (Whisper/Google STT)
- [ ] 整合真實 LLM API (GPT-4/Claude)
- [ ] 實作檔案上傳 (S3/MinIO)
- [ ] 新增 JWT 認證
- [ ] 實作限流機制

### 長期目標
- [ ] Kubernetes 部署
- [ ] Service Mesh (Istio)
- [ ] 分散式追蹤 (Jaeger)
- [ ] ELK Stack 日誌聚合
- [ ] 多租戶支援
- [ ] WebSocket 即時推送

## 🤝 貢獻

歡迎提出 Issue 或 Pull Request！

## 📄 授權

MIT License

## 👥 作者

AI Platform Architecture Team

---

**注意**: 這是一個 Demo 專案，用於系統設計面試展示。在生產環境使用前，請務必:
- 更換所有預設密碼
- 啟用 HTTPS/TLS
- 實作完整的認證授權
- 設定適當的資源限制
- 進行安全性稽核
- 設定資料備份策略
