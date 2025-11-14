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
│
├── services/
│   ├── api-service/                   # API 服務 (Node.js)
│   │   ├── Dockerfile
│   │   ├── package.json
│   │   └── index.js
│   │
│   ├── stt-worker/                    # STT Worker (Python)
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── worker.py
│   │
│   └── llm-worker/                    # LLM Worker (Python)
│       ├── Dockerfile
│       ├── requirements.txt
│       └── worker.py
│
└── monitoring/                        # 監控配置
    ├── prometheus.yml                 # Prometheus 配置
    └── grafana-datasources.yml        # Grafana 資料源
```

## 🚀 快速開始

### 前置需求

- Docker 20.10+
- Docker Compose 2.0+
- 至少 4GB 可用記憶體

### 啟動系統

1. **克隆專案**
```bash
git clone <repository-url>
cd ai_test_02
```

2. **啟動所有服務**
```bash
docker-compose up -d
```

3. **查看日誌**
```bash
# 查看所有服務日誌
docker-compose logs -f

# 查看特定服務日誌
docker-compose logs -f api-service
docker-compose logs -f stt-worker
docker-compose logs -f llm-worker
```

4. **檢查服務狀態**
```bash
docker-compose ps
```

### 服務端點

| 服務 | URL | 說明 |
|------|-----|------|
| API Service | http://localhost:8080 | REST API 主服務 |
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

### 2. 創建任務

```bash
curl -X POST http://localhost:8080/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "00000000-0000-0000-0000-000000000001",
    "audio_url": "https://example.com/audio/demo.mp3",
    "audio_duration": 60
  }'
```

**回應範例**:
```json
{
  "success": true,
  "data": {
    "task_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "status": "pending",
    "status_url": "/api/v1/tasks/f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "estimated_completion_time": "2024-11-14T12:12:00.000Z"
  }
}
```

### 3. 查詢任務狀態

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

### 4. 列出所有任務

```bash
curl "http://localhost:8080/api/v1/tasks?user_id=00000000-0000-0000-0000-000000000001&limit=10"
```

### 5. 查看統計資訊

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

1. **API Service (Node.js)**
   - REST API 端點
   - 任務建立與狀態管理
   - 快取層 (Redis)
   - 訊息發布 (RabbitMQ)

2. **STT Worker (Python)**
   - 從佇列消費 STT 任務
   - Mock 語音轉文字處理
   - 結果儲存與傳遞

3. **LLM Worker (Python)**
   - 從佇列消費 LLM 任務
   - Mock 文字摘要處理
   - 最終結果儲存

4. **PostgreSQL**
   - 任務狀態持久化
   - STT 與 LLM 結果儲存
   - 事務處理

5. **Redis**
   - 任務結果快取
   - 限流計數器
   - Session 管理

6. **RabbitMQ**
   - 非同步任務佇列
   - 服務解耦
   - 流量削峰

### 處理流程

```
使用者請求 → API Service → RabbitMQ (STT Queue)
                ↓
           PostgreSQL (任務記錄)

STT Worker ← RabbitMQ (STT Queue)
    ↓
處理語音轉文字
    ↓
PostgreSQL (STT 結果) → RabbitMQ (LLM Queue)

LLM Worker ← RabbitMQ (LLM Queue)
    ↓
處理文字摘要
    ↓
PostgreSQL (LLM 結果) + Redis (快取)
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
