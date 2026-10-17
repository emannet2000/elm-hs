CREATE OR REPLACE FUNCTION crm_handoff_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.case_officer_id IS DISTINCT FROM OLD.case_officer_id THEN
 INSERT INTO case_history(case_id,actor_id,event,details) SELECT id,crm_actor(),'Handoff',jsonb_build_object('from',OLD.case_officer_id,'to',NEW.case_officer_id) FROM cases WHERE client_id=NEW.id;
 UPDATE tasks SET assigned_to_id=NEW.case_officer_id WHERE client_id=NEW.id AND status<>'Done' AND assigned_to_id IS NOT DISTINCT FROM OLD.case_officer_id;
 END IF; RETURN NEW;
END $$;
