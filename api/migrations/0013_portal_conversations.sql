ALTER TABLE communications ADD COLUMN portal_visible boolean NOT NULL DEFAULT false;
CREATE FUNCTION crm_client_message_visibility() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.actor_id IS NULL THEN NEW.portal_visible=true; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER communications_portal_visibility BEFORE INSERT ON communications FOR EACH ROW EXECUTE FUNCTION crm_client_message_visibility();
