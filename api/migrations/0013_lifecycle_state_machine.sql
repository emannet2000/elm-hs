-- ECC CRM 2.0 canonical lifecycle and database-enforced state machines.
-- PostgreSQL is the final guardrail: every writer (API, import, automation,
-- future AI tools) must obey the same transitions.

-- Normalize legacy lead labels into the canonical lifecycle.
UPDATE leads SET stage = CASE stage
  WHEN 'New Lead' THEN 'Lead'
  WHEN 'Contacted' THEN 'Lead'
  WHEN 'Initial Assessment' THEN 'Qualified'
  WHEN 'Consultation Booked' THEN 'Consultation'
  WHEN 'Proposal Sent' THEN 'Application/Deal'
  WHEN 'Converted' THEN 'Student/Client'
  WHEN 'Closed/Lost' THEN 'Lost'
  ELSE stage
END;

-- Normalize legacy case/application labels conservatively.
UPDATE cases SET stage = CASE stage
  WHEN 'Documents Under Review' THEN 'Processing'
  WHEN 'Closed/Lost' THEN 'Lost'
  ELSE stage
END;

CREATE OR REPLACE FUNCTION crm_lead_stage_allowed(old_stage text, new_stage text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT old_stage = new_stage OR CASE old_stage
    WHEN 'Lead' THEN new_stage IN ('Qualified','Lost')
    WHEN 'Qualified' THEN new_stage IN ('Consultation','Lost')
    WHEN 'Consultation' THEN new_stage IN ('Application/Deal','Lost')
    WHEN 'Application/Deal' THEN new_stage IN ('Student/Client','Lost')
    WHEN 'Student/Client' THEN new_stage IN ('Completed','Lost')
    WHEN 'Completed' THEN false
    WHEN 'Lost' THEN false
    ELSE false
  END
$$;

CREATE OR REPLACE FUNCTION crm_lead_state_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.stage NOT IN ('Lead','Qualified','Consultation','Application/Deal','Student/Client','Completed','Lost') THEN
      RAISE EXCEPTION 'Invalid lead lifecycle stage: %', NEW.stage USING ERRCODE='P0001';
    END IF;
    IF NEW.converted_client_id IS NOT NULL AND NEW.stage NOT IN ('Student/Client','Completed') THEN
      RAISE EXCEPTION 'A converted lead must be in Student/Client or Completed' USING ERRCODE='P0001';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.stage IS DISTINCT FROM OLD.stage AND NOT crm_lead_stage_allowed(OLD.stage, NEW.stage) THEN
    RAISE EXCEPTION 'Invalid lead transition: % -> %', OLD.stage, NEW.stage USING ERRCODE='P0001';
  END IF;

  IF NEW.stage IN ('Student/Client','Completed') AND NEW.converted_client_id IS NULL THEN
    RAISE EXCEPTION 'Convert the lead to a client before entering %', NEW.stage USING ERRCODE='P0001';
  END IF;
  IF NEW.converted_client_id IS NOT NULL AND NEW.stage NOT IN ('Student/Client','Completed') THEN
    RAISE EXCEPTION 'Converted leads cannot return to the sales lifecycle' USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS leads_state_guard ON leads;
CREATE TRIGGER leads_state_guard BEFORE INSERT OR UPDATE OF stage,converted_client_id ON leads
FOR EACH ROW EXECUTE FUNCTION crm_lead_state_guard();

-- Applications/cases use a separate state machine. Cancelled/Lost/Completed
-- are terminal. Requirements and money gates are checked before completion.
CREATE OR REPLACE FUNCTION crm_case_stage_allowed(old_stage text, new_stage text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT old_stage = new_stage OR CASE old_stage
    WHEN 'Submitted' THEN new_stage IN ('Processing','Cancelled','Lost')
    WHEN 'Processing' THEN new_stage IN ('Approved','Cancelled','Lost')
    WHEN 'Approved' THEN new_stage IN ('Completed','Cancelled','Lost')
    WHEN 'Completed' THEN false
    WHEN 'Cancelled' THEN false
    WHEN 'Lost' THEN false
    ELSE false
  END
$$;

CREATE OR REPLACE FUNCTION crm_case_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE outstanding bigint;
BEGIN
  IF NEW.stage IS DISTINCT FROM OLD.stage THEN
    IF NOT crm_case_stage_allowed(OLD.stage, NEW.stage) THEN
      RAISE EXCEPTION 'Invalid application transition: % -> %', OLD.stage, NEW.stage USING ERRCODE='P0001';
    END IF;

    IF NEW.stage IN ('Approved','Completed') AND EXISTS(
      SELECT 1 FROM case_requirements r
      WHERE r.case_id=OLD.id AND NOT crm_requirement_ready(r)
    ) THEN
      RAISE EXCEPTION 'Complete all requirements with approved, unexpired documents before entering %', NEW.stage USING ERRCODE='P0001';
    END IF;

    IF NEW.stage='Completed' THEN
      SELECT coalesce(sum(greatest(i.amount_minor-coalesce(p.paid,0),0)),0)
      INTO outstanding
      FROM invoices i
      LEFT JOIN (SELECT invoice_id,sum(amount_minor) paid FROM payments GROUP BY invoice_id) p
        ON p.invoice_id=i.id
      WHERE i.client_id=OLD.client_id;
      IF outstanding > 0 THEN
        RAISE EXCEPTION 'Outstanding client balance must be paid before completion' USING ERRCODE='P0001';
      END IF;
    END IF;
  END IF;
  NEW.updated_at=now();
  RETURN NEW;
END $$;

-- Existing cases may have historical/custom stages. New cases enter the
-- canonical application lifecycle at Submitted.
ALTER TABLE cases ALTER COLUMN stage SET DEFAULT 'Submitted';

-- Terminal leads must not keep ordinary open sales follow-ups alive.
CREATE OR REPLACE FUNCTION crm_close_terminal_lead_tasks() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stage IN ('Lost','Completed') AND NEW.stage IS DISTINCT FROM OLD.stage THEN
    UPDATE tasks
       SET status='Done'
     WHERE lead_id=NEW.id AND status<>'Done';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS leads_terminal_tasks ON leads;
CREATE TRIGGER leads_terminal_tasks AFTER UPDATE OF stage ON leads
FOR EACH ROW EXECUTE FUNCTION crm_close_terminal_lead_tasks();

-- Preserve an explicit lifecycle event stream in addition to the generic audit log.
CREATE TABLE IF NOT EXISTS lifecycle_events (
  id bigserial PRIMARY KEY,
  entity_type text NOT NULL CHECK(entity_type IN ('lead','case','client')),
  entity_id integer NOT NULL,
  from_state text,
  to_state text NOT NULL,
  actor_id integer REFERENCES users(id) ON DELETE SET NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lifecycle_events_entity ON lifecycle_events(entity_type,entity_id,created_at DESC);

CREATE OR REPLACE FUNCTION crm_record_lead_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stage IS DISTINCT FROM OLD.stage THEN
    INSERT INTO lifecycle_events(entity_type,entity_id,from_state,to_state,actor_id)
    VALUES('lead',NEW.id,OLD.stage,NEW.stage,crm_actor());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS leads_lifecycle_history ON leads;
CREATE TRIGGER leads_lifecycle_history AFTER UPDATE OF stage ON leads
FOR EACH ROW EXECUTE FUNCTION crm_record_lead_transition();

CREATE OR REPLACE FUNCTION crm_record_case_transition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stage IS DISTINCT FROM OLD.stage THEN
    INSERT INTO lifecycle_events(entity_type,entity_id,from_state,to_state,actor_id)
    VALUES('case',NEW.id,OLD.stage,NEW.stage,crm_actor());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS cases_lifecycle_history ON cases;
CREATE TRIGGER cases_lifecycle_history AFTER UPDATE OF stage ON cases
FOR EACH ROW EXECUTE FUNCTION crm_record_case_transition();
