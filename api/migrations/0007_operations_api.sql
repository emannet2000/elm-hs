CREATE FUNCTION crm_snapshot(actor integer) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
 'user',(SELECT to_jsonb(u)-'password_hash' FROM users u WHERE id=actor),
 'settings',(SELECT to_jsonb(s) FROM access_settings s),
 'users',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'role',role)) FROM users),'[]'),
 'leads',coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY id DESC) FROM leads l WHERE crm_can_access(actor,'lead',id)),'[]'),
 'clients',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY id DESC) FROM clients c WHERE crm_can_access(actor,'client',id)),'[]'),
 'cases',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY id DESC) FROM cases c WHERE crm_can_access(actor,'case',id)),'[]'),
 'requirements',coalesce((SELECT jsonb_agg(to_jsonb(r)||jsonb_build_object('ready',crm_requirement_ready(r))) FROM case_requirements r WHERE crm_can_access(actor,'case',case_id)),'[]'),
 'templates',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM requirement_templates t),'[]'),
 'documents',coalesce((SELECT jsonb_agg(to_jsonb(d)-'content') FROM documents d WHERE crm_can_access(actor,CASE WHEN lead_id IS NOT NULL THEN 'lead' ELSE 'client' END,coalesce(lead_id,client_id))),'[]'),
 'tasks',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY due_date) FROM tasks t WHERE crm_can_access(actor,CASE WHEN client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(client_id,lead_id))),'[]'),
 'history',coalesce((SELECT jsonb_agg(to_jsonb(h) ORDER BY created_at DESC) FROM case_history h WHERE crm_can_access(actor,'case',case_id)),'[]'),
 'communications',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY created_at DESC) FROM communications c WHERE crm_can_access(actor,CASE WHEN case_id IS NOT NULL THEN 'case' WHEN client_id IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(case_id,client_id,lead_id))),'[]'),
 'messageTemplates',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM message_templates t),'[]'),
 'notifications',coalesce((SELECT jsonb_agg(to_jsonb(n) ORDER BY created_at DESC) FROM notifications n WHERE recipient_id=actor),'[]'),
 'invoices',coalesce((SELECT jsonb_agg(to_jsonb(i)||jsonb_build_object('paid_minor',coalesce((SELECT sum(amount_minor) FROM payments WHERE invoice_id=i.id),0))) FROM invoices i WHERE crm_can_access(actor,'client',client_id)),'[]'),
 'payments',coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM payments p JOIN invoices i ON i.id=p.invoice_id WHERE crm_can_access(actor,'client',i.client_id)),'[]'),
 'installments',coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM installments p JOIN invoices i ON i.id=p.invoice_id WHERE crm_can_access(actor,'client',i.client_id)),'[]'),
 'portalLinks',coalesce((SELECT jsonb_agg(to_jsonb(p)-'token_hash') FROM portal_access p WHERE crm_can_access(actor,'client',client_id)),'[]')
) $$;

