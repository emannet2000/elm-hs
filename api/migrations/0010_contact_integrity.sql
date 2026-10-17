CREATE OR REPLACE FUNCTION crm_duplicate_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE found_id integer; converting integer;
BEGIN
 PERFORM pg_advisory_xact_lock(718441);
 IF TG_OP='UPDATE' AND NEW.email IS NOT DISTINCT FROM OLD.email AND NEW.phone IS NOT DISTINCT FROM OLD.phone THEN RETURN NEW; END IF;
 converting=nullif(current_setting('ecc.converting',true),'')::integer;
 IF TG_TABLE_NAME='leads' THEN
 SELECT id INTO found_id FROM leads WHERE id<>NEW.id AND stage<>'Converted' AND
 ((nullif(lower(trim(NEW.email)),'') IS NOT NULL AND lower(trim(email))=lower(trim(NEW.email))) OR
 (nullif(regexp_replace(NEW.phone,'[^0-9]','','g'),'') IS NOT NULL AND regexp_replace(phone,'[^0-9]','','g')=regexp_replace(NEW.phone,'[^0-9]','','g'))) LIMIT 1;
 IF found_id IS NULL THEN
 SELECT id INTO found_id FROM clients WHERE id IS DISTINCT FROM NEW.converted_client_id AND
 ((nullif(lower(trim(NEW.email)),'') IS NOT NULL AND lower(trim(email))=lower(trim(NEW.email))) OR
 (nullif(regexp_replace(NEW.phone,'[^0-9]','','g'),'') IS NOT NULL AND regexp_replace(phone,'[^0-9]','','g')=regexp_replace(NEW.phone,'[^0-9]','','g'))) LIMIT 1;
 END IF;
 ELSE
 SELECT id INTO found_id FROM clients WHERE id<>NEW.id AND
 ((nullif(lower(trim(NEW.email)),'') IS NOT NULL AND lower(trim(email))=lower(trim(NEW.email))) OR
 (nullif(regexp_replace(NEW.phone,'[^0-9]','','g'),'') IS NOT NULL AND regexp_replace(phone,'[^0-9]','','g')=regexp_replace(NEW.phone,'[^0-9]','','g'))) LIMIT 1;
 IF found_id IS NULL THEN
 SELECT id INTO found_id FROM leads WHERE id IS DISTINCT FROM converting AND converted_client_id IS DISTINCT FROM NEW.id AND stage<>'Converted' AND
 ((nullif(lower(trim(NEW.email)),'') IS NOT NULL AND lower(trim(email))=lower(trim(NEW.email))) OR
 (nullif(regexp_replace(NEW.phone,'[^0-9]','','g'),'') IS NOT NULL AND regexp_replace(phone,'[^0-9]','','g')=regexp_replace(NEW.phone,'[^0-9]','','g'))) LIMIT 1;
 END IF;
 END IF;
 IF found_id IS NOT NULL THEN RAISE EXCEPTION 'A matching lead or client already exists (record #%); review contacts before saving',found_id USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION crm_conversion_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.stage='Converted' AND NEW.converted_client_id IS NULL THEN RAISE EXCEPTION 'Use Convert to client to preserve documents and outstanding work' USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER leads_conversion_guard BEFORE INSERT OR UPDATE ON leads FOR EACH ROW EXECUTE FUNCTION crm_conversion_guard();
