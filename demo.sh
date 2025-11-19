#!/bin/bash
# AI Processing Platform - Demo Script
# 用於展示系統功能的互動式腳本

set -e

# 配置
API_URL="http://localhost:8080"
RABBITMQ_URL="http://localhost:15672"
PROMETHEUS_URL="http://localhost:9090"
GRAFANA_URL="http://localhost:3000"

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 分隔線
LINE="================================================================"

# 檢查依賴
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}❌ 錯誤: 未安裝 jq${NC}"
        echo "請安裝 jq: brew install jq (macOS) 或 apt-get install jq (Linux)"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        echo -e "${RED}❌ 錯誤: 未安裝 curl${NC}"
        exit 1
    fi
}

# 打印標題
print_header() {
    echo -e "${CYAN}${LINE}${NC}"
    echo -e "${WHITE}$1${NC}"
    echo -e "${CYAN}${LINE}${NC}"
}

# 打印步驟
print_step() {
    echo -e "\n${BLUE}▶ $1${NC}"
}

# 打印成功
print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# 打印警告
print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# 打印錯誤
print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# 打印資訊
print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

# 等待用戶按鍵
wait_for_key() {
    echo -e "\n${YELLOW}按 Enter 繼續...${NC}"
    read
}

# 檢查服務健康狀態
check_health() {
    print_header "1. 健康檢查"

    print_step "檢查 API Service 存活狀態..."
    if curl -s "$API_URL/health/live" > /dev/null 2>&1; then
        LIVE_RESPONSE=$(curl -s "$API_URL/health/live" | jq -r '.status')
        if [ "$LIVE_RESPONSE" = "ok" ]; then
            print_success "API Service 運行正常"
        else
            print_error "API Service 狀態異常"
            return 1
        fi
    else
        print_error "無法連接到 API Service"
        return 1
    fi

    print_step "檢查依賴服務就緒狀態..."
    READY_RESPONSE=$(curl -s "$API_URL/health/ready")
    echo "$READY_RESPONSE" | jq .

    DB_STATUS=$(echo "$READY_RESPONSE" | jq -r '.checks.database')
    REDIS_STATUS=$(echo "$READY_RESPONSE" | jq -r '.checks.redis')
    RABBITMQ_STATUS=$(echo "$READY_RESPONSE" | jq -r '.checks.rabbitmq')

    if [ "$DB_STATUS" = "ok" ] && [ "$REDIS_STATUS" = "ok" ] && [ "$RABBITMQ_STATUS" = "ok" ]; then
        print_success "所有依賴服務正常"
    else
        print_warning "部分依賴服務可能有問題"
    fi

    print_info "RabbitMQ 管理介面: $RABBITMQ_URL (admin/admin123)"
    print_info "Prometheus: $PROMETHEUS_URL"
    print_info "Grafana: $GRAFANA_URL (admin/admin123)"
}

# 生成 UUID v4
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: 不傳 user_id，讓 API 使用預設值
        echo ""
    fi
}

# 創建單個任務
create_task() {
    local user_id=${1:-$(generate_uuid)}
    local audio_url=${2:-"https://example.com/demo/sample-audio.mp3"}
    local audio_duration=${3:-120}

    # 如果沒有 user_id，則不傳遞該欄位
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

    print_step "監控任務進度: $task_id"

    while [ $elapsed -lt $max_wait ]; do
        STATUS=$(get_task_status "$task_id")

        case "$STATUS" in
            "pending")
                echo -ne "${YELLOW}⏳ 狀態: pending (等待處理)${NC}\r"
                ;;
            "processing_stt")
                echo -ne "${BLUE}🎤 狀態: processing_stt (語音轉文字中)${NC}\r"
                ;;
            "stt_completed")
                echo -ne "${CYAN}📝 狀態: stt_completed (STT 完成)${NC}\r"
                ;;
            "processing_llm")
                echo -ne "${MAGENTA}🤖 狀態: processing_llm (生成摘要中)${NC}\r"
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
                echo -ne "${RED}❓ 狀態: $STATUS (未知)${NC}\r"
                ;;
        esac

        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo -ne "\n"
    print_warning "監控超時"
    return 1
}

