# Worship Connect — Database Migration Plan

**Version:** 0.1 (draft for review) | **Status:** Proposed — **no migration exists and none should be created until this specification is approved.**

Companion documents: [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) · [RLS_SECURITY_SPECIFICATION.md](RLS_SECURITY_SPECIFICATION.md) · [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md) · [ROADMAP.md](ROADMAP.md)

`DOMAIN_MODEL.md` §14 forbids creating "every conceptual table in one unreviewed migration". This plan delivers 103 tables in **small, reviewable migrations aligned to the roadmap phases**: no table exists before the phase that needs it.

---

## 1. Ground rules

1. **Migrations are the schema history** (`TECHNICAL_ARCHITECTURE.md` §7). Files in `supabase/migrations/` (timestamped by the CLI); no manual dashboard schema edits; drift is checked in CI.
2. **A table is never deployed without its RLS.** The table-creating migration runs `ENABLE ROW LEVEL SECURITY` + `FORCE` and grants nothing, so the table is *default-deny* from its first instant. Policies and grants follow in the **same release** (usually the same migration; where helper functions must be created first, the next migration in the same PR). A release cannot ship with a table lacking its §6 policies — enforced by the catalogue test (TESTING §3.1).
3. **A migration ships with its tests.** Positive, negative, cross-tenant, suspended-member and scope-boundary tests (TESTING) are part of the same pull request; CI runs them against a freshly reset database.
4. **One concern per migration.** Table groups, then helpers, then policies/grants, then RPCs, then seeds. Review checklist: RLS_SPEC §13.
5. **Forward-only in shared environments.** Down scripts exist for local development only. Production recovery is by a *new corrective migration* or point-in-time recovery.
6. **Expand → migrate → contract** for any change to a table that already holds data: add nullable/with default → backfill in batches → add `NOT VALID` constraint → `VALIDATE CONSTRAINT` → enforce → remove old. Never rewrite a large table inside a request path.
7. **Locking hygiene:** `SET lock_timeout`/`statement_timeout` at the top of every migration; avoid `ALTER TABLE … ADD COLUMN … DEFAULT volatile()`; create large indexes `CONCURRENTLY` in a dedicated single-statement migration (not possible inside a transaction block); add FKs `NOT VALID` then validate.
8. **Seed data is separate from schema.** *Reference data* (permissions, system roles, role_permissions, starter positions template) is applied by migrations idempotently (`INSERT … ON CONFLICT`). *Demo/test data* exists only in `supabase/seed/` and is **never** applied to production or preview-with-real-users; no real personal data anywhere.
9. **Reference data has a single source.** `permissions` and `role_permissions` are generated from one machine-readable file whose content is tested against [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md) §2/§4 (TESTING §3.9). Editing the matrix without the seed, or vice versa, fails CI.
10. **No client-visible breaking change without a deprecation window**; generated TypeScript types are regenerated and committed with each migration.
11. **Environments:** local (Supabase CLI), preview (per-PR database/branch), production. Separate projects, keys and secrets; previews use synthetic data only (`TECHNICAL_ARCHITECTURE.md` §14).
12. **Review gates:** each phase's migrations are reviewed by someone other than the author; Phase 1 requires an explicit security review before any real church is onboarded.

---

## 2. Phase plan (aligned to ROADMAP.md)

> Numbers are logical ordering (`M-nnn`); actual filenames use CLI timestamps in this order.

### Phase 0 — Foundations and spikes (no tenant data)

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-001 | `extensions_schemas_privileges` | Extensions (`pgcrypto`, `citext`, `pg_trgm`, `btree_gist`); schemas `private`, `platform`; default-privilege revocations; `anon` lock-down (RLS_SPEC §3) | — |
| M-002 | `common_functions` | `private.set_updated_at`, `forbid_org_change`, `bump_row_version`, `block_mutation`, `try_uuid`, `is_valid_timezone` | M-001 |
| M-003 | `audit_events` | Partitioned `audit_events`, partition-maintenance function, `private.write_audit`, indexes; clients have no DML | M-001, M-002 |

**Spikes required before M-010** (§6): extension availability, Realtime private-channel authorisation behaviour, storage policy flow, RLS helper performance baseline, PostgREST behaviour with column privileges.

### Phase 1 — Identity, tenancy and administration (first major release gate)

