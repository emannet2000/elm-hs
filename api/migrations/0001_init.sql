-- ECC CRM schema (PostgreSQL)

CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    email         VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255)        NOT NULL,
    name          VARCHAR(100)        NOT NULL,
    role          VARCHAR(20)         NOT NULL DEFAULT 'consultant'
                  CHECK (role IN ('admin', 'consultant', 'viewer')),
    created_at    TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS leads (
    id             SERIAL PRIMARY KEY,
    lead_number    VARCHAR(20)  UNIQUE NOT NULL,
    full_name      VARCHAR(200) NOT NULL,
    email          VARCHAR(255),
    phone          VARCHAR(50),
    source         VARCHAR(100),
    consultant_id  INTEGER REFERENCES users(id) ON DELETE SET NULL,
    quality        VARCHAR(20),
    stage          VARCHAR(50) NOT NULL DEFAULT 'New Lead',
    destination    VARCHAR(100),
    service        VARCHAR(100),
    notes          TEXT,
    last_contact   DATE,
    next_followup  DATE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_leads_stage       ON leads(stage);
CREATE INDEX IF NOT EXISTS idx_leads_consultant  ON leads(consultant_id);
CREATE INDEX IF NOT EXISTS idx_leads_quality     ON leads(quality);

CREATE TABLE IF NOT EXISTS clients (
    id              SERIAL PRIMARY KEY,
    client_number   VARCHAR(32)  UNIQUE NOT NULL,
    full_name       VARCHAR(200) NOT NULL,
    email           VARCHAR(255),
    phone           VARCHAR(50),
    case_officer_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_clients_officer ON clients(case_officer_id);

CREATE TABLE IF NOT EXISTS cases (
    id               SERIAL PRIMARY KEY,
    client_id        INTEGER REFERENCES clients(id) ON DELETE CASCADE,
    service_category VARCHAR(100),
    destination      VARCHAR(100),
    stage            VARCHAR(100) NOT NULL DEFAULT 'Documents Under Review',
    next_deadline    DATE,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cases_client ON cases(client_id);

CREATE TABLE IF NOT EXISTS tasks (
    id             SERIAL PRIMARY KEY,
    lead_id        INTEGER REFERENCES leads(id) ON DELETE CASCADE,
    title          VARCHAR(255) NOT NULL,
    description    TEXT,
    due_date       DATE,
    priority       VARCHAR(20) NOT NULL DEFAULT 'Medium',
    status         VARCHAR(20) NOT NULL DEFAULT 'Pending'
                   CHECK (status IN ('Pending', 'In Progress', 'Done')),
    assigned_to_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tasks_lead    ON tasks(lead_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status  ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_due     ON tasks(due_date);

CREATE TABLE IF NOT EXISTS activities (
    id          SERIAL PRIMARY KEY,
    lead_id     INTEGER REFERENCES leads(id) ON DELETE CASCADE,
    type        VARCHAR(50) NOT NULL,
    description TEXT,
    date        DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_activities_lead ON activities(lead_id);