# Demo 1: 基本功能展示
demo_basic() {
    print_header "2. 基本功能展示 - 創建並追蹤單個任務"

    print_step "創建任務..."
    TASK_ID=$(create_task)

    if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
        print_error "創建任務失敗"
        return 1
    fi

    print_success "任務已創建"
    print_info "Task ID: $TASK_ID"

    # 監控任務
    if monitor_task "$TASK_ID" 60; then
        print_step "查詢完整任務結果..."
        TASK_INFO=$(get_task_info "$TASK_ID")

        echo -e "\n${WHITE}任務詳情:${NC}"
        echo "$TASK_INFO" | jq '{
            id: .data.id,
            status: .data.status,
            transcription: (.data.transcription // "" | .[0:100] + "..."),
            summary: (.data.summary // "" | .[0:150] + "..."),
            created_at: .data.created_at,
            completed_at: .data.completed_at,
            cached: .cached
        }'

        print_step "測試快取機制..."
        sleep 1
        CACHED_INFO=$(get_task_info "$TASK_ID")
        IS_CACHED=$(echo "$CACHED_INFO" | jq -r '.cached')

        if [ "$IS_CACHED" = "true" ]; then
            print_success "快取命中! (Redis 快取生效)"
        else
            print_warning "未使用快取"
        fi
    fi
}

# Demo 2: 批量任務展示
demo_batch() {
    print_header "3. 批量任務展示 - 並發處理能力"

    local task_count=${1:-5}
    print_step "創建 $task_count 個並發任務..."

    declare -a task_ids

    # 使用固定的 user_id 或不傳（使用預設）
    for i in $(seq 1 $task_count); do
        TASK_ID=$(create_task \
            "" \
            "https://example.com/demo/audio-batch-$i.mp3" \
            $((60 + RANDOM % 60)))

        if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
            task_ids+=("$TASK_ID")
            print_success "任務 $i/$task_count: $TASK_ID"
        else
            print_error "任務 $i 創建失敗"
        fi

        sleep 0.2
    done

    print_info "已創建 ${#task_ids[@]} 個任務"
    print_info "提示: 可在 RabbitMQ 管理介面 ($RABBITMQ_URL) 觀察佇列狀態"

    wait_for_key

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

    print_info "所有任務 ID 已儲存在 task_ids 陣列中"
}

# Demo 2.5: MinIO 檔案上傳展示
demo_minio_upload() {
    print_header "2.5 MinIO 檔案上傳展示 - 完整處理流程"

    # 檢查音檔是否存在
    local audio_file="./harvard.wav"

    if [ ! -f "$audio_file" ]; then
        print_warning "找不到 harvard.wav，嘗試在當前目錄創建測試音檔..."

        # 嘗試尋找其他音檔
        if [ -f "./test.mp3" ]; then
            audio_file="./test.mp3"
            print_info "使用 test.mp3 作為測試音檔"
        elif [ -f "./sample.mp3" ]; then
            audio_file="./sample.mp3"
            print_info "使用 sample.mp3 作為測試音檔"
        else
            print_error "未找到音檔檔案！"
            print_info "請準備一個音檔檔案（harvard.wav, test.mp3, 或 sample.mp3）"
            return 1
        fi
    fi

    print_success "找到音檔檔案: $audio_file"

    # 顯示檔案資訊
    if command -v ls &> /dev/null; then
        local file_size=$(ls -lh "$audio_file" | awk '{print $5}')
        print_info "檔案大小: $file_size"
    fi

    # 步驟 1: 上傳音檔到 MinIO
    print_step "步驟 1/4: 上傳音檔到 MinIO..."

    UPLOAD_RESPONSE=$(curl -s -X POST "$API_URL/api/v1/upload" \
        -F "audio=@$audio_file")

    # 檢查上傳是否成功
    UPLOAD_SUCCESS=$(echo "$UPLOAD_RESPONSE" | jq -r '.success')

    if [ "$UPLOAD_SUCCESS" != "true" ]; then
        print_error "上傳失敗！"
        echo "$UPLOAD_RESPONSE" | jq .

        # 檢查是否因為 MinIO 未啟用
        ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.error')
        if [[ "$ERROR_MSG" == *"MinIO is not enabled"* ]]; then
            print_warning "MinIO 未啟用！請使用以下指令啟動："
            echo -e "${CYAN}export ENABLE_MINIO=true${NC}"
            echo -e "${CYAN}docker-compose --profile minio up -d --build${NC}"
        fi
        return 1
    fi

    print_success "音檔上傳成功！"

    # 提取上傳資訊
    AUDIO_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.audio_url')
    PUBLIC_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.public_url')
    FILE_KEY=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.file_key')
    FILE_SIZE=$(echo "$UPLOAD_RESPONSE" | jq -r '.data.size')

    echo -e "\n${WHITE}上傳詳情:${NC}"
    echo -e "  📦 File Key: ${CYAN}$FILE_KEY${NC}"
    echo -e "  🔗 內部 URL: ${CYAN}$AUDIO_URL${NC}"
    echo -e "  🌐 公開 URL: ${CYAN}$PUBLIC_URL${NC}"
    echo -e "  📊 檔案大小: ${CYAN}$(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes")${NC}"

    # 步驟 2: 創建處理任務
    print_step "步驟 2/4: 創建 STT 處理任務..."

    # 計算音檔時長（假設為 30 秒，實際應該從檔案解析）
    local audio_duration=30

    TASK_RESPONSE=$(curl -s -X POST "$API_URL/api/v1/tasks" \
        -H "Content-Type: application/json" \
        -d "{
            \"audio_url\": \"$AUDIO_URL\",
            \"audio_duration\": $audio_duration
        }")

    TASK_ID=$(echo "$TASK_RESPONSE" | jq -r '.data.task_id')

    if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
        print_error "創建任務失敗！"
        echo "$TASK_RESPONSE" | jq .
        return 1
    fi

    print_success "任務已創建！"
    print_info "Task ID: $TASK_ID"

    # 步驟 3: 監控任務處理
    print_step "步驟 3/4: 監控任務處理 (STT Worker 將從 MinIO 下載音檔)..."

    echo -e "${YELLOW}提示: 可以使用以下指令查看 Worker 日誌:${NC}"
    echo -e "${CYAN}  docker logs stt-worker-1 --tail 20 -f${NC}"
    echo ""

    # 監控任務狀態
    local start_time=$(date +%s)

    if monitor_task "$TASK_ID" 90; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        print_success "任務處理完成！總耗時: ${duration}秒"

        # 步驟 4: 查看處理結果
        print_step "步驟 4/4: 查詢處理結果..."

        TASK_INFO=$(get_task_info "$TASK_ID")

        echo -e "\n${WHITE}處理結果:${NC}"
        echo "$TASK_INFO" | jq '{
            id: .data.id,
            status: .data.status,
            audio_url: .data.audio_url,
            transcription: .data.transcription,
            confidence: .data.confidence,
            language: .data.language,
            summary: .data.summary,
            created_at: .data.created_at,
            completed_at: .data.completed_at
        }'

        # 顯示轉錄文字（完整）
        TRANSCRIPTION=$(echo "$TASK_INFO" | jq -r '.data.transcription')
        if [ -n "$TRANSCRIPTION" ] && [ "$TRANSCRIPTION" != "null" ]; then
            echo -e "\n${WHITE}📝 完整轉錄文字:${NC}"
            echo -e "${GREEN}$TRANSCRIPTION${NC}"
        fi

        # 顯示摘要（完整）
        SUMMARY=$(echo "$TASK_INFO" | jq -r '.data.summary')
        if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
            echo -e "\n${WHITE}📋 AI 摘要:${NC}"
            echo -e "${BLUE}$SUMMARY${NC}"
        fi

        # 驗證 Worker 日誌
        print_step "驗證 STT Worker 下載日誌..."
        echo -e "${CYAN}查看最近的 Worker 日誌:${NC}"
        docker logs stt-worker-1 --tail 15 2>&1 | grep -i "minio\|download\|processing task $TASK_ID" || true

        print_success "✨ MinIO 完整流程展示完成！"

    else
        print_error "任務處理超時或失敗"

        # 查看任務狀態
        TASK_INFO=$(get_task_info "$TASK_ID")
        STATUS=$(echo "$TASK_INFO" | jq -r '.data.status')
        ERROR_MSG=$(echo "$TASK_INFO" | jq -r '.data.error_message // empty')

        echo -e "\n${WHITE}任務狀態:${NC} $STATUS"
        if [ -n "$ERROR_MSG" ]; then
            echo -e "${WHITE}錯誤訊息:${NC} $ERROR_MSG"
        fi

        return 1
    fi
}

