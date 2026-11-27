-- M-017: authorisation helper functions used by RLS policies and RPCs.
-- Rules (RLS_SECURITY_SPECIFICATION.md section 4.1): SECURITY DEFINER, search_path = '', fully qualified names,
-- no caller-identity parameter (identity comes from auth.uid()), booleans/ids only, generic errors.
set lock_timeout = '10s';
set statement_timeout = '60s';

-- Organisations the caller is an ACTIVE member of, as a set (joins/RPCs) ...
create or replace function private.my_org_ids() returns setof uuid
language sql stable security definer set search_path = '' rows 5 as $$
  select m.organisation_id from public.memberships m join public.organisations o on o.id = m.organisation_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and o.status = 'active' $$;

-- ... and as an ARRAY. Table policies MUST use this form: `organisation_id = ANY ((select private.my_org_array())::uuid[])`.
-- `IN (select setof_fn())` cannot become an index condition (spike S-4: 240 ms vs 30 ms on 1 M rows).
create or replace function private.my_org_array() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(m.organisation_id), '{}'::uuid[]) from public.memberships m join public.organisations o on o.id = m.organisation_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and o.status = 'active' $$;

create or replace function private.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.memberships m join public.organisations o on o.id = m.organisation_id
    where m.organisation_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active' and o.status = 'active') $$;

create or replace function private.my_membership_id(p_org uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select m.id from public.memberships m join public.organisations o on o.id = m.organisation_id
  where m.organisation_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active' and o.status = 'active' $$;

-- THE permission check. Scope arguments are the RESOURCE's ancestors (from its scope columns).
-- A scoped grant NEVER matches a resource lacking that level (NULL = NULL is not true).
create or replace function private.has_perm(
  p_org uuid, p_perm text,
  p_campus uuid default null, p_ministry uuid default null, p_department uuid default null, p_team uuid default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.memberships m
    join public.organisations o on o.id = m.organisation_id and o.status = 'active'
    join public.membership_role_assignments a on a.membership_id = m.id and a.organisation_id = m.organisation_id
         and a.revoked_at is null and (a.expires_at is null or a.expires_at > now())
    join public.role_permissions rp on rp.role_id = a.role_id and rp.permission_key = p_perm
    join public.permissions pm on pm.key = rp.permission_key
    where m.organisation_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active'
      and a.scope_type = any (pm.allowed_scopes)          -- inert if the scope is not allowed for this permission
      and ( a.scope_type = 'organisation'
         or (a.scope_type = 'campus'     and a.campus_id     = p_campus)
         or (a.scope_type = 'ministry'   and a.ministry_id   = p_ministry)
         or (a.scope_type = 'department' and a.department_id = p_department)
         or (a.scope_type = 'team'       and a.team_id       = p_team)) ) $$;

-- Resolve a scope row to its full ancestor chain; no row if it does not belong to p_org.
create or replace function private.scope_ancestors(p_org uuid, p_scope_type text, p_scope_id uuid)
returns table (campus_id uuid, ministry_id uuid, department_id uuid, team_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_scope_type = 'organisation' then return query select null::uuid, null::uuid, null::uuid, null::uuid; return;
  elsif p_scope_type = 'campus' then
    return query select c.id, null::uuid, null::uuid, null::uuid from public.campuses c where c.id = p_scope_id and c.organisation_id = p_org;
  elsif p_scope_type = 'ministry' then
    return query select m.campus_id, m.id, null::uuid, null::uuid from public.ministries m where m.id = p_scope_id and m.organisation_id = p_org;
  elsif p_scope_type = 'department' then
    return query select d.campus_id, d.ministry_id, d.id, null::uuid from public.departments d where d.id = p_scope_id and d.organisation_id = p_org;
  elsif p_scope_type = 'team' then
    return query select t.campus_id, t.ministry_id, t.department_id, t.id from public.teams t where t.id = p_scope_id and t.organisation_id = p_org;
  end if;
end $$;

create or replace function private.has_perm_at_scope(p_org uuid, p_perm text, p_scope_type text, p_scope_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select private.has_perm(p_org, p_perm, a.campus_id, a.ministry_id, a.department_id, a.team_id)
                   from private.scope_ancestors(p_org, p_scope_type, p_scope_id) a), false) $$;

create or replace function private.has_perm_for_team(p_org uuid, p_perm text, p_team uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_perm(t.organisation_id, p_perm, t.campus_id, t.ministry_id, t.department_id, t.id)
  from public.teams t where t.id = p_team and t.organisation_id = p_org $$;

-- Permission over a PERSON: scope matches where the person is (their teams / home campus).
create or replace function private.has_perm_over_member(p_org uuid, p_perm text, p_target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.memberships me
    join public.organisations o on o.id = me.organisation_id and o.status = 'active'
    join public.membership_role_assignments a on a.membership_id = me.id and a.organisation_id = me.organisation_id
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
               where tm.membership_id = tgt.id and tm.status = 'active' and tm.team_id = a.team_id))) ) $$;

