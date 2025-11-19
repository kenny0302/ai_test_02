#!/bin/bash
# AI Processing Platform - 整合式 Demo 腳本
# 自動執行完整流程，無需手動按鍵

set -e

# 配置
API_URL="http://localhost:8080"
RABBITMQ_URL="http://localhost:15672"
PROMETHEUS_URL="http://localhost:9090"
GRAFANA_URL="http://localhost:3000"
MINIO_CONSOLE="http://localhost:9001"

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

LINE="================================================================"

# 打印函數
print_header() {
    echo -e "\n${CYAN}${LINE}${NC}"
    echo -e "${WHITE}$1${NC}"
    echo -e "${CYAN}${LINE}${NC}"
}

print_step() {
    echo -e "\n${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

# 檢查依賴
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        print_error "未安裝 jq"
        echo "請安裝 jq: brew install jq (macOS) 或 apt-get install jq (Linux)"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        print_error "未安裝 curl"
        exit 1
    fi
}

# 生成 UUID v4
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        echo ""
    fi
}

# 創建任務
create_task() {
    local user_id=${1:-$(generate_uuid)}
    local audio_url=${2:-"https://example.com/demo/sample-audio.mp3"}
    local audio_duration=${3:-120}

    if [ -z "$user_id" ]; then
        RESPONSE=$(curl -s -X POST "$API_URL/api/v1/tasks" \
            -H "Content-Type: application/json" \
            -d "{
                \"audio_url\": \"$audio_url\",
                \"audio_duration\": $audio_duration
            }")
    else
        RESPONSE=$(curl -s -X POST "$API_URL/api/v1/tasks" \
            -H "Content-Type: application/json" \
            -d "{
                \"user_id\": \"$user_id\",
                \"audio_url\": \"$audio_url\",
                \"audio_duration\": $audio_duration
            }")
    fi

    TASK_ID=$(echo "$RESPONSE" | jq -r '.data.task_id')

    if [ "$TASK_ID" != "null" ] && [ -n "$TASK_ID" ]; then
        echo "$TASK_ID"
        return 0
    else
        echo "$RESPONSE" | jq . >&2
        return 1
    fi
}

# 查詢任務狀態
get_task_status() {
    local task_id=$1
    curl -s "$API_URL/api/v1/tasks/$task_id" | jq -r '.data.status'
}

# 查詢完整任務資訊
get_task_info() {
    local task_id=$1
    curl -s "$API_URL/api/v1/tasks/$task_id"
}

# 監控任務進度
monitor_task() {
    local task_id=$1
    local max_wait=${2:-60}
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        STATUS=$(get_task_status "$task_id")

        case "$STATUS" in
            "pending")
                echo -ne "${YELLOW}⏳ 狀態: pending${NC}\r"
                ;;
            "processing_stt")
                echo -ne "${BLUE}🎤 狀態: processing_stt${NC}\r"
                ;;
            "stt_completed")
                echo -ne "${CYAN}📝 狀態: stt_completed${NC}\r"
                ;;
            "processing_llm")
                echo -ne "${MAGENTA}🤖 狀態: processing_llm${NC}\r"
                ;;
            "completed")
                echo -ne "\n"
                print_success "任務完成! 總耗時: ${elapsed}秒"
                return 0
                ;;
            "failed")
                echo -ne "\n"
                print_error "任務失敗"
                return 1
                ;;
            *)
                echo -ne "${RED}❓ 狀態: $STATUS${NC}\r"
                ;;
        esac

        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo -ne "\n"
    print_warning "監控超時"
    return 1
}

# ============================================================================
# 整合流程：自動執行所有步驟
# ============================================================================

