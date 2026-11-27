# Worship Connect — Database Architecture

**Version:** 0.1 (draft for review) | **Status:** Proposed — specification only; nothing here is implemented.

This is the entry point to the database specification. It records *what was found*, *what was decided and why*, *what remains open*, and *how every product requirement is covered*.

| Document | Content |
|---|---|
| **DATABASE_ARCHITECTURE.md** (this file) | Findings, principles, decisions, trade-offs, risks, traceability |
| [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) | 103-table inventory, columns, keys, constraints, indexes, time/delete policy |
| [RLS_SECURITY_SPECIFICATION.md](RLS_SECURITY_SPECIFICATION.md) | Privileges, helper functions, per-table policy matrix, storage, realtime, RPCs |
| [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md) | Permission catalogue (45), system roles, role×permission matrix |
| [DATABASE_MIGRATION_PLAN.md](DATABASE_MIGRATION_PLAN.md) | Phased migrations, ordering, dependencies, rollout and rollback |
| [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md) | Automated isolation/security tests, tools, scenarios, CI gates |

---

## 1. Scope and non-goals

**In scope:** a PostgreSQL (Supabase) schema, constraints, RLS, storage and realtime authorisation model, audit/retention design and test strategy for the full product vision in `PRODUCT_REQUIREMENTS.md`.

**Out of scope here:** application code, UI, deployment, infrastructure, real migrations, billing implementation, AI features, legal advice. Where a legal or commercial question affects design it is labelled **OPEN** (§15), not silently assumed.

**Nothing is implemented.** Every statement in these documents describes intended behaviour (`README.md` status note).

---

## 2. Review of existing documentation — inconsistencies and gaps found

Every document in `docs/` plus `README.md` was read before design. Items below are inconsistencies, ambiguities or omissions that affect the database. Existing documents were **not** edited; each item names its resolution.

| # | Finding | Where | Resolution in this specification |
|---|---|---|---|
| 1 | **Terminology drift:** "tenant", "church", "organisation", `tenant_id` | DOMAIN_MODEL, TECHNICAL_ARCHITECTURE, PRD | Table `organisations`, column `organisation_id` everywhere (D-019). "Tenant" remains the conceptual word. |
| 2 | **`Membership.status` includes `invited`** *and* a separate `Invitation` table exists | DOMAIN_MODEL §2 | Two representations of one state; and a membership row for an invitee would put them one bug away from reading tenant data. **No membership row exists until acceptance** (D-021). Statuses: `active`, `suspended`, `removed`. |
| 3 | **Polymorphic `scope_id`** on role assignments cannot carry a foreign key, so "validate same tenant" (DOMAIN_MODEL §3) is unenforceable in the database | DOMAIN_MODEL §3 | Typed scope columns with composite tenant FKs + CHECK (SCHEMA §0.2 "RS columns"). |
| 4 | "Validate tenant ownership across foreign-key relationships" (SECURITY §4) has **no mechanism** specified | SECURITY_AND_PRIVACY | Composite FKs `(organisation_id, id)` on every tenant relationship (D-020). |
| 5 | **Role** is "tenant-owned or controlled platform role" — ambiguous | DOMAIN_MODEL §3 | Global **system roles** (read-only rows) + tenant **custom roles** (D-023). |
| 6 | **Global profile carries `avatar_path`, `display_name`, `preferred_timezone`** — visible to every church the user joins | DOMAIN_MODEL §2 | Cross-church leakage of identity. Each church sees only `memberships.display_name`/avatar; the global profile is visible only to its owner (D-025). |
| 7 | Technical architecture says the selected workspace is "convenience state" but never says **how RLS knows which tenant is active** | TECHNICAL_ARCHITECTURE §5 | RLS grants the *union* of the user's active memberships; every permission check is per-organisation; the UI filters by organisation id explicitly. No tenant/role claims in the JWT (D-024). |
| 8 | **Service assignment** "person-specific or team-level" flagged ambiguous | DOMAIN_MODEL §7 | One row = one *slot*; `team_id` = accountable team, `membership_id` = person serving (SCHEMA G). |
| 9 | **Service `version` + `Service Revision` + "snapshot metadata"** overlap | DOMAIN_MODEL §7 | Live normalised rows + immutable `service_revisions.snapshot` + `service_songs` snapshot fields (D-032). |
| 10 | **Attendance:** "shared event abstraction?" left open | DOMAIN_MODEL §15 | One `attendance_records` table; invitations/RSVPs stay per event type (D-037). |
| 11 | **Venue** is free text on services; no rooms/locations, so room conflicts and equipment allocation cannot be modelled | DOMAIN_MODEL §7 | `locations` table. |
| 12 | **Recurring services/rehearsals** required (PRD §6.7) but absent from the domain model | PRD vs DOMAIN_MODEL | `event_series` with wall-clock recurrence (SCHEMA §13). |
| 13 | **Files** are referenced by "storage path" in several entities; no registry, status, scanning or ownership | DOMAIN_MODEL §6, §9 | `files` registry + pending-upload flow (D-039). |
| 14 | **Equipment inventory** absent (only "Equipment Checklist Item"); the task requires equipment and allocation | DOMAIN_MODEL §11 | `equipment_items`, `equipment_allocations`. |
| 15 | **Songwriters, copyright, tags, transposition preferences, vocal ranges, onboarding progress, emergency contacts** absent or one-line | PRD §6.4–6.5; task §C–D | Added (SCHEMA D, F). |
| 16 | PRD §6.1: "platform staff must not casually browse" — **no model** for support access | PRD | `platform.support_access_grants` (D-036). |
| 17 | PRD §6.2 requires workspace creation to be **transactional/recoverable** | PRD | `create_organisation()` RPC creating everything atomically. |
| 18 | **Permission identifiers** in TECHNICAL_ARCHITECTURE §6 are illustrative and inconsistent in style | TECHNICAL_ARCHITECTURE | Formal catalogue of 45 keys with mapping table (PERMISSIONS_MATRIX §2.9). |
| 19 | **Roadmap:** notifications foundation is Phase 2, communication Phase 5; `files`/storage/realtime foundations are Phase 1 | ROADMAP | Migration plan places `files`, `notifications`, audit in Phase 1–2 accordingly (MIGRATION §2). |
| 20 | **Moderation vs privacy conflict:** PRD wants moderation, SECURITY wants private messages | PRD §6.9, SECURITY §8 | Moderators act on non-private channels and on *reported snapshots*; **no role reads DMs** (D-034). |
| 21 | **Data-subject rights** (POPIA access/deletion) mentioned but no data model consequence | SECURITY §9 | Erasure = anonymise; subject-access exports must include restricted notes (risk R-9). |
| 22 | PRD §10 says "do not hardcode commercial limits" but §10 requires entitlements later | PRD | `organisation_entitlements` reserved; quotas read from settings/entitlements, never constants (deferred, §12). |
| 23 | `TECHNICAL_ARCHITECTURE` §9: realtime "scoped by tenant and resource permissions" — mechanism unspecified; Postgres Changes has known RLS limits (e.g. DELETE) | TECHNICAL_ARCHITECTURE | Private Broadcast + `realtime.messages` policies + id-only payloads (D-035). |

