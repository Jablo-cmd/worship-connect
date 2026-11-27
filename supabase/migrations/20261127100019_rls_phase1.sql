-- M-019: grants and RLS policies for every Phase-1 table (RLS_SECURITY_SPECIFICATION.md section 6.1-6.3, 6.6, 6.13).
-- Default deny: a table/operation with no policy is inaccessible. Tenant predicate form (spike S-4):
--   organisation_id = ANY ((select private.my_org_array())::uuid[])
-- WITH CHECK is evaluated AFTER BEFORE-triggers, so derived scope ancestors are what the policy sees.
set lock_timeout = '10s';
set statement_timeout = '60s';

-- ---------------------------------------------------------------- grants (minimum; RLS narrows further)
grant select on public.profiles to authenticated;
grant update (display_name, preferred_timezone, locale, avatar_path) on public.profiles to authenticated;

grant select on public.organisations to authenticated;
grant update (name, timezone, country_code, contact_email, contact_phone, website_url) on public.organisations to authenticated;
grant select on public.organisation_settings to authenticated;
grant update (locale, week_starts_on, default_service_duration_minutes, member_directory_visibility, allow_direct_messages,
              require_mfa_for_privileged, message_retention_days, attendance_retention_months, logo_file_id, ui_flags)
  on public.organisation_settings to authenticated;

grant select, insert, update on public.campuses, public.ministries, public.departments, public.teams, public.locations to authenticated;
grant select on public.permissions, public.roles, public.role_permissions to authenticated;
grant insert on public.roles to authenticated;
grant update (name, description, assignable_scopes, show_in_directory, archived_at) on public.roles to authenticated;
grant insert, delete on public.role_permissions to authenticated;

grant select on public.memberships to authenticated;
grant update (display_name, avatar_file_id, home_campus_id) on public.memberships to authenticated;
grant select on public.membership_status_events to authenticated;
grant select, insert, update, delete on public.membership_contacts to authenticated;
grant select, insert on public.policy_acceptances to authenticated;
grant select, insert, update, delete on public.team_memberships to authenticated;
grant select on public.membership_role_assignments, public.invitations, public.invitation_teams, public.files, public.audit_events to authenticated;
-- invitation_tokens: NO grants.

-- ---------------------------------------------------------------- profiles (global; self only - D-025)
create policy profiles_select_self on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ---------------------------------------------------------------- organisations
create policy organisations_select on public.organisations for select to authenticated
  using (id = any ((select private.my_org_array())::uuid[]));
create policy organisations_update on public.organisations for update to authenticated
  using (private.has_perm(id, 'org.settings.manage')) with check (private.has_perm(id, 'org.settings.manage'));
-- no INSERT/DELETE policy: creation is RPC-only, closure is a platform process.

create policy organisation_settings_select on public.organisation_settings for select to authenticated
  using (organisation_id = any ((select private.my_org_array())::uuid[]));
create policy organisation_settings_update on public.organisation_settings for update to authenticated
  using (private.has_perm(organisation_id, 'org.settings.manage')) with check (private.has_perm(organisation_id, 'org.settings.manage'));

-- ---------------------------------------------------------------- structure (readable by all members; managed by scope)
create policy campuses_select on public.campuses for select to authenticated using (organisation_id = any ((select private.my_org_array())::uuid[]));
create policy campuses_insert on public.campuses for insert to authenticated with check (private.has_perm(organisation_id, 'structure.manage'));
create policy campuses_update on public.campuses for update to authenticated
  using (private.has_perm(organisation_id, 'structure.manage', id)) with check (private.has_perm(organisation_id, 'structure.manage', id));

create policy ministries_select on public.ministries for select to authenticated using (organisation_id = any ((select private.my_org_array())::uuid[]));
create policy ministries_insert on public.ministries for insert to authenticated with check (private.has_perm(organisation_id, 'structure.manage', campus_id));
create policy ministries_update on public.ministries for update to authenticated
  using (private.has_perm(organisation_id, 'structure.manage', campus_id, id)) with check (private.has_perm(organisation_id, 'structure.manage', campus_id, id));

create policy departments_select on public.departments for select to authenticated using (organisation_id = any ((select private.my_org_array())::uuid[]));
create policy departments_insert on public.departments for insert to authenticated with check (private.has_perm(organisation_id, 'structure.manage', campus_id, ministry_id));
create policy departments_update on public.departments for update to authenticated
  using (private.has_perm(organisation_id, 'structure.manage', campus_id, ministry_id, id)) with check (private.has_perm(organisation_id, 'structure.manage', campus_id, ministry_id, id));

create policy teams_select on public.teams for select to authenticated using (organisation_id = any ((select private.my_org_array())::uuid[]));
create policy teams_insert on public.teams for insert to authenticated with check (private.has_perm(organisation_id, 'teams.manage', campus_id, ministry_id, department_id));
create policy teams_update on public.teams for update to authenticated
  using (private.has_perm(organisation_id, 'teams.manage', campus_id, ministry_id, department_id, id))
  with check (private.has_perm(organisation_id, 'teams.manage', campus_id, ministry_id, department_id, id));

create policy locations_select on public.locations for select to authenticated using (organisation_id = any ((select private.my_org_array())::uuid[]));
create policy locations_insert on public.locations for insert to authenticated with check (private.has_perm(organisation_id, 'locations.manage', campus_id));
create policy locations_update on public.locations for update to authenticated
  using (private.has_perm(organisation_id, 'locations.manage', campus_id)) with check (private.has_perm(organisation_id, 'locations.manage', campus_id));

