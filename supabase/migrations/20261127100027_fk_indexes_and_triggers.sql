-- M-027: CORRECTIVE (found by CAT-10, CAT-14): index foreign keys that lacked a supporting index and add the missing
-- organisation_id-immutability trigger on membership_contacts. Partial indexes `WHERE col IS NOT NULL` are used for sparse
-- nullable scope columns (referential checks use equality, which implies NOT NULL).
set lock_timeout = '10s';
set statement_timeout = '60s';

create index if not exists invitation_teams_team_idx     on public.invitation_teams (team_id);
create index if not exists invitation_teams_org_inv_idx  on public.invitation_teams (organisation_id, invitation_id);
create index if not exists invitation_tokens_org_idx     on public.invitation_tokens (organisation_id);
create index if not exists invitations_campus_idx        on public.invitations (campus_id)     where campus_id is not null;
create index if not exists invitations_ministry_idx      on public.invitations (ministry_id)   where ministry_id is not null;
create index if not exists invitations_department_idx    on public.invitations (department_id) where department_id is not null;
create index if not exists invitations_team_idx          on public.invitations (team_id)       where team_id is not null;
create index if not exists invitations_role_idx          on public.invitations (role_id)       where role_id is not null;
create index if not exists mra_membership_all_idx        on public.membership_role_assignments (membership_id);
create index if not exists mra_role_idx                  on public.membership_role_assignments (role_id);
create index if not exists mra_campus_idx                on public.membership_role_assignments (campus_id)     where campus_id is not null;
create index if not exists mra_ministry_idx              on public.membership_role_assignments (ministry_id)   where ministry_id is not null;
create index if not exists mra_department_idx            on public.membership_role_assignments (department_id) where department_id is not null;
create index if not exists mra_team_idx                  on public.membership_role_assignments (team_id)       where team_id is not null;
create index if not exists team_memberships_member_all_idx on public.team_memberships (membership_id);

create trigger membership_contacts_forbid_org_change before update on public.membership_contacts
  for each row when (old.organisation_id is distinct from new.organisation_id) execute function private.forbid_org_change();