No requirement was found that *conflicts* with this design; the principal tensions (privacy vs moderation, convenience vs isolation, history vs normalisation) are resolved explicitly above.

---

## 3. Architectural principles

1. **Tenant isolation is structural, not conditional.** Three independent layers: (a) composite foreign keys make cross-tenant references impossible, (b) RLS filters every row by live membership and permission, (c) server code and RPCs validate again. Any single layer failing must not leak data.
2. **Identity is global; everything else is per-church.** One `profiles` row per person; every church-facing fact hangs off `memberships`.
3. **Authorisation is data.** Permissions are rows (`permissions`, `roles`, `role_permissions`, `membership_role_assignments`). No role names appear in policies or UI logic; the UI asks the server what the user can do.
4. **Default deny, explicit grant.** `anon` has no privileges; `authenticated` gets minimal grants; RLS on every table; RPC-only for multi-step or secret-handling writes.
5. **State is read live.** No organisation, role or status claim is trusted from the JWT. Suspension is effective on the next query.
6. **Normalise the live model; snapshot the history.** Live tables are relational and constrained; published plans are additionally frozen in immutable revisions so history stays understandable.
7. **Positions are not roles.** What someone does (position/skill) is separate from what they may administer (role). The model is not musician-centric.
8. **Sensitive data is structurally separated** (split tables, column privileges) rather than relying on the UI to hide it.
9. **Privacy by construction.** DMs cannot be read by administrators; unavailability reasons cannot be read by leaders; global identity is not shared between churches.
10. **Avoid premature machinery.** No per-tenant schemas, no JWT claim hooks, no event sourcing, no partitioning of hot tables until measured, no permission overrides (§12).

---

## 4. Tenant model and isolation layers

### 4.1 Why shared tables with `organisation_id` (not schema-per-tenant or database-per-tenant)

| Option | Isolation | Ops cost | Fit |
|---|---|---|---|
| Database per church | Strongest | Very high (migrations × N, connection counts, cost) | Over-engineered for the target market |
| Schema per church | Strong | High (migrations × N, PostgREST/RLS/Realtime assume one schema) | Poor Supabase fit |
| **Shared tables + `organisation_id` + RLS** | Strong *if enforced as specified* | Low; one migration path; Supabase-native | **Chosen** (D-001 already accepts multi-tenant; D-007 modular monolith) |

The cost of the shared model is that isolation depends on getting policies right — hence the layered defence and the testing strategy that treats isolation as a release gate.

### 4.2 The three layers

```text
Browser ─ JWT(sub only) ─▶ PostgREST / Next.js server
                               │
   Layer 3  RPC / server validation: derive org from target rows, ceiling checks, rate limits
                               │
   Layer 2  RLS: is_member(org) ∧ has_perm(org, key, scope) evaluated per statement from live rows
                               │
   Layer 1  Schema: composite FK (organisation_id, parent_id) — a row can only reference parents of its own organisation;
            organisation_id immutable; actor columns stamped by trigger
```

### 4.3 What "active organisation" means

The UI's selected workspace is a *filter*, not an authority. Database access for a user is the union of their active memberships; permission checks are always evaluated for the specific row's organisation. A user in churches A and B who queries `songs` without a filter receives songs they are entitled to in **both** — never anyone else's. The application filters by `organisation_id` explicitly for correctness and caching, and clears client caches on switch (`USER_WORKFLOWS.md` §5). A single-organisation "session mode" via JWT claims was rejected: stale claims would outlive suspension (D-024).

