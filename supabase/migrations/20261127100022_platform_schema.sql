-- M-022: platform-staff schema. NOT exposed through the Data API; no client grants. Platform staff reach tenant data
-- only through narrow audited functions and owner-created, time-boxed support grants (D-036).
set lock_timeout = '10s';
set statement_timeout = '60s';

create table platform.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role text not null check (role in ('support','admin','superadmin')),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  disabled_at timestamptz
);
create table platform.support_access_grants (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  platform_user_id uuid not null references platform.admins (user_id),
  granted_by_membership_id uuid,
  level text not null check (level in ('metadata','content_read')),
  reason text not null check (char_length(reason) between 5 and 500),
  ticket_ref text check (ticket_ref is null or char_length(ticket_ref) <= 100),
  break_glass boolean not null default false,
  second_approver_user_id uuid references platform.admins (user_id),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, granted_by_membership_id) references public.memberships (organisation_id, id),
  check (expires_at > starts_at and expires_at <= starts_at + interval '72 hours'),
  check (not break_glass or second_approver_user_id is not null),
  check (break_glass or granted_by_membership_id is not null)
);
create index support_access_grants_org_idx on platform.support_access_grants (organisation_id, expires_at desc);
create table platform.takedown_requests (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid references public.organisations (id),
  reporter_name text, reporter_contact text, claim_text text not null,
  target_file_id uuid references public.files (id),
  status text not null default 'received' check (status in ('received','reviewing','content_disabled','rejected','reinstated')),
  received_at timestamptz not null default now(), actioned_by uuid references platform.admins (user_id), actioned_at timestamptz, notes text
);
create table platform.organisation_status_log (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id),
  from_status text, to_status text not null, reason text, actor_user_id uuid, occurred_at timestamptz not null default now()
);
do $$ declare t text; begin
  foreach t in array array['admins','support_access_grants','takedown_requests','organisation_status_log'] loop
    execute format('alter table platform.%I enable row level security', t);
    execute format('alter table platform.%I force row level security', t);
    execute format('revoke all on platform.%I from public, anon, authenticated', t);
  end loop;
end $$;
create trigger organisation_status_log_block before update or delete on platform.organisation_status_log for each row execute function private.block_mutation();

-- Called by the platform console's SERVER code (service role) after it has authenticated the staff member.
-- p_actor is verified here against platform.admins; the status change is logged and audited.
create or replace function platform.set_organisation_status(p_actor uuid, p_org uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_from text;
begin
  if p_status not in ('active','suspended','closing','closed') then raise exception 'invalid status' using errcode = '22023'; end if;
  if not exists (select 1 from platform.admins a where a.user_id = p_actor and a.disabled_at is null and a.role in ('admin','superadmin')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select status into v_from from public.organisations where id = p_org for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  update public.organisations set status = p_status, status_changed_at = now() where id = p_org;
  insert into platform.organisation_status_log (organisation_id, from_status, to_status, reason, actor_user_id) values (p_org, v_from, p_status, left(p_reason, 500), p_actor);
  insert into public.audit_events (organisation_id, actor_user_id, actor_type, action, resource_type, resource_id, severity, changes)
  values (p_org, p_actor, 'platform_admin', 'organisation.status_changed', 'organisation', p_org, 'security',
          jsonb_build_object('status', jsonb_build_object('old', v_from, 'new', p_status)));
end $$;
revoke all on function platform.set_organisation_status(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function platform.set_organisation_status(uuid,uuid,text,text) to service_role;
grant usage on schema platform to service_role;
grant select, insert, update on all tables in schema platform to service_role;

-- Owner-created, time-boxed support access (visible in the audit log to every Owner).
create or replace function public.grant_support_access(p_org uuid, p_platform_user uuid, p_level text, p_reason text, p_hours integer default 24)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.my_membership_id(p_org); v_id uuid;
begin
  if v_me is null or not private.has_perm(p_org, 'org.ownership.manage') or p_hours not between 1 and 72
     or not exists (select 1 from platform.admins a where a.user_id = p_platform_user and a.disabled_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform private.require_aal2(p_org);
  insert into platform.support_access_grants (organisation_id, platform_user_id, granted_by_membership_id, level, reason, expires_at)
  values (p_org, p_platform_user, v_me, p_level, p_reason, now() + make_interval(hours => p_hours)) returning id into v_id;
  perform private.write_audit(p_org, 'support_access.granted', 'support_access_grant', v_id, jsonb_build_object('level', jsonb_build_object('new', p_level)), 'security');
  return v_id;
end $$;
create or replace function public.revoke_support_access(p_grant uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare g platform.support_access_grants;
begin
  select * into g from platform.support_access_grants where id = p_grant and revoked_at is null for update;
  if not found or not private.has_perm(g.organisation_id, 'org.ownership.manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update platform.support_access_grants set revoked_at = now() where id = g.id;
  perform private.write_audit(g.organisation_id, 'support_access.revoked', 'support_access_grant', g.id, null, 'security');
end $$;
grant execute on function public.grant_support_access(uuid,uuid,text,text,integer), public.revoke_support_access(uuid) to authenticated;
