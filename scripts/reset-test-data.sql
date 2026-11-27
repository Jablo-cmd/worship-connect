-- DEV / TEST ONLY. Wipes all tenant data (keeps permissions, system roles and the synthetic seed users) so the
-- security suite can run against a persistent development database. NEVER run in production.
-- Refuses to run unless every auth user is a synthetic @wc-test.example one.
-- (Explicit ordered deletes, NOT truncate ... cascade: cascading from organisations would also wipe the system roles.)
do $$
begin
  if exists (select 1 from auth.users where email not like '%@wc-test.example') then
    raise exception 'refusing to reset: non-test users exist in this database';
  end if;
end $$;

alter table public.membership_status_events disable trigger membership_status_events_block;
alter table public.policy_acceptances       disable trigger policy_acceptances_block;
alter table platform.organisation_status_log disable trigger organisation_status_log_block;

delete from platform.support_access_grants;
delete from platform.takedown_requests;
delete from platform.organisation_status_log;
delete from public.invitation_teams;
delete from public.invitation_tokens;
delete from public.invitations;
delete from public.membership_role_assignments;
delete from public.team_memberships;
delete from public.membership_status_events;
delete from public.membership_contacts;
delete from public.policy_acceptances;
delete from public.role_permissions where role_id in (select id from public.roles where organisation_id is not null);
delete from public.roles where organisation_id is not null;
delete from public.teams;
delete from public.departments;
delete from public.ministries;
delete from public.locations;
delete from public.memberships;
delete from public.campuses;
delete from public.organisation_settings;
delete from public.files;
delete from public.organisations;
truncate table public.audit_events;          -- TRUNCATE fires no row triggers; partitions follow the parent
delete from storage.objects where bucket_id = 'org-files';

alter table public.membership_status_events enable trigger membership_status_events_block;
alter table public.policy_acceptances       enable trigger policy_acceptances_block;
alter table platform.organisation_status_log enable trigger organisation_status_log_block;
