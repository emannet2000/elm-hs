-- ECC CRM 2.0 domain foundation.
-- Additive migration: establishes identity, command/event, outbox, concurrency,
-- provenance and archive primitives without replacing the current production API.

CREATE TABLE IF NOT EXISTS people (
  id BIGSERIAL PRIMARY KEY,
  full_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  normalized_email TEXT GENERATED ALWAYS AS (NULLIF(lower(btrim(email)), '')) STORED,
  normalized_phone TEXT,
  provenance TEXT NOT NULL DEFAULT 'staff',
  version BIGINT NOT NULL DEFAULT 1,
  archived_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (provenance IN ('staff','import','conversion','automation','api','ai','system'))
);

CREATE INDEX IF NOT EXISTS people_email_idx ON people (normalized_email) WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS people_phone_idx ON people (normalized_phone) WHERE archived_at IS NULL;

ALTER TABLE leads ADD COLUMN IF NOT EXISTS person_id BIGINT REFERENCES people(id);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS provenance TEXT NOT NULL DEFAULT 'staff';
ALTER TABLE leads ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS person_id BIGINT REFERENCES people(id);
ALTER TABLE clients ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS provenance TEXT NOT NULL DEFAULT 'conversion';
ALTER TABLE clients ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS clients_person_active_uq
  ON clients(person_id) WHERE person_id IS NOT NULL AND archived_at IS NULL;

CREATE TABLE IF NOT EXISTS consultations (
  id BIGSERIAL PRIMARY KEY,
  person_id BIGINT NOT NULL REFERENCES people(id),
  lead_id INTEGER REFERENCES leads(id),
  consultant_id INTEGER REFERENCES users(id),
  scheduled_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  outcome TEXT,
  notes TEXT,
  next_action TEXT,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  version BIGINT NOT NULL DEFAULT 1,
  archived_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status IN ('scheduled','completed','cancelled','no_show','rescheduled'))
);

CREATE INDEX IF NOT EXISTS consultations_person_idx ON consultations(person_id, scheduled_at DESC);
CREATE INDEX IF NOT EXISTS consultations_schedule_idx ON consultations(scheduled_at) WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS workflow_definitions (
  id BIGSERIAL PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  definition JSONB NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS application_checklist_items (
  id BIGSERIAL PRIMARY KEY,
  case_id INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  label TEXT NOT NULL,
  required BOOLEAN NOT NULL DEFAULT true,
  status TEXT NOT NULL DEFAULT 'missing',
  blocking_reason TEXT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(case_id, code),
  CHECK (status IN ('missing','pending','satisfied','waived','rejected'))
);

CREATE TABLE IF NOT EXISTS domain_events (
  id BIGSERIAL PRIMARY KEY,
  event_id UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  event_type TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id BIGINT NOT NULL,
  person_id BIGINT REFERENCES people(id),
  actor_id INTEGER REFERENCES users(id),
  command_id UUID,
  correlation_id UUID,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS domain_events_entity_idx ON domain_events(entity_type, entity_id, occurred_at);
CREATE INDEX IF NOT EXISTS domain_events_person_idx ON domain_events(person_id, occurred_at) WHERE person_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS idempotency_keys (
  key TEXT PRIMARY KEY,
  command_type TEXT NOT NULL,
  actor_id INTEGER REFERENCES users(id),
  request_hash TEXT,
  result_status INTEGER,
  result_body JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS outbox_events (
  id BIGSERIAL PRIMARY KEY,
  event_id UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  topic TEXT NOT NULL,
  aggregate_type TEXT NOT NULL,
  aggregate_id BIGINT NOT NULL,
  payload JSONB NOT NULL,
  available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  attempts INTEGER NOT NULL DEFAULT 0,
  locked_at TIMESTAMPTZ,
  locked_by TEXT,
  processed_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS outbox_pending_idx
  ON outbox_events(available_at, id) WHERE processed_at IS NULL;

CREATE TABLE IF NOT EXISTS background_jobs (
  id BIGSERIAL PRIMARY KEY,
  job_key TEXT NOT NULL UNIQUE,
  job_type TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'pending',
  available_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 8,
  locked_at TIMESTAMPTZ,
  locked_by TEXT,
  heartbeat_at TIMESTAMPTZ,
  last_error TEXT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status IN ('pending','running','completed','failed','dead'))
);

CREATE INDEX IF NOT EXISTS background_jobs_ready_idx
  ON background_jobs(available_at, id) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS feature_flags (
  key TEXT PRIMARY KEY,
  enabled BOOLEAN NOT NULL DEFAULT false,
  description TEXT,
  updated_by INTEGER REFERENCES users(id),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger_entries (
  id BIGSERIAL PRIMARY KEY,
  person_id BIGINT NOT NULL REFERENCES people(id),
  case_id INTEGER REFERENCES cases(id),
  entry_type TEXT NOT NULL,
  amount NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
  currency CHAR(3) NOT NULL DEFAULT 'PHP',
  reference TEXT,
  notes TEXT,
  actor_id INTEGER REFERENCES users(id),
  reverses_entry_id BIGINT REFERENCES ledger_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (entry_type IN ('charge','payment','refund','discount','adjustment'))
);

CREATE INDEX IF NOT EXISTS ledger_person_idx ON ledger_entries(person_id, created_at);

-- Document metadata evolves additively; existing file storage remains intact.
ALTER TABLE documents ADD COLUMN IF NOT EXISTS person_id BIGINT REFERENCES people(id);
ALTER TABLE documents ADD COLUMN IF NOT EXISTS document_type TEXT;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS version_no INTEGER NOT NULL DEFAULT 1;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS is_current BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS verification_status TEXT NOT NULL DEFAULT 'unverified';
ALTER TABLE documents ADD COLUMN IF NOT EXISTS verified_by INTEGER REFERENCES users(id);
ALTER TABLE documents ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS expires_on DATE;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS rejection_reason TEXT;

CREATE INDEX IF NOT EXISTS documents_person_idx ON documents(person_id, created_at DESC) WHERE person_id IS NOT NULL;

-- The first flags are deliberately disabled. They are rollout controls, not configuration defaults.
INSERT INTO feature_flags(key, enabled, description) VALUES
  ('automation_engine', false, 'Enable durable business automation workers'),
  ('ai_copilot', false, 'Enable read-only AI copilot'),
  ('ai_mutations', false, 'Enable preview/approval AI business commands')
ON CONFLICT (key) DO NOTHING;
