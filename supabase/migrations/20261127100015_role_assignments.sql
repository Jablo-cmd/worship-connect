-- M-015: role assignments (the ONLY way a person gains a permission) and the guards around them.
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.membership_role_assignments (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  membership_id uuid not null,
  role_id uuid not null references public.roles (id),
  scope_type text not null default 'organisation' check (scope_type in ('organisation','campus','ministry','department','team')),
  campus_id uuid, ministry_id uuid, department_id uuid, team_id uuid,
  expires_at timestamptz,
  assigned_by_membership_id uuid,
  revoked_at timestamptz,
  revoked_by_membership_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, id),
  foreign key (organisation_id, membership_id) references public.memberships (organisation_id, id),
  foreign key (organisation_id, campus_id)     references public.campuses (organisation_id, id),
  foreign key (organisation_id, ministry_id)   references public.ministries (organisation_id, id),
  foreign key (organisation_id, department_id) references public.departments (organisation_id, id),
  foreign key (organisation_id, team_id)       references public.teams (organisation_id, id),
  foreign key (organisation_id, assigned_by_membership_id) references public.memberships (organisation_id, id),
  foreign key (organisation_id, revoked_by_membership_id)  references public.memberships (organisation_id, id),
  -- typed scope columns replace a polymorphic scope_id (which cannot carry a foreign key)
  check ( (scope_type = 'organisation' and num_nonnulls(campus_id, ministry_id, department_id, team_id) = 0)
       or (scope_type = 'campus'     and campus_id     is not null and num_nonnulls(ministry_id, department_id, team_id) = 0)
       or (scope_type = 'ministry'   and ministry_id   is not null and num_nonnulls(campus_id, department_id, team_id) = 0)
       or (scope_type = 'department' and department_id is not null and num_nonnulls(campus_id, ministry_id, team_id) = 0)
       or (scope_type = 'team'       and team_id       is not null and num_nonnulls(campus_id, ministry_id, department_id) = 0) ),
  check ((revoked_at is null) = (revoked_by_membership_id is null) or revoked_at is not null)
);
create unique index mra_active_uq on public.membership_role_assignments
  (membership_id, role_id, scope_type, coalesce(campus_id, ministry_id, department_id, team_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where revoked_at is null;
-- Hot path:
create index mra_membership_active_idx on public.membership_role_assignments (membership_id) where revoked_at is null;
create index mra_org_role_idx          on public.membership_role_assignments (organisation_id, role_id);
alter table public.membership_role_assignments enable row level security;
alter table public.membership_role_assignments force row level security;
create trigger mra_set_updated_at before update on public.membership_role_assignments for each row execute function private.set_updated_at();
create trigger mra_forbid_org_change before update on public.membership_role_assignments
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();

-- A role must be global or belong to the SAME organisation (an FK to a nullable-org row cannot express this),
-- and the scope must be one the role may be assigned at.
create or replace function private.check_role_org() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r public.roles;
begin
  select * into r from public.roles where id = new.role_id;
  if not found or (r.organisation_id is not null and r.organisation_id <> new.organisation_id) then
    raise exception 'role is not available in this organisation' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    if r.archived_at is not null then raise exception 'role is archived' using errcode = '23514'; end if;
    if not (new.scope_type = any (r.assignable_scopes)) then
      raise exception 'role % cannot be assigned at scope %', r.system_key, new.scope_type using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger mra_check_role_org before insert or update of role_id, scope_type on public.membership_role_assignments
  for each row execute function private.check_role_org();

-- Every active membership gets the baseline `member` role (auditable if later removed).
create or replace function private.assign_member_role() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'active' then
    insert into public.membership_role_assignments (organisation_id, membership_id, role_id)
    select new.organisation_id, new.id, r.id from public.roles r where r.system_key = 'member'
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger memberships_assign_member_role after insert on public.memberships
  for each row execute function private.assign_member_role();

-- Last-owner invariant: an organisation must always keep at least one ACTIVE Owner.
create or replace function private.active_owner_count(p_org uuid, p_excluding_membership uuid default null) returns integer
language sql stable security definer set search_path = '' as $$
  select count(distinct a.membership_id)::integer
  from public.membership_role_assignments a
  join public.roles r on r.id = a.role_id and r.system_key = 'owner'
  join public.memberships m on m.id = a.membership_id and m.status = 'active'
  where a.organisation_id = p_org and a.revoked_at is null and (a.expires_at is null or a.expires_at > now())
    and (p_excluding_membership is null or a.membership_id <> p_excluding_membership)
$$;

create or replace function private.guard_last_owner_assignment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare is_owner boolean;
begin
  select exists (select 1 from public.roles r where r.id = old.role_id and r.system_key = 'owner') into is_owner;
  if is_owner and old.revoked_at is null and new.revoked_at is not null
     and private.active_owner_count(old.organisation_id, old.membership_id) < 1 then
    raise exception 'last_owner: an organisation must keep at least one active Owner' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger mra_guard_last_owner before update of revoked_at on public.membership_role_assignments
  for each row execute function private.guard_last_owner_assignment();

-- Membership status machine + last-owner protection + lifecycle history.
create or replace function private.guard_membership_status() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if not ((old.status = 'active'    and new.status in ('suspended','removed'))
         or (old.status = 'suspended' and new.status in ('active','removed'))
         or (old.status = 'removed'   and new.status = 'active')) then
      raise exception 'illegal membership transition % -> %', old.status, new.status using errcode = '23514';
    end if;
    if old.status = 'active' and new.status <> 'active' and private.active_owner_count(old.organisation_id, old.id) < 1
       and exists (select 1 from public.membership_role_assignments a join public.roles r on r.id = a.role_id and r.system_key = 'owner'
                   where a.membership_id = old.id and a.revoked_at is null) then
      raise exception 'last_owner: an organisation must keep at least one active Owner' using errcode = '42501';
    end if;
    new.status_changed_at := now();
  end if;
  return new;
end $$;
create trigger memberships_guard_status before update of status on public.memberships
  for each row execute function private.guard_membership_status();

create or replace function private.record_membership_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_reason text;
begin
  begin v_reason := nullif(current_setting('app.status_reason', true), ''); exception when others then v_reason := null; end;
  insert into public.membership_status_events (organisation_id, membership_id, from_status, to_status, reason, actor_user_id)
  values (new.organisation_id, new.id, case when tg_op = 'UPDATE' then old.status end, new.status, left(v_reason, 500), (select auth.uid()));
  return new;
end $$;
create trigger memberships_record_status_ins after insert on public.memberships for each row execute function private.record_membership_status();
create trigger memberships_record_status_upd after update of status on public.memberships
  for each row when (old.status is distinct from new.status) execute function private.record_membership_status();
