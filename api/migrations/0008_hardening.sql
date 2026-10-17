CREATE TABLE auth_sessions (
 token_hash bytea PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days', revoked_at timestamptz);
CREATE FUNCTION crm_revoke_credentials() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.password_hash IS DISTINCT FROM OLD.password_hash OR NEW.role IS DISTINCT FROM OLD.role THEN
 UPDATE auth_sessions SET revoked_at=now() WHERE user_id=NEW.id;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER users_revoke AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION crm_revoke_credentials();
ALTER TABLE audit_log DROP CONSTRAINT audit_log_entity_type_check;
ALTER TABLE audit_log ADD CHECK(entity_type IN('lead','client','case','task','user','document','operations'));
ALTER TABLE notifications ADD COLUMN due_on date;
ALTER TABLE notifications ADD COLUMN resolved_at timestamptz;
CREATE OR REPLACE FUNCTION crm_generate_reminders() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO notifications(recipient_id,source_key,title,href,due_on)
 SELECT consultant_id,'lead:'||id||':'||next_followup,'Follow up: '||full_name,'/leads/'||id,next_followup FROM leads
 WHERE next_followup<=current_date+1 AND stage NOT IN ('Converted','Closed/Lost') AND consultant_id IS NOT NULL ON CONFLICT(recipient_id,source_key) DO UPDATE SET title=excluded.title,href=excluded.href,due_on=excluded.due_on,
 read_at=CASE WHEN notifications.resolved_at IS NOT NULL THEN NULL ELSE notifications.read_at END,
 created_at=CASE WHEN notifications.resolved_at IS NOT NULL THEN now() ELSE notifications.created_at END,resolved_at=NULL;
 INSERT INTO notifications(recipient_id,source_key,title,href,due_on)
 SELECT assigned_to_id,'task:'||id||':'||due_date,'Task due: '||title,'/workflow',due_date FROM tasks WHERE status<>'Done' AND due_date<=current_date+1 AND assigned_to_id IS NOT NULL ON CONFLICT(recipient_id,source_key) DO UPDATE SET title=excluded.title,href=excluded.href,due_on=excluded.due_on,
 read_at=CASE WHEN notifications.resolved_at IS NOT NULL THEN NULL ELSE notifications.read_at END,
 created_at=CASE WHEN notifications.resolved_at IS NOT NULL THEN now() ELSE notifications.created_at END,resolved_at=NULL;
 INSERT INTO notifications(recipient_id,source_key,title,href,due_on)
 SELECT cl.case_officer_id,'case:'||c.id||':'||c.next_deadline,'Case deadline: '||cl.full_name,'/clients/'||cl.id,c.next_deadline FROM cases c JOIN clients cl ON cl.id=c.client_id WHERE c.next_deadline<=current_date+3 AND c.stage NOT IN ('Completed','Cancelled','Closed/Lost') AND cl.case_officer_id IS NOT NULL ON CONFLICT(recipient_id,source_key) DO UPDATE SET title=excluded.title,href=excluded.href,due_on=excluded.due_on,
 read_at=CASE WHEN notifications.resolved_at IS NOT NULL THEN NULL ELSE notifications.read_at END,
 created_at=CASE WHEN notifications.resolved_at IS NOT NULL THEN now() ELSE notifications.created_at END,resolved_at=NULL;
 UPDATE notifications n SET resolved_at=now() WHERE resolved_at IS NULL AND NOT escalated AND (n.source_key LIKE 'lead:%' OR n.source_key LIKE 'task:%' OR n.source_key LIKE 'case:%') AND NOT (
 EXISTS(SELECT 1 FROM leads l WHERE n.source_key='lead:'||l.id||':'||l.next_followup AND l.stage NOT IN('Converted','Closed/Lost') AND l.consultant_id=n.recipient_id) OR
 EXISTS(SELECT 1 FROM tasks t WHERE n.source_key='task:'||t.id||':'||t.due_date AND t.status<>'Done' AND t.assigned_to_id=n.recipient_id) OR
 EXISTS(SELECT 1 FROM cases c JOIN clients cl ON cl.id=c.client_id WHERE n.source_key='case:'||c.id||':'||c.next_deadline AND c.stage NOT IN('Completed','Cancelled','Closed/Lost') AND cl.case_officer_id=n.recipient_id));
 INSERT INTO notifications(recipient_id,source_key,title,href,escalated,due_on)
 SELECT u.id,'escalation:'||n.id,'Overdue escalation: '||n.title,n.href,true,n.due_on FROM notifications n CROSS JOIN users u
 WHERE u.role='admin' AND NOT n.escalated AND n.created_at<now()-interval '1 day' AND n.due_on<current_date AND n.read_at IS NULL AND n.resolved_at IS NULL ON CONFLICT DO NOTHING;
 UPDATE notifications n SET resolved_at=now() WHERE n.escalated AND n.resolved_at IS NULL AND EXISTS(SELECT 1 FROM notifications source WHERE n.source_key='escalation:'||source.id AND source.resolved_at IS NOT NULL);
 DELETE FROM revoked_sessions WHERE expires_at<now();
 DELETE FROM auth_sessions WHERE expires_at<now();
END $$;