| Id | Migration | Tables / objects | Depends on |
|---|---|---|---|
| M-010 | `profiles` | `profiles`; trigger on `auth.users` insert (`private.handle_new_user`) | M-002 |
| M-011 | `organisations` | `organisations`, `organisation_settings` (logo FK added in M-018) | M-010 |
| M-012 | `org_structure` | `campuses`, `ministries`, `departments`, `teams`, `locations`; `private.fill_scope_ancestors` | M-011 |
| M-013 | `authorisation_catalogue` | `permissions`, `roles`, `role_permissions`; **seed 45 permissions + 8 system roles + mappings** | M-011 |
| M-014 | `memberships` | `memberships`, `membership_status_events`, `membership_contacts`, `policy_acceptances`; status-transition and last-owner triggers | M-011, M-012 |
| M-015 | `role_assignments` | `membership_role_assignments`; scope/role-org triggers; auto-`member` trigger | M-013, M-014 |
| M-016 | `invitations` | `invitations`, `invitation_tokens` (server-only), `invitation_teams` | M-014, M-015 |
| M-017 | `authz_helpers` | `private.my_org_ids`, `is_member`, `my_membership_id`, `has_perm`, `has_perm_for_team`, `has_perm_over_member`, `member_in_scope`, `scope_ancestors`, `has_perm_at_scope`, `can_grant_role`, `require_aal2` | M-013…M-016 |
| M-018 | `files_registry` | `files` (+ `organisation_settings.logo_file_id`, `memberships.avatar_file_id` FKs), storage buckets, **`storage.objects` policies**, `register_file`/`delete_file` RPCs | M-017 |
| M-019 | `rls_phase1` | Grants + policies for every Phase-1 table (RLS_SPEC §6.1–6.3, 6.6) | M-017, M-018 |
| M-020 | `rpc_phase1` | `create_organisation`, `my_workspaces`, `create/revoke/resend_invitation`, `get_invitation_preview`, `accept_invitation`, `set_membership_status`, `leave_organisation`, `assign_role`, `revoke_role`, `transfer_ownership` | M-019 |
| M-021 | `audit_triggers_phase1` | `private.audit_row_change` attached to Phase-1 sensitive tables | M-003, M-020 |
| M-022 | `platform_schema` | `platform.admins`, `support_access_grants`, `takedown_requests`, `organisation_status_log`; `platform.set_organisation_status` | M-011 |
| M-023 | `realtime_foundation` | `private.can_read_topic` (topics `me`, `presence` only), `realtime.messages` policies | M-017 |

**Exit gate (ROADMAP Phase 1 + PRD §12):** create/administer workspace; multiple memberships per user; tenant-specific roles; invitation lifecycle; **all Phase-1 isolation tests pass** (TESTING §3); storage/realtime foundations tested; advisors clean; manual security review signed off.

### Phase 2 — People, teams and member experience

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-030 | `people_catalogues` | `positions`, `skills`, `team_memberships` | M-012, M-014 |
| M-031 | `member_profiles` | `member_skills`, `member_positions`, `member_vocal_profiles`, `member_availability_preferences`, `member_emergency_contacts`, `member_private_notes` | M-030 |
| M-032 | `availability` | `member_unavailability` (GiST), `member_unavailability_notes` | M-014 |
| M-033 | `onboarding` | `onboarding_plans`, `onboarding_plan_steps`, `member_onboarding`, `member_onboarding_steps` | M-030, M-018 |
| M-034 | `notifications_foundation` | `notifications`, `notification_preferences`, `notification_deliveries`, `push_subscriptions`; `private.create_notification` | M-014 |
| M-035 | `rls_phase2` + `rpc_phase2` | Policies (RLS_SPEC §6.5, §6.11 notification rows); `complete_onboarding_step`; starter positions/skills seeding inside `create_organisation` (M-020 revised by a *new* migration, not an edit) | M-030…M-034 |
| M-036 | `views_directory` | `v_team_leaders`, directory helper views (`security_invoker`) | M-035 |

### Phase 3 — Music library and service planning

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-040 | `music_core` | `songs`, `song_alternate_titles`, `writers`, `song_writer_credits`, `tags`, `song_tags` | M-018 |
| M-041 | `music_rights_arrangements` | `song_rights`, `song_arrangements`, `arrangement_sections`; `private.gate_rights_content` | M-040 |
| M-042 | `music_resources_notes` | `song_resources`, `song_notes`, `member_song_preferences` | M-041, M-018 |
| M-043 | `services_core` | `service_types`, `event_series`, `service_templates`(+items/slots), `services`, `service_programme_items`, `service_songs`, `service_song_sections` | M-012, M-030, M-040 |
| M-044 | `service_people_history` | `service_assignments`, `service_assignment_private`, `service_notes`, `service_revisions`; status-machine and dirty-flag triggers | M-043 |
| M-045 | `file_attachments_v1` | `file_attachments` with `service_id` only | M-043 |
| M-046 | `rls_phase3` | `private.can_see_service`, `can_assign_slot`, `is_assigned_to_song`; extend `can_read_file`; policies RLS_SPEC §6.7–6.8 | M-040…M-045 |
| M-047 | `rpc_phase3` | `publish_service_revision`, `respond_to_assignment`, `apply_service_template`, `generate_series_occurrences` (worker) | M-046 |
| M-048 | `views_phase3` | `v_song_usage`, `v_service_participation` | M-046 |
| M-049 | `realtime_services` | `service` topic in `can_read_topic` | M-046, M-023 |
| M-049a | `audit_triggers_phase3` | audit for `services`, `service_assignments`, `song_rights` | M-044 |

### Phase 4 — Rehearsals and scheduling

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-050 | `rehearsals` | `rehearsals` (+ `event_series` FK), `rehearsal_songs`, `rehearsal_participants`, `rehearsal_notes` | M-043, M-030 |
| M-051 | `tasks` | `tasks` (no `meeting_id` yet), `task_assignees` | M-050 |
| M-052 | `attendance` | `attendance_records` (service/rehearsal only) | M-044, M-050 |
| M-053 | `file_attachments_v2` | add `rehearsal_id`, `task_id`; re-issue CHECK (`num_nonnulls = 1`) | M-045, M-051 |
| M-054 | `rls_phase4` / `rpc_phase4` | Policies §6.9; `respond_to_rehearsal`, `complete_task`, `record_attendance_bulk` | M-050…M-053 |
| M-055 | `conflicts_views` | `v_scheduling_conflicts` (overlaps across assignments, rehearsals, unavailability) | M-054, M-032 |

