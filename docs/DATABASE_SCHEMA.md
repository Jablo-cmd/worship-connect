# Worship Connect — Database Schema Specification

**Version:** 0.1 (draft for review) | **Status:** Proposed — specification only. No migration exists; nothing here is implemented.

Companion documents: [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) (decisions and rationale) · [RLS_SECURITY_SPECIFICATION.md](RLS_SECURITY_SPECIFICATION.md) · [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md) · [DATABASE_MIGRATION_PLAN.md](DATABASE_MIGRATION_PLAN.md) · [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md)

The SQL in this document is *illustrative specification*, deliberately not a runnable migration. Real migrations are written per [DATABASE_MIGRATION_PLAN.md](DATABASE_MIGRATION_PLAN.md) after this specification is approved.

---

## 0. How to read this document

### 0.1 Schemas

| Schema | Contents | Exposed through the Supabase Data API? |
|---|---|---|
| `public` | All tenant-owned and global-identity tables, plus the small set of RPC functions the client may call | Yes — **RLS on every table** |
| `private` | `SECURITY DEFINER` helper functions used by policies and triggers; trigger functions | **No** (never listed in the API's exposed schemas) |
| `platform` | Platform-staff tables (admins, support grants, takedown requests, organisation status log) | **No** — server-side console only |
| `auth`, `storage`, `realtime`, `extensions` | Supabase-managed | Policies are added to `storage.objects` and `realtime.messages` only |

### 0.2 Conventions used in every table definition

**STD columns** (implicit in every tenant-owned table; not repeated below):

```
id               uuid         PK  DEFAULT gen_random_uuid()
organisation_id  uuid         NOT NULL  REFERENCES organisations(id)   -- the tenant key
created_at       timestamptz  NOT NULL  DEFAULT now()
updated_at       timestamptz  NOT NULL  DEFAULT now()                  -- maintained by trigger
UNIQUE (organisation_id, id)                                            -- "TK": parent target for composite FKs
```

**Composite tenant FK pattern (normative).** Any foreign key from one tenant-owned table to another is declared on `(organisation_id, <parent>_id)` referencing the parent's `(organisation_id, id)`. This makes it *physically impossible* for a row of organisation A to reference a row of organisation B, whatever the application or a buggy RPC does. Written `FK (org, x_id) → x` below; shortened to `→ x` in column lists. Foreign keys to *global* tables (`profiles`, `permissions`, system `roles`) are ordinary single-column FKs.

**SC columns** ("scope columns") — carried by tables whose rows can be restricted to a part of the organisation:

```
campus_id      uuid NULL  FK (org, campus_id)      → campuses
ministry_id    uuid NULL  FK (org, ministry_id)    → ministries
department_id  uuid NULL  FK (org, department_id)  → departments
team_id        uuid NULL  FK (org, team_id)        → teams
```
A trigger (`private.fill_scope_ancestors`) derives all higher levels from the **lowest level set** and rejects inconsistent combinations. Result: a row scoped to team *T* always carries *T*'s department, ministry and campus, so `has_perm()` can match any scoped role assignment without joins. All-NULL means organisation-wide.

**RS columns** ("role-scope") — used by `membership_role_assignments` and `invitations`:

```
scope_type     text NOT NULL DEFAULT 'organisation'
               CHECK (scope_type IN ('organisation','campus','ministry','department','team'))
campus_id / ministry_id / department_id / team_id   uuid NULL (composite FKs as above)
CHECK ( (scope_type='organisation' AND num_nonnulls(campus_id,ministry_id,department_id,team_id)=0)
     OR (scope_type='campus'     AND campus_id     IS NOT NULL AND num_nonnulls(ministry_id,department_id,team_id)=0)
     OR (scope_type='ministry'   AND ministry_id   IS NOT NULL AND num_nonnulls(campus_id,department_id,team_id)=0)
     OR (scope_type='department' AND department_id IS NOT NULL AND num_nonnulls(campus_id,ministry_id,team_id)=0)
     OR (scope_type='team'       AND team_id       IS NOT NULL AND num_nonnulls(campus_id,ministry_id,department_id)=0) )
```
Typed columns replace the polymorphic `scope_id` in `DOMAIN_MODEL.md` §3, because a polymorphic id cannot carry a foreign key.

**Delete policy codes** (column `DEL` in each table, expanded in §14):

| Code | Meaning |
|---|---|
| **H** | Hard delete permitted to authorised users (row has no independent history value) |
| **A** | Archive: set `archived_at`; row remains for history and is hidden from default views |
| **S** | Lifecycle status (`cancelled`, `ended`, `removed`…) — never deleted in normal operation |
| **T** | Tombstone: content blanked, row retained (messages) |
| **R** | Restricted: no client delete; removed only by server-side retention/erasure jobs |
| **X** | Append-only: never updated or deleted by the application; removed only by partition drop / retention job |

**Types.** `uuid` keys; `text` (never `varchar(n)`) with `CHECK (char_length(...))` where limits matter; `citext` for e-mail and slug; `timestamptz` for instants; `date`/`time` for civil values; `integer`/`smallint` for counts; `numeric(p,s)` for measures; `bytea` for hashes; `jsonb` only for immutable snapshots, validated filter parameters and cosmetic UI flags — **never** for data that needs constraints, joins or permissions. **Statuses and categories are `text` + `CHECK (... IN (...))`, not native enums**, because enum values cannot be removed and are awkward to change in migrations; changing a CHECK is a cheap, reviewable migration.

**Timezones.** See §13.

**Naming.** snake_case, plural table names, `*_id` for FKs, `*_at` for instants, `*_on` for dates, `*_membership_id` for "actor/assignee as a person in this church".

**Optimistic concurrency.** Tables marked `row_version` carry `row_version integer NOT NULL DEFAULT 1`, incremented by trigger on every update; collaborative edit RPCs accept `expected_row_version` and fail with a conflict error if it no longer matches.

### 0.3 Table inventory (summary)

| Group | Tables | Count |
|---|---|---:|
| A. Identity & tenancy | `profiles`, `organisations`, `organisation_settings`, `memberships`, `membership_status_events`, `membership_contacts`, `invitations`, `invitation_tokens`, `invitation_teams`, `policy_acceptances` | 10 |
| B. Organisation structure | `campuses`, `ministries`, `departments`, `teams`, `locations` | 5 |
| C. Authorisation | `permissions`, `roles`, `role_permissions`, `membership_role_assignments` | 4 |
| P. Platform (schema `platform`) | `platform.admins`, `platform.support_access_grants`, `platform.takedown_requests`, `platform.organisation_status_log` | 4 |
| D. People & team operations | `team_memberships`, `positions`, `skills`, `member_skills`, `member_positions`, `member_vocal_profiles`, `member_unavailability`, `member_unavailability_notes`, `member_availability_preferences`, `member_emergency_contacts`, `member_private_notes`, `onboarding_plans`, `onboarding_plan_steps`, `member_onboarding`, `member_onboarding_steps` | 15 |
| E. Files | `files`, `file_attachments` | 2 |
| F. Music library | `songs`, `song_alternate_titles`, `writers`, `song_writer_credits`, `song_rights`, `song_arrangements`, `arrangement_sections`, `song_resources`, `song_notes`, `tags`, `song_tags`, `member_song_preferences` | 12 |
| G. Services | `service_types`, `event_series`, `service_templates`, `service_template_items`, `service_template_slots`, `services`, `service_programme_items`, `service_songs`, `service_song_sections`, `service_assignments`, `service_assignment_private`, `service_notes`, `service_revisions` | 13 |
| H. Rehearsals, tasks, attendance | `rehearsals`, `rehearsal_songs`, `rehearsal_participants`, `rehearsal_notes`, `tasks`, `task_assignees`, `attendance_records` | 7 |
| I. Meetings | `meetings`, `meeting_participants`, `meeting_agenda_items`, `meeting_minutes`, `meeting_decisions` | 5 |
| J. Communication | `announcements`, `announcement_receipts`, `conversations`, `conversation_participants`, `messages`, `message_attachments`, `message_reactions`, `message_reports`, `notifications`, `notification_preferences`, `notification_deliveries`, `push_subscriptions` | 12 |
| K. Technical production | `equipment_items`, `equipment_allocations`, `production_plans`, `production_plan_revisions`, `stage_plots`, `stage_plot_elements`, `input_list_items`, `monitor_requirements`, `production_cues`, `production_checklist_items`, `production_requirements`, `production_notes` | 12 |
| L. Reporting & audit | `audit_events`, `report_exports` | 2 |
| | **Total** | **103** |

Reserved but **not** in v1 (see [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) §12): `membership_permission_overrides`, `plans`/`organisation_entitlements`, AI-processing tables, `message_edit_history`.

### 0.4 Global versus organisation-owned

| Class | Tables | Notes |
|---|---|---|
| **Global identity** (no `organisation_id`) | `profiles`, `push_subscriptions` | Owned by the user; visible only to that user (and platform support under grant). One row per person regardless of how many churches. |
| **Global reference data** | `permissions`, system rows of `roles`, their `role_permissions` | Platform-owned, read-only to tenants. |
| **Tenant root** | `organisations` | The tenant itself. |
| **Organisation-owned** | Everything else in `public` | Carries `organisation_id`; protected by composite FKs and RLS. |
| **Platform-owned** | `platform.*` | Never reachable from the browser. |
| **Cross-tenant by design** | `audit_events` (nullable `organisation_id`, no FK so history survives tenant purge) | Written only by privileged functions. |

---

## A. Identity and tenancy

```
Auth (auth.users) 1—1 profiles
profiles 1—N memberships N—1 organisations 1—1 organisation_settings
memberships 1—N membership_status_events, 1—1 membership_contacts
organisations 1—N invitations (—N invitation_teams) ; invitation → memberships (on accept)
```

### `profiles` — global user profile (one per person)
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | `REFERENCES auth.users(id) ON DELETE CASCADE`; equals `auth.uid()` |
| `display_name` | text NOT NULL | 1–100 chars. Account-level name; **never shown to other churches** (each church sees `memberships.display_name`). |
| `preferred_timezone` | text NULL | IANA name, validated (§13) |
| `locale` | text NOT NULL DEFAULT 'en' | BCP-47 tag |
| `avatar_path` | text NULL | Own-account use only (bucket `avatars`, path `{user_id}/…`) |
| `terms_accepted_at`, `terms_version` | timestamptz, text NULL | Platform terms |
| `anonymised_at` | timestamptz NULL | Set by erasure procedure |
| `created_at`, `updated_at` | timestamptz | |

E-mail and credentials remain in `auth.users`; they are **not duplicated** here. Created by trigger on `auth.users` insert. **DEL: R** (erasure = anonymise, then delete auth user).

### `organisations` — the tenant (church)
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `name` | text NOT NULL | 1–120 |
| `slug` | citext NOT NULL UNIQUE | `^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$`; immutable after creation (trigger) |
| `status` | text NOT NULL DEFAULT 'active' | `active`, `suspended`, `closing`, `closed`. Changed **only** by platform functions. |
| `status_changed_at` | timestamptz | |
| `timezone` | text NOT NULL | IANA default for new events |
| `country_code` | char(2) NULL | ISO 3166-1 |
| `contact_email` | citext NULL | CHECK basic shape |
| `contact_phone` | text NULL | |
| `website_url` | text NULL | `^https://` |
| `created_by` | uuid NULL | → profiles ON DELETE SET NULL |
| `closing_requested_at`, `scheduled_purge_at` | timestamptz NULL | Closure workflow |
| `created_at`, `updated_at` | timestamptz | |

`organisation_id` is *not* a column of this table; its `id` is the tenant key. UNIQUE `(id)` suffices. **DEL: S** (closure → purge job).

### `organisation_settings` — settings and preferences (1:1)
| Column | Type | Notes |
|---|---|---|
| `organisation_id` | uuid PK | → organisations (no separate `id`) |
| `locale` | text DEFAULT 'en' | |
| `week_starts_on` | smallint DEFAULT 0 | CHECK 0–6 |
| `default_service_duration_minutes` | integer DEFAULT 90 | CHECK 15–600 |
| `member_directory_visibility` | text DEFAULT 'names_and_teams' | `names_only` \| `names_and_teams` |
| `allow_direct_messages` | boolean DEFAULT true | Disables creation of `direct`/`group` conversations |
| `require_mfa_for_privileged` | boolean DEFAULT false | If true, actions guarded by `private.require_aal2()` demand MFA (decision D-027) |
| `message_retention_days` | integer NULL | NULL = keep until deleted. Policy open (D-017) |
| `attendance_retention_months` | integer NULL | |
| `logo_file_id` | uuid NULL | FK (org, logo_file_id) → files |
| `ui_flags` | jsonb NOT NULL DEFAULT '{}' | **Cosmetic only. Never read by RLS or authorisation.** |
| `created_at`, `updated_at` | timestamptz | |

**DEL: R**. Created inside `create_organisation()`.

### `memberships` — a person's membership of one church
STD + TK.
| Column | Type | Notes |
|---|---|---|
| `user_id` | uuid NULL | → profiles ON DELETE SET NULL. NULL only after erasure (see CHECK). |
| `status` | text NOT NULL DEFAULT 'active' | `active`, `suspended`, `removed`. **There is no `invited` status** — an invitee has no membership row (D-021). |
| `display_name` | text NOT NULL | 1–100; the name this church sees. Copied from the profile at acceptance; editable by the member. |
| `avatar_file_id` | uuid NULL | FK (org, avatar_file_id) → files (organisation-owned copy) |
| `home_campus_id` | uuid NULL | FK (org, ·) → campuses |
| `joined_at` | timestamptz NOT NULL DEFAULT now() | First activation |
| `status_changed_at` | timestamptz | |
| `anonymised_at` | timestamptz NULL | |

* UNIQUE `(organisation_id, user_id)` — **one row per person per church for all time**; rejoining re-activates it (history keeps a stable identity).
* CHECK `(user_id IS NOT NULL) OR (status='removed' AND anonymised_at IS NOT NULL)`.
* IDX `(user_id, organisation_id) WHERE status='active'` — **hot path for every RLS check**; IDX `(organisation_id, status)`.
* Triggers: status-transition guard (`active→suspended→active`, `active|suspended→removed`, `removed→active` only via invitation acceptance); last-owner guard; auto-assign `member` role on insert; audit.
* **DEL: R** (never hard-deleted, except by organisation purge).

### `membership_status_events` — lifecycle history
STD (no `updated_at`).
| Column | Type | Notes |
|---|---|---|
| `membership_id` | uuid NOT NULL | → memberships |
| `from_status`, `to_status` | text | `NULL` from-status on first join |
| `reason` | text NULL | ≤500. **Restricted** — this is why the reason is not a column on `memberships` (the directory table). |
| `actor_user_id` | uuid NULL | → profiles ON DELETE SET NULL |
| `occurred_at` | timestamptz DEFAULT now() | |
Append-only. IDX `(membership_id, occurred_at DESC)`. **DEL: X**.

### `membership_contacts` — member contact details (restricted)
| Column | Type | Notes |
|---|---|---|
| `membership_id` | uuid PK | → memberships (1:1), plus `organisation_id` |
| `phone` | text NULL | E.164 preferred |
| `contact_email` | citext NULL | Church-specific; need not equal the sign-in e-mail |
| `preferred_method` | text NULL | `in_app`,`email`,`phone`,`whatsapp` |
| `created_at`, `updated_at` | | |
Readable by the member and by holders of `members.view_contact` over that member. **DEL: H** (own) / purged on removal.

### `invitations`
STD + TK + RS columns.
| Column | Type | Notes |
|---|---|---|
| `email` | citext NOT NULL | Invitation is **bound to this verified e-mail** (D-022) |
| `status` | text NOT NULL DEFAULT 'pending' | `pending`, `accepted`, `revoked`, `expired` |
| `role_id` | uuid NULL | → roles (extra role to give at the RS scope; `member` is always given). Trigger: role must be global or this organisation's; ceiling check at creation. |
| `invited_by_membership_id` | uuid NOT NULL | → memberships |
| `personal_message` | text NULL | ≤500 |
| `expires_at` | timestamptz NOT NULL | default `now()+14 days`; CHECK `≤ created_at + 60 days` |
| `send_count` | smallint DEFAULT 1; `last_sent_at` | Resend throttling |
| `accepted_by_user_id` | uuid NULL | → profiles |
| `accepted_membership_id` | uuid NULL | → memberships |
| `accepted_at`, `revoked_at` | timestamptz NULL | |
| `revoked_by_membership_id` | uuid NULL | → memberships |

* UNIQUE partial `(organisation_id, email) WHERE status='pending'`.
* CHECK status coherence (`accepted` ⇒ `accepted_at` and `accepted_membership_id` not null; `revoked` ⇒ `revoked_at`).
* The token hash is **not a column of this table**: it lives in `invitation_tokens` (below), a server-only table with no client grants. (Spike S-5: a column-level `REVOKE SELECT` is ineffective while a table-level grant exists, and the correct column-list grant makes `select *` fail — which is PostgREST's default shape. A split table avoids both traps.)
* **DEL: R** — terminal invitations purged 90 days after resolution (accepted invitations keep a minimal audit trail in `audit_events`).

### `invitation_tokens` (server-only)
| Column | Type | Notes |
|---|---|---|
| `invitation_id` | uuid PK | → invitations ON DELETE CASCADE (1:1), plus `organisation_id` |
| `token_hash` | bytea NOT NULL UNIQUE | SHA-256 of a 256-bit random token; the raw token is returned once by `create_invitation()` and never stored |
RLS enabled, **no policies and no grants** to `anon`/`authenticated`; read/written only by the `SECURITY DEFINER` invitation functions. **DEL: H** with parent.

### `invitation_teams`
| Column | Notes |
|---|---|
| `organisation_id`, `invitation_id`, `team_id` | PK `(invitation_id, team_id)`; composite FKs. Teams to join on acceptance (must lie within the inviter's `members.invite` scope — checked at creation). **DEL: H** with parent. |

### `policy_acceptances`
STD (no `updated_at`).
| Column | Type | Notes |
|---|---|---|
| `membership_id` | uuid | → memberships |
| `policy_key` | text | `music_rights`, `recording_consent`, `privacy_notice`, `terms` … |
| `policy_version` | text | |
| `accepted_at` | timestamptz DEFAULT now() | |
UNIQUE `(membership_id, policy_key, policy_version)`. Used to make **tenant responsibility for copyright** explicit (D-016) and to record recording consent. **DEL: X**.

---

## B. Organisation structure

```
organisations ─< campuses
              ─< ministries  (campus_id NULL = organisation-wide ministry)
              ─< departments (ministry_id NULL, campus_id NULL)
              ─< teams       (department_id NULL, ministry_id NULL, campus_id NULL)
              ─< locations   (campus_id NULL)
```
Every level is optional (D-003). Ancestor columns on each child are **derived** (never trusted from the client) by `private.fill_scope_ancestors`.

### `campuses`
STD + TK.
| Column | Type | Notes |
|---|---|---|
| `name` | text NOT NULL | 1–100; UNIQUE `(organisation_id, lower(name)) WHERE archived_at IS NULL` |
| `code` | text NULL | short label |
| `address_line`, `city`, `region`, `postal_code` | text NULL | |
| `country_code` | char(2) NULL | |
| `timezone` | text NULL | NULL ⇒ organisation timezone |
| `is_primary` | boolean DEFAULT false | UNIQUE partial: at most one primary per org |
| `archived_at` | timestamptz NULL | |
**DEL: A**.

### `ministries`
STD + TK. `name` (UNIQUE per org among non-archived), `description`, `campus_id` NULL → campuses (NULL = organisation-wide), `archived_at`. **DEL: A**.

### `departments`
STD + TK. `name`, `description`, `category` (text, see teams), `ministry_id` NULL → ministries, `campus_id` NULL → campuses (derived from ministry when ministry has one), `archived_at`. UNIQUE `(organisation_id, ministry_id, lower(name))` among non-archived (NULL ministry coalesced). **DEL: A**.

### `teams`
STD + TK. `name`, `description`, `category`, `department_id` NULL, `ministry_id` NULL, `campus_id` NULL (last three derived), `archived_at`.
`category` CHECK IN (`band`,`vocal`,`choir`,`orchestra`,`sound`,`lighting`,`media`,`projection`,`livestream`,`stage`,`hospitality`,`prayer`,`administration`,`other`) — **not limited to musicians** (principle in task §8).
IDX `(organisation_id, department_id)`, `(organisation_id, campus_id)`. **DEL: A**.

### `locations` — venues and rooms
STD + TK. `campus_id` NULL → campuses, `name`, `kind` CHECK IN (`sanctuary`,`rehearsal_room`,`hall`,`outdoor`,`online`,`offsite`,`other`), `room`, `address_text`, `capacity` integer NULL (>0), `online_url` text NULL (`^https://`), `timezone` NULL, `archived_at`. Replaces the free-text "venue" in the domain model so services and rehearsals can be conflict-checked against a room. **DEL: A**.

---

## C. Authorisation

### `permissions` — global catalogue (platform-owned)
| Column | Type | Notes |
|---|---|---|
| `key` | text PK | `^[a-z_]+(\.[a-z_]+)+$` (e.g. `services.publish`). Text PK is deliberate: keys are stable, human-readable, seeded identically in every environment and appear in policies/tests. |
| `description` | text NOT NULL | |
| `category` | text NOT NULL | grouping for admin UI |
| `allowed_scopes` | text[] NOT NULL | subset of the five scope names; CHECK non-empty |
| `is_sensitive` | boolean DEFAULT false | |
| `deprecated_at` | timestamptz NULL | |
Seeded from [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md) §2 (45 rows). Writable only by migrations. **DEL: R**.

### `roles`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `organisation_id` | uuid NULL | NULL ⇒ **system role** (global, read-only); non-NULL ⇒ custom role of that church |
| `system_key` | text NULL | `owner`, `admin`, `pastor`, `worship_director`, `department_leader`, `team_leader`, `production_lead`, `member` |
| `name`, `description` | text | |
| `is_system` | boolean NOT NULL | CHECK `is_system = (organisation_id IS NULL)` and `is_system = (system_key IS NOT NULL)` |
| `assignable_scopes` | text[] NOT NULL | e.g. owner `{organisation}`; team_leader `{team}` |
| `show_in_directory` | boolean DEFAULT false | If true, assignments of this role are visible to all members (leader lists) |
| `archived_at` | timestamptz NULL | |
UNIQUE `(system_key)`; UNIQUE `(organisation_id, lower(name))` for custom roles. UNIQUE `(organisation_id, id)` (usable as FK target for custom-role-only references). A trigger validates that a role used in an assignment/invitation is global or belongs to the **same** organisation (FKs to nullable-org rows cannot express this). **DEL: A** (custom), **R** (system).

Why system roles are global rows and not copied per tenant: new permissions or role changes ship once and apply everywhere without per-tenant drift; tenants customise by creating **custom roles**, not editing system ones (D-023).

### `role_permissions`
| Column | Notes |
|---|---|
| `role_id` → roles ON DELETE CASCADE, `permission_key` → permissions(key) | PK `(role_id, permission_key)`. IDX `(permission_key)`. For system roles writable only by migrations; for custom roles writable by `roles.manage` through RLS on the parent role's organisation. Trigger rejects `org.ownership.manage` in custom roles. **DEL: H** (custom roles) / **R** (system). |

### `membership_role_assignments`
STD + TK + RS columns.
| Column | Type | Notes |
|---|---|---|
| `membership_id` | uuid NOT NULL | → memberships |
| `role_id` | uuid NOT NULL | → roles (global or same-org; trigger) |
| `expires_at` | timestamptz NULL | temporary cover |
| `assigned_by_membership_id` | uuid NULL | → memberships |
| `revoked_at`, `revoked_by_membership_id` | | soft revoke keeps history |
* An assignment is **effective** iff `revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())` and the membership is active.
* UNIQUE `(membership_id, role_id, scope_type, coalesce(campus_id, ministry_id, department_id, team_id))` WHERE `revoked_at IS NULL`.
* Triggers: scope must be in `roles.assignable_scopes`; last-owner guard; audit; no self-assignment (also enforced in the RPC).
* IDX `(membership_id) WHERE revoked_at IS NULL` — **hot path**; IDX `(organisation_id, role_id)`.
* Direct DML is **not** exposed to clients; `assign_role()` / `revoke_role()` RPCs enforce the privilege ceiling. **DEL: S** (revoke).

---

## P. Platform schema (`platform`) — never exposed to the browser

### `platform.admins`
| Column | Notes |
|---|---|
| `user_id` uuid PK → auth.users | `role` CHECK IN (`support`,`admin`,`superadmin`); `created_by`, `created_at`, `disabled_at`. Separate identity space from church roles. |

### `platform.support_access_grants` — purpose-limited, time-boxed tenant access
| Column | Notes |
|---|---|
| `id` uuid PK; `organisation_id` → organisations | |
| `platform_user_id` → platform.admins | who may access |
| `granted_by_membership_id` | an **Owner** of that church (or `break_glass=true` with two platform approvers) |
| `level` | `metadata` \| `content_read` |
| `reason`, `ticket_ref` | mandatory |
| `starts_at`, `expires_at` | CHECK `expires_at ≤ starts_at + 72 hours` |
| `revoked_at`, `break_glass boolean`, `second_approver_user_id` | |
Every use is written to `audit_events` with `actor_type='platform_support'` and is visible to the church's Owners. **DEL: X**.

### `platform.takedown_requests`
| Column | Notes |
|---|---|
| `id`, `organisation_id` NULL, `reporter_name`, `reporter_contact`, `claim_text`, `target_song_resource_id` NULL, `target_file_id` NULL, `status` (`received`,`reviewing`,`content_disabled`,`rejected`,`reinstated`), `received_at`, `actioned_by`, `actioned_at`, `notes` | Supports the complaint/takedown process required by `SECURITY_AND_PRIVACY.md` §10. Action sets `files.status='quarantined'` and disables the resource. **DEL: X**. |

### `platform.organisation_status_log`
`id`, `organisation_id`, `from_status`, `to_status`, `reason`, `actor_user_id`, `occurred_at`. Append-only. **DEL: X**.

---

## D. People and team operations

```
memberships ─< team_memberships >─ teams
memberships ─< member_skills >─ skills ; ─< member_positions >─ positions
memberships ─1 member_vocal_profiles ; ─< member_unavailability ─1 member_unavailability_notes
memberships ─1 member_availability_preferences ; ─< member_emergency_contacts ; ─< member_private_notes
onboarding_plans ─< onboarding_plan_steps ; memberships ─< member_onboarding ─< member_onboarding_steps
```

**Team leadership** is *not* a column here. A team leader is a member holding the `team_leader` role scoped to that team; a department leader holds `department_leader` scoped to the department. One mechanism, one source of truth; "who leads this team?" is a view over `membership_role_assignments` joined to roles with `show_in_directory`.

### `team_memberships`
STD + TK. `team_id` → teams, `membership_id` → memberships, `status` CHECK IN (`active`,`inactive`,`alumni`) DEFAULT 'active', `joined_on` date DEFAULT current_date, `left_on` date NULL (CHECK ≥ joined_on), `added_by_membership_id`.
UNIQUE `(team_id, membership_id)`. IDX `(membership_id, team_id) WHERE status='active'` — hot path for scope-based visibility. **DEL: H** (leaving) — history of past membership is captured by `status='alumni'` plus audit.

### `positions` — what a person does in a service (not a role)
STD + TK. `name`, `category` CHECK IN (`vocal`,`instrument`,`audio`,`lighting`,`media`,`projection`,`livestream`,`stage`,`leadership`,`hospitality`,`other`), `description`, `department_id` NULL → departments (suggested home), `suggested_skill_id` NULL → skills, `sort_order` smallint, `archived_at`. UNIQUE `(organisation_id, lower(name))` among non-archived. Seeded per church with a neutral starter set (Lead Vocal, Backing Vocal, Keys, Acoustic Guitar, Bass, Drums, FOH Engineer, Monitor Engineer, Lighting Operator, Slides Operator, Camera Operator, Stage Manager…). **DEL: A**.

### `skills`
STD + TK. `name`, `category` CHECK IN (`instrument`,`vocal_role`,`technical`,`musical`,`other`), `archived_at`. UNIQUE `(organisation_id, category, lower(name))`. Instruments and vocal roles (lead, harmony, …) are skills; vocal *ranges* are in `member_vocal_profiles`. **DEL: A**.

### `member_skills`
STD + TK. `membership_id`, `skill_id`, `proficiency` smallint NULL CHECK 1–5 (**self-assessed unless `verified_at` set; never presented as objective**), `years_experience` smallint NULL, `is_primary` boolean, `verified_by_membership_id` NULL, `verified_at` NULL. UNIQUE `(membership_id, skill_id)`. **DEL: H**.

### `member_positions` — positions the member can fill
STD + TK. `membership_id`, `position_id`, `is_primary` boolean, `status` CHECK IN (`qualified`,`in_training`), UNIQUE `(membership_id, position_id)`. Drives substitute suggestions and unfilled-role search. **DEL: H**.

### `member_vocal_profiles`
`membership_id` PK → memberships (1:1) + `organisation_id`. `voice_type` CHECK IN (`soprano`,`mezzo_soprano`,`alto`,`countertenor`,`tenor`,`baritone`,`bass`,`unknown`), `lowest_note`, `highest_note`, `comfortable_lowest_note`, `comfortable_highest_note` (text, scientific pitch notation `^[A-G](#|b)?[0-8]$`), `can_lead` boolean, `can_harmonise` boolean, `notes` text ≤500, timestamps. Optional; visible to leaders planning vocals (`services.assign` over the member's team or `members.view_contact` scope — see RLS spec) and the member. **DEL: H**.

### `member_unavailability`
STD + TK. `membership_id`, `starts_at` timestamptz, `ends_at` timestamptz, `all_day` boolean, `timezone` text, `kind` CHECK IN (`unavailable`,`tentative`,`limited`), `rrule` text NULL (repeating pattern, validated subset), CHECK `ends_at > starts_at`.
IDX GiST `(membership_id, tstzrange(starts_at, ends_at))` for conflict detection. **The reason is deliberately not here** — see next table. **DEL: H**.

### `member_unavailability_notes`
`unavailability_id` PK → member_unavailability, `organisation_id`, `membership_id` (denormalised for RLS), `note` text ≤500. Readable **only by the member** — leaders see dates/`kind`, never why. **DEL: H** with parent; purged 90 days after the period ends.

### `member_availability_preferences`
`membership_id` PK + `organisation_id`; `max_assignments_per_month` smallint NULL (CHECK 1–31), `scheduling_notes` text ≤500 (member knows leaders can read it), timestamps. **DEL: H**.

### `member_emergency_contacts` (optional, restricted)
STD + TK. `membership_id`, `contact_name`, `relationship`, `phone`, `is_primary` boolean (UNIQUE partial per member), `consent_recorded_at` timestamptz NOT NULL (must be set; the member entered it themselves). Readable by the member and `members.notes.manage` over that member. **DEL: H**; purged on removal.

### `member_private_notes` (restricted leader notes)
STD + TK. `membership_id` (subject), `author_membership_id`, `category` CHECK IN (`development`,`scheduling`,`pastoral_care`,`general`), `body` text ≤4000, `visibility` CHECK IN (`author_only`,`leaders_in_scope`), `archived_at`. Readable by author and (if `leaders_in_scope`) `members.notes.manage` over the subject. Subject **cannot** read (see risk R-9 about data-subject access in [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) §13). **DEL: A**; hard-purged on subject erasure request subject to legal review.

### `onboarding_plans`
STD + TK + SC. `name`, `description`, `position_id` NULL → positions, `is_default` boolean, `archived_at`. **DEL: A**.

### `onboarding_plan_steps`
STD + TK. `plan_id`, `step_order` int (DEFERRABLE UNIQUE `(plan_id, step_order)`), `title`, `description`, `step_type` CHECK IN (`read`,`watch`,`complete_form`,`attend`,`shadow`,`sign_off`,`other`), `requires_verification` boolean, `resource_file_id` NULL → files, `resource_url` NULL (`^https://`). **DEL: H**.

### `member_onboarding`
STD + TK. `membership_id`, `plan_id`, `status` CHECK IN (`not_started`,`in_progress`,`completed`,`cancelled`), `started_at`, `completed_at`, `mentor_membership_id` NULL, `assigned_by_membership_id`. UNIQUE `(membership_id, plan_id)`. **DEL: S**.

### `member_onboarding_steps`
STD + TK. `member_onboarding_id`, `plan_step_id`, `status` CHECK IN (`pending`,`done`,`skipped`), `completed_at`, `verified_by_membership_id` NULL, `verified_at` NULL, `note` text ≤500. UNIQUE `(member_onboarding_id, plan_step_id)`. **DEL: H** with parent.

---

## E. Files

All uploaded objects are registered in `files` *before* upload; the storage policy only accepts an object whose path matches a pending `files` row (see RLS spec §8). Domain tables reference `files(id)`; they never store raw storage paths.

### `files`
STD + TK.
| Column | Type | Notes |
|---|---|---|
| `uploaded_by_user_id` | uuid NULL | → profiles ON DELETE SET NULL (not membership: avoids a `memberships ↔ files` cycle) |
| `bucket` | text NOT NULL DEFAULT 'org-files' | |
| `storage_path` | text NOT NULL UNIQUE | `{organisation_id}/{file_id}/{safe_filename}`; CHECK it starts with `organisation_id/id/` |
| `original_filename` | text NOT NULL | display only; never used in a path unsanitised |
| `mime_type` | text NOT NULL | allow-listed (CHECK against a list; bucket also enforces) |
| `size_bytes` | bigint NOT NULL | CHECK `> 0 AND ≤ 104857600` (100 MB hard ceiling; per-purpose limits in the RPC) |
| `sha256` | bytea NULL | set at finalisation |
| `purpose` | text NOT NULL | `song_resource`,`message_attachment`,`voice_note`,`meeting_document`,`service_file`,`rehearsal_recording`,`production_document`,`stage_plot_background`,`member_avatar`,`org_logo`,`report_export`,`permission_document`,`other` |
| `status` | text NOT NULL DEFAULT 'pending_upload' | `pending_upload`,`uploaded`,`available`,`quarantined`,`rejected`,`deleted` |
| `scan_status` | text NOT NULL DEFAULT 'not_scanned' | `not_scanned`,`clean`,`infected`,`error`,`not_required` |
| `scanned_at`, `deleted_at`, `retention_until` | timestamptz NULL | |

A file is readable only when `status='available'` **and** `scan_status IN ('clean','not_required')`. IDX `(organisation_id, purpose, created_at DESC)`, `(uploaded_by_user_id)`. **DEL: R** (soft `deleted` + purge job removes object then row).

### `file_attachments` — attach a file to a service, rehearsal, meeting, production plan or task
STD + TK. `file_id` → files; exactly one of `service_id`, `rehearsal_id`, `meeting_id`, `production_plan_id`, `task_id` (CHECK `num_nonnulls(...)=1`; each composite FK; `meeting_id`/`production_plan_id` FKs are added by the migration that creates those tables); `label`, `kind` (`document`,`chart`,`recording`,`diagram`,`other`), `sort_order`, `attached_by_membership_id`. UNIQUE per (target, file). **DEL: H**.

---

## F. Music library

```
songs ─< song_alternate_titles ; songs ─< song_writer_credits >─ writers ; songs ─1 song_rights
songs ─< song_arrangements ─< arrangement_sections
songs ─< song_resources (optionally per arrangement) ─ files / external URL
songs ─< song_notes ; songs ─< song_tags >─ tags ; memberships ─< member_song_preferences >─ songs
```
Usage history is **derived** from `service_songs` joined to completed services (view `v_song_usage`), not stored twice.

### `songs`
STD + TK.
| Column | Type | Notes |
|---|---|---|
| `title` | text NOT NULL | 1–200 |
| `subtitle` | text NULL | |
| `original_artist` | text NULL | PRD "artist" |
| `default_key` | text NULL | `^[A-G](#\|b)?m?$` |
| `default_bpm` | smallint NULL | CHECK 20–400 |
| `default_time_signature` | text NULL | `^[1-9][0-9]?/(1\|2\|4\|8\|16)$` |
| `language` | text DEFAULT 'en' | |
| `ccli_song_number` | text NULL | licence identifier (optional) |
| `description` | text NULL | |
| `status` | text NOT NULL DEFAULT 'active' | `draft`,`active`,`archived` |
| `search` | tsvector GENERATED | title, subtitle, artist (simple config) |
| `archived_at` | timestamptz NULL | |
| `created_by_membership_id`, `updated_by_membership_id` | uuid NULL | server-stamped |
IDX GIN `(search)`; GIN trigram `(title gin_trgm_ops)`; `(organisation_id, status)`. **DEL: A** (hard delete only via `music.delete` when never used).

### `song_alternate_titles`
STD. `song_id`, `title`, `language` NULL. UNIQUE `(song_id, lower(title))`. **DEL: H**.

### `writers`
STD + TK. `name` UNIQUE `(organisation_id, lower(name))`, `notes`. **DEL: A/H** if unreferenced.

### `song_writer_credits`
`organisation_id`, `song_id`, `writer_id`, `credit_role` CHECK IN (`lyrics`,`music`,`words_and_music`,`arrangement`,`translation`), `share_percent` numeric(5,2) NULL CHECK 0–100. PK `(song_id, writer_id, credit_role)`. **DEL: H**.

### `song_rights` (1:1; copyright and licensing)
`song_id` PK + `organisation_id`.
| Column | Notes |
|---|---|
| `rights_basis` | CHECK IN (`unknown`,`original_work`,`public_domain`,`licensed_ccli`,`licensed_other`,`permission_granted`) DEFAULT `unknown` |
| `copyright_holder`, `copyright_year` (smallint), `publisher`, `licence_reference`, `attribution_text` | |
| `permission_file_id` | NULL → files (written permission) |
| `allow_lyrics_storage`, `allow_chart_storage`, `allow_audio_storage` | boolean DEFAULT false. **Trigger-enforced gates**: lyrics/chords text in `arrangement_sections`, and `song_resources` of the corresponding type, can be written only when the flag is true (D-016). Flags are set by `music.rights.manage` holders who have an accepted `music_rights` policy (`policy_acceptances`). |
| `restrictions` | text — free-text constraints ("no recordings", "church use only") |
| `reviewed_by_membership_id`, `reviewed_at` | |
**DEL: R** (follows song). Platform does not verify rights; it records the tenant's attestation.

### `song_arrangements`
STD + TK. `song_id`, `name`, `key`, `bpm`, `time_signature` (same checks as songs), `capo` smallint NULL (0–12), `duration_seconds` integer NULL, `description`, `status` CHECK IN (`draft`,`approved`,`archived`), `is_default` boolean, `version` integer NOT NULL DEFAULT 1 (**incremented by trigger when sections or core fields change**), `approved_by_membership_id`, `approved_at`, `archived_at`.
UNIQUE `(song_id, lower(name))`; UNIQUE partial `(song_id) WHERE is_default AND archived_at IS NULL`. **DEL: A**.

### `arrangement_sections`
STD + TK. `arrangement_id`, `position` integer (DEFERRABLE UNIQUE `(arrangement_id, position)`), `section_type` CHECK IN (`intro`,`verse`,`pre_chorus`,`chorus`,`bridge`,`instrumental`,`interlude`,`vamp`,`tag`,`turnaround`,`outro`,`ending`,`other`), `label` text, `repeat_count` smallint DEFAULT 1 (CHECK 1–32), `bars` smallint NULL, `lyrics_text` text NULL, `chords_text` text NULL (ChordPro fragment — the **only** machine-transposable content; uploaded PDFs/images are never represented as transposable), `notes`. `lyrics_text`/`chords_text` gated by `song_rights` flags. **DEL: H**.

### `song_resources`
STD + TK.
| Column | Notes |
|---|---|
| `song_id`, `arrangement_id` NULL | |
| `resource_type` | CHECK IN (`lead_sheet`,`sheet_music`,`chord_chart_file`,`lyrics_file`,`audio_recording`,`audio_reference`,`video_reference`,`external_link`,`other`) |
| `title` text | |
| `file_id` NULL → files | purpose must be `song_resource` (trigger) |
| `external_url` NULL | CHECK `^https://`; **linked, never downloaded or re-hosted** by the platform |
| `external_provider` NULL | `youtube`,`spotify`,`apple_music`,`vimeo`,`other` |
| `instrument_or_part` NULL | e.g. "Trumpet", "SATB" |
| `resource_key` NULL | key the chart is written in |
| `access_scope` | CHECK IN (`all_members`,`assigned_members`,`leaders`) DEFAULT `assigned_members` — default is the **most restrictive useful** setting |
| `sort_order`, `archived_at`, `created_by_membership_id` | |
CHECK `num_nonnulls(file_id, external_url) = 1`. File-based types gated by `song_rights.allow_*_storage`. **DEL: A** (hard delete with `music.delete`; storage object purged).

### `song_notes`
STD + TK. `song_id`, `arrangement_id` NULL, `body` text, `visibility` CHECK IN (`all_members`,`music_leaders`), `author_membership_id`, `archived_at`. Internal notes: `music_leaders` requires `music.notes.view`. **DEL: A**.

### `tags`
STD + TK. `name`, `kind` CHECK IN (`theme`,`season`,`style`,`tempo`,`language`,`custom`). UNIQUE `(organisation_id, kind, lower(name))`. **DEL: H** if unused.
### `song_tags`
`organisation_id`, `song_id`, `tag_id`; PK `(song_id, tag_id)`. **DEL: H**.

### `member_song_preferences` (transposition preferences)
STD + TK. `membership_id`, `song_id`, `preferred_key` (key regex), `notes` text ≤300. UNIQUE `(membership_id, song_id)`. Readable by the member and by leaders who can assign them (`services.assign` over their team) so a lead vocalist's key is known when planning. **DEL: H**.

---

## G. Services and worship planning

```
service_types ─< service_templates ─< service_template_items / service_template_slots
event_series ─< services ─< service_programme_items ─1 service_songs ─< service_song_sections
services ─< service_assignments (slot: position + optional team + optional member)
services ─< service_notes ; services ─< service_revisions (immutable snapshots)
```

### `service_types`
STD + TK. `name`, `description`, `default_duration_minutes` integer, `default_start_local` time NULL, `campus_id` NULL, `colour` text NULL, `archived_at`. UNIQUE `(organisation_id, lower(name))`. **DEL: A**.

### `event_series` — recurrence for services *and* rehearsals
STD + TK.
| Column | Notes |
|---|---|
| `kind` | `service` \| `rehearsal` |
| `name`, `default_title` | |
| `campus_id` NULL, `team_id` NULL (rehearsals), `location_id` NULL | composite FKs |
| `service_type_id` NULL, `service_template_id` NULL | only for `kind='service'` (CHECK) |
| `timezone` | NOT NULL IANA — **recurrence is evaluated in this zone** (§13) |
| `rrule` | RFC 5545 subset (FREQ, INTERVAL, BYDAY, BYSETPOS, COUNT/UNTIL), validated by function |
| `local_start_time` | time NOT NULL (wall-clock) |
| `duration_minutes` | integer NOT NULL |
| `starts_on`, `ends_on` | date; `ends_on` NULL = open |
| `generate_ahead_days` | smallint DEFAULT 60 |
| `generated_through` | date NULL |
| `status` | `active`,`paused`,`ended` |
Generation is idempotent: occurrences are materialised as rows in `services`/`rehearsals` with UNIQUE `(series_id, occurrence_date)`. Editing "this and following" splits the series (new series row; old gets `ends_on`). **DEL: S**.

### `service_templates`
STD + TK. `service_type_id` NULL, `name`, `description`, `default_duration_minutes`, `campus_id` NULL, `version` integer, `archived_at`. **DEL: A**.
### `service_template_items`
STD + TK. `template_id`, `position` (DEFERRABLE UNIQUE per template), `item_type` (as programme items), `title`, `instructions`, `planned_duration_seconds`. **DEL: H**.
### `service_template_slots`
STD + TK. `template_id`, `position_id`, `team_id` NULL, `quantity` smallint DEFAULT 1 (CHECK 1–20), `call_offset_minutes` integer DEFAULT 60, `notes`. Applying a template **copies** items and slots into the new service; later template edits never alter existing services. **DEL: H**.

### `services`
STD + TK.
| Column | Type | Notes |
|---|---|---|
| `campus_id` | uuid NULL | NULL = multi-campus/organisation-wide service (D-029) |
| `service_type_id`, `template_id` NULL | provenance only |
| `series_id` NULL, `series_occurrence_date` date NULL | UNIQUE `(series_id, series_occurrence_date)` |
| `title` text NOT NULL | |
| `description` text NULL | |
| `starts_at`, `ends_at` | timestamptz NOT NULL; CHECK `ends_at > starts_at` |
| `timezone` | text NOT NULL | IANA of the venue; used to display "church-local" time |
| `location_id` | uuid NULL | |
| `status` | text NOT NULL DEFAULT 'draft' | `draft`,`published`,`completed`,`cancelled` |
| `published_at`, `published_by_membership_id` | | first publication |
| `last_published_revision` | integer NOT NULL DEFAULT 0 | highest `service_revisions.revision_number` |
| `has_unpublished_changes` | boolean NOT NULL DEFAULT false | set by triggers on child edits after first publication; cleared by publish |
| `rescheduled_from_starts_at` | timestamptz NULL | previous start if rescheduled |
| `cancelled_at`, `cancelled_by_membership_id`, `cancel_reason` | | CHECK `(status='cancelled') = (cancelled_at IS NOT NULL)` |
| `completed_at` | timestamptz NULL | |
| `row_version` | integer | optimistic lock |
| `created_by_membership_id` | uuid | |
IDX `(organisation_id, starts_at)`; partial `(organisation_id, starts_at) WHERE status IN ('draft','published')`; `(organisation_id, campus_id, starts_at)`.
Status machine (trigger): `draft→published→completed`; `draft|published→cancelled`; `cancelled→draft` (restore) only by `services.publish`. `completed` is immutable except notes. **DEL: H for `draft` with no revisions** (`services.delete`), otherwise **S**.

### `service_programme_items`
STD + TK + `row_version`. `service_id`, `position` integer (DEFERRABLE UNIQUE `(service_id, position)`), `item_type` CHECK IN (`song`,`prayer`,`scripture`,`announcement`,`offering`,`sermon`,`communion`,`video`,`transition`,`other`), `title`, `instructions` text, `planned_duration_seconds` integer NULL, `leader_membership_id` NULL, `responsible_team_id` NULL, `scripture_reference` text NULL.
UNIQUE `(organisation_id, service_id, id)` (target of the song FK). **DEL: H** (draft) / audit-tracked once published.

### `service_songs` (song chosen for a programme item — never rewrites the library)
STD + TK. `programme_item_id` (UNIQUE), `service_id`; FK `(organisation_id, service_id, programme_item_id) → service_programme_items(organisation_id, service_id, id)` guarantees the item belongs to this service. `song_id` → songs (**ON DELETE RESTRICT**), `arrangement_id` NULL → song_arrangements, `performance_key`, `bpm`, `time_signature`, `capo`, `lead_membership_id` NULL (song leader), `notes`, and **snapshot fields** captured at selection: `snapshot_title` text NOT NULL, `snapshot_arrangement_name`, `snapshot_arrangement_version` integer. CHECK item_type of the referenced programme item is `song` (trigger). **DEL: H** with item.

### `service_song_sections` (service-specific structure)
STD + TK. `service_song_id`, `position` (DEFERRABLE UNIQUE), `section_type` (as arrangement sections), `label`, `repeat_count`, `notes`, `source_section_id` NULL → arrangement_sections ON DELETE SET NULL. Copied from the arrangement when a song is selected; editing here **never** touches `arrangement_sections` (PRD §6.5). **DEL: H**.

### `service_assignments` (a *slot* and, optionally, who fills it)
STD + TK.
| Column | Type | Notes |
|---|---|---|
| `service_id`, `position_id` | uuid NOT NULL | |
| `slot_number` | smallint NOT NULL DEFAULT 1 | distinguishes e.g. Guitar 1 / Guitar 2 |
| `team_id` | uuid NULL | the **team accountable for filling** the slot (team-level assignment). Drives `services.assign` scoping. |
| `membership_id` | uuid NULL | the **person serving**. NULL = unfilled slot. |
| `vocal_part` | text NULL | `lead`,`soprano`,`alto`,`tenor`,`bass`,`harmony`,`backing`,`other` |
| `call_time` | timestamptz NULL | arrival time |
| `instructions` | text NULL | visible to the assignee |
| `response_status` | text NOT NULL DEFAULT 'pending' | `pending`,`accepted`,`declined`,`tentative` — **`pending` is never treated as confirmed** |
| `invited_at`, `responded_at` | timestamptz NULL | |
| `responded_by_membership_id` | uuid NULL | set when a leader answers on the member's behalf (D-026) |
| `assigned_by_membership_id` | uuid NULL | |
| `conflict_acknowledged_by_membership_id`, `conflict_acknowledged_at` | | a leader knowingly accepted a detected scheduling conflict (the free-text justification lives in `service_assignment_private`) |

* Resolves the "person vs team ambiguity" in `DOMAIN_MODEL.md` §7: **one row = one slot**; `team_id` = who is accountable, `membership_id` = who is serving; never a polymorphic assignee.
* UNIQUE `(service_id, position_id, slot_number)`; UNIQUE partial `(service_id, membership_id, position_id) WHERE membership_id IS NOT NULL`.
* CHECK `membership_id IS NOT NULL OR (response_status='pending' AND responded_at IS NULL)`; trigger clears response state when the person changes.
* IDX `(organisation_id, membership_id, service_id)` (my schedule); `(service_id)`.
* **Technical positions use the same table** — a sound engineer or slide operator is just a slot with a technical position; there is no separate "production assignment" table.
* **DEL: H** (draft). On published services a removal is a status change recorded in a revision and audit.

### `service_assignment_private` (decline reasons and conflict notes)
`assignment_id` PK → service_assignments (1:1), `organisation_id`, `membership_id` (denormalised for RLS = the assigned person), `decline_reason` text ≤300, `conflict_note` text ≤300, timestamps. Split from `service_assignments` because the roster is visible to every member who can see the service, while a decline reason ("family emergency") must only be readable by the member and by those who can assign the slot. (Same pattern as `member_unavailability_notes`; RLS cannot hide individual columns.) **DEL: H** with parent.

### `service_notes`
STD + TK. `service_id`, `programme_item_id` NULL, `team_id` NULL, `visibility` CHECK IN (`leaders`,`assigned`,`team`,`everyone`), `body`, `author_membership_id`, `pinned` boolean, `archived_at`. **DEL: A**.

### `service_revisions` (immutable plan history)
STD (no `updated_at`).
| Column | Notes |
|---|---|
| `service_id`, `revision_number` integer | UNIQUE `(service_id, revision_number)` |
| `kind` | `published`,`amended`,`rescheduled`,`cancelled`,`restored` |
| `summary` text | author's description |
| `is_material` boolean | drives member notification |
| `change_summary` jsonb | machine-computed list of changes vs previous revision (what to tell people) |
| `snapshot` jsonb NOT NULL | complete plan as published: service header, programme items, songs with **sections as then structured**, assignments (membership ids + display names at the time), key production summary |
| `snapshot_schema_version` smallint | |
| `created_by_membership_id` | |
| `notified_at` | the **only** column updatable after insert |
Created exclusively by `publish_service_revision()`. Satisfies "historical service snapshots remain understandable after catalogue edits" while keeping live tables normalised. IDX `(service_id, revision_number DESC)`. **DEL: X**.

---

## H. Rehearsals, tasks and attendance

### `rehearsals`
STD + TK + SC + `row_version`. `service_id` NULL → services, `series_id` NULL, `series_occurrence_date` NULL, `title`, `starts_at`, `ends_at` (CHECK >), `timezone`, `location_id` NULL, `status` CHECK IN (`scheduled`,`in_progress`,`completed`,`cancelled`), `agenda` text, `objectives` text, `cancelled_at`, `cancel_reason`, `created_by_membership_id`. `team_id` (SC) is the *owning* team. UNIQUE `(series_id, series_occurrence_date)`. IDX `(organisation_id, starts_at)`, `(organisation_id, service_id)`. **DEL: H** if no attendance recorded; otherwise **S**.

### `rehearsal_songs` (practice plan)
STD + TK. `rehearsal_id`, `position` (DEFERRABLE UNIQUE), `song_id` (RESTRICT), `arrangement_id` NULL, `focus_notes`, `planned_minutes` smallint. **DEL: H**.

### `rehearsal_participants` (invitation + RSVP)
STD + TK. `rehearsal_id`, `membership_id`, `required` boolean DEFAULT true, `response_status` (`pending`,`accepted`,`declined`,`tentative`), `invited_at`, `responded_at`, `responded_by_membership_id`. UNIQUE `(rehearsal_id, membership_id)`. Attendance is **not** here (see `attendance_records`). **DEL: H**.

### `rehearsal_notes`
STD + TK. `rehearsal_id`, `song_id` NULL, `arrangement_section_id` NULL → arrangement_sections, `kind` CHECK IN (`note`,`issue`,`decision`,`follow_up`), `body`, `status` CHECK IN (`open`,`resolved`) (issues), `resolved_by_membership_id`, `resolved_at`, `visibility` CHECK IN (`participants`,`leaders`), `author_membership_id`. **DEL: A**.

### `tasks` (preparation, practice, action items, follow-ups)
STD + TK + SC. One table serves PRD §6.8 practice tasks, §6.10 action items and service preparation checklists.
| Column | Notes |
|---|---|
| `kind` | `preparation`,`practice`,`action_item`,`follow_up`,`other` |
| `title`, `description` | |
| `due_at` | timestamptz NULL |
| `priority` | `low`,`normal`,`high` |
| `status` | `open`,`closed`,`cancelled` (task-level) |
| `service_id`, `rehearsal_id`, `meeting_id`, `song_id` | NULL; CHECK `num_nonnulls(service_id, rehearsal_id, meeting_id) <= 1`. `meeting_id` FK added in the Phase-5 migration. |
| `created_by_membership_id`, `closed_at` | |
IDX `(organisation_id, due_at) WHERE status='open'`. **DEL: A** (cancel) / H own drafts.

### `task_assignees` (per-person completion)
STD + TK. `task_id`, `membership_id`, `status` CHECK IN (`todo`,`in_progress`,`done`,`blocked`,`cancelled`), `completed_at`, `completion_note` ≤500. UNIQUE `(task_id, membership_id)`. IDX `(membership_id, status)`. Assignee can update **only** their own `status/completed_at/completion_note` (via RPC; direct UPDATE is restricted to `tasks.manage`). **DEL: H** (unassign).

### `attendance_records` (unified for services, rehearsals, meetings)
STD + TK.
| Column | Notes |
|---|---|
| `membership_id` | the person |
| `service_id` / `rehearsal_id` / `meeting_id` | exactly one (CHECK `num_nonnulls = 1`); `meeting_id` FK added in Phase 5 |
| `status` | `present`,`late`,`absent`,`excused`,`not_recorded` |
| `arrived_at` | timestamptz NULL (punctuality) |
| `note` | text ≤300, restricted |
| `recorded_by_membership_id`, `recorded_at` | server-stamped |
| `corrected_at` | set when changed after first record; the **full correction history is in `audit_events`** (`changes` = old/new status) |
UNIQUE partial per event: `(service_id, membership_id)`, `(rehearsal_id, membership_id)`, `(meeting_id, membership_id)`. `excused` ≠ `absent` so approved leave/illness never count against a member (PRD §6.13). No `excuse_reason` column — health information is deliberately not collected here. Answers the open question in `DOMAIN_MODEL.md` §15: **attendance is unified; invitation/RSVP stays per event type**. **DEL: R** (retention per `attendance_retention_months`).

---

## I. Meetings

### `meetings`
STD + TK + SC + `row_version`. `title`, `description`, `starts_at`, `ends_at`, `timezone`, `location_id` NULL, `online_url` NULL (`^https://`), `status` (`scheduled`,`in_progress`,`completed`,`cancelled`), `minutes_visibility` CHECK IN (`participants`,`leaders`) DEFAULT `participants`, `chair_membership_id`, `secretary_membership_id` NULL, `service_id` NULL → services, `created_by_membership_id`. IDX `(organisation_id, starts_at)`. **DEL: H** (no minutes) / **S**.
### `meeting_participants`
STD + TK. `meeting_id`, `membership_id`, `role` CHECK IN (`chair`,`secretary`,`attendee`,`observer`), `required` boolean, `response_status`, `responded_at`. UNIQUE `(meeting_id, membership_id)`. **DEL: H**.
### `meeting_agenda_items`
STD + TK. `meeting_id`, `position` (DEFERRABLE UNIQUE), `title`, `description`, `owner_membership_id` NULL, `planned_minutes`, `status` (`pending`,`discussed`,`deferred`). **DEL: H**.
### `meeting_minutes`
STD + TK + `row_version`. `meeting_id` UNIQUE, `body` text, `status` (`draft`,`approved`), `author_membership_id`, `approved_by_membership_id`, `approved_at`. Approved minutes are immutable except via an amendment RPC that audits. **DEL: R**.
### `meeting_decisions`
STD + TK. `meeting_id`, `agenda_item_id` NULL, `decision_text`, `decided_at`, `recorded_by_membership_id`. **DEL: R**.

Action items are rows in `tasks` (`kind='action_item'`, `meeting_id` set), with owners in `task_assignees`.

---

## J. Communication and notifications

```
announcements ─< announcement_receipts
conversations (channel | group | direct) ─< conversation_participants
conversations ─< messages ─< message_attachments >─ files ; messages ─< message_reactions ; messages ─< message_reports
notifications ─< notification_deliveries ; memberships ─< notification_preferences ; profiles ─< push_subscriptions
```

### `announcements`
STD + TK + SC. `title`, `body` text (≤10 000), `priority` CHECK IN (`normal`,`important`,`urgent`), `status` CHECK IN (`draft`,`scheduled`,`published`,`archived`), `publish_at`, `published_at`, `expires_at`, `pinned` boolean, `requires_acknowledgement` boolean, `author_membership_id`. **Audience = SC columns**: all NULL ⇒ whole organisation; otherwise members of that campus (home campus or a team on it), ministry, department or team. IDX `(organisation_id, status, publish_at DESC)`. **DEL: A**.
### `announcement_receipts`
STD (no `updated_at`). `announcement_id`, `membership_id`, `read_at`, `acknowledged_at`. UNIQUE `(announcement_id, membership_id)`. Own rows only; authors/`announcements.publish` see aggregate counts via RPC (not who failed to read). **DEL: H**.

### `conversations` — channels, group chats, direct messages in one table
STD + TK + SC.
| Column | Notes |
|---|---|
| `kind` | `channel`,`group`,`direct` |
| `name`, `description` | NULL for `direct` |
| `channel_kind` | `announcement`,`team`,`department`,`service`,`rehearsal`,`topic` — channels only |
| `visibility` | channels only: `organisation` (all active members), `scope` (members of the SC scope), `event` (participants of the linked service/rehearsal), `private` (explicit participants only) |
| `service_id`, `rehearsal_id` NULL | link for `event` channels (exactly one when `visibility='event'`) |
| `posting` | `everyone`,`moderators_only` (announcement-style channels) |
| `direct_key` | text NULL — for `direct`: the two membership ids sorted and joined; UNIQUE `(organisation_id, direct_key)` prevents duplicate 1:1 threads |
| `created_by_membership_id`, `archived_at` | |
| `last_message_at` | timestamptz (denormalised by trigger for inbox ordering) |
CHECKs: `direct` ⇒ `direct_key NOT NULL AND name IS NULL AND visibility IS NULL`; `channel` ⇒ `channel_kind` and `visibility` NOT NULL; `group` ⇒ visibility NULL; no cross-tenant conversations by construction (single `organisation_id`). **DEL: A** (channels), **R** (direct/group).
IDX `(organisation_id, kind, archived_at)`, `(organisation_id, last_message_at DESC)`.

### `conversation_participants`
STD + TK. `conversation_id`, `membership_id`, `role` CHECK IN (`member`,`moderator`,`owner`), `can_post` boolean DEFAULT true, `joined_at`, `left_at` NULL, `added_by_membership_id`, `last_read_message_id` NULL → messages ON DELETE SET NULL, `last_read_at`, `notification_level` CHECK IN (`all`,`mentions`,`none`), `muted_until`. UNIQUE `(conversation_id, membership_id)`. IDX `(membership_id, conversation_id) WHERE left_at IS NULL`.
* For `direct`/`group`/`private` channels these rows **are** the access list.
* For `organisation`/`scope`/`event` channels access is *computed*; rows exist only to store the member's read marker and mute settings (created on first open) and never grant access by themselves.
* **Read receipts** are a per-participant high-water mark (`last_read_message_id`), not a row per message per reader. **DEL: H** (leave) → `left_at`.

### `messages`
STD + TK. `conversation_id`; `sender_membership_id`; `kind` CHECK IN (`text`,`voice_note`,`file`,`system`); `body` text NULL (≤8000; NULL when tombstoned); `body_format` (`plain`,`markdown`); `parent_message_id` NULL — FK `(organisation_id, conversation_id, parent_message_id) → messages(organisation_id, conversation_id, id)` (replies stay in the same conversation); `mentioned_membership_ids` uuid[] (validated by trigger to be participants/accessors; used for notification fan-out only); `client_message_id` uuid NOT NULL (idempotent retries: UNIQUE `(conversation_id, sender_membership_id, client_message_id)`); `edited_at`; `deleted_at`, `deleted_by_membership_id`, `deletion_kind` (`sender`,`moderator`,`retention`); `moderation_status` (`visible`,`hidden`,`removed`); `pinned_at`, `pinned_by_membership_id`; `search` tsvector GENERATED (body).
UNIQUE `(organisation_id, conversation_id, id)`. IDX `(conversation_id, created_at DESC, id DESC)` (keyset pagination); GIN `(search)`; partial `(conversation_id) WHERE pinned_at IS NOT NULL`. Partitioning deferred until measured (ARCHITECTURE §9). **DEL: T** — body/attachments cleared, row kept so threads and read markers stay coherent; physical purge by retention job.

### `message_attachments`
STD + TK. `message_id`, `file_id`, `kind` (`image`,`audio`,`document`,`video`,`other`), `position` smallint, `duration_seconds` NULL (voice notes). UNIQUE `(message_id, file_id)`. File purpose must be `message_attachment` or `voice_note` and uploaded by the sender (trigger). **DEL: T** with message.

### `message_reactions`
`organisation_id`, `message_id`, `membership_id`, `emoji` text (1–16 chars), `created_at`. PK `(message_id, membership_id, emoji)`. Justified by PRD §6.9; cheap, own-row writes. **DEL: H** (own).

### `message_reports`
STD + TK. `message_id`, `reporter_membership_id`, `reason_category` CHECK IN (`harassment`,`inappropriate`,`spam`,`copyright`,`privacy`,`other`), `details` ≤1000, `body_snapshot` text (copy of the reported content at report time — the *only* way a reviewer sees content from a private conversation), `status` CHECK IN (`open`,`reviewing`,`actioned`,`dismissed`), `handled_by_membership_id`, `handled_at`, `resolution_note`. UNIQUE `(message_id, reporter_membership_id)`. **DEL: R**.

### `notifications`
STD (`updated_at` unused).
| Column | Notes |
|---|---|
| `recipient_membership_id` | → memberships (per-church) |
| `category` | `assignment`,`service_change`,`rehearsal`,`announcement`,`message`,`mention`,`meeting`,`task`,`invitation`,`onboarding`,`system` |
| `event_type` | text, e.g. `service.published` |
| `title` text ≤140, `body` text ≤300 | **must not contain sensitive content or private message bodies** |
| `resource_type` text, `resource_id` uuid | deep-link pointer; deliberately **not** a foreign key (polymorphic link, validated by the app; RLS never trusts it) |
| `actor_membership_id` NULL | |
| `dedupe_key` text NULL | UNIQUE `(recipient_membership_id, dedupe_key)` |
| `read_at`, `archived_at` | |
IDX `(recipient_membership_id, created_at DESC) WHERE archived_at IS NULL`; `(recipient_membership_id) WHERE read_at IS NULL`. Created only by triggers/RPCs/workers. **DEL: H** (own) + 90-day purge of read/archived.

### `notification_preferences`
STD + TK. `membership_id`, `category`, `channel` (`in_app`,`email`,`push`), `enabled` boolean. UNIQUE `(membership_id, category, channel)`. Critical categories (`assignment`, `service_change` when material, `invitation`) cannot disable `in_app`. **DEL: H**.

### `notification_deliveries` (service-role only)
STD + TK. `notification_id`, `channel` (`email`,`push`), `status` CHECK IN (`queued`,`sending`,`sent`,`failed`,`suppressed`,`bounced`), `attempt_count` smallint, `next_attempt_at`, `last_error` text ≤300 (sanitised, no addresses/tokens), `provider_message_id`, `sent_at`. IDX `(status, next_attempt_at) WHERE status IN ('queued','failed')`. No client access. **DEL: R** (90 days).

### `push_subscriptions` (global, per user device)
`id` uuid PK, `user_id` → profiles, `endpoint` text UNIQUE, `p256dh`, `auth` (encrypted at rest with pgsodium/Vault key per D-028), `user_agent_family`, `created_at`, `last_seen_at`, `revoked_at`. Own rows only. **DEL: H**.

---

## K. Technical production

```
equipment_items ─< equipment_allocations >─ services | rehearsals
services ─1 production_plans (is_template=false)   ;  production_plans (is_template=true) = reusable template
production_plans ─< stage_plots ─< stage_plot_elements
production_plans ─< input_list_items, monitor_requirements, production_cues, production_checklist_items,
                    production_requirements, production_notes, production_plan_revisions
```
Production **people** are `service_assignments` slots with technical positions — there is no parallel assignment table.

### `equipment_items`
STD + TK. `campus_id` NULL, `team_id` NULL (owning team; SC derived), `location_id` NULL (where it lives), `name`, `category` CHECK IN (`audio`,`lighting`,`video`,`projection`,`instrument`,`backline`,`cabling`,`power`,`staging`,`other`), `manufacturer`, `model`, `serial_number`, `asset_tag` (UNIQUE per org when not null), `quantity` integer DEFAULT 1 (CHECK ≥1), `status` CHECK IN (`available`,`in_service`,`maintenance`,`retired`,`lost`), `purchase_date`, `warranty_expires_on`, `notes`, `archived_at`. **DEL: A**.

### `equipment_allocations`
STD + TK. `equipment_item_id`; exactly one of `service_id`, `rehearsal_id` (CHECK); `quantity` integer DEFAULT 1; `starts_at`, `ends_at` (copied from the event, re-synced by trigger on reschedule); `status` CHECK IN (`reserved`,`checked_out`,`returned`,`cancelled`); `allocated_to_membership_id` NULL; `checked_out_at`, `checked_out_by_membership_id`, `returned_at`, `returned_by_membership_id`; `is_exclusive` boolean (trigger: item `quantity=1`); `notes`.
`EXCLUDE USING gist (equipment_item_id WITH =, tstzrange(starts_at, ends_at) WITH &&) WHERE (is_exclusive AND status IN ('reserved','checked_out'))` — requires `btree_gist`; prevents double-booking a single physical item. Multi-quantity items are checked by trigger (sum of overlapping quantity ≤ item quantity). **DEL: A**(cancel)/H.

### `production_plans`
STD + TK + SC + `row_version`. SC: `campus_id` copied from the service, `team_id` = the owning production team (e.g. Sound) so Team/Department-scoped Production Leads match. `service_id` NULL (UNIQUE when not null), `is_template` boolean, `name` (templates), `based_on_template_id` NULL → production_plans, `status` CHECK IN (`draft`,`ready`,`locked`,`archived`), `readiness` CHECK IN (`not_started`,`in_progress`,`ready`,`issues`), `readiness_notes`, `load_in_at`, `soundcheck_at` timestamptz NULL, `lead_membership_id` NULL, `revision` integer DEFAULT 0. CHECK `is_template = (service_id IS NULL)`; templates require `name`. A new service plan **copies** a template (elements, inputs, checklist) so each service keeps its own configuration. **DEL: A**.
### `production_plan_revisions`
STD (no `updated_at`). `production_plan_id`, `revision_number`, `summary`, `snapshot` jsonb NOT NULL, `created_by_membership_id`. UNIQUE `(production_plan_id, revision_number)`. Created at `ready`/`locked` transitions and on post-lock edits. Answers "how are stage layouts versioned": normalised live rows + immutable snapshots. **DEL: X**.
### `stage_plots`
STD + TK + `row_version`. `production_plan_id`, `name`, `width_m` numeric(5,2), `depth_m` numeric(5,2), `background_file_id` NULL → files, `is_primary` boolean (UNIQUE partial per plan), `notes`. **DEL: H**.
### `stage_plot_elements`
STD + TK. `stage_plot_id`, `label`, `element_type` CHECK IN (`performer`,`instrument`,`monitor_wedge`,`iem_pack`,`di_box`,`microphone`,`amp`,`riser`,`drum_kit`,`keyboard`,`stand`,`cable_run`,`other`), `x_pct`, `y_pct` numeric(5,2) CHECK 0–100, `width_pct`, `height_pct` numeric(5,2) NULL, `rotation_deg` smallint CHECK 0–359, `z_index` smallint, `position_id` NULL, `membership_id` NULL, `colour`, `notes`. Normalised so elements can be linked to people/positions and queried (not a canvas blob). **DEL: H**.
### `input_list_items`
STD + TK. `production_plan_id`, `channel_number` smallint CHECK 1–256 (DEFERRABLE UNIQUE `(production_plan_id, channel_number)`), `source_label`, `position_id` NULL, `stage_plot_element_id` NULL, `mic_or_di` text, `connection_type` CHECK IN (`xlr`,`di`,`line`,`usb`,`dante`,`other`), `stand_type`, `phantom_power` boolean, `gain_notes`, `monitor_sends`, `foh_notes`. **DEL: H**.
### `monitor_requirements`
STD + TK. `production_plan_id`, `position_id` NULL, `membership_id` NULL, `monitor_type` CHECK IN (`wedge`,`iem_stereo`,`iem_mono`,`sidefill`,`none`), `mix_number` smallint, `needs` text. **DEL: H**.
### `production_cues`
STD + TK. `production_plan_id`, `position` integer (DEFERRABLE UNIQUE per plan), `cue_type` CHECK IN (`lighting`,`projection`,`media`,`livestream`,`audio`,`stage`,`other`), `programme_item_id` NULL (trigger: must belong to the plan's service), `trigger_description`, `instructions`, `offset_seconds` integer NULL, `assigned_membership_id` NULL, `status` (`planned`,`rehearsed`,`ready`). **DEL: H**.
### `production_checklist_items`
STD + TK. `production_plan_id`, `phase` CHECK IN (`load_in`,`setup`,`soundcheck`,`pre_service`,`during`,`strike`), `position` integer, `title`, `equipment_item_id` NULL, `assigned_membership_id` NULL, `status` (`todo`,`done`,`skipped`,`blocked`), `completed_at`, `completed_by_membership_id`, `notes`. Kept separate from `tasks` because it is ordered, phase-grouped, templated and copied per service. **DEL: H**.
### `production_requirements` (service-specific needs requested of production)
STD + TK. `production_plan_id`, `category` CHECK IN (`audio`,`lighting`,`projection`,`livestream`,`stage`,`media`,`other`), `requirement` text, `priority` (`low`,`normal`,`high`), `status` CHECK IN (`requested`,`acknowledged`,`confirmed`,`unavailable`,`done`), `requested_by_membership_id`, `assigned_to_membership_id` NULL, `response_note`. A worship leader raises "need a second keyboard DI"; production answers. **DEL: H**.
### `production_notes`
STD + TK. `production_plan_id`, `category` text, `visibility` CHECK IN (`production_team`,`all_assigned`,`leaders`), `body`, `author_membership_id`, `archived_at`. **DEL: A**.

---

## L. Reporting and audit

### `audit_events` (append-only, partitioned)
```
id               bigint GENERATED ALWAYS AS IDENTITY
occurred_at      timestamptz NOT NULL DEFAULT now()
organisation_id  uuid NULL           -- NO foreign key: history must outlive tenant purge; NULL = platform event
actor_user_id    uuid NULL           -- no FK (same reason)
actor_membership_id uuid NULL
actor_type       text NOT NULL       -- user | system | service | platform_support | platform_admin
action           text NOT NULL       -- dotted verb: membership.suspended, role.assigned, service.published …
resource_type    text NULL
resource_id      uuid NULL
severity         text NOT NULL DEFAULT 'info'   -- info | notice | security
changes          jsonb NULL          -- allow-listed {column: {old,new}}; never bodies, tokens, notes, contact data
metadata         jsonb NULL          -- safe context (counts, ids, reason codes)
request_id       text NULL
client_ip_hash   bytea NULL          -- keyed HMAC of IP, not the raw address (D-031)
PRIMARY KEY (id, occurred_at)
PARTITION BY RANGE (occurred_at)     -- monthly partitions
```
* IDX `(organisation_id, occurred_at DESC)`; `(organisation_id, resource_type, resource_id, occurred_at DESC)`; `(organisation_id, actor_membership_id, occurred_at DESC)`; BRIN `(occurred_at)`.
* **Partitions must exist before they are needed.** An insert with no matching partition *fails* (verified in S-7 extras), and audit writes happen inside business transactions — a missing partition would block membership changes. Mitigation: a scheduled job creates partitions ≥3 months ahead, a `DEFAULT` partition catches stragglers, and an alert fires if the default partition is non-empty.
* Inserted only by `private.write_audit()` (called from triggers and RPCs). `INSERT/UPDATE/DELETE/TRUNCATE` revoked from all client roles; a trigger raises on UPDATE/DELETE. Retention = drop whole partitions. **DEL: X**.
* What is audited, retained and how it is protected: [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) §10.

### `report_exports`
STD + TK. `requested_by_membership_id`, `report_kind` text, `parameters` jsonb (validated server-side; no personal data), `scope_*` (SC columns), `status` CHECK IN (`queued`,`running`,`ready`,`failed`,`expired`), `file_id` NULL → files (`purpose='report_export'`), `row_count`, `expires_at` (default +7 days), `download_count`. Every export creates an audit event. **DEL: R** (file and row expire).

### Reporting views (no storage; `security_invoker = true`)
`v_attendance_summary`, `v_service_participation`, `v_rehearsal_participation`, `v_task_completion`, `v_song_usage`, `v_org_activity`, `v_team_leaders`, `v_scheduling_conflicts`. Because they are *security-invoker*, the base-table RLS decides what each caller can see; metrics over other people only return rows the caller is permitted to read (`attendance.view`, `reports.view`…). Materialised rollups (if needed for scale) are populated by a worker into RLS-protected tables, **never** exposed as materialised views (they bypass RLS). See ARCHITECTURE §10.

---

## 13. Timestamps and timezone handling

1. **Instants** (`starts_at`, `created_at`, `sent_at`…) are `timestamptz`, stored in UTC by Postgres, displayed by the client.
2. **Every event table also stores `timezone`** (IANA name, e.g. `Africa/Johannesburg`) — the venue's zone, so "church-local time" is always recoverable and shown beside the viewer's local time (PRD §10/`TECHNICAL_ARCHITECTURE.md` §11).
3. **Validation (verified in spike S-7).** `AT TIME ZONE` also accepts abbreviations (`EST`), POSIX strings (`UTC+3`) and odd names (`Factory`), so "does not raise" is **not** validation. `private.is_valid_timezone(text)` must require `name IN (SELECT name FROM pg_timezone_names) AND (name = 'UTC' OR name ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$')` and reject the `Etc/`, `posix/` and `right/` prefixes. It is used in CHECK constraints and re-validated in the RPCs. App-side Zod validation uses `Intl.supportedValuesOf('timeZone')`.
4. **Recurrence** stores *wall-clock intent*: `local_start_time` + `timezone` + `rrule`. Each occurrence's UTC instant is computed as `(occurrence_date + local_start_time) AT TIME ZONE timezone`, so a 10:00 service stays at 10:00 local across DST changes (non-existent and ambiguous local times follow PostgreSQL's behaviour, pinned by golden tests: a local time inside a spring-forward gap is shifted forward by the gap length — 01:30 on the London change day becomes 02:30 BST; an ambiguous local time in an autumn overlap resolves to the **later, standard-time** instance). Generated rows are normal rows and may then be edited individually.
5. **Civil values** (`date`, `time`) are used for things with no instant (`left_on`, `series starts_on`, `local_start_time`).
6. **Ranges** use half-open semantics `[starts_at, ends_at)`; CHECK `ends_at > starts_at`.
7. **`updated_at`** is maintained by a `BEFORE UPDATE` trigger (`private.set_updated_at`), never by the client. **Actor columns** (`created_by_*`, `recorded_by_*`) are stamped by trigger from `auth.uid()` and cannot be supplied by clients.
8. **Clock** — `now()` (transaction start) for row stamps; `clock_timestamp()` for `messages.created_at` ordering inside a transaction.

## 14. Soft delete versus permanent delete

| Class | Policy | Examples |
|---|---|---|
| **Identity & lifecycle rows** | Never hard-deleted; state changes recorded | `memberships`, `membership_role_assignments` (revoked), `invitations` (purged only after 90 days) |
| **Catalogue / reference data** | Archive (`archived_at`); hidden by default; history keeps referencing | `songs`, `arrangements`, `positions`, `skills`, `teams`, `campuses`, `equipment_items` |
| **Published history** | Immutable | `service_revisions`, `production_plan_revisions`, `audit_events`, `membership_status_events`, `policy_acceptances` |
| **Drafts & working data** | Hard delete allowed to authorised users | draft services, programme items, template items, checklist items, stage elements |
| **Personal convenience data** | Hard delete by owner; purged on removal/erasure | availability, notes, contacts, preferences |
| **Messages** | Tombstone (blank body & attachments), physical purge by retention job | `messages`, `message_attachments` |
| **Ephemeral** | Auto-purged | read/archived `notifications` (90 d), `notification_deliveries` (90 d), terminal `invitations` (90 d), `report_exports` (7 d) |

**Cascades** delete children only where the child has no independent meaning (sections of an arrangement, items of a draft service). A cascade runs with the privileges of the FK trigger and **ignores RLS** — therefore the parent's DELETE policy must be at least as strict as the strictest child policy (verified by tests in [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md) §3.7). Foreign keys to history-bearing parents (`songs`, `positions`, `memberships`) are `ON DELETE RESTRICT`.

**Erasure (POPIA right to deletion) = anonymise, don't orphan.** Profile PII is cleared, `memberships.user_id` is set NULL with `display_name='Former member'`, contacts/notes/availability are deleted, and messages/attendance remain attached to the anonymised membership so shared church records stay coherent. Retention windows are *proposals* pending legal review (open decision D-017/D-033).

## 15. Indexing strategy

1. **Tenant-leading composite indexes.** Almost every query is `WHERE organisation_id = $1 AND …`; indexes lead with `organisation_id` followed by the filter/sort column (`(organisation_id, starts_at)`).
2. **Every foreign key is indexed.** Composite FKs `(organisation_id, parent_id)` get an index starting `(parent_id, …)` or `(organisation_id, parent_id)`; this also keeps ON DELETE checks and RLS subqueries cheap.
3. **RLS support indexes** (highest priority — they run on every statement): `memberships (user_id, organisation_id) WHERE status='active'`; `membership_role_assignments (membership_id) WHERE revoked_at IS NULL`; `role_permissions (role_id, permission_key)`; `team_memberships (membership_id, team_id) WHERE status='active'`; `conversation_participants (membership_id, conversation_id) WHERE left_at IS NULL`; `service_assignments (organisation_id, membership_id, service_id)`; `rehearsal_participants (membership_id, rehearsal_id)`; `meeting_participants (membership_id, meeting_id)`; `task_assignees (membership_id, status)`.
4. **Partial indexes** for active subsets (`WHERE archived_at IS NULL`, `WHERE status='open'`, `WHERE read_at IS NULL`).
5. **Search:** GIN on `tsvector` (songs, messages); `pg_trgm` GIN on `songs.title` and `members` display names for type-ahead.
6. **Time ranges:** GiST for unavailability overlap and equipment exclusion; BRIN on append-only time columns (`audit_events.occurred_at`).
7. **Keyset pagination** everywhere (`(created_at, id) < ($1,$2)`), never OFFSET on large tables.
8. **Index discipline:** add indexes for *observed* query patterns (`pg_stat_statements`), review unused indexes quarterly.

## 16. Tenant-consistency triggers (summary)

| Trigger function | Applied to | Purpose |
|---|---|---|
| `private.set_updated_at` | all tables with `updated_at` | server-owned timestamp |
| `private.forbid_org_change` | all tenant tables | `organisation_id` immutable on UPDATE |
| `private.stamp_actor` | tables with `created_by_*` / `recorded_by_*` | derive actor membership from `auth.uid()` + row org |
| `private.fill_scope_ancestors` | SC tables, `teams`, `departments`, `ministries` | derive/validate ancestor ids |
| `private.bump_row_version` | `row_version` tables | optimistic locking |
| `private.check_active_membership` | `service_assignments`, `rehearsal_participants`, `meeting_participants`, `task_assignees`, `conversation_participants`, `team_memberships` | the referenced membership must be `active` when the row is created/changed |
| `private.guard_role_definition` | `role_permissions`, `roles` | role-definition ceiling; no `org.ownership.manage` in custom roles |
| `private.check_role_org` | `membership_role_assignments`, `invitations` | role is global or same organisation; scope allowed by role |
| `private.guard_membership_status` | `memberships` | legal transitions, last-owner protection |
| `private.guard_service_status` | `services` | legal transitions; immutability of completed |
| `private.mark_service_dirty` | service child tables | sets `has_unpublished_changes` |
| `private.gate_rights_content` | `arrangement_sections`, `song_resources` | requires `song_rights.allow_*` flags |
| `private.audit_row_change(allow_list)` | sensitive tables (list in ARCHITECTURE §10) | field-level audit with allow-listed columns |
| `private.block_mutation` | append-only tables | raise on UPDATE/DELETE |

## 17. Cross-checks performed on this schema

* **Circular dependencies:** none. The two apparent cycles were removed by design — `files.uploaded_by_user_id` references `profiles` (not `memberships`), and `service_types` no longer points at templates (templates point at types). Forward references (`tasks.meeting_id`, `attendance_records.meeting_id`, `file_attachments.meeting_id/production_plan_id`) are added with `ALTER TABLE` in the migration that creates the target ([DATABASE_MIGRATION_PLAN.md](DATABASE_MIGRATION_PLAN.md) §3).
* **Tenant ownership:** every table in groups A (except `profiles`, `organisations`), B, D, E, F, G, H, I, J (except `push_subscriptions`), K, L carries `organisation_id`; the exceptions are enumerated in §0.4.
* **Requirement coverage:** traced in [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) §14.
