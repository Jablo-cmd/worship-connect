-- M-002: trigger functions and small utilities shared by every table.
set lock_timeout = '10s';
set statement_timeout = '60s';

-- Server-owned timestamp.
create or replace function private.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- organisation_id is immutable: a row can never be moved between tenants.
create or replace function private.forbid_org_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.organisation_id is distinct from old.organisation_id then
    raise exception 'organisation_id is immutable' using errcode = '42501';
  end if;
  return new;
end $$;

-- Optimistic concurrency for collaborative tables.
create or replace function private.bump_row_version() returns trigger
language plpgsql set search_path = '' as $$
begin new.row_version := old.row_version + 1; return new; end $$;

-- Append-only tables: no UPDATE/DELETE from anyone through normal paths.
create or replace function private.block_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin raise exception 'table % is append-only', tg_table_name using errcode = '42501'; end $$;

-- Safe uuid parsing for storage paths and realtime topics (NULL instead of an error).
create or replace function private.try_uuid(p text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin return p::uuid; exception when others then return null; end $$;

-- IANA time zone allow-list. AT TIME ZONE also accepts abbreviations ('EST'), POSIX strings ('UTC+3')
-- and odd names ('Factory'); "does not raise" is NOT validation (spike S-7).
create or replace function private.is_valid_timezone(p text) returns boolean
language sql stable set search_path = '' as $$
  select p is not null
     and (p = 'UTC' or p ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$')
     and p !~ '^(Etc|posix|right)/'
     and exists (select 1 from pg_catalog.pg_timezone_names n where n.name = p)
$$;

grant execute on function private.try_uuid(text), private.is_valid_timezone(text) to authenticated, service_role;