### Phase 5 — Communication and meetings

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-060 | `meetings` | `meetings`, `meeting_participants`, `meeting_agenda_items`, `meeting_minutes`, `meeting_decisions` | M-012, M-014 |
| M-061 | `forward_refs_meetings` | **ALTER**: `tasks.meeting_id`, `attendance_records.meeting_id`, `file_attachments.meeting_id` (+FKs, re-issued CHECKs, new partial unique indexes) | M-060, M-051, M-052, M-053 |
| M-062 | `announcements` | `announcements`, `announcement_receipts` | M-012 |
| M-063 | `conversations` | `conversations`, `conversation_participants`, `messages`, `message_attachments`, `message_reactions`, `message_reports` | M-050, M-043, M-018 |
| M-064 | `rls_phase5` | `can_access_conversation`, `can_post_conversation`; extend `can_read_file`; policies §6.10–6.11 | M-060…M-063 |
| M-065 | `rpc_phase5` | `create_conversation`, `add_participants`, `delete_message`, `moderate_message`, `report_message`, `mark_read`, `respond_to_meeting`; notification fan-out triggers | M-064 |
| M-066 | `realtime_conversations` | `conv` topic; message-insert trigger → `realtime.send` (id-only payload) | M-064, M-023 |
| M-067 | `message_search_indexes` | FTS/GIN indexes (separate migration; `CONCURRENTLY` if table non-empty) | M-063 |

### Phase 6 — Technical production

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-070 | `equipment` | `equipment_items`, `equipment_allocations` (+ GiST exclusion) | M-043, M-050, M-012 |
| M-071 | `production_core` | `production_plans`, `production_plan_revisions`, `stage_plots`, `stage_plot_elements`, `input_list_items`, `monitor_requirements` | M-043, M-030 |
| M-072 | `production_ops` | `production_cues`, `production_checklist_items`, `production_requirements`, `production_notes` | M-071 |
| M-073 | `file_attachments_v3` | add `production_plan_id`; final CHECK | M-071 |
| M-074 | `rls_phase6` / `rpc_phase6` | Policies §6.12; `complete_checklist_item`; template-apply function | M-070…M-073 |

### Phase 7 — Insights and advanced operations

| Id | Migration | Contents | Depends on |
|---|---|---|---|
| M-080 | `reporting_views` | `v_attendance_summary`, `v_rehearsal_participation`, `v_task_completion`, `v_org_activity` (all `security_invoker`) | M-054, M-061 |
| M-081 | `report_exports` | `report_exports`; `request_report_export` | M-018, M-080 |
| M-082 | `retention_jobs` | purge/anonymise/partition-maintenance functions + `pg_cron` schedules (service role) | M-003, M-034, M-063 |
| M-083 | `entitlements` | **only after D-015 is decided**: `plans`, `organisation_entitlements`, quota checks in `register_file` etc. | decision |

### Phase 8

No schema is specified. AI-related tables require a separate privacy/contract review before design.

---

## 3. Ordering and dependency rules

### 3.1 Dependency graph (condensed)

```text
auth.users → profiles → organisations → (org_structure, authorisation_catalogue)
                                   └→ memberships → role_assignments → invitations
                                                   └→ authz_helpers → files → rls_phase1 → rpc_phase1
people (positions/skills/team_memberships) → services → service_assignments → rehearsals → tasks/attendance
songs → arrangements → service_songs ; files → song_resources, message_attachments, file_attachments
meetings → (ALTER tasks, attendance_records, file_attachments) ; conversations → messages
services/rehearsals/teams → production_plans / equipment
```

### 3.2 Forward references (the only circularity-prone spots) and how they are broken

| Reference | Why not created earlier | Resolution |
|---|---|---|
| `tasks.meeting_id`, `attendance_records.meeting_id`, `file_attachments.meeting_id` | `meetings` arrive in Phase 5, tasks/attendance in Phase 4 | Column + FK added by **M-061** (`ALTER TABLE … ADD COLUMN … NULL`, add FK `NOT VALID`, `VALIDATE`, re-issue CHECK and partial-unique indexes). Existing rows unaffected. |
| `file_attachments.rehearsal_id`/`task_id`/`production_plan_id` | Targets arrive later | Added by M-053 / M-073 the same way |
| `organisation_settings.logo_file_id`, `memberships.avatar_file_id` | `files` needs `organisations`/`memberships` first | FK added in M-018 |
| `service_types` ↔ templates | would be a cycle | Designed away: templates point at types; types have no template pointer (SCHEMA §17) |
| `files ↔ memberships` | `files.uploaded_by` would point at memberships | Designed away: `uploaded_by_user_id` → `profiles` |
| `event_series.service_template_id` | templates in M-043 with series | Created in the same migration, series after templates |
| `rehearsals.series_id` | series created in Phase 3 | FK added with `rehearsals` in M-050 |
| Policies need helpers that need tables | Function bodies reference tables | Order: tables → helpers (`CHECK_FUNCTION_BODIES` on) → policies; tables are default-deny meanwhile |

