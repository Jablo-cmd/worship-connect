# Worship Connect — Row Level Security Specification

**Version:** 0.1 (draft for review) | **Status:** Proposed — specification only. **No policy described here is implemented or tested.** Per `SECURITY_AND_PRIVACY.md` and `TECHNICAL_ARCHITECTURE.md` §17, no control may be described as implemented until its tests pass.

Companion documents: [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) · [PERMISSIONS_MATRIX.md](PERMISSIONS_MATRIX.md) · [DATABASE_ARCHITECTURE.md](DATABASE_ARCHITECTURE.md) · [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md)

All SQL below is **illustrative specification** to be turned into reviewed migrations ([DATABASE_MIGRATION_PLAN.md](DATABASE_MIGRATION_PLAN.md)).

---

## 1. Guarantees this specification must deliver

1. **Tenant isolation at the database.** A signed-in user can read or write a row only if they hold an *active* membership of that row's organisation and the required permission over the row's scope — evaluated by Postgres on every statement, independent of the frontend, Next.js server code, or the client-supplied `organisation_id`.
2. **Default deny.** Every table has RLS enabled; a table or operation with no policy is inaccessible to client roles.
3. **Membership state is live.** Suspension, removal, role revocation, role expiry and organisation suspension take effect on the *next query*, because nothing about membership or roles is cached in the JWT.
4. **No role or tenant claim is trusted from the client.** Identity comes from `auth.uid()` (the verified JWT subject). Organisation, membership, role and scope are always *derived from rows in the database*.
5. **Private stays private.** Direct and group conversations and private channels are readable only by their participants — not by owners, admins, moderators, or platform staff.
6. **Files and realtime follow the same rules** as the rows they belong to.

## 2. Principles

| # | Principle |
|---|---|
| 1 | RLS is the **last line of defence**, not the only one: composite tenant foreign keys, immutable `organisation_id`, server-side validation and RPC checks are layered underneath (ARCHITECTURE §4). |
| 2 | Policies are **small, uniform and generated from patterns** (§5). Bespoke policies need a written justification and a dedicated test. |
| 3 | Policies call a **small library of audited helper functions** (§4); they never embed role names. |
| 4 | Wrap per-statement constants in `(select …)` so the planner evaluates them once (`(select auth.uid())`, `(select private.my_org_array())`). |
| 5 | Every column used by a policy is indexed. |
| 6 | **Never weaken a policy to make a feature work** (`TECHNICAL_ARCHITECTURE.md` §17.2). If a feature needs more access, add a narrow `SECURITY DEFINER` function with its own checks and tests. |
| 7 | `WITH CHECK` on every INSERT/UPDATE policy so a caller cannot *move* a row into a tenant, scope or state they do not control. |
| 8 | Direct DML is exposed only where RLS can express the rule fully. Anything needing multi-row invariants, secrets, or cross-table authority is **RPC-only** (§11). |

---

## 3. Postgres-level privileges (before any policy)

```sql
-- Run once per environment, by migration, as the migration owner (postgres).

-- 3.1 anon gets NOTHING in public. Unauthenticated users never touch tenant tables.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon, public;

-- 3.2 New objects are born without client privileges (Supabase would otherwise
--     auto-grant to anon/authenticated).
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;

-- 3.3 private and platform schemas are not exposed by the Data API and have no anon access.
revoke all on schema private  from public, anon;
grant  usage on schema private to authenticated;      -- required so policies can call helpers
revoke all on schema platform from public, anon, authenticated;
```

Each migration then **explicitly grants** the minimum to `authenticated`:

```sql
-- Table with full CRUD under RLS
grant select, insert, update, delete on public.songs to authenticated;
-- RPC-only table: read access only; writes go through functions
grant select on public.memberships to authenticated;
-- Column-restricted update (RLS cannot restrict columns; privileges can)
grant update (name, timezone, country_code, contact_email, contact_phone, website_url)
  on public.organisations to authenticated;
-- Secrets live in server-only tables with NO grants (e.g. invitation_tokens); a column-level
-- REVOKE is ineffective while a table-level grant exists (spike S-5).
```

**Result:** `anon` can do nothing; `authenticated` can do only what a grant *and* a policy both allow; `service_role` bypasses RLS and is confined by §12.

---

## 4. Helper function library (`private` schema)

### 4.1 Rules for every `SECURITY DEFINER` function (normative)