integrated_demo() {
    print_header "🚀 AI Processing Platform - 整合式自動化 Demo"

    echo -e "${WHITE}此 Demo 將自動執行以下步驟:${NC}"
    echo "  1️⃣  系統健康檢查"
    echo "  2️⃣  MinIO 檔案上傳 + 完整處理流程 (使用 harvard.wav)"
    echo "  3️⃣  批量任務處理（5個並發）"
    echo "  4️⃣  系統統計資訊"
    echo "  5️⃣  任務概覽"
    echo ""

    # ========================================================================
    # 步驟 1: 健康檢查
    # ========================================================================
    print_header "步驟 1/6: 系統健康檢查"

    print_step "檢查 API Service..."
    if curl -s "$API_URL/health/live" > /dev/null 2>&1; then
        LIVE_RESPONSE=$(curl -s "$API_URL/health/live" | jq -r '.status')
        if [ "$LIVE_RESPONSE" = "ok" ]; then
            print_success "API Service 運行正常"
        else
            print_error "API Service 狀態異常"
            exit 1
        fi
    else
        print_error "無法連接到 API Service"
        exit 1
    fi

    print_step "檢查依賴服務..."
    READY_RESPONSE=$(curl -s "$API_URL/health/ready")

    DB_STATUS=$(echo "$READY_RESPONSE" | jq -r '.checks.database')
    REDIS_STATUS=$(echo "$READY_RESPONSE" | jq -r '.checks.redis')
    RABBITMQ_STATUS=$(echo "$READY_RESPONSE" | jq -r '.checks.rabbitmq')

    echo -e "  Database: ${GREEN}$DB_STATUS${NC}"
    echo -e "  Redis: ${GREEN}$REDIS_STATUS${NC}"
    echo -e "  RabbitMQ: ${GREEN}$RABBITMQ_STATUS${NC}"

    if [ "$DB_STATUS" = "ok" ] && [ "$REDIS_STATUS" = "ok" ] && [ "$RABBITMQ_STATUS" = "ok" ]; then
        print_success "所有依賴服務正常"
    else
        print_warning "部分依賴服務可能有問題"
    fi

    sleep 2

    # ========================================================================
    # 步驟 2: MinIO 檔案上傳 + 完整處理流程
    # ========================================================================
    print_header "步驟 2/5: MinIO 檔案上傳 + 完整處理流程 (harvard.wav)"

    # 檢查音檔是否存在
    local audio_file=""
    if [ -f "./harvard.wav" ]; then
        audio_file="./harvard.wav"
    elif [ -f "./test.mp3" ]; then
        audio_file="./test.mp3"
    elif [ -f "./sample.mp3" ]; then
        audio_file="./sample.mp3"
    fi

    if [ -n "$audio_file" ]; then
        print_info "找到音檔: $audio_file"

        # 顯示檔案資訊
        if command -v ls &> /dev/null; then
            local file_size=$(ls -lh "$audio_file" | awk '{print $5}')
            print_info "檔案大小: $file_size"
        fi

        # 上傳檔案
        print_step "步驟 1/4: 上傳音檔到 MinIO..."
        UPLOAD_RESPONSE=$(curl -s -X POST "$API_URL/api/v1/upload" \
            -F "audio=@$audio_file")

        UPLOAD_SUCCESS=$(echo "$UPLOAD_RESPONSE" | jq -r '.success')

        if [ "$UPLOAD_SUCCESS" = "true" ]; then
            print_success "音檔上傳成功"

            AUDIO_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.audio_url')
            FILE_KEY=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.file_key')

            echo -e "  📦 File Key: ${CYAN}$FILE_KEY${NC}"
            echo -e "  🔗 Audio URL: ${CYAN}$AUDIO_URL${NC}"

            # 創建處理任務
            print_step "步驟 2/4: 創建 STT 處理任務..."
            TASK_RESPONSE=$(curl -s -X POST "$API_URL/api/v1/tasks" \
                -H "Content-Type: application/json" \
                -d "{
                    \"audio_url\": \"$AUDIO_URL\",
                    \"audio_duration\": 30
                }")

            MINIO_TASK_ID=$(echo "$TASK_RESPONSE" | jq -r '.data.task_id')

            if [ -n "$MINIO_TASK_ID" ] && [ "$MINIO_TASK_ID" != "null" ]; then
                print_success "任務已創建"
                print_info "Task ID: $MINIO_TASK_ID"

                print_step "步驟 3/4: 監控任務處理 (STT → LLM)..."
                if monitor_task "$MINIO_TASK_ID" 90; then
                    print_step "步驟 4/4: 查詢處理結果..."
                    TASK_INFO=$(get_task_info "$MINIO_TASK_ID")

                    TRANSCRIPTION=$(echo "$TASK_INFO" | jq -r '.data.transcription')
                    SUMMARY=$(echo "$TASK_INFO" | jq -r '.data.summary')
                    CONFIDENCE=$(echo "$TASK_INFO" | jq -r '.data.confidence')

                    echo -e "\n${WHITE}處理結果:${NC}"
                    echo "$TASK_INFO" | jq '{
                        id: .data.id,
                        status: .data.status,
                        audio_url: .data.audio_url,
                        confidence: .data.confidence,
                        language: .data.language,
                        created_at: .data.created_at,
                        completed_at: .data.completed_at
                    }'

                    if [ -n "$TRANSCRIPTION" ] && [ "$TRANSCRIPTION" != "null" ]; then
                        echo -e "\n${WHITE}📝 完整轉錄文字:${NC}"
                        echo -e "${GREEN}$TRANSCRIPTION${NC}"
                    fi

                    if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
                        echo -e "\n${WHITE}📋 AI 摘要:${NC}"
                        echo -e "${BLUE}$SUMMARY${NC}"
                    fi

                    # 測試快取
                    print_step "測試 Redis 快取..."
                    sleep 1
                    CACHED_INFO=$(get_task_info "$MINIO_TASK_ID")
                    IS_CACHED=$(echo "$CACHED_INFO" | jq -r '.cached')

                    if [ "$IS_CACHED" = "true" ]; then
                        print_success "快取命中! (Redis 快取生效)"
                    fi

                    print_success "✨ MinIO 完整流程成功！"
                else
                    print_warning "MinIO 任務處理超時"
                fi
            else
                print_error "創建 MinIO 任務失敗"
            fi
        else
            print_warning "MinIO 上傳失敗或未啟用，跳過此步驟"
            ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.error')
            if [[ "$ERROR_MSG" == *"MinIO is not enabled"* ]]; then
                print_info "MinIO 未啟用，使用以下指令啟動："
                echo -e "  ${CYAN}export ENABLE_MINIO=true${NC}"
                echo -e "  ${CYAN}docker-compose --profile minio up -d${NC}"
            fi
        fi
    else
        print_warning "未找到音檔檔案，跳過 MinIO Demo"
        print_info "如需測試，請準備 harvard.wav / test.mp3 / sample.mp3"
    fi

    sleep 2

    # ========================================================================
    # 步驟 3: 批量任務處理
    # ========================================================================
    print_header "步驟 3/5: 批量任務處理（並發能力測試）"

    local task_count=5
    print_step "創建 $task_count 個並發任務..."

    declare -a task_ids

    for i in $(seq 1 $task_count); do
        TASK_ID=$(create_task \
            "" \
            "https://example.com/demo/audio-batch-$i.mp3" \
            $((60 + RANDOM % 60)))

        if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
            task_ids+=("$TASK_ID")
            echo -e "  ${GREEN}✓${NC} 任務 $i: $TASK_ID"
        else
            echo -e "  ${RED}✗${NC} 任務 $i 創建失敗"
        fi

        sleep 0.2
    done

    print_success "已創建 ${#task_ids[@]} 個任務"
    print_info "可在 RabbitMQ ($RABBITMQ_URL) 觀察佇列狀態"

    # 等待一段時間讓任務處理
    sleep 5

    # 檢查狀態分布
    print_step "檢查任務狀態分布..."
    local pending=0
    local processing=0
    local completed=0
    local failed=0

    for task_id in "${task_ids[@]}"; do
        status=$(get_task_status "$task_id")
        case "$status" in
            "pending") pending=$((pending + 1)) ;;
            "processing_stt"|"stt_completed"|"processing_llm") processing=$((processing + 1)) ;;
            "completed") completed=$((completed + 1)) ;;
            "failed") failed=$((failed + 1)) ;;
        esac
    done

    echo -e "\n${WHITE}任務狀態統計:${NC}"
    echo -e "  ${YELLOW}等待中:${NC} $pending"
    echo -e "  ${BLUE}處理中:${NC} $processing"
    echo -e "  ${GREEN}已完成:${NC} $completed"
    echo -e "  ${RED}失敗:${NC} $failed"

    sleep 2

    # ========================================================================
    # 步驟 4: 系統統計資訊
    # ========================================================================
    print_header "步驟 4/5: 系統統計資訊"

    print_step "查詢系統統計..."
    STATS=$(curl -s "$API_URL/api/v1/stats")

    TOTAL=$(echo "$STATS" | jq -r '.data.total')
    COMPLETED=$(echo "$STATS" | jq -r '.data.completed')
    FAILED=$(echo "$STATS" | jq -r '.data.failed')
    PROCESSING=$(echo "$STATS" | jq -r '.data.processing')
    PENDING=$(echo "$STATS" | jq -r '.data.pending')
    AVG_DURATION=$(echo "$STATS" | jq -r '.data.avg_duration_seconds')

    echo -e "\n${WHITE}統計摘要 (過去 24 小時):${NC}"
    echo -e "  📊 總任務數: ${CYAN}$TOTAL${NC}"
    echo -e "  ✅ 已完成: ${GREEN}$COMPLETED${NC}"
    echo -e "  ⏳ 處理中: ${BLUE}$PROCESSING${NC}"
    echo -e "  ⏸️  等待中: ${YELLOW}$PENDING${NC}"
    echo -e "  ❌ 失敗: ${RED}$FAILED${NC}"
    echo -e "  ⏱️  平均處理時間: ${YELLOW}${AVG_DURATION}秒${NC}"

    sleep 2

    # ========================================================================
    # 步驟 5: 任務概覽
    # ========================================================================
    print_header "步驟 5/5: 任務概覽"

    echo "$STATS" | jq '.data'

    # ========================================================================
    # Demo 完成
    # ========================================================================
    print_header "✨ 整合式 Demo 完成"

    echo -e "${WHITE}系統資訊:${NC}"
    echo -e "  🔗 API Service: ${CYAN}$API_URL${NC}"
    echo -e "  📦 MinIO Console: ${CYAN}$MINIO_CONSOLE${NC} (admin/admin123456)"
    echo -e "  🐰 RabbitMQ: ${CYAN}$RABBITMQ_URL${NC} (admin/admin123)"
    echo -e "  📊 Prometheus: ${CYAN}$PROMETHEUS_URL${NC}"
    echo -e "  📈 Grafana: ${CYAN}$GRAFANA_URL${NC} (admin/admin123)"

    echo -e "\n${WHITE}文檔資源:${NC}"
    echo "  - API 文檔: README.md"
    echo "  - MinIO 上傳指南: MINIO_UPLOAD_GUIDE.md"
    echo "  - 架構設計: ARCHITECTURE.md"

    echo -e "\n${GREEN}✅ 所有步驟執行完畢！${NC}"
}

# ============================================================================
# 主程式
# ============================================================================

main() {
    check_dependencies
    integrated_demo
}

main "$@"