### 3.3 Verified acyclic

The foreign-key graph of the target schema was reviewed for cycles (SCHEMA §17); the CI includes a **catalogue test** that builds the FK graph from `pg_constraint` and fails on any strongly connected component other than self-references (`production_plans.based_on_template_id`, `messages.parent_message_id`).

---

## 4. Anatomy of a table migration (template)

```sql
-- supabase/migrations/<ts>_music_core.sql
set lock_timeout = '5s';
set statement_timeout = '60s';

create table public.songs (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations(id),
  title           text not null check (char_length(title) between 1 and 200),
  /* … columns per DATABASE_SCHEMA.md … */
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organisation_id, id)
);
create index songs_org_status_idx on public.songs (organisation_id, status);
create index songs_search_idx on public.songs using gin (search);

alter table public.songs enable row level security;
alter table public.songs force  row level security;
-- (no grants yet: default deny)

create trigger songs_set_updated_at   before update on public.songs for each row execute function private.set_updated_at();
create trigger songs_forbid_org_change before update on public.songs for each row execute function private.forbid_org_change();
```
The grants and policies arrive in the phase's `rls_*` migration, reviewed against RLS_SPEC §6, together with the tests that prove them.

## 5. Rollout, rollback and data safety

| Topic | Approach |
|---|---|
| **Deploy order** | Preview database → automated tests → production. Application code that needs a new column deploys *after* the migration; code is tolerant of the *old* schema for one release (expand/contract). |
| **Rollback** | Production is forward-fix. Before risky migrations take a manual backup/PITR marker. Down scripts are local-only. |
| **Validation queries** | Each constraint-adding migration ships a validation script (orphan counts, cross-tenant FK mismatches = 0). |
| **Backfills** | Batched (e.g. 5 000 rows), idempotent, resumable, outside long transactions; progress logged. |
| **Policy changes** | Treated like code changes to security: a policy migration must change the tests in the same PR (mutation test: removing the policy must fail a test). |
| **Zero-downtime concerns** | Avoid table rewrites; `ALTER … SET NOT NULL` only after a validated CHECK; index creation `CONCURRENTLY` as a separate single-statement migration. |
| **Seed reference data** | Idempotent; permission removals are `deprecated_at` first, deleted only after no role references them. |
| **Type generation** | `supabase gen types typescript` committed with each migration. |
| **Backups & restore** | Configure backups before Phase 1 exit; restore tested into a scratch project; documented that erasure requests received after a backup must be re-applied (ARCH §10.4). |

## 6. Spikes and validations required before implementation starts

Each produces a short written result appended to this plan (or `DECISIONS.md`). Anything that fails changes the specification, not the tests.

| # | Question | Pass criterion |
|---|---|---|
| S-1 | Are `pgcrypto` (`digest`, `gen_random_bytes`), `citext`, `pg_trgm`, `btree_gist` available on the chosen Supabase tier? `pg_partman`/`pg_cron` for maintenance? | All required extensions available; otherwise adopt documented fallbacks (manual partition function, external scheduler) |
| S-2 | Realtime private channels: policy evaluated at join; behaviour on token refresh; `realtime.send` from triggers; topic parsing in policies | Isolation + revocation behaviour matches RLS_SPEC §10; documented limits |
| S-3 | `storage.objects` policies calling `SECURITY DEFINER` helpers; signed URL expiry; listing endpoints do not reveal other tenants' objects | Cross-tenant list/read/upload attempts denied |
| S-4 | `has_perm` benchmark: 5 000 orgs, 100 k memberships, 1 M songs/assignments, 20 M messages | p95 list query within agreed budget (set in S-4; e.g. <50 ms for 50-row pages); otherwise adopt `effective_grants` |
| S-5 | Column-level privileges: `GRANT UPDATE (cols)` and `REVOKE SELECT (col)` — behaviour of `select *` and error shape | **Resolved at SQL level (§9)**; PostgREST layer still to be confirmed |
| S-6 | `create_organisation` as one RPC transaction through PostgREST under `authenticated`; `auth.users` read inside `SECURITY DEFINER` | Atomic; no orphans on forced failure |
| S-7 | DST generation for `event_series` in zones with DST, without DST, and with unusual rules (e.g. `Africa/Johannesburg`, `Europe/London`, `Australia/Lord_Howe`, `America/Sao_Paulo`) | Golden-file test of occurrences across transitions |
| S-8 | MFA (`aal2`) claim availability for `require_aal2()` | Claim present after TOTP verification |
| S-9 | Supabase branching / preview databases vs migrations-only CI | Chosen CI flow documented |
| S-10 | Behaviour of FORCE RLS with the Supabase `postgres` role | Documented (expected: no effect for `BYPASSRLS` roles) |

## 7. Seed and fixture data

