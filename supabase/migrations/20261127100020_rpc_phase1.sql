-- M-020: the privileged write paths for Phase 1 (RLS_SECURITY_SPECIFICATION.md section 11). All are SECURITY DEFINER with
-- search_path = '', derive the organisation from TARGET ROWS (never trust a client-supplied tenant), return generic errors
-- (SQLSTATE 42501 'forbidden') and write audit events. Execute is granted to `authenticated` only (never anon).
set lock_timeout = '10s';
set statement_timeout = '60s';

-- ------------------------------------------------------------------ create_organisation
create or replace function public.create_organisation(
  p_name text, p_slug text, p_timezone text, p_country_code text default null, p_contact_email text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_org uuid; v_mem uuid; v_name text; v_verified boolean;
begin
  if v_uid is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select (email_confirmed_at is not null) into v_verified from auth.users where id = v_uid;
  if not coalesce(v_verified, false) then raise exception 'email_not_verified' using errcode = '42501'; end if;
  if (select count(*) from public.organisations o where o.created_by = v_uid) >= 5 then
    raise exception 'quota_exceeded' using errcode = '53400';            -- abuse guard, not a commercial limit
  end if;
  select display_name into v_name from public.profiles where id = v_uid;
  -- One transaction: any failure rolls back EVERYTHING (no orphan organisations).
  insert into public.organisations (name, slug, timezone, country_code, contact_email, created_by)
  values (btrim(p_name), lower(btrim(p_slug)), p_timezone, upper(p_country_code), p_contact_email, v_uid) returning id into v_org;
  insert into public.organisation_settings (organisation_id) values (v_org);
  insert into public.memberships (organisation_id, user_id, display_name) values (v_org, v_uid, coalesce(v_name, 'Owner')) returning id into v_mem;
  insert into public.membership_role_assignments (organisation_id, membership_id, role_id, assigned_by_membership_id)
    select v_org, v_mem, r.id, v_mem from public.roles r where r.system_key = 'owner';
  perform private.write_audit(v_org, 'organisation.created', 'organisation', v_org, null, 'notice');
  return v_org;
end $$;

-- ------------------------------------------------------------------ my_workspaces
-- Lets a SUSPENDED user learn their own status without any read policy on the organisation.
create or replace function public.my_workspaces()
returns table (organisation_id uuid, name text, slug text, my_status text)
language sql stable security definer set search_path = '' as $$
  select m.organisation_id, o.name, o.slug::text, m.status
  from public.memberships m join public.organisations o on o.id = m.organisation_id
  where m.user_id = (select auth.uid()) and m.status in ('active','suspended') $$;

-- ------------------------------------------------------------------ invitations
create or replace function public.create_invitation(
  p_org uuid, p_email text, p_role uuid default null, p_scope_type text default 'organisation', p_scope_id uuid default null,
  p_team_ids uuid[] default '{}', p_message text default null)
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.my_membership_id(p_org);
        v_token text := encode(extensions.gen_random_bytes(32), 'hex');
        v_id uuid; v_exp timestamptz := now() + interval '14 days'; a record; t uuid;
begin
  if v_me is null then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into a from private.scope_ancestors(p_org, p_scope_type, p_scope_id);
  if not found or not private.has_perm(p_org, 'members.invite', a.campus_id, a.ministry_id, a.department_id, a.team_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_role is not null and not private.can_grant_role(p_org, p_role, p_scope_type, p_scope_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_team_ids is not null then
    foreach t in array p_team_ids loop
      if not private.has_perm_for_team(p_org, 'members.invite', t) then raise exception 'forbidden' using errcode = '42501'; end if;
    end loop;
  end if;
  if exists (select 1 from public.memberships m join auth.users u on u.id = m.user_id
             where m.organisation_id = p_org and m.status = 'active' and lower(u.email) = lower(btrim(p_email))) then
    raise exception 'already_member' using errcode = '23505';
  end if;
  insert into public.invitations (organisation_id, email, role_id, scope_type, campus_id, ministry_id, department_id, team_id,
                                  invited_by_membership_id, personal_message, expires_at)
  values (p_org, btrim(p_email), p_role, p_scope_type,
          case when p_scope_type = 'campus'     then p_scope_id end, case when p_scope_type = 'ministry' then p_scope_id end,
          case when p_scope_type = 'department' then p_scope_id end, case when p_scope_type = 'team'     then p_scope_id end,
          v_me, left(p_message, 500), v_exp) returning id into v_id;
  insert into public.invitation_tokens (invitation_id, organisation_id, token_hash) values (v_id, p_org, extensions.digest(v_token, 'sha256'));
  if p_team_ids is not null and cardinality(p_team_ids) > 0 then
    insert into public.invitation_teams (organisation_id, invitation_id, team_id) select p_org, v_id, x from unnest(p_team_ids) x;
  end if;
  perform private.write_audit(p_org, 'invitation.created', 'invitation', v_id, null, 'notice');
  return query select v_id, v_token, v_exp;          -- raw token returned ONCE to the inviter's server action; only its hash is stored
end $$;

create or replace function public.revoke_invitation(p_invitation uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.invitations;
begin
  select * into i from public.invitations where id = p_invitation and status = 'pending' for update;
  if not found or private.my_membership_id(i.organisation_id) is null
     or not (i.invited_by_membership_id = private.my_membership_id(i.organisation_id)
             or private.has_perm_at_scope(i.organisation_id, 'members.invite', i.scope_type, coalesce(i.campus_id, i.ministry_id, i.department_id, i.team_id))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.invitations set status = 'revoked', revoked_at = now(), revoked_by_membership_id = private.my_membership_id(i.organisation_id) where id = i.id;
  perform private.write_audit(i.organisation_id, 'invitation.revoked', 'invitation', i.id, null, 'notice');
end $$;

-- Re-issue the token (old token stops working). Throttled.
create or replace function public.resend_invitation(p_invitation uuid)
returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare i public.invitations; v_token text := encode(extensions.gen_random_bytes(32), 'hex'); v_exp timestamptz := now() + interval '14 days';
begin
  select * into i from public.invitations where id = p_invitation and status = 'pending' for update;
  if not found or private.my_membership_id(i.organisation_id) is null
     or not (i.invited_by_membership_id = private.my_membership_id(i.organisation_id)
             or private.has_perm_at_scope(i.organisation_id, 'members.invite', i.scope_type, coalesce(i.campus_id, i.ministry_id, i.department_id, i.team_id))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if i.last_sent_at > now() - interval '1 minute' or i.send_count >= 10 then raise exception 'throttled' using errcode = '53400'; end if;
  update public.invitation_tokens it set token_hash = extensions.digest(v_token, 'sha256') where it.invitation_id = i.id;
  update public.invitations set send_count = send_count + 1, last_sent_at = now(), expires_at = v_exp where id = i.id;
  perform private.write_audit(i.organisation_id, 'invitation.resent', 'invitation', i.id, null, 'info');
  return query select i.id, v_token, v_exp;
end $$;

-- Shared validation for preview/accept: ONE generic error for unknown, expired, revoked, used, wrong e-mail, unverified e-mail.
create or replace function private.resolve_invitation(p_token text, p_lock boolean) returns public.invitations
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_email text; v_verified boolean; v_inv public.invitations;
begin
  if v_uid is null or p_token is null or char_length(p_token) > 200 then raise exception 'invalid_invitation' using errcode = '22023'; end if;
  select lower(email), (email_confirmed_at is not null) into v_email, v_verified from auth.users where id = v_uid;
  if p_lock then
    select i.* into v_inv from public.invitations i join public.invitation_tokens t on t.invitation_id = i.id
     where t.token_hash = extensions.digest(p_token, 'sha256') and i.status = 'pending' for update of i;
  else
    select i.* into v_inv from public.invitations i join public.invitation_tokens t on t.invitation_id = i.id
     where t.token_hash = extensions.digest(p_token, 'sha256') and i.status = 'pending';
  end if;
  if not found or v_inv.expires_at <= now() or not coalesce(v_verified, false) or lower(v_inv.email::text) <> v_email
     or not exists (select 1 from public.organisations o where o.id = v_inv.organisation_id and o.status = 'active') then
    raise exception 'invalid_invitation' using errcode = '22023';
  end if;
  return v_inv;
end $$;

create or replace function public.get_invitation_preview(p_token text)
returns table (organisation_name text, inviter_display_name text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_inv public.invitations;
begin
  v_inv := private.resolve_invitation(p_token, false);
  return query select o.name, m.display_name, v_inv.expires_at
    from public.organisations o join public.memberships m on m.id = v_inv.invited_by_membership_id where o.id = v_inv.organisation_id;
end $$;

create or replace function public.accept_invitation(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_inv public.invitations; v_mem uuid; v_ex public.memberships;
begin
  v_inv := private.resolve_invitation(p_token, true);
  select * into v_ex from public.memberships where organisation_id = v_inv.organisation_id and user_id = v_uid for update;
  if found and v_ex.status = 'suspended' then raise exception 'invalid_invitation' using errcode = '22023';   -- a suspension cannot be bypassed by re-inviting
  elsif found and v_ex.status = 'removed' then
    update public.memberships set status = 'active' where id = v_ex.id returning id into v_mem;                -- re-activate the SAME row (stable identity)
    insert into public.membership_role_assignments (organisation_id, membership_id, role_id)
      select v_inv.organisation_id, v_mem, r.id from public.roles r where r.system_key = 'member' on conflict do nothing;
  elsif found then v_mem := v_ex.id;                                                                           -- already active: idempotent
  else
    insert into public.memberships (organisation_id, user_id, display_name)
      select v_inv.organisation_id, v_uid, p.display_name from public.profiles p where p.id = v_uid returning id into v_mem;   -- trigger assigns `member`
  end if;
  if v_inv.role_id is not null then                    -- ceiling was checked at creation; re-validate availability now
    insert into public.membership_role_assignments (organisation_id, membership_id, role_id, scope_type, campus_id, ministry_id, department_id, team_id, assigned_by_membership_id)
    select v_inv.organisation_id, v_mem, r.id, v_inv.scope_type, v_inv.campus_id, v_inv.ministry_id, v_inv.department_id, v_inv.team_id, v_inv.invited_by_membership_id
    from public.roles r where r.id = v_inv.role_id and r.archived_at is null and (r.organisation_id is null or r.organisation_id = v_inv.organisation_id)
    on conflict do nothing;
  end if;
  insert into public.team_memberships (organisation_id, team_id, membership_id, added_by_membership_id)
    select it.organisation_id, it.team_id, v_mem, v_inv.invited_by_membership_id from public.invitation_teams it where it.invitation_id = v_inv.id
    on conflict do nothing;
  update public.invitations set status = 'accepted', accepted_at = now(), accepted_by_user_id = v_uid, accepted_membership_id = v_mem where id = v_inv.id;
  perform private.write_audit(v_inv.organisation_id, 'invitation.accepted', 'invitation', v_inv.id, null, 'notice');
  return v_mem;
end $$;

-- ------------------------------------------------------------------ membership lifecycle
create or replace function public.set_membership_status(p_membership uuid, p_to text, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_user uuid; v_from text; v_target_is_owner boolean;
begin
  select organisation_id, user_id, status into v_org, v_user, v_from from public.memberships where id = p_membership;
  if v_org is null or p_to not in ('active','suspended','removed') or v_user = (select auth.uid())
     or not private.has_perm_over_member(v_org, 'members.suspend', p_membership) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select exists (select 1 from public.membership_role_assignments a join public.roles r on r.id = a.role_id and r.system_key = 'owner'
                 where a.membership_id = p_membership and a.revoked_at is null) into v_target_is_owner;
  if v_target_is_owner then
    if not private.has_perm(v_org, 'org.ownership.manage') then raise exception 'forbidden' using errcode = '42501'; end if;
    perform private.require_aal2(v_org);                      -- inert unless the organisation enables it (D-027 deferred)
  end if;
  perform set_config('app.status_reason', coalesce(left(p_reason, 500), ''), true);
  update public.memberships set status = p_to where id = p_membership;          -- triggers: legal transitions, last-owner guard, history
  perform private.write_audit(v_org, 'membership.' || p_to, 'membership', p_membership,
                              jsonb_build_object('status', jsonb_build_object('old', v_from, 'new', p_to)), 'security');
  begin    -- tell connected clients (id-only); the database is the source of truth, so a failure here must not fail the change
    perform realtime.send(jsonb_build_object('type', 'membership.revoked', 'status', p_to), 'membership.revoked',
                          'org:' || v_org || ':me:' || p_membership, true);
  exception when others then null;
  end;
end $$;

create or replace function public.leave_organisation(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.my_membership_id(p_org);
begin
  if v_me is null then raise exception 'forbidden' using errcode = '42501'; end if;
  perform set_config('app.status_reason', 'left', true);
  update public.memberships set status = 'removed' where id = v_me;           -- last-owner trigger applies
  perform private.write_audit(p_org, 'membership.left', 'membership', v_me, null, 'notice');
end $$;

-- ------------------------------------------------------------------ roles
create or replace function public.assign_role(
  p_membership uuid, p_role uuid, p_scope_type text default 'organisation', p_scope_id uuid default null, p_expires_at timestamptz default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_target_user uuid; v_id uuid;
begin
  select organisation_id, user_id into v_org, v_target_user from public.memberships where id = p_membership and status = 'active';   -- tenant from the TARGET row
  if v_org is null or not private.is_member(v_org) or v_target_user = (select auth.uid())                                      -- no self-assignment
     or not private.can_grant_role(v_org, p_role, p_scope_type, p_scope_id) then                                                -- privilege ceiling
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (select 1 from public.roles r where r.id = p_role and r.system_key = 'owner') then perform private.require_aal2(v_org); end if;
  insert into public.membership_role_assignments (organisation_id, membership_id, role_id, scope_type, campus_id, ministry_id, department_id, team_id, expires_at, assigned_by_membership_id)
  values (v_org, p_membership, p_role, p_scope_type,
          case when p_scope_type = 'campus'     then p_scope_id end, case when p_scope_type = 'ministry' then p_scope_id end,
          case when p_scope_type = 'department' then p_scope_id end, case when p_scope_type = 'team'     then p_scope_id end,
          p_expires_at, private.my_membership_id(v_org)) returning id into v_id;
  perform private.write_audit(v_org, 'role.assigned', 'membership_role_assignment', v_id,
                              jsonb_build_object('role_id', p_role, 'scope_type', p_scope_type), 'security');
  return v_id;
end $$;

create or replace function public.revoke_role(p_assignment uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.membership_role_assignments; v_target_user uuid;
begin
  select * into a from public.membership_role_assignments where id = p_assignment and revoked_at is null for update;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  select user_id into v_target_user from public.memberships where id = a.membership_id;
  if not private.is_member(a.organisation_id) or v_target_user = (select auth.uid())
     or not private.can_grant_role(a.organisation_id, a.role_id, a.scope_type, coalesce(a.campus_id, a.ministry_id, a.department_id, a.team_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (select 1 from public.roles r where r.id = a.role_id and r.system_key = 'owner') then perform private.require_aal2(a.organisation_id); end if;
  update public.membership_role_assignments set revoked_at = now(), revoked_by_membership_id = private.my_membership_id(a.organisation_id) where id = a.id;   -- last-owner trigger applies
  perform private.write_audit(a.organisation_id, 'role.revoked', 'membership_role_assignment', a.id, jsonb_build_object('role_id', a.role_id), 'security');
end $$;

create or replace function public.transfer_ownership(p_org uuid, p_to_membership uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid := private.my_membership_id(p_org); v_owner uuid;
begin
  if v_me is null or not private.has_perm(p_org, 'org.ownership.manage') or p_to_membership = v_me
     or not exists (select 1 from public.memberships m where m.id = p_to_membership and m.organisation_id = p_org and m.status = 'active') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform private.require_aal2(p_org);
  select id into v_owner from public.roles where system_key = 'owner';
  insert into public.membership_role_assignments (organisation_id, membership_id, role_id, assigned_by_membership_id)
    values (p_org, p_to_membership, v_owner, v_me) on conflict do nothing;                         -- new Owner first, so the last-owner guard holds
  update public.membership_role_assignments set revoked_at = now(), revoked_by_membership_id = v_me
    where organisation_id = p_org and membership_id = v_me and role_id = v_owner and revoked_at is null;
  perform private.write_audit(p_org, 'ownership.transferred', 'membership', p_to_membership, null, 'security');
end $$;

-- ------------------------------------------------------------------ files
create or replace function public.register_file(p_org uuid, p_filename text, p_mime text, p_size bigint, p_purpose text)
returns table (file_id uuid, storage_path text)
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid(); v_safe text; v_path text; v_uid uuid := (select auth.uid());
begin
  if not private.is_member(p_org) then raise exception 'forbidden' using errcode = '42501'; end if;
  -- abuse guards (technical, not commercial; entitlements come later - PRD section 10)
  if (select count(*) from public.files f where f.uploaded_by_user_id = v_uid and f.status = 'pending_upload') >= 20
     or (select count(*) from public.files f where f.uploaded_by_user_id = v_uid and f.created_at > now() - interval '1 day') >= 200 then
    raise exception 'quota_exceeded' using errcode = '53400';
  end if;
  v_safe := left(regexp_replace(coalesce(nullif(btrim(p_filename), ''), 'file'), '[^A-Za-z0-9._-]', '_', 'g'), 120);
  v_path := p_org::text || '/' || v_id::text || '/' || v_safe;
  insert into public.files (id, organisation_id, uploaded_by_user_id, storage_path, original_filename, mime_type, size_bytes, purpose)
  values (v_id, p_org, v_uid, v_path, left(btrim(p_filename), 255), p_mime, p_size, p_purpose);
  return query select v_id, v_path;
end $$;

-- Soft delete only; a server job removes the object and row after retention. files.manage = delete/quarantine, never read.
create or replace function public.delete_file(p_file uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.files;
begin
  select * into f from public.files where id = p_file;
  if not found or not private.is_member(f.organisation_id)
     or not (f.uploaded_by_user_id = (select auth.uid()) or private.has_perm(f.organisation_id, 'files.manage')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.files set status = 'deleted', deleted_at = now() where id = f.id;
  perform private.write_audit(f.organisation_id, 'file.deleted', 'file', f.id, null, 'notice');
end $$;

-- ------------------------------------------------------------------ execute grants (anon gets none)
grant execute on function
  public.create_organisation(text,text,text,text,text), public.my_workspaces(),
  public.create_invitation(uuid,text,uuid,text,uuid,uuid[],text), public.revoke_invitation(uuid), public.resend_invitation(uuid),
  public.get_invitation_preview(text), public.accept_invitation(text),
  public.set_membership_status(uuid,text,text), public.leave_organisation(uuid),
  public.assign_role(uuid,uuid,text,uuid,timestamptz), public.revoke_role(uuid), public.transfer_ownership(uuid,uuid),
  public.register_file(uuid,text,text,bigint,text), public.delete_file(uuid)
  to authenticated;
revoke execute on function private.resolve_invitation(text,boolean) from public, anon, authenticated;
