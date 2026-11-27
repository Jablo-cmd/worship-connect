# Worship Connect — Decision Log

Record confirmed direction, provisional decisions and open questions here. Update this file when a decision changes.

**Statuses:** Accepted, Proposed, Open, Superseded.

## Accepted direction

### D-001 — Multi-tenant SaaS
**Status:** Accepted  
Design for multiple independent church tenants from the beginning. Tenant isolation is foundational and expensive to retrofit.

### D-002 — Global identity, multiple memberships
**Status:** Accepted  
One global user identity may have different memberships and roles in multiple churches.

### D-003 — Flexible organisational hierarchy
**Status:** Accepted  
Support optional campuses, ministries, departments and teams. Small churches must not be forced into enterprise structure.

### D-004 — Cross-department service collaboration
**Status:** Accepted  
Departments and teams collaborate on shared church services while retaining appropriate scoped permissions.

### D-005 — End-to-end worship operations
**Status:** Accepted  
Scope includes people, music, services, rehearsals, communication, meetings and technical production.

### D-006 — Database and server-side security
**Status:** Accepted  
Use PostgreSQL RLS and server-side authorisation. Frontend-only checks are insufficient.

## Proposed technical decisions

### D-007 — Modular monolith
**Status:** Proposed  
Start with modular Next.js application and PostgreSQL backend, not microservices. Reassess when measured requirements justify separation.

### D-008 — Initial stack
**Status:** Proposed  
Next.js, TypeScript, Supabase Auth, PostgreSQL, RLS, Realtime, Storage, Tailwind, shadcn/ui and Vercel. Validate provider limits, pricing and compatibility before production.

### D-009 — Private file storage
**Status:** Proposed  
Private buckets with authorised access and short-lived signed URLs by default.

### D-010 — In-app notifications first
**Status:** Proposed  
Establish internal notification model before multiple external delivery providers.

### D-011 — Responsive web first
**Status:** Proposed  
Mobile-first responsive web experience; defer native apps until product validation.

## Open decisions

### D-012 — Final brand
Is Worship Connect the final public name? Confirm visual identity, domain and tagline.

### D-013 — Onboarding
Self-service church registration, invitation-led registration or approval/verification?

### D-014 — Campus scope
Include campus management in first production release or later?

### D-015 — Billing
Provider, free tier, pricing dimensions, limits, trial and grace-period behaviour?

### D-016 — Music rights
What content may tenants store? What rights metadata and takedown process are needed?

### D-017 — Chat policy
Retention, editing/deletion, export, moderation and voice-note limits?

### D-018 — Native apps
What adoption and usage evidence justifies Android and iOS apps?

## Database architecture decisions (proposed — awaiting approval)

Raised by the database specification ([DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md)). None is implemented. **Proposed** = recommended and designed in; **Open** = needs a product, legal or commercial answer and is *not* assumed by the schema unless stated.

### D-019 — Naming: organisation, not tenant
**Status:** Proposed  
Table `organisations`, column `organisation_id`. "Tenant" stays a conceptual term. Resolves terminology drift between `DOMAIN_MODEL.md` (`tenant_id`) and the product vocabulary.

### D-020 — Tenant integrity by composite foreign keys
**Status:** Proposed  
Every tenant-to-tenant foreign key is `(organisation_id, parent_id)` → parent `(organisation_id, id)`, so cross-tenant references are impossible at schema level, in addition to RLS. Cost: wider keys, `UNIQUE (organisation_id, id)` on every parent.

### D-021 — No membership row before invitation acceptance
**Status:** Proposed  
Membership statuses are `active`, `suspended`, `removed`. The `invited` status in `DOMAIN_MODEL.md` §2 is replaced by the `invitations` table alone, guaranteeing an invitee has no database access before accepting. Consequence: people cannot be pre-assigned before they register (see D-038).

### D-022 — Invitations are e-mail-bound, hashed, single-use
**Status:** Proposed (shareable join links/codes: **Open**, not in v1)  
Acceptance requires the invitee's verified e-mail to match, the raw token is never stored, and failures return one generic error.

### D-023 — System roles are global rows; tenants create custom roles
**Status:** Proposed  
Eight system roles are read-only global rows that evolve with the code; organisations customise by creating custom roles from the permission catalogue. Platform permissions never appear in church roles.

### D-024 — Authorisation is evaluated from live database state; no tenant/role claims in the JWT
**Status:** Proposed  
RLS grants the union of the user's active memberships; every permission check is per-organisation. The selected workspace is a UI filter only. Rejected alternative: a "current organisation" JWT claim (stale after suspension).