-- ---------------------------------------------------------------- authorisation catalogue
create policy permissions_select on public.permissions for select to authenticated using (true);   -- global, non-secret
create policy roles_select on public.roles for select to authenticated
  using (organisation_id is null or organisation_id = any ((select private.my_org_array())::uuid[]));
create policy roles_insert on public.roles for insert to authenticated
  with check (organisation_id is not null and not is_system and system_key is null and private.has_perm(organisation_id, 'roles.manage'));
create policy roles_update on public.roles for update to authenticated
  using (organisation_id is not null and not is_system and private.has_perm(organisation_id, 'roles.manage'))
  with check (organisation_id is not null and not is_system and private.has_perm(organisation_id, 'roles.manage'));
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id));                     -- inherits roles RLS
create policy role_permissions_insert on public.role_permissions for insert to authenticated
  with check (private.can_edit_role_permission(role_id, permission_key));                 -- role-definition ceiling
create policy role_permissions_delete on public.role_permissions for delete to authenticated
  using (private.can_edit_role_permission(role_id, permission_key));

-- ---------------------------------------------------------------- memberships and member-owned data
-- A user always sees their own rows (to learn they are suspended); others see ACTIVE rows of organisations they are
-- active in; members.suspend holders also see non-active rows.
create policy memberships_select on public.memberships for select to authenticated using (
     user_id = (select auth.uid())
  or (organisation_id = any ((select private.my_org_array())::uuid[]) and status = 'active')
  or private.has_perm(organisation_id, 'members.suspend') );
create policy memberships_update_self on public.memberships for update to authenticated
  using (user_id = (select auth.uid()) and status = 'active' and organisation_id = any ((select private.my_org_array())::uuid[]))
  with check (user_id = (select auth.uid()) and status = 'active');
create policy memberships_update_managed on public.memberships for update to authenticated
  using (status = 'active' and private.has_perm_over_member(organisation_id, 'members.manage', id))
  with check (status = 'active' and private.has_perm_over_member(organisation_id, 'members.manage', id));
-- status/user_id/organisation_id are NOT updatable by any client (column grant): status changes go through set_membership_status().

create policy membership_status_events_select on public.membership_status_events for select to authenticated
  using (membership_id = private.my_membership_id(organisation_id) or private.has_perm(organisation_id, 'members.suspend'));

create policy membership_contacts_select on public.membership_contacts for select to authenticated
  using (membership_id = private.my_membership_id(organisation_id) or private.has_perm_over_member(organisation_id, 'members.view_contact', membership_id));
create policy membership_contacts_insert on public.membership_contacts for insert to authenticated
  with check (membership_id = private.my_membership_id(organisation_id));
create policy membership_contacts_update on public.membership_contacts for update to authenticated
  using (membership_id = private.my_membership_id(organisation_id)) with check (membership_id = private.my_membership_id(organisation_id));
create policy membership_contacts_delete on public.membership_contacts for delete to authenticated
  using (membership_id = private.my_membership_id(organisation_id));

create policy policy_acceptances_select on public.policy_acceptances for select to authenticated
  using (membership_id = private.my_membership_id(organisation_id) or private.has_perm(organisation_id, 'org.settings.manage'));
create policy policy_acceptances_insert on public.policy_acceptances for insert to authenticated
  with check (membership_id = private.my_membership_id(organisation_id));

create policy team_memberships_select on public.team_memberships for select to authenticated using (
  organisation_id = any ((select private.my_org_array())::uuid[])
  and ( private.directory_shows_teams(organisation_id)
     or membership_id = private.my_membership_id(organisation_id)
     or private.has_perm_for_team(organisation_id, 'teams.manage', team_id) ) );
create policy team_memberships_insert on public.team_memberships for insert to authenticated
  with check (private.has_perm_for_team(organisation_id, 'teams.manage', team_id));
create policy team_memberships_update on public.team_memberships for update to authenticated
  using (private.has_perm_for_team(organisation_id, 'teams.manage', team_id))
  with check (private.has_perm_for_team(organisation_id, 'teams.manage', team_id));
create policy team_memberships_delete on public.team_memberships for delete to authenticated
  using (private.has_perm_for_team(organisation_id, 'teams.manage', team_id) or membership_id = private.my_membership_id(organisation_id));

-- ---------------------------------------------------------------- role assignments (writes are RPC-only)
create policy mra_select on public.membership_role_assignments for select to authenticated using (
  organisation_id = any ((select private.my_org_array())::uuid[])
  and ( membership_id = private.my_membership_id(organisation_id)
     or private.has_perm(organisation_id, 'roles.assign') or private.has_perm(organisation_id, 'roles.manage')
     or exists (select 1 from public.roles r where r.id = role_id and r.show_in_directory) ) );

-- ---------------------------------------------------------------- invitations (writes are RPC-only; invitees have NO policy)
create policy invitations_select on public.invitations for select to authenticated using (
     invited_by_membership_id = private.my_membership_id(organisation_id)
  or private.has_perm_at_scope(organisation_id, 'members.invite', scope_type, coalesce(campus_id, ministry_id, department_id, team_id)) );
create policy invitation_teams_select on public.invitation_teams for select to authenticated
  using (exists (select 1 from public.invitations i where i.id = invitation_id));

-- ---------------------------------------------------------------- files (writes are RPC-only)
create policy files_select on public.files for select to authenticated
  using (private.can_read_file(id) or uploaded_by_user_id = (select auth.uid()));

-- ---------------------------------------------------------------- audit (append-only; clients can only read, with audit.view)
create policy audit_events_select on public.audit_events for select to authenticated
  using (organisation_id is not null and private.has_perm(organisation_id, 'audit.view'));
revoke insert, update, delete, truncate on public.audit_events from authenticated;
