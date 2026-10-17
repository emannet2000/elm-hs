-- Workflow, communication, finance and portal records. Monetary values are integer minor units.
ALTER TABLE tasks DROP CONSTRAINT tasks_lead_id_fkey;
ALTER TABLE tasks ADD CONSTRAINT tasks_lead_id_fkey FOREIGN KEY(lead_id) REFERENCES leads(id) ON DELETE SET NULL;
ALTER TABLE tasks ADD COLUMN client_id integer REFERENCES clients(id) ON DELETE CASCADE;
ALTER TABLE tasks ADD COLUMN case_id integer REFERENCES cases(id) ON DELETE CASCADE;
ALTER TABLE cases ADD COLUMN next_action text;
ALTER TABLE cases ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE documents ADD COLUMN category text NOT NULL DEFAULT 'Other';
ALTER TABLE documents ADD COLUMN review_status text NOT NULL DEFAULT 'Pending' CHECK (review_status IN ('Pending','Approved','Rejected'));
ALTER TABLE documents ADD COLUMN rejection_reason text;
ALTER TABLE documents ADD COLUMN expires_on date;
ALTER TABLE documents ADD COLUMN replaces_id integer REFERENCES documents(id) ON DELETE SET NULL;
ALTER TABLE documents ADD COLUMN reviewed_by integer REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE documents ADD COLUMN reviewed_at timestamptz;
CREATE UNIQUE INDEX documents_one_replacement ON documents(replaces_id) WHERE replaces_id IS NOT NULL;
CREATE INDEX tasks_client ON tasks(client_id);
CREATE INDEX tasks_case ON tasks(case_id);
CREATE TABLE requirement_templates (
 id serial PRIMARY KEY, service text NOT NULL, destination text NOT NULL DEFAULT '*',
 title text NOT NULL CHECK (length(trim(title))>0), category text,
 UNIQUE(service,destination,title));
CREATE TABLE case_requirements (
 id serial PRIMARY KEY, case_id integer NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
 template_id integer REFERENCES requirement_templates(id) ON DELETE SET NULL,
 title text NOT NULL CHECK (length(trim(title))>0), category text,
 completed boolean NOT NULL DEFAULT false, document_id integer REFERENCES documents(id) ON DELETE SET NULL,
 UNIQUE(case_id,template_id));