# Demo 3: 統計資訊展示
demo_stats() {
    print_header "4. 系統統計資訊"

    print_step "查詢系統統計..."
    STATS=$(curl -s "$API_URL/api/v1/stats")

    echo "$STATS" | jq .

    TOTAL=$(echo "$STATS" | jq -r '.data.total')
    COMPLETED=$(echo "$STATS" | jq -r '.data.completed')
    FAILED=$(echo "$STATS" | jq -r '.data.failed')
    AVG_DURATION=$(echo "$STATS" | jq -r '.data.avg_duration_seconds')

    echo -e "\n${WHITE}統計摘要:${NC}"
    echo -e "  總任務數: ${CYAN}$TOTAL${NC}"
    echo -e "  已完成: ${GREEN}$COMPLETED${NC}"
    echo -e "  失敗: ${RED}$FAILED${NC}"
    echo -e "  平均處理時間: ${YELLOW}${AVG_DURATION}秒${NC}"
}

# Demo 4: 列出任務 (使用統計數據代替)
demo_list_tasks() {
    print_header "5. 任務統計與概覽"

    print_step "查詢任務統計資訊..."

    # 查詢統計數據
    STATS=$(curl -s "$API_URL/api/v1/stats")

    echo -e "\n${WHITE}任務統計 (過去 24 小時):${NC}"
    echo "$STATS" | jq '.data'

    TOTAL=$(echo "$STATS" | jq -r '.data.total')
    COMPLETED=$(echo "$STATS" | jq -r '.data.completed')
    FAILED=$(echo "$STATS" | jq -r '.data.failed')
    PROCESSING=$(echo "$STATS" | jq -r '.data.processing')
    PENDING=$(echo "$STATS" | jq -r '.data.pending')

    echo -e "\n${WHITE}狀態分布:${NC}"
    echo -e "  📊 總任務數: ${CYAN}$TOTAL${NC}"
    echo -e "  ✅ 已完成: ${GREEN}$COMPLETED${NC}"
    echo -e "  ⏳ 處理中: ${BLUE}$PROCESSING${NC}"
    echo -e "  ⏸️  等待中: ${YELLOW}$PENDING${NC}"
    echo -e "  ❌ 失敗: ${RED}$FAILED${NC}"
}

