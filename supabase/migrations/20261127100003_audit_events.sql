-- M-003: append-only, monthly-partitioned audit log and the only writer function.
-- Spec: DATABASE_SCHEMA.md section L; DATABASE_ARCHITECTURE.md section 10.
set lock_timeout = '10s';
set statement_timeout = '60s';

create table public.audit_events (
  id                  bigint generated always as identity,
  occurred_at         timestamptz not null default now(),
  organisation_id     uuid,            -- deliberately NO foreign key: history must outlive tenant purge; NULL = platform event
  actor_user_id       uuid,            -- no FK (same reason)
  actor_membership_id uuid,
  actor_type          text not null check (actor_type in ('user','system','service','platform_support','platform_admin')),
  action              text not null check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  resource_type       text,
  resource_id         uuid,
  severity            text not null default 'info' check (severity in ('info','notice','security')),
  changes             jsonb,           -- allow-listed {column: {old,new}} only; never bodies, tokens, notes, contact data
  metadata            jsonb,           -- safe context (counts, ids, reason codes)
  request_id          text,
  client_ip_hash      bytea,           -- keyed hash, never the raw address (D-031); populated by the application layer
  primary key (id, occurred_at)
) partition by range (occurred_at);

create index audit_events_org_time_idx      on public.audit_events (organisation_id, occurred_at desc);
create index audit_events_resource_idx      on public.audit_events (organisation_id, resource_type, resource_id, occurred_at desc);
create index audit_events_actor_idx         on public.audit_events (organisation_id, actor_membership_id, occurred_at desc);
create index audit_events_occurred_brin_idx on public.audit_events using brin (occurred_at);

alter table public.audit_events enable row level security;
alter table public.audit_events force row level security;

create trigger audit_events_block_mutation
  before update or delete on public.audit_events
  for each row execute function private.block_mutation();
-- (TRUNCATE is revoked from every client role; retention drops whole partitions.)

-- Partitions must exist BEFORE they are needed: an insert with no matching partition FAILS, and audit writes happen
-- inside business transactions (spike S-7 extras). A DEFAULT partition is a safety net; alert if it is non-empty.
create table public.audit_events_default partition of public.audit_events default;

create or replace function private.ensure_audit_partitions(p_months_ahead integer default 3)
returns integer language plpgsql set search_path = '' as $$
declare m date; made integer := 0; part text;
begin
  for i in 0 .. p_months_ahead loop
    m := (date_trunc('month', now()) + make_interval(months => i))::date;
    part := 'audit_events_' || to_char(m, 'YYYY_MM');
    if to_regclass('public.' || part) is null then
      execute format('create table public.%I partition of public.audit_events for values from (%L) to (%L)',
                     part, m, (m + interval '1 month')::date);
      made := made + 1;
    end if;
  end loop;
  return made;
end $$;
select private.ensure_audit_partitions(6);

-- The ONLY way to write audit rows. Not executable by any client role.
create or replace function private.write_audit(
  p_org uuid, p_action text, p_resource_type text default null, p_resource_id uuid default null,
  p_changes jsonb default null, p_severity text default 'info', p_metadata jsonb default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_req text;
begin
  begin v_req := (current_setting('request.headers', true)::jsonb)->>'x-request-id'; exception when others then v_req := null; end;
  insert into public.audit_events (organisation_id, actor_user_id, actor_membership_id, actor_type, action,
                                   resource_type, resource_id, severity, changes, metadata, request_id)
  values (p_org, v_uid,
          case when v_uid is not null and p_org is not null
               then (select m.id from public.memberships m where m.organisation_id = p_org and m.user_id = v_uid) end,
          case when v_uid is null then 'system' else 'user' end,
          p_action, p_resource_type, p_resource_id, p_severity, p_changes, p_metadata, v_req);
end $$;
-- (memberships does not exist yet when this migration runs; the function body is only resolved at call time.)

revoke all on public.audit_events from anon, authenticated;
revoke execute on function private.write_audit(uuid,text,text,uuid,jsonb,text,jsonb) from public, anon, authenticated;
