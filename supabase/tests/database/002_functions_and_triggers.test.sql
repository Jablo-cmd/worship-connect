-- DEF-*/INT-*/INV-*: behaviours that need direct SQL (expiry, hostile search_path, trigger guards, append-only audit).
-- Fixtures are created inside the transaction and rolled back. Requires the synthetic seed users (supabase/seed.sql).
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- ------------------------------------------------------------------ fixtures (as the migration owner)
insert into public.organisations (id, name, slug, timezone) values
  ('b0000000-0000-4000-8000-0000000000a1', 'Fixture X', 'fixture-x', 'UTC'),
  ('b0000000-0000-4000-8000-0000000000a2', 'Fixture Y', 'fixture-y', 'UTC');
insert into public.memberships (id, organisation_id, user_id, display_name) values
  ('c0000000-0000-4000-8000-0000000000a1', 'b0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-000000000001', 'Alice X'),
  ('c0000000-0000-4000-8000-0000000000a2', 'b0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-000000000001', 'Alice Y'),
  ('c0000000-0000-4000-8000-0000000000a3', 'b0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-000000000004', 'Dan X');
insert into public.membership_role_assignments (organisation_id, membership_id, role_id)
  select m.organisation_id, m.id, r.id from public.memberships m join public.roles r on r.system_key = 'owner' where m.display_name in ('Alice X', 'Alice Y');
insert into public.policy_acceptances (organisation_id, membership_id, policy_key, policy_version)
  values ('b0000000-0000-4000-8000-0000000000a1', 'c0000000-0000-4000-8000-0000000000a1', 'terms', 'v1');   -- a row, so the append-only trigger has something to block
insert into public.campuses (id, organisation_id, name) values
  ('d0000000-0000-4000-8000-0000000000a1', 'b0000000-0000-4000-8000-0000000000a1', 'X-campus'),
  ('d0000000-0000-4000-8000-0000000000a2', 'b0000000-0000-4000-8000-0000000000a2', 'Y-campus');

-- ------------------------------------------------------------------ INV: expiry, binding (invitee = heidi)
insert into public.invitations (id, organisation_id, email, invited_by_membership_id, created_at, expires_at) values
  ('e0000000-0000-4000-8000-0000000000a1', 'b0000000-0000-4000-8000-0000000000a1', 'heidi@wc-test.example', 'c0000000-0000-4000-8000-0000000000a1', now() - interval '1 day', now() - interval '1 minute'),
  ('e0000000-0000-4000-8000-0000000000a2', 'b0000000-0000-4000-8000-0000000000a2', 'heidi@wc-test.example', 'c0000000-0000-4000-8000-0000000000a2', now(), now() + interval '1 day');
insert into public.invitation_tokens (invitation_id, organisation_id, token_hash) values
  ('e0000000-0000-4000-8000-0000000000a1', 'b0000000-0000-4000-8000-0000000000a1', extensions.digest('tok-expired', 'sha256')),
  ('e0000000-0000-4000-8000-0000000000a2', 'b0000000-0000-4000-8000-0000000000a2', extensions.digest('tok-valid', 'sha256'));

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000009","role":"authenticated"}', true);   -- heidi
select throws_ok($$ select public.accept_invitation('tok-expired') $$, '22023', 'invalid_invitation', 'INV-05 an EXPIRED invitation cannot be accepted (generic error)');
select throws_ok($$ select public.accept_invitation('tok-nonexistent') $$, '22023', 'invalid_invitation', 'INV-05b an unknown token fails with the same error');
select lives_ok($$ select public.accept_invitation('tok-valid') $$, 'INV-04 a valid, unexpired invitation is accepted');
select is((select count(*) from public.campuses where organisation_id = 'b0000000-0000-4000-8000-0000000000a2'), 1::bigint, 'INV-04b access to Y appears only after acceptance');
select is((select count(*) from public.campuses where organisation_id = 'b0000000-0000-4000-8000-0000000000a1'), 0::bigint, 'INV-01 and none for X (expired invitation granted nothing)');

-- ------------------------------------------------------------------ DEF-02: hostile search_path
reset role;
create schema evil;
create table evil.memberships (organisation_id uuid, user_id uuid, id uuid, status text);
insert into evil.memberships values ('b0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-000000000012', gen_random_uuid(), 'active');  -- mallory "member" of X in the shadow table
create function public.vulnerable_is_member(p_org uuid) returns boolean language sql stable security definer as
  $$ select exists (select 1 from memberships m where m.organisation_id = p_org and m.user_id = auth.uid() and m.status = 'active') $$;
grant execute on function public.vulnerable_is_member(uuid) to authenticated;   -- (default privileges are locked down, so grant explicitly for this demonstration)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000012","role":"authenticated"}', true);   -- mallory
set local search_path = evil, public, pg_catalog, extensions;   -- the shadow schema comes FIRST; `extensions` stays reachable so pgTAP itself still works
select is(public.vulnerable_is_member('b0000000-0000-4000-8000-0000000000a1'), true, 'DEF-02 sensitivity check: a function WITHOUT search_path IS hijacked');
select is(private.is_member('b0000000-0000-4000-8000-0000000000a1'), false, 'DEF-02 hardened helper ignores the shadow table (is_member)');
select is(private.has_perm('b0000000-0000-4000-8000-0000000000a1', 'music.view'), false, 'DEF-02 hardened helper ignores the shadow table (has_perm)');
reset search_path; reset role;