# 完整 Demo 流程
run_full_demo() {
    print_header "🎬 AI Processing Platform - 完整 Demo"

    echo -e "${WHITE}此 Demo 將展示以下功能:${NC}"
    echo "  1. 健康檢查"
    echo "  2. 基本功能 - 創建並追蹤任務"
    echo "  2.5 MinIO 檔案上傳 - 完整處理流程 (如果 MinIO 已啟用)"
    echo "  3. 批量處理 - 並發任務"
    echo "  4. 系統統計"
    echo "  5. 任務列表"
    echo ""

    wait_for_key

    # 健康檢查
    if ! check_health; then
        print_error "健康檢查失敗，請確認服務是否正常運行"
        print_info "提示: 執行 'docker-compose ps' 檢查服務狀態"
        exit 1
    fi

    wait_for_key

    # 基本功能
    demo_basic

    wait_for_key

    # MinIO 上傳 Demo（如果 MinIO 啟用且有音檔）
    if [ -f "./harvard.wav" ] || [ -f "./test.mp3" ] || [ -f "./sample.mp3" ]; then
        print_info "檢測到音檔檔案，執行 MinIO 上傳 Demo..."
        if demo_minio_upload; then
            wait_for_key
        else
            print_warning "MinIO Demo 跳過（可能未啟用或上傳失敗）"
            wait_for_key
        fi
    else
        print_info "未找到音檔檔案 (harvard.wav/test.mp3/sample.mp3)，跳過 MinIO Demo"
        print_info "如需測試 MinIO 上傳功能，請準備音檔後執行: ./demo.sh upload"
        wait_for_key
    fi

    # 批量任務
    demo_batch 5

    wait_for_key

    # 統計資訊
    demo_stats

    wait_for_key

    # 任務列表
    demo_list_tasks

    print_header "✨ Demo 完成"
    print_info "更多資訊請查看:"
    echo "  - API 文檔: README.md"
    echo "  - MinIO 上傳指南: MINIO_UPLOAD_GUIDE.md"
    echo "  - 架構設計: ARCHITECTURE.md"
    echo "  - RabbitMQ: $RABBITMQ_URL"
    echo "  - Prometheus: $PROMETHEUS_URL"
    echo "  - Grafana: $GRAFANA_URL"
    echo "  - MinIO Console: http://localhost:9001 (如已啟用)"
}