### 4.4 Organisation lifecycle

`active → suspended` (platform; instant lock-out for all members) · `active → closing → closed` (owner-requested; export window; scheduled purge) · purge job deletes tenant rows and storage objects; `audit_events` rows remain (no FK) for the retention period.

---

## 5. Identity and membership lifecycle

```text
auth.users ──trigger──▶ profiles
                          │ 1..N
create_organisation()  ──▶ memberships(active) + owner assignment            (no invitation needed)
create_invitation()    ──▶ invitations(pending)   [no membership row; no access]
accept_invitation()    ──▶ memberships(active | re-activated) + baseline `member` role + optional role/teams
set_membership_status  ──▶ active ⇄ suspended ;  active|suspended ─▶ removed
re-invite (removed)    ──▶ same membership row re-activated (history keeps one identity)
erase_my_account()     ──▶ memberships.user_id = NULL, display_name = 'Former member', PII deleted
```

* **One account, many churches:** `UNIQUE (organisation_id, user_id)`; no duplicate users; each membership has independent status and roles.
* **Invitation security:** e-mail-bound, 256-bit token, hash stored only, 14-day default expiry, revocable, single use, generic failure message, acceptance via RPC (RLS_SPEC §7.4). Invitee has **zero** database privileges on the organisation until acceptance.
* **Suspension** ≠ removal: suspension keeps history and roles but disables all access and cannot be bypassed by re-invitation; removal ends the relationship.
* **Last-owner invariant** enforced by trigger; ownership transfer is an audited, MFA-step-up RPC.
* **Self-service:** a member may leave an organisation (not if last Owner).

---

## 6. Authorisation model

Summarised from [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md):

* 45 permission keys; 8 system roles (global rows) + tenant custom roles; additive only.
* Scopes: organisation, campus, ministry, department, team. A scoped grant matches a resource only when the resource carries that ancestor id (SC columns, derived by trigger); it never matches an unscoped resource.
* Privilege ceiling prevents escalation: you can hand out only what you hold, over a scope you cover; Owner needs `org.ownership.manage`; no self-assignment.
* **Overrides deferred** (D-030). Temporary cover uses `expires_at`.
* **Team leadership is a role assignment**, not a column — one source of truth.
* Hierarchy semantics: `Church → Campus → Ministry → Department → Team` with every level optional. Membership of departments, ministries and campuses is *derived* from team membership (plus `home_campus_id`), so people are stored once.

---

## 7. Domain overview

```text
IDENTITY/TENANCY  profiles · organisations · organisation_settings · memberships · membership_status_events
                  membership_contacts · invitations · invitation_teams · policy_acceptances
STRUCTURE         campuses · ministries · departments · teams · locations
AUTHORISATION     permissions · roles · role_permissions · membership_role_assignments        (platform.*: admins, grants, takedowns)
PEOPLE            team_memberships · positions · skills · member_skills · member_positions · member_vocal_profiles
                  member_unavailability(+notes) · member_availability_preferences · member_emergency_contacts
                  member_private_notes · onboarding_plans/steps · member_onboarding(+steps)
FILES             files · file_attachments
MUSIC             songs · alternate titles · writers/credits · song_rights · arrangements/sections · song_resources
                  song_notes · tags/song_tags · member_song_preferences
SERVICES          service_types · event_series · service_templates(+items/slots) · services · programme items
                  service_songs(+sections) · service_assignments(+private) · service_notes · service_revisions
REHEARSAL/TASKS   rehearsals · rehearsal_songs/participants/notes · tasks · task_assignees · attendance_records
MEETINGS          meetings · participants · agenda items · minutes · decisions
COMMUNICATION     announcements(+receipts) · conversations · participants · messages(+attachments/reactions/reports)
                  notifications · notification_preferences · notification_deliveries · push_subscriptions
PRODUCTION        equipment_items/allocations · production_plans(+revisions) · stage_plots/elements · input_list_items
                  monitor_requirements · production_cues · production_checklist_items · requirements · notes
REPORTING/AUDIT   audit_events · report_exports · v_* security-invoker views
```

### 7.1 Key modelling decisions

| Topic | Decision | Why |
|---|---|---|
| **Songs and history** | Library is canonical and editable; services copy key/BPM/arrangement name/version and **copy sections** (`service_song_sections`); revision snapshots freeze the whole plan | PRD §6.5 "service-specific choices must not overwrite canonical data"; roadmap Phase 3 exit "catalogue edits do not rewrite historical plans" |
| **Chords/lyrics** | Machine-transposable only as `chords_text` (ChordPro) in sections; uploaded PDFs/images never claim transposability | PRD §6.5 |
| **Rights** | `song_rights.allow_*_storage` flags gate lyrics/chord/audio storage; `policy_acceptances` records the tenant's responsibility; `platform.takedown_requests` handles complaints; external media is **linked, never re-hosted** | PRD §6.5, SECURITY §10, D-016 (legal confirmation pending) |
| **Collaborative plans** | Live rows + `row_version` optimistic locking + `has_unpublished_changes` + curated immutable `service_revisions` + field-level audit | "Collaborative, auditable, no lost history" without CRDT complexity |
| **Technical production** | Production people are service slots with technical positions; plans/stage plots/inputs normalised; templates are `production_plans` with `is_template`; per-service copy; equipment allocation with exclusion constraint | Not musician-centric; PRD §6.11 |
| **Attendance** | Unified `attendance_records`; `excused` distinct from `absent`; no free-text health reasons | PRD §6.13 respectful accountability |
| **Tasks** | One `tasks` + `task_assignees` for preparation, practice and meeting action items | Avoids three near-identical structures |
| **Conversations** | One `conversations` table for channels/groups/DMs; one `messages` table | One authorisation function, one realtime topic scheme, one attachment path |
| **Notifications** | Persisted per membership, content-minimal, delivery attempts separate and service-only | TECH_ARCH §12 |
| **Audit** | Append-only partitioned `audit_events` with allow-listed field diffs; no FK to tenant | Survives tenant purge; no PII sprawl |