| Class | Content | Where applied |
|---|---|---|
| Reference (production) | 45 permissions; 8 system roles; role→permission mappings; default `notification` categories; allowed MIME list | Migrations (idempotent) |
| Starter content per church | Positions, skills, default channels (`#general`, `#announcements`), onboarding checklist | Inside `create_organisation()` (data, not migration) |
| Test fixtures | Two organisations, users in every state (owner, admin, leader, member, suspended, removed, invited, multi-org, outsider) — see TESTING §2 | `supabase/seed/` and test setup helpers; local/CI only |
| Demo data | Optional, synthetic | Local only; never production |

## 8. Definition of done for a migration

- [ ] Reviewed against SCHEMA, RLS_SPEC §13 checklist and PERMISSIONS_MATRIX.
- [ ] RLS enabled; grants minimal; policies present and tested; advisors clean.
- [ ] Tests added/updated (isolation, state, scope, privacy) and green in CI against `supabase db reset`.
- [ ] Rollback/forward-fix noted; lock/timeouts set; no table rewrite risk.
- [ ] Types regenerated; docs updated; `DECISIONS.md` updated if a decision changed.
- [ ] No secrets, real data or production identifiers in the migration.

---

## 9. Spike results (run 2026-11-27)

**Environment and limits of this evidence.** PostgreSQL 16.15 (vanilla Ubuntu build) with a **mocked** `auth` schema (`auth.uid()` reading `request.jwt.claims`) and plain `anon`/`authenticated`/`service_role` roles. **No Docker daemon was available, so no Supabase stack ran**: nothing below says anything about PostgREST, Supabase Auth, Storage, Realtime, extension availability on the hosted tier, or Supabase's managed `postgres` role beyond what is stated. The SQL under test was the helper/policy code from RLS_SECURITY_SPECIFICATION §4 and §7. Dataset for S-4: 2 000 organisations, 100 006 memberships, 110 006 role assignments, 1 000 000 songs, 200 000 rehearsals.

| Spike | Status | Result |
|---|---|---|
| **S-1** Extensions | **Done on Supabase (see §9.1); SQL-level notes kept** | `pgcrypto`, `citext`, `pg_trgm`, `btree_gist` install and work on PG 16. `pg_partman`, `pg_cron`, `pgtap` were **not** available in this build. **Availability on the Supabase tier is unverified.** The spec's partition maintenance must not depend on `pg_partman` until confirmed (a plain SQL function + scheduler is sufficient). |
| **S-2** Realtime private channels | **Done on Supabase (§9.1)** | Behaves as specified; D-035 supported. |
| **S-3** Storage policies | **Done on Supabase (§9.1)** | One real spec bug found and fixed (`files.manage`). |
| **S-4** RLS performance | **Done at SQL level; spec changed** | See below. |
| **S-5** Column privileges | **Done; spec changed** | See below and §9.1 (PostgREST behaviour confirmed). |
| **S-6** Atomic `create_organisation` | **Done (SQL level + through the real API)** | A `SECURITY DEFINER` function inserting organisation + settings + membership + role assignment and then raising rolled back **all** rows (0 leaked); success path committed all; `anon` got `permission denied for function`. Through PostgREST/`auth.users` still to confirm on Supabase. |
| **S-7** Time zones / DST | **Done; spec changed** | See below. |
| **S-8** MFA `aal2` claim | **Not run** | Needs Supabase Auth. |
| **S-9** Branching / CI flow | **Not run** | Needs Supabase tooling. |
| **S-10** FORCE RLS | **Done; spec corrected** | A table owner with `BYPASSRLS` still sees all rows with `FORCE ROW LEVEL SECURITY`; an owner without it sees none. FORCE is therefore **not a control** for Supabase's `postgres` role; kept as harmless defence for non-bypass owners. |

### S-4 details

| Query (as `authenticated`, RLS on) | Result |
|---|---|
| Member: page of 50 songs, filtered to one organisation (500 rows, 1 M table) | **4.0 ms**, index scan |
| Same, after switching to the array predicate | **2.3 ms** |
| Member: count of one organisation's songs (500 rows → 500 `has_perm` calls) | **10 ms** (≈20 µs per row) |
| Team-scoped leader: 100 rehearsals, per-row scoped `has_perm` | **2.1–2.5 ms** |
| Member lacking the permission: same list | 2.3 ms, 0 rows |
| Outsider reading another organisation's songs | 0.9 ms, **0 rows** |
| Multi-organisation member, **no** organisation filter, `IN (select setof_fn())` policy | **240 ms** (116 ms with `ROWS 5`): sequential scan of 1 M rows — the planner cannot turn a hashed sub-select into an index condition |
| Same query, **array** predicate `organisation_id = ANY ((select private.my_org_array())::uuid[])` | **30 ms**, bitmap index scan |

**Conclusions.** (1) The `has_perm` design meets the working budget (<50 ms for 50-row pages) at this scale **without** the `effective_grants` optimisation — it stays deferred. (2) Table policies must use the **array form**; the spec now says so (RLS_SPEC §4.2, §5, §7). (3) Applications should still always filter by `organisation_id`. Caveat: one 2 000-organisation dataset on a warm cache on a single machine; the 20 M-message and concurrency cases were **not** run and S-4 should be repeated on Supabase hardware before Phase-1 exit.

### S-5 details (bug found in the original spec)

