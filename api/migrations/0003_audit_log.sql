-- Audit trail: who changed what and when.  Rows survive entity deletion
-- (no FKs on entity_id) so history is preserved after deletes.

CREATE TABLE IF NOT EXISTS audit_log (
    id          SERIAL PRIMARY KEY,
    entity_type VARCHAR(20)  NOT NULL CHECK (entity_type IN
                  ('lead', 'client', 'case', 'task', 'user', 'document')),
    entity_id   INTEGER      NOT NULL,
    entity_name VARCHAR(300),
    action      VARCHAR(20)  NOT NULL CHECK (action IN
                  ('created', 'updated', 'deleted')),
    changes     JSONB,       -- {"Field": {"from": …, "to": …}} for updates
    actor_id    INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_actor  ON audit_log(actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_time   ON audit_log(created_at);