---

## 8. API surface: direct table access vs RPC

**Direct PostgREST access under RLS** for simple CRUD where RLS can express the whole rule (songs, notes, rehearsal agenda items, most children). **RPC-only** for operations that (a) touch several rows with an invariant, (b) handle secrets, (c) change authority (roles, membership status, invitations), (d) must stamp server facts (publishing, attendance bulk, file lifecycle), or (e) need to write only part of a row owned by someone else (member RSVP). Full catalogue: RLS_SPEC §11.

Rationale: RLS can say *who may touch a row*; it cannot say *which columns* or *which multi-row combinations* are legal. Pushing those into narrow, tested functions keeps policies simple and uniform.

---

## 9. Scale and performance

* **Expected shape:** thousands of tenants, tens to a few thousand members each; `messages`, `notifications`, `audit_events` and `attendance_records` dominate row counts.
* **Hot path:** RLS helper lookups on `memberships`, `membership_role_assignments`, `role_permissions`, `team_memberships` — small, heavily indexed (SCHEMA §15 (item 3)). Targets and a benchmark suite are in TESTING §3.11; the optimisation if needed is a trigger-maintained `effective_grants` table (not built in v1).
* **Pagination:** keyset only; messages by `(conversation_id, created_at, id)`.
* **Partitioning:** `audit_events` partitioned monthly from day one (cheap to start, expensive to retrofit; retention = drop partition). `messages` is **not** partitioned in v1; revisit when a measurable threshold is crossed (indicatively >50 M rows or vacuum/index-maintenance pain) — hash-partition by `conversation_id` or range by `created_at`; the composite PK/FK design (`(organisation_id, id)`) is partition-compatible only with added work, so this is flagged as a *known future migration* (D-042).
* **Search:** Postgres FTS + trigram; no external search service in v1.
* **Connection management:** use Supavisor transaction pooling for serverless (Vercel); RLS helpers are pooler-safe (no session state). Per-request `set_config` tenant context is deliberately **not** used.
* **Realtime cost:** Broadcast, id-only payloads, no Postgres Changes on content tables; subscriptions per active conversation, not per organisation.
* **Cost watch:** storage/egress quotas per organisation enforced in `register_file()`; monitor DB size, realtime messages, egress (PRD §9).

---

## 10. Audit, history, retention and protection of sensitive records

### 10.1 Three complementary history mechanisms

| Mechanism | Answers | Examples |
|---|---|---|
| **Audit events** (`audit_events`) | *Who changed what, when, from what to what?* (security and accountability) | membership/role/invitation changes, settings, status transitions, attendance corrections, moderation, exports, support access |
| **Revisions** (`service_revisions`, `production_plan_revisions`) | *What exactly was the published plan on date X?* (product feature, notifications) | publish/amend/reschedule/cancel snapshots |
| **State/lifecycle tables** (`membership_status_events`, `policy_acceptances`) | *What is this person's lifecycle?* | suspension/removal with reason; rights acknowledgements |

### 10.2 What is audited

**Always** (severity `security`/`notice`): organisation creation/status/closure; invitation create/resend/revoke/accept/expire; membership join/suspend/reinstate/remove/leave; role create/edit/permission change; role assign/revoke; ownership transfer; settings (security-relevant keys); service publish/revise/reschedule/cancel/restore/delete; attendance create/correct; song rights and takedown actions; message moderation and reports; file quarantine/delete; report exports; support-access grants and every console read; erasure; failed privileged attempts (authorisation failures in RPCs, invitation brute-force signals).
**Field-level diffs** (allow-listed columns only) on: `memberships`, `membership_role_assignments`, `roles`/`role_permissions`, `organisation_settings`, `invitations`, `services` (status/time/location), `service_assignments` (person/response), `attendance_records`, `song_rights`, `files` (status), `conversations` (visibility/archival), `equipment_allocations` (status).
**Never in audit:** message bodies, notes, contact details, tokens/hashes, availability reasons, file contents, raw IP addresses (a keyed hash is kept, D-031).

### 10.3 Retention (proposals — require legal review; labelled OPEN D-033)

