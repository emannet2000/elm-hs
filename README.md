# ECC CRM

A small immigration-consultancy CRM: a Haskell (Scotty + PostgreSQL) JSON API and
an Elm single-page app that share one repository.

```
.
├── api/            Haskell REST API (Scotty + postgresql-simple)
│   ├── app/Main.hs         entry point, CLI subcommands, static file server
│   ├── src/ECC/            Config, DB, Models, Routes, Auth, Pool, RateLimit, …
│   └── migrations/         numbered SQL migrations (applied on startup)
└── web/            Elm SPA
    ├── src/                Main, State, Views, Api, Types, Ui
    ├── public/css/         source-of-truth stylesheet
    └── dist/               built SPA served by the API (index.html, main.js, css/)
```

## Features

- JWT authentication with roles (`admin`, `consultant`, `viewer`).
- Leads pipeline with stages, quality, source, follow-up dates, notes and a
  per-lead activity timeline.
- Lead → client conversion that **keeps the lead** as history
  (`stage = 'Converted'`, `converted_client_id`) and moves its documents across.
- Cases, tasks, document upload/download, CSV import/export, and an admin audit
  trail of every edit and deletion.
- Server-side filtering, sorting **and pagination** for the leads and clients
  lists (the browser no longer downloads whole tables).

## Requirements

- GHC 9.6+ and Cabal 3.8+ (built with GHC 9.6.6 / Cabal 3.10)
- PostgreSQL 13+
- Elm 0.19.1 (only needed to rebuild the frontend)
- The C development files GHC links against: `libgmp-dev` and `libpq-dev`
  (plus a `pg_config` on `PATH`). Without those packages the build fails with
  `cannot find -lgmp` / `Library requirements (PostgreSQL) not met`.

## Quick start

### 1. Database

```bash
createdb ecc_crm
```

### 2. Configuration

```bash
cd api
cp .env.example .env      # then edit it
export $(grep -v '^#' .env | xargs)
```