# 快速創建任務
quick_create() {
    print_header "快速創建任務"

    TASK_ID=$(create_task)

    if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
        print_success "任務已創建: $TASK_ID"
        echo -e "\n查詢任務: curl $API_URL/api/v1/tasks/$TASK_ID | jq ."
        echo -e "監控任務: $0 monitor $TASK_ID"
    else
        print_error "創建任務失敗"
        exit 1
    fi
}

# 快速監控任務
quick_monitor() {
    local task_id=$1

    if [ -z "$task_id" ]; then
        print_error "請提供 Task ID"
        echo "用法: $0 monitor <task_id>"
        exit 1
    fi

    print_header "監控任務: $task_id"

    if monitor_task "$task_id" 120; then
        echo ""
        get_task_info "$task_id" | jq .
    fi
}

# 顯示幫助
show_help() {
    cat << EOF
${WHITE}AI Processing Platform - Demo Script${NC}

${CYAN}用法:${NC}
  $0 [command] [options]

${CYAN}命令:${NC}
  ${GREEN}full${NC}              執行完整 Demo 流程 (推薦)
  ${GREEN}health${NC}            檢查系統健康狀態
  ${GREEN}upload${NC}            MinIO 檔案上傳完整展示 (需要 harvard.wav) ⭐ NEW!
  ${GREEN}create${NC}            快速創建一個任務
  ${GREEN}monitor <task_id>${NC} 監控指定任務的處理進度
  ${GREEN}batch [count]${NC}     創建批量任務 (預設 5 個)
  ${GREEN}stats${NC}             查看系統統計資訊
  ${GREEN}list [limit]${NC}      列出用戶任務 (預設 10 筆)
  ${GREEN}help${NC}              顯示此幫助資訊

${CYAN}範例:${NC}
  $0 full                  # 執行完整 Demo
  $0 health                # 健康檢查
  $0 upload                # MinIO 上傳 + STT + LLM 完整流程
  $0 create                # 創建任務
  $0 monitor abc-123...    # 監控任務
  $0 batch 10              # 創建 10 個批量任務
  $0 stats                 # 查看統計
  $0 list 20               # 列出最近 20 筆任務

${CYAN}服務端點:${NC}
  API Service:   $API_URL
  MinIO Console: http://localhost:9001 (admin/admin123456)
  RabbitMQ:      $RABBITMQ_URL (admin/admin123)
  Prometheus:    $PROMETHEUS_URL
  Grafana:       $GRAFANA_URL (admin/admin123)

${CYAN}需要:${NC}
  - jq (JSON 處理工具)
  - curl
  - Docker & Docker Compose
  - harvard.wav (用於 upload demo)

${CYAN}MinIO 模式啟動:${NC}
  export ENABLE_MINIO=true
  docker-compose --profile minio up -d

EOF
}

# 主程式
main() {
    # 檢查依賴
    check_dependencies

    # 處理命令
    case "${1:-help}" in
        full)
            run_full_demo
            ;;
        health)
            check_health
            ;;
        upload)
            demo_minio_upload
            ;;
        create)
            quick_create
            ;;
        monitor)
            quick_monitor "$2"
            ;;
        batch)
            demo_batch "${2:-5}"
            ;;
        stats)
            demo_stats
            ;;
        list)
            demo_list_tasks "00000000-0000-0000-0000-000000000001" "${2:-10}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知命令: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 執行主程式
main "$@"
