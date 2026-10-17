CREATE FUNCTION crm_case_creation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.stage NOT IN('Documents Under Review','Rejected','Cancelled','Closed/Lost') AND EXISTS(
 SELECT 1 FROM requirement_templates t WHERE lower(t.service)=lower(coalesce(NEW.service_category,'')) AND (t.destination='*' OR lower(t.destination)=lower(coalesce(NEW.destination,'')))) THEN
 RAISE EXCEPTION 'Start this case at Documents Under Review and complete its checklist before advancing' USING ERRCODE='P0001';
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER cases_creation_guard BEFORE INSERT ON cases FOR EACH ROW EXECUTE FUNCTION crm_case_creation_guard();