* `REVOKE SELECT (token_hash)` **had no effect** while a table-level `SELECT` grant existed: `select *` still returned the hash. The original RLS spec relied on exactly that statement.
* The effective pattern is to revoke the table-level grant and grant a column list; then `select *` fails with *permission denied for table* (also for `WHERE token_hash = …`, so there is no oracle) — but `select *` is PostgREST's default shape, so clients would break.
* **Spec change:** the hash moved to a server-only table `invitation_tokens` (no policies, no grants). Column-level `GRANT UPDATE (cols)` works as designed (updating a granted column succeeded; an ungranted column was denied).

### S-7 details

* Wall-clock recurrence `(date + time) AT TIME ZONE tz` kept 10:00 local across the 2027 spring change in `Europe/London` (10:00 UTC → 09:00 UTC); `Africa/Johannesburg` stayed 08:00 UTC; `America/Sao_Paulo` stayed 13:00 UTC in January and July; `Australia/Lord_Howe` shifted by 30 minutes (23:00 → 23:30 UTC).
* Gap (01:30 on 2027-03-28, London): PostgreSQL shifts the time forward to 02:30 BST. Overlap (01:30 on 2026-10-25): PostgreSQL returns the **later, standard-time** instance. The earlier spec text said "first occurrence for overlaps"; it now states the observed behaviour, to be pinned by golden tests.
* `AT TIME ZONE` accepts `EST`, `UTC+3` and `Factory`, and 16 of 499 `pg_timezone_names` have no `/`. "Does not raise" is not validation; the validator is now specified as an allow-list (SCHEMA §13 item 3, test CAT-20).

### Additional checks run (spec features)

| Check | Result |
|---|---|
| Composite FK `(organisation_id, campus_id)` rejects a team in organisation B pointing at a campus of A | Rejected (FK violation); legitimate row accepted |
| Policy `WITH CHECK` rejects an insert by a member without `music.manage`; `anon` has no table privilege | Rejected / `permission denied` |
| `SECURITY DEFINER` function **without** `search_path=''` | **Hijacked** by a shadow table in a schema on the caller's `search_path` (outsider reported "member"); the hardened `private.is_member` returned `false` |
| Equipment `EXCLUDE USING gist … WHERE (is_exclusive AND status IN (…))` | Overlap rejected; adjacent ranges and cancelled overlaps allowed |
| `DEFERRABLE INITIALLY DEFERRED` unique position | Swapping two positions in one transaction succeeds |
| `audit_events` partitioned by month with PK `(id, occurred_at)`; block-mutation trigger | UPDATE/DELETE raise; **insert with no matching partition fails** (so partitions must pre-exist, plus a `DEFAULT` partition and an alert — SCHEMA §L); dropping a partition removes its rows without row triggers |

### 9.1 Results on a real Supabase project (worship-hub, Postgres 17.12, eu-west-2)

**Setup.** A cut-down copy of the specification (organisations, profiles, memberships, roles and assignments, invitations + `invitation_tokens`, songs, files registry, conversations, participants, messages, attachments), the §4 helpers, §7 policies and RPCs, the `org-files` bucket policies and the `realtime.messages` policies were applied by migration. Eight synthetic users (owner A, admin A, member A, member A later suspended, invitee, member of A *and* admin of B, owner B, outsider) signed in with real passwords and every test used their **real JWTs through PostgREST, Storage and Realtime** — not SQL `set role`. Two churches were created through the real `create_organisation` RPC; invitations, acceptance, songs, a private DM, a private channel, an org channel, file registration and uploads were all done through the API. Test code lives outside the repository (scratch space) and is not committed.

**Outcome (accurate tally).** First run: **130 checks, 121 passed, 9 failed** — 4 real spec defects (all `files.manage`, below) and 5 caused by the test harness. After fixing the spec bug and the harness, the **files, realtime and suspension sections were re-run (50 checks): 49 passed, 1 failed** — RT-03b, whose assertion was too strict (the payload was verified by hand to carry only ids, no body; it is **not** counted as a pass). The 80 isolation / scope / invitation / multi-org / private-message checks passed in the first run and were **not re-run** (the invitation tokens are single-use, so that section is not idempotent). Check IDs below follow DATABASE_TESTING_STRATEGY.md; the spike's test code lives outside the repository and is not committed.