-- Is a member inside an audience scope? The lowest non-null level decides; all-null = whole organisation.
create or replace function private.member_in_scope(p_membership uuid, p_campus uuid, p_ministry uuid, p_department uuid, p_team uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_team is not null then exists (select 1 from public.team_memberships tm where tm.membership_id = p_membership and tm.status = 'active' and tm.team_id = p_team)
    when p_department is not null then exists (select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
         where tm.membership_id = p_membership and tm.status = 'active' and t.department_id = p_department)
    when p_ministry is not null then exists (select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
         where tm.membership_id = p_membership and tm.status = 'active' and t.ministry_id = p_ministry)
    when p_campus is not null then exists (select 1 from public.memberships m where m.id = p_membership and m.home_campus_id = p_campus)
         or exists (select 1 from public.team_memberships tm join public.teams t on t.id = tm.team_id
         where tm.membership_id = p_membership and tm.status = 'active' and t.campus_id = p_campus)
    else true end $$;

create or replace function private.directory_shows_teams(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.member_directory_visibility = 'names_and_teams' from public.organisation_settings s where s.organisation_id = p_org), false) $$;

-- Privilege ceiling for ROLE ASSIGNMENT (PERMISSIONS_MATRIX 1.1 rule 5): you can hand out only what you hold,
-- over a scope you cover; Owner needs org.ownership.manage.
create or replace function private.can_grant_role(p_org uuid, p_role uuid, p_scope_type text, p_scope_id uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare r public.roles; a record;
begin
  select * into r from public.roles where id = p_role and archived_at is null and (organisation_id is null or organisation_id = p_org);
  if not found or not (p_scope_type = any (r.assignable_scopes)) then return false; end if;
  if r.system_key = 'owner' and not private.has_perm(p_org, 'org.ownership.manage') then return false; end if;
  select * into a from private.scope_ancestors(p_org, p_scope_type, p_scope_id);
  if not found then return false; end if;
  if not private.has_perm(p_org, 'roles.assign', a.campus_id, a.ministry_id, a.department_id, a.team_id) then return false; end if;
  return not exists (
    select 1 from public.role_permissions rp
    where rp.role_id = p_role
      and not private.has_perm(p_org, rp.permission_key, a.campus_id, a.ministry_id, a.department_id, a.team_id));
end $$;

-- Role-DEFINITION ceiling (PERMISSIONS_MATRIX 1.1 rule 6): without it, anyone holding roles.manage through a custom role
-- could edit their own role to grant themselves anything.
create or replace function private.can_edit_role_permission(p_role uuid, p_permission text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare r public.roles; v_me uuid;
begin
  select * into r from public.roles where id = p_role and organisation_id is not null and archived_at is null;
  if not found or p_permission = 'org.ownership.manage' then return false; end if;
  v_me := private.my_membership_id(r.organisation_id);
  if v_me is null or not private.has_perm(r.organisation_id, 'roles.manage') then return false; end if;
  if exists (select 1 from public.membership_role_assignments a where a.role_id = p_role and a.membership_id = v_me and a.revoked_at is null) then return false; end if;
  return private.has_perm(r.organisation_id, p_permission);       -- caller holds the permission at organisation scope
end $$;

-- Custom roles can never contain org.ownership.manage (also enforced by can_edit_role_permission for clients).
create or replace function private.guard_role_permission() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r public.roles;
begin
  select * into r from public.roles where id = new.role_id;
  if r.organisation_id is not null and new.permission_key = 'org.ownership.manage' then
    raise exception 'org.ownership.manage cannot be part of a custom role' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger role_permissions_guard before insert on public.role_permissions for each row execute function private.guard_role_permission();

-- MFA step-up hook: INERT unless the organisation turns it on (D-027 deferred; no MFA is implemented or tested).
create or replace function private.require_aal2(p_org uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce((select s.require_mfa_for_privileged from public.organisation_settings s where s.organisation_id = p_org), false)
     and coalesce((select auth.jwt())->>'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required' using errcode = '42501';
  end if;
end $$;

grant execute on function
  private.my_org_ids(), private.my_org_array(), private.is_member(uuid), private.my_membership_id(uuid),
  private.has_perm(uuid,text,uuid,uuid,uuid,uuid), private.scope_ancestors(uuid,text,uuid),
  private.has_perm_at_scope(uuid,text,text,uuid), private.has_perm_for_team(uuid,text,uuid),
  private.has_perm_over_member(uuid,text,uuid), private.member_in_scope(uuid,uuid,uuid,uuid,uuid),
  private.directory_shows_teams(uuid), private.can_grant_role(uuid,uuid,text,uuid),
  private.can_edit_role_permission(uuid,text), private.require_aal2(uuid)
  to authenticated, service_role;
