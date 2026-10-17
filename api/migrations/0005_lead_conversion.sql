-- Converting a lead into a client used to DELETE the lead, which cascaded
-- away its tasks, activities and documents.  Leads are now kept as history
-- (stage = 'Converted') and point at the client they became.

ALTER TABLE leads ADD COLUMN IF NOT EXISTS converted_client_id INTEGER
    REFERENCES clients(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_leads_converted_client ON leads(converted_client_id);