| Area | Result on Supabase |
|---|---|
| **S-1** extensions | `btree_gist`, `citext`, `pg_trgm`, `pg_cron`, `pg_partman`, `pgtap`, `pgsodium`, `supabase_vault` available; `pgcrypto` and Vault pre-installed. The `postgres` role is `NOSUPERUSER BYPASSRLS` (confirms S-10 on the real platform). |
| **CAT-03** default-privilege lock-down | After `ALTER DEFAULT PRIVILEGES … REVOKE`, newly created tables had **zero** grants to `anon` and `authenticated`. |
| **ISO** (cross-organisation) | Organisation B's owner read 0 rows of A in 8 tenant tables, could not insert/update/delete/move A rows, could not call any RPC against A (suspend, DM, register file, invite, assign role), and a forged cross-tenant message was rejected. `anon` was denied on tables and RPCs; an outsider with no memberships saw nothing. |
| **CAT-16** token hash | `invitation_tokens` returned *permission denied* even to the organisation Owner. |
| **SCP** escalation | A member could not invite, assign roles (including to self), or suspend; an Admin could not grant Owner or self-assign; the last Owner could not be suspended (even by an Admin); column grants stopped members changing their own `status` or `organisation_id`. |
| **INV** invitations | A pending invitee saw no organisation, membership, invitation, workspace or conversation. Wrong token, another user's token and a reused token returned the **same** generic error. Access appeared only after acceptance; a second accept failed. |
| **MUL** | A user in two churches saw exactly both churches' songs; Admin-in-B could not write in A or suspend/assign there; cross-organisation DMs were impossible. |
| **PRV** private messages | Owner, Admin, other-organisation owner and outsider saw **0** DM conversations, messages or participants; participants saw them. Owner and member could not read a private channel; managers could not add themselves (no write grant, RPC-only); sender spoofing and posting into a private channel were rejected; no client DELETE on messages. |
| **FIL** files | Other-organisation and outsider downloads and signed URLs denied; upload to unregistered paths, other organisations' prefixes, someone else's pending path and **overwrite (upsert)** all denied; listing another prefix empty; clients could not mark a file `available`. **Bug found:** see below. |
| **RT** realtime | Participants joined their private topic and received `message.created`; other-organisation users, the Owner and the Admin could **not** join it; malformed topics denied; **clients could not broadcast onto a content topic**; non-participants received nothing. |
| **MEM** suspension | The suspended member, on the **same JWT without re-login**, went from 3 songs to 0 immediately, lost organisations/conversations/files/posting/uploads, could not reinstate himself, could not bypass suspension with a new invitation, could not rejoin his realtime topic, and was told via `membership.revoked` on his personal topic. Other members were unaffected; reinstatement restored access. `my_workspaces()` still told him he was suspended. |

**Real spec bug found by a failing test.** With `files.manage` in `can_read_file`, an Owner/Admin could download a **DM attachment** and any **unattached** file, and list them in Storage (FIL-02b, 02c, 04, 11c failed). Fixed: `files.manage` now means delete/quarantine only and grants no read/list access (RLS_SPEC §4.3, PERMISSIONS_MATRIX §2.8, new test FIL-03b). Re-run: all FIL checks pass.

**Harness-caused failures (not spec defects, recorded so nobody repeats them).** (1) Node's built-in `fetch` ignores the sandbox proxy → run with `NODE_USE_ENV_PROXY=1`. (2) The `ws` WebSocket client also ignores it, which made *every* realtime channel error with `transport failure`, so the first realtime "denials" were meaningless; the **positive twin test caught this**, and after routing `ws` through `https-proxy-agent` the denials and allows were re-measured. (3) The id-only payload assertion was too strict: Realtime adds its own `id`; the payload carried only `id`, `message_id`, `conversation_id` and no body.

**Behaviour to design around.**
* `UPDATE` on a column without a column grant fails with *permission denied for table …* (PostgREST surfaces the table, not the column).
* `supabase-js` realtime logs a notice that `send()` falls back to REST; use `httpSend()` explicitly.
* A realtime join denied by policy reports `CHANNEL_ERROR` (no reason), and a join that is never answered times out — treat both as "no access".
* Realtime revocation is *not* instantaneous for an already-joined socket, as designed: the spike confirmed the `membership.revoked` notification and that database reads stop at once; it did **not** attempt to read new content on a retained subscription because payloads carry no content.

**Not covered by this run (still open).** Signed-URL expiry timing and `Cache-Control`; bucket MIME/size enforcement and quotas; malware scanning; the `forbid_org_change` trigger, scope-ancestor triggers and scoped (campus/ministry/department/team) permissions — the spike implemented organisation-scope roles only, so **SCP-07/08/11/12/14/15 are untested**; MFA `aal2` (S-8); Supabase branching (S-9); S-4 at message-table scale on Supabase hardware; expired-invitation acceptance; PostgREST `select=*` embedding leaks (ISO-12) beyond the tables above; concurrency (INV-08 double accept in parallel).

### Still to run
S-8, S-9; scoped-permission and trigger tests above; S-4 at scale on Supabase; the "not covered" list above. These remain **gates before Phase-1 exit**.


---

## 10. Phase 1 implementation status (2026-11-27)

**State: implemented and verified on a development project; NOT production-ready.** Migrations, tests and CI configuration are in the repository (`supabase/`, `tests/`, `.github/workflows/database.yml`). Nothing has been deployed to a production environment.

### 10.1 What exists

| Item | Detail |
|---|---|
| Migrations | 23 files, `supabase/migrations/20261127100001…100029`. M-001…M-024 implement Phase 0–1 as planned (with the deviations below); M-025…M-029 are **corrective migrations** found by the tests (forward-only: applied migrations are never edited). |
| Tables | 34 relations in `public`/`platform` incl. `audit_events` and 8 monthly partitions: all of Phase-1 group A, B, C, `team_memberships`, `files`, `audit_events`, `platform.*`. |
| Seed | `supabase/seed.sql` (synthetic test users, **never production**); permission/role seed **generated** from `docs/PERMISSIONS_MATRIX.md` (`scripts/generate-permissions-seed.py --check`, negative-tested). |
| Tests | pgTAP: `supabase/tests/database/001_catalogue.test.sql` (structural CAT-*), `002_functions_and_triggers.test.sql` (31 functional assertions). API suite: 9 Vitest files, 121 tests, real password sessions and real JWTs through PostgREST, Storage and Realtime. |
| CI | `.github/workflows/database.yml` (static checks, `supabase start`/`db reset`/`db lint`/`test db`, API suite with a service-role fixture key, gitleaks). **Authored but never executed** — the first GitHub run is its verification. |

