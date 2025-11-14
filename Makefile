.PHONY: help setup build up down restart logs ps clean test db-reset env-check health

# Default target
.DEFAULT_GOAL := help

# Colors for output
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

## help: Display this help message
help:
	@echo "$(CYAN)AI Processing Platform - Make Commands$(NC)"
	@echo ""
	@echo "$(GREEN)Available commands:$(NC)"
	@echo "  $(CYAN)make setup$(NC)        - Initial setup (create .env from .env.example)"
	@echo "  $(CYAN)make build$(NC)        - Build all Docker images"
	@echo "  $(CYAN)make up$(NC)           - Start all services"
	@echo "  $(CYAN)make down$(NC)         - Stop all services"
	@echo "  $(CYAN)make restart$(NC)      - Restart all services"
	@echo "  $(CYAN)make logs$(NC)         - View logs (follow mode)"
	@echo "  $(CYAN)make logs-api$(NC)     - View API service logs"
	@echo "  $(CYAN)make logs-workers$(NC) - View worker logs"
	@echo "  $(CYAN)make ps$(NC)           - Show running services"
	@echo "  $(CYAN)make health$(NC)       - Check service health"
	@echo "  $(CYAN)make test$(NC)         - Run tests"
	@echo "  $(CYAN)make clean$(NC)        - Stop services and remove volumes (DESTRUCTIVE)"
	@echo "  $(CYAN)make db-reset$(NC)     - Reset database (DESTRUCTIVE)"
	@echo "  $(CYAN)make env-check$(NC)    - Validate environment configuration"
	@echo ""
	@echo "$(YELLOW)Examples:$(NC)"
	@echo "  make setup && make up  # First time setup and start"
	@echo "  make logs SERVICE=api-service  # View specific service logs"
	@echo ""

## setup: Create .env file from .env.example if it doesn't exist
setup:
	@if [ ! -f .env ]; then \
		echo "$(GREEN)Creating .env from .env.example...$(NC)"; \
		cp .env.example .env; \
		echo "$(YELLOW)⚠️  Please edit .env and update credentials before running 'make up'$(NC)"; \
	else \
		echo "$(YELLOW).env file already exists, skipping...$(NC)"; \
	fi

## env-check: Validate environment configuration
env-check:
	@echo "$(CYAN)Checking environment configuration...$(NC)"
	@if [ ! -f .env ]; then \
		echo "$(RED)✗ .env file not found! Run 'make setup' first.$(NC)"; \
		exit 1; \
	else \
		echo "$(GREEN)✓ .env file exists$(NC)"; \
	fi
	@if grep -q "change-me-in-production" .env; then \
		echo "$(YELLOW)⚠️  Warning: Default passwords detected in .env$(NC)"; \
		echo "$(YELLOW)   Please update credentials for production use!$(NC)"; \
	else \
		echo "$(GREEN)✓ No default passwords detected$(NC)"; \
	fi

## build: Build all Docker images
build: env-check
	@echo "$(CYAN)Building Docker images...$(NC)"
	docker-compose build
	@echo "$(GREEN)✓ Build complete$(NC)"

## up: Start all services
up: env-check
	@echo "$(CYAN)Starting services...$(NC)"
	docker-compose up -d
	@echo "$(YELLOW)Waiting for services to be ready...$(NC)"
	@sleep 5
	@$(MAKE) ps
	@echo ""
	@echo "$(GREEN)✓ Services started successfully!$(NC)"
	@echo ""
	@echo "$(CYAN)Access URLs:$(NC)"
	@echo "  API Service:  http://localhost:8080"
	@echo "  Grafana:      http://localhost:3000 (admin/admin123)"
	@echo "  Prometheus:   http://localhost:9090"
	@echo "  RabbitMQ:     http://localhost:15672 (admin/admin123)"
	@echo ""
	@echo "Run '$(CYAN)make health$(NC)' to check service health"
	@echo "Run '$(CYAN)make logs$(NC)' to view logs"

## down: Stop all services
down:
	@echo "$(CYAN)Stopping services...$(NC)"
	docker-compose down
	@echo "$(GREEN)✓ Services stopped$(NC)"

## restart: Restart all services
restart: down up

## logs: View logs for all services (follow mode)
logs:
	@echo "$(CYAN)Showing logs (Ctrl+C to exit)...$(NC)"
	docker-compose logs -f $(SERVICE)

