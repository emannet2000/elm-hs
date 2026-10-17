CREATE OR REPLACE FUNCTION crm_can_access(actor integer, kind text, record_id integer) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT CASE kind WHEN 'lead' THEN EXISTS(SELECT 1 FROM leads WHERE id=record_id)
 WHEN 'client' THEN EXISTS(SELECT 1 FROM clients WHERE id=record_id)
 WHEN 'case' THEN EXISTS(SELECT 1 FROM cases WHERE id=record_id) ELSE false END
 AND EXISTS(SELECT 1 FROM users u, access_settings s WHERE u.id=actor AND
 (u.role IN ('admin','viewer') OR s.consultant_scope='all' OR
 CASE kind
 WHEN 'lead' THEN EXISTS(SELECT 1 FROM leads l LEFT JOIN clients cl ON cl.id=l.converted_client_id WHERE l.id=record_id AND CASE WHEN l.converted_client_id IS NOT NULL THEN cl.case_officer_id=actor ELSE l.consultant_id=actor END)
 WHEN 'client' THEN EXISTS(SELECT 1 FROM clients WHERE id=record_id AND case_officer_id=actor)
 WHEN 'case' THEN EXISTS(SELECT 1 FROM cases c JOIN clients cl ON cl.id=c.client_id WHERE c.id=record_id AND cl.case_officer_id=actor)
 ELSE false END)) $$;
ALTER TABLE invoices ADD CHECK(amount_minor<=9007199254740991);
ALTER TABLE payments ADD CHECK(amount_minor<=9007199254740991);
ALTER TABLE installments ADD CHECK(amount_minor<=9007199254740991);
ALTER TABLE tasks ADD CHECK(length(trim(title))>0);
ALTER TABLE tasks ADD CHECK(priority IN('Low','Medium','High'));
ALTER TABLE cases ADD CHECK(length(trim(stage))>0);
ALTER TABLE message_templates ADD CHECK(length(trim(title))>0 AND length(trim(body))>0);
CREATE FUNCTION crm_portal_message_notification() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.actor_id IS NULL AND NEW.client_id IS NOT NULL THEN
 INSERT INTO notifications(recipient_id,source_key,title,href) SELECT case_officer_id,'message:'||NEW.id,'New client message: '||full_name,'/workflow' FROM clients WHERE id=NEW.client_id AND case_officer_id IS NOT NULL ON CONFLICT DO NOTHING;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER communications_notify AFTER INSERT ON communications FOR EACH ROW EXECUTE FUNCTION crm_portal_message_notification();
CREATE FUNCTION crm_portal_upload_notification() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.uploaded_by IS NULL AND NEW.client_id IS NOT NULL THEN
 INSERT INTO notifications(recipient_id,source_key,title,href) SELECT case_officer_id,'upload:'||NEW.id,'Client document uploaded: '||full_name,'/workflow' FROM clients WHERE id=NEW.client_id AND case_officer_id IS NOT NULL ON CONFLICT DO NOTHING;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER documents_notify AFTER INSERT ON documents FOR EACH ROW EXECUTE FUNCTION crm_portal_upload_notification();
