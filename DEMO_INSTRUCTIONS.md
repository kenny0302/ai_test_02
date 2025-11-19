# 🎯 Demo 執行指南

## ⚠️  重要修正

### UUID 驗證問題修正

`integrated_demo.sh` 腳本使用的 UUID `00000000-0000-0000-0000-000000000001` 無法通過 API 驗證。

**解決方案有兩種:**

### 方案 1: 修改 Demo 腳本 (推薦)

移除 `user_id` 參數,讓 API 使用預設用戶:

```bash
# 修改 integrated_demo.sh 中的任務創建請求
# 從:
curl -X POST http://localhost:8080/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d "{
    \"user_id\": \"00000000-0000-0000-0000-000000000001\",
    \"audio_url\": \"$AUDIO_URL\",
    \"audio_duration\": $AUDIO_DURATION
  }"

# 改為:
curl -X POST http://localhost:8080/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d "{
    \"audio_url\": \"$AUDIO_URL\",
    \"audio_duration\": $AUDIO_DURATION
  }"
```

### 方案 2: 使用有效的 UUID 格式

使用標準 UUID 格式:

```bash
# 在 Demo 腳本中使用
USER_ID="550e8400-e29b-41d4-a716-446655440000"
```

---

## 🚀 重新運行 Demo 的完整步驟

### 1. 確保所有服務正常運行

```bash
# 檢查服務狀態
docker-compose ps

# 如果有服務停止,重啟它們
docker-compose up -d
```

### 2. 檢查 RabbitMQ 連線

當 RabbitMQ 重啟後,API Service 和 Workers 需要重新連線:

```bash
# 重啟所有依賴 RabbitMQ 的服務
docker-compose restart api-service stt-worker-1 stt-worker-2 llm-worker-1 llm-worker-2

# 等待服務啟動 (約 10 秒)
sleep 10

# 驗證 API Service 已連線
docker logs ai-platform-api --tail 20 | grep "RabbitMQ connected"
```

### 3. 修正 Demo 腳本後執行

```bash
# 修改 integrated_demo.sh (移除 user_id 或使用有效 UUID)
# 然後執行
./integrated_demo.sh
```

---

## ✅ 手動測試完整流程

如果 Demo 腳本有問題,可以手動執行以下步驟:

### 步驟 1: 上傳音檔

```bash
UPLOAD_RESPONSE=$(curl -s -X POST http://localhost:8080/api/v1/upload \
  -F "audio=@harvard.wav")

echo "$UPLOAD_RESPONSE" | jq

# 提取 audio_url
AUDIO_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.audio_url')
echo "Audio URL: $AUDIO_URL"
```

### 步驟 2: 創建任務

```bash
TASK_RESPONSE=$(curl -s -X POST http://localhost:8080/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d "{
    \"audio_url\": \"$AUDIO_URL\",
    \"audio_duration\": 3
  }")

echo "$TASK_RESPONSE" | jq

# 提取 task_id
TASK_ID=$(echo "$TASK_RESPONSE" | jq -r '.data.task_id')
echo "Task ID: $TASK_ID"
```

### 步驟 3: 等待處理完成

```bash
# STT 處理約需 6-10 秒
# LLM 處理約需 8-12 秒
# 總計約 15-25 秒

echo "等待處理完成..."
for i in {1..30}; do
    echo "檢查第 $i 次..."
    STATUS=$(curl -s http://localhost:8080/api/v1/tasks/$TASK_ID | jq -r '.data.status')
    echo "狀態: $STATUS"

    if [ "$STATUS" == "completed" ]; then
        echo "✅ 任務完成!"
        break
    elif [ "$STATUS" == "failed" ]; then
        echo "❌ 任務失敗"
        curl -s http://localhost:8080/api/v1/tasks/$TASK_ID | jq '.data.error_message'
        break
    fi

    sleep 2
done
```

### 步驟 4: 查看結果

```bash
curl -s http://localhost:8080/api/v1/tasks/$TASK_ID | jq '{
  status: .data.status,
  transcription: .data.transcription,
  summary: .data.summary,
  language: .data.language,
  model_name: .data.model_name,
  tokens_used: .data.tokens_used
}'
```

---

## 🎯 成功運行的預期結果