| Data | Proposed retention | Mechanism |
|---|---|---|
| `audit_events` (general) | 24 months online | drop monthly partitions |
| `audit_events` severity `security` (membership, roles, ownership, support access) | 7 years | archive partitions to cold storage before drop |
| `membership_status_events` | life of membership + 2 years | purge job |
| `service_revisions`, `production_plan_revisions` | indefinite (church history) unless org closes | with organisation |
| Messages | **organisation-configurable**; default until deleted (D-017 open) | `message_retention_days` → tombstone + purge |
| `notifications` | 90 days after read/archive | purge job |
| `notification_deliveries` | 90 days | purge job |
| Terminal `invitations` | 90 days after resolution | purge job |
| Availability, notes, contacts, preferences of a removed member | 30 days after removal (unless erasure sooner) | purge/anonymise job |
| Attendance | per `attendance_retention_months` (proposal 36) | purge/aggregate job |
| Files | until deleted + `retention_until`; exports 7 days | purge job removes object then row |
| Closed organisation | export window 30 days, then full purge | closure job |

### 10.4 Protecting sensitive records

* **Split tables** for mixed-sensitivity data (unavailability reasons, decline reasons, emergency contacts, leader notes, contact details).
* **Column privileges** for server-controlled columns (`status`, `organisation_id`) and **server-only tables with no grants** for secrets (`invitation_tokens`) — column-level REVOKEs are not relied on (spike S-5).
* **Permissions flagged `is_sensitive`** are always audited, excluded from default custom-role templates, and (for Owner-level actions) protected by MFA step-up.
* **No reasons for absence/unavailability** are collected beyond what the member chooses to note privately.
* **Encryption:** managed disk/transport encryption by the platform; push-subscription keys additionally encrypted (D-028); evaluate column-level encryption (pgsodium/Vault) for emergency contacts and leader notes — open, minimal v1 = RLS + split tables.
* **Logs:** application and Postgres logs must not contain request bodies, tokens or note text; `pgaudit` for DDL/role changes only.
* **Exports** are permissioned, audited, expire, and are stored as private files.
* **Backups** contain everything: restoration procedure includes re-applying erasure requests received since the backup (documented in the incident/DR runbook, SECURITY §13).

### 10.5 Reporting without breaking isolation

Reports are `security_invoker` views over base tables, so a leader sees metrics only for people they can already see. Metrics treat `excused` and approved unavailability as non-negative (PRD §6.13); no ranking views exist. If scale demands rollups, a worker populates RLS-protected summary tables (`org_daily_metrics`-style); **materialised views are never exposed** because they cannot enforce RLS.

---

## 11. Files, realtime and notifications (summary)

* **Files:** registry-first uploads, private bucket, status + scan gating, short-lived signed URLs, relationship-based read rules shared with table RLS (RLS_SPEC §8).
* **Realtime:** private Broadcast topics `org:{org}:conv:{id}` etc., authorised by `realtime.messages` policies calling the same helpers; id-only payloads; no content over Postgres Changes (RLS_SPEC §10).
* **Notifications:** created by triggers/RPCs after the business transaction, persisted per membership, preferences per membership/category/channel, delivery attempts in a service-only table so critical planning transactions never wait on e-mail (TECH_ARCH §12).

---

## 12. Deferred or reserved (not in v1)

| Item | Reason deferred | Trigger to revisit |
|---|---|---|
| `membership_permission_overrides` | Non-monotonic permissions harm auditability/testing (D-030) | Repeated demand custom roles cannot meet |
| `plans`, `organisation_entitlements`, usage metering | Billing undecided (D-015); PRD forbids hardcoding limits | Phase 7 / billing decision |
| `message_edit_history` | Retention/moderation policy open (D-017); reports capture snapshots | Moderation needs proof of edits |
| Placeholder (account-less) members | Complicates RLS and invitations (D-038 OPEN) | Product decision |
| `effective_grants` materialisation | Premature | RLS benchmark failure |
| Message partitioning | Unmeasured | Row-count/ops threshold (D-042) |
| AI processing tables / consent flags | Phase 8; needs privacy and contractual review | AI scope approved |
| External calendar sync (ICS/Google) | Not in PRD | Product decision |
| Congregation CRM, giving, accounting, pastoral case management | PRD §11 out of scope | — |

---

## 13. Risks and mitigations

