-- M-021: row-level audit for tables that clients write DIRECTLY under RLS. RPC-only paths (membership status, role
-- assignment, invitations) write explicit domain audit events inside their functions instead, avoiding duplicates.
-- Only allow-listed columns are recorded (never bodies, tokens, notes or contact data).
set lock_timeout = '10s';
set statement_timeout = '60s';

create or replace function private.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare rec jsonb; oldr jsonb; col text; chg jsonb := '{}'::jsonb; v_org uuid; v_res uuid; v_sev text; v_act text;
begin
  rec  := to_jsonb(case when tg_op = 'DELETE' then old else new end);
  oldr := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  foreach col in array tg_argv loop
    if tg_op = 'INSERT' then chg := chg || jsonb_build_object(col, jsonb_build_object('new', rec -> col));
    elsif tg_op = 'DELETE' then chg := chg || jsonb_build_object(col, jsonb_build_object('old', rec -> col));
    elsif (rec -> col) is distinct from (oldr -> col) then
      chg := chg || jsonb_build_object(col, jsonb_build_object('old', oldr -> col, 'new', rec -> col));
    end if;
  end loop;
  if tg_op = 'UPDATE' and chg = '{}'::jsonb then return null; end if;   -- nothing audit-relevant changed
  v_org := nullif(rec ->> 'organisation_id', '')::uuid;
  if v_org is null and tg_table_name = 'role_permissions' then
    select r.organisation_id into v_org from public.roles r where r.id = (rec ->> 'role_id')::uuid;
  end if;
  if tg_table_name = 'organisations' then v_org := (rec ->> 'id')::uuid; end if;
  v_res := coalesce(nullif(rec ->> 'id', '')::uuid, nullif(rec ->> 'organisation_id', '')::uuid, nullif(rec ->> 'role_id', '')::uuid);
  v_sev := case when tg_table_name in ('roles', 'role_permissions') then 'security' else 'notice' end;
  v_act := tg_table_name || '.' || case tg_op when 'INSERT' then 'created' when 'UPDATE' then 'updated' else 'deleted' end;
  perform private.write_audit(v_org, v_act, tg_table_name, v_res, chg, v_sev);
  return null;
end $$;

create trigger organisations_audit        after update on public.organisations        for each row execute function private.audit_row_change('name','status','timezone');
create trigger organisation_settings_audit after update on public.organisation_settings for each row execute function private.audit_row_change('member_directory_visibility','allow_direct_messages','require_mfa_for_privileged','message_retention_days','attendance_retention_months');
create trigger roles_audit                after insert or update on public.roles      for each row execute function private.audit_row_change('name','archived_at','assignable_scopes','show_in_directory');
create trigger role_permissions_audit     after insert or delete on public.role_permissions for each row execute function private.audit_row_change('permission_key');
create trigger team_memberships_audit     after insert or update or delete on public.team_memberships for each row execute function private.audit_row_change('team_id','status');
create trigger campuses_audit             after insert or update on public.campuses     for each row execute function private.audit_row_change('name','archived_at');
create trigger ministries_audit           after insert or update on public.ministries   for each row execute function private.audit_row_change('name','archived_at');
create trigger departments_audit          after insert or update on public.departments  for each row execute function private.audit_row_change('name','archived_at');
create trigger teams_audit                after insert or update on public.teams        for each row execute function private.audit_row_change('name','archived_at');
create trigger files_audit                after update on public.files                  for each row execute function private.audit_row_change('status','scan_status');