### 轉錄結果 (OpenAI Whisper)

```
The stale smell of old beer lingers. It takes heat to bring out the odor.
A cold dip restores health and zest. A salt pickle tastes fine with ham.
Tacos al pastor are my favorite. A zestful food is the hot cross bun.
```

### 摘要結果 (GPT-4)

```
Summary: The speaker discusses various sensory experiences related to
food and drink, ranging from the stale smell of old beer to the enjoyment
of tacos al pastor and hot cross buns.

Key Points:
- The speaker mentions the lingering smell of old beer, which is more
  pronounced in heat.
- Cold dips are associated with restoration of health and zest.
- The speaker enjoys the combination of salt pickles and ham.
- Tacos al pastor is a favorite dish of the speaker.
- Hot cross buns are considered a zestful food.
```

### 處理時間

- **STT 處理**: ~6-10 秒 (OpenAI Whisper API)
- **LLM 處理**: ~8-12 秒 (GPT-4 API)
- **總時間**: ~15-25 秒

### Token 使用

- **約 200-250 tokens** (GPT-4)

---

## 🔍 故障排查

### 問題 1: 任務創建失敗 "Channel closed"

**原因:** RabbitMQ 連線斷開

**解決:**
```bash
docker-compose restart api-service stt-worker-1 stt-worker-2 llm-worker-1 llm-worker-2
sleep 10
```

### 問題 2: UUID 驗證錯誤

**錯誤訊息:**
```json
{
  "success": false,
  "errors": [{
    "field": "user_id",
    "message": "user_id must be a valid UUID"
  }]
}
```

**解決:** 移除 `user_id` 參數或使用有效的 UUID 格式

### 問題 3: "No module named 'requests'"

**原因:** Worker 容器重建後依賴未安裝

**解決:**
```bash
# 重建 workers
docker-compose up -d --build stt-worker-1 stt-worker-2 llm-worker-1 llm-worker-2
```

### 問題 4: OpenAI API 錯誤

**檢查 API Key:**
```bash
grep OPENAI_API_KEY .env
```

**確認 Mock 模式已關閉:**
```bash
grep MOCK_ .env
# 應該顯示:
# MOCK_STT_SERVICE=false
# MOCK_LLM_SERVICE=false
```

---

## 📊 監控處理流程

### 查看 Worker 日誌

```bash
# STT Worker
docker logs ai_test_02-stt-worker-1-1 --tail 50 -f

# LLM Worker
docker logs ai_test_02-llm-worker-1-1 --tail 50 -f

# API Service
docker logs ai-platform-api --tail 50 -f
```

### 查看 RabbitMQ 佇列

訪問: http://localhost:15672
- 帳號: `admin`
- 密碼: `change-me-in-production-use-strong-password`

### 查看 Grafana 儀表板

訪問: http://localhost:3000
- 帳號: `admin`
- 密碼: `admin123`

---

## 🎉 快速驗證指令

一鍵測試完整流程:

```bash
# 上傳 + 創建任務 + 等待完成
AUDIO_URL=$(curl -s -X POST http://localhost:8080/api/v1/upload -F "audio=@harvard.wav" | jq -r '.data.audio_url') && \
TASK_ID=$(curl -s -X POST http://localhost:8080/api/v1/tasks -H "Content-Type: application/json" -d "{\"audio_url\":\"$AUDIO_URL\",\"audio_duration\":3}" | jq -r '.data.task_id') && \
echo "Task ID: $TASK_ID" && \
sleep 20 && \
curl -s http://localhost:8080/api/v1/tasks/$TASK_ID | jq '{status: .data.status, transcription: .data.transcription, summary: .data.summary}'
```

---

## 📝 注意事項

1. ✅ 確保 `.env` 中的 `OPENAI_API_KEY` 已設置
2. ✅ 確保 `MOCK_STT_SERVICE=false` 和 `MOCK_LLM_SERVICE=false`
3. ✅ 每次重啟 RabbitMQ 後都要重啟 API Service 和 Workers
4. ✅ OpenAI API 調用會產生費用 (Whisper + GPT-4)
5. ✅ 處理時間取決於網路速度和 OpenAI API 負載
6. ⚠️  Demo 腳本的 UUID 需要修正後才能正常運行