| Id | Risk | Severity | Mitigation |
|---|---|---|---|
| R-1 | A policy or helper bug leaks across tenants | Critical | Layered defence; isolation test matrix as release gate; policy-mutation tests; advisors in CI |
| R-2 | `SECURITY DEFINER` helper misuse (search_path, over-broad returns) | High | §4.1 rules; lint; tests; code review checklist |
| R-3 | RLS performance degrades with many members/roles | Medium | Indexes; `(select …)` caching; benchmark suite; `effective_grants` fallback |
| R-4 | Service-role key leakage | Critical | RLS_SPEC §12; secret scanning; server-only modules; rotation runbook |
| R-5 | Realtime subscription outlives revocation | Medium | Id-only payloads; short TTL; revoke broadcast; content only via RLS fetch |
| R-6 | Copyright infringement via uploaded lyrics/charts/audio | High (legal) | Gating flags, acknowledgements, takedown process, link-not-host, **legal review (D-016)** |
| R-7 | Orphaned or inconsistent data after composite-FK migrations | Medium | Strict migration ordering; validation queries; staged `NOT VALID`→`VALIDATE` |
| R-8 | Cascades bypass RLS and delete data the caller could not | Medium | Parent DELETE policies ≥ child; RESTRICT on history parents; tests |
| R-9 | **Data-subject access**: the subject cannot read `member_private_notes`, but POPIA gives them a right of access to personal information held about them | High (legal) | Per-subject export function that includes restricted notes for the data controller (church) to review before release; legal guidance on what must be disclosed; keep notes factual; limit categories — **OPEN, needs legal advice** |
| R-10 | Supabase platform limits/behaviour change (Realtime authorisation caching, policy limits, extension availability e.g. `btree_gist`, `pg_partman`) | Medium | Validate in a spike before Phase 1 exit (MIGRATION §6); pin versions; fallbacks documented |
| R-11 | Over-collection of personal data (health, family reasons) | Medium | Only optional private notes; no reason columns visible to leaders; `excused` flag instead of reasons |
| R-12 | Reporting turns into surveillance/shaming | Medium | No ranking views; aggregates respect excused status; `reports.view` scoped and sensitive |
| R-13 | Complexity of ~100 tables slows delivery | Medium | Phased migrations aligned to roadmap; no table created before its phase; deferred list §12 |
| R-14 | Time-zone/DST errors in recurrence | Medium | Wall-clock recurrence + tests across DST for several zones (incl. southern-hemisphere and zones without DST) |
| R-15 | Account takeover of an Owner/Admin | High | MFA step-up for Owner actions (D-027), session management, audit of privileged changes, alerting |

---

## 14. Requirement traceability (cross-check)

Legend: ✔ covered in schema/RLS · ◐ covered with a stated limitation or open decision · — not applicable.

### 14.1 Task sections A–I

| Requirement | Covered by | Status |
|---|---|---|
| **A** Churches/organisations, campuses, ministries, departments, teams | `organisations`, `campuses`, `ministries`, `departments`, `teams` (SCHEMA A, B) | ✔ |
| A Users + multiple memberships, no duplicate accounts | `profiles` 1:N `memberships`, `UNIQUE(org,user)` | ✔ |
| A Invitations and acceptance | `invitations`, `invitation_teams`, `accept_invitation` | ✔ |
| A Organisation settings/preferences | `organisation_settings` | ✔ |
| A DB-level tenant isolation | Composite FKs + RLS + immutability triggers | ✔ |
| **B** Identity/profile, membership, roles, permissions, role-permissions | A, C groups | ✔ |
| B User-specific overrides *if justified* | **Deferred** with rationale (D-030) | ◐ |
| B Scoped permissions at 5 levels | RS columns + `has_perm` | ✔ |
| B Invitation/membership lifecycle, suspension, termination | statuses, `membership_status_events`, RPCs | ✔ |
| B No hardcoded permissions; permission matrix | `permissions` rows; PERMISSIONS_MATRIX | ✔ |
| **C** Team membership, positions, instruments/skills | `team_memberships`, `positions`, `skills`, `member_skills`, `member_positions` | ✔ |
| C Vocal ranges and roles | `member_vocal_profiles`; vocal roles as `skills(category='vocal_role')`; `service_assignments.vocal_part` | ✔ |
| C Availability, schedules, unavailability | `member_unavailability`(+notes), preferences, `service_assignments`, `v_scheduling_conflicts` | ✔ |
| C Profiles/preferences | `memberships`, `membership_contacts`, `member_song_preferences`, notification prefs | ✔ |
| C Team leaders and departmental leadership | role assignments scoped to team/department; `v_team_leaders` | ✔ |
| C Onboarding and progress | `onboarding_*`, `member_onboarding(+steps)` | ✔ |
| C Non-musician teams | `teams.category`, `positions.category`, technical/hospitality/etc. | ✔ |
| **D** Songs, writers, copyright | `songs`, `writers`, `song_writer_credits`, `song_rights` | ✔ |
| D Arrangements, keys, tempos, time signatures, sections | `song_arrangements`, `arrangement_sections` | ✔ |
| D Lyrics, chord charts, sheet music, audio, YouTube/external | `arrangement_sections.lyrics_text/chords_text`, `song_resources` | ✔ |
| D Internal notes, tags/categories | `song_notes`, `tags`, `song_tags` | ✔ |
| D Transposition preferences | `member_song_preferences`; arrangement/service key fields | ✔ |
| D Usage history | `v_song_usage` over `service_songs` | ✔ |
| D Responsible copyright/media handling | gating flags, acknowledgements, takedown, link-not-host | ◐ (legal review D-016) |
| **E** Service types, schedules, plans, programme, songs, arrangements used | `service_types`, `services`, `service_programme_items`, `service_songs`(+sections) | ✔ |
| E Assigned musicians/vocalists, notes | `service_assignments`, `service_notes` | ✔ |
| E Revisions/history, collaborative & auditable | `service_revisions`, `row_version`, audit | ✔ |
| E Templates, recurrence | `service_templates`(+items/slots), `event_series` | ✔ |
| E Cancellation and rescheduling | status machine, `rescheduled_from_starts_at`, revisions | ✔ |
| **F** Rehearsals, locations, attendance, notes | `rehearsals`, `locations`, `rehearsal_participants`, `attendance_records`, `rehearsal_notes` | ✔ |
| F Preparation tasks, assignments, completion | `tasks`, `task_assignees` | ✔ |
| F Availability, scheduling conflicts | unavailability + GiST + `v_scheduling_conflicts` + acknowledgement flags | ✔ |
| **G** Announcements (org/team), channels, DMs, groups | `announcements`, `conversations` | ✔ |
| G Attachments, read receipts, reactions, notifications, preferences | `message_attachments`, `conversation_participants.last_read_*`, `message_reactions`, `notifications*` | ✔ |
| G Meetings, attendance, minutes, action items | `meetings*`, `attendance_records`, `meeting_minutes`, `tasks` | ✔ |
| G Realtime tenant isolation | RLS_SPEC §10 | ✔ |
| **H** Sound/media/projection/lighting/stage, equipment, allocation | `positions`/`teams` categories, `equipment_*`, `production_*` | ✔ |
| H Production plans, stage plots, input lists, technical notes, service requirements | `production_plans`, `stage_plots`(+elements), `input_list_items`, `production_notes`, `production_requirements` | ✔ |
| **I** Audit, membership activity, participation, attendance, rehearsal, task, song analytics, org activity | `audit_events`, `membership_status_events`, `v_*` views | ✔ |
| I Retention and protection of sensitive records | §10.3–10.4 | ◐ (retention periods OPEN D-033) |