### D-025 — Per-church identity; global profile is private to its owner
**Status:** Proposed  
Each church sees `memberships.display_name`/avatar; the global `profiles` row is readable only by its owner, preventing cross-church identity leakage.

### D-026 — Leaders may respond to assignments on a member's behalf
**Status:** Open (recommended: yes, recorded in `responded_by_membership_id`)  
Answers the question in `DOMAIN_MODEL.md` §15. "No response" is never treated as confirmation.

### D-027 — MFA step-up for privileged actions
**Status:** Open (recommended: required for Owner actions; optional per organisation for Admins)  
Ownership transfer, Owner assignment/removal and similar actions call `require_aal2()`.

### D-028 — Push-subscription key protection
**Status:** Proposed  
Encrypt push endpoint keys at rest (Vault/pgsodium) subject to the spike result; keys never logged.

### D-029 — Services may be multi-campus
**Status:** Proposed  
`services.campus_id` is nullable; NULL means multi-campus/organisation-wide (editable only by organisation-scope holders). Assignments may draw from any campus. Partly answers D-014 / `DOMAIN_MODEL.md` §15.

### D-030 — Per-member permission overrides deferred
**Status:** Proposed  
Not in v1. Custom roles, scoped assignments and expiring assignments cover known needs; deny rules harm auditability. Revisit on evidence.

### D-031 — Audit design: append-only, monthly partitions, no raw IP
**Status:** Proposed  
`audit_events` has no foreign key to tenants (survives purge), stores allow-listed field diffs only, and a keyed hash of the client IP instead of the address.

### D-032 — Published-plan model: live rows + immutable revisions
**Status:** Open (recommended as designed)  
Edits to published plans are visible immediately; leaders see an "unpublished changes" indicator; publishing a revision snapshots the plan and notifies members of material changes. Alternative (members see only the last published snapshot until republish) is possible but more complex.

### D-033 — Retention periods
**Status:** Open — requires legal review (e.g. POPIA)  
Proposed defaults are in `DATABASE_ARCHITECTURE.md` §10.3. They are placeholders, not commitments. Related: D-017.

### D-034 — Private conversations are unreadable by every role
**Status:** Proposed (needs explicit confirmation)  
Owners, Admins, moderators and platform staff cannot read direct/group conversations or private channels. Moderation of such content works only from reported-message snapshots.

### D-035 — Realtime: private Broadcast, id-only payloads, no Postgres Changes on content
**Status:** Proposed (pending spike S-2)  
Authorised by RLS on `realtime.messages`; payloads carry identifiers only so a subscription outliving a revocation leaks nothing.

### D-036 — Platform support access through owner-granted, time-boxed grants
**Status:** Proposed  
Support sees metadata freely; content only under an unexpired Owner-created grant (≤72 h) or dual-approved break-glass; always audited and visible to the church's Owners; DMs never.

### D-037 — Unified attendance and tasks
**Status:** Proposed  
One `attendance_records` table for services, rehearsals and meetings (answers `DOMAIN_MODEL.md` §15); one `tasks`/`task_assignees` pair for preparation, practice and meeting action items.

### D-038 — Members without accounts (placeholder members)
**Status:** Open  
Churches often schedule people who have not registered. The schema assumes every membership has an account (D-021). Supporting placeholders requires nullable identities, merge-on-registration and RLS changes; not designed in v1.

### D-039 — File registry and upload lifecycle
**Status:** Proposed (extends D-009)  
Uploads are pre-registered in `files`, validated and scanned before becoming `available`; Storage policies key on that registry; signed URLs ≤60 s.

### D-040 — Music rights gating
**Status:** Proposed — needs legal confirmation (extends D-016)  
Lyrics/chord text and uploaded charts/audio can be stored only when a rights-holder with `music.rights.manage` has set the song's `allow_*_storage` flags after accepting a rights-responsibility policy. External media is linked, never re-hosted. A takedown process is recorded in `platform.takedown_requests`.

### D-041 — Text + CHECK instead of native enums
**Status:** Proposed  
Status/category columns use `text` with `CHECK`, which is easier to evolve in migrations than Postgres enums.

### D-042 — Message partitioning deferred; audit partitioned from day one
**Status:** Proposed  
`messages` stays a single table until measured thresholds are reached (see `DATABASE_ARCHITECTURE.md` §9); this is a known future migration.

### D-043 — Data-subject access to restricted leader notes
**Status:** Open — requires legal advice (risk R-9)  
Members cannot read `member_private_notes` about themselves in the application; how access requests are satisfied must be decided with legal input.

## Changing a decision

1. Add or update a decision with reason.
2. Identify affected docs, code and migrations.
3. Document migration and compatibility implications.
4. Update product and architecture specifications.
5. Do not silently implement a conflicting approach.
