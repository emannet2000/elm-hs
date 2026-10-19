# ECC CRM 2.0 — Product and Architecture Roadmap

This roadmap evolves ECC CRM from a CRUD-oriented CRM into an operational system for ECC Consulting. The implementation order is deliberate: establish business invariants first, then build automation and AI on top of trustworthy data and workflows.

## Target architecture

**Customers & Leads → Workflow / State Machine → Applications → Documents → Tasks → Communications → Billing → Automation → Event / Audit History → Analytics → AI Agent**

## Phase 1 — Business core

### 1. Real business lifecycle

Canonical lifecycle:

`Lead → Qualified → Consultation → Application/Deal → Student/Client → Completed/Lost`

Requirements:
- Conversion creates the student/client record automatically.
- The converted student/client remains permanently linked to the originating lead.
- A person's history is traceable from first inquiry through completion.
- Ordinary users do not manually create students that should originate from lead conversion.
- Admin/import flows may create legitimate pre-existing clients, with provenance recorded.
- Conversion is transactional and idempotent: retrying cannot create duplicate clients.

### 2. State machines and invariants

Statuses are controlled transitions, not arbitrary labels.

Example application flow:

`Draft → Submitted → Processing → Approved → Completed`

Terminal outcomes may include `Completed`, `Lost`, and `Cancelled` as appropriate to the entity.

Rules:
- Reject invalid transitions in the backend even if a UI bug attempts one.
- Required documents, payments, approvals, or other prerequisites can block progression.
- Terminal records do not generate ordinary follow-up work.
- Every transition records actor, timestamp, previous state, new state, and reason/context.
- Transition rules are unit/property tested.

### 3. Operational dashboard — “What should I do today?”

The dashboard prioritizes work rather than vanity counts:
- Needs attention
- Consultations today
- Overdue tasks
- Stale leads
- Applications blocked
- Missing documents
- Payments due
- Recent conversions
- Recent activity

Every actionable item links directly to the affected person/work item.

### 4. 360° person view

One person screen combines:
- original lead and acquisition source
- contact information
- consultations
- application/deal
- student/client profile
- school/program
- documents and verification state
- invoices/payments/balance
- tasks
- communications
- assigned staff
- chronological event timeline
- audit history

A search for a person such as Maria Santos should reveal the complete relationship without forcing staff to hunt through modules.

## Phase 2 — Find, communicate and automate

### 5. Global search and command bar

Provide a keyboard-accessible command surface (target shortcut: `Ctrl+K` / `Cmd+K`). It searches people, applications, schools, tasks, documents and payments and supports commands such as:
- Create task for Maria
- Open Maria's application
- Show overdue applications

Natural-language commands can be added after deterministic commands are reliable.

### 6. Automation engine

Initial rules:
- stale lead → create follow-up task
- consultation tomorrow → reminder
- missing document → reminder
- document expiring → alert
- payment overdue → task
- application unchanged for X days → escalation
- lead converted → stop sales follow-ups
- completed case → start after-service workflow

Automation jobs must be idempotent. Each generated action receives a deterministic rule/run identity or equivalent uniqueness protection so retries cannot create duplicate reminders/tasks.

### 7. AI copilot

Example questions:
- Which clients need attention today?
- Why is Maria's application blocked?
- Summarize everything that happened with Maria.
- Find leads we have not contacted in seven days.
- Draft follow-ups for those leads.
- What should Aya work on next?

AI begins read-only. Mutating actions use:

`preview → approval → execute → audit log`

The model must use controlled application tools rather than direct database access for mutations.

### 8. Communications hub

Represent email, SMS/chat notes, calls, meetings and follow-ups in the person's timeline. Establish a provider-neutral communication/event model first so external messaging integrations can be added without redesigning the CRM.

## Phase 3 — Documents, money and staff operations

### 9. Document subsystem

Track:
- document type and owner
- related application/case
- required/optional
- received date
- expiry date
- verification state
- verified by / verified at
- replacement/version history
- missing-document rules

### 10. Payments and financial workflow

Support invoices/payment schedules, partial payments, balance due, overdue status, receipts, refunds and immutable transaction history. Dashboard financial summaries should derive from transactions, not manually entered counters.

### 11. Staff workload management

Each employee receives a **My Work** view with today's tasks, consultations, overdue work, assigned clients, blocked cases and priority recommendations. Managers receive workload distribution and bottleneck visibility.

### 12. Audit/event history

Important business events are append-oriented and reconstruct the person's journey, for example:

`LeadCreated → LeadQualified → ConsultationBooked → ApplicationCreated → DocumentReceived → PaymentReceived → ConvertedToStudent`

PostgreSQL remains the source of truth initially. XTDB can be evaluated later for richer temporal/event queries; it is not required for the first implementation.

## Phase 4 — Production engineering

### 13. Observability

Add structured JSON logs, request IDs/correlation IDs, endpoint latency/error metrics, DB pool health, worker heartbeat, failed-login monitoring, automation failures, `/health`, `/ready`, and build/deployment version information.

### 14. Recovery

Establish encrypted scheduled PostgreSQL backups, retention policy, restore verification, documented recovery procedure and periodic restore drills. A successful backup job alone is not considered proof of recoverability.

### 15. Security hardening

Strengthen RBAC and object-level authorization. Add session controls, rate limiting, login auditing, secure headers, upload validation, authorization tests and optional MFA for administrators when the authentication architecture is ready.

### 16. Testing maturity

Required layers:
- unit tests
- state-transition/property tests
- API integration tests
- database migration tests
- authorization/security tests
- workflow tests
- browser tests
- critical end-to-end journey: `Create lead → qualify → consultation → application → documents → convert → payment → complete`

### 17. Deployment discipline

Target delivery pipeline:

`Push → static checks → Haskell tests → Elm compile → integration tests → migration test → security checks → Docker build → deploy → health check`

A failed required check blocks production deployment.

### 18. Performance and reliability

Use pagination, appropriate indexes, query profiling, DB pool tuning, request/worker timeouts, bounded retries, worker locking, idempotency keys and protection against double-submit/double-conversion.

### 19. Mobile workflow

Mobile is task-oriented rather than merely responsive desktop UI. Staff should be able to call a lead, record a follow-up, complete a task, upload a document/photo and see today's appointments quickly with touch-friendly controls.

### 20. Management intelligence

Provide trustworthy operational/business answers including:
- Where are leads coming from?
- Which source converts best?
- Which staff member closes the most?
- Where do applications get stuck?
- How long does conversion take?
- What revenue is expected next month?
- Which schools/programs produce the most business?

## Delivery order

Do not implement all modules simultaneously.

1. Lifecycle and conversion invariants
2. State machines and transition audit
3. 360° person view
4. Operational dashboard
5. Search/command bar
6. Automation engine
7. Documents, payments and communications
8. AI copilot on top of stable application tools
9. Management analytics

Observability, security, testing, recovery, performance and deployment safeguards are cross-cutting requirements and should improve continuously with every phase.

## Definition of done for the business-core milestone

The first major milestone is complete when a lead can travel safely through the canonical lifecycle, conversion cannot duplicate a client, every state transition is validated/audited, staff can see a person's full linked history, and the dashboard tells staff what requires action today. Critical workflow tests must pass before deployment.