### 14.2 Task section 4 (PostgreSQL requirements)

| Item | Where |
|---|---|
| Complete table inventory | SCHEMA §0.3 (103 tables) |
| Definitions, columns | SCHEMA groups A–L |
| PK/FK, unique, check | SCHEMA per table; composite-FK pattern §0.2 |
| Index strategy | SCHEMA §15 |
| Relationships | ER sketches per group; ARCH §7 |
| Data types | SCHEMA §0.2 |
| Timestamps/timezones | SCHEMA §13 |
| Soft vs permanent delete | SCHEMA §14 |
| Audit/history | ARCH §10 |
| Migration ordering | MIGRATION plan |
| UUID PKs; global vs tenant records | SCHEMA §0.4 (exceptions: `permissions.key` text PK, `organisation_settings`/1:1 tables keyed by parent, bridge tables with composite PKs, `audit_events` bigint) |

### 14.3 Product requirement spot-checks (PRD §6)

| PRD | Covered |
|---|---|
| 6.1 Platform administration, suspension, audited support | `platform.*`, `organisations.status`, grants, audit |
| 6.2 Onboarding transactional | `create_organisation()` |
| 6.3 RBAC incl. scoped, audited | C group, audit |
| 6.4 People/teams, sensitive notes restricted | D group |
| 6.5 Music library incl. version history | F group; `song_arrangements.version`, revision snapshots |
| 6.6 Service planning incl. printable/shareable plan | data model supports; sharing links not modelled (would be a signed, expiring read-only RPC — **not specified**, noted) |
| 6.7 Availability/RSVP/conflicts/recurrence/substitute suggestions | unavailability, `response_status`, series, `member_positions`/`skills` for future suggestions |
| 6.8 Rehearsals incl. recordings | `rehearsals`, `file_attachments` (`kind='recording'`) |
| 6.9 Communication incl. pinned, search, voice notes, retention | `messages` pin/FTS/`kind='voice_note'`, retention setting |
| 6.10 Meetings and tasks | I group, `tasks` |
| 6.11 Production | K group |
| 6.12 Personal workspace | read-model over assignments/tasks/notifications; no extra tables |
| 6.13 Reporting, excused handling | views, `excused` |
| 6.14 AI (P2) | deferred |
| §9 NFR: timestamps, IANA zones, pagination, idempotent retries | SCHEMA §13; keyset; `client_message_id`, `invitations` single-use |
| §12 Foundation acceptance criteria 1–12 | MIGRATION Phase 1 exit; TESTING gates |

**Gap noted:** *shareable/printable service plan links* (PRD §6.6) need a design (signed expiring token or authenticated print view). Not required for the database foundation; flagged for the Phase-3 design.

---

## 15. Unresolved decisions (summary)

Full text and status are recorded in [DECISIONS.md](DECISIONS.md) (D-019 → D-043). Items needing your approval before implementation:

| Id | Question | Recommendation |
|---|---|---|
| D-019 | `organisation` vs `tenant` naming | `organisations` / `organisation_id` |
| D-022 | Invitations e-mail-bound only, or also shareable join links/codes? | E-mail-bound only in v1 |
| D-026 | May leaders accept/decline on a member's behalf? | Yes, recorded in `responded_by` |
| D-027 | Require MFA (aal2) for Owner-level actions? | Yes for Owners; optional per-org for Admins |
| D-032 | Do members see edits to published plans immediately (live rows) or only on republish? | Immediate + "unpublished changes" indicator for leaders; revisit if churches want staging |
| D-033 | Retention periods | Adopt §10.3 after legal review |
| D-034 | Confirm no role (incl. Owner) can read DMs | Confirm |
| D-036 | Support access via owner-granted time-boxed grants | Confirm |
| D-038 | Allow placeholder members without accounts? | Not in v1; revisit with churches |
| D-016/D-040 | Rights gating defaults (`allow_*_storage = false`) | Confirm with legal advice |
| D-017 | Chat retention/edit/export | Org-configurable retention; no edit history v1 |
| D-014 | Campuses in first release? | Schema supports from day one; UI may defer |
| R-9 | Data-subject access to leader notes | Legal advice required |