-- ------------------------------------------------------------------ INT: guards and constraints (as the migration owner, bypassing RLS)
select throws_ok($$ update public.memberships set status = 'suspended' where id = 'c0000000-0000-4000-8000-0000000000a1' $$, '42501', null, 'MEM-13 the sole Owner cannot be suspended (trigger)');
select throws_ok($$ update public.membership_role_assignments set revoked_at = now() where membership_id = 'c0000000-0000-4000-8000-0000000000a1' and role_id = (select id from public.roles where system_key = 'owner') $$, '42501', null, 'MEM-13b the last Owner assignment cannot be revoked');
select lives_ok($$ update public.memberships set status = 'suspended' where id = 'c0000000-0000-4000-8000-0000000000a3' $$, 'MEM-14 active -> suspended is legal');
select lives_ok($$ update public.memberships set status = 'suspended' where id = 'c0000000-0000-4000-8000-0000000000a3' $$, 'MEM-14b re-setting the same status is a no-op, not a transition');
select lives_ok($$ update public.memberships set status = 'removed' where id = 'c0000000-0000-4000-8000-0000000000a3' $$, 'MEM-14c suspended -> removed is legal');
select throws_ok($$ update public.memberships set status = 'suspended' where id = 'c0000000-0000-4000-8000-0000000000a3' $$, '23514', null, 'MEM-14d removed -> suspended is illegal');
select is((select array_agg(to_status order by occurred_at, to_status) from public.membership_status_events where membership_id = 'c0000000-0000-4000-8000-0000000000a3'), array['active','removed','suspended'], 'status history records every transition');

select throws_ok($$ insert into public.teams (organisation_id, name, campus_id) values ('b0000000-0000-4000-8000-0000000000a1', 't', 'd0000000-0000-4000-8000-0000000000a2') $$, '23503', null, 'INT-01 composite FK: a team cannot reference another organisation''s campus');
select throws_ok($$ update public.campuses set organisation_id = 'b0000000-0000-4000-8000-0000000000a2' where id = 'd0000000-0000-4000-8000-0000000000a1' $$, '42501', null, 'ISO-06 organisation_id is immutable');
select throws_ok($$ update public.organisations set slug = 'renamed' where id = 'b0000000-0000-4000-8000-0000000000a1' $$, '42501', null, 'slug is immutable');
select throws_ok($$ insert into public.membership_role_assignments (organisation_id, membership_id, role_id, scope_type) values ('b0000000-0000-4000-8000-0000000000a1', 'c0000000-0000-4000-8000-0000000000a3', (select id from public.roles where system_key = 'team_leader'), 'organisation') $$, '23514', null, 'INT-04 role cannot be assigned at a scope it does not allow');
select throws_ok($$ insert into public.membership_role_assignments (organisation_id, membership_id, role_id, scope_type, team_id) values ('b0000000-0000-4000-8000-0000000000a1', 'c0000000-0000-4000-8000-0000000000a1', (select id from public.roles where system_key = 'member'), 'organisation', gen_random_uuid()) $$, '23514', null, 'INT-04b scope columns must match scope_type (CHECK)');
select throws_ok($$ insert into public.roles (organisation_id, name, is_system, assignable_scopes) values ('b0000000-0000-4000-8000-0000000000a1', 'sys', true, '{organisation}') $$, '23514', null, 'system flag requires NULL organisation (CHECK)');
select throws_ok($$ insert into public.role_permissions (role_id, permission_key) select r.id, 'music.view' from public.roles r where r.system_key = 'member' $$, '23505', null, 'duplicate role-permission pair is rejected (primary key)');
select lives_ok($$ insert into public.roles (id, organisation_id, name, is_system, assignable_scopes) values ('f0000000-0000-4000-8000-0000000000a1', 'b0000000-0000-4000-8000-0000000000a1', 'Custom', false, '{organisation}') $$, 'custom role insert');
select throws_ok($$ insert into public.role_permissions (role_id, permission_key) values ('f0000000-0000-4000-8000-0000000000a1', 'org.ownership.manage') $$, '42501', null, 'SCP-13 org.ownership.manage can never be part of a custom role');

select throws_ok($$ insert into public.invitations (organisation_id, email, invited_by_membership_id) values ('b0000000-0000-4000-8000-0000000000a1', 'HEIDI@wc-test.example', 'c0000000-0000-4000-8000-0000000000a1') $$, '23505', null, 'INV-14 one pending invitation per (organisation, e-mail), case-insensitive');
select throws_ok($$ insert into public.files (organisation_id, storage_path, original_filename, mime_type, size_bytes, purpose) values ('b0000000-0000-4000-8000-0000000000a1', 'wrong/path/x.pdf', 'x.pdf', 'application/pdf', 1, 'other') $$, '23514', null, 'FIL: storage_path must be {organisation}/{id}/{name} (CHECK)');
select throws_ok($$ insert into public.organisations (name, slug, timezone) values ('t', 'tz-test', 'EST') $$, '23514', null, 'timezone CHECK rejects an abbreviation');

-- ------------------------------------------------------------------ audit: append-only even for the table owner
select throws_ok($$ update public.audit_events set action = 'x.y' $$, '42501', null, 'CAT-15 UPDATE on audit_events is blocked');
select throws_ok($$ delete from public.audit_events $$, '42501', null, 'CAT-15 DELETE on audit_events is blocked');
select throws_ok($$ update public.membership_status_events set reason = 'x' $$, '42501', null, 'CAT-15 status history is append-only');
select throws_ok($$ update public.policy_acceptances set policy_version = 'x' $$, '42501', null, 'CAT-15 policy acceptances are append-only');

select * from finish();
rollback;