`JWT_SECRET` is **required** (≥ 32 characters) unless you explicitly set
`ALLOW_INSECURE_DEV=1` for local work — see [Security](#security).

### 3. Run the API

```bash
cd api
cabal run ecc-crm-api
```

On startup the API connects to PostgreSQL, applies any pending migrations from
`migrations/`, optionally seeds demo data, and listens on `PORT` (default
`4000`). It refuses to start with a clear message if the database is
unreachable.

With `SEED_DEMO=1` (the default) an empty database is seeded with demo accounts —
all use the password `password123`:

| Email           | Role       |
| --------------- | ---------- |
| `admin@ecc.com` | admin      |
| `aya@ecc.com`   | consultant |
| `marco@ecc.com` | consultant |
| `hana@ecc.com`  | consultant |
| `devon@ecc.com` | viewer     |

### 4. Frontend

The API serves the compiled SPA from `WEB_DIST` (`../web/dist` by default) for
every non-`/api` path, so once `web/dist` is built you only run the one process.
Open <http://localhost:4000>.

To rebuild the SPA after changing `web/src`:

```bash
cd web
elm make src/Main.elm --output=dist/main.js          # development build
# or, for a smaller/faster release build:
elm make src/Main.elm --output=dist/main.js --optimize
```

During UI development you can instead use `elm reactor` (or another dev server)
and point it at the API on `:4000`; `Api.computeBase` derives the API URL from
the page location.

## CLI subcommands

```bash
cabal run ecc-crm-api -- adduser <email> <name> <role> <password>
cabal run ecc-crm-api -- reset-password <email> <new-password>
cabal run ecc-crm-api -- wipe-data --yes      # destructive: needs --yes
```

`wipe-data` clears all CRM rows (leads, clients, tasks, documents, audit) but
keeps user accounts and does **not** reset the `counters` table, so newly
created records keep advancing their numbers.

## Configuration reference

| Variable             | Default                                          | Notes |
| -------------------- | ------------------------------------------------ | ----- |
| `PORT`               | `4000`                                           | HTTP listen port |
| `DATABASE_URL`       | `host=localhost dbname=ecc_crm user=postgres password=postgres` | libpq connection string |
| `DB_POOL_SIZE`       | `10`                                             | Max pooled DB connections |
| `JWT_SECRET`         | —                                                | **Required**, ≥ 32 chars |
| `ALLOW_INSECURE_DEV` | off                                              | `1` allows a missing/short secret (dev only) |
| `SEED_DEMO`          | `1`                                              | Seed demo data into an empty DB |
| `WEB_DIST`           | `../web/dist`                                    | Static SPA root |

## API overview

All endpoints live under `/api` and return JSON. Mutating requests need the
`Authorization: Bearer <token>` header (a `?token=` query parameter is also
accepted for `<a>`-based downloads).

| Area     | Endpoints |
| -------- | --------- |
| Auth     | `POST /auth/login`, `GET /auth/me`, `PUT /auth/password` |
| Leads    | `GET/POST /leads`, `GET/PATCH/DELETE /leads/:id`, `POST /leads/:id/advance`, `POST /leads/:id/convert`, `POST /leads/:id/notes`, `POST /leads/:id/documents` |
| Clients  | `GET/POST /clients`, `GET/PATCH/DELETE /clients/:id`, `POST /clients/:id/cases`, `POST /clients/:id/documents` |
| Tasks    | `GET/POST /tasks`, `PATCH/DELETE /tasks/:id` |
| Cases    | `DELETE /cases/:id` |
| Docs     | `GET /documents/:id/download`, `DELETE /documents/:id` |
| Bulk/CSV | `POST /bulk/leads`, `POST /import/leads`, `GET /export/leads.csv`, `GET /export/clients.csv` |
| Misc     | `GET /users`, `POST /users`, `PATCH/DELETE /users/:id`, `GET /stats`, `GET /audit`, `GET /activities`, `GET /health` |

### Pagination

`GET /leads` and `GET /clients` accept `limit` (default `100`, max `500`) and
`offset`, and respond with `{ "items": [...], "total": N }`. Leads additionally
accept `q`, `stage`, `quality`, `source`, `sort` and `dir`.

## Security

- **JWT secret is mandatory.** The process refuses to boot without a
  sufficiently long `JWT_SECRET`, avoiding a silent, forgeable default.
- **Constant-time token signature comparison.**
- **Login throttling:** 10 failed sign-ins per email address per 15 minutes
  (in-memory, per process — put a real limiter or proxy in front for multi-instance deployments).
- **Connection pooling:** requests never share a single libpq connection across
  Warp worker threads (the previous, unsafe behaviour).
- **JSON error responses:** unhandled exceptions are logged server-side and
  returned as a generic JSON `500`, never an HTML stack trace.
- API requests are same-origin by default; `CORS_ORIGIN` can allow one explicit development frontend origin.

## Database migrations

Migrations are plain SQL files named `NNNN_description.sql` in `api/migrations/`.
They are applied in order inside a transaction and recorded in a
`schema_migrations` table, so they run once. Add new files rather than editing
existing ones.

## Development notes

- `cabal build` type-checks the API; `-Wall` is enabled.
- `elm make src/Main.elm --output=/dev/null` type-checks the frontend.
- `web/public/css/app.css` is the source stylesheet; the copy under
  `web/dist/css/app.css` is what the running app serves — keep them in sync when
  editing styles without a full build.

## Workflow workspace and client portal

Open **Workflow & billing** in the sidebar (`/workflow`). The Haskell API and Elm
application remain the main application; the workflow tools run in a same-origin
embedded workspace. Source assets live in `web/public`; `scripts/build.sh` builds
both applications and synchronizes the served files.

- **Applications:** configure service/destination requirement templates in
  Administration. Templates also populate matching existing applications. Add
  case-specific requirements, link document evidence, and mark steps complete.
  Stage changes are blocked if requirements lack approved, current evidence.
  Replacing a document makes evidence pointing to its old version outstanding.
- **Tasks:** attach work to a lead, client or application, assign a person, set a
  deadline and priority, and change status. Conversion retains the lead history
  and links its tasks to the new client. Conversion is transactional and locked.
- **Documents:** review uploads, give rejection reasons, categorize files, record
  expiry dates, and identify the previous version being replaced. Uploads accept
  PDF/JPEG/PNG with matching file signatures, up to 25 MB.
- **Reminders:** a server worker runs every minute, persists reminders before
  deadlines and follow-ups, resolves reminders when their work changes, and
  escalates overdue reminders left unread for a day to admins. Reminder history
  is available in the inbox. Client uploads/messages notify the case officer.
  Notifications are in-app; email/SMS delivery is not connected.
- **Communications:** log notes, calls, emails and messages against a lead,
  client or application. Admins can create reusable message templates. Choose client portal visibility to share a message in the portal; internal
  entries stay private. Logging an email/message does not send it through an external provider.
- **Reports:** lead cohort conversion, lead sources, current workload, overdue
  cases and recorded time in application stages. Stage timing begins when this
  feature is installed, rather than inventing historical timings.
- **Billing:** invoices, installment schedules, payments with unique references,
  outstanding balances and printable receipts. Amounts are integer minor units
  (for example, `10000` means PHP 100.00). Overpayments and installment schedules
  exceeding the invoice total are rejected under a database lock. Payment entry
  records received funds; there is no payment gateway or accounting integration.
- **Duplicates:** email and normalized phone matches are blocked across active
  leads and clients, including CSV import. Import reports invalid rows and keeps
  successful rows. Admins can merge two leads or two clients; the destination
  retains its profile and related work is moved. Client merges revoke existing
  portal links. Review the records before merging; this removes the source row.
- **Access:** admins manage users, handoffs, templates, merges and record scope.
  Consultants can read all records or only their assigned records, according to
  the admin setting. Viewers can read all records and cannot mutate them.
- **Client portal:** generate a seven-day link, share it privately, and revoke it
  when needed. The portal shows only client-facing progress/requirements and
  documents, and lets the client upload files or message the consultant. Tokens
  are stored hashed server-side and are passed in a header after the page opens.

Checklist templates and document categories are business configuration; no
country-specific immigration requirements are preloaded. The theme, emblem and
motif assets were copied from `/home/eman/ecc-crm-myapp6`, with adapters for this
repository's Elm views. The reference application's backend and data were not
copied.

### Sessions and account recovery

Sessions are registered server-side. Existing tokens issued before this upgrade
require signing in again. Signing out revokes the token. Password/role changes
revoke affected sessions; an authenticated password change retains the current
session while revoking the others. Admins can reset passwords from Users, or use
`reset-password` on the CLI. This is administrator-assisted recovery; an email
reset service is not configured.

Same-origin requests are the default. Set `CORS_ORIGIN` to one explicit frontend
origin only if you use a separate development server. Production should use
HTTPS, a random `JWT_SECRET`, `SEED_DEMO=0`, and a reverse proxy with a body limit;
see `docs/deployment/nginx.conf.example`. Do not use the example signing secret.

### Backups and restoration

`DATABASE_URL=... ECC_BACKUP_DIR=... ./scripts/backup.sh` produces a restricted
PostgreSQL custom-format dump, including stored documents. It validates the dump
catalog before promoting the temporary file. Copy backups to separate, protected
storage and choose a retention policy appropriate for your organization.

For scheduled backups, install the example service/timer from `docs/deployment/`,
create `/etc/ecc-crm/backup.env` with `DATABASE_URL` and `ECC_BACKUP_DIR`, adapt the
installation paths and service user, and enable `ecc-backup.timer` on your server.
These files do not automatically install or change system services.

Regularly test a backup using:

```bash
ECC_RESTORE_DATABASE_URL='dbname=ecc_restore_check ...' ./scripts/verify-restore.sh /path/to/backup.dump
```

Use a dedicated empty verification database. The script refuses existing tables
and restores transactionally without cleaning a database. It prints record
counts after successful restoration. Scheduling and an actual restore drill
must be performed on the deployment host.

### Verification

```bash
cd api && cabal build && cabal test auth-tests
cd ../web && elm make src/Main.elm --optimize --output=dist/main.js
cd .. && npm install && npm test
./scripts/test-database.sh
```

Database integration tests initialize a temporary PostgreSQL cluster and use its
single-user backend, requiring no network listener or running service. They
exercise checklist blockers, expiry, task conversion, history, permissions,
duplicates, billing, portal revocation and reminder idempotency. UI DOM tests
exercise populated screens, commands, viewer restrictions and receipt rendering.
Live HTTP/browser testing and backup restoration require a host that allows
local server sockets.
