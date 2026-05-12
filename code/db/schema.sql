-- AI_SYS PostgreSQL schema (v1.0)
-- Purpose: case-law data storage for search, RAG, and learning history

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'data_status'
    ) THEN
        CREATE TYPE data_status AS ENUM (
            'collected',
            'parsed',
            'summarized',
            'reviewed',
            'published',
            'blocked'
        );
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'relation_type'
    ) THEN
        CREATE TYPE relation_type AS ENUM (
            'similar',
            'related',
            'opposite'
        );
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS cases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_number VARCHAR(64) NOT NULL,
    case_name TEXT NOT NULL,
    court_name VARCHAR(128) NOT NULL,
    decision_date DATE,
    case_type VARCHAR(64),
    subject VARCHAR(64) NOT NULL,
    raw_text TEXT NOT NULL,
    issue_summary TEXT,
    holding_summary TEXT,
    exam_points TEXT,
    source_url TEXT,
    source_name VARCHAR(128),
    status data_status NOT NULL DEFAULT 'collected',
    collected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_cases_case_number UNIQUE (case_number)
);

CREATE TABLE IF NOT EXISTS case_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    chunk_text TEXT NOT NULL,
    token_count INT,
    embedding vector(1024),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_case_chunks_case_chunk UNIQUE (case_id, chunk_index)
);

CREATE TABLE IF NOT EXISTS case_keywords (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    keyword VARCHAR(128) NOT NULL,
    weight NUMERIC(5, 2) NOT NULL DEFAULT 1.00,
    source VARCHAR(64) NOT NULL DEFAULT 'manual',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_case_keywords_weight CHECK (weight >= 0 AND weight <= 100),
    CONSTRAINT uq_case_keywords_case_keyword UNIQUE (case_id, keyword)
);

CREATE TABLE IF NOT EXISTS case_relations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    related_case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    relation relation_type NOT NULL,
    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_case_relations_not_self CHECK (case_id <> related_case_id),
    CONSTRAINT uq_case_relations_pair UNIQUE (case_id, related_case_id, relation)
);

CREATE TABLE IF NOT EXISTS user_case_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(128) NOT NULL,
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    action_type VARCHAR(32) NOT NULL,
    is_wrong_answer BOOLEAN NOT NULL DEFAULT FALSE,
    solved_at TIMESTAMPTZ,
    review_due_at TIMESTAMPTZ,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_user_case_history_action_type CHECK (
        action_type IN ('view', 'search', 'wrong_answer', 'review')
    )
);

CREATE INDEX IF NOT EXISTS idx_cases_subject ON cases(subject);
CREATE INDEX IF NOT EXISTS idx_cases_status ON cases(status);
CREATE INDEX IF NOT EXISTS idx_cases_decision_date ON cases(decision_date);
CREATE INDEX IF NOT EXISTS idx_case_chunks_case_id ON case_chunks(case_id);
CREATE INDEX IF NOT EXISTS idx_case_keywords_case_id ON case_keywords(case_id);
CREATE INDEX IF NOT EXISTS idx_case_keywords_keyword ON case_keywords(keyword);
CREATE INDEX IF NOT EXISTS idx_case_relations_case_id ON case_relations(case_id);
CREATE INDEX IF NOT EXISTS idx_user_case_history_user_id ON user_case_history(user_id);
CREATE INDEX IF NOT EXISTS idx_user_case_history_case_id ON user_case_history(case_id);
CREATE INDEX IF NOT EXISTS idx_user_case_history_review_due ON user_case_history(review_due_at);

CREATE OR REPLACE VIEW published_cases AS
SELECT
    id,
    case_number,
    case_name,
    court_name,
    decision_date,
    subject,
    issue_summary,
    holding_summary,
    exam_points,
    source_url,
    updated_at
FROM cases
WHERE status = 'published';

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_cases_updated_at ON cases;
CREATE TRIGGER trg_cases_updated_at
BEFORE UPDATE ON cases
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

COMMIT;