### 10.2 Deviations from the plan above

* `team_memberships` moved from Phase 2 into Phase 1 (scope helpers and invitation team pre-assignment depend on it).
* `invitation_tokens` (server-only) replaces a `token_hash` column on `invitations` (spike S-5).
* `service_assignment_private`, `production_plans` SC columns etc. are unchanged (later phases).
* No `rls_matrix.yaml` yet: CAT-19 (policy coverage generated from the matrix) is **not implemented**; policy coverage is currently asserted by the hand-written suites.

### 10.3 Defects found by the tests and fixed (all by corrective migrations)

| Migration | Defect | Found by |
|---|---|---|
| M-025 | **Every function in `public`/`private`/`platform` was executable by `anon`/PUBLIC.** `M-001` revoked default function privileges per schema, which cannot remove PostgreSQL's *global* default `EXECUTE … TO PUBLIC`. Public RPCs still rejected unauthenticated callers and `anon` has no `USAGE` on `private`, so no data was exposed, but it contradicted the specification. Fix: global default revoked, blanket revoke, explicit allow-list re-grant. Also: audit partitions had no RLS of their own (a partition queried directly does not inherit the parent's policies). | CAT-03b/03c, CAT-01 |
| M-026 | `invitation_tokens`/`invitation_teams` referenced `invitations(id)` with a single-column FK, so their `organisation_id` was not pinned to the invitation's (tenant-integrity hole). | CAT-08 |
| M-027 | 15 foreign keys without a supporting index; `membership_contacts` lacked the `organisation_id`-immutability trigger. | CAT-10, CAT-14 |
| M-028 | `memberships.user_id` FK covered only by a partial index. | CAT-10 |
| M-029 | Two permissive UPDATE policies on `memberships` merged (Supabase performance advisor 0006). | advisor |
| (spec) | `files.manage` let Owner/Admin read DM attachments and unattached files. | spike FIL-02c (Supabase) |

Test-code defects found along the way (not product defects): a NUL byte in a filename, a `Blob` without a MIME type (Storage correctly enforced the bucket allow-list), a duplicate Realtime channel after a denied join, and an assertion over a status history shared across test files.

### 10.4 Verification results (development project, Postgres 17, real Supabase Auth/Storage/Realtime)

| Suite | Result |
|---|---|
| pgTAP catalogue (CAT-01…CAT-21 as implemented) | all pass after M-025…M-028 (initial run: 8 of 34 failed) |
| pgTAP functional (`002`) | 31 / 31 |
| API security suite | 117 passed, 4 skipped, 0 failed (the 4 skipped need a service-role fixture key and run in CI) |
| Supabase advisors (security) | 0 errors. 13 INFO "RLS enabled, no policy" = the intended deny-all tables and partitions. 16 WARN "signed-in users can execute SECURITY DEFINER function" = the deliberate RPC surface (each validates identity inside). 1 WARN "leaked-password protection disabled" = **Auth dashboard setting, must be enabled before production**. |
| Supabase advisors (performance) | 1 WARN fixed (M-029). INFO: 31 "unindexed foreign keys" are composite FKs whose supporting index is `(x)` or `(organisation_id, x)` rather than the exact column order the linter wants (accepted for Phase-1 volumes); unused-index notices on a fresh database. |
| From-scratch apply | all 23 migration files apply cleanly to an empty database; seed counts 45 / 8 / 194; `anon` can execute 0 functions. |

### 10.5 Not done / required before any production use

1. **CI has not run.** Run it on GitHub; fix whatever it finds.
2. **Not covered by tests yet:** signed-URL expiry and `Cache-Control`; malware scanning (no scanner exists — files never become `available` without a service-role actor); parallel double-accept of one invitation; per-user quota edge cases; Realtime behaviour for a socket that stays open across a suspension beyond the first check (only the revoke notification and fresh-join denial are tested); `platform.*` console functions beyond privilege checks; `erase_my_account()` (not implemented); retention/purge jobs (not implemented); `report_exports`, notifications and every Phase 2+ table (not created).
3. **Operational:** separate production project, backups and a **restore drill**, monitoring/alerting (including the audit DEFAULT-partition alert and partition job), incident runbook, key-rotation drill, enabling Auth leaked-password protection and the production Auth/email settings, rate limiting at the edge for sign-in/recovery/invitation endpoints.
4. **Review:** independent security review of every `SECURITY DEFINER` function and policy; penetration test (tenant isolation, invitations, storage, realtime); legal decisions D-016/D-033/D-040/D-043.
5. **MFA is deferred by decision** (D-027): the `require_aal2()` hook exists and is inert.
6. **Performance** was measured at SQL level on a local database (spike S-4); repeat on production-class hardware at realistic volumes before launch.