## logs-api: View API service logs only
logs-api:
	@echo "$(CYAN)Showing API service logs (Ctrl+C to exit)...$(NC)"
	docker-compose logs -f api-service

## logs-workers: View worker logs only
logs-workers:
	@echo "$(CYAN)Showing worker logs (Ctrl+C to exit)...$(NC)"
	docker-compose logs -f stt-worker-1 stt-worker-2 llm-worker-1 llm-worker-2

## ps: Show running services
ps:
	@echo "$(CYAN)Service Status:$(NC)"
	@docker-compose ps

## health: Check health of all services
health:
	@echo "$(CYAN)Checking service health...$(NC)"
	@echo ""
	@echo "$(YELLOW)API Service:$(NC)"
	@curl -s http://localhost:8080/health/ready | jq '.' || echo "$(RED)✗ API not responding$(NC)"
	@echo ""
	@echo "$(YELLOW)Database:$(NC)"
	@docker-compose exec -T postgres pg_isready -U admin && echo "$(GREEN)✓ PostgreSQL is ready$(NC)" || echo "$(RED)✗ PostgreSQL is down$(NC)"
	@echo ""
	@echo "$(YELLOW)Redis:$(NC)"
	@docker-compose exec -T redis redis-cli ping | grep -q PONG && echo "$(GREEN)✓ Redis is ready$(NC)" || echo "$(RED)✗ Redis is down$(NC)"
	@echo ""
	@echo "$(YELLOW)RabbitMQ:$(NC)"
	@curl -s -u admin:admin123 http://localhost:15672/api/overview > /dev/null && echo "$(GREEN)✓ RabbitMQ is ready$(NC)" || echo "$(RED)✗ RabbitMQ is down$(NC)"

## test: Run tests
test:
	@echo "$(CYAN)Running tests...$(NC)"
	@echo "$(YELLOW)API Tests:$(NC)"
	docker-compose exec -T api-service npm test || echo "$(YELLOW)No tests configured yet$(NC)"

## db-reset: Reset database (DESTRUCTIVE)
db-reset:
	@echo "$(RED)⚠️  WARNING: This will DELETE all data in the database!$(NC)"
	@read -p "Are you sure? (yes/no): " confirm && [ "$$confirm" = "yes" ] || (echo "Cancelled" && exit 1)
	@echo "$(CYAN)Resetting database...$(NC)"
	docker-compose down postgres
	docker volume rm ai_test_02_postgres_data || true
	docker-compose up -d postgres
	@echo "$(YELLOW)Waiting for database to initialize...$(NC)"
	@sleep 10
	@echo "$(GREEN)✓ Database reset complete$(NC)"

## clean: Remove all containers, volumes, and images (DESTRUCTIVE)
clean:
	@echo "$(RED)⚠️  WARNING: This will DELETE all data and images!$(NC)"
	@read -p "Are you sure? (yes/no): " confirm && [ "$$confirm" = "yes" ] || (echo "Cancelled" && exit 1)
	@echo "$(CYAN)Cleaning up...$(NC)"
	docker-compose down -v
	docker system prune -f
	@echo "$(GREEN)✓ Cleanup complete$(NC)"

## shell-api: Open shell in API service container
shell-api:
	@echo "$(CYAN)Opening shell in API service...$(NC)"
	docker-compose exec api-service sh

## shell-db: Open PostgreSQL shell
shell-db:
	@echo "$(CYAN)Opening PostgreSQL shell...$(NC)"
	docker-compose exec postgres psql -U admin -d ai_platform

## create-task: Create a test task
create-task:
	@echo "$(CYAN)Creating test task...$(NC)"
	@curl -X POST http://localhost:8080/api/v1/tasks \
		-H "Content-Type: application/json" \
		-d '{"audio_url": "https://example.com/test.mp3", "audio_duration": 60}' | jq '.'

## list-tasks: List all tasks
list-tasks:
	@echo "$(CYAN)Listing tasks...$(NC)"
	@curl -s http://localhost:8080/api/v1/tasks | jq '.'

## stats: Show task statistics
stats:
	@echo "$(CYAN)Task Statistics:$(NC)"
	@curl -s http://localhost:8080/api/v1/stats | jq '.'
