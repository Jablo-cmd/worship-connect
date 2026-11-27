-- M-001: extensions, schemas and default privileges.
-- Spec: RLS_SECURITY_SPECIFICATION.md section 3; DATABASE_MIGRATION_PLAN.md M-001.
set lock_timeout = '10s';
set statement_timeout = '60s';

create extension if not exists pgcrypto   with schema extensions;
create extension if not exists citext     with schema extensions;
create extension if not exists pg_trgm    with schema extensions;
create extension if not exists btree_gist with schema extensions;

-- `private`: SECURITY DEFINER helpers and trigger functions. NEVER exposed through the Data API.
-- `platform`: platform-staff tables. NEVER exposed through the Data API.
create schema if not exists private;
create schema if not exists platform;

revoke all on schema private  from public, anon;
revoke all on schema platform from public, anon, authenticated;
grant usage on schema private  to authenticated, service_role;   -- policies call helpers as the caller
grant usage on schema platform to service_role;

-- New objects are born WITHOUT client privileges (Supabase would otherwise grant to anon/authenticated).
alter default privileges for role postgres in schema public   revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public   revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public   revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema private  revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema platform revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema platform revoke execute on functions from public, anon, authenticated;
