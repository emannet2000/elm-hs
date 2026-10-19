# ECC CRM 2.0 — Domain Architecture

This document locks the architectural direction for the production-ready ECC CRM. New features should fit this model rather than adding ad-hoc CRUD paths.

## Core principle: Person is the identity root

A human being is represented once as a Person. Lead and Student/Client are business relationships/states attached to that person, not duplicate identities.

Person
- identity/contact profile
- lead relationship
- consultations
- applications/cases
- student/client relationship
- documents
- communications
- tasks
- financial account
- chronological business timeline

Lead conversion must not create a second Person. It creates/activates the Student/Client relationship and permanently links it to the originating lead journey.

## Command architecture

Business mutations are explicit commands, not arbitrary row patches:

- CreateLead
- QualifyLead
- ScheduleConsultation
- CompleteConsultation
- StartApplication
- MarkLeadLost
- ConvertLead
- CompleteClient
- SubmitApplication
- ApproveApplication
- CompleteApplication
- CancelApplication
- RecordPayment
- VerifyDocument
- ArchiveRecord

Every command follows:

`authenticate -> authorize -> load current version -> validate transition -> evaluate prerequisites -> execute transaction -> append audit/event -> enqueue outbox work -> return typed result`

Lifecycle fields are not ordinary editable form fields.

## Command result contract

Commands return a stable business result rather than relying on generic HTTP errors:

- Success
- ValidationFailure
- Conflict
- Unauthorized
- NotFound
- Duplicate
- InvalidTransition
- PrerequisiteFailed
- AlreadyCompleted

Failures should contain machine-readable codes and safe human-readable explanations for Elm.

## State and policy layer

Lead lifecycle:

`Lead -> Qualified -> Consultation -> Application/Deal -> Student/Client -> Completed`

`Lost` is a controlled terminal exit from appropriate non-terminal states.

Application lifecycle:

`Draft -> Submitted -> Processing -> Approved -> Completed`

`Cancelled` and `Lost` are controlled terminal outcomes.

Policy evaluation explains blockers. Example:

`CanSubmitApplication = identity verified AND required documents complete AND consultation complete AND application data complete AND required payment satisfied`

The API returns the exact unmet prerequisites so the UI, dashboard, automation and AI use the same business truth.

## Workflow definitions

Service workflows are data/configuration-backed definitions rather than scattered status strings. A workflow definition can specify stages, allowed transitions, required checklist items, documents, payment prerequisites and automation hooks.

Example Canada Student Visa workflow:

`Consultation -> School Application -> Offer Letter -> Document Collection -> Visa Submission -> Decision -> Pre-departure -> Completed`

The first implementation may keep definitions in application code/migrations, but the domain boundary must allow configurable definitions later.

## Data integrity

Important invariants are enforced in both the domain layer and PostgreSQL where practical:

- one Person identity root
- conversion cannot create duplicate client relationships
- terminal states cannot silently reopen
- stale writes are rejected using optimistic concurrency/version numbers
- important records are archived/soft-deleted, not normally destroyed
- provenance identifies staff/import/conversion/automation/API/AI origin
- money is append-oriented ledger data
- document replacement preserves version history
- retries are safe through idempotency keys/unique constraints

## Business events

Initial event vocabulary:

- PersonCreated
- LeadCreated
- LeadQualified
- ConsultationScheduled
- ConsultationCompleted
- ApplicationStarted
- LeadLost
- LeadConverted
- ClientCreated
- ApplicationSubmitted
- DocumentUploaded
- DocumentVerified
- ChargeCreated
- PaymentRecorded
- ApplicationApproved
- ApplicationCompleted
- ClientCompleted
- RecordArchived

PostgreSQL remains the source of truth. Events are append-oriented operational history, not a requirement to adopt full event sourcing.

## Transactional outbox and workers

A business transaction writes business data, audit/event records and outbox entries atomically. External side effects happen afterward.

`PostgreSQL transaction -> outbox -> worker -> automation / notifications / integrations / AI jobs`

Workers require durable job state, locking/lease semantics, bounded retry, idempotency, heartbeat and dead-letter/exception visibility.

Do not send email/SMS/WhatsApp or execute external AI actions inside the critical database transaction.

## Consultations

Consultation is a first-class record with person/lead, scheduled time, consultant, status, outcome, notes, reschedule/cancellation information, completion time and next action.

## Applications and checklists

Applications/cases use workflow definitions and checklist instances. Requirements can vary by service/destination. The system records why progression is blocked rather than merely disabling buttons.

## Documents

Documents track owner/person, application, document type, required/optional state, version, current-version marker, received time, expiry, verification state, verifier/time and rejection reason. File access is authorized and audited.

## Financial ledger

Do not use a single mutable amount-paid field as financial truth. Model charges/invoices, payments, refunds, discounts/adjustments and derived balance. Financial entries are append-oriented and audited.

## Authorization and privacy

RBAC is backend-enforced and complemented by record/object-level authorization. Sensitive reads and exports are auditable. Upload validation, session controls, rate limiting, secure headers, retention controls and secrets hygiene are production requirements.

## 360-degree person view

The Person page is the primary operational record. It combines identity/contact data, acquisition source, lead journey, consultations, applications, student/client relationship, school/program, documents, money, tasks, communications, staff assignments, event timeline and audit history.

## Attention and exception queues

Operational queues include overdue tasks, stale leads, consultations today, blocked applications, missing/expiring/rejected documents, overdue payments, failed automation, failed messages, duplicate-person candidates and worker dead letters.

## AI boundary

AI starts read-only and receives controlled application tools, for example:

- searchPerson
- getPerson360
- getAttentionQueue
- explainApplicationBlock
- draftFollowup
- previewQualifyLead
- previewConvertLead
- previewCreateTask
- executeApprovedCommand

AI never receives unrestricted SQL mutation capability. Mutations use `preview -> human approval -> validated command -> transaction -> audit event`.

## Observability and recovery

Production includes structured logs, correlation/request IDs, latency/error metrics, DB pool health, worker heartbeat, failed-job counts, deployment version, separate `/health` and `/ready`, scheduled backups and periodic restore drills.

## Testing contract

CI must cover unit tests, transition/property tests, API integration, migrations, authorization, idempotency, concurrency, workflow/browser tests and a seeded end-to-end journey:

`create person/lead -> qualify -> consultation -> application -> documents -> convert -> payment -> approve/complete`

It must also test forbidden transitions, stale writes and double conversion.

## Deployment contract

`Push -> static checks -> Haskell tests -> Elm compile -> integration tests -> migration tests -> security checks -> Docker build -> staging/smoke -> readiness -> production promotion`

Production is promoted only from a validated commit. Feature work does not deploy directly to the live Render branch.

## Scope discipline

ECC CRM remains a modular monolith: Elm SPA + Haskell API/domain layer + PostgreSQL + worker/outbox. Do not add Kafka, Kubernetes or microservices without a demonstrated scaling or organizational need.
