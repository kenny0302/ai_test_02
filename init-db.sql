-- AI Processing Platform Database Schema
-- Version: 1.0
-- Description: Initial database schema for task management

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Tasks table
CREATE TABLE IF NOT EXISTS tasks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    audio_url TEXT,
    audio_duration_seconds INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    metadata JSONB DEFAULT '{}'::jsonb,
    -- Constraints
    CONSTRAINT check_status CHECK (status IN ('pending', 'processing_stt', 'stt_completed', 'processing_llm', 'completed', 'failed')),
    CONSTRAINT check_retry_count CHECK (retry_count >= 0 AND retry_count <= 10),
    CONSTRAINT check_audio_duration CHECK (audio_duration_seconds IS NULL OR (audio_duration_seconds > 0 AND audio_duration_seconds <= 7200))
);

-- STT results table
CREATE TABLE IF NOT EXISTS stt_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    transcription TEXT NOT NULL,
    confidence FLOAT,
    language VARCHAR(10),
    processing_time_ms INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    -- Constraints
    CONSTRAINT check_confidence CHECK (confidence IS NULL OR (confidence >= 0.0 AND confidence <= 1.0)),
    CONSTRAINT check_stt_processing_time CHECK (processing_time_ms IS NULL OR processing_time_ms >= 0),
    CONSTRAINT unique_task_stt_result UNIQUE (task_id)
);

-- LLM summaries table
CREATE TABLE IF NOT EXISTS llm_summaries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    summary TEXT NOT NULL,
    model_name VARCHAR(100),
    tokens_used INTEGER,
    processing_time_ms INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    -- Constraints
    CONSTRAINT check_tokens CHECK (tokens_used IS NULL OR tokens_used >= 0),
    CONSTRAINT check_llm_processing_time CHECK (processing_time_ms IS NULL OR processing_time_ms >= 0),
    CONSTRAINT unique_task_llm_summary UNIQUE (task_id)
);

-- Users table (simplified for demo)
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    username VARCHAR(100) NOT NULL,
    tier VARCHAR(50) DEFAULT 'free', -- free, pro, enterprise
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- API Keys table
CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(100),
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_used_at TIMESTAMP WITH TIME ZONE
);

-- ============================================
-- Indexes for performance optimization
-- ============================================

-- Single column indexes
CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stt_results_created_at ON stt_results(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_llm_summaries_created_at ON llm_summaries(created_at DESC);

-- Composite indexes for common queries
CREATE INDEX IF NOT EXISTS idx_tasks_user_created ON tasks(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_status_created ON tasks(status, created_at DESC);

-- Partial indexes for frequently accessed subsets
CREATE INDEX IF NOT EXISTS idx_tasks_pending ON tasks(created_at DESC) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_tasks_processing ON tasks(created_at DESC) WHERE status LIKE 'processing%';
CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(completed_at DESC) WHERE status = 'completed';
CREATE INDEX IF NOT EXISTS idx_tasks_failed ON tasks(created_at DESC) WHERE status = 'failed';

-- API keys index
CREATE INDEX IF NOT EXISTS idx_api_keys_key ON api_keys(key) WHERE active = true;
CREATE INDEX IF NOT EXISTS idx_api_keys_user ON api_keys(user_id) WHERE active = true;

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Trigger to automatically update updated_at
CREATE TRIGGER update_tasks_updated_at BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Insert demo user
INSERT INTO users (id, email, username, tier)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'demo@example.com',
    'Demo User',
    'pro'
) ON CONFLICT (email) DO NOTHING;

-- Insert demo API key
INSERT INTO api_keys (user_id, key, name)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'demo-api-key-12345',
    'Demo API Key'
) ON CONFLICT (key) DO NOTHING;

-- ============================================
-- Audit Log Table
-- ============================================
CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    table_name VARCHAR(50) NOT NULL,
    record_id UUID NOT NULL,
    action VARCHAR(20) NOT NULL, -- INSERT, UPDATE, DELETE
    old_values JSONB,
    new_values JSONB,
    changed_by UUID,
    changed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_record ON audit_log(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp ON audit_log(changed_at DESC);

-- Audit trigger function
CREATE OR REPLACE FUNCTION audit_trigger_function()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_values)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', to_jsonb(OLD));
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_values, new_values)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, record_id, action, new_values)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', to_jsonb(NEW));
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Apply audit trigger to tasks table
CREATE TRIGGER tasks_audit_trigger
AFTER INSERT OR UPDATE OR DELETE ON tasks
FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

-- ============================================
-- Materialized View for task statistics
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS task_statistics AS
SELECT
    DATE_TRUNC('hour', created_at) as hour,
    status,
    COUNT(*) as count,
    AVG(EXTRACT(EPOCH FROM (COALESCE(completed_at, NOW()) - created_at))) as avg_duration_seconds
FROM tasks
GROUP BY DATE_TRUNC('hour', created_at), status;

CREATE INDEX IF NOT EXISTS idx_task_stats_hour ON task_statistics(hour DESC);

-- Function to refresh materialized view (can be called periodically)
CREATE OR REPLACE FUNCTION refresh_task_statistics()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY task_statistics;
END;
$$ LANGUAGE plpgsql;

-- Grant permissions (for demo purposes)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO admin;

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'Database schema initialized successfully!';
    RAISE NOTICE 'Demo user: demo@example.com';
    RAISE NOTICE 'Demo API key: demo-api-key-12345';
END $$;
