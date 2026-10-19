-- Align database-side operational APIs and reminders with the ECC CRM 2.0
-- lifecycle introduced in 0013.

-- crm_command is defined in 0007.  Rather than duplicating that large function
-- here, enforce canonical case state input at the database boundary used by it.
CREATE OR REPLACE FUNCTION crm_case_command_state_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stage NOT IN ('Submitted','Processing','Approved','Completed','Cancelled','Lost') THEN
    RAISE EXCEPTION 'Invalid application lifecycle stage: %', NEW.stage USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS cases_command_state_guard ON cases;
CREATE TRIGGER cases_command_state_guard
BEFORE INSERT OR UPDATE OF stage ON cases
FOR EACH ROW EXECUTE FUNCTION crm_case_command_state_guard();

-- Conversion is deliberately available only from Application/Deal.  This
-- protects against accidental conversion from a raw or unqualified lead even
-- if a future UI or AI tool calls the conversion endpoint directly.
CREATE OR REPLACE FUNCTION crm_conversion_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.converted_client_id IS NOT NULL
     AND OLD.converted_client_id IS NULL
     AND OLD.stage <> 'Application/Deal' THEN
    RAISE EXCEPTION 'Lead must be at Application/Deal before conversion' USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS leads_conversion_entry_guard ON leads;
CREATE TRIGGER leads_conversion_entry_guard
BEFORE UPDATE OF converted_client_id ON leads
FOR EACH ROW EXECUTE FUNCTION crm_conversion_entry_guard();

-- Replace the legacy reminder generator so terminal canonical states never
-- generate ordinary follow-up/deadline notifications.
CREATE OR REPLACE FUNCTION crm_generate_reminders() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO notifications(recipient_id,source_key,title,href)
 SELECT consultant_id,'lead:'||id||':'||next_followup,'Follow up: '||full_name,'/leads/'||id FROM leads
 WHERE next_followup<=current_date+1
   AND stage NOT IN ('Student/Client','Completed','Lost')
   AND consultant_id IS NOT NULL ON CONFLICT DO NOTHING;

 INSERT INTO notifications(recipient_id,source_key,title,href)
 SELECT assigned_to_id,'task:'||id||':'||due_date,'Task due: '||title,'/operations.html?tab=tasks' FROM tasks
 WHERE status<>'Done' AND due_date<=current_date+1 AND assigned_to_id IS NOT NULL ON CONFLICT DO NOTHING;

 INSERT INTO notifications(recipient_id,source_key,title,href)
 SELECT cl.case_officer_id,'case:'||c.id||':'||c.next_deadline,'Application deadline: '||cl.full_name,'/clients/'||cl.id
 FROM cases c JOIN clients cl ON cl.id=c.client_id
 WHERE c.next_deadline<=current_date+3
   AND c.stage NOT IN ('Completed','Cancelled','Lost')
   AND cl.case_officer_id IS NOT NULL ON CONFLICT DO NOTHING;

 INSERT INTO notifications(recipient_id,source_key,title,href,escalated)
 SELECT u.id,'escalation:'||n.id,'Overdue escalation: '||n.title,n.href,true FROM notifications n CROSS JOIN users u
 WHERE u.role='admin' AND NOT n.escalated AND n.created_at<now()-interval '1 day' AND n.read_at IS NULL ON CONFLICT DO NOTHING;

 DELETE FROM revoked_sessions WHERE expires_at<now();
END $$;