CREATE FUNCTION crm_assert_access(actor integer,kind text,record_id integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF record_id IS NULL OR NOT crm_can_access(actor,kind,record_id) THEN RAISE EXCEPTION 'Record unavailable or access denied' USING ERRCODE='P0001'; END IF;
END $$;

CREATE FUNCTION crm_command(actor integer,op text,p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE rid integer; cid integer; lid integer; kid integer; target integer; admin boolean; token text; kind text;
BEGIN
 PERFORM set_config('ecc.actor',actor::text,true);
 SELECT role='admin' INTO admin FROM users WHERE id=actor;
 IF NOT EXISTS(SELECT 1 FROM users WHERE id=actor AND role IN ('admin','consultant')) AND op<>'readNotification' THEN RAISE EXCEPTION 'Write access required' USING ERRCODE='P0001'; END IF;
 rid=nullif(p->>'id','')::integer;
 cid=nullif(p->>'client_id','')::integer; lid=nullif(p->>'lead_id','')::integer; kid=nullif(p->>'case_id','')::integer;
 CASE op
 WHEN 'template' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 INSERT INTO requirement_templates(service,destination,title,category) VALUES(p->>'service',coalesce(nullif(p->>'destination',''),'*'),p->>'title',nullif(p->>'category','')) RETURNING id INTO rid;
 INSERT INTO case_requirements(case_id,template_id,title,category) SELECT c.id,t.id,t.title,t.category FROM cases c JOIN requirement_templates t ON t.id=rid WHERE lower(coalesce(c.service_category,''))=lower(t.service) AND (t.destination='*' OR lower(t.destination)=lower(coalesce(c.destination,''))) ON CONFLICT DO NOTHING;
 WHEN 'updateTemplate' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 UPDATE requirement_templates SET service=p->>'service',destination=coalesce(nullif(p->>'destination',''),'*'),title=p->>'title',category=nullif(p->>'category','') WHERE id=rid;
 UPDATE case_requirements r SET title=t.title,category=t.category FROM requirement_templates t WHERE t.id=rid AND r.template_id=t.id;
 INSERT INTO case_requirements(case_id,template_id,title,category) SELECT c.id,t.id,t.title,t.category FROM cases c JOIN requirement_templates t ON t.id=rid WHERE lower(coalesce(c.service_category,''))=lower(t.service) AND (t.destination='*' OR lower(t.destination)=lower(coalesce(c.destination,''))) ON CONFLICT DO NOTHING;
 WHEN 'retireTemplate' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 DELETE FROM requirement_templates WHERE id=rid;
 WHEN 'removeRequirement' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 SELECT case_id INTO kid FROM case_requirements WHERE id=rid; PERFORM crm_assert_access(actor,'case',kid);
 INSERT INTO case_history(case_id,actor_id,event,details) SELECT case_id,actor,'Requirement removed',to_jsonb(r) FROM case_requirements r WHERE id=rid;
 DELETE FROM case_requirements WHERE id=rid;
 WHEN 'requirement' THEN
 PERFORM crm_assert_access(actor,'case',kid);
 INSERT INTO case_requirements(case_id,title,category) VALUES(kid,p->>'title',nullif(p->>'category','')) RETURNING id INTO rid;
 WHEN 'completeRequirement' THEN
 SELECT case_id INTO kid FROM case_requirements WHERE id=rid; PERFORM crm_assert_access(actor,'case',kid);
 IF nullif(p->>'document_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM documents d JOIN cases c ON c.client_id=d.client_id WHERE c.id=kid AND d.id=(p->>'document_id')::integer) THEN RAISE EXCEPTION 'Document belongs to another client' USING ERRCODE='P0001'; END IF;
 UPDATE case_requirements SET completed=(p->>'completed')::boolean,document_id=nullif(p->>'document_id','')::integer WHERE id=rid;
 INSERT INTO case_history(case_id,actor_id,event,details) VALUES(kid,actor,'Requirement updated',p);
 WHEN 'case' THEN
 SELECT client_id INTO cid FROM cases WHERE id=rid; PERFORM crm_assert_access(actor,'client',cid);
 UPDATE cases SET stage=coalesce(nullif(p->>'stage',''),stage),next_action=p->>'next_action',next_deadline=nullif(p->>'next_deadline','')::date WHERE id=rid;
 WHEN 'handoff' THEN
 PERFORM crm_assert_access(actor,'client',cid);
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required for handoff' USING ERRCODE='P0001'; END IF;
 UPDATE clients SET case_officer_id=(p->>'officer_id')::integer WHERE id=cid;
 WHEN 'task' THEN
 IF num_nonnulls(cid,lid,kid)<>1 THEN RAISE EXCEPTION 'Choose exactly one lead, client or case' USING ERRCODE='P0001'; END IF;
 IF kid IS NOT NULL THEN PERFORM crm_assert_access(actor,'case',kid); SELECT client_id INTO cid FROM cases WHERE id=kid;
 ELSIF cid IS NOT NULL THEN PERFORM crm_assert_access(actor,'client',cid);
 ELSE PERFORM crm_assert_access(actor,'lead',lid); END IF;
 INSERT INTO tasks(lead_id,client_id,case_id,title,description,due_date,priority,assigned_to_id) VALUES(lid,cid,kid,p->>'title',p->>'description',nullif(p->>'due_date','')::date,coalesce(p->>'priority','Medium'),coalesce(nullif(p->>'assigned_to_id','')::integer,actor)) RETURNING id INTO rid;
 WHEN 'taskStatus' THEN
 SELECT client_id,lead_id,case_id INTO cid,lid,kid FROM tasks WHERE id=rid;
 PERFORM crm_assert_access(actor,CASE WHEN cid IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(cid,lid));
 UPDATE tasks SET status=p->>'status' WHERE id=rid;
 WHEN 'document' THEN
 SELECT client_id,lead_id INTO cid,lid FROM documents WHERE id=rid;
 PERFORM crm_assert_access(actor,CASE WHEN cid IS NOT NULL THEN 'client' ELSE 'lead' END,coalesce(cid,lid));
 UPDATE documents SET category=coalesce(nullif(p->>'category',''),category),review_status=p->>'review_status',rejection_reason=p->>'rejection_reason',expires_on=nullif(p->>'expires_on','')::date,replaces_id=nullif(p->>'replaces_id','')::integer,reviewed_by=actor,reviewed_at=now() WHERE id=rid;
 WHEN 'communication' THEN
 IF num_nonnulls(cid,lid,kid)<>1 THEN RAISE EXCEPTION 'Choose exactly one lead, client or case' USING ERRCODE='P0001'; END IF;
 kind=CASE WHEN kid IS NOT NULL THEN 'case' WHEN cid IS NOT NULL THEN 'client' ELSE 'lead' END;
 PERFORM crm_assert_access(actor,kind,coalesce(kid,cid,lid));
 INSERT INTO communications(lead_id,client_id,case_id,kind,body,actor_id,portal_visible) VALUES(lid,cid,kid,p->>'kind',p->>'body',actor,coalesce((p->>'portal_visible')::boolean,false)) RETURNING id INTO rid;
 WHEN 'messageTemplate' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 INSERT INTO message_templates(title,body) VALUES(p->>'title',p->>'body') RETURNING id INTO rid;
 WHEN 'readNotification' THEN
 UPDATE notifications SET read_at=now() WHERE id=rid AND recipient_id=actor;
 WHEN 'invoice' THEN
 PERFORM crm_assert_access(actor,'client',cid);
 INSERT INTO invoices(client_id,description,currency,amount_minor,due_date,created_by) VALUES(cid,p->>'description',upper(p->>'currency'),(p->>'amount_minor')::bigint,(p->>'due_date')::date,actor) RETURNING id INTO rid;
 WHEN 'payment' THEN
 SELECT client_id INTO cid FROM invoices WHERE id=(p->>'invoice_id')::integer; PERFORM crm_assert_access(actor,'client',cid);
 INSERT INTO payments(invoice_id,amount_minor,reference,received_on,created_by) VALUES((p->>'invoice_id')::integer,(p->>'amount_minor')::bigint,p->>'reference',(p->>'received_on')::date,actor) RETURNING id INTO rid;
 WHEN 'installment' THEN
 SELECT client_id INTO cid FROM invoices WHERE id=(p->>'invoice_id')::integer; PERFORM crm_assert_access(actor,'client',cid);
 INSERT INTO installments(invoice_id,amount_minor,due_date) VALUES((p->>'invoice_id')::integer,(p->>'amount_minor')::bigint,(p->>'due_date')::date) RETURNING id INTO rid;
 WHEN 'portalLink' THEN
 PERFORM crm_assert_access(actor,'client',cid);
 token=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 INSERT INTO portal_access(client_id,token_hash,expires_at,created_by) VALUES(cid,sha256(convert_to(token,'UTF8')),now()+interval '7 days',actor);
 INSERT INTO audit_log(entity_type,entity_id,action,changes,actor_id) VALUES('client',cid,'updated',jsonb_build_object('portalLink','created'),actor);
 RETURN jsonb_build_object('token',token);
 WHEN 'revokePortal' THEN
 SELECT client_id INTO cid FROM portal_access WHERE id=rid; PERFORM crm_assert_access(actor,'client',cid);
 UPDATE portal_access SET revoked_at=now() WHERE id=rid;
 WHEN 'settings' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 UPDATE access_settings SET consultant_scope=p->>'consultant_scope';
 WHEN 'merge' THEN
 IF NOT admin THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='P0001'; END IF;
 target=(p->>'target_id')::integer; kind=p->>'kind';
 IF rid=target THEN RAISE EXCEPTION 'Select two different records' USING ERRCODE='P0001'; END IF;
 PERFORM pg_advisory_xact_lock(718441);
 IF kind='lead' THEN
 PERFORM id FROM leads WHERE id IN(rid,target) ORDER BY id FOR UPDATE;
 IF (SELECT count(*) FROM leads WHERE id IN(rid,target) AND converted_client_id IS NULL)<>2 THEN RAISE EXCEPTION 'Only two unconverted leads can be merged' USING ERRCODE='P0001'; END IF;
 UPDATE tasks SET lead_id=target WHERE lead_id=rid; UPDATE documents SET lead_id=target WHERE lead_id=rid;
 UPDATE activities SET lead_id=target WHERE lead_id=rid; UPDATE communications SET lead_id=target WHERE lead_id=rid;
 INSERT INTO activities(lead_id,type,description) SELECT target,'merge','Merged record: '||to_jsonb(l)::text FROM leads l WHERE id=rid;
 DELETE FROM leads WHERE id=rid;
 ELSIF kind='client' THEN
 PERFORM id FROM clients WHERE id IN(rid,target) ORDER BY id FOR UPDATE;
 IF (SELECT count(*) FROM clients WHERE id IN(rid,target))<>2 THEN RAISE EXCEPTION 'Client not found' USING ERRCODE='P0001'; END IF;
 p=p||jsonb_build_object('source_profile',(SELECT to_jsonb(cl) FROM clients cl WHERE id=rid));
 UPDATE cases SET client_id=target WHERE client_id=rid; UPDATE tasks SET client_id=target WHERE client_id=rid;
 UPDATE documents SET client_id=target WHERE client_id=rid; UPDATE communications SET client_id=target WHERE client_id=rid;
 UPDATE invoices SET client_id=target WHERE client_id=rid; UPDATE leads SET converted_client_id=target WHERE converted_client_id=rid;
 -- Revoke old portal links: merging must never broaden an existing bearer link's access.
 UPDATE portal_access SET revoked_at=now() WHERE client_id IN(rid,target);
 DELETE FROM clients WHERE id=rid;
 ELSE RAISE EXCEPTION 'Invalid merge type' USING ERRCODE='P0001'; END IF;
 ELSE RAISE EXCEPTION 'Unknown operation' USING ERRCODE='P0001';
 END CASE;
 INSERT INTO audit_log(entity_type,entity_id,action,changes,actor_id) VALUES('operations',coalesce(rid,cid,kid,0),'updated',jsonb_build_object('operation',op,'payload',p-'token'),actor);
 RETURN jsonb_build_object('updated',true,'id',rid);
END $$;

CREATE FUNCTION crm_portal(token text) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE cid integer;
BEGIN
 SELECT client_id INTO cid FROM portal_access WHERE token_hash=sha256(convert_to(token,'UTF8')) AND revoked_at IS NULL AND expires_at>now();
 IF cid IS NULL THEN RAISE EXCEPTION 'Portal link expired or revoked' USING ERRCODE='P0001'; END IF;
 RETURN jsonb_build_object(
 'client',(SELECT jsonb_build_object('id',id,'full_name',full_name,'client_number',client_number) FROM clients WHERE id=cid),
 'cases',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'service_category',service_category,'destination',destination,'stage',stage,'next_deadline',next_deadline,'next_action',next_action)) FROM cases WHERE client_id=cid),'[]'),
 'requirements',coalesce((SELECT jsonb_agg(jsonb_build_object('id',r.id,'case_id',r.case_id,'title',r.title,'category',r.category,'ready',crm_requirement_ready(r))) FROM case_requirements r JOIN cases c ON c.id=r.case_id WHERE c.client_id=cid),'[]'),
 'messages',coalesce((SELECT jsonb_agg(jsonb_build_object('body',m.body,'created_at',m.created_at,'sender',CASE WHEN m.actor_id IS NULL THEN 'You' ELSE 'ECC consultant' END) ORDER BY m.created_at) FROM communications m WHERE m.portal_visible AND (m.client_id=cid OR m.case_id IN(SELECT id FROM cases WHERE client_id=cid))),'[]'),
 'documents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'filename',filename,'category',category,'review_status',review_status,'rejection_reason',rejection_reason,'expires_on',expires_on)) FROM documents WHERE client_id=cid),'[]'));
END $$;