1. Lives in `private` (not exposed by the API) **unless** it is an intentional RPC, in which case it lives in `public` and is listed in §11.
2. Declared `SET search_path = ''` and **fully schema-qualifies every object** (`public.memberships`, `auth.uid()`), preventing search-path hijack.
3. `STABLE` when read-only (allows planner caching); never `VOLATILE` unless it writes.
4. Takes **no caller-identity parameter** (`p_user_id` is forbidden). Identity is read inside the function from `auth.uid()`.
5. Treats every parameter as hostile: tenant is derived from the target row, never from a client-supplied organisation id.
6. No dynamic SQL (`EXECUTE`) unless unavoidable and then only with `format('%I', …)`/`quote_literal`.
7. `REVOKE EXECUTE … FROM PUBLIC, anon`; `GRANT EXECUTE … TO authenticated` **only** for helpers that policies call (policies run with the caller's privileges, so `authenticated` needs execute) and for intentional RPCs. Internal-only helpers (`write_audit`, trigger functions) are granted to no client role.
8. Returns the minimum (boolean / id), never row sets of tenant data from a helper used in policies.
9. Raises generic errors for authorisation failures (`errcode 42501`) so error text does not reveal whether a row exists.
10. Reviewed in PR with the checklist in §13; covered by tests in [DATABASE_TESTING_STRATEGY.md](DATABASE_TESTING_STRATEGY.md) §3.6; scanned by Supabase advisors / `splinter` (`function_search_path_mutable`, `anon_security_definer_function_executable`).

11. **Trigger functions** that must read other tables to validate a write (`check_role_org`, `gate_rights_content`, status/scope guards, `check_active_membership`) are also `SECURITY DEFINER` under rules 1–10, so validation never depends on what the *caller* happens to be allowed to see.

A `SECURITY DEFINER` function bypasses RLS on the tables it reads — that is why helpers read only `memberships`, `organisations`, role-assignment and role tables and never return tenant content.

### 4.2 Core helpers

```sql
-- Organisations the caller is an ACTIVE member of (active org), as a SET. Use for joins/RPCs.
create or replace function private.my_org_ids()
returns setof uuid language sql stable security definer set search_path = '' as $$
  select m.organisation_id
  from public.memberships m
  join public.organisations o on o.id = m.organisation_id
  where m.user_id = (select auth.uid())
    and m.status  = 'active'
    and o.status  = 'active'
$$;

-- Same, as an ARRAY. THIS is what table policies use: `organisation_id = ANY ((select private.my_org_array())::uuid[])`.
-- Spike S-4: the `IN (SELECT setof_fn())` form cannot become an index condition, so an *unfiltered* query for a
-- multi-organisation user fell back to a sequential scan (240 ms on 1 M rows); the array form uses the index (30 ms).
create or replace function private.my_org_array()
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(m.organisation_id), '{}')
  from public.memberships m
  join public.organisations o on o.id = m.organisation_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and o.status = 'active'
$$;

create or replace function private.is_member(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.memberships m
    join public.organisations o on o.id = m.organisation_id
    where m.organisation_id = p_org
      and m.user_id = (select auth.uid())
      and m.status = 'active' and o.status = 'active')
$$;

create or replace function private.my_membership_id(p_org uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select m.id
  from public.memberships m
  join public.organisations o on o.id = m.organisation_id
  where m.organisation_id = p_org
    and m.user_id = (select auth.uid())
    and m.status = 'active' and o.status = 'active'
$$;

-- THE permission check. Scope arguments are the RESOURCE's ancestors (from its SC columns).
create or replace function private.has_perm(
  p_org uuid, p_perm text,
  p_campus uuid default null, p_ministry uuid default null,
  p_department uuid default null, p_team uuid default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.memberships m
    join public.organisations o on o.id = m.organisation_id and o.status = 'active'
    join public.membership_role_assignments a
         on a.membership_id = m.id and a.organisation_id = m.organisation_id
        and a.revoked_at is null
        and (a.expires_at is null or a.expires_at > now())
    join public.role_permissions rp on rp.role_id = a.role_id and rp.permission_key = p_perm
    join public.permissions pm       on pm.key = rp.permission_key
    where m.organisation_id = p_org
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and a.scope_type = any (pm.allowed_scopes)          -- inert if scope not allowed for this permission
      and ( a.scope_type = 'organisation'
         or (a.scope_type = 'campus'     and a.campus_id     = p_campus)
         or (a.scope_type = 'ministry'   and a.ministry_id   = p_ministry)
         or (a.scope_type = 'department' and a.department_id = p_department)
         or (a.scope_type = 'team'       and a.team_id       = p_team))
  )
$$;
```
`a.campus_id = p_campus` is `NULL`-safe by construction: if the resource has no campus, `p_campus` is NULL, the comparison is NULL (false) and a campus-scoped grant never matches an unscoped resource (PERMISSIONS_MATRIX §1.1 rule 3).

```sql
-- Convenience: resolve a team's ancestors then check.
create or replace function private.has_perm_for_team(p_org uuid, p_perm text, p_team uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.has_perm(t.organisation_id, p_perm, t.campus_id, t.ministry_id, t.department_id, t.id)
  from public.teams t where t.id = p_team and t.organisation_id = p_org
$$;

-- Permission over a PERSON: scope matches where the person is (their teams / home campus).
create or replace function private.has_perm_over_member(p_org uuid, p_perm text, p_target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.memberships me
    join public.organisations o on o.id = me.organisation_id and o.status = 'active'
    join public.membership_role_assignments a
         on a.membership_id = me.id and a.organisation_id = me.organisation_id
        and a.revoked_at is null and (a.expires_at is null or a.expires_at > now())
    join public.role_permissions rp on rp.role_id = a.role_id and rp.permission_key = p_perm
    join public.permissions pm on pm.key = rp.permission_key and a.scope_type = any (pm.allowed_scopes)
    join public.memberships tgt on tgt.id = p_target and tgt.organisation_id = me.organisation_id
    where me.organisation_id = p_org and me.user_id = (select auth.uid()) and me.status = 'active'
      and ( a.scope_type = 'organisation'
         or (a.scope_type = 'campus' and (tgt.home_campus_id = a.campus_id or exists (
               select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
               where tm.membership_id = tgt.id and tm.status = 'active' and t.campus_id = a.campus_id)))
         or (a.scope_type = 'ministry' and exists (
               select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
               where tm.membership_id = tgt.id and tm.status = 'active' and t.ministry_id = a.ministry_id))
         or (a.scope_type = 'department' and exists (
               select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
               where tm.membership_id = tgt.id and tm.status = 'active' and t.department_id = a.department_id))
         or (a.scope_type = 'team' and exists (
               select 1 from public.team_memberships tm
               where tm.membership_id = tgt.id and tm.status = 'active' and tm.team_id = a.team_id)))
  )
$$;

-- Is a member inside an audience scope (used for announcements and 'scope' channels)?
-- The lowest non-null level decides; all-null = whole organisation.
create or replace function private.member_in_scope(
  p_membership uuid, p_campus uuid, p_ministry uuid, p_department uuid, p_team uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when p_team       is not null then exists (select 1 from public.team_memberships tm
         where tm.membership_id = p_membership and tm.status='active' and tm.team_id = p_team)
    when p_department is not null then exists (select 1 from public.team_memberships tm
         join public.teams t on t.id = tm.team_id
         where tm.membership_id = p_membership and tm.status='active' and t.department_id = p_department)
    when p_ministry   is not null then exists (select 1 from public.team_memberships tm
         join public.teams t on t.id = tm.team_id
         where tm.membership_id = p_membership and tm.status='active' and t.ministry_id = p_ministry)
    when p_campus     is not null then exists (select 1 from public.memberships m
         where m.id = p_membership and m.home_campus_id = p_campus)
         or exists (select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
         where tm.membership_id = p_membership and tm.status='active' and t.campus_id = p_campus)
    else true end
$$;
```

### 4.3 Resource helpers

```sql
-- Service visibility: the single source of truth for 'who can see this service'.
create or replace function private.can_see_service(
  p_id uuid, p_org uuid, p_status text, p_campus uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_member(p_org) and (
    case when p_status = 'draft'
      then private.has_perm(p_org, 'services.view_drafts', p_campus)
           or exists (select 1 from public.service_assignments sa                 -- assigners of a slot see the draft
                      left join public.teams t on t.id = sa.team_id
                      where sa.service_id = p_id and sa.team_id is not null
                        and private.has_perm(p_org, 'services.assign', p_campus, t.ministry_id, t.department_id, t.id))
      else private.has_perm(p_org, 'services.view', p_campus)
           or exists (select 1 from public.service_assignments sa                 -- participants always see their service
                      where sa.service_id = p_id and sa.membership_id = private.my_membership_id(p_org))
    end)
$$;

-- Conversation access: participants only for direct/group/private; computed for open channels.
create or replace function private.can_access_conversation(p_conv uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.conversations c
    join public.memberships me on me.organisation_id = c.organisation_id
         and me.user_id = (select auth.uid()) and me.status = 'active'
    join public.organisations o on o.id = c.organisation_id and o.status = 'active'
    where c.id = p_conv and (
         -- direct, group and private channels: explicit, current participants ONLY
         (c.kind in ('direct','group') or (c.kind='channel' and c.visibility='private'))
           and exists (select 1 from public.conversation_participants cp
                       where cp.conversation_id = c.id and cp.membership_id = me.id and cp.left_at is null)
      or (c.kind = 'channel' and c.visibility = 'organisation')
      or (c.kind = 'channel' and c.visibility = 'scope' and
            ( private.member_in_scope(me.id, c.campus_id, c.ministry_id, c.department_id, c.team_id)
              or private.has_perm(c.organisation_id, 'channels.manage', c.campus_id, c.ministry_id, c.department_id, c.team_id)))
      or (c.kind = 'channel' and c.visibility = 'event' and (
            exists (select 1 from public.service_assignments sa
                    where sa.service_id = c.service_id and sa.membership_id = me.id)
         or exists (select 1 from public.rehearsal_participants rp
                    where rp.rehearsal_id = c.rehearsal_id and rp.membership_id = me.id)
         or private.has_perm(c.organisation_id, 'channels.manage', c.campus_id, c.ministry_id, c.department_id, c.team_id)))
    )
  )
$$;
```
**There is deliberately no branch that lets `channels.manage`, `messages.moderate`, an Owner, or an Admin read a `direct`, `group` or `private` conversation.** Moderators handle those only through `message_reports.body_snapshot`.

```sql
create or replace function private.can_post_conversation(p_conv uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.can_access_conversation(p_conv) and exists (
    select 1 from public.conversations c
    where c.id = p_conv and c.archived_at is null
      and ( c.posting = 'everyone'
            or exists (select 1 from public.conversation_participants cp
                       where cp.conversation_id = c.id and cp.role in ('moderator','owner')
                         and cp.membership_id = private.my_membership_id(c.organisation_id))
            or private.has_perm(c.organisation_id,'channels.manage',c.campus_id,c.ministry_id,c.department_id,c.team_id))
      and ( c.kind = 'channel' and c.visibility <> 'private'
            or exists (select 1 from public.conversation_participants cp
                       where cp.conversation_id = c.id and cp.can_post and cp.left_at is null
                         and cp.membership_id = private.my_membership_id(c.organisation_id)))
  )
$$;

-- File access: a file is readable only through a relationship that grants it.
create or replace function private.can_read_file(p_file uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.files f
    where f.id = p_file and f.status = 'available' and f.scan_status in ('clean','not_required')
      and private.is_member(f.organisation_id)
      and ( f.uploaded_by_user_id = (select auth.uid())
         -- NOTE: `files.manage` is deliberately NOT a read path. Verified on Supabase: with it here, an Owner/Admin could
         -- download a DM attachment and any unattached file (tests FIL-02b/02c/04/11c failed). files.manage = delete/quarantine only.
         or exists (select 1 from public.message_attachments ma
                    join public.messages ms on ms.id = ma.message_id
                    where ma.file_id = f.id and ms.deleted_at is null
                      and private.can_access_conversation(ms.conversation_id))
         or exists (select 1 from public.song_resources sr
                    where sr.file_id = f.id and sr.archived_at is null
                      and private.has_perm(f.organisation_id,'music.view')
                      and (sr.access_scope = 'all_members'
                           or private.has_perm(f.organisation_id,'music.manage')
                           or (sr.access_scope = 'assigned_members' and private.is_assigned_to_song(sr.song_id))))
         or exists (select 1 from public.file_attachments fa
                    where fa.file_id = f.id and private.can_read_attachment_target(fa.id))
         or exists (select 1 from public.report_exports re
                    where re.file_id = f.id
                      and re.requested_by_membership_id = private.my_membership_id(f.organisation_id)))
  )
$$;
```
(`is_assigned_to_song`, `can_read_attachment_target` follow the same definer pattern: they resolve the parent service/rehearsal/meeting/plan/task and apply that resource's own visibility rule. `is_assigned_to_song` = the caller holds a `service_assignments` slot, or is a `rehearsal_participants` row, for a non-completed or recently completed (≤14 days) service/rehearsal that includes the song.)

### 4.4 Supporting utilities

| Function | Purpose |
|---|---|
| `private.try_uuid(text) → uuid` | returns NULL instead of raising on malformed input (storage/realtime path parsing) |
| `private.scope_ancestors(org, scope_type, scope_id) → record` | resolves a scope row to its full ancestor chain (campus, ministry, department, team), verifying the row belongs to `org`; returns no row otherwise |
| `private.has_perm_at_scope(org, perm, scope_type, scope_id) → boolean` | `scope_ancestors` + `has_perm`; used for **role-scope (RS) columns**, which store only the single typed column of the scope, not its ancestors |
| `private.can_grant_role(org, role, scope_type, scope_id)` | privilege ceiling (§7.3) |
| `private.can_assign_slot(service_id, team_id)` | `has_perm(org,'services.assign', service.campus_id, team.ministry_id, team.department_id, team.id)` |
| `private.can_edit_role_permission(role, permission)` | role-definition ceiling: custom role of the caller's organisation, caller holds `permission` at organisation scope, role has no active assignment to the caller |
| `private.require_aal2(org)` | raises unless the org does not require MFA **or** `(select auth.jwt()->>'aal') = 'aal2'` (D-027) |
| `private.write_audit(...)` | the only way to insert into `audit_events`; not executable by clients |
| `private.is_valid_timezone(text)` | tz validation |

### 4.5 Performance notes

* `(select private.my_org_array())` and `(select auth.uid())` are evaluated once per statement (initPlan). Measured results are in MIGRATION_PLAN §9. `has_perm(...)` with row-dependent scope arguments is evaluated per row; each call is two or three index lookups against small tables (`memberships (user_id, organisation_id) WHERE active`, `membership_role_assignments (membership_id) WHERE revoked_at IS NULL`, `role_permissions (role_id, permission_key)`).
* Policies list the **cheapest, most selective predicate first** (`organisation_id IN (select …)`) so the planner can use the tenant-leading index before invoking per-row helpers.
* If benchmarking shows `has_perm` dominates for a hot list query, the sanctioned optimisation is a trigger-maintained `effective_grants` table (membership, permission, scope columns) turning the check into a single index probe. That is **not** built in v1 (premature complexity) — see ARCHITECTURE §9.

---

## 5. Policy patterns

Every policy in §6 is an instance of one of these.

| Id | Pattern | SELECT | Write |
|---|---|---|---|
| **P1** | *Organisation catalogue* | `organisation_id = ANY ((SELECT private.my_org_array())::uuid[])` | `has_perm(org, key[, scope])` |
| **P2** | *Own rows* | `membership_id = private.my_membership_id(organisation_id)` | same, with `WITH CHECK` |
| **P3** | *Permission over a person* | own **or** `has_perm_over_member(org, key, membership_id)` | permission over the person |
| **P4** | *Inherit from parent* | `EXISTS (SELECT 1 FROM parent p WHERE p.id = child.parent_id)` — **runs the parent's RLS** because the subquery executes as the caller | `EXISTS (parent p … AND has_perm(… edit …))` |
| **P5** | *Participant-gated* | `private.can_access_conversation(conversation_id)` etc. | participant + `can_post` |
| **P6** | *Server-only* | no grant, RLS on, no policy | no grant |
| **P7** | *Append-only* | `has_perm(org,'audit.view')` | none for clients; written by definer functions |
| **P8** | *RPC-only* | grant `SELECT` + a policy | **no** write grants/policies; `SECURITY DEFINER` function does validated writes |

**P4 and recursion.** Because the parent subquery applies the parent's RLS, child policies automatically stay in step with parent policies. Recursion is avoided by construction: helpers read RLS-free base tables (`memberships`, role tables) via `SECURITY DEFINER`, and parent policies never subquery their own children without going through a definer helper (e.g. `can_see_service` reads `service_assignments` as definer).

**Client-supplied organisation ids.** For INSERT the `WITH CHECK` calls `has_perm(organisation_id, …)` with the *supplied* id: a forged `organisation_id` for a church where the caller lacks the permission simply fails. A forged id for a church where the caller *does* have the permission cannot reference parents of another church because every parent FK is composite on `(organisation_id, parent_id)`. `organisation_id` cannot be changed by UPDATE (`private.forbid_org_change`).

---

## 6. Per-table RLS matrix

**Legend.** *RLS* column: every table is **ON**; `ON+F` = ON and `FORCE`. FORCE only affects table owners *without* `BYPASSRLS`; the Supabase `postgres` role has `BYPASSRLS`, so FORCE adds no protection there (verified, spike S-10) — the real controls are the grants in §3 and keeping application code off `postgres`/`service_role`. A dash means **denied (no policy / no grant)**.

| Shorthand | Meaning |
|---|---|
| **M** | active member of the row's organisation. Written in policies as `organisation_id = ANY ((SELECT private.my_org_array())::uuid[])` (not `IN (SELECT …)`; see §4.5) |
| **Self** | row belongs to the caller: `membership_id = private.my_membership_id(organisation_id)` (or `user_id = auth.uid()` for global tables) |
| **P:`k`** | `has_perm(organisation_id, 'k', row's SC ancestors)`; rows without SC columns match only organisation-scope grants |
| **Pm:`k`** | `has_perm_over_member(organisation_id, 'k', <the person the row is about>)` |
| **Par** | caller is a participant of the event / conversation |
| **Parent** | pattern P4: read = parent visible to caller; write = the parent's edit permission |
| **RPC** | only through the named `SECURITY DEFINER` function (§11); no direct write grant |
| **Trg** | written only by trigger / server worker, not callable by clients |

### 6.1 A — Identity and tenancy

| Table | SELECT | INSERT | UPDATE | DELETE | Scope / tenant checks |
|---|---|---|---|---|---|
| `profiles` | Self (`id = auth.uid()`) | Trg (on `auth.users` insert) | Self; columns `display_name, preferred_timezone, locale, avatar_path` | — (erasure RPC) | Global table: never visible across users |
| `organisations` | M (`id = ANY(my_org_array())`) | RPC `create_organisation` | P:`org.settings.manage`; columns `name, timezone, country_code, contact_*, website_url` only; `status`/`slug` never | — | `status` changed only by `platform.*` |
| `organisation_settings` | M | RPC (with organisation) | P:`org.settings.manage` | — | 1:1 on org id |
| `memberships` | Self (any status) **or** (M and `status='active'`) **or** P:`members.suspend` | RPC (`accept_invitation`, `create_organisation`) | Self while active (cols `display_name, avatar_file_id, home_campus_id`); Pm:`members.manage` (same cols). `status` via RPC `set_membership_status` | — | Suspended/removed rows invisible to ordinary members |
| `membership_status_events` | Self (own history) or P:`members.suspend` | Trg/RPC | — | — | Append-only |
| `membership_contacts` | Self or Pm:`members.view_contact` | Self | Self | Self | |
| `invitations` | P:`members.invite` at the invitation's RS scope, or invited_by = Self | RPC `create_invitation` | RPC (`revoke_invitation`, `resend_invitation`) | — | An invitee has no policy at all; they use `get_invitation_preview`/`accept_invitation` |
| `invitation_tokens` | — (server-only; no policy, no grant) | RPC | — | cascade | Holds `token_hash`; spike S-5 |
| `invitation_teams` | Parent | RPC | — | Parent (with invitation) | Teams must lie in inviter's scope |
| `policy_acceptances` | Self or P:`org.settings.manage` | Self | — | — | Append-only |

### 6.2 B — Organisation structure

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `campuses` | M | P:`structure.manage` (organisation scope) | P:`structure.manage` | — (archive) | Campus creation is org-level |
| `ministries` | M | P:`structure.manage` at the new row's campus | P:`structure.manage` | — | |
| `departments` | M | P:`structure.manage` at parent scope | P:`structure.manage` | — | |
| `teams` | M | P:`teams.manage` at parent scope | P:`teams.manage` | — | Ancestors derived by trigger; client values ignored |
| `locations` | M | P:`locations.manage` | P:`locations.manage` | — | |

### 6.3 C — Authorisation

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `permissions` | any authenticated | — | — | — | Global read-only catalogue |
| `roles` | system rows (`organisation_id IS NULL`) → any authenticated; custom → M | P:`roles.manage` (custom only; `organisation_id` = own) | P:`roles.manage` (custom only) | — (archive) | System roles immutable to clients |
| `role_permissions` | Parent (role visible) | P:`roles.manage` on a custom role **and** `private.can_edit_role_permission(role_id, permission_key)` (caller holds that permission at organisation scope; role is not assigned to the caller); trigger forbids `org.ownership.manage` | — | same checks | Role-definition ceiling (PERMISSIONS §1.1 rule 6): `roles.manage` cannot be used to self-escalate by editing one's own role |
| `membership_role_assignments` | Self, or P:`roles.assign`/`roles.manage`, or (M and role `show_in_directory`) | RPC `assign_role` | RPC `revoke_role` | — | Privilege ceiling, no self-assignment, last-owner guard |

### 6.4 P — Platform (`platform.*`)

RLS ON with **no policies**; `REVOKE ALL` from `anon`/`authenticated`; schema not exposed. Accessed only by the platform console's server code via narrow audited functions (§9).

### 6.5 D — People and team operations

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `team_memberships` | M (if `member_directory_visibility='names_and_teams'`) else Self or P:`teams.manage` | P:`teams.manage` at the team | P:`teams.manage` | P:`teams.manage` **or** Self (leave team) | |
| `positions` | M | P:`teams.manage` (org scope) | same | — | |
| `skills` | M | P:`teams.manage` (org scope) | same | — | |
| `member_skills` | M | Self or Pm:`members.manage` | Self or Pm:`members.manage` | Self or Pm:`members.manage` | `verified_*` writable only by Pm:`members.manage` |
| `member_positions` | M | Self or Pm:`members.manage` | same | same | |
| `member_vocal_profiles` | Self, Pm:`members.manage`, Pm:`services.assign` | Self | Self or Pm:`members.manage` | Self | |
| `member_unavailability` | Self, Pm:`availability.view`, Pm:`services.assign` | Self | Self | Self | Dates only |
| `member_unavailability_notes` | **Self only** | Self | Self | Self | Reason never visible to leaders |
| `member_availability_preferences` | Self, Pm:`availability.view`, Pm:`services.assign` | Self | Self | Self | |
| `member_emergency_contacts` | Self or Pm:`members.notes.manage` | Self | Self | Self | |
| `member_private_notes` | author, or (`visibility='leaders_in_scope'` and Pm:`members.notes.manage`) | Pm:`members.notes.manage` (author = Self, stamped) | author | — (archive) | Subject cannot read (risk R-9) |
| `onboarding_plans` | M | P:`onboarding.manage` | P:`onboarding.manage` | — | |
| `onboarding_plan_steps` | Parent | Parent write | Parent write | Parent write | |
| `member_onboarding` | Self, mentor, or Pm:`onboarding.manage` | Pm:`onboarding.manage` | Pm:`onboarding.manage` | — | |
| `member_onboarding_steps` | Parent | RPC | Self via RPC `complete_onboarding_step` (unverified steps); Pm:`onboarding.manage` (verify) | — | |

### 6.6 E — Files

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `files` | `private.can_read_file(id)` **or** uploader (any status, to see own pending). **`files.manage` grants no read or list access** to content or metadata | RPC `register_file` (active member; quota check) | RPC (`finalise_file`, service role/worker sets `available`/`scan_status`) | RPC `delete_file` (uploader or P:`files.manage`) | Storage policy (§8) keys on this row |
| `file_attachments` | Parent target visible | Parent target edit perm (`services.edit`, `rehearsals.manage`, `meetings.manage`, `production.manage`, `tasks.manage`) | same | same | file must be same-org, purpose-compatible, readable by attacher |

### 6.7 F — Music library

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `songs` | P:`music.view` | P:`music.manage` | P:`music.manage` | P:`music.delete` (only if never used) | |
| `song_alternate_titles`, `writers`, `song_writer_credits`, `tags`, `song_tags` | P:`music.view` | P:`music.manage` | P:`music.manage` | P:`music.manage` | |
| `song_rights` | P:`music.view` | P:`music.rights.manage` | P:`music.rights.manage` | — | Gate flags enforced by trigger |
| `song_arrangements`, `arrangement_sections` | P:`music.view` and (`status<>'draft'` or P:`music.manage`) | P:`music.manage` | P:`music.manage` | P:`music.manage` (archive preferred) | Sections gated by rights flags |
| `song_resources` | P:`music.view` **and** (`access_scope='all_members'` or P:`music.manage` or (`'assigned_members'` and `is_assigned_to_song`)); archived hidden from non-managers | P:`music.manage` | P:`music.manage` | P:`music.delete` | Same predicate guards the storage object |
| `song_notes` | (`visibility='all_members'` and P:`music.view`) or P:`music.notes.view` | P:`music.manage` or P:`music.notes.view` (author stamped) | author or P:`music.manage` | — | |
| `member_song_preferences` | Self or Pm:`services.assign` | Self | Self | Self | |

### 6.8 G — Services and planning

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `service_types` | M | P:`services.templates.manage` | same | — | |
| `service_templates`, `service_template_items`, `service_template_slots` | P:`services.create` or P:`services.templates.manage` | P:`services.templates.manage` | same | same | |
| `event_series` | `kind='service'`: P:`services.templates.manage`; `'rehearsal'`: P:`rehearsals.manage` | same by kind | same by kind | — | Generator worker uses service role |
| `services` | `private.can_see_service(id, organisation_id, status, campus_id)` | P:`services.create` at `campus_id` (status forced `draft`) | P:`services.edit` (non-status columns, status ≠ completed); status transitions only via RPC | P:`services.delete` and `status='draft'` and `last_published_revision=0` | Draft vs published split lives in `can_see_service` |
| `service_programme_items`, `service_songs`, `service_song_sections` | Parent (service visible) | Parent: P:`services.edit` and service not `completed` | same | same | `service_songs` snapshot fields stamped by trigger |
| `service_assignments` | Parent (service visible) | `private.can_assign_slot` | `private.can_assign_slot` (any column); **members answer via RPC** `respond_to_assignment` | `private.can_assign_slot` | Slot ancestry from `team_id`; org/campus-level assigners match unowned slots |
| `service_assignment_private` | assigned member (Self) or `can_assign_slot` | RPC | RPC (`respond_to_assignment`) / assigners | — | Decline reasons never visible to the roster |
| `service_notes` | Parent and (`visibility='everyone'` or `'assigned'` and Par-assigned, or `'team'` and member of `team_id`, or `'leaders'` and P:`services.edit`/`assign`) | P:`services.edit` | author or P:`services.edit` | — | |
| `service_revisions` | P:`services.view_drafts` or P:`services.publish` (campus of service) | RPC `publish_service_revision` | worker sets `notified_at` only | — | Immutable |

### 6.9 H — Rehearsals, tasks, attendance

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `rehearsals` | P:`rehearsals.view` or P:`rehearsals.manage` or participant (Self in `rehearsal_participants`) | P:`rehearsals.manage` | P:`rehearsals.manage` | P:`rehearsals.manage` if no attendance recorded | |
| `rehearsal_songs`, `rehearsal_notes` | Parent (notes: and `visibility='participants'` or P:`rehearsals.manage`) | Parent: P:`rehearsals.manage` | same | same | |
| `rehearsal_participants` | Parent (rehearsal visible) | P:`rehearsals.manage` | P:`rehearsals.manage`; **members answer via RPC** `respond_to_rehearsal` | P:`rehearsals.manage` | |
| `tasks` | assignee, creator, P:`tasks.manage`, or (linked meeting visible) | P:`tasks.manage` | P:`tasks.manage` or creator while open | P:`tasks.manage` | SC-scoped |
| `task_assignees` | Self or Parent(task visible) | P:`tasks.manage` (task scope) | P:`tasks.manage`; Self only via RPC `complete_task` | P:`tasks.manage` | |
| `attendance_records` | Self or Pm:`attendance.view` | Pm:`attendance.record` (+ event visible, same org) | Pm:`attendance.record` | — | Corrections audited with old/new status; no delete |

### 6.10 I — Meetings

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `meetings` | participant, or P:`meetings.manage` | P:`meetings.manage` | P:`meetings.manage` | P:`meetings.manage` if no minutes | |
| `meeting_participants`, `meeting_agenda_items` | Parent | P:`meetings.manage` | same; RSVP via RPC `respond_to_meeting` | same | |
| `meeting_minutes` | P:`meetings.manage`; or P:`meetings.minutes.view_all`; or (participant and `minutes_visibility='participants'` and `status='approved'`); author of draft | P:`meetings.manage` or secretary | same; approved ⇒ amendment RPC | — | |
| `meeting_decisions` | follows `meeting_minutes` visibility | P:`meetings.manage` | same | — | |

### 6.11 J — Communication

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `announcements` | (`status='published'`, within `publish_at/expires_at`, and `member_in_scope(me, SC)`) **or** P:`announcements.publish` **or** author | P:`announcements.publish` at audience SC | same / author while draft | — (archive) | Audience *is* the SC columns |
| `announcement_receipts` | Self | Self (announcement visible) | Self | — | Aggregates via RPC only |
| `conversations` | `can_access_conversation(id)` **or** (`kind='channel'` and `visibility<>'private'` and P:`channels.manage`) | channels: P:`channels.manage` at SC; `direct`/`group`: RPC `create_conversation` | channels: P:`channels.manage`; group: owner | — | Never expose private/direct content via manager branch |
| `conversation_participants` | Self, or co-participant of a conversation the caller can access (`kind<>'channel'` or private), or P:`channels.manage` (non-direct) | RPC `add_participants` | Self (read marker, notification settings, mute); P:`channels.manage` or group owner (role, `can_post`) | Self (leave); P:`channels.manage` (not `direct`) | `direct` participant set is fixed at creation |
| `messages` | `can_access_conversation(conversation_id)` (moderation *hide/remove* is a **tombstone**: `body` and attachments are cleared; the original text survives only in `message_reports.body_snapshot`) | sender = Self **and** `can_post_conversation` | sender, own, within edit window (`body` only); moderation via RPC | — (tombstone via RPC `delete_message`) | Composite FK pins message to conversation's org |
| `message_attachments` | Parent (message visible) | sender of the message; file uploaded by sender | — | sender | |
| `message_reactions` | Parent | Self + message visible | — | Self | |
| `message_reports` | reporter, or moderators: P:`messages.moderate` over the conversation scope (organisation-scope only for `direct`/`group`) | Self + message visible; trigger stores `body_snapshot` | moderators | — | The **only** moderator path to private content |
| `notifications` | recipient (Self) | Trg/worker | Self: `read_at`, `archived_at` columns | Self | No `INSERT` grant to clients |
| `notification_preferences` | Self | Self | Self | Self | |
| `notification_deliveries` | — | Trg/worker | worker | worker | P6 server-only |
| `push_subscriptions` | Self (`user_id = auth.uid()`) | Self | Self | Self | Global; not tenant-owned |

### 6.12 K — Technical production

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `equipment_items` | P:`equipment.view` | P:`equipment.manage` | P:`equipment.manage` | — (archive) | SC: campus/team |
| `equipment_allocations` | P:`equipment.view` or P:`production.view` (plan scope) | P:`equipment.manage` or P:`production.manage` | same | same while `reserved` | Exclusion constraint prevents double-booking |
| `production_plans` | P:`production.view` at plan SC, **or** (plan `status IN ('ready','locked')` and caller holds a `service_assignments` slot on the service) | P:`production.manage` | P:`production.manage` | P:`production.manage` if `draft` | Templates (`is_template`) readable by `production.view` only |
| `production_plan_revisions` | Parent | RPC | — | — | Immutable |
| `stage_plots`, `stage_plot_elements`, `input_list_items`, `monitor_requirements`, `production_cues` | Parent (plan visible) | P:`production.manage` at plan | same | same | |
| `production_checklist_items` | Parent | P:`production.manage` | same; assignee marks own item via RPC `complete_checklist_item` | same | |
| `production_requirements` | Parent | P:`production.manage`, P:`services.edit`, or service participant | P:`production.manage`; requester while `requested` | P:`production.manage` | |
| `production_notes` | Parent and (`visibility='all_assigned'` and participant, `'production_team'` and P:`production.view`, `'leaders'` and P:`production.manage`) | P:`production.manage` | author / P:`production.manage` | — | |

### 6.13 L — Reporting and audit

| Table | SELECT | INSERT | UPDATE | DELETE | Notes |
|---|---|---|---|---|---|
| `audit_events` | P:`audit.view` (`organisation_id` = row's); platform events (`organisation_id IS NULL`) never visible to clients | Trg / `private.write_audit` only | — | — | `TRUNCATE/UPDATE/DELETE` revoked and blocked by trigger |
| `report_exports` | requester (Self) or P:`reports.export` | RPC `request_report_export` (requires `reports.export`) | worker | — | Each request audited |

**Reporting views (`v_*`).** All are `WITH (security_invoker = true)`, so the caller's RLS on the base tables applies, **and** each aggregate view adds an explicit `reports.view` predicate so that raw-row access (`attendance.view`) and summary reporting stay separately grantable:

```sql
create view public.v_attendance_summary with (security_invoker = true) as
select a.organisation_id, a.membership_id, /* aggregates … */
from public.attendance_records a
where a.membership_id = private.my_membership_id(a.organisation_id)                       -- everyone sees their own summary
   or private.has_perm_over_member(a.organisation_id, 'reports.view', a.membership_id)    -- leaders: only people in their scope
group by a.organisation_id, a.membership_id;
```
`reports.export` additionally gates `request_report_export`. Excused/approved-leave rows are excluded from "absence" metrics inside the view definitions. Materialised views are **never** exposed (they cannot enforce RLS).

---

## 7. Representative policies and functions

### 7.1 Enable RLS and grant (template applied to every table)

```sql
alter table public.songs enable row level security;
alter table public.songs force row level security;   -- harmless, but NOT a control on Supabase: roles with BYPASSRLS (incl. `postgres`) ignore it (spike S-10)
grant select, insert, update, delete on public.songs to authenticated;
```

### 7.2 Organisation catalogue (P1) — `songs`

```sql
create policy songs_select on public.songs for select to authenticated
using ( organisation_id = any ((select private.my_org_array())::uuid[])
        and private.has_perm(organisation_id, 'music.view') );

create policy songs_insert on public.songs for insert to authenticated
with check ( private.has_perm(organisation_id, 'music.manage') );

create policy songs_update on public.songs for update to authenticated
using      ( private.has_perm(organisation_id, 'music.manage') )
with check ( private.has_perm(organisation_id, 'music.manage') );     -- organisation_id also immutable by trigger

create policy songs_delete on public.songs for delete to authenticated
using ( private.has_perm(organisation_id, 'music.delete')
        and not exists (select 1 from public.service_songs ss where ss.song_id = songs.id) );
```

### 7.3 Identity: organisations, memberships, role assignment

```sql
-- organisations: visible only to active members; edit via permission and column grant.
create policy organisations_select on public.organisations for select to authenticated
using ( id = any ((select private.my_org_array())::uuid[]) );
create policy organisations_update on public.organisations for update to authenticated
using      ( private.has_perm(id, 'org.settings.manage') )
with check ( private.has_perm(id, 'org.settings.manage') );
-- no INSERT/DELETE policy: creation is RPC-only, deletion is a platform process.

-- memberships: a user always sees their own rows (to learn they are suspended);
-- others see only ACTIVE rows of organisations they are active in.
create policy memberships_select on public.memberships for select to authenticated
using (
     user_id = (select auth.uid())
  or ( organisation_id = any ((select private.my_org_array())::uuid[]) and status = 'active' )
  or private.has_perm(organisation_id, 'members.suspend')
);
create policy memberships_update_self on public.memberships for update to authenticated
using      ( user_id = (select auth.uid()) and status = 'active'
             and organisation_id = any ((select private.my_org_array())::uuid[]) )
with check ( user_id = (select auth.uid()) and status = 'active' );
-- column grant limits what can change:
grant update (display_name, avatar_file_id, home_campus_id) on public.memberships to authenticated;
-- status, user_id, organisation_id are not updatable by any client role.
```

```sql
-- assign_role: the ONLY way to create a role assignment.
create or replace function public.assign_role(
  p_membership uuid, p_role uuid, p_scope_type text default 'organisation',
  p_scope_id uuid default null, p_expires_at timestamptz default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid; v_target_user uuid; v_id uuid;
begin
  -- 1. tenant derived from the TARGET ROW — never from a parameter
  select organisation_id, user_id into v_org, v_target_user
  from public.memberships where id = p_membership and status = 'active';
  if v_org is null or not private.is_member(v_org) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- 2. no self-assignment (prevents self-escalation)
  if v_target_user = (select auth.uid()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- 3. privilege ceiling: role/scope valid for this org, caller holds roles.assign over the scope
  --    AND every permission contained in the role over that scope; Owner role needs org.ownership.manage
  if not private.can_grant_role(v_org, p_role, p_scope_type, p_scope_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (select 1 from public.roles r where r.id = p_role and r.system_key = 'owner') then
    perform private.require_aal2(v_org);                -- MFA step-up where configured (D-027)
  end if;
  -- 4. write. The scope row was validated against v_org inside can_grant_role (scope_ancestors);
  --    RS columns store ONLY the typed column for the scope (the CHECK requires exactly one).
  insert into public.membership_role_assignments
    (organisation_id, membership_id, role_id, scope_type, campus_id, ministry_id, department_id, team_id,
     expires_at, assigned_by_membership_id)
  values (v_org, p_membership, p_role, p_scope_type,
     case when p_scope_type = 'campus'     then p_scope_id end,
     case when p_scope_type = 'ministry'   then p_scope_id end,
     case when p_scope_type = 'department' then p_scope_id end,
     case when p_scope_type = 'team'       then p_scope_id end,
     p_expires_at, private.my_membership_id(v_org))
  returning id into v_id;
  perform private.write_audit(v_org, 'role.assigned', 'membership_role_assignment', v_id,
          jsonb_build_object('role_id', p_role, 'scope_type', p_scope_type), 'security');
  return v_id;
end $$;
revoke execute on function public.assign_role(uuid,uuid,text,uuid,timestamptz) from public, anon;
grant  execute on function public.assign_role(uuid,uuid,text,uuid,timestamptz) to authenticated;
```

```sql
-- Privilege ceiling (excerpt)
create or replace function private.can_grant_role(p_org uuid, p_role uuid, p_scope_type text, p_scope_id uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare r public.roles; a record;
begin
  select * into r from public.roles
   where id = p_role and archived_at is null and (organisation_id is null or organisation_id = p_org);
  if not found or not (p_scope_type = any (r.assignable_scopes)) then return false; end if;
  if r.system_key = 'owner' and not private.has_perm(p_org, 'org.ownership.manage') then return false; end if;
  select * into a from private.scope_ancestors(p_org, p_scope_type, p_scope_id);   -- validates scope row belongs to p_org
  if not found then return false; end if;
  if not private.has_perm(p_org, 'roles.assign', a.campus_id, a.ministry_id, a.department_id, a.team_id) then
    return false;
  end if;
  return not exists (                                    -- caller must hold everything they hand out
    select 1 from public.role_permissions rp
    where rp.role_id = p_role
      and not private.has_perm(p_org, rp.permission_key, a.campus_id, a.ministry_id, a.department_id, a.team_id));
end $$;
```
*Effect:* a Team Leader holds no `roles.assign`, so cannot promote anyone; a Department Leader can hand out `team_leader` inside their department (they hold every permission it contains) but not `production_lead` or `admin`; only an Owner can grant Owner; nobody can grant themselves anything.

### 7.4 Invitations — creation and acceptance

```sql
-- The token hash is in public.invitation_tokens: RLS on, no policy, no grant -> unreachable by clients.

create policy invitations_select on public.invitations for select to authenticated
using ( invited_by_membership_id = private.my_membership_id(organisation_id)
     or private.has_perm_at_scope(organisation_id, 'members.invite',
          scope_type, coalesce(campus_id, ministry_id, department_id, team_id)) );   -- RS columns hold only the typed id
-- No INSERT/UPDATE/DELETE policy and no write grants: RPC-only.

create or replace function public.create_invitation(
  p_org uuid, p_email citext, p_role uuid default null,
  p_scope_type text default 'organisation', p_scope_id uuid default null,
  p_team_ids uuid[] default '{}')
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_me uuid := private.my_membership_id(p_org);        -- NULL unless caller is an ACTIVE member of p_org
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_id uuid; v_exp timestamptz := now() + interval '14 days'; a record; t uuid;
begin
  if v_me is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into a from private.scope_ancestors(p_org, p_scope_type, p_scope_id);
  if not found or not private.has_perm(p_org, 'members.invite',
        a.campus_id, a.ministry_id, a.department_id, a.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_role is not null and not private.can_grant_role(p_org, p_role, p_scope_type, p_scope_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  foreach t in array p_team_ids loop                    -- pre-assigned teams must be inside the inviter's scope
    if not private.has_perm_for_team(p_org, 'members.invite', t) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end loop;
  insert into public.invitations (organisation_id, email, role_id, scope_type,
        campus_id, ministry_id, department_id, team_id, invited_by_membership_id, expires_at)
  values (p_org, p_email, p_role, p_scope_type,
        case when p_scope_type = 'campus'     then p_scope_id end,
        case when p_scope_type = 'ministry'   then p_scope_id end,
        case when p_scope_type = 'department' then p_scope_id end,
        case when p_scope_type = 'team'       then p_scope_id end,
        v_me, v_exp)
  returning id into v_id;
  insert into public.invitation_tokens (invitation_id, organisation_id, token_hash)
    values (v_id, p_org, extensions.digest(v_token, 'sha256'));
  insert into public.invitation_teams (organisation_id, invitation_id, team_id)
    select p_org, v_id, unnest(p_team_ids);
  perform private.write_audit(p_org, 'invitation.created', 'invitation', v_id, null, 'notice');
  return query select v_id, v_token, v_exp;             -- raw token returned ONCE, to the inviter's server action
end $$;
```
The raw token is e-mailed by the application server and **never stored**; only its SHA-256 is. Because acceptance is bound to the invitee's *verified e-mail* (D-022), a leaked link alone is not sufficient.

```sql
create or replace function public.accept_invitation(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := (select auth.uid());
  v_email text; v_verified boolean;
  v_inv   public.invitations; v_mem uuid; v_existing public.memberships;
begin
  if v_uid is null then raise exception 'invalid_invitation' using errcode = '28000'; end if;
  select lower(email), (email_confirmed_at is not null) into v_email, v_verified from auth.users where id = v_uid;
  select i.* into v_inv from public.invitations i
   join public.invitation_tokens t on t.invitation_id = i.id
   where t.token_hash = extensions.digest(p_token, 'sha256') and i.status = 'pending'
   for update of i;                                           -- serialises concurrent accepts
  -- ONE generic error for: unknown token, expired, revoked, used, e-mail mismatch, unverified e-mail
  if not found or v_inv.expires_at <= now() or not coalesce(v_verified,false)
     or lower(v_inv.email::text) <> v_email then
    raise exception 'invalid_invitation' using errcode = '22023';
  end if;
  if not exists (select 1 from public.organisations where id = v_inv.organisation_id and status = 'active') then
    raise exception 'invalid_invitation' using errcode = '22023';
  end if;
  select * into v_existing from public.memberships
   where organisation_id = v_inv.organisation_id and user_id = v_uid for update;
  if found and v_existing.status = 'suspended' then          -- a suspension cannot be bypassed by re-inviting
    raise exception 'invalid_invitation' using errcode = '22023';
  elsif found and v_existing.status = 'removed' then
    update public.memberships set status = 'active', status_changed_at = now() where id = v_existing.id
      returning id into v_mem;                                -- reactivate same row (stable identity)
  elsif found then v_mem := v_existing.id;                    -- already active: idempotent
  else
    insert into public.memberships (organisation_id, user_id, display_name)
      select v_inv.organisation_id, v_uid, p.display_name from public.profiles p where p.id = v_uid
      returning id into v_mem;                                -- trigger assigns the baseline `member` role
  end if;
  if v_inv.role_id is not null then                           -- role was ceiling-checked at creation; re-validate it still exists/unarchived
    insert into public.membership_role_assignments (organisation_id, membership_id, role_id, scope_type,
          campus_id, ministry_id, department_id, team_id, assigned_by_membership_id)
    select v_inv.organisation_id, v_mem, r.id, v_inv.scope_type, v_inv.campus_id, v_inv.ministry_id,
           v_inv.department_id, v_inv.team_id, v_inv.invited_by_membership_id
    from public.roles r where r.id = v_inv.role_id and r.archived_at is null
      and (r.organisation_id is null or r.organisation_id = v_inv.organisation_id);
  end if;
  insert into public.team_memberships (organisation_id, team_id, membership_id)
    select it.organisation_id, it.team_id, v_mem from public.invitation_teams it
    where it.invitation_id = v_inv.id on conflict do nothing;
  update public.invitations set status='accepted', accepted_at=now(),
         accepted_by_user_id=v_uid, accepted_membership_id=v_mem where id = v_inv.id;
  perform private.write_audit(v_inv.organisation_id, 'invitation.accepted', 'invitation', v_inv.id, null, 'notice');
  return v_mem;
end $$;
```
* **Before acceptance** the invitee has no membership row, therefore `is_member()`, `has_perm()` and every policy return false for that organisation: *they cannot see the organisation, its name, or anything in it.*
* `get_invitation_preview(token)` returns only `{organisation_name, inviter_display_name, expires_at}` after the same generic validation; it requires `authenticated` (unauthenticated callers get nothing) and is rate-limited at the edge.
* Brute force is infeasible (256-bit tokens, hashed lookup); failed attempts are rate-limited per user/IP in the application layer and counted in audit.

### 7.5 Scoped, person-based access — availability (P3 + Self)

```sql
create policy unavailability_select on public.member_unavailability for select to authenticated
using (
  organisation_id = any ((select private.my_org_array())::uuid[])
  and ( membership_id = private.my_membership_id(organisation_id)
     or private.has_perm_over_member(organisation_id, 'availability.view', membership_id)
     or private.has_perm_over_member(organisation_id, 'services.assign',  membership_id) )
);
create policy unavailability_write_self on public.member_unavailability for all to authenticated
using      ( membership_id = private.my_membership_id(organisation_id) )
with check ( membership_id = private.my_membership_id(organisation_id) );

-- the private reason: owner only — no leader branch exists.
create policy unavailability_notes_self on public.member_unavailability_notes for all to authenticated
using      ( membership_id = private.my_membership_id(organisation_id) )
with check ( membership_id = private.my_membership_id(organisation_id) );
```

### 7.6 Parent-inherited visibility (P4) — services

```sql
create policy services_select on public.services for select to authenticated
using ( organisation_id = any ((select private.my_org_array())::uuid[])
        and private.can_see_service(id, organisation_id, status, campus_id) );

create policy services_insert on public.services for insert to authenticated
with check ( status = 'draft' and private.has_perm(organisation_id, 'services.create', campus_id) );

create policy services_update on public.services for update to authenticated
using      ( private.has_perm(organisation_id, 'services.edit', campus_id) and status <> 'completed' )
with check ( private.has_perm(organisation_id, 'services.edit', campus_id) );
-- status transitions, publish, cancel, reschedule: RPC only (column grant excludes status, published_*, cancelled_*).

create policy services_delete on public.services for delete to authenticated
using ( status = 'draft' and last_published_revision = 0
        and private.has_perm(organisation_id, 'services.delete', campus_id) );

-- Child tables inherit through the parent's own RLS (runs as the caller):
create policy programme_items_select on public.service_programme_items for select to authenticated
using ( exists (select 1 from public.services s where s.id = service_id) );
create policy programme_items_write on public.service_programme_items for all to authenticated
using ( exists (select 1 from public.services s
                where s.id = service_id and s.status <> 'completed'
                  and private.has_perm(s.organisation_id, 'services.edit', s.campus_id)) )
with check ( exists (select 1 from public.services s
                where s.id = service_id and s.organisation_id = service_programme_items.organisation_id
                  and s.status <> 'completed'
                  and private.has_perm(s.organisation_id, 'services.edit', s.campus_id)) );
```

```sql
-- Slots: a Team Leader may fill only slots owned by their team; an Admin/Director any slot.
create policy assignments_write on public.service_assignments for all to authenticated
using      ( private.can_assign_slot(service_id, team_id) )
with check ( private.can_assign_slot(service_id, team_id) );
-- Member response: RPC, touches ONLY response columns of the caller's own slot.
create or replace function public.respond_to_assignment(p_assignment uuid, p_response text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_member uuid;
begin
  if p_response not in ('accepted','declined','tentative') then raise exception 'invalid' using errcode='22023'; end if;
  select organisation_id, membership_id into v_org, v_member
    from public.service_assignments where id = p_assignment;
  if v_org is null or v_member is distinct from private.my_membership_id(v_org) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.service_assignments
     set response_status = p_response, responded_at = now(), responded_by_membership_id = v_member
   where id = p_assignment;
  insert into public.service_assignment_private (assignment_id, organisation_id, membership_id, decline_reason)
    values (p_assignment, v_org, v_member, left(p_reason, 300))
    on conflict (assignment_id) do update set decline_reason = excluded.decline_reason;
end $$;
```

### 7.7 Conversations and messages (P5)

```sql
create policy conversations_select on public.conversations for select to authenticated
using ( private.can_access_conversation(id)
     or ( kind = 'channel' and visibility <> 'private'              -- managers may LIST non-private channels
          and private.has_perm(organisation_id, 'channels.manage', campus_id, ministry_id, department_id, team_id) ) );

create policy messages_select on public.messages for select to authenticated
using ( private.can_access_conversation(conversation_id) );

create policy messages_insert on public.messages for insert to authenticated
with check (
      sender_membership_id = private.my_membership_id(organisation_id)
  and private.can_post_conversation(conversation_id)
  -- organisation_id is pinned to the conversation's by the composite FK (organisation_id, conversation_id)
);

create policy messages_edit_own on public.messages for update to authenticated
using      ( sender_membership_id = private.my_membership_id(organisation_id) and deleted_at is null
             and private.can_access_conversation(conversation_id)
             and created_at > now() - interval '15 minutes' )
with check ( sender_membership_id = private.my_membership_id(organisation_id) );
grant update (body) on public.messages to authenticated;          -- nothing else is client-editable
-- No DELETE policy. Deleting = RPC delete_message (sender, or P:messages.moderate for NON-private channels).

-- Participants: see own row + co-participants of conversations you can already open.
create policy participants_select on public.conversation_participants for select to authenticated
using ( membership_id = private.my_membership_id(organisation_id)
     or private.can_access_conversation(conversation_id) and exists (
          select 1 from public.conversations c where c.id = conversation_id and (c.kind <> 'channel' or c.visibility = 'private')) );
```
Direct-message creation (`create_conversation`) verifies: caller active in `p_org`, every target is an **active member of the same organisation**, `organisation_settings.allow_direct_messages`, computes `direct_key` for dedupe, and inserts conversation + participants atomically. A user cannot DM someone outside their shared organisation because no such conversation can be constructed (single `organisation_id`, composite FKs).

### 7.8 Attendance, notifications, audit

```sql
create policy attendance_select on public.attendance_records for select to authenticated
using ( membership_id = private.my_membership_id(organisation_id)
     or private.has_perm_over_member(organisation_id, 'attendance.view', membership_id) );
create policy attendance_insert on public.attendance_records for insert to authenticated
with check ( private.has_perm_over_member(organisation_id, 'attendance.record', membership_id) );
create policy attendance_update on public.attendance_records for update to authenticated
using      ( private.has_perm_over_member(organisation_id, 'attendance.record', membership_id) )
with check ( private.has_perm_over_member(organisation_id, 'attendance.record', membership_id) );
-- no DELETE; every UPDATE writes audit_events with old/new status (trigger).

create policy notifications_own on public.notifications for select to authenticated
using ( recipient_membership_id = private.my_membership_id(organisation_id) );
grant update (read_at, archived_at) on public.notifications to authenticated;
create policy notifications_mark on public.notifications for update to authenticated
using ( recipient_membership_id = private.my_membership_id(organisation_id) )
with check ( recipient_membership_id = private.my_membership_id(organisation_id) );

create policy audit_select on public.audit_events for select to authenticated
using ( organisation_id is not null and private.has_perm(organisation_id, 'audit.view') );
revoke insert, update, delete, truncate on public.audit_events from authenticated;
```

### 7.9 Membership status change (RPC)

`set_membership_status(p_membership, p_to, p_reason)`:
1. Derive org from the target row; require `members.suspend` over that scope; refuse self-targeting; for `removed`/`suspended` of an Owner require `org.ownership.manage` and `private.require_aal2`.
2. Enforce legal transitions (trigger) and the **last-owner guard**.
3. Update status, insert `membership_status_events` (with the reason), call `write_audit`.
4. Enqueue a realtime `membership.revoked` broadcast on the user's personal topic (§10) so connected clients drop channels immediately.

Because policies read `memberships.status` on every statement, access ends on the next query — no token refresh is needed for database reads.

---

## 8. Storage and uploaded files

### 8.1 Model

* One private bucket `org-files` (`public = false`), plus `avatars` (own-account use only). Bucket-level config sets `file_size_limit` and `allowed_mime_types` (defence in depth; the RPC enforces per-purpose limits).
* Object path: **`{organisation_id}/{file_id}/{sanitised_filename}`**. The path is an *identifier*, never an authorisation: policies always consult `files` (`status`, `scan_status`, relationship) and membership.
* Lifecycle: `register_file()` → row `pending_upload` → client uploads to the returned path → server finaliser (service role, after verifying the object exists, size/MIME, SHA-256) → `uploaded` → malware scan → `available`/`quarantined`. Clients can never mark a file `available`.
* Reads use **short-lived signed URLs (≤ 60 s)** created by the server after `can_read_file()` passes; the `Cache-Control` of private objects is `private, no-store`. No public URLs for tenant content.

### 8.2 Policies on `storage.objects`

```sql
-- READ: only through the files registry and the same relationship rules as the database.
create policy org_files_read on storage.objects for select to authenticated
using ( bucket_id = 'org-files'
        and private.can_read_file( private.try_uuid((storage.foldername(name))[2]) )
        and private.try_uuid((storage.foldername(name))[1]) =
            (select f.organisation_id from public.files f
             where f.id = private.try_uuid((storage.foldername(name))[2])) );

-- UPLOAD: only to a path pre-registered by the caller for an organisation they are an ACTIVE member of.
create policy org_files_insert on storage.objects for insert to authenticated
with check ( bucket_id = 'org-files'
  and private.can_upload_registered_object(name) );

create or replace function private.can_upload_registered_object(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.files f
    where f.storage_path = p_name
      and f.id = private.try_uuid((string_to_array(p_name,'/'))[2])
      and f.organisation_id = private.try_uuid((string_to_array(p_name,'/'))[1])
      and f.status = 'pending_upload'
      and f.uploaded_by_user_id = (select auth.uid())
      and private.is_member(f.organisation_id))
$$;

-- No UPDATE or DELETE policy for clients (no overwrite, no client deletion). Removal is done by a
-- server job after files.deleted_at / retention (service role).
```
`avatars`: `bucket_id='avatars' and (storage.foldername(name))[1] = (select auth.uid())::text` for insert/select/update/delete; other members see an organisation's member avatars through `memberships.avatar_file_id` (organisation-owned copy), **not** through the global bucket.

### 8.3 Requirements

| Concern | Control |
|---|---|
| Cross-tenant read | Path prefix is checked **and** must equal `files.organisation_id`; caller must be active member; relationship rule in `can_read_file` |
| Suspended/removed member | `is_member()` false ⇒ no read, no signed URL |
| Private conversation attachment | Readable only if `can_access_conversation()` for the message |
| Song resource restricted to assigned/leaders | Same `access_scope` predicate as the table |
| Guessing a UUID path | Useless without membership + relationship; error is identical (404-style) for "missing" and "forbidden" |
| Overwrite / replace | Not permitted (`x-upsert` blocked: no UPDATE policy); new version = new `files` row |
| Malicious upload | MIME/extension allow-list, size caps, content-type sniffing at finalisation, malware scan before `available`, images re-encoded/stripped of EXIF, Content-Disposition forced `attachment` for non-images, separate domain for user content |
| Quota/rate limits | Enforced in `register_file()` (per-member and per-org daily and total quotas; entitlements later) |
| Copyright | Rights gating on `song_resources`; takedown sets `files.status='quarantined'` which immediately blocks reads |
| Retention | `files.retention_until`; purge job deletes object then row; export files expire in 7 days |

---

## 9. Administrative and platform access

### 9.1 Church administrators are not super-users of data

| Actor | Can | Cannot |
|---|---|---|
| **Owner / Admin** | Everything in their organisation covered by §6 (all non-private content, membership, roles, audit) | Read direct/group conversations or private channels they are not in; read another organisation; change `organisations.status`; edit system roles; read `member_unavailability_notes` |
| **Owner** | Grant/revoke Owner, transfer ownership (MFA step-up where required) | Remove the last Owner |

### 9.2 Platform staff

* Platform identities live in `platform.admins` (separate from church membership; church roles never grant platform power and vice versa). They use a **separate server-side console** with enforced MFA; the console calls narrow `platform.*` functions through a server-only connection — **not** via PostgREST with a user JWT and not from the browser.
* **Metadata** (organisation name/slug/status/plan, member *counts*, storage usage, health) is available to `support`/`admin` without a grant.
* **Content access** requires an active, unexpired `platform.support_access_grants` row created by an Owner of that church (`level='content_read'`, ≤ 72 h) or a **break-glass** grant with two platform approvers. Every read through the console writes an `audit_events` row (`actor_type='platform_support'`) that the church's Owners can see.
* Even with a grant, **direct/group conversations and private channels remain unreadable**; there is no support function that returns them. Reported-message snapshots are the extent of content review.
* Suspension/reactivation of an organisation (`organisations.status`) goes through `platform.set_organisation_status()` and `platform.organisation_status_log`. A `suspended` organisation fails `is_member()` for every user instantly.

### 9.3 Support / escalation from inside the product

"Request support access" in church settings creates the grant (Owner only, MFA step-up). Revoking it sets `revoked_at` and takes effect on the next console call.

---

## 10. Realtime

### 10.1 Decisions (D-035)

1. **Use Realtime *Broadcast* on private channels, authorised by RLS on `realtime.messages`, with payloads that carry identifiers only** (`{type, conversation_id, message_id}`); clients then fetch content through normal RLS-protected queries. Even if a subscription outlives a revocation, it leaks *nothing but an opaque id*.
2. **Do not use Postgres Changes on tenant-content tables** in v1: DELETE events cannot be filtered by RLS, per-subscriber policy evaluation is costly, and payloads would contain row data.
3. Broadcasts originate from **database triggers** (`realtime.send(payload, event, topic, private := true)`), never from clients, so a client cannot inject events into another tenant's topic.
4. **Presence** is allowed only on `org:{org_id}:presence` and exposes `membership_id` + display name already visible in the directory.

### 10.2 Topic grammar

| Topic | Who may receive |
|---|---|
| `org:{org_id}:conv:{conversation_id}` | `can_access_conversation()` **and** conversation belongs to `org_id` |
| `org:{org_id}:me:{membership_id}` | exactly that membership (notifications, `membership.revoked`) |
| `org:{org_id}:service:{service_id}` | `can_see_service()` |
| `org:{org_id}:presence` | active members of `org_id` |

```sql
create or replace function private.can_read_topic(p_topic text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare p text[] := string_to_array(p_topic, ':'); v_org uuid := private.try_uuid(p[2]); v_id uuid := private.try_uuid(p[4]);
begin
  if p[1] <> 'org' or v_org is null or not private.is_member(v_org) then return false; end if;
  return case p[3]
    when 'conv'     then exists (select 1 from public.conversations c where c.id = v_id and c.organisation_id = v_org)
                         and private.can_access_conversation(v_id)
    when 'me'       then v_id = private.my_membership_id(v_org)
    when 'service'  then exists (select 1 from public.services s
                                 where s.id = v_id and s.organisation_id = v_org
                                   and private.can_see_service(s.id, s.organisation_id, s.status, s.campus_id))
    when 'presence' then true
    else false end;
end $$;

create policy rt_receive on realtime.messages for select to authenticated
using ( realtime.messages.extension in ('broadcast','presence')
        and private.can_read_topic((select realtime.topic())) );

-- Clients may only send presence on the org presence topic; they can NOT broadcast into content topics.
create policy rt_presence_send on realtime.messages for insert to authenticated
with check ( realtime.messages.extension = 'presence'
             and (select realtime.topic()) like 'org:%:presence'
             and private.can_read_topic((select realtime.topic())) );
```

### 10.3 Revocation behaviour

Realtime evaluates the policy when a channel is joined and re-evaluates on token refresh, not on every message. Therefore:

* Access tokens are short-lived (≤ 1 h; refresh re-runs the policy).
* `set_membership_status` broadcasts `membership.revoked` on the member's personal topic; the client must unsubscribe from that organisation's channels immediately (UX) — **but security does not depend on this**: payloads are id-only, and all content access still passes RLS.
* Signing a user out of *all* sessions is **not** used for per-organisation suspension (it would disrupt their other churches).
* Reconnect always re-authorises; clients re-fetch from the last-seen message id, tolerating duplicates (idempotent by `message_id`).

---

## 11. RPC catalogue (the only privileged write paths)

All are `SECURITY DEFINER`, `SET search_path=''`, `REVOKE … FROM public, anon`, `GRANT … TO authenticated`, derive organisation from target rows, write audit events for security-relevant changes, and are rate-limited at the edge. Unlisted writes are direct DML under RLS.

| Function | Purpose | Key checks |
|---|---|---|
| `create_organisation(name, slug, tz, …)` | Transactional creation: organisation, settings, owner membership, `owner` assignment, starter positions/skills, default channels | Caller authenticated + verified e-mail; per-user creation quota; slug uniqueness; **creates nothing if any step fails** (no orphans) |
| `my_workspaces()` | List caller's memberships with org name + own status (incl. suspended) | Reads own rows only; lets a suspended user see *that* they are suspended without any org read policy |
| `create_invitation`, `revoke_invitation`, `resend_invitation` | Invitation lifecycle | `members.invite` over scope; ceiling check; resend throttled |
| `get_invitation_preview(token)`, `accept_invitation(token)` | Invitee flow | Verified-e-mail binding; generic error; suspension not bypassable |
| `set_membership_status(m, to, reason)` | suspend/reinstate/remove | `members.suspend`; no self; last-owner guard; MFA step-up for Owners |
| `leave_organisation(org)` | self-removal | not last Owner |
| `assign_role`, `revoke_role` | role assignments | ceiling; no self; last-owner |
| `transfer_ownership(org, to_membership)` | Owner handover | `org.ownership.manage`; MFA step-up |
| `publish_service_revision(service, summary, expected_row_version)` | publish/amend/reschedule/cancel + snapshot + notifications | `services.publish`; optimistic lock; writes `service_revisions` + audit |
| `respond_to_assignment`, `respond_to_rehearsal`, `respond_to_meeting` | member RSVP | own row only; leaders may act on behalf (`responded_by` recorded) |
| `apply_service_template`, `generate_series_occurrences` | planning helpers | `services.create` / worker |
| `record_attendance_bulk(event, rows[])` | batch attendance | `attendance.record` over each member; same-org check per row |
| `complete_task`, `complete_onboarding_step`, `complete_checklist_item` | assignee self-completion | own assignment only |
| `create_conversation(kind, participants[], …)` | direct/group creation with dedupe | all targets active members of the same org; `allow_direct_messages` |
| `add_participants`, `delete_message`, `moderate_message`, `report_message` | conversation administration | participant/moderator rules; moderators of non-private only; **a `channels.manage` holder may add *other* members to a private channel only if they are already a participant-owner/moderator of it — never themselves** (otherwise managing a private channel would grant reading it); report stores snapshot |
| `mark_read(conversation, message)` | read marker | participant/accessor |
| `register_file`, `finalise_file`*, `delete_file` | file lifecycle (*`finalise_file` is service-role only) | quota, purpose, membership |
| `request_report_export(kind, params)` | enqueue export | `reports.export`; params validated; audited |
| `erase_my_account()` | right to deletion | anonymise procedure (§ architecture) |

Server-only (never callable by `authenticated`): `private.write_audit`, `private.create_notification`, notification delivery workers, series generator, retention/purge jobs, file scanner callbacks.

---

## 12. Service-role key rules

The Supabase **service-role key bypasses RLS**. Rules (normative):

1. **Never** in browser code, `NEXT_PUBLIC_*` variables, client bundles, logs, error reports, or Git. Stored only in server-side secret configuration (Vercel encrypted env for server runtime; separate keys per environment).
2. The admin client is constructed **only** in modules that `import 'server-only'` and is never passed to request-scoped code that handles raw client input.
3. Every service-role code path first **authenticates the caller from the verified session** (not a header/body field), then **authorises explicitly**, then derives tenant ids from the verified session/rows. A service-role query must never use an `organisation_id` taken from the request.
4. Permitted uses are an allow-list: notification delivery, file finalisation/scan callbacks, series generation, retention/purge/anonymisation jobs, billing/entitlement webhooks, the platform console, test seeding. Anything else uses the user's JWT so RLS applies.
5. CI scans for the key pattern and for admin-client imports outside the allow-listed directories; secret scanning enabled on the repository.
6. Rotation procedure documented; rotate on any suspected exposure.
7. Tests (DATABASE_TESTING_STRATEGY §3.10) assert the browser bundle contains no service-role key and that no allow-listed endpoint accepts a client-supplied organisation id.

The `anon` key is public by design and is therefore harmless **only because** `anon` has no table or function privileges (§3).

---

## 13. Review checklist (every migration touching tables, policies or functions)

- [ ] New table has `organisation_id` (or is documented global/platform), composite FKs to every tenant parent, `UNIQUE (organisation_id, id)`.
- [ ] `ENABLE ROW LEVEL SECURITY` (+ `FORCE`); grants are minimal; **no** grant to `anon`.
- [ ] Each operation has a policy matching §6 or is deliberately absent; `WITH CHECK` present on INSERT/UPDATE.
- [ ] All permission keys exist in PERMISSIONS_MATRIX §2; scope arguments are the row's SC ancestors.
- [ ] Policy columns are indexed; subqueries wrapped in `(select …)`.
- [ ] Helper functions meet §4.1; `search_path = ''`; execute revoked from `public, anon`.
- [ ] Sensitive columns excluded by column privileges or split tables, not left to the UI.
- [ ] Cascade deletes cannot remove data the caller could not DELETE directly.
- [ ] Storage/realtime impact considered; topic and path rules updated.
- [ ] Tests added: positive, negative, cross-tenant, suspended, scope-boundary.
- [ ] `get_advisors` (security + performance) clean; `supabase db lint` clean.

## 14. Known limitations and mitigations

| Limitation | Mitigation |
|---|---|
| RLS cannot hide individual columns | Column privileges for write restriction; **split tables** for mixed-sensitivity rows (`*_notes`, `service_assignment_private`) |
| Cascades and FK checks bypass RLS | Parent DELETE policies at least as strict as children; tests §3.7 |
| `SECURITY DEFINER` bypasses RLS | §4.1 rules; minimal helpers; tests §3.6 |
| Policies with joins can be slow at scale | Indexes in SCHEMA §15; `(select …)` wrapping; measured optimisation path (§4.5) |
| Realtime policy evaluated at join/refresh | Id-only payloads; short token TTL; client-side unsubscribe on `membership.revoked` |
| Table owner / `service_role` / `postgres` bypass RLS | Service-role rules §12; migrations reviewed; no app code uses `postgres` |
| Views run with owner privileges by default | All views `security_invoker = true`; materialised views not exposed |
| Error messages can confirm existence | Generic errors in RPCs; 404-style semantics in server routes |
| PostgREST returns affected rows (`Prefer: return=representation`) | A write succeeds but the representation is empty if the caller lacks SELECT; policies are written so write-permission implies read-permission, and tests assert it |