CREATE TABLE case_history (
 id bigserial PRIMARY KEY, case_id integer NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
 actor_id integer REFERENCES users(id) ON DELETE SET NULL, event text NOT NULL,
 details jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE communications (
 id bigserial PRIMARY KEY, lead_id integer REFERENCES leads(id) ON DELETE CASCADE,
 client_id integer REFERENCES clients(id) ON DELETE CASCADE,
 case_id integer REFERENCES cases(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('Note','Call','Email','Message')),
 body text NOT NULL CHECK(length(trim(body))>0), actor_id integer REFERENCES users(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(), CHECK(num_nonnulls(lead_id,client_id,case_id)=1));
CREATE TABLE message_templates (id serial PRIMARY KEY, title text NOT NULL, body text NOT NULL);
INSERT INTO message_templates(title,body) VALUES
 ('Document request','Please upload the outstanding documents listed in your client portal.'),
 ('Follow-up','Following up on your application. Please let us know a convenient time to speak.');
CREATE TABLE notifications (
 id bigserial PRIMARY KEY, recipient_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 source_key text NOT NULL, title text NOT NULL, href text NOT NULL, escalated boolean NOT NULL DEFAULT false,
 read_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(recipient_id,source_key));
CREATE TABLE invoices (
 id serial PRIMARY KEY, client_id integer NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
 description text NOT NULL CHECK(length(trim(description))>0), currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'),
 amount_minor bigint NOT NULL CHECK(amount_minor>0), due_date date NOT NULL,
 created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE installments (
 id serial PRIMARY KEY, invoice_id integer NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
 amount_minor bigint NOT NULL CHECK(amount_minor>0), due_date date NOT NULL);
CREATE TABLE payments (
 id serial PRIMARY KEY, invoice_id integer NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
 amount_minor bigint NOT NULL CHECK(amount_minor>0), reference text NOT NULL UNIQUE CHECK(length(trim(reference))>0),
 received_on date NOT NULL, created_by integer REFERENCES users(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE portal_access (
 id serial PRIMARY KEY, client_id integer NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
 token_hash bytea NOT NULL UNIQUE, expires_at timestamptz NOT NULL, revoked_at timestamptz,
 created_by integer REFERENCES users(id) ON DELETE SET NULL);
CREATE TABLE revoked_sessions (token_hash bytea PRIMARY KEY, expires_at timestamptz NOT NULL DEFAULT now()+interval '8 days');
CREATE TABLE access_settings (id boolean PRIMARY KEY DEFAULT true CHECK(id), consultant_scope text NOT NULL DEFAULT 'all' CHECK(consultant_scope IN ('all','assigned')));
INSERT INTO access_settings DEFAULT VALUES;

CREATE FUNCTION crm_actor() RETURNS integer LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('ecc.actor',true),'')::integer $$;
CREATE FUNCTION crm_can_access(actor integer, kind text, record_id integer) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM users u, access_settings s WHERE u.id=actor AND
 (u.role IN ('admin','viewer') OR s.consultant_scope='all' OR
 CASE kind
 WHEN 'lead' THEN EXISTS(SELECT 1 FROM leads WHERE id=record_id AND consultant_id=actor)
 WHEN 'client' THEN EXISTS(SELECT 1 FROM clients WHERE id=record_id AND case_officer_id=actor)
 WHEN 'case' THEN EXISTS(SELECT 1 FROM cases c JOIN clients cl ON cl.id=c.client_id WHERE c.id=record_id AND cl.case_officer_id=actor)
 ELSE false END)) $$;
CREATE FUNCTION crm_apply_templates() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO case_requirements(case_id,template_id,title,category)
 SELECT NEW.id,t.id,t.title,t.category FROM requirement_templates t
 WHERE lower(t.service)=lower(coalesce(NEW.service_category,'')) AND (t.destination='*' OR lower(t.destination)=lower(coalesce(NEW.destination,'')))
 ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
CREATE TRIGGER cases_templates AFTER INSERT OR UPDATE OF service_category,destination ON cases FOR EACH ROW EXECUTE FUNCTION crm_apply_templates();
CREATE FUNCTION crm_requirement_ready(r case_requirements) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT r.completed AND (r.category IS NULL OR EXISTS(
 SELECT 1 FROM documents d JOIN cases c ON c.id=r.case_id
 WHERE d.id=r.document_id AND d.client_id=c.client_id AND d.category=r.category
 AND d.review_status='Approved' AND (d.expires_on IS NULL OR d.expires_on>=current_date)
 AND NOT EXISTS(SELECT 1 FROM documents replacement WHERE replacement.replaces_id=d.id))) $$;
CREATE FUNCTION crm_case_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.stage IS DISTINCT FROM OLD.stage AND NEW.stage NOT IN ('Documents Under Review','Cancelled','Closed/Lost') THEN
 IF EXISTS(SELECT 1 FROM case_requirements r WHERE r.case_id=OLD.id AND NOT crm_requirement_ready(r)) THEN
 RAISE EXCEPTION 'Complete all requirements with approved, unexpired documents before changing stage' USING ERRCODE='P0001';
 END IF;
 END IF;
 NEW.updated_at=now();
 RETURN NEW;
END $$;
CREATE TRIGGER cases_guard BEFORE UPDATE ON cases FOR EACH ROW EXECUTE FUNCTION crm_case_guard();
CREATE FUNCTION crm_case_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO case_history(case_id,actor_id,event,details) VALUES(NEW.id,crm_actor(),TG_OP,jsonb_build_object('before',CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,'after',to_jsonb(NEW)));
 RETURN NEW;
END $$;
CREATE TRIGGER cases_history AFTER INSERT OR UPDATE ON cases FOR EACH ROW EXECUTE FUNCTION crm_case_history();
CREATE FUNCTION crm_handoff_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.case_officer_id IS DISTINCT FROM OLD.case_officer_id THEN
 INSERT INTO case_history(case_id,actor_id,event,details) SELECT id,crm_actor(),'Handoff',jsonb_build_object('from',OLD.case_officer_id,'to',NEW.case_officer_id) FROM cases WHERE client_id=NEW.id;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER clients_handoff AFTER UPDATE ON clients FOR EACH ROW EXECUTE FUNCTION crm_handoff_history();
CREATE FUNCTION crm_conversion_tasks() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.converted_client_id IS DISTINCT FROM OLD.converted_client_id AND NEW.converted_client_id IS NOT NULL THEN
 UPDATE tasks SET client_id=NEW.converted_client_id WHERE lead_id=NEW.id;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER leads_tasks AFTER UPDATE ON leads FOR EACH ROW EXECUTE FUNCTION crm_conversion_tasks();
UPDATE tasks t SET client_id=l.converted_client_id FROM leads l WHERE t.lead_id=l.id AND l.converted_client_id IS NOT NULL;
CREATE FUNCTION crm_duplicate_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE found_id integer;
BEGIN
 -- Serialize competing contact writes, including imports, against a single transaction lock.
 PERFORM pg_advisory_xact_lock(718441);
 IF TG_OP='UPDATE' AND NEW.email IS NOT DISTINCT FROM OLD.email AND NEW.phone IS NOT DISTINCT FROM OLD.phone THEN RETURN NEW; END IF;
 IF TG_TABLE_NAME='leads' THEN
 SELECT id INTO found_id FROM leads WHERE id<>NEW.id AND stage<>'Converted' AND
 ((nullif(lower(trim(NEW.email)),'') IS NOT NULL AND lower(trim(email))=lower(trim(NEW.email))) OR
 (nullif(regexp_replace(NEW.phone,'[^0-9]','','g'),'') IS NOT NULL AND regexp_replace(phone,'[^0-9]','','g')=regexp_replace(NEW.phone,'[^0-9]','','g'))) LIMIT 1;
 ELSE
 SELECT id INTO found_id FROM clients WHERE id<>NEW.id AND
 ((nullif(lower(trim(NEW.email)),'') IS NOT NULL AND lower(trim(email))=lower(trim(NEW.email))) OR
 (nullif(regexp_replace(NEW.phone,'[^0-9]','','g'),'') IS NOT NULL AND regexp_replace(phone,'[^0-9]','','g')=regexp_replace(NEW.phone,'[^0-9]','','g'))) LIMIT 1;
 END IF;
 IF found_id IS NOT NULL THEN RAISE EXCEPTION 'Matching contact already exists: % %',TG_TABLE_NAME,found_id USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER leads_duplicates BEFORE INSERT OR UPDATE ON leads FOR EACH ROW EXECUTE FUNCTION crm_duplicate_guard();
CREATE TRIGGER clients_duplicates BEFORE INSERT OR UPDATE ON clients FOR EACH ROW EXECUTE FUNCTION crm_duplicate_guard();
CREATE FUNCTION crm_document_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.review_status='Rejected' AND nullif(trim(NEW.rejection_reason),'') IS NULL THEN RAISE EXCEPTION 'A rejection reason is required' USING ERRCODE='P0001'; END IF;
 IF NEW.replaces_id IS NOT NULL AND (TG_OP='INSERT' OR NEW.replaces_id IS DISTINCT FROM OLD.replaces_id) AND NOT EXISTS(SELECT 1 FROM documents d WHERE d.id=NEW.replaces_id AND d.id<>NEW.id AND d.lead_id IS NOT DISTINCT FROM NEW.lead_id AND d.client_id IS NOT DISTINCT FROM NEW.client_id AND d.id<NEW.id) THEN
 RAISE EXCEPTION 'Replacement must reference an older document for the same contact' USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER documents_guard BEFORE INSERT OR UPDATE ON documents FOR EACH ROW EXECUTE FUNCTION crm_document_guard();
CREATE FUNCTION crm_payment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE total bigint; paid bigint;
BEGIN
 SELECT amount_minor INTO total FROM invoices WHERE id=NEW.invoice_id FOR UPDATE;
 SELECT coalesce(sum(amount_minor),0) INTO paid FROM payments WHERE invoice_id=NEW.invoice_id AND id<>NEW.id;
 IF paid+NEW.amount_minor>total THEN RAISE EXCEPTION 'Payment exceeds outstanding balance' USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER payments_guard BEFORE INSERT OR UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION crm_payment_guard();
CREATE FUNCTION crm_installment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE total bigint; scheduled bigint;
BEGIN
 SELECT amount_minor INTO total FROM invoices WHERE id=NEW.invoice_id FOR UPDATE;
 SELECT coalesce(sum(amount_minor),0) INTO scheduled FROM installments WHERE invoice_id=NEW.invoice_id AND id<>NEW.id;
 IF scheduled+NEW.amount_minor>total THEN RAISE EXCEPTION 'Installments exceed invoice total' USING ERRCODE='P0001'; END IF; RETURN NEW;
END $$;
CREATE TRIGGER installments_guard BEFORE INSERT OR UPDATE ON installments FOR EACH ROW EXECUTE FUNCTION crm_installment_guard();

CREATE FUNCTION crm_generate_reminders() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO notifications(recipient_id,source_key,title,href)
 SELECT consultant_id,'lead:'||id||':'||next_followup,'Follow up: '||full_name,'/leads/'||id FROM leads
 WHERE next_followup<=current_date+1 AND stage NOT IN ('Converted','Closed/Lost') AND consultant_id IS NOT NULL ON CONFLICT DO NOTHING;
 INSERT INTO notifications(recipient_id,source_key,title,href)
 SELECT assigned_to_id,'task:'||id||':'||due_date,'Task due: '||title,'/operations.html?tab=tasks' FROM tasks WHERE status<>'Done' AND due_date<=current_date+1 AND assigned_to_id IS NOT NULL ON CONFLICT DO NOTHING;
 INSERT INTO notifications(recipient_id,source_key,title,href)
 SELECT cl.case_officer_id,'case:'||c.id||':'||c.next_deadline,'Case deadline: '||cl.full_name,'/clients/'||cl.id FROM cases c JOIN clients cl ON cl.id=c.client_id WHERE c.next_deadline<=current_date+3 AND c.stage NOT IN ('Completed','Cancelled','Closed/Lost') AND cl.case_officer_id IS NOT NULL ON CONFLICT DO NOTHING;
 INSERT INTO notifications(recipient_id,source_key,title,href,escalated)
 SELECT u.id,'escalation:'||n.id,'Overdue escalation: '||n.title,n.href,true FROM notifications n CROSS JOIN users u
 WHERE u.role='admin' AND NOT n.escalated AND n.created_at<now()-interval '1 day' AND n.read_at IS NULL ON CONFLICT DO NOTHING;
 DELETE FROM revoked_sessions WHERE expires_at<now();
END $$;
