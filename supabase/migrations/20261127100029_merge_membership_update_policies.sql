-- M-029: CORRECTIVE (Supabase performance advisor 0006 multiple_permissive_policies). Two permissive UPDATE policies on
-- memberships (self / managed) were evaluated for every update; merge them into one with identical semantics.
set lock_timeout = '10s';
set statement_timeout = '60s';
drop policy memberships_update_self    on public.memberships;
drop policy memberships_update_managed on public.memberships;
create policy memberships_update on public.memberships for update to authenticated
  using ( status = 'active'
          and ( (user_id = (select auth.uid()) and organisation_id = any ((select private.my_org_array())::uuid[]))
             or private.has_perm_over_member(organisation_id, 'members.manage', id) ) )
  with check ( status = 'active'
          and ( user_id = (select auth.uid()) or private.has_perm_over_member(organisation_id, 'members.manage', id) ) );
-- Column privileges are unchanged: only display_name, avatar_file_id, home_campus_id are updatable by clients.