---

## 16. Trade-offs in brief

| Choice | Gain | Cost |
|---|---|---|
| Shared tables + composite FKs | Cheap ops, DB-level cross-tenant impossibility | Wider FKs/indexes; every parent needs `UNIQUE (org,id)`; more verbose DDL |
| Permissions-as-data, live evaluation | Revocation is instant; no hardcoded roles | Per-row helper cost; needs good indexes/benchmarks |
| No JWT tenant/role claims | No stale authority; multi-org safe | Slightly more DB work per query |
| Global system roles | One place to evolve roles | Tenants cannot edit system roles (must clone as custom) |
| No `invited` membership | Strong guarantee for invitees | Cannot pre-assign someone before they register (D-038) |
| Split sensitive tables | Real column-level privacy under RLS | More tables/joins; need RPC for composite reads |
| Snapshot jsonb in revisions | Faithful history without temporal tables | Duplicated data; snapshot schema versioning needed |
| One `conversations`/`messages` model | Single auth path | Table grows large; partition later |
| id-only realtime payloads | Safe under delayed revocation | Extra fetch per event |
| Overrides deferred | Simple, auditable permissions | Some "one-off" requests need a custom role |
| ~100 tables | Complete product vision | Must migrate in phases; discipline against building ahead |

---

## 17. Review of tenant-isolation assumptions

Performed after drafting, against RLS_SPEC and SCHEMA. "Finding" = a gap that was closed in the specification as a result.

| # | Assumption | Verified how | Result |
|---|---|---|---|
| 1 | Cross-tenant references are impossible | Every tenant→tenant FK is composite; catalogue test CAT-08 | Holds; exceptions are FKs to global tables only |
| 2 | Client-supplied `organisation_id` is never trusted | Policies evaluate `has_perm(organisation_id…)` with the supplied id against the caller's real memberships; RPCs derive org from target rows (the few that accept an org id — `create_invitation`, `register_file`, `create_conversation` — first verify active membership); `organisation_id` immutable | Holds |
| 3 | Roles/status are never read from the JWT | Only `sub` (and `aal` for MFA step-up) used | Holds |
| 4 | Global tables do not leak between churches | `profiles`, `push_subscriptions` self-only; `permissions`/system roles are non-secret catalogue | Holds |
| 5 | Unique constraints do not create cross-tenant existence oracles | Reviewed every global UNIQUE: `organisations.slug` (acceptable, public-ish), `invitations.token_hash` (256-bit hash), `files.storage_path` (server-generated; clients cannot choose paths), others are tenant-prefixed | Holds; `slug` oracle accepted |
| 6 | FK/CHECK error messages do not leak other tenants' data | Messages echo only caller-supplied values | Holds |
| 7 | Cascades cannot delete across tenants or beyond DELETE rights | Composite FKs keep cascades inside a tenant; parent-DELETE ≥ child (INT-02) | Holds, test-enforced |
| 8 | `SECURITY DEFINER` helpers cannot be abused to probe other tenants | `has_perm(B, …)` from an A member returns false (membership required inside); helpers return booleans only (DEF-03) | Holds |
| 9 | Views/materialised views respect RLS | `security_invoker`; no materialised views exposed (CAT-11) | Holds |
| 10 | Storage and realtime are as strict as tables | Same helper functions; registry-first uploads; id-only payloads | Holds subject to spikes S-2/S-3 |
| 11 | Suspension is immediate | Live evaluation; MEM-06 | Holds for DB/Storage reads; Realtime relies on id-only payloads (R-5) |
| 12 | Platform staff cannot browse tenant content | `platform` schema unexposed; grants; no DM function | Holds by design; console is the weak point → MFA, audit, review |
| 13 | **Finding F-1:** a holder of `roles.manage` (via a custom role) could edit the role assigned to themselves to self-escalate | Reviewed role-definition path | **Closed:** role-definition ceiling (PERMISSIONS §1.1 rule 6; `can_edit_role_permission`; SCP-21) |
| 14 | **Finding F-2:** a `channels.manage` holder could add themselves to a private channel and read it | Reviewed conversation administration | **Closed:** `add_participants` forbids self-add to private channels (PRV-03) |
| 15 | **Finding F-3:** the `reports.view` permission was not enforced anywhere (summary reporting would have followed `attendance.view`) | Cross-checked permission keys against RLS spec | **Closed:** explicit predicate in reporting views (RLS_SPEC §6.13) |
| 16 | **Finding F-4:** decline reasons and conflict notes were on a row visible to the whole roster | Column sensitivity review | **Closed:** `service_assignment_private` split table |
| 17 | **Finding F-5:** Team/Department-scoped Production Leads could not match production plans (no scope columns) | Scope-matching review | **Closed:** SC columns on `production_plans` (owning team) |
| 18 | Triggers that validate cross-table state depend on caller visibility | Reviewed trigger design | **Closed:** validation triggers are `SECURITY DEFINER` (RLS_SPEC §4.1 rule 11) |
| 19 | Residual: the `organisation.slug` and member-count metadata are visible to platform support without a grant | By design (operations) | Accepted, documented |
| 20 | Residual: backups contain all tenants; restore into non-prod must be scrubbed | Operational | Documented in DR runbook requirement (§10.4) |
