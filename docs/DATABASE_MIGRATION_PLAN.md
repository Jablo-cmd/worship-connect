# Worship Connect — Database Migration Plan

**Version:** 0.1 (draft for review) | **Status:** Proposed — **no migration exists and none should be created until this specification is approved.**

Companion documents: [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) · [RLS_SECURITY_SPECIFICATION.md](RLS_SECURITY_SPECIFICATION.md) · [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md) · [ROADMAP.md](ROADMAP.md)

`DOMAIN_MODEL.md` §14 forbids creating "every conceptual table in one unreviewed migration". This plan delivers 102 tables in **small, reviewable migrations aligned to the roadmap phases**: no table exists before the phase that needs it.

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
| M-016 | `invitations` | `invitations`, `invitation_teams`; column privilege on `token_hash` | M-014, M-015 |
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
| S-5 | PostgREST with column-level `GRANT UPDATE (cols)` and `REVOKE SELECT (token_hash)` — behaviour of `select=*` and error shape | Documented client rule: never `select *` on `invitations`; use views/RPC where needed |
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
