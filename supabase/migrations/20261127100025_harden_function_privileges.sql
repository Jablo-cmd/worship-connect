-- M-025: CORRECTIVE (found by catalogue tests CAT-03b/03c). M-001 revoked default function privileges only per schema,
-- which cannot remove PostgreSQL's GLOBAL default (EXECUTE granted to PUBLIC), so every function created afterwards was
-- executable by anon/PUBLIC. Fix: remove the global default, revoke on all existing functions, then re-grant ONLY the
-- allow-listed helpers and RPCs. Also enable RLS on audit partitions (a partition queried directly does not inherit the
-- parent's policies) and make the partition maintenance function do the same.
set lock_timeout = '10s';
set statement_timeout = '60s';

alter default privileges for role postgres revoke execute on functions from public;                  -- GLOBAL default
alter default privileges for role postgres in schema public   revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema private  revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema platform revoke execute on functions from public, anon, authenticated;

revoke execute on all functions in schema public   from public, anon;     -- RPCs keep their explicit grants to authenticated
revoke execute on all functions in schema private  from public, anon, authenticated;
revoke execute on all functions in schema platform from public, anon, authenticated;

-- Allow-list: helpers that RLS policies / RPCs call as the signed-in user (and the service role).
grant execute on function
  private.try_uuid(text), private.is_valid_timezone(text),
  private.my_org_ids(), private.my_org_array(), private.is_member(uuid), private.my_membership_id(uuid),
  private.has_perm(uuid,text,uuid,uuid,uuid,uuid), private.scope_ancestors(uuid,text,uuid),
  private.has_perm_at_scope(uuid,text,text,uuid), private.has_perm_for_team(uuid,text,uuid),
  private.has_perm_over_member(uuid,text,uuid), private.member_in_scope(uuid,uuid,uuid,uuid,uuid),
  private.directory_shows_teams(uuid), private.can_grant_role(uuid,uuid,text,uuid),
  private.can_edit_role_permission(uuid,text), private.require_aal2(uuid),
  private.can_read_file(uuid), private.can_upload_registered_object(text), private.can_read_topic(text)
  to authenticated, service_role;
grant execute on function private.ensure_audit_partitions(integer) to service_role;
grant execute on function platform.set_organisation_status(uuid,uuid,text,text) to service_role;

-- Audit partitions: RLS + FORCE on every partition (no policies = deny; they also have no client grants).
create or replace function private.ensure_audit_partitions(p_months_ahead integer default 3)
returns integer language plpgsql set search_path = '' as $$
declare m date; made integer := 0; part text;
begin
  for i in 0 .. p_months_ahead loop
    m := (date_trunc('month', now()) + make_interval(months => i))::date;
    part := 'audit_events_' || to_char(m, 'YYYY_MM');
    if to_regclass('public.' || part) is null then
      execute format('create table public.%I partition of public.audit_events for values from (%L) to (%L)', part, m, (m + interval '1 month')::date);
      execute format('alter table public.%I enable row level security', part);
      execute format('alter table public.%I force row level security', part);
      made := made + 1;
    end if;
  end loop;
  return made;
end $$;
revoke execute on function private.ensure_audit_partitions(integer) from public, anon, authenticated;
grant  execute on function private.ensure_audit_partitions(integer) to service_role;
do $$ declare r record; begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r','p') and c.relispartition and c.relname like 'audit_events\_%' loop
    execute format('alter table public.%I enable row level security', r.relname);
    execute format('alter table public.%I force row level security', r.relname);
    execute format('revoke all on public.%I from anon, authenticated', r.relname);
  end loop;
end $$;
